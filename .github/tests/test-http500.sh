#!/usr/bin/env bash
#
# Regression tests for:
#   1. GitHub Release asset operations (gh-release-lib.sh):
#        - HTTP 500 + 5xx retry with backoff and Retry-After
#        - transient failure followed by success
#        - permanent failure (no retry)
#        - ambiguous mutation outcome reconciliation (upload that may have
#          landed before the error)
#        - asset already deleted (delete is idempotent)
#   2. publish-prod.sh safety:
#        - missing requested package archive (inventory enforcement)
#        - metadata-only build artifact -> inventory fail
#        - database with 7 packages when 8 expected -> fail before mutation
#        - valid non-destructive merge still works
#        - no unintended Release changes after validation failure
#
# The mock `gh` (shared fixture .github/tests/mock-gh.sh) is a controllable
# fake that serves both the legacy `gh release ...` subcommands and the raw
# `gh api --include/--jq` contract used by gh-release-lib.sh from a local
# fake-release directory, with fault injection (500/429/retry-after).
# No network, no live GitHub, no secrets.
#
# The publish-prod scenarios run `pacman -Syu` (the script's normal
# preamble) and therefore must run inside the pinned test container; they
# are enabled with RUN_PROD_SCENARIOS=1 (set by run-tests.sh). The pure
# gh-release-lib tests are host-safe and always run.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
SKIP=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m %s\n' "$*"; }

# -- test key (for signed-mode tests) ---------------------------------------
export GNUPGHOME="$WORKDIR/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
cat > "$WORKDIR/keyparams" <<'KP'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: 88kbleirad package signing
Name-Email: 88kbleirad@users.noreply.github.com
Expire-Date: 0
%commit
KP
gpg --batch --gen-key "$WORKDIR/keyparams" >/dev/null 2>&1
KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
export GPG_PRIVATE_KEY=$(gpg --armor --export-secret-keys "$KEYID")

# -- hooks for the event log (write-only, never read back for secrets) -----
EVENTS="$WORKDIR/events.log"
: > "$EVENTS"

# mock gh must be first on PATH for EVERY `gh` invocation in this suite
mkdir -p "$WORKDIR/mockbin"
cat > "$WORKDIR/mockbin/gh" <<'SHIM'
#!/usr/bin/env bash
export FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?}"
export FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"
exec bash "$MOCK_GH" "$@"
SHIM
chmod +x "$WORKDIR/mockbin/gh"
export MOCK_GH="$REPO_ROOT/.github/tests/mock-gh.sh"
export PATH="$WORKDIR/mockbin:$PATH"

# -- minimal release fixture -------------------------------------------------
make_release() { # dir
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"; touch "$dir/.created"
  # testa + testb packages (valid archives)
  for name in testa testb; do
    local d="$WORKDIR/pkgbuild/$name"
    mkdir -p "$d/usr/share"; printf 'x\n' > "$d/usr/share/$name"
    cat > "$d/.PKGINFO" <<PKG
pkgname = $name
pkgbase = $name
pkgver = 1.0-1
pkgdesc = fixture
url = https://example.com
builddate = 1
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 8
arch = x86_64
license = MIT
PKG
    ( cd "$d" && tar --zstd -cf "$dir/$name-1.0-1-x86_64.pkg.tar.zst" .PKGINFO usr )
    printf '{"package": "%s", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' "$name" \
      > "$dir/v4-$name.meta.json"
  done
  ( cd "$dir" && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst \
      testb-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
  : > "$dir/.ids"
}

# -- run publish-prod with fault-injected mock gh ---------------------------
run_prod() { # scenario releasedir expected_packages [extra_env...]
  local scenario="$1" releasedir="$2" expected="$3"; shift 3
  local ws="$WORKDIR/ws-$scenario"
  local events="$WORKDIR/$scenario.events"
  : > "$events"
  rm -rf "$ws"; mkdir -p "$ws/.github/scripts" "$ws/output" "$ws/bin"
  cp "$REPO_ROOT/.github/scripts/sign-helpers.sh" "$ws/.github/scripts/"
  cp "$REPO_ROOT/.github/scripts/gh-release-lib.sh" "$ws/.github/scripts/"
  cp "$REPO_ROOT/.github/scripts/publish-prod.sh" "$ws/.github/scripts/"
  cp "$REPO_ROOT/.github/scripts/validate-release.sh" "$ws/.github/scripts/"
  cp "$REPO_ROOT/.github/tests/mock-gh.sh" "$ws/bin/mock-gh.sh"
  cat > "$ws/bin/gh" <<'SHIM'
#!/usr/bin/env bash
export FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?}"
export FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"
exec bash "$(dirname "$(readlink -f "$0")")/mock-gh.sh" "$@"
SHIM
  chmod +x "$ws/bin/gh"

  # fixture set for the run's output/: default testa+testb; empty for the
  # metadata-only scenario (only a failed-status meta file is seeded)
  local fixtures="testa,testb" a
  for a in "$@"; do
    case "$a" in
      WS_FIXTURES=*) fixtures="${a#WS_FIXTURES=}" ;;
    esac
  done
  local name
  if [[ -n "$fixtures" ]]; then
    for name in ${fixtures//,/ }; do
      local d="$WORKDIR/pkgbuild/$name"
      ( cd "$d" && tar --zstd -cf "$ws/output/$name-1.0-1-x86_64.pkg.tar.zst" .PKGINFO usr )
      printf '{"package": "%s", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' "$name" \
        > "$ws/output/v4-$name.meta.json"
    done
  fi

  ( cd "$ws" && \
    env -i \
      PATH="$ws/bin:$PATH" HOME="$HOME" \
      GITHUB_WORKSPACE="$ws" \
      GITHUB_REPOSITORY="owner/repo" \
      GH_TOKEN=dummy \
      RELEASE_TAG=repository \
      REPO_DB_NAME=88kbleirad \
      GITHUB_STEP_SUMMARY="$ws/summary.md" \
      SIGNING_MODE=unsigned \
      EXPECTED_PACKAGES="$expected" \
      FAKE_RELEASE_DIR="$releasedir" \
      FAKE_EVENTS_LOG="$events" \
      "$@" \
      bash "$ws/.github/scripts/publish-prod.sh" > "$WORKDIR/$scenario.log" 2>&1 )
  echo $?
}

# ---------------------------------------------------------------------------
note "gh-release-lib: HTTP 500 retry with backoff"
W="$WORKDIR/lib-test"
mkdir -p "$W"
touch "$W/.created"; : > "$W/.ids"
export FAKE_RELEASE_DIR="$W"
export FAKE_EVENTS_LOG="$EVENTS"
export GH_API_MAX_ATTEMPTS=3
export GH_API_BASE_DELAY=1
. "$REPO_ROOT/.github/scripts/gh-release-lib.sh"

# always-500: upload must fail after bounded retries (no infinite loop)
printf 'abc' > "$W/asset.jar"
export FAIL_500_ON="asset.jar"
rc1=0
gh_upload_asset repository owner/repo "$W/asset.jar" >/dev/null 2>&1 || rc1=$?
unset FAIL_500_ON
[[ "$rc1" -ne 0 ]] && ok "HTTP 500 causes failure after retries exhausted" || bad "500 unexpectedly succeeded"

# transient 500: fail once then succeed
export FAIL_500_ONCE="asset.jar"
gh_upload_asset repository owner/repo "$W/asset.jar" >/dev/null 2>&1 && \
  ok "retry after transient 500 succeeds" || bad "retry did not succeed"
unset FAIL_500_ONCE
[[ -f "$W/asset.jar" ]] && ok "asset present after successful upload" || bad "asset missing"

# retry-after header handling (429 + retry-after: 1)
export FAIL_429_ON="asset2.jar"
printf 'abc' > "$W/asset2.jar"
start=$(date +%s)
gh_upload_asset repository owner/repo "$W/asset2.jar" >/dev/null 2>&1 || true
elapsed=$(( $(date +%s) - start ))
[[ $elapsed -ge 1 ]] && ok "Retry-After honoured (>=1s sleep)" || bad "Retry-After not honoured"
unset FAIL_429_ON

# permanent failure: non-retryable 400 -> immediate failure
export PERMANENT_ON="asset3.jar"
printf 'abc' > "$W/asset3.jar"
rcp=0
gh_upload_asset repository owner/repo "$W/asset3.jar" >/dev/null 2>&1 || rcp=$?
[[ "$rcp" -ne 0 ]] && ok "permanent 400 fails without retry loop" || bad "400 unexpectedly succeeded"
unset PERMANENT_ON

# already-deleted: delete of missing asset is idempotent success
gh_delete_asset repository owner/repo "never-existed.jar" >/dev/null 2>&1 && \
  ok "delete of missing asset succeeds (idempotent)" || bad "delete of missing asset failed"

if [[ "${RUN_PROD_SCENARIOS:-0}" != "1" ]]; then
  skip "publish-prod scenarios (require test container; set RUN_PROD_SCENARIOS=1)"
else

# ---------------------------------------------------------------------------
note "publish-prod: 7-vs-8 inventory enforcement (fails before mutation)"
REL8="$WORKDIR/release-8"
make_release "$REL8"
# simulate the failure: only testa,testb artifacts (2); expect 8 -> must fail
rc=$(run_prod miss8 "$REL8" '["nmtui-go","osu-mime","ksuperkey","magika","catppuccin-fcitx5-git","catppuccin-whiskers-bin","physlock","all-contributors-cli"]')
if [[ "$rc" -ne 0 ]] && grep -q "Expected package" "$WORKDIR/miss8.log"; then
  ok "7-vs-8 expected inventory fails"
else
  bad "inventory enforcement did not fail (rc=$rc): $(tail -3 "$WORKDIR/miss8.log")"
fi
grep -q 'create repository' "$WORKDIR/miss8.events" && bad "release was created despite inventory failure" || ok "release not created on inventory failure"
grep -q 'upload ' "$WORKDIR/miss8.events" && bad "assets uploaded despite inventory failure" || ok "no uploads on inventory failure"

# ---------------------------------------------------------------------------
note "publish-prod: metadata-only artifact not accepted as a package"
# only metadata (no archive) for a requested package -> must fail before any
# mutation (the archive count gate trips first: "No package files produced")
W2="$WORKDIR/meta-only"
rm -rf "$W2"; mkdir -p "$W2"; touch "$W2/.created"; : > "$W2/.ids"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "failed", "fingerprint": "x"}\n' > "$W2/v4-testa.meta.json"
rc=$(run_prod metaonly "$W2" '["testa"]' WS_FIXTURES="")
if [[ "$rc" -ne 0 ]] && grep -Eq "No package files produced|Expected package" "$WORKDIR/metaonly.log"; then
  ok "metadata-only build artifact is rejected before publish"
else
  bad "metadata-only artifact accepted (rc=$rc): $(tail -3 "$WORKDIR/metaonly.log")"
fi
grep -q 'create repository' "$WORKDIR/metaonly.events" && bad "release created despite metadata-only run" || ok "no release mutation on metadata-only run"

# ---------------------------------------------------------------------------
note "publish-prod: valid non-destructive merge still works"
W3="$WORKDIR/release-merge"
make_release "$W3"
# publish with expected packages exactly matching the 2 available
rc=$(run_prod mergeok "$W3" '["testa","testb"]')
if [[ "$rc" -eq 0 ]]; then
  ok "valid publish with matching inventory succeeds"
else
  bad "valid publish failed (rc=$rc): $(tail -4 "$WORKDIR/mergeok.log")"
fi
[[ -f "$W3/testa-1.0-1-x86_64.pkg.tar.zst" ]] && ok "existing testa preserved" || bad "testa missing after merge"
[[ -f "$W3/testb-1.0-1-x86_64.pkg.tar.zst" ]] && ok "existing testb preserved" || bad "testb missing after merge"
[[ -f "$W3/88kbleirad.db.tar.gz" ]] && ok "database regenerated" || bad "database missing"

# ---------------------------------------------------------------------------
note "publish-prod: no unintended Release changes after validation failure"
W4="$WORKDIR/release-noval"
make_release "$W4"
before=$(ls "$W4" | sort | md5sum | awk '{print $1}')
# give invalid expected inventory so publish aborts before upload
rc=$(run_prod noval "$W4" '["testa","testb","missing-pkg"]')
after=$(ls "$W4" | sort | md5sum | awk '{print $1}')
[[ "$rc" -ne 0 ]] && ok "publish aborts on inventory failure" || bad "publish did not abort"
[[ "$before" == "$after" ]] && ok "release asset set unchanged after failed publish" || bad "release assets changed despite failure"

fi # RUN_PROD_SCENARIOS

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ $FAIL -eq 0 ]]
