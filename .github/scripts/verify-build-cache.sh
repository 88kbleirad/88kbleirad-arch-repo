#!/usr/bin/env bash
#
# Deterministic build-cache verification (Objective C).
#
# Consumes per-package build results (status files + v4 metadata + package
# archives in output/) and matches each requested package in the expected
# inventory to its result. Distinguishes:
#
#   HIT    - status-skipped (cache hit) and a VALID package archive exists
#   MISS   - status-built (legitimate rebuild) — allowed in normal mode
#   MISS_FINGERPRINT - cached metadata exists but fingerprint changed
#   MISS_ARCHIVE - matching metadata but no package archive
#   INVALID - cached archive failed structural/metadata validation (with a
#              precise reason)
#   FAILED - build status-failed
#   EXCLUDED - intentionally excluded (in excluded set)
#   MISSING - no result recorded for an expected package
#
# Archive validation distinguishes INFRASTRUCTURE errors (missing tools)
# from corrupted content. Without a working archive reader the verification
# fails closed and reports TOOL_UNAVAILABLE — never "CORRUPT".
#
# Modes:
#   --strict   any unexpected cache miss (rebuild, fingerprint change,
#              missing archive, invalid artifact) fails verification
#   --all      expect 100% cache hits (strict + no excluded/external)
#   (default)  normal production mode: rebuilds are allowed and reported
#
# Output: machine-readable JSON summary + human-readable table.
#
# Usage:
#   verify-build-cache.sh --expected '<[pkg,...]>' \
#       --results-dir <dir> [--strict|--all] [--excluded '<json>']
#       [--hashes '<{pkg: sha256hex,...}>']
#
# results-dir layout (from build jobs / publish artifacts):
#   status-<state>-<pkg>.txt      (state: built|skipped|restored|failed)
#   protect-*.txt                  (protected names)
#   v4-<pkg>.meta.json             (metadata, contains fingerprint/profile)
#   *.pkg.tar.zst                  (package archives)

set -euo pipefail

MODE="normal"
EXPECTED_JSON=""
RESULTS_DIR=""
EXCLUDED_JSON=""
EXPECTED_HASHES_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected) shift; EXPECTED_JSON="$1" ;;
    --results-dir) shift; RESULTS_DIR="$1" ;;
    --excluded) shift; EXCLUDED_JSON="$1" ;;
    --hashes) shift; EXPECTED_HASHES_JSON="$1" ;;
    --strict) MODE="strict" ;;
    --all) MODE="all" ;;
  esac
  shift
done

[[ -n "$EXPECTED_JSON" ]] || { echo "::error::--expected JSON is required"; exit 2; }
[[ -n "$RESULTS_DIR" && -d "$RESULTS_DIR" ]] || { echo "::error::--results-dir must exist"; exit 2; }

expected_names=()
while IFS= read -r name; do
  [[ -n "$name" ]] && expected_names+=("$name")
done < <(printf '%s\n' "$EXPECTED_JSON" | jq -r '.[]')

excluded_names=()
if [[ -n "$EXCLUDED_JSON" ]]; then
  while IFS= read -r name; do
    [[ -n "$name" ]] && excluded_names+=("$name")
  done < <(printf '%s\n' "$EXCLUDED_JSON" | jq -r '.[]')
fi

declare -A EXPECTED_HASHES=()
if [[ -n "$EXPECTED_HASHES_JSON" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pkg="${line%%|*}"
    hex="${line#*|}"
    EXPECTED_HASHES["$pkg"]="$hex"
  done < <(printf '%s\n' "$EXPECTED_HASHES_JSON" | jq -r 'to_entries[] | "\(.key)|\(.value)"')
fi

# build a lookup of status by package
declare -A STATUS_BY_PKG=()
for f in "$RESULTS_DIR"/status-*.txt; do
  [[ -f "$f" ]] || continue
  bn=$(basename "$f")
  state="${bn#status-}"
  state="${state%%-*}"
  pkg="${bn#status-${state}-}"
  pkg="${pkg%.txt}"
  [[ -n "$pkg" ]] && STATUS_BY_PKG["$pkg"]="$state"
done

declare -A META_FP=()
declare -A META_PROFILE=()
for f in "$RESULTS_DIR"/v4-*.meta.json; do
  [[ -f "$f" ]] || continue
  bn=$(basename "$f")
  pkg="${bn#v4-}"
  pkg="${pkg%.meta.json}"
  fp=$(jq -r '.fingerprint // empty' "$f" 2>/dev/null || true)
  prof=$(jq -r '.profile // empty' "$f" 2>/dev/null || true)
  META_FP["$pkg"]="$fp"
  META_PROFILE["$pkg"]="$prof"
done

# ---------------------------------------------------------------------------
# Archive validation with precise diagnostics.
#
# Tool selection: prefer bsdtar (libarchive), fall back to GNU tar with
# zstd. If neither is usable, VALIDATION_TOOL_ERROR is set and every
# artifact is classified TOOL_UNAVAILABLE (infrastructure error), never
# CORRUPT.
# ---------------------------------------------------------------------------
ARCHIVE_TOOL=""
VALIDATION_TOOL_ERROR=""

detect_archive_tool() {
  if command -v bsdtar >/dev/null 2>&1; then
    # probe: bsdtar must actually run (a broken shim must not pass)
    if bsdtar --version >/dev/null 2>&1; then
      ARCHIVE_TOOL="bsdtar"
      return 0
    fi
  fi
  if command -v tar >/dev/null 2>&1; then
    if tar --version >/dev/null 2>&1 && tar --zstd --version >/dev/null 2>&1; then
      ARCHIVE_TOOL="tar-zstd"
      return 0
    fi
  fi
  VALIDATION_TOOL_ERROR="required archive validation tool unavailable (bsdtar/libarchive or tar with zstd)"
  return 1
}

# archive_list <file> -> list members (or empty)
archive_list() {
  local f="$1"
  if [[ "$ARCHIVE_TOOL" == "bsdtar" ]]; then
    bsdtar -tf "$f" 2>/dev/null
  else
    tar --zstd -tf "$f" 2>/dev/null
  fi
}

# archive_pkginfo <file> -> prints .PKGINFO content (or empty)
archive_pkginfo() {
  local f="$1"
  if [[ "$ARCHIVE_TOOL" == "bsdtar" ]]; then
    bsdtar -xOf "$f" .PKGINFO 2>/dev/null
  else
    tar --zstd -xOf "$f" .PKGINFO 2>/dev/null
  fi
}

# validate_archive <file> -> 0 valid, 1 invalid
# Sets VALIDATION_REASON on failure.
validate_archive() {
  local f="$1"
  VALIDATION_REASON=""
  [[ -s "$f" ]] || { VALIDATION_REASON="missing archive"; return 1; }
  if ! archive_list "$f" | grep -q '^\.PKGINFO$'; then
    VALIDATION_REASON="archive decompression failed or missing .PKGINFO"
    return 1
  fi
  if ! archive_pkginfo "$f" | grep -q '^pkgname = '; then
    VALIDATION_REASON="missing .PKGINFO (no pkgname)"
    return 1
  fi
  return 0
}

if ! detect_archive_tool; then
  echo "ERROR: $VALIDATION_TOOL_ERROR"
  echo "::error::$VALIDATION_TOOL_ERROR"
fi

declare -A RESULTS=()
declare -A ARTIFACT=()

for name in "${expected_names[@]}"; do
  status="${STATUS_BY_PKG[$name]:-}"

  if [[ -n "$VALIDATION_TOOL_ERROR" ]]; then
    RESULTS["$name"]="TOOL_UNAVAILABLE"
    ARTIFACT["$name"]="ERROR"
    continue
  fi

  # duplicate detection: more than one status file or more than one archive
  # for the same package is an invalid result
  n_status=0
  for f in "$RESULTS_DIR"/status-*-"$name".txt; do
    [[ -f "$f" ]] && n_status=$(( n_status + 1 ))
  done
  n_arch=0
  for a in "$RESULTS_DIR"/"$name"-*.pkg.tar.zst; do
    [[ -f "$a" ]] && n_arch=$(( n_arch + 1 ))
  done
  if (( n_status > 1 || n_arch > 1 )); then
    RESULTS["$name"]="DUPLICATE"
    ARTIFACT["$name"]="n_status=$n_status n_arch=$n_arch"
    continue
  fi

  # build profile verification: cached metadata must carry the v4 profile
  if [[ -n "${META_PROFILE[$name]:-}" && "${META_PROFILE[$name]}" != "${BUILD_PROFILE:-x86-64-v4}" ]]; then
    RESULTS["$name"]="WRONG_PROFILE"
    ARTIFACT["$name"]="${META_PROFILE[$name]}"
    continue
  fi

  art=""
  for a in "$RESULTS_DIR"/"$name"-*.pkg.tar.zst; do
    [[ -f "$a" ]] && { art="$a"; break; }
  done

  case "$status" in
    skipped)
      # cache hit: must have a valid archive
      if [[ -n "$art" ]] && validate_archive "$art"; then
        if [[ -n "${EXPECTED_HASHES[$name]:-}" ]]; then
          actual=$(sha256sum "$art" | awk '{print $1}')
          if [[ "$actual" != "${EXPECTED_HASHES[$name]}" ]]; then
            RESULTS["$name"]="INVALID"
            ARTIFACT["$name"]="checksum mismatch"
            continue
          fi
        fi
        RESULTS["$name"]="HIT"
        ARTIFACT["$name"]="VALID"
      elif [[ -n "$art" ]]; then
        RESULTS["$name"]="INVALID"
        ARTIFACT["$name"]="$VALIDATION_REASON"
      else
        RESULTS["$name"]="MISS_ARCHIVE"
        ARTIFACT["$name"]="MISSING"
      fi
      ;;
    built)
      if [[ -n "$art" ]] && validate_archive "$art"; then
        if [[ -n "${EXPECTED_HASHES[$name]:-}" ]]; then
          actual=$(sha256sum "$art" | awk '{print $1}')
          if [[ "$actual" != "${EXPECTED_HASHES[$name]}" ]]; then
            RESULTS["$name"]="INVALID"
            ARTIFACT["$name"]="checksum mismatch"
            continue
          fi
        fi
        RESULTS["$name"]="MISS"
        ARTIFACT["$name"]="VALID"
      elif [[ -n "$art" ]]; then
        RESULTS["$name"]="INVALID"
        ARTIFACT["$name"]="$VALIDATION_REASON"
      else
        RESULTS["$name"]="MISS_ARCHIVE"
        ARTIFACT["$name"]="MISSING"
      fi
      ;;
    restored)
      RESULTS["$name"]="MISS"
      ARTIFACT["$name"]="RESTORED"
      ;;
    failed)
      RESULTS["$name"]="FAILED"
      ARTIFACT["$name"]="NONE"
      ;;
    "")
      if [[ -n "${META_FP[$name]:-}" ]]; then
        RESULTS["$name"]="MISS_FINGERPRINT"
        ARTIFACT["$name"]="NO_ARCHIVE"
      else
        RESULTS["$name"]="MISSING"
        ARTIFACT["$name"]="NONE"
      fi
      ;;
  esac
done

# excluded packages: confirm they are absent from results (or present as
# intentionally excluded)
for name in "${excluded_names[@]}"; do
  if [[ -n "${STATUS_BY_PKG[$name]:-}" ]]; then
    RESULTS["$name"]="EXCLUDED"
    ARTIFACT["$name"]="SKIPPED"
  fi
done

# ---- machine-readable summary --------------------------------------------
hits=0; misses=0; invalid=0; failed=0; excluded=0; missing=0; duplicates=0; tool_missing=0
for name in "${expected_names[@]}"; do
  case "${RESULTS[$name]:-MISSING}" in
    HIT) hits=$(( hits + 1 )) ;;
    MISS) misses=$(( misses + 1 )) ;;
    TOOL_UNAVAILABLE) tool_missing=$(( tool_missing + 1 )) ;;
    MISS_FINGERPRINT|MISS_ARCHIVE|INVALID|WRONG_PROFILE|DUPLICATE) invalid=$(( invalid + 1 )) ;;
    FAILED) failed=$(( failed + 1 )) ;;
    EXCLUDED) excluded=$(( excluded + 1 )) ;;
    MISSING) missing=$(( missing + 1 )) ;;
  esac
done

cat <<JSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "expected": ${#expected_names[@]},
  "validated": $(( ${#expected_names[@]} - missing )),
  "hits": $hits,
  "misses": $misses,
  "invalid": $invalid,
  "failed": $failed,
  "excluded": $excluded,
  "missing": $missing,
  "tool_unavailable": $tool_missing,
  "mode": "$MODE"
}
JSON

# ---- cache-history sidecar (CI performance metrics) --------------------------
# One line per run for observability: timestamp, run id (when present), and
# cache counters. Written only when the run has a workspace to write to; this
# is a pure local artifact, never uploaded by this script.
if [[ -n "${GITHUB_WORKSPACE:-}" && -d "$GITHUB_WORKSPACE" ]]; then
  run_id="${GITHUB_RUN_ID:-}"
  printf '%s\n' "$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg run "$run_id" \
    --argjson hits "$hits" \
    --argjson misses "$misses" \
    --argjson invalid "$invalid" \
    --argjson failed "$failed" \
    --argjson excluded "$excluded" \
    --argjson missing "$missing" \
    '{timestamp:$ts, run:$run, hits:$hits, misses:$misses, invalid:$invalid,
      failed:$failed, excluded:$excluded, missing:$missing,
      hit_rate:(if ($hits + $misses) > 0 then (($hits * 1000 / ($hits + $misses)) | round / 10) else null end)}')" \
    > "$GITHUB_WORKSPACE/cache-history.jsonl"
fi

# ---- human-readable table ---------------------------------------------------
printf '%-32s %-20s %s\n' "Package" "Cache Status" "Artifact"
printf '%-32s %-20s %s\n' "-------" "-----------" "--------"
for name in "${expected_names[@]}"; do
  printf '%-32s %-20s %s\n' "$name" "${RESULTS[$name]:-MISSING}" "${ARTIFACT[$name]:-NONE}"
done

# ---- verdict --------------------------------------------------------------
verdict=0
for name in "${expected_names[@]}"; do
  case "${RESULTS[$name]:-MISSING}" in
    HIT) ;;
    MISS)
      if [[ "$MODE" == "strict" || "$MODE" == "all" ]]; then
        echo "::error::cache verification: unexpected rebuild for $name (strict mode)"
        verdict=1
      fi
      ;;
    TOOL_UNAVAILABLE)
      echo "::error::cache verification: validation tool unavailable; cannot verify $name"
      verdict=1
      ;;
    MISS_FINGERPRINT|MISS_ARCHIVE|INVALID|FAILED|WRONG_PROFILE|DUPLICATE)
      echo "::error::cache verification: ${RESULTS[$name]} for $name (${ARTIFACT[$name]:-})"
      verdict=1
      ;;
    MISSING)
      echo "::error::cache verification: no result recorded for $name"
      verdict=1
      ;;
    EXCLUDED) ;;
  esac
done

exit $verdict
