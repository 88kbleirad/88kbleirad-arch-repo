#!/usr/bin/env bash
#
# Single matrix-generation script for the production and staging publish
# workflows. All user-controlled workflow inputs are read from environment
# bindings (never interpolated into shell source) and are validated here:
#
#   - package names are matched against a strict character class
#     (AUR pkgname rules); anything else is rejected before it can reach
#     a shell, a path, or the build matrix
#   - empty selections are rejected
#   - duplicates are dropped deterministically (first occurrence wins)
#   - every selected package must have a PKGBUILD directory
#   - system-critical packages are handled from ONE shared list
#     (.github/scripts/critical-packages.sh)
#
# Modes:
#   MODE=staging   - any critical package is rejected without exception
#   MODE=production - critical packages are excluded by default; an exact
#                     `allow-critical` approval may include one; scheduled
#                     runs have no inputs and can never include them
#
# Environment (all values arrive via workflow env bindings):
#   MODE, EVENT_NAME, INPUT_CONFIRM_PRODUCTION, INPUT_PACKAGES,
#   INPUT_ALLOW_CRITICAL, INPUT_INCLUDE_KSUPERKEY,
#   ALLOW_SCHEDULED_PRODUCTION, GITHUB_WORKSPACE, GITHUB_OUTPUT,
#   GITHUB_STEP_SUMMARY, RELEASE_TAG

set -euo pipefail

MODE="${MODE:?MODE is required (staging|production)}"
EVENT_NAME="${EVENT_NAME:-workflow_dispatch}"

. "$GITHUB_WORKSPACE/.github/scripts/critical-packages.sh"

die() { echo "::error::$*" >&2; exit 1; }

# parse_list <var> <csv>: trims whitespace, validates the strict name
# charset, rejects empty entries, deduplicates deterministically.
parse_list() {
  local outvar="$1" csv="$2" entry
  local -a parts=() result=()
  local -A seen=()

  # reject embedded newlines / carriage returns outright — they can be
  # used to smuggle extra commands or truncate the list silently
  if [[ "$csv" == *$'\n'* || "$csv" == *$'\r'* ]]; then
    die "Invalid package list: embedded newline/carriage-return is not allowed."
  fi

  IFS=',' read -r -a parts <<< "$csv"
  for entry in "${parts[@]}"; do
    entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$entry" ]] || continue
    if [[ ! "$entry" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
      die "Invalid package name '$entry' (allowed characters: letters, digits, @ . _ + -)."
    fi
    if [[ -n "${seen[$entry]:-}" ]]; then
      echo "::warning::Duplicate package name '$entry' ignored."
      continue
    fi
    seen["$entry"]=1
    result+=("$entry")
  done
  # assign result to the requested variable name
  eval "$outvar=(\"\${result[@]}\")"
}

pkg_has_pkgbuild() { [[ -f "$1/PKGBUILD" ]]; }

# ---------------------------------------------------------------------------
# staging mode
# ---------------------------------------------------------------------------
if [[ "$MODE" == "staging" ]]; then
  PKG_LIST="${INPUT_PACKAGES:-}"
  if [[ -z "$PKG_LIST" ]]; then
    PKG_LIST="nmtui-go,osu-mime"
  fi
  parse_list REQUESTED "$PKG_LIST"

  # include-ksuperkey boolean input from the workflow (optional, exact)
  if [[ "${INPUT_INCLUDE_KSUPERKEY:-}" == "true" ]]; then
    local_ok=1
    for p in "${REQUESTED[@]}"; do
      [[ "$p" == "ksuperkey" ]] && local_ok=0
    done
    if [[ $local_ok -eq 1 ]]; then
      REQUESTED+=("ksuperkey")
    fi
  fi

  for pkg in "${REQUESTED[@]}"; do
    if ! pkg_has_pkgbuild "$pkg"; then
      die "Requested package '$pkg' has no PKGBUILD directory; aborting."
    fi
    if printf '%s\n' "${CRITICAL_PACKAGES[@]}" | grep -qx "$pkg"; then
      die "System-critical package '$pkg' is forbidden in staging."
    fi
  done

  if (( ${#REQUESTED[@]} == 0 )); then
    die "No valid packages requested."
  fi

  MATRIX_JSON=$(printf '%s\n' "${REQUESTED[@]}" | jq -R . | jq -s -c .)
  echo "staging matrix: $MATRIX_JSON"
  echo "matrix=$MATRIX_JSON" >> "$GITHUB_OUTPUT"

  {
    echo "## Staging build (${RELEASE_TAG:-repository-v4-test})"
    echo ""
    echo "- Packages: ${REQUESTED[*]}"
    echo "- Target: x86-64-v4 (CachyOS)"
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# ---------------------------------------------------------------------------
# production mode
# ---------------------------------------------------------------------------
if [[ "$MODE" != "production" ]]; then
  die "Unknown MODE '$MODE' (expected staging|production)."
fi

# manual confirmation gate
if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then
  if [[ "${INPUT_CONFIRM_PRODUCTION:-}" != "YES" ]]; then
    die "Production runs require the 'confirm-production' input set to YES (manual verification mode)."
  fi
fi

# schedule authorization gate (separate, explicitly authorized path)
if [[ "$EVENT_NAME" == "schedule" ]]; then
  if [[ "${ALLOW_SCHEDULED_PRODUCTION:-}" != "yes" ]]; then
    die "Scheduled production runs are not authorized (set repository variable ALLOW_SCHEDULED_PRODUCTION=yes in the separately approved enable-PR)."
  fi
  echo "::notice::Scheduled production run authorized (ALLOW_SCHEDULED_PRODUCTION=yes)."
fi

if [[ ! -f packages.txt ]]; then
  die "packages.txt not found at repo root."
fi

# approved critical packages (manual allow-critical, exact names only)
APPROVED_CRITICAL=()
if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then
  parse_list APPROVED_CRITICAL "${INPUT_ALLOW_CRITICAL:-}"
  for c in "${APPROVED_CRITICAL[@]}"; do
    if ! printf '%s\n' "${CRITICAL_PACKAGES[@]}" | grep -qx "$c"; then
      die "'$c' is not a known system-critical package; refusing the approval list."
    fi
  done
fi

is_approved() {
  local pkg="$1" c
  for c in "${APPROVED_CRITICAL[@]:-}"; do
    [[ "$pkg" == "$c" ]] && return 0
  done
  return 1
}
is_critical() {
  local pkg="$1" c
  for c in "${CRITICAL_PACKAGES[@]}"; do
    [[ "$pkg" == "$c" ]] && return 0
  done
  return 1
}
is_requested() {
  local pkg="$1" req
  [[ "$EVENT_NAME" == "workflow_dispatch" ]] || return 1
  (( ${#REQUESTED[@]} > 0 )) || return 1
  for req in "${REQUESTED[@]}"; do
    [[ "$req" == "$pkg" ]] && return 0
  done
  return 1
}

# optional subset input
REQUESTED=()
if [[ "$EVENT_NAME" == "workflow_dispatch" && -n "${INPUT_PACKAGES:-}" ]]; then
  parse_list REQUESTED "$INPUT_PACKAGES"
  declare -A PACKAGES_TXT=()
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    pkg_entry="$(printf '%s' "$raw_line" | sed 's/#.*//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$pkg_entry" ]] && continue
    PACKAGES_TXT["${pkg_entry#local:}"]=1
  done < packages.txt

  for req in "${REQUESTED[@]}"; do
    if [[ -z "${PACKAGES_TXT[$req]:-}" ]]; then
      die "Requested package '$req' is not listed in packages.txt; refusing subset selection."
    fi
  done
fi

pkgs=()
missing=()
excluded=()
REQUESTED_SUBSET=false
(( ${#REQUESTED[@]} > 0 )) && REQUESTED_SUBSET=true

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  pkg_entry="$(printf '%s' "$raw_line" | sed 's/#.*//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -z "$pkg_entry" ]] && continue
  # local: prefix marks manually maintained packages inside the repo
  pkg="${pkg_entry#local:}"
  if ! pkg_has_pkgbuild "$pkg"; then
    echo "::warning::packages.txt entry '$pkg' has no PKGBUILD directory; skipped"
    missing+=("$pkg")
    continue
  fi
  if is_critical "$pkg"; then
    if is_approved "$pkg"; then
      echo "::notice::system-critical package '$pkg' explicitly approved for this run."
      pkgs+=("$pkg")
    elif is_requested "$pkg"; then
      die "Requested system-critical package '$pkg' requires explicit approval. Add '$pkg' to the 'allow-critical' input to build it."
    else
      echo "::warning::system-critical package '$pkg' excluded from the default matrix (requires explicit 'allow-critical' approval)."
      excluded+=("$pkg")
    fi
    continue
  fi
  if [[ "$REQUESTED_SUBSET" == "true" ]]; then
    selected=0
    for req in "${REQUESTED[@]}"; do
      [[ "$req" == "$pkg" ]] && { selected=1; break; }
    done
    [[ $selected -eq 1 ]] || continue
  fi
  pkgs+=("$pkg")
done < packages.txt

if (( ${#pkgs[@]} == 0 )); then
  die "No buildable packages found (empty selection). Refusing to run."
fi

MATRIX_JSON=$(printf '%s\n' "${pkgs[@]}" | jq -R . | jq -s -c .)
echo "Found packages: $MATRIX_JSON"
echo "matrix=$MATRIX_JSON" >> "$GITHUB_OUTPUT"
if (( ${#missing[@]} > 0 )); then
  echo "missing=$(printf '%s,' "${missing[@]}" | sed 's/,$//')" >> "$GITHUB_OUTPUT"
fi
if (( ${#excluded[@]} > 0 )); then
  echo "excluded=$(printf '%s,' "${excluded[@]}" | sed 's/,$//')" >> "$GITHUB_OUTPUT"
  printf '%s\n' "${excluded[@]}" > output-excluded-bases.txt
  echo "excluded_bases_file=output-excluded-bases.txt" >> "$GITHUB_OUTPUT"
fi

{
  echo "## Package selection (packages.txt)"
  echo ""
  echo "- Buildable entries: ${#pkgs[@]}"
  if (( ${#missing[@]} > 0 )); then
    echo "- Missing PKGBUILD definitions (skipped): ${missing[*]}"
  fi
  if (( ${#excluded[@]} > 0 )); then
    echo "- System-critical packages excluded (explicit approval required): ${excluded[*]}"
  fi
  echo "- Matrix built from packages.txt only."
} >> "$GITHUB_STEP_SUMMARY"
