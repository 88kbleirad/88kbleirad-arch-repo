#!/usr/bin/env bash
#
# Phase 5.3.5 metrics snapshot builder tests:
#   - schema stable, KPIs derived (never invented)
#   - retention bounded (newest N kept)
#   - missing sources => null KPIs (N/A), not fabricated
#   - read-only: never mutates inputs
set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

BUILD="$REPO_ROOT/.github/scripts/build-metrics.sh"

# -- fixtures -----------------------------------------------------------------
mkdir -p "$WORKDIR/health" "$WORKDIR/publish" "$WORKDIR/runs"
cat > "$WORKDIR/health/health-history.jsonl" <<'JSONL'
{"timestamp":"2026-11-04T10:00:00Z","release":"repository","state":"HEALTHY"}
{"timestamp":"2026-11-05T10:00:00Z","release":"repository","state":"DEGRADED"}
{"timestamp":"2026-11-05T10:05:00Z","release":"repository","state":"HEALTHY"}
{"timestamp":"2026-11-05T10:10:00Z","release":"repository-v4-test","state":"HEALTHY"}
JSONL
cat > "$WORKDIR/publish/publish-history.jsonl" <<'JSONL'
{"timestamp":"2026-11-05T10:00:00Z","release":"repository","unchanged":44,"uploaded":0,"replaced":0,"failed":0,"api_requests":4,"duration_seconds":3.2}
JSONL
cat > "$WORKDIR/runs/build-durations.jsonl" <<'JSONL'
{"timestamp":"2026-11-05T09:00:00Z","package":"beautyline","duration_seconds":30,"cache":"HIT"}
{"timestamp":"2026-11-05T09:05:00Z","package":"nmtui-go","duration_seconds":45,"cache":"MISS"}
JSONL
cat > "$WORKDIR/runs/cache-history.jsonl" <<'JSONL'
{"timestamp":"2026-11-05T09:00:00Z","run":"r1","hits":1,"misses":1,"hit_rate":50}
JSONL
cat > "$WORKDIR/lifecycle.json" <<'JSON'
[
  {"package":"beautyline","update_type":"UP_TO_DATE","current_version":"3.0.5","current_epoch":"2","current_release":"2","upstream_version":"3.0.5","upstream_url":"https://x","package_type":"stable","source_kind":"gitlab","source_reference":"","rebuild_required":false,"risk_level":"low","recommended_action":"none","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":""},
  {"package":"nmtui-go","update_type":"UPDATE_AVAILABLE","current_version":"0.2.7","current_epoch":"","current_release":"1","upstream_version":"0.3.0","upstream_url":"https://x","package_type":"stable","source_kind":"github","source_reference":"v0.3.0","rebuild_required":true,"risk_level":"medium","recommended_action":"review PR proposal","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":""}
]
JSON

# ---------------------------------------------------------------------------
note "metrics: full pipeline produces derived, consistent KPIs"
bash "$BUILD" \
  --health-dir "$WORKDIR/health" \
  --publish-dir "$WORKDIR/publish" \
  --runs-dir "$WORKDIR/runs" \
  --lifecycle "$WORKDIR/lifecycle.json" \
  --retention 50 --out "$WORKDIR/snapshot.json" > /dev/null 2>&1
if jq -e '.schema == "repo-metrics/v1" and .generated_at != null' \
    "$WORKDIR/snapshot.json" >/dev/null 2>&1; then
  ok "schema + generated_at present"
else
  bad "schema missing: $(head -c 120 "$WORKDIR/snapshot.json")"
fi
if jq -e '.kpis.total_packages == 2 and .kpis.up_to_date == 1 and .kpis.updates_available == 1' \
    "$WORKDIR/snapshot.json" >/dev/null 2>&1; then
  ok "total/up-to-date/updates KPIs derived from lifecycle"
else
  bad "KPI derivation wrong: $(jq -c '.kpis' "$WORKDIR/snapshot.json")"
fi
if jq -e '.kpis.build_failures == 0' "$WORKDIR/snapshot.json" >/dev/null 2>&1; then
  ok "build_failures is a verified zero when CI rows exist"
else
  bad "build_failures should be 0 with verified CI rows: $(jq -c '.kpis.build_failures' "$WORKDIR/snapshot.json")"
fi
if jq -e '.kpis.production_health == "HEALTHY" and .kpis.staging_health == "HEALTHY"' \
    "$WORKDIR/snapshot.json" >/dev/null 2>&1; then
  ok "health KPIs from newest observation per release"
else
  bad "health KPIs wrong: $(jq -c '.kpis | {p:.production_health,s:.staging_health}' "$WORKDIR/snapshot.json")"
fi
if jq -e '.kpis.cache_hit_rate == 50 and .kpis.build_success_rate == 100 and .kpis.avg_build_duration == 37.5' \
    "$WORKDIR/snapshot.json" >/dev/null 2>&1; then
  ok "cache/build KPIs derived"
else
  bad "cache/build KPIs wrong: $(jq -c '.kpis | {c:.cache_hit_rate,b:.build_success_rate,a:.avg_build_duration}' "$WORKDIR/snapshot.json")"
fi
if jq -e '.kpis.api_requests == 4 and .kpis.publication_duration == 3.2' \
    "$WORKDIR/snapshot.json" >/dev/null 2>&1; then
  ok "publish KPIs derived"
else
  bad "publish KPIs wrong: $(jq -c '.kpis | {a:.api_requests,d:.publication_duration}' "$WORKDIR/snapshot.json")"
fi
if jq -e '(.health_history | length) == 4 and (.publish_history | length) == 1 and (.packages | length) == 2 and (.build_durations | length) == 2 and (.cache_history | length) == 1' \
    "$WORKDIR/snapshot.json" >/dev/null 2>&1; then
  ok "history series populated"
else
  bad "history series wrong: $(jq -c '{h:(.health_history|length),p:(.publish_history|length),g:(.packages|length),b:(.build_durations|length),c:(.cache_history|length)}' "$WORKDIR/snapshot.json")"
fi

# ---------------------------------------------------------------------------
note "metrics: retention truncates to newest N"
for i in $(seq 1 12); do
  printf '{"timestamp":"2026-11-%02dT00:00:00Z","release":"repository","state":"HEALTHY"}\n' $((i)) \
    >> "$WORKDIR/health/health-history.jsonl"
done
bash "$BUILD" \
  --health-dir "$WORKDIR/health" \
  --retention 5 --out "$WORKDIR/snapshot2.json" > /dev/null 2>&1
N=$(jq '.health_history | length' "$WORKDIR/snapshot2.json")
if [[ "$N" -eq 5 ]]; then
  ok "retention bounded to 5"
else
  bad "retention not bounded (got $N)"
fi
if jq -e '.health_history[0].timestamp >= "2026-11-08"' "$WORKDIR/snapshot2.json" >/dev/null 2>&1; then
  ok "retention keeps newest points"
else
  bad "retention kept stale points: $(jq -c '.health_history[0]' "$WORKDIR/snapshot2.json")"
fi

# ---------------------------------------------------------------------------
note "metrics: missing sources yield null KPIs, never fabricated"
bash "$BUILD" --out "$WORKDIR/snapshot3.json" > /dev/null 2>&1
if jq -e '.kpis.total_packages == 0 and .kpis.production_health == null and .kpis.cache_hit_rate == null' \
    "$WORKDIR/snapshot3.json" >/dev/null 2>&1; then
  ok "no-source snapshot has null KPIs"
else
  bad "no-source KPIs fabricated: $(jq -c '.kpis' "$WORKDIR/snapshot3.json")"
fi
if jq -e '.kpis.build_failures == null and .kpis.build_success_rate == null' \
    "$WORKDIR/snapshot3.json" >/dev/null 2>&1; then
  ok "build KPIs are null (not zero) when no CI source exists"
else
  bad "build KPIs fabricated from absent CI: $(jq -c '.kpis | {f:.build_failures,s:.build_success_rate}' "$WORKDIR/snapshot3.json")"
fi

# ---------------------------------------------------------------------------
note "metrics: strict lifecycle KPI mapping (mutually exclusive states)"
# one record per lifecycle state — every KPI must count exactly its own state
cat > "$WORKDIR/all-states.json" <<'JSON'
[
  {"package":"p1","update_type":"UP_TO_DATE","checked_at":"2026-11-06T00:00:00Z","note":""},
  {"package":"p2","update_type":"UPDATE_AVAILABLE","checked_at":"2026-11-06T00:00:00Z","note":""},
  {"package":"p3","update_type":"SOURCE_CHANGED","checked_at":"2026-11-06T00:00:00Z","note":""},
  {"package":"p4","update_type":"MANUAL_REVIEW","checked_at":"2026-11-06T00:00:00Z","note":""},
  {"package":"p5","update_type":"CHECK_FAILED","checked_at":"2026-11-06T00:00:00Z","note":""},
  {"package":"p6","update_type":"UPSTREAM_UNAVAILABLE","checked_at":"2026-11-06T00:00:00Z","note":""},
  {"package":"p7","update_type":"UPSTREAM_ARCHIVED","checked_at":"2026-11-06T00:00:00Z","note":""},
  {"package":"p8","update_type":"REBUILD_REQUIRED","checked_at":"2026-11-06T00:00:00Z","note":""},
  {"package":"p9","update_type":"UNKNOWN","checked_at":"2026-11-06T00:00:00Z","note":""}
]
JSON
bash "$BUILD" --lifecycle "$WORKDIR/all-states.json" --out "$WORKDIR/snapshot-states.json" > /dev/null 2>&1
if jq -e '.kpis.up_to_date == 1 and .kpis.updates_available == 1 and .kpis.source_changes == 1
          and .kpis.manual_review == 1 and .kpis.check_failed == 1
          and .kpis.upstream_unavailable == 1 and .kpis.upstream_archived == 1' \
    "$WORKDIR/snapshot-states.json" >/dev/null 2>&1; then
  ok "every lifecycle state maps to its own KPI"
else
  bad "state mapping wrong: $(jq -c '.kpis' "$WORKDIR/snapshot-states.json")"
fi
# CHECK_FAILED must NOT count upstream unavailable/archived
if jq -e '.kpis.check_failed == 1 and .kpis.upstream_unavailable == 1 and .kpis.upstream_archived == 1' \
    "$WORKDIR/snapshot-states.json" >/dev/null 2>&1; then
  ok "check_failed excludes upstream unavailable/archived"
else
  bad "conflation still present: $(jq -c '.kpis | {c:.check_failed,u:.upstream_unavailable,a:.upstream_archived}' "$WORKDIR/snapshot-states.json")"
fi
# unknown statuses are preserved, never silently dropped
if jq -e '.kpis.lifecycle_unknown == 1 and .kpis.total_packages == 9' \
    "$WORKDIR/snapshot-states.json" >/dev/null 2>&1; then
  ok "unknown lifecycle status preserved (lifecycle_unknown=1)"
else
  bad "unknown status dropped: $(jq -c '.kpis' "$WORKDIR/snapshot-states.json")"
fi
# sum of mutually exclusive lifecycle KPIs == classified records
SUM=$(jq '.kpis.up_to_date + .kpis.updates_available + .kpis.source_changes + .kpis.manual_review + .kpis.check_failed + .kpis.upstream_unavailable + .kpis.upstream_archived + .kpis.rebuild_required + .kpis.lifecycle_unknown' "$WORKDIR/snapshot-states.json")
if [[ "$SUM" -eq 9 ]]; then
  ok "mutually exclusive lifecycle KPIs sum to classified records"
else
  bad "KPI sum mismatch: $SUM != 9"
fi
if jq -e '.kpis.rebuild_required == 1' "$WORKDIR/snapshot-states.json" >/dev/null 2>&1; then
  ok "REBUILD_REQUIRED maps to its own KPI"
else
  bad "rebuild_required missing: $(jq -c '.kpis.rebuild_required' "$WORKDIR/snapshot-states.json")"
fi

# archived-only inventory
cat > "$WORKDIR/archived-only.json" <<'JSON'
[
  {"package":"physlock","update_type":"UPSTREAM_ARCHIVED","checked_at":"2026-11-06T00:00:00Z","note":"archived"}
]
JSON
bash "$BUILD" --lifecycle "$WORKDIR/archived-only.json" --out "$WORKDIR/snapshot-arch.json" > /dev/null 2>&1
if jq -e '.kpis.upstream_archived == 1 and .kpis.check_failed == 0' \
    "$WORKDIR/snapshot-arch.json" >/dev/null 2>&1; then
  ok "archived-only inventory -> upstream_archived=1, check_failed=0"
else
  bad "archived conflation: $(jq -c '.kpis | {a:.upstream_archived,c:.check_failed}' "$WORKDIR/snapshot-arch.json")"
fi

# upstream-unavailable-only inventory
cat > "$WORKDIR/unavailable-only.json" <<'JSON'
[
  {"package":"gone","update_type":"UPSTREAM_UNAVAILABLE","checked_at":"2026-11-06T00:00:00Z","note":"404"}
]
JSON
bash "$BUILD" --lifecycle "$WORKDIR/unavailable-only.json" --out "$WORKDIR/snapshot-unav.json" > /dev/null 2>&1
if jq -e '.kpis.upstream_unavailable == 1 and .kpis.check_failed == 0' \
    "$WORKDIR/snapshot-unav.json" >/dev/null 2>&1; then
  ok "unavailable-only inventory -> upstream_unavailable=1, check_failed=0"
else
  bad "unavailable conflation: $(jq -c '.kpis | {u:.upstream_unavailable,c:.check_failed}' "$WORKDIR/snapshot-unav.json")"
fi

# probe-failure-only inventory
cat > "$WORKDIR/failed-only.json" <<'JSON'
[
  {"package":"flaky","update_type":"CHECK_FAILED","checked_at":"2026-11-06T00:00:00Z","note":"timeout"}
]
JSON
bash "$BUILD" --lifecycle "$WORKDIR/failed-only.json" --out "$WORKDIR/snapshot-fail.json" > /dev/null 2>&1
if jq -e '.kpis.check_failed == 1 and .kpis.upstream_unavailable == 0 and .kpis.upstream_archived == 0' \
    "$WORKDIR/snapshot-fail.json" >/dev/null 2>&1; then
  ok "probe-failure-only inventory -> check_failed=1 only"
else
  bad "failure classification wrong: $(jq -c '.kpis' "$WORKDIR/snapshot-fail.json")"
fi

# corrupted lifecycle data is rejected by the collector; build-metrics treats
# a non-array as empty (never fabricates)
printf 'this is not json' > "$WORKDIR/corrupt.json"
bash "$BUILD" --lifecycle "$WORKDIR/corrupt.json" --out "$WORKDIR/snapshot-corrupt.json" > /dev/null 2>&1
if jq -e '.kpis.total_packages == 0 and .kpis.up_to_date == 0' \
    "$WORKDIR/snapshot-corrupt.json" >/dev/null 2>&1; then
  ok "corrupted lifecycle data -> empty KPIs (no fabrication)"
else
  bad "corrupt lifecycle fabricated values: $(jq -c '.kpis' "$WORKDIR/snapshot-corrupt.json")"
fi

# ---------------------------------------------------------------------------
note "metrics: read-only, never mutates input fixtures"
before=$(find "$WORKDIR/health" "$WORKDIR/publish" "$WORKDIR/runs" -type f | sort | xargs md5sum)
bash "$BUILD" --health-dir "$WORKDIR/health" --publish-dir "$WORKDIR/publish" --runs-dir "$WORKDIR/runs" \
  --lifecycle "$WORKDIR/lifecycle.json" --out "$WORKDIR/snapshot4.json" > /dev/null 2>&1
after=$(find "$WORKDIR/health" "$WORKDIR/publish" "$WORKDIR/runs" -type f | sort | xargs md5sum)
if [[ "$before" == "$after" ]]; then
  ok "input fixtures unchanged"
else
  bad "build-metrics mutated inputs"
fi

# ---------------------------------------------------------------------------
note "metrics: bounded history merge (merge-metrics-history.sh)"
MERGE="$REPO_ROOT/.github/scripts/merge-metrics-history.sh"
printf '{"generated_at":"2026-11-04T00:00:00Z","kpis":{"total_packages":1}}\n' > "$WORKDIR/hist.jsonl"
printf '{"generated_at":"2026-11-05T00:00:00Z","kpis":{"total_packages":2}}\n' >> "$WORKDIR/hist.jsonl"
printf '{"generated_at":"2026-11-06T00:00:00Z","kpis":{"total_packages":3}}\n' > "$WORKDIR/snap.json"
bash "$MERGE" --history "$WORKDIR/hist.jsonl" --snapshot "$WORKDIR/snap.json" \
  --retention 2 --out "$WORKDIR/merged.jsonl" > /dev/null 2>&1
if [[ "$(jq -s 'length' "$WORKDIR/merged.jsonl")" -eq 2 ]]; then
  ok "history merge trims to retention"
else
  bad "history merge retention wrong: $(jq -s 'length' "$WORKDIR/merged.jsonl")"
fi
if jq -e 'select(.generated_at == "2026-11-06T00:00:00Z")' "$WORKDIR/merged.jsonl" >/dev/null 2>&1; then
  ok "new snapshot appended"
else
  bad "new snapshot missing from merged history"
fi
# dedupe: identical snapshots do not duplicate
printf '{"generated_at":"2026-11-06T00:00:00Z","kpis":{"total_packages":3}}\n' >> "$WORKDIR/hist.jsonl"
bash "$MERGE" --history "$WORKDIR/hist.jsonl" --snapshot "$WORKDIR/snap.json" \
  --retention 10 --out "$WORKDIR/merged2.jsonl" > /dev/null 2>&1
if [[ "$(jq -s 'length' "$WORKDIR/merged2.jsonl")" -eq 3 ]]; then
  ok "exact duplicate snapshots deduplicated"
else
  bad "dedupe failed: $(jq -s 'length' "$WORKDIR/merged2.jsonl") entries"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
