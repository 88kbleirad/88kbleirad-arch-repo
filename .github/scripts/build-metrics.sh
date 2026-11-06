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
#   --inventory <file>     source-artifact inventory (collect-artifacts.sh)
#   --retention <n>        max history points kept per series (default 50)
#
# Output (stdout or --out): a metrics snapshot with a stable schema:
#   {
#     "schema": "repo-metrics/v1",
#     "generated_at": ISO8601,
#     "retention": N,
#     "completeness": "COMPLETE|PARTIAL|NO_DATA" | null,
#     "inventory": { ... } | null,
#     "source_summary": {"health_production":{...}, ...},
#     "kpis": {...},
#     "health_history": [ {timestamp, release, state} ],
#     "publish_history": [ {timestamp, release, unchanged, uploaded, replaced, failed, api_requests} ],
#     "build_durations": [ {timestamp, package, duration_seconds, cache} ],
#     "cache_history": [ {timestamp, run, hits, misses, hit_rate} ],
#     "packages": [ <lifecycle rows> ]
#   }
#
# Source policy (Phase 5.4): the snapshot transparently records where each
# series came from. Missing sources yield null KPIs — never fabricated
# values. The `completeness` verdict is authoritative: NO_DATA means no
# verified core source (health production, health staging, lifecycle) was
# available, and the dashboard/report must present this as an incomplete
# state, not a populated observability dashboard.
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
INVENTORY=""
RETENTION="${METRICS_RETENTION:-50}"
OUT=""
BUILD_PROFILE="${BUILD_PROFILE:-x86-64-v4}"
RELEASE_TAG="${RELEASE_TAG:-repository}"
NOW="${METRICS_NOW:-}"
PACKAGES_FILE="${PACKAGES_FILE:-}"
PUBLISHED_COUNT="${PUBLISHED_COUNT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --health-dir) HEALTH_DIR="${2:-}"; shift 2 ;;
    --publish-dir) PUBLISH_DIR="${2:-}"; shift 2 ;;
    --lifecycle) LIFECYCLE="${2:-}"; shift 2 ;;
    --runs-dir) RUNS_DIR="${2:-}"; shift 2 ;;
    --inventory) INVENTORY="${2:-}"; shift 2 ;;
    --packages-file) PACKAGES_FILE="${2:-}"; shift 2 ;;
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

# ---------------------------------------------------------------------------
# source resolution: when an inventory (collect-artifacts.sh) is provided,
# only the inventory-blessed, schema-validated files are consumed — never
# an ad-hoc scan of the input directory. Without an inventory (offline
# tests), the legacy directory scans are used.
# ---------------------------------------------------------------------------
INVENTORY_JSON=""
INVENTORY_OK=0
if [[ -n "$INVENTORY" && -f "$INVENTORY" ]]; then
  if jq -e '.schema == "repo-artifact-inventory/v1"' "$INVENTORY" >/dev/null 2>&1; then
    INVENTORY_OK=1
    INVENTORY_JSON="$(cat "$INVENTORY")"
  else
    echo "::error::inventory file is invalid (expected repo-artifact-inventory/v1); refusing to build metrics from unknown sources" >&2
    exit 2
  fi
fi

src_for() { # <slot> -> prints the inventory-resolved "file|dir" (empty if not ok)
  [[ $INVENTORY_OK -eq 1 ]] || return 1
  local slot="$1" st f
  st="$(jq -r --arg s "$slot" '.sources[$s].status // ""' <<<"$INVENTORY_JSON")"
  [[ "$st" == "ok" ]] || return 1
  f="$(jq -r --arg s "$slot" '.sources[$s].file // ""' <<<"$INVENTORY_JSON")"
  [[ -n "$f" && -e "$f" ]] || return 1
  printf '%s' "$f"
}

health_rows="[]"
publish_rows="[]"
build_rows="[]"
cache_rows="[]"
packages="[]"
PUBLISHED_PACKAGES=""

if (( INVENTORY_OK )); then
  # -- health reports (production + staging, independently resolved) --------
  local_hp="" local_hs=""
  src_for health_production >/dev/null 2>&1 && local_hp="$(src_for health_production)" || true
  src_for health_staging >/dev/null 2>&1 && local_hs="$(src_for health_staging)" || true
  extra="[]"
  for f in "$local_hp" "$local_hs"; do
    [[ -n "$f" && -f "$f" ]] || continue
    extra="$(jq -n -c --argjson e "$extra" \
      --arg ts "$(jq -r '.timestamp // ""' "$f")" \
      --arg rel "$(jq -r '.release_tag // ""' "$f")" \
      --arg st "$(jq -r '.overall_status // "UNKNOWN"' "$f")" \
      '$e + [{timestamp:$ts, release:$rel, state:$st}]')"
  done
  health_rows="$extra"
  # published package count (production release inventory — distinct from the
  # configured/checked package count reported by the lifecycle report)
  if [[ -n "$local_hp" ]]; then
    PUBLISHED_PACKAGES="$(jq -r '.package_count // ""' "$local_hp")"
  fi

  # -- publish / build / cache sidecars from the collector's slot dirs ------
  local_pub="" local_ci=""
  src_for publish >/dev/null 2>&1 && local_pub="$(src_for publish)" || true
  src_for ci >/dev/null 2>&1 && local_ci="$(src_for ci)" || true
  if [[ -n "$local_pub" && -f "$local_pub/publish-history.jsonl" ]]; then
    publish_rows="$(jq -s -c 'map(select(.timestamp != null))' "$local_pub/publish-history.jsonl" 2>/dev/null || echo '[]')"
  fi
  if [[ -n "$local_ci" ]]; then
    if [[ -f "$local_ci/build-durations.jsonl" ]]; then
      build_rows="$(jq -s -c 'map(select(.timestamp != null))' "$local_ci/build-durations.jsonl" 2>/dev/null || echo '[]')"
    fi
    if [[ -f "$local_ci/cache-history.jsonl" ]]; then
      cache_rows="$(jq -s -c 'map(select(.timestamp != null))' "$local_ci/cache-history.jsonl" 2>/dev/null || echo '[]')"
    fi
  fi

  # -- lifecycle report (inventory-blessed) ---------------------------------
  local_lc=""
  src_for lifecycle >/dev/null 2>&1 && local_lc="$(src_for lifecycle)" || true
  if [[ -n "$local_lc" ]]; then
    packages="$(jq -c 'if type=="array" then . else [] end' "$local_lc" 2>/dev/null || echo '[]')"
  fi
else
  # -- legacy directory scans (offline tests; health tag from the report) ---
  if [[ -n "$HEALTH_DIR" && -d "$HEALTH_DIR" ]]; then
    if [[ -f "$HEALTH_DIR/health-history.jsonl" ]]; then
      health_rows=$(jq -s -c 'map(select(.state != null))' "$HEALTH_DIR/health-history.jsonl" 2>/dev/null || echo '[]')
    fi
    extra="[]"
    if shopt -s nullglob 2>/dev/null; then
      extra=$(for f in "$HEALTH_DIR"/health-report*.json; do
        jq -c --arg rel "$(jq -r '.release_tag // empty' "$f" 2>/dev/null)" \
          '{timestamp:(.timestamp // null), release:$rel, state:(.overall_status // "UNKNOWN")}' "$f" 2>/dev/null || true
      done | jq -s -c 'map(select(.timestamp != null))' 2>/dev/null || echo '[]')
    fi
    health_rows=$(jq -nc --argjson a "$health_rows" --argjson b "$extra" '$a + $b' 2>/dev/null || echo "$health_rows")
  fi
  if [[ -n "$PUBLISH_DIR" && -d "$PUBLISH_DIR" ]]; then
    if [[ -f "$PUBLISH_DIR/publish-history.jsonl" ]]; then
      publish_rows=$(jq -s -c 'map(select(.timestamp != null))' "$PUBLISH_DIR/publish-history.jsonl" 2>/dev/null || echo '[]')
    fi
  fi
  if [[ -n "$RUNS_DIR" && -d "$RUNS_DIR" ]]; then
    if [[ -f "$RUNS_DIR/build-durations.jsonl" ]]; then
      build_rows=$(jq -s -c 'map(select(.timestamp != null))' "$RUNS_DIR/build-durations.jsonl" 2>/dev/null || echo '[]')
    fi
    if [[ -f "$RUNS_DIR/cache-history.jsonl" ]]; then
      cache_rows=$(jq -s -c 'map(select(.timestamp != null))' "$RUNS_DIR/cache-history.jsonl" 2>/dev/null || echo '[]')
    fi
  fi
  if [[ -n "$LIFECYCLE" && -f "$LIFECYCLE" ]]; then
    packages=$(jq -c 'if type=="array" then . else [] end' "$LIFECYCLE" 2>/dev/null || echo '[]')
  fi
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
# only a schema-validated state may drive a health KPI: an unknown state is
# dropped (never silently reported as HEALTHY)
health_rows=$(jq -c '[.[] | select(.state == "HEALTHY" or .state == "DEGRADED" or .state == "FAILED")]' <<<"$health_rows")

# Strict lifecycle KPI mapping — every state is a mutually exclusive count.
# Archived/unavailable upstreams are NOT probe failures; source changes are
# NOT confirmed updates. Unknown statuses are never dropped: they surface
# through `lifecycle_unknown` and the completeness/inventory machinery.
total_packages=$(jq 'length' <<<"$packages")
up_to_date=$(jq '[.[] | select(.update_type == "UP_TO_DATE")] | length' <<<"$packages")
updates_available=$(jq '[.[] | select(.update_type == "UPDATE_AVAILABLE")] | length' <<<"$packages")
source_changes=$(jq '[.[] | select(.update_type == "SOURCE_CHANGED")] | length' <<<"$packages")
manual_review=$(jq '[.[] | select(.update_type == "MANUAL_REVIEW")] | length' <<<"$packages")
check_failed=$(jq '[.[] | select(.update_type == "CHECK_FAILED")] | length' <<<"$packages")
upstream_unavailable=$(jq '[.[] | select(.update_type == "UPSTREAM_UNAVAILABLE")] | length' <<<"$packages")
upstream_archived=$(jq '[.[] | select(.update_type == "UPSTREAM_ARCHIVED")] | length' <<<"$packages")
rebuild_required=$(jq '[.[] | select(.update_type == "REBUILD_REQUIRED")] | length' <<<"$packages")
lifecycle_unknown=$(jq '[.[] | select(.update_type != "UP_TO_DATE" and .update_type != "UPDATE_AVAILABLE" and .update_type != "SOURCE_CHANGED" and .update_type != "REBUILD_REQUIRED" and .update_type != "MANUAL_REVIEW" and .update_type != "CHECK_FAILED" and .update_type != "UPSTREAM_UNAVAILABLE" and .update_type != "UPSTREAM_ARCHIVED")] | length' <<<"$packages")
# build failures come from verified CI run metrics; when no CI source is
# available the KPI is null (N/A), never a fabricated zero
build_failures=$(jq -c 'if length == 0 then null else ([.[] | select(.cache == "FAILED")] | length) end' <<<"$build_rows")

# configured inventory comes from the canonical packages.txt count; the
# published inventory from the verified production health report / release
# inventory. They are deliberately DIFFERENT numbers: configured may exceed
# published (the production release carries an operator-chosen subset).
packages_configured=""
if [[ -n "$PACKAGES_FILE" && -f "$PACKAGES_FILE" ]]; then
  packages_configured="$(awk 'NF && $0 !~ /^[[:space:]]*#/' "$PACKAGES_FILE" | wc -l | tr -d ' ')"
fi
[[ -n "$packages_configured" ]] || packages_configured="$total_packages"
packages_published=""
if [[ -n "$PUBLISHED_COUNT" ]]; then
  packages_published="$PUBLISHED_COUNT"
elif [[ -n "$PUBLISHED_PACKAGES" ]]; then
  packages_published="$PUBLISHED_PACKAGES"
fi
[[ "$packages_published" =~ ^[0-9]+$ ]] || packages_published="null"

prod_health=$(jq -c '[.[] | select(.release == "repository")] | if length == 0 then null else (last | .state) end' <<<"$health_rows")
stage_health=$(jq -c '[.[] | select(.release == "repository-v4-test")] | if length == 0 then null else (last | .state) end' <<<"$health_rows")
prod_health_at=$(jq -c '[.[] | select(.release == "repository")] | if length == 0 then null else (last | .timestamp) end' <<<"$health_rows")
stage_health_at=$(jq -c '[.[] | select(.release == "repository-v4-test")] | if length == 0 then null else (last | .timestamp) end' <<<"$health_rows")

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
  --argjson source_changes "$source_changes" \
  --argjson manual_review "$manual_review" \
  --argjson check_failed "$check_failed" \
  --argjson upstream_unavailable "$upstream_unavailable" \
  --argjson upstream_archived "$upstream_archived" \
  --argjson rebuild_required "$rebuild_required" \
  --argjson lifecycle_unknown "$lifecycle_unknown" \
  --argjson build_failures "$build_failures" \
  --argjson production_health "$prod_health" \
  --argjson staging_health "$stage_health" \
  --argjson production_health_at "$prod_health_at" \
  --argjson staging_health_at "$stage_health_at" \
  --argjson build_success_rate "$build_success_rate" \
  --argjson cache_hit_rate "$cache_hit_rate" \
  --argjson avg_build_duration "$avg_build_duration" \
  --argjson publication_duration "$publication_duration" \
  --argjson api_requests "$api_requests" \
  --argjson last_successful_publish "$last_publish" \
  --arg snapshot_at "$NOW" \
  --argjson packages_checked "$total_packages" \
  --argjson packages_configured "$packages_configured" \
  --argjson packages_published "$packages_published" \
  '{total_packages:$total_packages, up_to_date:$up_to_date, updates_available:$updates_available,
    source_changes:$source_changes, manual_review:$manual_review, check_failed:$check_failed,
    upstream_unavailable:$upstream_unavailable, upstream_archived:$upstream_archived,
    rebuild_required:$rebuild_required, lifecycle_unknown:$lifecycle_unknown,
    build_failures:$build_failures, production_health:$production_health, staging_health:$staging_health,
    production_health_at:$production_health_at, staging_health_at:$staging_health_at,
    build_success_rate:$build_success_rate, cache_hit_rate:$cache_hit_rate,
    avg_build_duration:$avg_build_duration, publication_duration:$publication_duration,
    api_requests:$api_requests, last_successful_publish:$last_successful_publish,
    snapshot_at:$snapshot_at, packages_checked:$packages_checked,
    packages_configured:$packages_configured, packages_published:$packages_published}')

# ---------------------------------------------------------------------------
# completeness verdict + source summary
# ---------------------------------------------------------------------------
COMPLETENESS="null"
SOURCE_SUMMARY="null"
if (( INVENTORY_OK )); then
  COMPLETENESS="$(jq -r '.completeness // ""' <<<"$INVENTORY_JSON")"
  [[ "$COMPLETENESS" =~ ^(COMPLETE|PARTIAL|NO_DATA)$ ]] || COMPLETENESS="null"
  # summarize each known slot; the snapshot carries the raw inventory
  # (sources/rejected/warnings) so consumers can render the incomplete state
  SOURCE_SUMMARY="$(jq -c '{completeness, sources, missing, unavailable, rejected, warnings}' <<<"$INVENTORY_JSON")"
fi

SNAPSHOT=$(jq -nc \
  --arg schema "repo-metrics/v1" \
  --arg generated_at "$NOW" \
  --argjson retention "$RETENTION" \
  --arg build_profile "$BUILD_PROFILE" \
  --arg completeness "$COMPLETENESS" \
  --argjson source_summary "$SOURCE_SUMMARY" \
  --argjson kpis "$kpis" \
  --argjson health_history "$health_rows" \
  --argjson publish_history "$publish_rows" \
  --argjson build_durations "$build_rows" \
  --argjson cache_history "$cache_rows" \
  --argjson packages "$packages" \
  '{schema:$schema, generated_at:$generated_at, retention:$retention, build_profile:$build_profile,
    completeness:$completeness, source_summary:$source_summary,
    kpis:$kpis, health_history:$health_history, publish_history:$publish_history,
    build_durations:$build_durations, cache_history:$cache_history, packages:$packages}')

if [[ -n "$OUT" ]]; then
  printf '%s\n' "$SNAPSHOT" > "$OUT"
  echo "[metrics] wrote $OUT (packages=$total_packages health=$(( $(jq 'length' <<<"$health_rows") )) publish=$(( $(jq 'length' <<<"$publish_rows") )) completeness=${COMPLETENESS:-null})" >&2
else
  printf '%s\n' "$SNAPSHOT"
fi
