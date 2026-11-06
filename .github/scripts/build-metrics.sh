#!/usr/bin/env bash
#
# Repository metrics snapshot builder (Phase 5.3.5). Read-only: it collects
# available observations from CI artifacts / reports produced by earlier
# stages and emits ONE bounded snapshot document. It never invents values:
# an unavailable metric is emitted as null and rendered as "N/A" by the
# dashboard.
#
# Sources (all optional; missing sources simply contribute nothing):
#   --health-dir <dir>     directory of health-report*.json (+ *.meta)
#   --publish-dir <dir>    directory of publish-summary*.json / *.txt
#   --lifecycle <file>     package lifecycle report (check-updates.sh)
#   --runs-dir <dir>       directory of workflow-run metrics JSON
#   --retention <n>        max history points kept per series (default 50)
#
# Output (stdout or --out): a metrics snapshot with a stable schema:
#   {
#     "schema": "repo-metrics/v1",
#     "generated_at": ISO8601,
#     "retention": N,
#     "kpis": {...},
#     "health_history": [ {timestamp, release, state} ],
#     "publish_history": [ {timestamp, release, unchanged, uploaded, replaced, failed, api_requests} ],
#     "build_durations": [ {timestamp, package, duration_seconds, cache} ],
#     "cache_history": [ {timestamp, run, hits, misses, hit_rate} ],
#     "packages": [ <lifecycle rows> ]
#   }
#
# Retention: each history array is sorted by timestamp and truncated to the
# newest `retention` points (bounded growth; the dashboard downsamples
# visually). Snapshots are plain JSON so they can be committed, uploaded as
# artifacts, or diffed.

set -euo pipefail

HEALTH_DIR=""
PUBLISH_DIR=""
LIFECYCLE=""
RUNS_DIR=""
RETENTION="${METRICS_RETENTION:-50}"
OUT=""
BUILD_PROFILE="${BUILD_PROFILE:-x86-64-v4}"
RELEASE_TAG="${RELEASE_TAG:-repository}"
NOW="${METRICS_NOW:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --health-dir) HEALTH_DIR="${2:-}"; shift 2 ;;
    --publish-dir) PUBLISH_DIR="${2:-}"; shift 2 ;;
    --lifecycle) LIFECYCLE="${2:-}"; shift 2 ;;
    --runs-dir) RUNS_DIR="${2:-}"; shift 2 ;;
    --retention) RETENTION="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

[[ -n "$NOW" ]] || NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# collect
# ---------------------------------------------------------------------------
health_rows="[]"
publish_rows="[]"
build_rows="[]"
cache_rows="[]"
packages="[]"

# -- health reports: prefer an explicit event sidecar (health-history.jsonl)
if [[ -n "$HEALTH_DIR" && -d "$HEALTH_DIR" ]]; then
  # sidecar lines: {"timestamp":...,"release":...,"state":...}
  if [[ -f "$HEALTH_DIR/health-history.jsonl" ]]; then
    health_rows=$(jq -s -c 'map(select(.state != null))' "$HEALTH_DIR/health-history.jsonl" 2>/dev/null || echo '[]')
  fi
  # individual reports (health-report*.json) also contribute one point each
  extra="[]"
  if shopt -s nullglob 2>/dev/null; then
    extra=$(for f in "$HEALTH_DIR"/health-report*.json; do
      jq -c --arg rel "$RELEASE_TAG" \
        '{timestamp:(.timestamp // null), release:$rel, state:(.overall_status // "UNKNOWN")}' "$f" 2>/dev/null || true
    done | jq -s -c 'map(select(.timestamp != null))' 2>/dev/null || echo '[]')
  fi
  health_rows=$(jq -nc --argjson a "$health_rows" --argjson b "$extra" '$a + $b' 2>/dev/null || echo "$health_rows")
fi

# -- publish summaries: sidecar lines with counters
if [[ -n "$PUBLISH_DIR" && -d "$PUBLISH_DIR" ]]; then
  if [[ -f "$PUBLISH_DIR/publish-history.jsonl" ]]; then
    publish_rows=$(jq -s -c 'map(select(.timestamp != null))' "$PUBLISH_DIR/publish-history.jsonl" 2>/dev/null || echo '[]')
  fi
fi

# -- build/cache metrics: sidecar lines
if [[ -n "$RUNS_DIR" && -d "$RUNS_DIR" ]]; then
  if [[ -f "$RUNS_DIR/build-durations.jsonl" ]]; then
    build_rows=$(jq -s -c 'map(select(.timestamp != null))' "$RUNS_DIR/build-durations.jsonl" 2>/dev/null || echo '[]')
  fi
  if [[ -f "$RUNS_DIR/cache-history.jsonl" ]]; then
    cache_rows=$(jq -s -c 'map(select(.timestamp != null))' "$RUNS_DIR/cache-history.jsonl" 2>/dev/null || echo '[]')
  fi
fi

# -- lifecycle packages
if [[ -n "$LIFECYCLE" && -f "$LIFECYCLE" ]]; then
  packages=$(jq -c 'if type=="array" then . else [] end' "$LIFECYCLE" 2>/dev/null || echo '[]')
fi

# ---------------------------------------------------------------------------
# retention (bounded): newest N points per series
# ---------------------------------------------------------------------------
health_rows=$(jq -c --argjson n "$RETENTION" 'sort_by(.timestamp) | if length > $n then .[length-$n:] else . end' <<<"$health_rows")
publish_rows=$(jq -c --argjson n "$RETENTION" 'sort_by(.timestamp) | if length > $n then .[length-$n:] else . end' <<<"$publish_rows")
build_rows=$(jq -c --argjson n "$RETENTION" 'sort_by(.timestamp) | if length > $n then .[length-$n:] else . end' <<<"$build_rows")
cache_rows=$(jq -c --argjson n "$RETENTION" 'sort_by(.timestamp) | if length > $n then .[length-$n:] else . end' <<<"$cache_rows")

# ---------------------------------------------------------------------------
# KPIs — every value derived or null (never fabricated)
# ---------------------------------------------------------------------------
total_packages=$(jq 'length' <<<"$packages")
up_to_date=$(jq '[.[] | select(.update_type == "UP_TO_DATE")] | length' <<<"$packages")
updates_available=$(jq '[.[] | select(.update_type == "UPDATE_AVAILABLE" or .update_type == "SOURCE_CHANGED" or .update_type == "REBUILD_REQUIRED")] | length' <<<"$packages")
build_failures=$(jq '[.[] | select(.update_type == "BUILD_FAILED" or .update_type == "VALIDATION_FAILED")] | length' <<<"$packages")

prod_health=$(jq -c '[.[] | select(.release == "repository")] | if length == 0 then null else (last | .state) end' <<<"$health_rows")
stage_health=$(jq -c '[.[] | select(.release == "repository-v4-test")] | if length == 0 then null else (last | .state) end' <<<"$health_rows")

# cache hit rate from the newest cache observation
cache_hit_rate=$(jq -c 'if length == 0 then null else (last | if (.hits + .misses) > 0 then (((.hits / (.hits + .misses)) * 1000 | round) / 10) else null end) end' <<<"$cache_rows")

# build success rate from build rows (cache == "HIT" counts as success)
build_total=$(jq 'length' <<<"$build_rows")
build_ok=$(jq '[.[] | select(.cache != "FAILED")] | length' <<<"$build_rows")
build_success_rate=$(jq -n --argjson ok "$build_ok" --argjson total "$build_total" \
  'if $total == 0 then null else ((($ok / $total) * 1000 | round) / 10) end')

avg_build_duration=$(jq -c 'if length == 0 then null else (((map(.duration_seconds // 0) | add) / length) * 10 | round) / 10 end' <<<"$build_rows")
publication_duration=$(jq -c 'if length == 0 then null else (last | .duration_seconds // null) end' <<<"$publish_rows")
api_requests=$(jq -c 'if length == 0 then null else (last | .api_requests // null) end' <<<"$publish_rows")
last_publish=$(jq -c 'if length == 0 then null else (last | .timestamp // null) end' <<<"$publish_rows")

kpis=$(jq -nc \
  --argjson total_packages "$total_packages" \
  --argjson up_to_date "$up_to_date" \
  --argjson updates_available "$updates_available" \
  --argjson build_failures "$build_failures" \
  --argjson production_health "$prod_health" \
  --argjson staging_health "$stage_health" \
  --argjson build_success_rate "$build_success_rate" \
  --argjson cache_hit_rate "$cache_hit_rate" \
  --argjson avg_build_duration "$avg_build_duration" \
  --argjson publication_duration "$publication_duration" \
  --argjson api_requests "$api_requests" \
  --argjson last_successful_publish "$last_publish" \
  --arg snapshot_at "$NOW" \
  --argjson packages_checked "$total_packages" \
  '{total_packages:$total_packages, up_to_date:$up_to_date, updates_available:$updates_available,
    build_failures:$build_failures, production_health:$production_health, staging_health:$staging_health,
    build_success_rate:$build_success_rate, cache_hit_rate:$cache_hit_rate,
    avg_build_duration:$avg_build_duration, publication_duration:$publication_duration,
    api_requests:$api_requests, last_successful_publish:$last_successful_publish,
    snapshot_at:$snapshot_at, packages_checked:$packages_checked}')

SNAPSHOT=$(jq -nc \
  --arg schema "repo-metrics/v1" \
  --arg generated_at "$NOW" \
  --argjson retention "$RETENTION" \
  --arg build_profile "$BUILD_PROFILE" \
  --argjson kpis "$kpis" \
  --argjson health_history "$health_rows" \
  --argjson publish_history "$publish_rows" \
  --argjson build_durations "$build_rows" \
  --argjson cache_history "$cache_rows" \
  --argjson packages "$packages" \
  '{schema:$schema, generated_at:$generated_at, retention:$retention, build_profile:$build_profile,
    kpis:$kpis, health_history:$health_history, publish_history:$publish_history,
    build_durations:$build_durations, cache_history:$cache_history, packages:$packages}')

if [[ -n "$OUT" ]]; then
  printf '%s\n' "$SNAPSHOT" > "$OUT"
  echo "[metrics] wrote $OUT (packages=$total_packages health=$(( $(jq 'length' <<<"$health_rows") )) publish=$(( $(jq 'length' <<<"$publish_rows") )))" >&2
else
  printf '%s\n' "$SNAPSHOT"
fi
