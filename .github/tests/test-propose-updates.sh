#!/usr/bin/env bash
#
# Regression tests for Phase 5.2 update proposal generation
# (propose-updates.sh). Runs offline (no --push, no network). Verifies:
#   - proposals are only generated for verified update states
#   - deterministic branch derivation (same report => same branch)
#   - no PKGBUILD edits / no invented checksums
#   - index lists manual-review candidates separately
#   - no secrets/tokens in generated documents
set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# -- fixture lifecycle report ------------------------------------------------
cat > "$WORKDIR/report.json" <<'JSON'
[
  {"package":"pkg-a","current_version":"1.0.0","current_epoch":"","current_release":"1","upstream_version":"1.2.0","upstream_url":"https://github.com/example/pkg-a","update_type":"UPDATE_AVAILABLE","package_type":"stable","source_kind":"github","source_reference":"v1.2.0","rebuild_required":true,"risk_level":"medium","recommended_action":"review PR proposal","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"newer version 1.2.0"},
  {"package":"pkg-b","current_version":"1.0","current_epoch":"","current_release":"1","upstream_version":"","upstream_url":"https://github.com/example/pkg-b","update_type":"SOURCE_CHANGED","package_type":"vcs","source_kind":"git","source_reference":"abcdef0123","rebuild_required":true,"risk_level":"low","recommended_action":"none","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"branch HEAD moved"},
  {"package":"pkg-c","current_version":"2.0","current_epoch":"","current_release":"1","upstream_version":"","upstream_url":"https://github.com/example/pkg-c","update_type":"CHECK_FAILED","package_type":"stable","source_kind":"github","source_reference":"","rebuild_required":false,"risk_level":"low","recommended_action":"none","probe_ok":false,"checked_at":"2026-11-06T00:00:00Z","note":"github probe returned no versions"},
  {"package":"pkg-d","current_version":"1.0","current_epoch":"","current_release":"1","upstream_version":"","upstream_url":"","update_type":"MANUAL_REVIEW","package_type":"stable","source_kind":"unsupported","source_reference":"","rebuild_required":false,"risk_level":"low","recommended_action":"none","probe_ok":false,"checked_at":"2026-11-06T00:00:00Z","note":"unparsable source"}
]
JSON

# ---------------------------------------------------------------------------
note "propose: proposal docs generated only for verified update states"
OUT1="$WORKDIR/out1"
rc=0
bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
  --report "$WORKDIR/report.json" --outdir "$OUT1" --base main \
  > "$WORKDIR/propose1.log" 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "propose-updates exits 0 offline"
else
  bad "propose-updates failed (rc=$rc): $(tail -3 "$WORKDIR/propose1.log")"
fi
if [[ -f "$OUT1/pkg-a.md" ]]; then
  ok "UPDATE_AVAILABLE package gets a proposal"
else
  bad "pkg-a.md missing"
fi
if [[ -f "$OUT1/pkg-b.md" ]]; then
  ok "SOURCE_CHANGED package gets a proposal"
else
  bad "pkg-b.md missing"
fi
if [[ ! -f "$OUT1/pkg-c.md" && ! -f "$OUT1/pkg-d.md" ]]; then
  ok "CHECK_FAILED/MANUAL_REVIEW packages get NO proposal"
else
  bad "unverified package proposed: $(ls "$OUT1" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
note "propose: index separates automatic proposals from manual review"
if grep -q 'Automatic proposals (2)' "$OUT1/README.md" \
    && grep -q 'pkg-a' "$OUT1/README.md" \
    && grep -q 'pkg-b' "$OUT1/README.md" \
    && grep -q 'pkg-c' "$OUT1/README.md" \
    && grep -q 'pkg-d' "$OUT1/README.md"; then
  ok "index lists proposals and manual-review candidates"
else
  bad "index structure wrong: $(head -20 "$OUT1/README.md")"
fi

# ---------------------------------------------------------------------------
note "propose: deterministic branch + plan"
PLAN="$OUT1/proposal-plan.json"
if jq -e '.update_count == 1 and (.proposals | length) == 2 and (.branch | length > 0)' \
    "$PLAN" >/dev/null 2>&1; then
  ok "plan JSON has branch + update count + proposals"
else
  bad "plan JSON wrong: $(cat "$PLAN")"
fi
OUT2="$WORKDIR/out2"
bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
  --report "$WORKDIR/report.json" --outdir "$OUT2" --base main \
  > /dev/null 2>&1
B1=$(jq -r '.branch' "$PLAN")
B2=$(jq -r '.branch' "$OUT2/proposal-plan.json")
if [[ "$B1" == "$B2" && -n "$B1" ]]; then
  ok "branch is deterministic across runs"
else
  bad "branch not deterministic: $B1 vs $B2"
fi
if diff -r "$OUT1" "$OUT2" >/dev/null 2>&1; then
  ok "proposal documents byte-identical across runs"
else
  bad "proposal documents differ across runs"
fi

# ---------------------------------------------------------------------------
note "propose: never edits PKGBUILDs, never invents checksums"
if grep -qrE 'sha256sums=\(|apply this patch|edit PKGBUILD|modify PKGBUILD' "$OUT1"; then
  bad "proposal contains concrete edit instructions"
else
  ok "no checksum/PKGBUILD edits proposed"
fi
if grep -q 'No checksums are proposed automatically' "$OUT1/pkg-a.md"; then
  ok "proposal documents checksum policy (never guessed)"
else
  bad "checksum policy note missing"
fi

# ---------------------------------------------------------------------------
note "propose: documents never contain secrets/tokens"
if grep -rqiE 'GH_TOKEN|GITHUB_TOKEN|ghp_|github_pat_|BEGIN (RSA |OPENSSH |PGP )?PRIVATE KEY' \
    "$OUT1"; then
  bad "sensitive content found in proposals"
else
  ok "proposal documents free of secrets"
fi

# ---------------------------------------------------------------------------
note "propose: no-update report yields zero proposals, exit 0"
cat > "$WORKDIR/no-update.json" <<'JSON'
[
  {"package":"pkg-a","current_version":"1.0.0","update_type":"UP_TO_DATE","package_type":"stable","source_kind":"github","source_reference":"v1.0.0","rebuild_required":false,"risk_level":"low","recommended_action":"none","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"current matches"}
]
JSON
OUT3="$WORKDIR/out3"
rc=0
bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
  --report "$WORKDIR/no-update.json" --outdir "$OUT3" \
  > /dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'Automatic proposals (0)' "$OUT3/README.md"; then
  ok "no-update report -> 0 proposals, exit 0"
else
  bad "no-update handling wrong (rc=$rc)"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
