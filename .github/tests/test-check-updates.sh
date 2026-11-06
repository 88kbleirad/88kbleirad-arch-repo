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
  rm -f "$WORKDIR/report.json"
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

# ===========================================================================
# Phase 5.1 — lifecycle fields, mock probes, package typing
# ===========================================================================
run_check_mock() { # pkg dir [env assignments...]
  local pkg="$1" dir="$2"; shift 2
  local rc
  rm -f "$WORKDIR/report.json"
  set +e
  env -i PATH="$PATH" HOME="$HOME" \
    GITHUB_WORKSPACE="$dir" "$@" \
    bash "$REPO_ROOT/.github/scripts/check-updates.sh" "$pkg" \
    --json "$WORKDIR/report.json" --timeout 2 \
    > "$WORKDIR/check.log" 2>&1
  rc=$?
  set -e
  echo $rc
}

# epoch + pkgrel PKGBUILD (must parse epoch separately, never conflate)
mkdir -p "$WORKDIR/epoch-pkg"
cat > "$WORKDIR/epoch-pkg/PKGBUILD" <<'PB'
pkgname=epoch-pkg
pkgver=3.0.5
pkgrel=2
epoch=2
url=https://github.com/example/epoch-pkg
source=("https://github.com/example/epoch-pkg/archive/v${pkgver}.tar.gz")
sha256sums=('SKIP')
PB

note "lifecycle: epoch and pkgrel are parsed separately from pkgver"
run_check_mock epoch-pkg "$WORKDIR" MOCK_PROBE_GITHUB_JSON='{"tag_name":"v3.0.5"}' >/dev/null
if jq -e '.[0].current_version == "3.0.5" and .[0].current_epoch == "2" and .[0].current_release == "2"' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "epoch/pkgrel parsed separately"
else
  bad "epoch/pkgrel wrong: $(jq -c '.[0] | {v:.current_version,e:.current_epoch,r:.current_release}' "$WORKDIR/report.json")"
fi
if jq -e '.[0].update_type == "UP_TO_DATE"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "matching upstream tag is UP_TO_DATE (vercmp equal, not lexical)"
else
  bad "equal version not UP_TO_DATE: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi

note "lifecycle: newer upstream version is UPDATE_AVAILABLE"
run_check_mock epoch-pkg "$WORKDIR" MOCK_PROBE_GITHUB_JSON='{"tag_name":"v3.1.0"}' >/dev/null
if jq -e '.[0].update_type == "UPDATE_AVAILABLE" and .[0].upstream_version == "3.1.0"' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "newer upstream -> UPDATE_AVAILABLE with upstream_version"
else
  bad "update not detected: $(jq -c '.[0] | {t:.update_type,u:.upstream_version}' "$WORKDIR/report.json")"
fi
if jq -e '.[0].rebuild_required == true and .[0].recommended_action == "review PR proposal"' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "update marks rebuild_required + review action"
else
  bad "rebuild/recommendation flags wrong: $(jq -c '.[0] | {r:.rebuild_required,a:.recommended_action}' "$WORKDIR/report.json")"
fi

note "lifecycle: missing upstream (404) is UPSTREAM_UNAVAILABLE"
run_check_mock epoch-pkg "$WORKDIR" MOCK_PROBE_GITHUB_REPO_STATUS=404 >/dev/null
if jq -e '.[0].update_type == "UPSTREAM_UNAVAILABLE"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "missing upstream -> UPSTREAM_UNAVAILABLE"
else
  bad "404 not classified UPSTREAM_UNAVAILABLE: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi
if jq -e '.[0].upstream_version == ""' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "no upstream version invented on unavailable upstream"
else
  bad "upstream version invented: $(jq -r '.[0].upstream_version' "$WORKDIR/report.json")"
fi

note "lifecycle: archived upstream is UPSTREAM_ARCHIVED"
run_check_mock epoch-pkg "$WORKDIR" MOCK_PROBE_GITHUB_REPO_JSON='{"archived":true}' >/dev/null
if jq -e '.[0].update_type == "UPSTREAM_ARCHIVED"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "archived upstream -> UPSTREAM_ARCHIVED"
else
  bad "archived not classified: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi

note "lifecycle: rate-limited/empty upstream is CHECK_FAILED, never an update"
run_check_mock epoch-pkg "$WORKDIR" MOCK_PROBE_GITHUB_REPO_JSON='{}' MOCK_PROBE_GITHUB_JSON='[]' >/dev/null
if jq -e '.[0].update_type == "CHECK_FAILED"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "empty upstream metadata -> CHECK_FAILED"
else
  bad "empty metadata misclassified: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi

note "lifecycle: pinned VCS commit ahead of upstream HEAD is SOURCE_CHANGED"
mkdir -p "$WORKDIR/pinned-pkg"
cat > "$WORKDIR/pinned-pkg/PKGBUILD" <<'PB'
pkgname=pinned-pkg
pkgver=1.0
pkgrel=1
url=https://github.com/example/pinned-pkg
source=("git+https://github.com/example/pinned-pkg.git#commit=aaaaaaa")
sha256sums=('SKIP')
PB
run_check_mock pinned-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	HEAD
aaaaaaa0000000000000000000000000000000	refs/heads/main' >/dev/null
if jq -e '.[0].update_type == "SOURCE_CHANGED"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "pinned commit behind HEAD -> SOURCE_CHANGED (no version invented)"
else
  bad "pinned commit misclassified: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi
run_check_mock pinned-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='aaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	HEAD' >/dev/null
if jq -e '.[0].update_type == "UP_TO_DATE"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "pinned commit matching HEAD prefix -> UP_TO_DATE"
else
  bad "matching pinned commit misclassified: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi

note "lifecycle: package type classification (stable/vcs/binary/local/xlibre)"
mkdir -p "$WORKDIR/vcs-pkg-git"
cat > "$WORKDIR/vcs-pkg-git/PKGBUILD" <<'PB'
pkgname=vcs-pkg-git
pkgver=1.0
pkgrel=1
url=https://github.com/example/vcs-pkg-git
source=("git+https://github.com/example/vcs-pkg-git.git")
sha256sums=('SKIP')
PB
run_check_mock vcs-pkg-git "$WORKDIR" MOCK_PROBE_GIT_REFS='aaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	HEAD' >/dev/null
if jq -e '.[0].package_type == "vcs"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "-git/-hg/-svn style name typed vcs"
else
  bad "vcs typing wrong: $(jq -r '.[0].package_type' "$WORKDIR/report.json")"
fi
run_check_mock epoch-pkg "$WORKDIR" MOCK_PROBE_GITHUB_JSON='{"tag_name":"v3.0.5"}' >/dev/null
if jq -e '.[0].package_type == "stable"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "plain name typed stable"
else
  bad "stable typing wrong: $(jq -r '.[0].package_type' "$WORKDIR/report.json")"
fi

note "lifecycle: schema is complete and self-consistent"
run_check_mock epoch-pkg "$WORKDIR" MOCK_PROBE_GITHUB_JSON='{"tag_name":"v3.1.0"}' >/dev/null
if jq -e '.[0] | has("package") and has("current_version") and has("current_epoch")
      and has("current_release") and has("upstream_version") and has("upstream_url")
      and has("update_type") and has("package_type") and has("source_kind")
      and has("source_reference") and has("rebuild_required") and has("risk_level")
      and has("recommended_action") and has("probe_ok") and has("checked_at") and has("note")' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "lifecycle schema complete"
else
  bad "lifecycle schema incomplete: $(jq -c '.[0]' "$WORKDIR/report.json")"
fi
if jq -e '.[0].checked_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "checked_at is a UTC timestamp"
else
  bad "checked_at missing/malformed: $(jq -r '.[0].checked_at' "$WORKDIR/report.json")"
fi
if jq -e '.[0].probe_ok == true' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "probe_ok=true for a successful probe"
else
  bad "probe_ok wrong: $(jq -r '.[0].probe_ok' "$WORKDIR/report.json")"
fi

note "lifecycle: discovery from packages.txt (no hardcoded package count)"
# discovery must read the real packages.txt and include local: entries.
# Probes are mocked so the check is offline and deterministic.
rc=0
env -i PATH="$PATH" HOME="$HOME" GITHUB_WORKSPACE="$REPO_ROOT" \
  MOCK_PROBE_GITHUB_REPO_JSON='{}' MOCK_PROBE_GITHUB_JSON='[]' \
  MOCK_PROBE_GIT_REFS='1111111111111111111111111111111111111111	HEAD' \
  bash "$REPO_ROOT/.github/scripts/check-updates.sh" --json "$WORKDIR/discover.json" --timeout 2 \
  > "$WORKDIR/discover.log" 2>&1 || rc=$?
expected_count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  t="$(echo "$line" | sed 's/#.*//' | xargs)"
  [[ -z "$t" ]] && continue
  expected_count=$(( expected_count + 1 ))
done < "$REPO_ROOT/packages.txt"
# entries whose package directory is missing are skipped by the checker
missing_dirs=$(awk 'NF && $0 !~ /^#/ {print $1}' "$REPO_ROOT/packages.txt" | while read -r p; do p="${p#local:}"; [ -d "$REPO_ROOT/$p" ] || echo x; done | wc -l)
expected_count=$(( expected_count - missing_dirs ))
got_count=$(jq 'length' "$WORKDIR/discover.json" 2>/dev/null || echo 0)
if [[ "$got_count" -eq "$expected_count" && "$got_count" -gt 0 ]]; then
  ok "discovered $got_count/$expected_count packages from packages.txt"
else
  bad "discovery mismatch: got $got_count expected $expected_count (rc=$rc)"
fi
if jq -e 'any(.[]; .package_type == "local")' "$WORKDIR/discover.json" >/dev/null 2>&1; then
  ok "local: packages discovered with type=local"
else
  bad "no local: package discovered: $(jq -r '[.[].package_type] | unique | join(",")' "$WORKDIR/discover.json")"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
