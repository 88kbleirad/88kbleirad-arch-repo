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
#   INVALID - cached archive failed structural/metadata validation
#   FAILED - build status-failed
#   EXCLUDED - intentionally excluded (in excluded set)
#   MISSING - no result recorded for an expected package
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected) shift; EXPECTED_JSON="$1" ;;
    --results-dir) shift; RESULTS_DIR="$1" ;;
    --excluded) shift; EXCLUDED_JSON="$1" ;;
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

# archive validation
validate_archive() { # file -> 0 valid, 1 invalid
  local f="$1"
  [[ -s "$f" ]] || return 1
  bsdtar -tf "$f" >/dev/null 2>&1 || return 1
  bsdtar -xOf "$f" .PKGINFO 2>/dev/null | grep -q '^pkgname = ' || return 1
  return 0
}

declare -A RESULTS=()
declare -A ARTIFACT=()

for name in "${expected_names[@]}"; do
  status="${STATUS_BY_PKG[$name]:-}"

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

  case "$status" in
    skipped)
      # cache hit: must have a valid archive
      art=""
      for a in "$RESULTS_DIR"/"$name"-*.pkg.tar.zst; do
        [[ -f "$a" ]] && { art="$a"; break; }
      done
      if [[ -n "$art" ]] && validate_archive "$art"; then
        RESULTS["$name"]="HIT"
        ARTIFACT["$name"]="VALID"
      elif [[ -n "$art" ]]; then
        RESULTS["$name"]="INVALID"
        ARTIFACT["$name"]="CORRUPT"
      else
        RESULTS["$name"]="MISS_ARCHIVE"
        ARTIFACT["$name"]="MISSING"
      fi
      ;;
    built)
      art=""
      for a in "$RESULTS_DIR"/"$name"-*.pkg.tar.zst; do
        [[ -f "$a" ]] && { art="$a"; break; }
      done
      if [[ -n "$art" ]] && validate_archive "$art"; then
        RESULTS["$name"]="MISS"
        ARTIFACT["$name"]="VALID"
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
hits=0; misses=0; invalid=0; failed=0; excluded=0; missing=0; duplicates=0
for name in "${expected_names[@]}"; do
  case "${RESULTS[$name]:-MISSING}" in
    HIT) hits=$(( hits + 1 )) ;;
    MISS) misses=$(( misses + 1 )) ;;
    MISS_FINGERPRINT|MISS_ARCHIVE) invalid=$(( invalid + 1 )) ;;
    INVALID|WRONG_PROFILE|DUPLICATE) invalid=$(( invalid + 1 )) ;;
    FAILED) failed=$(( failed + 1 )) ;;
    EXCLUDED) excluded=$(( excluded + 1 )) ;;
    MISSING) missing=$(( missing + 1 )) ;;
  esac
done

cat <<JSON
{
  "expected": ${#expected_names[@]},
  "validated": $(( ${#expected_names[@]} - missing )),
  "hits": $hits,
  "misses": $misses,
  "invalid": $invalid,
  "failed": $failed,
  "excluded": $excluded,
  "missing": $missing,
  "mode": "$MODE"
}
JSON

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
    MISS_FINGERPRINT|MISS_ARCHIVE|INVALID|FAILED|WRONG_PROFILE|DUPLICATE)
      echo "::error::cache verification: ${RESULTS[$name]} for $name"
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
