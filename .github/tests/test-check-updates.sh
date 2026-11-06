#!/usr/bin/env bash
#
# Regression tests for the Phase 4.4 update detector. These validate the
# SAFETY semantics (never fabricate an update; unreliable upstream data is
# CHECK_FAILED/MANUAL_REVIEW, never UPDATE_AVAILABLE) and the JSON schema.
# Network probes are intentionally unreliable/unavailable in the test
# environment, which is exactly the failure mode the checker must handle
# safely.
set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

run_check() { # pkg dir -> rc
  local pkg="$1" dir="$2" rc
  set +e
  GH_TOKEN= GITHUB_WORKSPACE="$dir" \
    bash "$REPO_ROOT/.github/scripts/check-updates.sh" "$pkg" \
    --json "$WORKDIR/report.json" --timeout 2 \
    > "$WORKDIR/check.log" 2>&1
  rc=$?
  set -e
  echo $rc
}

# -- fixture packages --------------------------------------------------------
mk_pkg() { # pkg source_line
  local pkg="$1" src="$2"
  mkdir -p "$WORKDIR/$pkg"
  cat > "$WORKDIR/$pkg/PKGBUILD" <<PB
pkgname=$pkg
pkgver=1.0.0
pkgrel=1
url=https://example.com/$pkg
source=($src)
sha256sums=('SKIP')
PB
}

# git+ VCS (probe unavailable -> CHECK_FAILED or pinned MANUAL_REVIEW)
mk_pkg vcs-pkg "git+https://github.com/example/vcs-pkg.git"
# github tarball (probe unavailable -> CHECK_FAILED)
mk_pkg gh-pkg "https://github.com/example/gh-pkg/archive/v\\\${pkgver}.tar.gz"
# unknown scheme -> MANUAL_REVIEW
mk_pkg odd-pkg "ftp://example.com/odd-pkg.tar.gz"

# ---------------------------------------------------------------------------
note "update detection: probe failure never fabricates an update"
rc=$(run_check vcs-pkg "$WORKDIR")
if [[ "$rc" -eq 0 ]]; then
  ok "checker exit 0 on probe failure"
else
  bad "checker failed (rc=$rc): $(tail -3 "$WORKDIR/check.log")"
fi
if jq -e '.[0].update_type != "UPDATE_AVAILABLE"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "VCS probe failure does NOT report UPDATE_AVAILABLE"
else
  bad "VCS probe failure reported an update"
fi

# ---------------------------------------------------------------------------
note "update detection: GitHub tarball probe failure is CHECK_FAILED"
rc=$(run_check gh-pkg "$WORKDIR")
if jq -e '.[0].update_type == "CHECK_FAILED"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "github probe failure is CHECK_FAILED"
else
  bad "github probe failure not CHECK_FAILED: $(jq -r '.[0].update_type' "$WORKDIR/report.json" 2>/dev/null)"
fi
# the checker must resolve the package's PKGBUILD path; a CHECK_FAILED
# caused by an empty path would silently disable all source parsing
if jq -e '.[0].note | test("no PKGBUILD") | not' "$WORKDIR/report.json" >/dev/null 2>&1 \
    && jq -e '.[0].current_version == "1.0.0"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "PKGBUILD resolved (pkgver parsed, failure is upstream)"
else
  bad "PKGBUILD not resolved: $(jq -c '.[0]' "$WORKDIR/report.json")"
fi

# ---------------------------------------------------------------------------
note "update detection: unsupported source is MANUAL_REVIEW (never guessed)"
rc=$(run_check odd-pkg "$WORKDIR")
if jq -e '.[0].update_type == "MANUAL_REVIEW"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "unsupported source is MANUAL_REVIEW"
else
  bad "unsupported source not MANUAL_REVIEW: $(jq -r '.[0].update_type' "$WORKDIR/report.json" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
note "update detection: report contains required schema fields"
if jq -e '.[0] | has("package") and has("current_version") and has("upstream_version") and has("update_type") and has("source_reference") and has("rebuild_required") and has("risk_level") and has("recommended_action")' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "JSON schema fields present"
else
  bad "JSON schema incomplete: $(cat "$WORKDIR/report.json")"
fi

# ---------------------------------------------------------------------------
note "update detection: vercmp semantics are never lexical"
# a version like 1.10.0 must compare greater than 1.9.0
if [[ "$(vercmp 1.10.0 1.9.0)" == "1" ]]; then
  ok "vercmp 1.10.0 > 1.9.0 (non-lexical)"
else
  bad "vercmp semantics unavailable/wrong"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
