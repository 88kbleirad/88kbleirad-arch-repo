#!/usr/bin/env bash
#
# Regression tests for the Phase 5.4 cross-workflow artifact retrieval
# (collect-artifacts.sh) and the dashboard completeness/inventory behavior.
#
# These tests run fully offline against the mock `gh api` fixture
# (mock-gh-api.sh): deterministic GitHub API responses, no network, no
# secrets, no writes (the events log proves GET-only usage).
#
# Aspects covered:
#   - artifact discovery across independent workflow runs (REST API)
#   - correct source-run selection (completed + successful; newest first)
#   - artifact expiration handling
#   - missing workflow artifacts
#   - corrupted JSON reports are rejected, never rendered healthy
#   - mixed valid and invalid sources
#   - production and staging health separation
#   - missing metrics-history artifact (bounded history still merges)
#   - history retention / dedupe across two simulated runs
#   - dashboard completeness classification (COMPLETE/PARTIAL/NO_DATA)
#   - empty data vs legitimate zero values (no fabrication)
#   - no accidental GitHub API writes
set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

COLLECT="$REPO_ROOT/.github/scripts/collect-artifacts.sh"
BUILD_METRICS="$REPO_ROOT/.github/scripts/build-metrics.sh"
MERGE="$REPO_ROOT/.github/scripts/merge-metrics-history.sh"
BUILD_DASH="$REPO_ROOT/.github/scripts/build-dashboard.sh"

# ---------------------------------------------------------------------------
# mock gh API fixture
# ---------------------------------------------------------------------------
API="$WORKDIR/api"
MOCKBIN="$WORKDIR/mockbin"
mkdir -p "$API/artifacts" "$API/runs" "$MOCKBIN"
cp "$REPO_ROOT/.github/tests/mock-gh-api.sh" "$MOCKBIN/gh"
chmod +x "$MOCKBIN/gh"

run_json() { # <id> <conclusion> <path> <created>
  cat > "$API/runs/$1.json" <<EOF
{"id":$1,"status":"completed","conclusion":"$2","path":"$3","created_at":"$4"}
EOF
}
run_json 111 success .github/workflows/repo-health.yml 2026-11-04T10:00:00Z
run_json 222 success .github/workflows/repo-health.yml 2026-11-04T11:00:00Z
run_json 333 success .github/workflows/check-updates.yml 2026-11-03T10:00:00Z
run_json 444 success .github/workflows/observability.yml 2026-11-02T10:00:00Z
run_json 555 success .github/workflows/observability.yml 2026-11-06T09:00:00Z  # CURRENT run
run_json 666 success .github/workflows/build-release.yml 2026-11-05T10:00:00Z
run_json 777 success .github/workflows/build-release.yml 2026-11-05T11:00:00Z
run_json 888 success .github/workflows/repo-health.yml 2026-11-06T06:00:00Z
run_json 890 failure .github/workflows/repo-health.yml 2026-11-06T07:00:00Z
run_json 999 failure .github/workflows/check-updates.yml 2026-11-06T08:00:00Z
run_json 1000 success .github/workflows/check-updates.yml 2026-11-06T08:30:00Z
run_json 1001 success .github/workflows/repo-health.yml 2026-11-06T08:45:00Z
run_json 1111 success .github/workflows/repo-health.yml 2026-11-06T09:10:00Z

mkzip() { # <dir> <zip>
  local d="$1" z="$2"
  ( cd "$d" && python3 -m zipfile -c "$z" . ) 2>/dev/null \
    || ( cd "$d" && zip -q -r "$z" . )
}

# --- valid production health report (run 111) -------------------------------
mkdir -p "$WORKDIR/src/prod"
cat > "$WORKDIR/src/prod/health-report.json" <<'JSON'
{
  "repository": "88kbleirad/88kbleirad-arch-repo",
  "release_tag": "repository",
  "timestamp": "2026-11-04T10:02:00Z",
  "package_count": 20,
  "overall_status": "HEALTHY"
}
JSON
mkzip "$WORKDIR/src/prod" "$API/artifacts/111.zip"

# --- valid staging health report (run 222) ----------------------------------
mkdir -p "$WORKDIR/src/stage"
cat > "$WORKDIR/src/stage/health-report.json" <<'JSON'
{
  "repository": "88kbleirad/88kbleirad-arch-repo",
  "release_tag": "repository-v4-test",
  "timestamp": "2026-11-04T11:02:00Z",
  "package_count": 20,
  "overall_status": "DEGRADED"
}
JSON
mkzip "$WORKDIR/src/stage" "$API/artifacts/222.zip"

# --- expired production health report (run 888) ------------------------------
mkdir -p "$WORKDIR/src/exp"
cp "$WORKDIR/src/prod/health-report.json" "$WORKDIR/src/exp/"
mkzip "$WORKDIR/src/exp" "$API/artifacts/888.zip"

# --- failed-run production health report (run 890) ---------------------------
mkdir -p "$WORKDIR/src/failrun"
cp "$WORKDIR/src/prod/health-report.json" "$WORKDIR/src/failrun/"
mkzip "$WORKDIR/src/failrun" "$API/artifacts/890.zip"

# --- valid lifecycle report (run 333) ----------------------------------------
mkdir -p "$WORKDIR/src/lc"
cat > "$WORKDIR/src/lc/update-report.json" <<'JSON'
[
  {"package":"beautyline","current_version":"3.0.5","current_epoch":"2","current_release":"2",
   "upstream_version":"3.0.5","update_type":"UP_TO_DATE","rebuild_required":false,
   "checked_at":"2026-11-03T10:01:00Z"},
  {"package":"nmtui-go","current_version":"1.2.3","upstream_version":"1.3.0",
   "update_type":"UPDATE_AVAILABLE","rebuild_required":true,
   "checked_at":"2026-11-03T10:02:00Z"}
]
JSON
mkzip "$WORKDIR/src/lc" "$API/artifacts/333.zip"

# --- failed-run lifecycle report (run 999) ------------------------------------
mkdir -p "$WORKDIR/src/lcfail"
cp "$WORKDIR/src/lc/update-report.json" "$WORKDIR/src/lcfail/"
mkzip "$WORKDIR/src/lcfail" "$API/artifacts/999.zip"

# --- corrupted lifecycle report (run 1000) ------------------------------------
mkdir -p "$WORKDIR/src/lccorrupt"
printf '{ this is not json\n' > "$WORKDIR/src/lccorrupt/update-report.json"
mkzip "$WORKDIR/src/lccorrupt" "$API/artifacts/1000.zip"

# --- corrupted production health report (run 1001) -----------------------------
mkdir -p "$WORKDIR/src/prodcorrupt"
printf 'not json at all\n' > "$WORKDIR/src/prodcorrupt/health-report.json"
mkzip "$WORKDIR/src/prodcorrupt" "$API/artifacts/1001.zip"

# --- previous metrics history (run 444, previous observability run) ------------
mkdir -p "$WORKDIR/src/hist"
printf '{"generated_at":"2026-11-01T00:00:00Z","kpis":{"total_packages":2}}\n' > "$WORKDIR/src/hist/metrics-history.jsonl"
printf '{"generated_at":"2026-11-02T00:00:00Z","kpis":{"total_packages":2}}\n' >> "$WORKDIR/src/hist/metrics-history.jsonl"
printf '{"schema":"repo-metrics/v1","generated_at":"2026-11-02T00:00:00Z","retention":200,"kpis":{"total_packages":2}}\n' > "$WORKDIR/src/hist/snapshot.json"
mkzip "$WORKDIR/src/hist" "$API/artifacts/444.zip"

# --- current-run history (run 555) — must be excluded --------------------------
mkdir -p "$WORKDIR/src/self"
printf '{"generated_at":"2026-11-06T09:00:00Z","kpis":{}}\n' > "$WORKDIR/src/self/metrics-history.jsonl"
mkzip "$WORKDIR/src/self" "$API/artifacts/555.zip"

# --- wrong-workflow history (run 1111) — must be rejected -----------------------
mkdir -p "$WORKDIR/src/wrongwf"
printf '{"generated_at":"2026-11-06T09:10:00Z","kpis":{}}\n' > "$WORKDIR/src/wrongwf/metrics-history.jsonl"
mkzip "$WORKDIR/src/wrongwf" "$API/artifacts/1111.zip"

# --- publish summary sidecar (run 666) -----------------------------------------
mkdir -p "$WORKDIR/src/pub"
printf '{"timestamp":"2026-11-05T10:10:00Z","release":"repository","unchanged":44,"uploaded":0,"replaced":0,"failed":0,"api_requests":4,"duration_seconds":3.2}\n' > "$WORKDIR/src/pub/publish-history.jsonl"
mkzip "$WORKDIR/src/pub" "$API/artifacts/666.zip"

# --- CI run sidecars (run 777) ------------------------------------------------
mkdir -p "$WORKDIR/src/ci"
printf '{"timestamp":"2026-11-05T11:05:00Z","package":"beautyline","duration_seconds":30,"cache":"HIT"}\n' > "$WORKDIR/src/ci/build-durations.jsonl"
printf '{"timestamp":"2026-11-05T11:05:00Z","run":"r1","hits":1,"misses":1,"hit_rate":50}\n' > "$WORKDIR/src/ci/cache-history.jsonl"
mkzip "$WORKDIR/src/ci" "$API/artifacts/777.zip"

# --- full artifact listing (newest first) --------------------------------------
cat > "$API/artifacts.json" <<'JSON'
{
  "total_count": 14,
  "artifacts": [
    {"id":1111,"name":"metrics-snapshot","workflow_run":{"id":1111},"expired":false,"created_at":"2026-11-06T09:10:00Z","expires_at":"2026-12-06T09:10:00Z"},
    {"id":1001,"name":"health-report-repository","workflow_run":{"id":1001},"expired":false,"created_at":"2026-11-06T08:45:00Z","expires_at":"2026-12-06T08:45:00Z"},
    {"id":1000,"name":"update-report","workflow_run":{"id":1000},"expired":false,"created_at":"2026-11-06T08:30:00Z","expires_at":"2026-12-06T08:30:00Z"},
    {"id":999,"name":"update-report","workflow_run":{"id":999},"expired":false,"created_at":"2026-11-06T08:00:00Z","expires_at":"2026-12-06T08:00:00Z"},
    {"id":890,"name":"health-report-repository","workflow_run":{"id":890},"expired":false,"created_at":"2026-11-06T07:00:00Z","expires_at":"2026-12-06T07:00:00Z"},
    {"id":888,"name":"health-report-repository","workflow_run":{"id":888},"expired":true,"created_at":"2026-11-06T06:00:00Z","expires_at":"2026-10-01T00:00:00Z"},
    {"id":777,"name":"run-metrics-42161541158","workflow_run":{"id":777},"expired":false,"created_at":"2026-11-05T11:00:00Z","expires_at":"2026-12-05T11:00:00Z"},
    {"id":666,"name":"publish-summary-repository","workflow_run":{"id":666},"expired":false,"created_at":"2026-11-05T10:00:00Z","expires_at":"2026-12-05T10:00:00Z"},
    {"id":555,"name":"metrics-snapshot","workflow_run":{"id":555},"expired":false,"created_at":"2026-11-06T09:00:00Z","expires_at":"2026-12-06T09:00:00Z"},
    {"id":444,"name":"metrics-snapshot","workflow_run":{"id":444},"expired":false,"created_at":"2026-11-02T10:00:00Z","expires_at":"2026-12-02T10:00:00Z"},
    {"id":333,"name":"update-report","workflow_run":{"id":333},"expired":false,"created_at":"2026-11-03T10:00:00Z","expires_at":"2026-12-03T10:00:00Z"},
    {"id":222,"name":"health-report-repository-v4-test","workflow_run":{"id":222},"expired":false,"created_at":"2026-11-04T11:00:00Z","expires_at":"2026-12-04T11:00:00Z"},
    {"id":111,"name":"health-report-repository","workflow_run":{"id":111},"expired":false,"created_at":"2026-11-04T10:00:00Z","expires_at":"2026-12-04T10:00:00Z"},
    {"id":1,"name":"pkg-beautyline","workflow_run":{"id":1},"expired":false,"created_at":"2026-11-01T00:00:00Z","expires_at":"2026-12-01T00:00:00Z"}
  ]
}
JSON

EVENTS="$WORKDIR/events.log"
: > "$EVENTS"

run_collect() { # <out> [extra args...]
  local out="$1"; shift
  env -i PATH="$MOCKBIN:$PATH" HOME="$HOME" \
    GH_TOKEN=mock MOCK_GH_API_DIR="$API" MOCK_GH_API_EVENTS="$EVENTS" \
    bash "$COLLECT" --repo owner/repo --run-id 555 --out "$out" \
    --inventory "$out/inventory.json" --history-out "$out/previous-history.jsonl" \
    --summary "$out/summary.md" --prod-release repository --staging-release repository-v4-test \
    "$@"
}

# ---------------------------------------------------------------------------
note "collect: full fixture -> COMPLETE with validated sources"
COLL="$WORKDIR/coll1"
run_collect "$COLL" >/dev/null 2>&1
if [[ "$(jq -r '.completeness' "$COLL/inventory.json")" == "COMPLETE" ]]; then
  ok "completeness=COMPLETE"
else
  bad "expected COMPLETE, got $(jq -r '.completeness' "$COLL/inventory.json")"
fi
if [[ -f "$COLL/health_production/health-report.json" \
   && -f "$COLL/health_staging/health-report.json" \
   && -f "$COLL/lifecycle/update-report.json" \
   && -f "$COLL/publish/publish-history.jsonl" \
   && -f "$COLL/ci/build-durations.jsonl" \
   && -f "$COLL/ci/cache-history.jsonl" ]]; then
  ok "per-slot extraction dirs present"
else
  bad "missing per-slot extraction dirs"
fi
if [[ -s "$COLL/previous-history.jsonl" ]] && [[ "$(jq -s 'length' "$COLL/previous-history.jsonl")" -eq 2 ]]; then
  ok "previous history retrieved (2 entries)"
else
  bad "previous history not retrieved"
fi
if jq -e '.sources.health_production.status == "ok" and .sources.health_production.run_id == "111"
        and .sources.health_production.state == "HEALTHY"
        and .sources.health_staging.status == "ok" and .sources.health_staging.state == "DEGRADED"
        and .sources.lifecycle.status == "ok"
        and .sources.history.status == "ok" and .sources.history.run_id == "444"
        and .sources.publish.status == "ok" and .sources.ci.status == "ok"' \
    "$COLL/inventory.json" >/dev/null 2>&1; then
  ok "source attribution correct (run ids + states)"
else
  bad "source attribution wrong: $(jq -c '.sources' "$COLL/inventory.json")"
fi

note "collect: current-run artifacts are excluded (recursion guard)"
if jq -e '[.rejected[] | select(.reason == "current_run_ignored")] | length >= 1' \
    "$COLL/inventory.json" >/dev/null 2>&1; then
  ok "current-run metrics-snapshot rejected"
else
  bad "current-run artifact was ingested"
fi
if jq -e '.sources.history.run_id != "555"' "$COLL/inventory.json" >/dev/null 2>&1; then
  ok "history source is not the current run"
else
  bad "history source is from the current run"
fi

note "collect: wrong-workflow history candidate is rejected"
if jq -e '[.rejected[] | select(.reason == "wrong_workflow")] | length >= 1' \
    "$COLL/inventory.json" >/dev/null 2>&1; then
  ok "wrong-workflow history rejected"
else
  bad "wrong-workflow history not rejected"
fi

note "collect: expired candidate is rejected, older valid candidate selected"
if jq -e '[.rejected[] | select(.reason == "expired")] | length >= 1' \
    "$COLL/inventory.json" >/dev/null 2>&1; then
  ok "expired candidate recorded as rejected"
else
  bad "expired candidate not recorded"
fi
if jq -e '.sources.health_production.run_id == "111"' "$COLL/inventory.json" >/dev/null 2>&1; then
  ok "newest *eligible* candidate selected for production health"
else
  bad "production health selected wrong run"
fi

note "collect: failed source run is not chosen (recorded, falls back)"
if jq -e '[.rejected[] | select(.reason == "source_run_failed")] | length >= 1' \
    "$COLL/inventory.json" >/dev/null 2>&1; then
  ok "failed-run lifecycle candidate recorded"
else
  bad "failed-run lifecycle candidate missing from rejected"
fi
if jq -e '.sources.lifecycle.run_id == "333"' "$COLL/inventory.json" >/dev/null 2>&1; then
  ok "successful lifecycle run selected"
else
  bad "lifecycle source selection wrong"
fi

note "collect: no accidental GitHub API writes"
if ! grep -q -- '--method' "$EVENTS" && ! grep -q 'POST \|PATCH \|DELETE \|PUT ' "$EVENTS"; then
  ok "events log contains GET requests only"
else
  bad "non-GET API usage detected in events log"
fi

# ---------------------------------------------------------------------------
note "metrics: inventory-driven build keeps production/staging separate"
SNAP="$WORKDIR/snap1.json"
bash "$BUILD_METRICS" --inventory "$COLL/inventory.json" \
  --health-dir "$COLL" --publish-dir "$COLL" --runs-dir "$COLL" \
  --lifecycle "$COLL/lifecycle/update-report.json" \
  --packages-file "$REPO_ROOT/packages.txt" \
  --retention 50 --out "$SNAP" >/dev/null 2>&1
if jq -e '.completeness == "COMPLETE" and .schema == "repo-metrics/v1"' "$SNAP" >/dev/null 2>&1; then
  ok "snapshot schema + COMPLETE verdict"
else
  bad "snapshot completeness/schema wrong: $(jq -c '{c:.completeness,s:.schema}' "$SNAP")"
fi
if jq -e '.kpis.production_health == "HEALTHY" and .kpis.staging_health == "DEGRADED"' "$SNAP" >/dev/null 2>&1; then
  ok "production and staging health independent"
else
  bad "health separation broken: $(jq -c '.kpis | {p:.production_health,s:.staging_health}' "$SNAP")"
fi
if jq -e '.kpis.packages_configured == 55 and .kpis.packages_published == 20' "$SNAP" >/dev/null 2>&1; then
  ok "configured (55) vs published (20) inventory kept separate"
else
  bad "inventory separation broken: $(jq -c '.kpis | {c:.packages_configured,p:.packages_published}' "$SNAP")"
fi
if jq -e '.kpis.total_packages == 2 and .kpis.updates_available == 1 and .kpis.up_to_date == 1
          and .kpis.source_changes == 0 and .kpis.build_failures == 0
          and .kpis.check_failed == 0 and .kpis.upstream_unavailable == 0 and .kpis.upstream_archived == 0' "$SNAP" >/dev/null 2>&1; then
  ok "lifecycle-derived KPIs separate confirmed updates from source changes"
else
  bad "lifecycle KPIs wrong: $(jq -c '.kpis' "$SNAP")"
fi
if jq -e '.kpis.cache_hit_rate == 50 and .kpis.publication_duration == 3.2' "$SNAP" >/dev/null 2>&1; then
  ok "publish/CI sidecar KPIs derived"
else
  bad "sidecar KPIs missing"
fi

# ---------------------------------------------------------------------------
note "metrics: missing history artifact is optional (COMPLETE retained, flagged)"
COLL2="$WORKDIR/coll2"
mkdir -p "$COLL2"
cp -r "$COLL/health_production" "$COLL2/"
cp -r "$COLL/health_staging" "$COLL2/"
cp -r "$COLL/lifecycle" "$COLL2/"
# omit the metrics-snapshot artifact entirely
cat > "$API/artifacts.json" <<'JSON'
{
  "total_count": 3,
  "artifacts": [
    {"id":333,"name":"update-report","workflow_run":{"id":333},"expired":false,"created_at":"2026-11-03T10:00:00Z","expires_at":"2026-12-03T10:00:00Z"},
    {"id":222,"name":"health-report-repository-v4-test","workflow_run":{"id":222},"expired":false,"created_at":"2026-11-04T11:00:00Z","expires_at":"2026-12-04T11:00:00Z"},
    {"id":111,"name":"health-report-repository","workflow_run":{"id":111},"expired":false,"created_at":"2026-11-04T10:00:00Z","expires_at":"2026-12-04T10:00:00Z"}
  ]
}
JSON
: > "$EVENTS"
run_collect "$COLL2" >/dev/null 2>&1
if [[ "$(jq -r '.completeness' "$COLL2/inventory.json")" == "COMPLETE" ]]; then
  ok "completeness still COMPLETE without history (optional source)"
else
  bad "completeness regressed when optional history missing"
fi
if jq -e '.sources.history.status == "not_found" and (.unavailable | index("history")) != null' \
    "$COLL2/inventory.json" >/dev/null 2>&1; then
  ok "missing history flagged as unavailable optional source"
else
  bad "missing history not flagged"
fi
if [[ -f "$COLL2/previous-history.jsonl" ]]; then
  bad "previous history file should not exist"
else
  ok "no previous history file when artifact absent"
fi

# ---------------------------------------------------------------------------
note "collect: NO_DATA when no core source exists"
COLL3="$WORKDIR/coll3"
cat > "$API/artifacts.json" <<'JSON'
{
  "total_count": 1,
  "artifacts": [
    {"id":1,"name":"pkg-beautyline","workflow_run":{"id":1},"expired":false,"created_at":"2026-11-01T00:00:00Z","expires_at":"2026-12-01T00:00:00Z"}
  ]
}
JSON
: > "$EVENTS"
run_collect "$COLL3" >/dev/null 2>&1
if [[ "$(jq -r '.completeness' "$COLL3/inventory.json")" == "NO_DATA" ]]; then
  ok "NO_DATA when no core sources exist"
else
  bad "expected NO_DATA, got $(jq -r '.completeness' "$COLL3/inventory.json")"
fi
if jq -e '(.missing | index("health_production")) != null and (.missing | index("health_staging")) != null and (.missing | index("lifecycle")) != null' \
    "$COLL3/inventory.json" >/dev/null 2>&1; then
  ok "all core slots listed as missing"
else
  bad "missing core slots not enumerated"
fi

# ---------------------------------------------------------------------------
note "collect: corrupted report is rejected, never treated as healthy"
COLL4="$WORKDIR/coll4"
cat > "$API/artifacts.json" <<'JSON'
{
  "total_count": 3,
  "artifacts": [
    {"id":1001,"name":"health-report-repository","workflow_run":{"id":1001},"expired":false,"created_at":"2026-11-06T08:45:00Z","expires_at":"2026-12-06T08:45:00Z"},
    {"id":222,"name":"health-report-repository-v4-test","workflow_run":{"id":222},"expired":false,"created_at":"2026-11-04T11:00:00Z","expires_at":"2026-12-04T11:00:00Z"},
    {"id":333,"name":"update-report","workflow_run":{"id":333},"expired":false,"created_at":"2026-11-03T10:00:00Z","expires_at":"2026-12-03T10:00:00Z"}
  ]
}
JSON
: > "$EVENTS"
run_collect "$COLL4" >/dev/null 2>&1
if jq -e '.sources.health_production.status == "invalid" and .sources.health_production.reason != ""' \
    "$COLL4/inventory.json" >/dev/null 2>&1; then
  ok "corrupted production report rejected"
else
  bad "corrupted report accepted: $(jq -c '.sources.health_production' "$COLL4/inventory.json")"
fi
if [[ "$(jq -r '.completeness' "$COLL4/inventory.json")" == "PARTIAL" ]]; then
  ok "PARTIAL when some core sources valid"
else
  bad "completeness $(jq -r '.completeness' "$COLL4/inventory.json") != PARTIAL"
fi

# ---------------------------------------------------------------------------
note "collect: failed source run yields explicit status, not silent absence"
COLL5="$WORKDIR/coll5"
cat > "$API/artifacts.json" <<'JSON'
{
  "total_count": 2,
  "artifacts": [
    {"id":999,"name":"update-report","workflow_run":{"id":999},"expired":false,"created_at":"2026-11-06T08:00:00Z","expires_at":"2026-12-06T08:00:00Z"},
    {"id":111,"name":"health-report-repository","workflow_run":{"id":111},"expired":false,"created_at":"2026-11-04T10:00:00Z","expires_at":"2026-12-04T10:00:00Z"}
  ]
}
JSON
: > "$EVENTS"
run_collect "$COLL5" >/dev/null 2>&1
if jq -e '.sources.lifecycle.status == "source_run_failed" and .sources.health_production.status == "ok"' \
    "$COLL5/inventory.json" >/dev/null 2>&1; then
  ok "failed source run classified explicitly"
else
  bad "failed-run classification wrong: $(jq -c '.sources' "$COLL5/inventory.json")"
fi

# ---------------------------------------------------------------------------
note "metrics: two simulated runs merge history with retention + dedupe"
# first run: no previous history -> merge starts from snapshot
SNAP_A="$WORKDIR/snapA.json"
METRICS_NOW=2026-11-06T09:30:00Z bash "$BUILD_METRICS" --inventory "$COLL/inventory.json" \
  --health-dir "$COLL" --publish-dir "$COLL" --runs-dir "$COLL" \
  --lifecycle "$COLL/lifecycle/update-report.json" \
  --retention 50 --out "$SNAP_A" >/dev/null 2>&1
HIST_A="$WORKDIR/histA.jsonl"
bash "$MERGE" --snapshot "$SNAP_A" --retention 50 --out "$HIST_A" >/dev/null 2>&1

# second (simulated) run: previous history artifact exists with a *different*
# snapshot; merge must append, dedupe exact duplicates (same generated_at),
# sort, and trim to retention
mkdir -p "$WORKDIR/src/hist2"
cp "$HIST_A" "$WORKDIR/src/hist2/metrics-history.jsonl"
printf '{"schema":"repo-metrics/v1","generated_at":"2026-11-06T10:00:00Z","retention":50,"kpis":{"total_packages":3}}\n' > "$WORKDIR/src/hist2/snapshot.json"
mkzip "$WORKDIR/src/hist2" "$API/artifacts/444.zip"
# restore full listing for a clean COMPLETE run
cat > "$API/artifacts.json" <<'JSON'
{
  "total_count": 3,
  "artifacts": [
    {"id":444,"name":"metrics-snapshot","workflow_run":{"id":444},"expired":false,"created_at":"2026-11-02T10:00:00Z","expires_at":"2026-12-02T10:00:00Z"},
    {"id":333,"name":"update-report","workflow_run":{"id":333},"expired":false,"created_at":"2026-11-03T10:00:00Z","expires_at":"2026-12-03T10:00:00Z"},
    {"id":111,"name":"health-report-repository","workflow_run":{"id":111},"expired":false,"created_at":"2026-11-04T10:00:00Z","expires_at":"2026-12-04T10:00:00Z"}
  ]
}
JSON
COLL6="$WORKDIR/coll6"
: > "$EVENTS"
run_collect "$COLL6" >/dev/null 2>&1
# second simulated run produces a NEW snapshot (later generated_at) that must
# be appended to the previous history and deduplicated/sorted/trimmed
SNAP_B="$WORKDIR/snapB.json"
METRICS_NOW=2026-11-06T10:15:00Z bash "$BUILD_METRICS" --inventory "$COLL6/inventory.json" \
  --health-dir "$COLL6" --publish-dir "$COLL6" --runs-dir "$COLL6" \
  --lifecycle "$COLL6/lifecycle/update-report.json" \
  --retention 50 --out "$SNAP_B" >/dev/null 2>&1
HIST_B="$WORKDIR/histB.jsonl"
bash "$MERGE" --history "$COLL6/previous-history.jsonl" --snapshot "$SNAP_B" \
  --retention 50 --out "$HIST_B" >/dev/null 2>&1
if [[ "$(jq -s 'length' "$HIST_B")" -ge 2 ]]; then
  ok "history merge across two runs retains entries"
else
  bad "history merge lost entries"
fi
if jq -s -e 'map(.generated_at) == (map(.generated_at) | unique)' "$HIST_B" >/dev/null 2>&1; then
  ok "history deduplicated (no identical duplicate timelines)"
else
  bad "history contains duplicate snapshots"
fi
# retention trim: 60 generated entries -> longest 50
for i in $(seq 1 60); do
  printf '{"generated_at":"2026-11-05T%02d:%02d:00Z","kpis":{"total_packages":1}}\n' $(( i / 60 )) $(( i % 60 )) >> "$HIST_B"
done
bash "$MERGE" --history "$HIST_B" --snapshot "$SNAP_A" --retention 50 --out "$WORKDIR/histC.jsonl" >/dev/null 2>&1
if [[ "$(jq -s 'length' "$WORKDIR/histC.jsonl")" -eq 50 ]]; then
  ok "history trimmed to retention (50)"
else
  bad "history not trimmed: $(jq -s 'length' "$WORKDIR/histC.jsonl")"
fi

# ---------------------------------------------------------------------------
note "dashboard: NO_DATA snapshot renders an explicitly labelled incomplete state"
SNAP_EMPTY="$WORKDIR/snapEmpty.json"
bash "$BUILD_METRICS" --inventory "$COLL3/inventory.json" \
  --out "$SNAP_EMPTY" >/dev/null 2>&1
if jq -e '.completeness == "NO_DATA" and .kpis.total_packages == 0 and .kpis.production_health == null' \
    "$SNAP_EMPTY" >/dev/null 2>&1; then
  ok "NO_DATA snapshot carries null KPIs (never fabricated zeros)"
else
  bad "NO_DATA snapshot KPIs wrong"
fi
DIST="$WORKDIR/dist-empty"
bash "$BUILD_DASH" --metrics "$SNAP_EMPTY" --out "$DIST" >/dev/null 2>&1
if grep -q '"completeness":"NO_DATA"' "$DIST/metrics.json"; then
  ok "dashboard payload carries NO_DATA verdict"
else
  bad "dashboard payload missing NO_DATA verdict"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
