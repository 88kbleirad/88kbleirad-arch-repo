#!/usr/bin/env bash
#
# Cross-workflow artifact collector for the Phase 5.3 observability
# dashboard.
#
# WHY THIS EXISTS
# ---------------
# `actions/download-artifact` only ever sees artifacts of the CURRENT
# workflow run unless it is given an explicit `run-id`, and its `pattern`
# input is a SINGLE glob (a multiline value matches nothing). The
# dashboard's inputs (health reports, lifecycle report, previous metrics
# history) are produced by OTHER workflows in OTHER runs, so retrieval
# must go through the GitHub Actions REST API:
#
#   1. enumerate the repository's artifacts (paginated),
#   2. resolve the owning workflow run of every candidate and require a
#      COMPLETED + SUCCESSFUL run (never an in-flight or failed one),
#   3. honour artifact expiration/retention,
#   4. never ingest the CURRENT run's own artifacts (recursion guard),
#   5. download each selected artifact into its OWN directory (artifact
#      names collide: every health report ships a file called
#      `health-report.json`),
#   6. validate every downloaded file against its report schema and
#      REJECT malformed data instead of rendering it as healthy,
#   7. persist history by retrieving the most recent `metrics-snapshot`
#      artifact from a PREVIOUS successful run of this workflow.
#
# READ-ONLY: this script performs HTTP GETs only (`gh api <path>`, never
# --method/--field/--input), so a stray write is impossible.
#
# Usage:
#   collect-artifacts.sh --repo OWNER/REPO --run-id <current-run-id>
#       --out <dir>
#       [--inventory <file>] [--history-out <file>] [--summary <file>]
#       [--prod-release repository] [--staging-release repository-v4-test]
#       [--max-pages 10]
#
# Environment: GH_TOKEN (github.token), GITHUB_REPOSITORY, GITHUB_RUN_ID
#
# Output (--inventory): a `repo-artifact-inventory/v1` document:
#   {
#     "schema": "repo-artifact-inventory/v1",
#     "generated_at": ISO8601,
#     "repository": "owner/repo",
#     "current_run_id": "123",
#     "completeness": "COMPLETE|PARTIAL|NO_DATA",
#     "core_sources": [...], "optional_sources": [...],
#     "sources": {
#       "health_production": {
#         "status": "ok|not_found|expired|source_run_failed|
#                    source_run_incomplete|source_run_unknown|invalid|
#                    download_failed|self_run",
#         "artifact", "artifact_id", "run_id", "run_conclusion",
#         "created_at", "expires_at", "file", "state",
#         "report_timestamp", "reason"
#       }, ...
#     },
#     "missing": [core slots without data],
#     "unavailable": [optional slots without data],
#     "rejected": [{slot, artifact, artifact_id, run_id, reason}],
#     "warnings": [...]
#   }
#
# Completeness criteria (documented, stable):
#   core sources = health_production, health_staging, lifecycle
#   COMPLETE     = every core source retrieved and schema-valid
#   PARTIAL      = at least one core source ok, but not all
#   NO_DATA      = no core source ok
# A NO_DATA dashboard is an explicitly labelled incomplete state; the
# workflow turns it into a failed run after uploading the artifact.

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-}"
RUN_ID="${GITHUB_RUN_ID:-}"
OUT=""
INVENTORY=""
HISTORY_OUT=""
SUMMARY=""
PROD_RELEASE="repository"
STAGING_RELEASE="repository-v4-test"
MAX_PAGES="${ARTIFACT_MAX_PAGES:-10}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --inventory) INVENTORY="${2:-}"; shift 2 ;;
    --history-out) HISTORY_OUT="${2:-}"; shift 2 ;;
    --summary) SUMMARY="${2:-}"; shift 2 ;;
    --prod-release) PROD_RELEASE="${2:-}"; shift 2 ;;
    --staging-release) STAGING_RELEASE="${2:-}"; shift 2 ;;
    --max-pages) MAX_PAGES="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$REPO" && "$REPO" == */* ]] || { echo "::error::--repo owner/repo is required" >&2; exit 2; }
[[ -n "$RUN_ID" ]] || { echo "::error::--run-id is required (recursion guard)" >&2; exit 2; }
[[ -n "$OUT" ]] || { echo "::error::--out is required" >&2; exit 2; }
for t in gh jq unzip; do
  command -v "$t" >/dev/null 2>&1 \
    || { echo "::error::$t required (install it before collecting artifacts)" >&2; exit 2; }
done

mkdir -p "$OUT"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# read-only REST helpers (GET only)
# ---------------------------------------------------------------------------
api_get() { # <path> -> body on stdout; nonzero on failure
  gh api -H "Accept: application/vnd.github+json" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. enumerate the repository's artifacts (paginated)
# ---------------------------------------------------------------------------
ARTIFACTS_FILE="$(mktemp)"
PAGES_FILE="$(mktemp)"
trap 'rm -f "$ARTIFACTS_FILE" "$PAGES_FILE" "$PAGES_FILE.parts"' EXIT
page=1
while (( page <= MAX_PAGES )); do
  if ! api_get "repos/$REPO/actions/artifacts?per_page=100&page=$page" > "$PAGES_FILE"; then
    echo "::error::artifact discovery failed (HTTP error on page $page); refusing to build a dashboard from unknown sources" >&2
    exit 1
  fi
  jq -e 'has("artifacts")' "$PAGES_FILE" >/dev/null 2>&1 || {
    echo "::error::artifact discovery returned an unexpected payload (page $page)" >&2
    exit 1
  }
  n="$(jq '.artifacts | length' "$PAGES_FILE")"
  jq -c '.artifacts' "$PAGES_FILE" >> "$PAGES_FILE.parts"
  (( n < 100 )) && break
  page=$(( page + 1 ))
done
jq -s 'add' "$PAGES_FILE.parts" > "$ARTIFACTS_FILE" 2>/dev/null \
  || printf '[]\n' > "$ARTIFACTS_FILE"
TOTAL="$(jq 'length' "$ARTIFACTS_FILE")"

# newest first (the API is already ordered; sort defensively)
CANDIDATES="$(jq -r '
  map(select(.id != null and .name != null))
  | map({id: (.id|tostring), name, run: ((.workflow_run.id // "")|tostring),
         expired: (.expired // false), created: (.created_at // ""),
         expires: (.expires_at // "")})
  | sort_by(.created) | reverse | .[]
  | [.id, .name, .run, .expired, .created, .expires] | @tsv' "$ARTIFACTS_FILE")"

declare -A RUN_CACHE=()
run_json() { # <run_id> -> run JSON (empty when unresolvable)
  local id="$1"
  if [[ -n "${RUN_CACHE[$id]:-}" ]]; then printf '%s' "${RUN_CACHE[$id]}"; return 0; fi
  local body=""
  body="$(api_get "repos/$REPO/actions/runs/$id")" || body=""
  if [[ -n "$body" ]] && ! jq -e 'has("id")' >/dev/null 2>&1 <<<"$body"; then body=""; fi
  RUN_CACHE["$id"]="$body"
  printf '%s' "$body"
}

# ---------------------------------------------------------------------------
# 2/3/4. candidate selection per slot
#
# A candidate is eligible only when: not the current run, not expired, and
# its owning run is completed + successful (and, for the history slot, the
# owning workflow IS this workflow). Every rejected candidate is recorded
# so the dashboard can tell "no artifact exists" apart from "the newest
# source run failed" or "the artifact expired".
# ---------------------------------------------------------------------------
REJECTED="[]"
# Status of the newest REJECTED candidate of the slot currently being
# materialized: an artifact that could not be used must be explained, never
# silently absent. The current run's own artifacts are excluded from
# ingestion entirely (recursion guard), so they never become the status.
FALLBACK=""
note_fallback() { # <reason>
  [[ -n "$FALLBACK" ]] && return 0
  [[ "$1" == "self_run" ]] && return 0
  FALLBACK="$1"
}
record_rejection() { # <slot> <name> <artifact_id> <run_id> <reason>
  REJECTED="$(jq -n -c --argjson r "$REJECTED" --arg slot "$1" --arg name "$2" \
    --arg aid "$3" --arg run "$4" --arg reason "$5" \
    '$r + [{slot:$slot, artifact:$name, artifact_id:$aid, run_id:$run, reason:$reason}]' <<<"$REJECTED")"
}

# Candidate eligibility is evaluated inline by materialize() below (in the
# current shell) so that every rejection is recorded and every per-slot
# state persists. A candidate is eligible only when it is not the current
# run, not expired, and its owning run is completed + successful.

# ---------------------------------------------------------------------------
# 5. download into a per-slot directory (artifact filenames collide)
# ---------------------------------------------------------------------------
download_artifact() { # <slot> <artifact_id> -> directory on stdout
  local slot="$1" aid="$2" dir zip
  dir="$OUT/$slot"; zip="$OUT/$slot/.artifact.zip"
  rm -rf "$dir"; mkdir -p "$dir"
  api_get "repos/$REPO/actions/artifacts/$aid/zip" > "$zip" 2>/dev/null || { rm -f "$zip"; return 1; }
  [[ -s "$zip" ]] || { rm -f "$zip"; return 1; }
  unzip -o -q "$zip" -d "$dir" >/dev/null 2>&1 || { rm -f "$zip"; return 1; }
  rm -f "$zip"
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# 6. schema validation (malformed data is rejected, never "healthy")
# ---------------------------------------------------------------------------
LIFECYCLE_STATES='"UP_TO_DATE","UPDATE_AVAILABLE","SOURCE_CHANGED","REBUILD_REQUIRED","MANUAL_REVIEW","CHECK_FAILED","UPSTREAM_UNAVAILABLE","UPSTREAM_ARCHIVED","UNKNOWN"'

validate_health() { # <file> <expected_release_tag> -> error (empty = valid)
  local f="$1" tag="$2" actual_rel state ts
  [[ -s "$f" ]] || { printf 'empty report file'; return 0; }
  jq -e . "$f" >/dev/null 2>&1 || { printf 'invalid JSON'; return 0; }
  actual_rel="$(jq -r '.release_tag // ""' "$f")"
  state="$(jq -r '.overall_status // ""' "$f")"
  ts="$(jq -r '.timestamp // ""' "$f")"
  [[ -n "$actual_rel" ]] || { printf 'missing release_tag'; return 0; }
  [[ "$actual_rel" == "$tag" ]] || { printf 'release_tag mismatch (%s != %s)' "$actual_rel" "$tag"; return 0; }
  [[ -n "$ts" ]] || { printf 'missing timestamp'; return 0; }
  case "$state" in
    HEALTHY|DEGRADED|FAILED) ;;
    *) printf 'unknown overall_status (%s)' "$state"; return 0 ;;
  esac
  printf ''
}

validate_lifecycle() { # <file> -> error (empty = valid)
  local f="$1"
  [[ -s "$f" ]] || { printf 'empty report file'; return 0; }
  jq -e . "$f" >/dev/null 2>&1 || { printf 'invalid JSON'; return 0; }
  jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <"$f" \
    || { printf 'report is not a non-empty array'; return 0; }
  jq -e --argjson ok "[$LIFECYCLE_STATES]" '
      all(.[];
        (.package | type == "string" and length > 0)
        and (.update_type | type == "string" and length > 0)
        and ((.update_type as $t | $ok | index($t)) != null))' >/dev/null 2>&1 <"$f" \
    || { printf 'malformed package rows (missing package/update_type or unknown lifecycle state)'; return 0; }
  printf ''
}

validate_history() { # <file> -> error (empty = valid)
  local f="$1"
  [[ -s "$f" ]] || { printf 'empty history file'; return 0; }
  jq -e -R -s 'split("\n") | map(select(length > 0)) | length > 0
      and all(.[]; (fromjson?) as $o | ($o | type) == "object" and ($o.generated_at != null))' \
    >/dev/null 2>&1 <"$f" \
    || { printf 'malformed history (unparsable line or missing generated_at)'; return 0; }
  printf ''
}

# ---------------------------------------------------------------------------
# slot definitions + selection + materialisation
# ---------------------------------------------------------------------------
declare -A S_STATUS=() S_REASON=() S_ARTIFACT=() S_ARTIFACT_ID=() S_RUN=()
declare -A S_CONCLUSION=() S_CREATED=() S_EXPIRES=() S_FILE=() S_STATE=() S_TS=()

CORE_SLOTS=(health_production health_staging lifecycle)
OPTIONAL_SLOTS=(publish ci history)

materialize() { # <slot> <glob> [required_workflow_path]
  local slot="$1" glob="$2" want="${3:-}"
  local id name run expired created expires body dir f err rel
  local found=0
  FALLBACK=""
  while IFS=$'\t' read -r id name run expired created expires; do
    [[ -n "$id" ]] || continue
    # shellcheck disable=SC2254 # artifact-name glob, intended
    case "$name" in $glob) ;; *) continue ;; esac
    if [[ "$run" == "$RUN_ID" ]]; then
      record_rejection "$slot" "$name" "$id" "$run" "current_run_ignored"
      continue
    fi
    if [[ "$expired" == "true" || ( -n "$expires" && "$expires" < "$NOW" ) ]]; then
      record_rejection "$slot" "$name" "$id" "$run" "expired"
      note_fallback "expired"
      continue
    fi
    body="$(run_json "$run")"
    if [[ -z "$body" ]]; then
      record_rejection "$slot" "$name" "$id" "$run" "source_run_unknown"
      note_fallback "source_run_unknown"
      continue
    fi
    if [[ -n "$want" && "$(jq -r '.path // ""' <<<"$body")" != "$want" ]]; then
      record_rejection "$slot" "$name" "$id" "$run" "wrong_workflow"
      continue
    fi
    if [[ "$(jq -r '.status // ""' <<<"$body")" != "completed" ]]; then
      record_rejection "$slot" "$name" "$id" "$run" "source_run_incomplete"
      note_fallback "source_run_incomplete"
      continue
    fi
    if [[ "$(jq -r '.conclusion // ""' <<<"$body")" != "success" ]]; then
      record_rejection "$slot" "$name" "$id" "$run" "source_run_failed"
      note_fallback "source_run_failed"
      continue
    fi

    if ! dir="$(download_artifact "$slot" "$id")"; then
      record_rejection "$slot" "$name" "$id" "$run" "download_failed"
      note_fallback "download_failed"
      continue
    fi
    case "$slot" in
      health_production) rel="$PROD_RELEASE" ;;
      health_staging) rel="$STAGING_RELEASE" ;;
      *) rel="" ;;
    esac
    case "$slot" in
      health_production|health_staging)
        f="$dir/health-report.json"
        [[ -f "$f" ]] || f="$(find "$dir" -maxdepth 2 -type f -name 'health-report*.json' | head -1)"
        if [[ -z "$f" || ! -f "$f" ]]; then
          record_rejection "$slot" "$name" "$id" "$run" "invalid: no health-report*.json in artifact"
          note_fallback "invalid"
          continue
        fi
        err="$(validate_health "$f" "$rel")"
        if [[ -n "$err" ]]; then
          record_rejection "$slot" "$name" "$id" "$run" "invalid: $err"
          note_fallback "invalid"
          continue
        fi
        S_FILE["$slot"]="$f"
        S_STATE["$slot"]="$(jq -r '.overall_status' "$f")"
        S_TS["$slot"]="$(jq -r '.timestamp' "$f")"
        ;;
      lifecycle)
        f="$dir/update-report.json"
        [[ -f "$f" ]] || f="$(find "$dir" -maxdepth 2 -type f -name 'update-report*.json' | head -1)"
        if [[ -z "$f" || ! -f "$f" ]]; then
          record_rejection "$slot" "$name" "$id" "$run" "invalid: no update-report.json in artifact"
          note_fallback "invalid"
          continue
        fi
        err="$(validate_lifecycle "$f")"
        if [[ -n "$err" ]]; then
          record_rejection "$slot" "$name" "$id" "$run" "invalid: $err"
          note_fallback "invalid"
          continue
        fi
        S_FILE["$slot"]="$f"
        S_TS["$slot"]="$(jq -r '[.[] | .checked_at // empty] | max // ""' "$f")"
        ;;
      history)
        f="$dir/metrics-history.jsonl"
        if [[ ! -f "$f" ]]; then
          record_rejection "$slot" "$name" "$id" "$run" "invalid: no metrics-history.jsonl in artifact"
          note_fallback "invalid"
          continue
        fi
        err="$(validate_history "$f")"
        if [[ -n "$err" ]]; then
          record_rejection "$slot" "$name" "$id" "$run" "invalid: $err"
          note_fallback "invalid"
          continue
        fi
        S_FILE["$slot"]="$f"
        S_TS["$slot"]="$(jq -r -R -s 'split("\n") | map(select(length>0)) | map(fromjson.generated_at) | max // ""' "$f")"
        ;;
      publish|ci)
        S_FILE["$slot"]="$dir"
        S_TS["$slot"]="$created"
        ;;
    esac
    S_STATUS["$slot"]="ok"; found=1
    S_ARTIFACT["$slot"]="$name"; S_ARTIFACT_ID["$slot"]="$id"; S_RUN["$slot"]="$run"
    S_CREATED["$slot"]="$created"; S_EXPIRES["$slot"]="$expires"
    S_CONCLUSION["$slot"]="$(jq -r '.conclusion // ""' <<<"$(run_json "$run")")"
    break
  done <<<"$CANDIDATES"
  if (( ! found )); then
    [[ -n "$FALLBACK" ]] || FALLBACK="not_found"
    S_STATUS["$slot"]="$FALLBACK"
    S_REASON["$slot"]="$(jq -r --arg slot "$slot" \
      '[.[] | select(.slot == $slot)][0].reason // ""' <<<"$REJECTED")"
  fi
  return 0
}

materialize health_production "health-report-$PROD_RELEASE"
materialize health_staging "health-report-$STAGING_RELEASE"
materialize lifecycle "update-report"
materialize publish "publish-summary-*"
materialize ci "run-metrics-*"
materialize history "metrics-snapshot" ".github/workflows/observability.yml"

# ---------------------------------------------------------------------------
# 7. history persistence: hand the previous history to the merge step
# ---------------------------------------------------------------------------
if [[ -n "$HISTORY_OUT" && "${S_STATUS[history]}" == "ok" ]]; then
  cp "${S_FILE[history]}" "$HISTORY_OUT"
fi

# ---------------------------------------------------------------------------
# completeness verdict + inventory document
# ---------------------------------------------------------------------------
core_ok=0
missing='[]'; unavailable='[]'; warnings='[]'
for slot in "${CORE_SLOTS[@]}"; do
  if [[ "${S_STATUS[$slot]:-not_found}" == "ok" ]]; then
    core_ok=$(( core_ok + 1 ))
  else
    missing="$(jq -n -c --argjson m "$missing" --arg s "$slot" '$m + [$s]')"
  fi
done
for slot in "${OPTIONAL_SLOTS[@]}"; do
  [[ "${S_STATUS[$slot]:-not_found}" == "ok" ]] && continue
  unavailable="$(jq -n -c --argjson u "$unavailable" --arg s "$slot" '$u + [$s]')"
done

if (( core_ok == ${#CORE_SLOTS[@]} )); then
  COMPLETENESS="COMPLETE"
elif (( core_ok > 0 )); then
  COMPLETENESS="PARTIAL"
else
  COMPLETENESS="NO_DATA"
fi

for slot in "${OPTIONAL_SLOTS[@]}"; do
  [[ "${S_STATUS[$slot]:-not_found}" == "ok" ]] && continue
  case "$slot" in
    publish) pattern="publish-summary-*" ;;
    ci) pattern="run-metrics-*" ;;
    history) pattern="metrics-snapshot from a previous observability run" ;;
    *) pattern="$slot" ;;
  esac
  warnings="$(jq -n -c --argjson w "$warnings" \
    --arg m "optional source '$slot' unavailable (status=${S_STATUS[$slot]:-not_found}; artifact pattern: $pattern)" \
    '$w + [$m]')"
done
for slot in "${CORE_SLOTS[@]}"; do
  [[ "${S_STATUS[$slot]:-not_found}" == "ok" ]] && continue
  warnings="$(jq -n -c --argjson w "$warnings" \
    --arg m "core source '$slot' unavailable (status=${S_STATUS[$slot]:-not_found}${S_REASON[$slot]:+; ${S_REASON[$slot]}})" \
    '$w + [$m]')"
done

slot_list_json() { printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length>0))'; }

inventory_sources='{}'
for slot in "${CORE_SLOTS[@]}" "${OPTIONAL_SLOTS[@]}"; do
  entry="$(jq -nc \
    --arg status "${S_STATUS[$slot]:-not_found}" \
    --arg artifact "${S_ARTIFACT[$slot]:-}" \
    --arg artifact_id "${S_ARTIFACT_ID[$slot]:-}" \
    --arg run_id "${S_RUN[$slot]:-}" \
    --arg run_conclusion "${S_CONCLUSION[$slot]:-}" \
    --arg created_at "${S_CREATED[$slot]:-}" \
    --arg expires_at "${S_EXPIRES[$slot]:-}" \
    --arg file "${S_FILE[$slot]:-}" \
    --arg state "${S_STATE[$slot]:-}" \
    --arg report_timestamp "${S_TS[$slot]:-}" \
    --arg reason "${S_REASON[$slot]:-}" \
    '{status:$status, artifact:$artifact, artifact_id:$artifact_id, run_id:$run_id,
      run_conclusion:$run_conclusion, created_at:$created_at, expires_at:$expires_at,
      file:$file, state:$state, report_timestamp:$report_timestamp, reason:$reason}')"
  inventory_sources="$(jq -n -c --argjson s "$inventory_sources" --arg k "$slot" --argjson v "$entry" '$s + {($k): $v}')"
done

INVENTORY_JSON="$(jq -nc \
  --arg schema "repo-artifact-inventory/v1" \
  --arg generated_at "$NOW" \
  --arg repository "$REPO" \
  --arg current_run_id "$RUN_ID" \
  --arg completeness "$COMPLETENESS" \
  --argjson core_sources "$(slot_list_json "${CORE_SLOTS[@]}")" \
  --argjson optional_sources "$(slot_list_json "${OPTIONAL_SLOTS[@]}")" \
  --argjson sources "$inventory_sources" \
  --argjson missing "$missing" \
  --argjson unavailable "$unavailable" \
  --argjson rejected "$REJECTED" \
  --argjson warnings "$warnings" \
  '{schema:$schema, generated_at:$generated_at, repository:$repository, current_run_id:$current_run_id,
    completeness:$completeness, core_sources:$core_sources, optional_sources:$optional_sources,
    sources:$sources, missing:$missing, unavailable:$unavailable, rejected:$rejected, warnings:$warnings}')"

if [[ -n "$INVENTORY" ]]; then
  printf '%s\n' "$INVENTORY_JSON" > "$INVENTORY"
else
  printf '%s\n' "$INVENTORY_JSON"
fi

# ---------------------------------------------------------------------------
# human-readable summary (always names the missing/unavailable sources)
# ---------------------------------------------------------------------------
if [[ -n "$SUMMARY" ]]; then
  {
    echo "## Source artifact retrieval (read-only REST API)"
    echo
    echo "- repository artifacts visible: $TOTAL"
    echo "- current run (excluded from ingestion): $RUN_ID"
    echo "- **completeness: $COMPLETENESS**"
    echo
    echo "| source | status | artifact | source run | conclusion | report timestamp | file |"
    echo "|---|---|---|---|---|---|---|"
    for slot in "${CORE_SLOTS[@]}" "${OPTIONAL_SLOTS[@]}"; do
      printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
        "$slot" "${S_STATUS[$slot]:-not_found}" "${S_ARTIFACT[$slot]:--}" \
        "${S_RUN[$slot]:--}" "${S_CONCLUSION[$slot]:--}" "${S_TS[$slot]:--}" "${S_FILE[$slot]:--}"
    done
    if [[ "$missing" != "[]" ]]; then
      echo
      echo "### missing core sources"
      jq -r '.[] | "- \(.)"' <<<"$missing"
    fi
    if [[ "$unavailable" != "[]" ]]; then
      echo
      echo "### unavailable optional sources"
      jq -r '.[] | "- \(.)"' <<<"$unavailable"
    fi
    if [[ "$REJECTED" != "[]" ]]; then
      echo
      echo "### rejected candidates (never used as sources)"
      jq -r '.[] | "- \(.slot): \(.artifact) (run \(.run_id)) rejected: \(.reason)"' <<<"$REJECTED"
    fi
  } >> "$SUMMARY"
fi

echo "[collect] artifacts=$TOTAL completeness=$COMPLETENESS missing=$missing optional_unavailable=$unavailable" >&2
exit 0
