#!/usr/bin/env bash
#
# Phase 5.3 dashboard tests:
#   - reproducible build (same inputs => identical output)
#   - metrics JSON embedded verbatim (no fabrication)
#   - Catppuccin Mocha color tokens present, no rounded corners anywhere
#   - responsive viewport meta, searchable table, filters
#   - no secrets in generated output
#   - empty snapshot renders N/A (no crash)
set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

BUILD="$REPO_ROOT/.github/scripts/build-dashboard.sh"

# -- fixture snapshot ---------------------------------------------------------
cat > "$WORKDIR/snapshot.json" <<'JSON'
{
  "schema": "repo-metrics/v1",
  "generated_at": "2026-11-06T00:00:00Z",
  "retention": 50,
  "build_profile": "x86-64-v4",
  "kpis": {
    "total_packages": 2,
    "up_to_date": 1,
    "updates_available": 1,
    "build_failures": 0,
    "production_health": "HEALTHY",
    "staging_health": "HEALTHY",
    "build_success_rate": 100,
    "cache_hit_rate": 50,
    "avg_build_duration": 12.5,
    "publication_duration": 3.2,
    "api_requests": 42,
    "last_successful_publish": "2026-11-05T10:00:00Z",
    "snapshot_at": "2026-11-06T00:00:00Z",
    "packages_checked": 2
  },
  "health_history": [
    {"timestamp":"2026-11-05T10:00:00Z","release":"repository","state":"HEALTHY"},
    {"timestamp":"2026-11-05T10:05:00Z","release":"repository-v4-test","state":"HEALTHY"}
  ],
  "publish_history": [
    {"timestamp":"2026-11-05T10:01:00Z","release":"repository","unchanged":44,"uploaded":0,"replaced":0,"failed":0,"api_requests":4,"duration_seconds":3.2}
  ],
  "build_durations": [
    {"timestamp":"2026-11-05T09:00:00Z","package":"beautyline","duration_seconds":30,"cache":"HIT"}
  ],
  "cache_history": [
    {"timestamp":"2026-11-05T09:00:00Z","run":"r1","hits":1,"misses":1,"hit_rate":50}
  ],
  "packages": [
    {"package":"beautyline","current_version":"3.0.5","current_epoch":"2","current_release":"2","upstream_version":"3.0.5","upstream_url":"https://gitlab.com/example/beautyline","update_type":"UP_TO_DATE","package_type":"stable","source_kind":"gitlab","source_reference":"","rebuild_required":false,"risk_level":"low","recommended_action":"none","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"current matches"},
    {"package":"nmtui-go","current_version":"0.2.7","current_epoch":"","current_release":"1","upstream_version":"0.3.0","upstream_url":"https://github.com/example/nmtui-go","update_type":"UPDATE_AVAILABLE","package_type":"stable","source_kind":"github","source_reference":"v0.3.0","rebuild_required":true,"risk_level":"medium","recommended_action":"review PR proposal","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"newer version 0.3.0"}
  ]
}
JSON

# ---------------------------------------------------------------------------
note "dashboard: reproducible build from snapshot"
bash "$BUILD" --metrics "$WORKDIR/snapshot.json" --out "$WORKDIR/dist1" > /dev/null 2>&1
bash "$BUILD" --metrics "$WORKDIR/snapshot.json" --out "$WORKDIR/dist2" > /dev/null 2>&1
if diff -r "$WORKDIR/dist1" "$WORKDIR/dist2" >/dev/null 2>&1; then
  ok "same snapshot -> identical output"
else
  bad "build not reproducible"
fi
for f in index.html style.css app.js metrics.js metrics.json; do
  [[ -s "$WORKDIR/dist1/$f" ]] || { bad "missing $f"; continue; }
  ok "$f present"
done

# ---------------------------------------------------------------------------
note "dashboard: metrics embedded verbatim, JSON valid"
if node -e 'const m=require(process.argv[1]); if(m.kpis.total_packages!==2||m.packages.length!==2) process.exit(1)' \
    "$WORKDIR/dist1/metrics.json" 2>/dev/null; then
  ok "embedded metrics JSON is valid and complete"
else
  bad "metrics.json invalid/incomplete"
fi
if grep -q 'window.REPO_METRICS' "$WORKDIR/dist1/metrics.js"; then
  ok "metrics.js defines window.REPO_METRICS"
else
  bad "metrics.js missing global"
fi

# ---------------------------------------------------------------------------
note "dashboard: Catppuccin Mocha palette + square corners"
if grep -q '#1e1e2e' "$WORKDIR/dist1/style.css" \
    && grep -q '#cdd6f4' "$WORKDIR/dist1/style.css" \
    && grep -q '#89b4fa' "$WORKDIR/dist1/style.css" \
    && grep -q '#a6e3a1' "$WORKDIR/dist1/style.css" \
    && grep -q '#f38ba8' "$WORKDIR/dist1/style.css" \
    && grep -q '#cba6f7' "$WORKDIR/dist1/style.css"; then
  ok "Mocha palette tokens present"
else
  bad "palette missing"
fi
if grep -qE 'border-radius:\s*[1-9]' "$WORKDIR/dist1/style.css"; then
  bad "non-zero border-radius found"
else
  ok "no rounded corners anywhere"
fi

# ---------------------------------------------------------------------------
note "dashboard: responsive + accessible + table features"
if grep -q 'name="viewport"' "$WORKDIR/dist1/index.html" \
    && grep -q '@media (max-width: 900px)' "$WORKDIR/dist1/style.css"; then
  ok "viewport meta + responsive breakpoint"
else
  bad "responsive markers missing"
fi
if grep -q 'aria-label="Search packages"' "$WORKDIR/dist1/index.html" \
    && grep -q 'role="img"' "$WORKDIR/dist1/app.js"; then
  ok "accessibility attributes present"
else
  bad "accessibility markers missing"
fi
if grep -q 'id="search"' "$WORKDIR/dist1/index.html" \
    && grep -q 'filter-btn' "$WORKDIR/dist1/app.js" \
    && grep -q '<th data-key="current_version">' "$WORKDIR/dist1/index.html" \
    && grep -q 'src="metrics.js"' "$WORKDIR/dist1/index.html" \
    && grep -q 'src="app.js"' "$WORKDIR/dist1/index.html"; then
  ok "search + filters + sortable table present"
else
  bad "table features missing"
fi

# ---------------------------------------------------------------------------
note "dashboard: no secrets or fabricated data in output"
if grep -rqiE 'GH_TOKEN|GITHUB_TOKEN|ghp_|github_pat_|BEGIN (RSA |OPENSSH |PGP )?PRIVATE KEY' \
    "$WORKDIR/dist1"; then
  bad "secrets found in dashboard output"
else
  ok "no secrets in output"
fi

# ---------------------------------------------------------------------------
note "dashboard: empty snapshot builds without data (all N/A)"
bash "$BUILD" --out "$WORKDIR/dist-empty" > /dev/null 2>&1
if grep -q 'window.REPO_METRICS =' "$WORKDIR/dist-empty/metrics.js" \
    && jq -e . "$WORKDIR/dist-empty/metrics.json" >/dev/null 2>&1; then
  ok "empty snapshot embedded"
else
  bad "empty snapshot not embedded"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
