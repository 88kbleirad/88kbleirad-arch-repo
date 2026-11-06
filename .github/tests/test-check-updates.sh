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

# ---------------------------------------------------------------------------
note "update detection: missing vercmp dependency fails closed with rc 2"
# The detector MUST refuse to run when vercmp is unavailable (this is the
# live runner failure mode on Ubuntu hosts without the `makepkg` package).
NOBIN="$WORKDIR/nobin"
mkdir -p "$NOBIN"
BASH_BIN="$(command -v bash)"
rc=0
# PATH contains only an empty directory: vercmp (and every other external
# tool) is unreachable, which is exactly the missing-dependency case.
env -i PATH="$NOBIN" HOME="$HOME" GITHUB_WORKSPACE="$WORKDIR" \
  "$BASH_BIN" "$REPO_ROOT/.github/scripts/check-updates.sh" epoch-pkg \
  --json "$WORKDIR/nover-report.json" --timeout 2 \
  > "$WORKDIR/nover.log" 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  ok "checker exits 2 when vercmp is missing"
else
  bad "expected rc 2 without vercmp, got $rc"
fi
if [[ ! -s "$WORKDIR/nover-report.json" ]]; then
  ok "no report is produced without vercmp"
else
  bad "report was produced without vercmp"
fi

note "update detection: full vercmp comparison smoke (epoch/pkgver/pkgrel)"
# Arch semantics: epoch dominates, then pkgver, then pkgrel — never lexical.
if [[ "$(vercmp 2:3.0.5-2 1:4.0.0-1)" == "1" ]]; then
  ok "epoch dominates comparison"
else
  bad "epoch comparison failed"
fi
if [[ "$(vercmp 1:1.0.0-10 1:1.0.0-2)" == "1" ]]; then
  ok "pkgrel compares numerically"
else
  bad "pkgrel comparison failed"
fi
if [[ "$(vercmp 1:1.0rc1-1 1:1.0.0-1)" == "-1" ]]; then
  ok "prerelease < release (non-lexical)"
else
  bad "prerelease comparison failed"
fi
if [[ "$(vercmp 1:20240101-1 1:2024.01-1)" == "1" ]]; then
  ok "numeric forms compare by value"
else
  bad "numeric form comparison failed"
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
run_check_mock epoch-pkg "$WORKDIR" \
  MOCK_PROBE_GITHUB_REPO_JSON='{}' \
  MOCK_PROBE_GITHUB_JSON='{"tag_name":"v3.0.5"}' >/dev/null
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
run_check_mock epoch-pkg "$WORKDIR" \
  MOCK_PROBE_GITHUB_REPO_JSON='{}' \
  MOCK_PROBE_GITHUB_JSON='{"tag_name":"v3.1.0"}' >/dev/null
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
run_check_mock epoch-pkg "$WORKDIR" \
  MOCK_PROBE_GITHUB_REPO_JSON='{}' \
  MOCK_PROBE_GITHUB_JSON='{"tag_name":"v3.0.5"}' >/dev/null
if jq -e '.[0].package_type == "stable"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "plain name typed stable"
else
  bad "stable typing wrong: $(jq -r '.[0].package_type' "$WORKDIR/report.json")"
fi

note "lifecycle: schema is complete and self-consistent"
run_check_mock epoch-pkg "$WORKDIR" \
  MOCK_PROBE_GITHUB_REPO_JSON='{}' \
  MOCK_PROBE_GITHUB_JSON='{"tag_name":"v3.1.0"}' >/dev/null
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

# ---------------------------------------------------------------------------
note "lifecycle: large VCS ref list produces no broken pipe (regression)"
# The previous `printf | awk '...exit'` pipeline died with EPIPE (exit 1)
# on large ref lists: awk exits after the first HEAD line while printf is
# still writing, and `set -o pipefail` propagates the failure. The live
# failure happens with real `git ls-remote` output, which can be far larger
# than an environment variable can carry — so this regression builds a real
# local bare repository with tens of thousands of refs and feeds it through
# the actual git_ls_remote() (no mock, no network, no env-size limit).
FAKE_REPO="$WORKDIR/fake-git-repo.git"
git init --bare -q "$FAKE_REPO"
# build one real commit object (offline; no date/environment dependence)
BLOB="$(printf 'content' | git -C "$FAKE_REPO" hash-object -w --stdin)"
TREE="$(printf '100644 blob %s	file
' "$BLOB" | git -C "$FAKE_REPO" mktree)"
OBJID="$(printf 'tree %s
author T <t@t> 0 +0000\ncommitter T <t@t> 0 +0000\n\ninit\n' "$TREE" | git -C "$FAKE_REPO" hash-object -t commit -w --stdin)"
i=0
while (( i < 20000 )); do
  git -C "$FAKE_REPO" update-ref "refs/tags/v1.$(( i / 1000 )).$(( i % 1000 ))" "$OBJID"
  i=$(( i + 1 ))
done
git -C "$FAKE_REPO" symbolic-ref HEAD refs/heads/main
git -C "$FAKE_REPO" update-ref refs/heads/main "$OBJID"
REF_COUNT="$(git -C "$FAKE_REPO" show-ref | wc -l)"
mkdir -p "$WORKDIR/large-vcs-pkg"
cat > "$WORKDIR/large-vcs-pkg/PKGBUILD" <<PB
pkgname=large-vcs-pkg
pkgver=r1.g44444444
pkgrel=1
url=https://github.com/example/large-vcs-pkg
source=("git+file://${WORKDIR}/fake-git-repo.git")
sha256sums=('SKIP')
PB
# the heredoc above REQUIRES expansion so the fixture points at the local
# repository (an unexpanded \${WORKDIR} would silently use a non-existent
# path and the test would pass for the wrong reason)
grep -q "file://${WORKDIR}/fake-git-repo.git" "$WORKDIR/large-vcs-pkg/PKGBUILD" \
  || { echo "FATAL: fixture PKGBUILD was not expanded" >&2; exit 1; }
rc=$(run_check_mock large-vcs-pkg "$WORKDIR")
if [[ "$rc" -eq 0 ]]; then
  ok "large VCS ref list ($REF_COUNT refs) handled without broken pipe (rc=0)"
else
  bad "large VCS ref list failed with rc=$rc (broken pipe regression)"
fi
if jq -e '.[0].update_type == "SOURCE_CHANGED" and .[0].source_reference != ""' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "branch HEAD SHA extracted from the large ref list"
else
  bad "large ref list misparsed: $(jq -c '.[0] | {u:.update_type, r:.source_reference}' "$WORKDIR/report.json")"
fi

note "lifecycle: HEAD absent -> master/main fallback still works (large list)"
# regenerate a fake repo without a symbolic HEAD (only refs/heads/main plus
# tens of thousands of tags) — exercises the second (fallback) scan
FAKE_REPO2="$WORKDIR/fake-git-repo2.git"
git init --bare -q "$FAKE_REPO2"
BLOB2="$(printf 'content2' | git -C "$FAKE_REPO2" hash-object -w --stdin)"
TREE2="$(printf '100644 blob %s\tfile\n' "$BLOB2" | git -C "$FAKE_REPO2" mktree)"
OBJID2="$(printf 'tree %s\nauthor T <t@t> 0 +0000\ncommitter T <t@t> 0 +0000\n\nmain\n' "$TREE2" | git -C "$FAKE_REPO2" hash-object -t commit -w --stdin)"
i=0
while (( i < 20000 )); do
  git -C "$FAKE_REPO2" update-ref "refs/tags/v9.$(( i % 997 ))" "$OBJID2"
  i=$(( i + 1 ))
done
BLOB2="$(printf 'content2' | git -C "$FAKE_REPO2" hash-object -w --stdin)"
TREE2="$(printf '100644 blob %s	file
' "$BLOB2" | git -C "$FAKE_REPO2" mktree)"
MAIN_SHA="$(printf 'tree %s
author T <t@t> 0 +0000\ncommitter T <t@t> 0 +0000\n\nmain\n' "$TREE2" | git -C "$FAKE_REPO2" hash-object -t commit -w --stdin)"
git -C "$FAKE_REPO2" update-ref refs/heads/main "$MAIN_SHA"
sed "s#fake-git-repo.git#fake-git-repo2.git#" \
  "$WORKDIR/large-vcs-pkg/PKGBUILD" > "$WORKDIR/large-vcs-pkg/PKGBUILD.tmp"
mv "$WORKDIR/large-vcs-pkg/PKGBUILD.tmp" "$WORKDIR/large-vcs-pkg/PKGBUILD"
grep -q "file://${WORKDIR}/fake-git-repo2.git" "$WORKDIR/large-vcs-pkg/PKGBUILD" \
  || { echo "FATAL: fallback fixture PKGBUILD was not rewritten" >&2; exit 1; }
rc=$(run_check_mock large-vcs-pkg "$WORKDIR")
if [[ "$rc" -eq 0 ]]; then
  ok "master/main fallback parsing survives a large ref list"
else
  bad "fallback parsing failed rc=$rc"
fi
if jq -e ".[0].source_reference == \"$MAIN_SHA\"" \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "main branch SHA extracted from the large list"
else
  bad "main SHA not extracted: $(jq -r '.[0].source_reference' "$WORKDIR/report.json")"
fi

# ---------------------------------------------------------------------------
note "lifecycle: PKGBUILD source parsing — variable expansion, quotes, VCS fragments"
# exact fixtures mirroring the live CHECK_FAILED packages:
#   lua-pam-git:   url="https://github.com/RMTT/${_gitname}"; source=("git+${url}.git")
#   opendoas-cpp:  source=("git+${url}.git") with _gitname defined
#   picom:         source=(git+"https://github.com/nhktmdzhg/${_gitname}.git#branch=next")
#   snapper:       source=(git+"https://github.com/jrabinow/snapper-rollback.git")
mkdir -p "$WORKDIR/var-git-pkg"
cat > "$WORKDIR/var-git-pkg/PKGBUILD" <<'PB'
pkgname=var-git-pkg
pkgver=r10.abcdef123
pkgrel=1
_gitname=lua-pam
url="https://github.com/RMTT/${_gitname}"
source=("git+${url}.git")
sha256sums=(SKIP)
PB
run_check_mock var-git-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='aabbccddeeff00112233445566778899aabbccdd	HEAD' >/dev/null
if jq -e '.[0].upstream_url == "https://github.com/RMTT/lua-pam.git" and .[0].source_kind == "git"' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "nested \${_gitname} expanded through url into git+ source"
else
  bad "nested var source misparsed: $(jq -c '.[0] | {u:.upstream_url,k:.source_kind}' "$WORKDIR/report.json")"
fi

mkdir -p "$WORKDIR/qgit-pkg"
cat > "$WORKDIR/qgit-pkg/PKGBUILD" <<'PB'
pkgname=qgit-pkg
pkgver=r20.393845c
pkgrel=1
_gitname=picom
url="https://github.com/nhktmdzhg/${_gitname}"
source=(git+"https://github.com/nhktmdzhg/${_gitname}.git#branch=next")
sha256sums=('SKIP')
PB
run_check_mock qgit-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='393845cf3ed0e0000bfe57fe1b9ad75748e2547f	HEAD
393845cf3ed0e0000bfe57fe1b9ad75748e2547f	refs/heads/next' >/dev/null
if jq -e '.[0].upstream_url == "https://github.com/nhktmdzhg/picom.git#branch=next" and .[0].source_kind == "git"' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "git+\"URL#branch=...\" form parses (quote after git+ stripped, fragment kept)"
else
  bad "git+ quote form misparsed: $(jq -c '.[0] | {u:.upstream_url,k:.source_kind}' "$WORKDIR/report.json")"
fi
if jq -e '.[0].update_type == "UP_TO_DATE"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "pinned branch with matching HEAD classification works"
else
  bad "qgit branch probe wrong: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi

mkdir -p "$WORKDIR/signed-git-pkg"
cat > "$WORKDIR/signed-git-pkg/PKGBUILD" <<'PB'
pkgname=signed-git-pkg
pkgver=7.1.0.r9.g54d9411
pkgrel=5
_commit=663941f641595667f4e21052ea54060414bfeec3
source=("git+https://github.com/CachyOS/pacman.git?signed#commit=${_commit}")
sha256sums=('330bdf5660e0c0de4e6c1eed60e4391f77afacc3657a3023391f1deca143d97a')
PB
run_check_mock signed-git-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='663941f641595667f4e21052ea54060414bfeec3	HEAD' >/dev/null
if jq -e '.[0].upstream_url == "https://github.com/CachyOS/pacman.git?signed#commit=663941f641595667f4e21052ea54060414bfeec3" and .[0].source_kind == "git"' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "signed git source (?signed#commit=...) parses"
else
  bad "signed git source misparsed: $(jq -c '.[0] | {u:.upstream_url,k:.source_kind}' "$WORKDIR/report.json")"
fi
if jq -e '.[0].update_type == "UP_TO_DATE"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "signed git probe targets repo URL without ?signed; pinned commit matches"
else
  bad "signed git probe wrong: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi

# ---------------------------------------------------------------------------
note "lifecycle: git probe failure classification (missing / network / auth)"
mkdir -p "$WORKDIR/missing-git-pkg"
cat > "$WORKDIR/missing-git-pkg/PKGBUILD" <<'PB'
pkgname=missing-git-pkg
pkgver=1.0
pkgrel=1
source=("git+https://github.com/example/does-not-exist.git")
sha256sums=('SKIP')
PB
run_check_mock missing-git-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='' MOCK_PROBE_GIT_ERROR=missing >/dev/null
if jq -e '.[0].update_type == "UPSTREAM_UNAVAILABLE"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "missing git repo -> UPSTREAM_UNAVAILABLE (not CHECK_FAILED)"
else
  bad "missing git repo misclassified: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi
run_check_mock missing-git-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='' MOCK_PROBE_GIT_ERROR=timed_out >/dev/null
if jq -e '.[0].update_type == "CHECK_FAILED" and .[0].probe_error == "timed_out"' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "transient git failure -> CHECK_FAILED with probe_error"
else
  bad "git failure classification wrong: $(jq -c '.[0] | {t:.update_type,e:.probe_error}' "$WORKDIR/report.json")"
fi

# ---------------------------------------------------------------------------
note "lifecycle: npm metadata failures are classified (404 vs transient)"
mkdir -p "$WORKDIR/npm-pkg"
cat > "$WORKDIR/npm-pkg/PKGBUILD" <<'PB'
pkgname=npm-pkg
pkgver=7.0.0
pkgrel=1
source=("https://registry.npmjs.org/npm-pkg/-/npm-pkg-7.0.0.tgz")
sha256sums=('8fa01c78bdf5e1ed8b86c3db50b13c69a1066ccb8f79d4478f5d7bfcdccf76aba05cada0d55ac0ec6f2e27b20df8dc6eaa4a9bc10a62b61fdab447efb46b4bcf')
PB
run_check_mock npm-pkg "$WORKDIR" MOCK_PROBE_NPM_STATUS=404 >/dev/null
if jq -e '.[0].update_type == "UPSTREAM_UNAVAILABLE"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "npm 404 -> UPSTREAM_UNAVAILABLE"
else
  bad "npm 404 misclassified: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi
run_check_mock npm-pkg "$WORKDIR" MOCK_PROBE_NPM_STATUS=403 >/dev/null
if jq -e '.[0].update_type == "CHECK_FAILED" and (.[0].note | contains("403"))' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "npm 403 -> CHECK_FAILED (rate limit/auth), never an update"
else
  bad "npm 403 misclassified: $(jq -c '.[0] | {t:.update_type,n:.note}' "$WORKDIR/report.json")"
fi
run_check_mock npm-pkg "$WORKDIR" MOCK_PROBE_NPM_JSON='{"version":"8.0.0"}' >/dev/null
if jq -e '.[0].update_type == "UPDATE_AVAILABLE" and .[0].upstream_version == "8.0.0" and .[0].probe_ok == true' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "npm metadata probe returns latest version"
else
  bad "npm success probe wrong: $(jq -c '.[0] | {t:.update_type,u:.upstream_version,p:.probe_ok}' "$WORKDIR/report.json")"
fi

# ---------------------------------------------------------------------------
note "lifecycle: GitHub repository redirects are MANUAL_REVIEW"
mkdir -p "$WORKDIR/redirect-pkg"
cat > "$WORKDIR/redirect-pkg/PKGBUILD" <<'PB'
pkgname=redirect-pkg
pkgver=0.2.1
pkgrel=5
url="https://github.com/storytold/printcraft"
source=("https://github.com/storytold/printcraft/archive/refs/tags/v0.2.1/$pkgname-$pkgver.tar.gz")
sha256sums=('db39eb513b0652e32f5456cb4bb0ecc2df2ff0bb62355a834d840d2ebc0cd02f')
PB
run_check_mock redirect-pkg "$WORKDIR" MOCK_PROBE_GITHUB_REPO_JSON='{"archived":false,"full_name":"storytold/pdfcraft"}' \
  MOCK_PROBE_GITHUB_REPO_STATUS=200 >/dev/null
if jq -e '.[0].update_type == "MANUAL_REVIEW" and (.[0].note | contains("redirected"))' \
    "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "redirected repo -> MANUAL_REVIEW (identity cannot be assumed)"
else
  bad "redirect not classified MANUAL_REVIEW: $(jq -c '.[0] | {t:.update_type,n:.note}' "$WORKDIR/report.json")"
fi

# ---------------------------------------------------------------------------
note "lifecycle: abbreviated pkgver SHA vs full upstream HEAD (false-positive fix)"
mkdir -p "$WORKDIR/abbrev-pkg"
cat > "$WORKDIR/abbrev-pkg/PKGBUILD" <<'PB'
pkgname=abbrev-pkg
pkgver=r20.393845c
pkgrel=2
url="https://github.com/catppuccin/fcitx5"
source=("${pkgname}::git+https://github.com/catppuccin/fcitx5.git")
sha256sums=('SKIP')
PB
# upstream HEAD equals the recorded abbreviated SHA (8 chars)
run_check_mock abbrev-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='393845cf3ed0e0000bfe57fe1b9ad75748e2547f	HEAD' >/dev/null
if jq -e '.[0].update_type == "UP_TO_DATE"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "abbreviated pkgver SHA matching upstream HEAD -> UP_TO_DATE (not SOURCE_CHANGED)"
else
  bad "abbreviated match misclassified: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi
# upstream HEAD differs
run_check_mock abbrev-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='9999999999999999999999999999999999999999	HEAD' >/dev/null
if jq -e '.[0].update_type == "SOURCE_CHANGED"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "differing HEAD -> SOURCE_CHANGED"
else
  bad "real HEAD change misclassified: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
fi
# pkgver without any sha (e.g. date-based) => MANUAL_REVIEW, never assert rebuild
mkdir -p "$WORKDIR/nosha-pkg"
cat > "$WORKDIR/nosha-pkg/PKGBUILD" <<'PB'
pkgname=nosha-pkg
pkgver=2026.09.09
pkgrel=1
source=("git+https://github.com/example/nosha.git")
sha256sums=('SKIP')
PB
run_check_mock nosha-pkg "$WORKDIR" MOCK_PROBE_GIT_REFS='aabbccddeeff00112233445566778899aabbccdd	HEAD' >/dev/null
if jq -e '.[0].update_type == "MANUAL_REVIEW"' "$WORKDIR/report.json" >/dev/null 2>&1; then
  ok "unrecoverable pkgver revision -> MANUAL_REVIEW (never SOURCE_CHANGED)"
else
  bad "nosha pkgver misclassified: $(jq -r '.[0].update_type' "$WORKDIR/report.json")"
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
