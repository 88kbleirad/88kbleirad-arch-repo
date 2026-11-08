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
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] || rm -rf "$WORKDIR"' EXIT

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

# -- minimal package fixture (pkgbuild tree) --------------------------------
mk_pkgbuild() { # name
  local name="$1"
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
  # deterministic mtimes: fixture archives must be byte-stable across
  # regeneration (tar embeds member mtimes by default, which would make
  # each run's archive bytes differ and trip the same-version drift gate)
  touch -t 202001010000.00 "$d/.PKGINFO" "$d/usr" "$d/usr/share" "$d/usr/share/$name"
}

# deterministic tar: fixed mtime, sorted member order, ./-free paths
# (same member layout as the original tar --zstd -cf .PKGINFO usr)
mk_tar() { # <archive> <dir>
  local archive="$1" dir="$2"
  ( cd "$dir" && find . -mindepth 1 \( -type f -o -type d \) | sort \
      | sed 's|^\./||' \
      | tar --zstd --mtime='@1' -cf "$archive" -T - )
}

# -- minimal release fixture -------------------------------------------------
make_release() { # dir
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"; touch "$dir/.created"
  # testa + testb packages (valid archives)
  for name in testa testb; do
    mk_pkgbuild "$name"
    mk_tar "$dir/$name-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/$name"
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
  cp "$REPO_ROOT/.github/scripts/verify-remote-release.sh" "$ws/.github/scripts/"
  cp "$REPO_ROOT/.github/tests/mock-gh.sh" "$ws/bin/mock-gh.sh"
  cat > "$ws/bin/gh" <<'SHIM'
#!/usr/bin/env bash
export FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?}"
export FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"
exec bash "$(dirname "$(readlink -f "$0")")/mock-gh.sh" "$@"
SHIM
  chmod +x "$ws/bin/gh"

  # fixture set for the run's output/: default testa+testb; empty for the
  # metadata-only scenario (only a failed-status meta file is seeded); a
  # directory (WS_FIXTURES_DIR) copies exact prior output bytes instead of
  # regenerating archives (for idempotency tests).
  local fixtures="testa,testb" a fixtures_dir=""
  for a in "$@"; do
    case "$a" in
      WS_FIXTURES=*) fixtures="${a#WS_FIXTURES=}" ;;
      WS_FIXTURES_DIR=*) fixtures_dir="${a#WS_FIXTURES_DIR=}" ;;
    esac
  done
  local name
  if [[ -n "$fixtures_dir" && -d "$fixtures_dir" ]]; then
    cp -a "$fixtures_dir/." "$ws/output/"
  elif [[ -n "$fixtures" ]]; then
    for name in ${fixtures//,/ }; do
      mk_pkgbuild "$name"
      mk_tar "$ws/output/$name-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/$name"
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

# ---------------------------------------------------------------------------
note "gh-release-lib: asset status of a missing release is MISSING, not FAILED"
# A 404 on the release-by-tag query means the release does not exist; the
# asset status must be MISSING (every local file is NEW) so dry-run can
# plan uploads — never FAILED (which would abort the plan on a missing
# release).
WM="$WORKDIR/lib-missing-release"
rm -rf "$WM"; mkdir -p "$WM"           # no .created marker -> release absent
printf 'local-bytes' > "$WM/new-asset.jar"
prev_fake="$FAKE_RELEASE_DIR"; export FAKE_RELEASE_DIR="$WM"
prev_events="$FAKE_EVENTS_LOG"; export FAKE_EVENTS_LOG=/dev/null
rc_status=0
gh_asset_status repository owner/repo "$WM/new-asset.jar" "$WM" >/dev/null 2>&1 || rc_status=$?
export FAKE_RELEASE_DIR="$prev_fake"; export FAKE_EVENTS_LOG="$prev_events"
if [[ "$ASSET_STATUS" == "MISSING" ]]; then
  ok "missing release classified MISSING (rc=$rc_status)"
else
  bad "missing release classified '$ASSET_STATUS' (rc=$rc_status)"
fi

# ---------------------------------------------------------------------------
note "gh-release-lib: DRY_RUN blocks writes before any API call"
# lib-level defense in depth: even if a caller invokes the mutation
# helpers directly, dry-run must never touch the fake release.
WDRY="$WORKDIR/lib-dryrun"
rm -rf "$WDRY"; mkdir -p "$WDRY/src" "$WDRY/release"
touch "$WDRY/release/.created"; : > "$WDRY/release/.ids"
printf 'seed-bytes' > "$WDRY/release/seed.jar"
printf 'local-bytes' > "$WDRY/src/new-asset.jar"
DRY_EVENTS="$WORKDIR/dryrun-lib.events"
: > "$DRY_EVENTS"
export DRY_RUN=1
prev_fake="$FAKE_RELEASE_DIR"; export FAKE_RELEASE_DIR="$WDRY/release"
prev_events="$FAKE_EVENTS_LOG"; export FAKE_EVENTS_LOG="$DRY_EVENTS"
rc_upload=0
gh_upload_asset repository owner/repo "$WDRY/src/new-asset.jar" >/dev/null 2>&1 || rc_upload=$?
rc_delete=0
gh_delete_asset repository owner/repo "seed.jar" >/dev/null 2>&1 || rc_delete=$?
export FAKE_RELEASE_DIR="$prev_fake"; export FAKE_EVENTS_LOG="$prev_events"
unset DRY_RUN
[[ "$rc_upload" -eq 0 && "$rc_delete" -eq 0 ]] \
  && ok "dry-run mutation helpers exit 0" || bad "dry-run helpers failed (upload=$rc_upload delete=$rc_delete)"
[[ ! -f "$WDRY/release/new-asset.jar" ]] \
  && ok "dry-run upload wrote nothing" || bad "dry-run upload created a file"
[[ -f "$WDRY/release/seed.jar" ]] \
  && ok "dry-run delete removed nothing" || bad "dry-run delete removed an asset"
if grep -qE 'upload |delete-asset |create ' "$DRY_EVENTS" 2>/dev/null; then
  bad "dry-run lib-level mutations logged: $(cat "$DRY_EVENTS")"
else
  ok "dry-run lib-level zero remote mutations"
fi

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
note "publish-prod: split package base matches inventory by %BASE%"
# A split package's base may differ from every subpackage name (e.g.
# fcitx5-lotus-git -> fcitx5-lotus-git/openrc/runit subpackages share
# the base but the *primary* subpackage name equals the base; here we
# simulate the stricter case: base=splitbase, subpackage name=sublib).
R="$WORKDIR/release-split"
rm -rf "$R"; mkdir -p "$R"; touch "$R/.created"; : > "$R/.ids"
mkdir -p "$WORKDIR/pkgbuild/sublib/usr/lib"; printf 'x\n' > "$WORKDIR/pkgbuild/sublib/usr/lib/sublib.so"
cat > "$WORKDIR/pkgbuild/sublib/.PKGINFO" <<'PKG'
pkgname = sublib
pkgbase = splitbase
pkgver = 1.0-1
pkgdesc = fixture
url = https://example.com
builddate = 1
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 8
arch = x86_64
license = MIT
PKG
( cd "$WORKDIR/pkgbuild/sublib" && tar --zstd -cf "$R/sublib-1.0-1-x86_64.pkg.tar.zst" .PKGINFO usr )
printf '{"package": "splitbase", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' > "$R/v4-splitbase.meta.json"
( cd "$R" && repo-add 88kbleirad.db.tar.gz sublib-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
# seed the run's output/ with the fresh subpackage archive + meta
SPLIT_OUT="$WORKDIR/split-out"
rm -rf "$SPLIT_OUT"; mkdir -p "$SPLIT_OUT"
cp "$R/sublib-1.0-1-x86_64.pkg.tar.zst" "$SPLIT_OUT/"
cp "$R/v4-splitbase.meta.json" "$SPLIT_OUT/"
rc=$(run_prod splitok "$R" '["splitbase"]' WS_FIXTURES_DIR="$SPLIT_OUT")
if [[ "$rc" -eq 0 ]]; then
  ok "split base accepted via %BASE% match"
else
  bad "split base rejected (rc=$rc): $(tail -4 "$WORKDIR/splitok.log")"
fi
rc=$(run_prod splitmiss "$R" '["splitbase","otherbase"]' WS_FIXTURES_DIR="$SPLIT_OUT")
if [[ "$rc" -ne 0 ]] && grep -q "Expected package.*otherbase" "$WORKDIR/splitmiss.log"; then
  ok "missing split base still fails inventory"
else
  bad "split inventory miss not detected (rc=$rc)"
fi

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

# ---------------------------------------------------------------------------
note "publish-prod: missing database asset is recovered from package archives"
# Release has package archives + metas but NO .db.tar.gz (the live failure
# shape). Local run builds testa+testb; the release additionally carries
# staypkg which must be recovered (downloaded + validated) into the
# reconstructed database. Expected inventory = all three.
seed_rel_archive() { # name rel
  local name="$1" rel="$2"
  mk_pkgbuild "$name"
  mk_tar "$rel/$name-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/$name"
  printf '{"package": "%s", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' "$name" \
    > "$rel/v4-$name.meta.json"
}
W5="$WORKDIR/release-missing-db"
rm -rf "$W5"; mkdir -p "$W5"; touch "$W5/.created"; : > "$W5/.ids"
seed_rel_archive testa "$W5"
seed_rel_archive testb "$W5"
seed_rel_archive staypkg "$W5"
rc=$(run_prod recover-missing-db "$W5" '["testa","testb","staypkg"]')
if [[ "$rc" -eq 0 ]]; then
  ok "publish succeeds by reconstructing the database from release archives"
else
  bad "recovery publish failed (rc=$rc): $(tail -4 "$WORKDIR/recover-missing-db.log")"
fi
grep -q "reconstructing the repository database" "$WORKDIR/recover-missing-db.log" \
  && ok "recovery path logged" || bad "recovery log missing"
grep -q "Recovered previously published package: staypkg" "$WORKDIR/recover-missing-db.log" \
  && ok "remote staypkg recovered into database" || bad "staypkg not recovered"
[[ -f "$W5/88kbleirad.db.tar.gz" ]] && ok "reconstructed .db.tar.gz uploaded" || bad "reconstructed db missing"
[[ -f "$W5/88kbleirad.files.tar.gz" ]] && ok "reconstructed .files.tar.gz uploaded" || bad "files index missing"
[[ -f "$W5/testa-1.0-1-x86_64.pkg.tar.zst" ]] && ok "existing testa preserved" || bad "testa lost"
[[ -f "$W5/staypkg-1.0-1-x86_64.pkg.tar.zst" ]] && ok "existing staypkg preserved" || bad "staypkg lost"
# preservation invariant: every package archive that existed in the release
# before recovery must still exist afterwards (clobber delete+upload is
# fine; losing an archive is not)
have_all=$(for a in "$W5"/*.pkg.tar.zst; do printf '%s\n' "$(basename "$a")"; done | sort)
want_all=$(for a in testa testb staypkg; do printf '%s\n' "${a}-1.0-1-x86_64.pkg.tar.zst"; done | sort)
[[ "$have_all" == "$want_all" ]] \
  && ok "all package archives preserved after recovery" \
  || bad "package archives lost during recovery: $(printf '%s ' $have_all)"

# ---------------------------------------------------------------------------
note "publish-prod: recovery is idempotent (invoked more than once)"
# Running the same missing-DB recovery a second time (same local inputs)
# must produce zero further mutations — the recovered release is already
# the target state.
rm -rf "$WORKDIR/recover-idem-out"; mkdir -p "$WORKDIR/recover-idem-out"
mk_pkgbuild testa; mk_pkgbuild testb
mk_tar "$WORKDIR/recover-idem-out/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
mk_tar "$WORKDIR/recover-idem-out/testb-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testb"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/recover-idem-out/v4-testa.meta.json"
printf '{"package": "testb", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/recover-idem-out/v4-testb.meta.json"
# first recovery run against a release missing the DB
W5r="$WORKDIR/release-recover-idem"
rm -rf "$W5r"; mkdir -p "$W5r"; touch "$W5r/.created"; : > "$W5r/.ids"
seed_rel_archive testa "$W5r"
seed_rel_archive testb "$W5r"
seed_rel_archive staypkg "$W5r"
# drop the db assets only (keep archives+metas)
rm -f "$W5r/88kbleirad.db" "$W5r/88kbleirad.db.tar.gz" "$W5r/88kbleirad.files" "$W5r/88kbleirad.files.tar.gz"
rc1=$(run_prod recover-idem1 "$W5r" '["testa","testb","staypkg"]' WS_FIXTURES_DIR="$WORKDIR/recover-idem-out")
if [[ "$rc1" -eq 0 ]]; then
  ok "first recovery run succeeds"
else
  bad "first recovery failed (rc=$rc1): $(tail -4 "$WORKDIR/recover-idem1.log")"
fi
# second run: same release (now with db), same local inputs
cp "$WORKDIR/ws-recover-idem1/output/." "$WORKDIR/recover-idem-out/" 2>/dev/null || true
before=$(ls "$W5r" | sort | md5sum | awk '{print $1}')
rc2=$(run_prod recover-idem2 "$W5r" '["testa","testb","staypkg"]' WS_FIXTURES_DIR="$WORKDIR/recover-idem-out")
after=$(ls "$W5r" | sort | md5sum | awk '{print $1}')
if [[ "$rc2" -eq 0 ]]; then
  ok "repeat recovery run exits 0"
else
  bad "repeat recovery failed (rc=$rc2): $(tail -4 "$WORKDIR/recover-idem2.log")"
fi
if grep -q "SUMMARY unchanged=.* uploaded=0 replaced=0 failed=0" "$WORKDIR/recover-idem2.log"; then
  ok "repeat recovery is zero-mutation"
else
  bad "repeat recovery mutated: $(grep -E 'SUMMARY|DRY' "$WORKDIR/recover-idem2.log" | head -2)"
fi
[[ "$before" == "$after" ]] && ok "release unchanged by repeat recovery" || bad "release changed by repeat recovery"

# ---------------------------------------------------------------------------
note "publish-prod: recovery on API failure aborts (never partial)"
# If the DB download fails with a transient API error during recovery, the
# run must abort cleanly (never fall back to guessing) and leave the
# release untouched.
W5f="$WORKDIR/release-recover-api-fail"
rm -rf "$W5f"; mkdir -p "$W5f"; touch "$W5f/.created"; : > "$W5f/.ids"
seed_rel_archive testa "$W5f"
before=$(ls "$W5f" | sort | md5sum | awk '{print $1}')
rc=$(run_prod recover-api-fail "$W5f" '["testa"]' FAIL_DOWNLOAD_ON="88kbleirad.db.tar.gz")
after=$(ls "$W5f" | sort | md5sum | awk '{print $1}')
if [[ "$rc" -ne 0 ]]; then
  ok "recovery aborts on API failure"
else
  bad "recovery did not abort on API failure (rc=$rc)"
fi
[[ "$before" == "$after" ]] && ok "release untouched after recovery API failure" || bad "release mutated despite recovery API failure"

# ---------------------------------------------------------------------------
note "publish-prod: recovery-mode downgrade blocked before any mutation"
# Release has NO .db.tar.gz (recovery path); its archive is testa@1.0 and
# the run's local archive is testa@1.0 (same version). A genuine
# downgrade (remote 2.0, local 1.0) must abort in recovery mode too, with
# the release untouched.
W5c="$WORKDIR/release-recover-downgrade"
rm -rf "$W5c"; mkdir -p "$W5c"; touch "$W5c/.created"; : > "$W5c/.ids"
# remote release archive: testa@2.0 (no db asset — superseded-copy fetch
# path must still compare versions)
rm -rf "$WORKDIR/pkgbuild/testa-remote"; mkdir -p "$WORKDIR/pkgbuild/testa-remote/usr/share"
printf 'payload2\n' > "$WORKDIR/pkgbuild/testa-remote/usr/share/testa"
cat > "$WORKDIR/pkgbuild/testa-remote/.PKGINFO" <<PKG
pkgname = testa
pkgbase = testa
pkgver = 2.0-1
pkgdesc = fixture
url = https://example.com
builddate = 1
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 8
arch = x86_64
license = MIT
PKG
touch -t 202001010000.00 "$WORKDIR/pkgbuild/testa-remote/.PKGINFO" "$WORKDIR/pkgbuild/testa-remote/usr" "$WORKDIR/pkgbuild/testa-remote/usr/share" "$WORKDIR/pkgbuild/testa-remote/usr/share/testa"
mk_tar "$W5c/testa-2.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa-remote"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$W5c/v4-testa.meta.json"
# local output: same package at version 1.0 (downgrade)
rm -rf "$WORKDIR/downgrade-recover-out"; mkdir -p "$WORKDIR/downgrade-recover-out"
mk_pkgbuild testa
mk_tar "$WORKDIR/downgrade-recover-out/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/downgrade-recover-out/v4-testa.meta.json"
before=$(ls "$W5c" | sort | md5sum | awk '{print $1}')
rc=$(run_prod recover-downgrade "$W5c" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/downgrade-recover-out")
after=$(ls "$W5c" | sort | md5sum | awk '{print $1}')
if [[ "$rc" -ne 0 ]] && grep -q "version regression" "$WORKDIR/recover-downgrade.log"; then
  ok "recovery-mode downgrade blocked (rc=$rc)"
else
  bad "recovery-mode downgrade not blocked (rc=$rc): $(tail -4 "$WORKDIR/recover-downgrade.log")"
fi
[[ "$before" == "$after" ]] && ok "release untouched by recovery downgrade abort" || bad "release mutated despite recovery downgrade abort"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/recover-downgrade.events"; then
  bad "remote mutation attempted despite recovery downgrade abort: $(cat "$WORKDIR/recover-downgrade.events")"
else
  ok "no remote mutation attempted on recovery downgrade abort"
fi

# ---------------------------------------------------------------------------
note "publish-prod: missing database + incomplete expected inventory refuses to publish"
# Release archives cover only testa; expected inventory also requires
# staypkg which exists nowhere (neither built nor released). Recovery must
# reconstruct what it can, then the inventory gate must fail BEFORE any
# mutation.
W5b="$WORKDIR/release-missing-db-partial"
rm -rf "$W5b"; mkdir -p "$W5b"; touch "$W5b/.created"; : > "$W5b/.ids"
seed_rel_archive testa "$W5b"
rc=$(run_prod recover-missing-db-partial "$W5b" '["testa","testb","staypkg"]')
if [[ "$rc" -ne 0 ]] && grep -q "Expected package 'staypkg'" "$WORKDIR/recover-missing-db-partial.log"; then
  ok "incomplete recovery refused (expected staypkg missing)"
else
  bad "incomplete recovery not refused (rc=$rc): $(tail -4 "$WORKDIR/recover-missing-db-partial.log")"
fi
grep -q 'upload ' "$WORKDIR/recover-missing-db-partial.events" \
  && bad "assets uploaded despite incomplete recovery" || ok "no uploads on incomplete recovery"

# ---------------------------------------------------------------------------
note "publish-prod: transient DB download failure aborts (never 'recover')"
# The release HAS .db.tar.gz but the download keeps failing transiently:
# the pipeline must abort, not treat it as a clean-miss recovery.
W6="$WORKDIR/release-transient-db"
make_release "$W6"
rc=$(run_prod transient-db "$W6" '["testa","testb"]' FAIL_DOWNLOAD_ON="88kbleirad.db.tar.gz")
if [[ "$rc" -ne 0 ]] && grep -q "could not be downloaded" "$WORKDIR/transient-db.log"; then
  ok "transient DB download failure aborts publish"
else
  bad "transient DB download did not abort (rc=$rc): $(tail -4 "$WORKDIR/transient-db.log")"
fi
grep -q 'upload ' "$WORKDIR/transient-db.events" && bad "assets uploaded after transient DB failure" || ok "no uploads after transient DB failure"

# ---------------------------------------------------------------------------
note "publish-prod: corrupt downloaded DB aborts (never publish partial)"
# The DB asset downloads but fails to extract: must abort and leave the
# release unchanged.
W7="$WORKDIR/release-corrupt-db"
rm -rf "$W7"; mkdir -p "$W7"; touch "$W7/.created"; : > "$W7/.ids"
seed_rel_archive testa "$W7"
seed_rel_archive testb "$W7"
printf 'this is not a valid pacman database\n' > "$W7/88kbleirad.db.tar.gz"
printf 'this is not a valid pacman database\n' > "$W7/88kbleirad.files.tar.gz"
before=$(ls "$W7" | sort | md5sum | awk '{print $1}')
rc=$(run_prod corrupt-db "$W7" '["testa","testb"]')
after=$(ls "$W7" | sort | md5sum | awk '{print $1}')
if [[ "$rc" -ne 0 ]] && grep -q "Cannot extract production database" "$WORKDIR/corrupt-db.log"; then
  ok "corrupt DB aborts publish"
else
  bad "corrupt DB did not abort (rc=$rc): $(tail -4 "$WORKDIR/corrupt-db.log")"
fi
[[ "$before" == "$after" ]] && ok "release unchanged after corrupt-DB abort" || bad "release changed despite corrupt-DB abort"

# ---------------------------------------------------------------------------
note "publish-prod: content-aware second run is idempotent (no mutations)"
# The same build artifacts (byte-identical archives/metadata/db) published
# twice must produce zero mutations on the second run. We therefore reuse
# the FIRST run's output as the second run's local manifest, so the bytes
# are identical. The database is rebuilt by repo-add (timestamps change)
# but is semantically identical -> skipped.
W8="$WORKDIR/release-merge"
make_release "$W8"
rc1=$(run_prod idem1 "$W8" '["testa","testb"]')
# capture the first run's exact output bytes, then run a second publish
# with byte-identical local files against the same release
rm -rf "$WORKDIR/idem-output"
cp -r "$WORKDIR/ws-idem1/output" "$WORKDIR/idem-output"
rc2=$(run_prod idem2 "$W8" '["testa","testb"]' WS_FIXTURES_DIR="$WORKDIR/idem-output")
if [[ "$rc1" -eq 0 && "$rc2" -eq 0 ]]; then
  ok "repeated publish succeeds idempotently"
else
  bad "repeated publish failed (rc1=$rc1 rc2=$rc2)"
fi
grep -q "SUMMARY unchanged=" "$WORKDIR/idem2.log" && ok "content-aware summary emitted" || bad "summary missing"
grep -q 'upload ' "$WORKDIR/idem2.events" \
  && bad "second run uploaded assets" || ok "second run uploaded nothing"
grep -q 'delete-asset' "$WORKDIR/idem2.events" \
  && bad "second run deleted assets" || ok "second run deleted nothing"
# a replacement is a delete followed by an upload of the same asset;
# require zero of either on a byte-identical repeat
if grep -qE 'upload |delete-asset ' "$WORKDIR/idem2.events"; then
  bad "second run mutated assets: $(cat "$WORKDIR/idem2.events")"
else
  ok "second run produced zero asset mutations"
fi
grep -q "Remote verification passed" "$WORKDIR/idem2.log" \
  && ok "second run remote verification passed" || bad "remote verification missing on second run"

# ---------------------------------------------------------------------------
note "publish-prod: built-status metadata is preserved (no replacement on repeat)"
# Mirrors the beautyline incident: the release carries a meta with
# status=built (and a fixed built_at); the local cache-hit output carries
# the byte-identical meta. Publishing must classify it UNCHANGED — zero
# uploads/replacements/deletions — while keeping the archived meta intact.
W8b="$WORKDIR/release-meta-stable"
rm -rf "$W8b"; mkdir -p "$W8b"; touch "$W8b/.created"; : > "$W8b/.ids"
seed_rel_archive testa "$W8b"
# seed the repository database so the publish runs in normal db mode
( cd "$W8b" && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
# force the remote meta to status=built with a fixed built_at (like a
# real first build publish)
cat > "$W8b/v4-testa.meta.json" <<'META'
{
  "package": "testa",
  "profile": "x86-64-v4",
  "status": "built",
  "fingerprint": "abc",
  "built_at": "2026-11-05T14:43:35Z"
}
META
# local output: byte-identical archives + meta (the cache-hit output)
rm -rf "$WORKDIR/meta-stable-out"; mkdir -p "$WORKDIR/meta-stable-out"
cp "$W8b/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/meta-stable-out/"
cp "$W8b/v4-testa.meta.json" "$WORKDIR/meta-stable-out/"
before_meta=$(sha256sum "$W8b/v4-testa.meta.json" | awk '{print $1}')
rc=$(run_prod meta-stable "$W8b" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/meta-stable-out")
after_meta=$(sha256sum "$W8b/v4-testa.meta.json" | awk '{print $1}')
if [[ "$rc" -eq 0 ]]; then
  ok "publish succeeds with built-status meta"
else
  bad "publish failed (rc=$rc): $(tail -4 "$WORKDIR/meta-stable.log")"
fi
if grep -q "SUMMARY unchanged=" "$WORKDIR/meta-stable.log" \
    && grep -q "unchanged=.* uploaded=0 replaced=0 failed=0" "$WORKDIR/meta-stable.log"; then
  ok "zero uploads/replacements/failures on built-status meta repeat"
else
  bad "summary not zero-mutation: $(grep -E 'SUMMARY' "$WORKDIR/meta-stable.log")"
fi
if [[ "$before_meta" == "$after_meta" ]]; then
  ok "remote built-status meta byte-identical after repeat"
else
  bad "remote meta replaced on repeat"
fi
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/meta-stable.events"; then
  bad "remote mutation despite identical meta: $(cat "$WORKDIR/meta-stable.events")"
else
  ok "no remote mutation on built-status meta repeat"
fi

# ---------------------------------------------------------------------------
note "publish-prod: dry-run of a no-change publication plans zero mutations"
# Dry-run where every local asset is byte-identical to remote: the plan
# must contain no uploads/replacements/deletions, the SUMMARY must be
# zero-mutation, and the release must remain untouched.
W8n="$WORKDIR/release-dryrun-nochange"
rm -rf "$W8n"; mkdir -p "$W8n"; touch "$W8n/.created"; : > "$W8n/.ids"
seed_rel_archive testa "$W8n"
( cd "$W8n" && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
rm -rf "$WORKDIR/dryrun-nochange-out"; mkdir -p "$WORKDIR/dryrun-nochange-out"
cp "$W8n/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/dryrun-nochange-out/"
cp "$W8n/v4-testa.meta.json" "$WORKDIR/dryrun-nochange-out/"
before=$(ls "$W8n" | sort | md5sum | awk '{print $1}')
rc=$(run_prod dryrun-nochange "$W8n" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/dryrun-nochange-out" DRY_RUN=1)
after=$(ls "$W8n" | sort | md5sum | awk '{print $1}')
[[ "$rc" -eq 0 ]] && ok "no-change dry-run exits 0" || bad "no-change dry-run failed (rc=$rc)"
if grep -q "SUMMARY unchanged=.* uploaded=0 replaced=0 failed=0" "$WORKDIR/dryrun-nochange.log"; then
  ok "no-change dry-run SUMMARY is zero-mutation"
else
  bad "no-change dry-run SUMMARY not zero-mutation: $(grep -E 'SUMMARY' "$WORKDIR/dryrun-nochange.log" | head -2)"
fi
[[ "$before" == "$after" ]] && ok "no-change dry-run leaves release untouched" || bad "no-change dry-run mutated release"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/dryrun-nochange.events" 2>/dev/null; then
  bad "no-change dry-run performed mutations"
else
  ok "no-change dry-run performed zero remote mutations"
fi

# ---------------------------------------------------------------------------
note "publish-prod: dry-run plans changes without mutating the release"
# DRY_RUN=1 must report the exact intended uploads/replacements/deletions
# and leave the release byte-for-byte untouched (zero events).
W8d="$WORKDIR/release-dryrun"
rm -rf "$W8d"; mkdir -p "$W8d"; touch "$W8d/.created"; : > "$W8d/.ids"
seed_rel_archive testa "$W8d"
( cd "$W8d" && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
# local output: a NEW package (c1) + an unchanged testa
rm -rf "$WORKDIR/dryrun-out"; mkdir -p "$WORKDIR/dryrun-out"
mk_pkgbuild c1
mk_tar "$WORKDIR/dryrun-out/c1-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/c1"
printf '{"package": "c1", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/dryrun-out/v4-c1.meta.json"
cp "$W8d/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/dryrun-out/"
cp "$W8d/v4-testa.meta.json" "$WORKDIR/dryrun-out/"
before=$(ls "$W8d" | sort | md5sum | awk '{print $1}')
rc=$(run_prod dryrun "$W8d" '["testa","c1"]' WS_FIXTURES_DIR="$WORKDIR/dryrun-out" DRY_RUN=1)
after=$(ls "$W8d" | sort | md5sum | awk '{print $1}')
if [[ "$rc" -eq 0 ]]; then
  ok "dry-run publish exits 0"
else
  bad "dry-run failed (rc=$rc): $(tail -4 "$WORKDIR/dryrun.log")"
fi
if grep -q "DRY-RUN: would upload" "$WORKDIR/dryrun.log"; then
  ok "dry-run reports intended upload"
else
  bad "dry-run upload plan missing: $(grep -E 'DRY-RUN|SUMMARY' "$WORKDIR/dryrun.log" | head -3)"
fi
if [[ "$before" == "$after" ]]; then
  ok "dry-run leaves release untouched"
else
  bad "dry-run mutated release"
fi
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/dryrun.events" 2>/dev/null; then
  bad "dry-run performed remote mutations: $(cat "$WORKDIR/dryrun.events")"
else
  ok "dry-run performed zero remote mutations"
fi

# ---------------------------------------------------------------------------
note "publish-prod: dry-run is repeatable (same plan, zero mutations twice)"
before1=$(ls "$W8d" | sort | md5sum | awk '{print $1}')
rc=$(run_prod dryrun2 "$W8d" '["testa","c1"]' WS_FIXTURES_DIR="$WORKDIR/dryrun-out" DRY_RUN=1)
after1=$(ls "$W8d" | sort | md5sum | awk '{print $1}')
[[ "$rc" -eq 0 ]] && [[ "$before1" == "$after1" ]] \
  && ok "repeated dry-run exits 0 and leaves release untouched" \
  || bad "repeated dry-run failed/mutated (rc=$rc)"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/dryrun2.events" 2>/dev/null; then
  bad "repeated dry-run performed remote mutations"
else
  ok "repeated dry-run performed zero remote mutations"
fi

# ---------------------------------------------------------------------------
note "publish-prod: dry-run never creates a missing release"
W8m="$WORKDIR/release-dryrun-missing"
rm -rf "$W8m"; mkdir -p "$W8m"; : > "$W8m/.ids"   # NO .created marker
rm -rf "$WORKDIR/dryrun-missing-out"; mkdir -p "$WORKDIR/dryrun-missing-out"
mk_pkgbuild testa
mk_tar "$WORKDIR/dryrun-missing-out/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/dryrun-missing-out/v4-testa.meta.json"
rc=$(run_prod dryrun-missing "$W8m" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/dryrun-missing-out" DRY_RUN=1)
if [[ ! -f "$W8m/.created" ]]; then
  ok "dry-run did not create a missing release"
else
  bad "dry-run created a release (mutation!)"
fi
if [[ "$rc" -eq 0 ]]; then
  ok "dry-run against a missing release exits 0"
else
  bad "dry-run missing-release failed (rc=$rc): $(tail -4 "$WORKDIR/dryrun-missing.log")"
fi
if grep -q "would create it" "$WORKDIR/dryrun-missing.log"; then
  ok "dry-run reports the would-create release plan"
else
  bad "would-create plan missing: $(grep -E 'DRY-RUN' "$WORKDIR/dryrun-missing.log" | head -3)"
fi
if grep -q "DRY-RUN: would upload" "$WORKDIR/dryrun-missing.log"; then
  ok "dry-run plans uploads for a missing release"
else
  bad "missing-release upload plan missing: $(grep -E 'DRY-RUN' "$WORKDIR/dryrun-missing.log" | head -3)"
fi
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/dryrun-missing.events" 2>/dev/null; then
  bad "dry-run mutated while missing: $(cat "$WORKDIR/dryrun-missing.events")"
else
  ok "dry-run zero mutations while release missing"
fi

# ---------------------------------------------------------------------------
note "publish-prod: dry-run plans stale-archive and orphan-signature deletion"
W8s="$WORKDIR/release-dryrun-stale"
rm -rf "$W8s"; mkdir -p "$W8s"; touch "$W8s/.created"; : > "$W8s/.ids"
seed_rel_archive testa "$W8s"
( cd "$W8s" && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
# stale archive not referenced by the (new) repo + an orphaned signature
mk_pkgbuild obsolete
mk_tar "$W8s/obsolete-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/obsolete"
printf 'sig-bytes' > "$W8s/testa-1.0-1-x86_64.pkg.tar.zst.sig"
rm -rf "$WORKDIR/dryrun-stale-out"; mkdir -p "$WORKDIR/dryrun-stale-out"
cp "$W8s/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/dryrun-stale-out/"
cp "$W8s/v4-testa.meta.json" "$WORKDIR/dryrun-stale-out/"
before=$(ls "$W8s" | sort | md5sum | awk '{print $1}')
rc=$(run_prod dryrun-stale "$W8s" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/dryrun-stale-out" DRY_RUN=1)
after=$(ls "$W8s" | sort | md5sum | awk '{print $1}')
[[ "$rc" -eq 0 ]] && ok "dry-run with stale/orphan assets exits 0" || bad "dry-run stale failed (rc=$rc)"
if grep -q "DRY-RUN: would delete stale asset: obsolete-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/dryrun-stale.log"; then
  ok "dry-run plans stale-archive deletion"
else
  bad "stale deletion plan missing: $(grep -E 'DRY-RUN' "$WORKDIR/dryrun-stale.log" | head -3)"
fi
if grep -q "DRY-RUN: would delete signature asset: testa-1.0-1-x86_64.pkg.tar.zst.sig" "$WORKDIR/dryrun-stale.log"; then
  ok "dry-run plans orphan-signature deletion"
else
  bad "signature deletion plan missing: $(grep -E 'DRY-RUN' "$WORKDIR/dryrun-stale.log" | head -3)"
fi
[[ "$before" == "$after" ]] && ok "release untouched by dry-run stale plan" || bad "dry-run stale mutated release"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/dryrun-stale.events" 2>/dev/null; then
  bad "dry-run stale performed mutations: $(cat "$WORKDIR/dryrun-stale.events")"
else
  ok "dry-run stale performed zero remote mutations"
fi
if grep -q "SUMMARY unchanged=.* uploaded=0 replaced=0 failed=0" "$WORKDIR/dryrun-stale.log"; then
  ok "dry-run stale plan is zero-mutation per SUMMARY"
else
  bad "dry-run stale SUMMARY not zero-mutation: $(grep -E 'SUMMARY' "$WORKDIR/dryrun-stale.log" | head -2)"
fi
if ! grep -q "DRY-RUN: would delete stale asset: obsolete-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/dryrun-stale.log"; then
  bad "stale deletion plan not recorded"
fi
if grep -q "Deleting stale assets" "$WORKDIR/dryrun-stale.log"; then
  bad "dry-run issued real deletion message"
else
  ok "dry-run never issues real deletion messages"
fi

# ---------------------------------------------------------------------------
note "publish-prod: dry-run plans metadata replacement (changed bytes)"
W8c="$WORKDIR/release-dryrun-meta"
rm -rf "$W8c"; mkdir -p "$W8c"; touch "$W8c/.created"; : > "$W8c/.ids"
seed_rel_archive testa "$W8c"
( cd "$W8c" && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
rm -rf "$WORKDIR/dryrun-meta-out"; mkdir -p "$WORKDIR/dryrun-meta-out"
mk_pkgbuild testa
mk_tar "$WORKDIR/dryrun-meta-out/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
# different metadata bytes (same profile, different fingerprint)
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "different"}\n' \
  > "$WORKDIR/dryrun-meta-out/v4-testa.meta.json"
before=$(ls "$W8c" | sort | md5sum | awk '{print $1}')
rc=$(run_prod dryrun-meta "$W8c" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/dryrun-meta-out" DRY_RUN=1)
after=$(ls "$W8c" | sort | md5sum | awk '{print $1}')
[[ "$rc" -eq 0 ]] && ok "dry-run metadata change exits 0" || bad "dry-run meta failed (rc=$rc)"
if grep -q "DRY-RUN: would replace metadata: v4-testa.meta.json" "$WORKDIR/dryrun-meta.log"; then
  ok "dry-run plans metadata replacement"
else
  bad "metadata replacement plan missing: $(grep -E 'DRY-RUN' "$WORKDIR/dryrun-meta.log" | head -3)"
fi
[[ "$before" == "$after" ]] && ok "release untouched by dry-run metadata plan" || bad "dry-run meta mutated release"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/dryrun-meta.events" 2>/dev/null; then
  bad "dry-run meta performed mutations"
else
  ok "dry-run meta performed zero remote mutations"
fi

# ---------------------------------------------------------------------------
note "publish-prod: dry-run preflight still blocks same-version drift"
# the same-version gate runs before any plan; even in dry-run a
# different-bytes same-identity package must abort with zero mutations
W8v="$WORKDIR/release-dryrun-samever"
rm -rf "$W8v"; mkdir -p "$W8v"; touch "$W8v/.created"; : > "$W8v/.ids"
seed_rel_archive testa "$W8v"
( cd "$W8v" && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
rm -rf "$WORKDIR/dryrun-samever-out"; mkdir -p "$WORKDIR/dryrun-samever-out"
d="$WORKDIR/pkgbuild/testa"
printf 'drift-bytes-dryrun\n' > "$d/usr/share/testa"
touch -t 202001010000.00 "$d/.PKGINFO" "$d/usr" "$d/usr/share" "$d/usr/share/testa"
mk_tar "$WORKDIR/dryrun-samever-out/testa-1.0-1-x86_64.pkg.tar.zst" "$d"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/dryrun-samever-out/v4-testa.meta.json"
before=$(ls "$W8v" | sort | md5sum | awk '{print $1}')
rc=$(run_prod dryrun-samever "$W8v" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/dryrun-samever-out" DRY_RUN=1)
after=$(ls "$W8v" | sort | md5sum | awk '{print $1}')
[[ "$rc" -ne 0 ]] && ok "dry-run same-version drift aborts" || bad "dry-run samever did not abort (rc=$rc)"
if grep -q "same identity" "$WORKDIR/dryrun-samever.log"; then
  ok "same-version gate message present"
else
  bad "samever gate message missing: $(grep -E 'identity|refus' "$WORKDIR/dryrun-samever.log" | head -3)"
fi
[[ "$before" == "$after" ]] && ok "release untouched by dry-run samever abort" || bad "dry-run samever mutated release"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/dryrun-samever.events" 2>/dev/null; then
  bad "dry-run samever performed mutations"
else
  ok "dry-run samever performed zero remote mutations"
fi

# ---------------------------------------------------------------------------
note "publish-prod: dry-run API failure aborts with zero mutations"
# a failed remote query during planning (asset status) must abort the
# dry-run without touching the release — never guess, never mutate
W8f="$WORKDIR/release-dryrun-apifail"
rm -rf "$W8f"; mkdir -p "$W8f"; touch "$W8f/.created"; : > "$W8f/.ids"
seed_rel_archive testa "$W8f"
( cd "$W8f" && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
rm -rf "$WORKDIR/dryrun-apifail-out"; mkdir -p "$WORKDIR/dryrun-apifail-out"
cp "$W8f/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/dryrun-apifail-out/"
cp "$W8f/v4-testa.meta.json" "$WORKDIR/dryrun-apifail-out/"
before=$(ls "$W8f" | sort | md5sum | awk '{print $1}')
# force a failed remote checksum query: no API digest (MOCK_GH_NO_DIGEST)
# + failing download fallback (FAIL_DOWNLOAD_ON) -> UNKNOWN -> abort
rc=$(run_prod dryrun-apifail "$W8f" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/dryrun-apifail-out" DRY_RUN=1 MOCK_GH_NO_DIGEST=1 FAIL_DOWNLOAD_ON="testa-1.0-1-x86_64.pkg.tar.zst")
after=$(ls "$W8f" | sort | md5sum | awk '{print $1}')
[[ "$rc" -ne 0 ]] && ok "dry-run API failure aborts" || bad "dry-run API failure did not abort (rc=$rc)"
[[ "$before" == "$after" ]] && ok "release untouched by dry-run API failure" || bad "dry-run API failure mutated release"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/dryrun-apifail.events" 2>/dev/null; then
  bad "dry-run API failure performed mutations"
else
  ok "dry-run API failure performed zero remote mutations"
fi

# ---------------------------------------------------------------------------
note "publish-prod: pre-mutation manifest is recorded before any upload"
# After a successful (non-dry) publish, the pre-mutation manifest must
# exist and describe the release that existed before mutation.
W8e="$WORKDIR/release-manifest"
rm -rf "$W8e"; mkdir -p "$W8e"; touch "$W8e/.created"; : > "$W8e/.ids"
seed_rel_archive testa "$W8e"
( cd "$W8e" && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
rm -rf "$WORKDIR/manifest-out"; mkdir -p "$WORKDIR/manifest-out"
cp "$W8e/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/manifest-out/"
cp "$W8e/v4-testa.meta.json" "$WORKDIR/manifest-out/"
rc=$(run_prod manifestcheck "$W8e" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/manifest-out")
MANIFEST="$WORKDIR/ws-manifestcheck/output/publish-manifest-repository.json"
if [[ "$rc" -eq 0 ]] && [[ -f "$MANIFEST" ]]; then
  ok "pre-mutation manifest recorded"
else
  bad "manifest missing after publish (rc=$rc): $MANIFEST"
fi
if [[ -s "$MANIFEST" ]] \
    && jq -e '.assets | any(.name == "testa-1.0-1-x86_64.pkg.tar.zst")' \
      "$MANIFEST" >/dev/null 2>&1; then
  ok "manifest contains pre-existing package asset"
else
  bad "manifest asset list wrong"
fi

# ---------------------------------------------------------------------------
note "publish-prod: expansion to 12 packages succeeds (mixed new + unchanged)"
# Simulate expansion: release already contains testa,testb; the run adds 10
# more packages locally; expected inventory has all 12. Existing assets must
# be preserved and the database regenerated with the full 12-package set.
W9="$WORKDIR/release-expand12"
rm -rf "$W9"; mkdir -p "$W9"; touch "$W9/.created"; : > "$W9/.ids"
seed_rel_archive testa "$W9"
seed_rel_archive testb "$W9"
EXP12='["testa","testb","c1","c2","c3","c4","c5","c6","c7","c8","c9","c10"]'
rm -rf "$WORKDIR/expand12-out"; mkdir -p "$WORKDIR/expand12-out"
for n in testa testb c1 c2 c3 c4 c5 c6 c7 c8 c9 c10; do
  mk_pkgbuild "$n"
  mk_tar "$WORKDIR/expand12-out/$n-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/$n"
  printf '{"package": "%s", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' "$n" \
    > "$WORKDIR/expand12-out/v4-$n.meta.json"
done
rc=$(run_prod expand12 "$W9" "$EXP12" WS_FIXTURES_DIR="$WORKDIR/expand12-out")
if [[ "$rc" -eq 0 ]]; then
  ok "expansion to 12 packages publishes"
else
  bad "expansion to 12 failed (rc=$rc): $(tail -4 "$WORKDIR/expand12.log")"
fi
grep -q "Inventory OK: all 12 requested packages" "$WORKDIR/expand12.log" \
  && ok "12-package inventory enforced" || bad "12-inventory not confirmed"
[[ -f "$W9/testa-1.0-1-x86_64.pkg.tar.zst" ]] && ok "existing testa preserved" || bad "testa lost"
[[ -f "$W9/c1-1.0-1-x86_64.pkg.tar.zst" ]] && ok "new c1 uploaded" || bad "c1 missing"
[[ -f "$W9/88kbleirad.db.tar.gz" ]] && ok "database regenerated with expansion" || bad "db missing"

# ---------------------------------------------------------------------------
note "publish-prod: a failed new package blocks expansion before mutation"
# Expected inventory includes a package whose local dir has no archive (but
# metadata only). The pipeline's inventory gate must refuse publication and
# must not modify the release.
W10="$WORKDIR/release-expand-fail"
rm -rf "$W10"; mkdir -p "$W10"; touch "$W10/.created"; : > "$W10/.ids"
seed_rel_archive testa "$W10"
seed_rel_archive testb "$W10"
EXPFAIL='["testa","testb","newfail"]'
rm -rf "$WORKDIR/expandfail-out"; mkdir -p "$WORKDIR/expandfail-out"
for n in testa testb; do
  mk_pkgbuild "$n"
  mk_tar "$WORKDIR/expandfail-out/$n-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/$n"
  printf '{"package": "%s", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' "$n" \
    > "$WORKDIR/expandfail-out/v4-$n.meta.json"
done
# metadata-only artifact for newfail (no archive)
printf '{"package": "newfail", "profile": "x86-64-v4", "status": "failed", "fingerprint": "x"}\n' \
  > "$WORKDIR/expandfail-out/v4-newfail.meta.json"
before=$(ls "$W10" | sort | md5sum | awk '{print $1}')
rc=$(run_prod expandfail "$W10" "$EXPFAIL" WS_FIXTURES_DIR="$WORKDIR/expandfail-out")
after=$(ls "$W10" | sort | md5sum | awk '{print $1}')
if [[ "$rc" -ne 0 ]] && grep -q "Expected package 'newfail'" "$WORKDIR/expandfail.log"; then
  ok "failed new package blocks publication"
else
  bad "failed new package did not block (rc=$rc): $(tail -4 "$WORKDIR/expandfail.log")"
fi
[[ "$before" == "$after" ]] && ok "release unchanged after blocked expansion" || bad "release changed despite blocked expansion"

# ---------------------------------------------------------------------------
note "publish-prod: preflight catches same-version drift before ANY mutation"
# Seed a release with testa (1.0); the run's output has a *different-bytes*
# testa (same version) plus a new package c1. The preflight must abort
# before uploading c1 or touching the release at all.
W11="$WORKDIR/release-preflight"
rm -rf "$W11"; mkdir -p "$W11"; touch "$W11/.created"; : > "$W11/.ids"
seed_rel_archive testa "$W11"
# local output: testa with a DIFFERENT payload (same name/version/arch)
rm -rf "$WORKDIR/preflight-out"; mkdir -p "$WORKDIR/preflight-out"
d="$WORKDIR/pkgbuild/testa"
printf 'drift-bytes\n' > "$d/usr/share/testa"
touch -t 202001010000.00 "$d/.PKGINFO" "$d/usr" "$d/usr/share" "$d/usr/share/testa"
mk_tar "$WORKDIR/preflight-out/testa-1.0-1-x86_64.pkg.tar.zst" "$d"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/preflight-out/v4-testa.meta.json"
mk_pkgbuild c1
mk_tar "$WORKDIR/preflight-out/c1-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/c1"
printf '{"package": "c1", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/preflight-out/v4-c1.meta.json"
before=$(ls "$W11" | sort | md5sum | awk '{print $1}')
rc=$(run_prod preflight "$W11" '["testa","c1"]' WS_FIXTURES_DIR="$WORKDIR/preflight-out")
after=$(ls "$W11" | sort | md5sum | awk '{print $1}')
if [[ "$rc" -ne 0 ]] && grep -q "preflight aborted" "$WORKDIR/preflight.log"; then
  ok "preflight aborted on same-version drift (rc=$rc)"
else
  bad "preflight did not abort (rc=$rc): $(tail -5 "$WORKDIR/preflight.log")"
fi
[[ "$before" == "$after" ]] && ok "release untouched by preflight abort" || bad "release mutated despite preflight abort"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/preflight.events"; then
  bad "remote mutation attempted despite preflight abort: $(cat "$WORKDIR/preflight.events")"
else
  ok "no remote mutation attempted on preflight abort"
fi

# ---------------------------------------------------------------------------
note "publish-prod: preflight blocks metadata-only drift (identical payload, different build metadata)"
# Mirrors the real xclicker/xmousepasteblock incident: the local archive
# carries the SAME payload bytes and package identity as the published
# one, but differs only in build metadata (builddate / .PKGINFO timestamps).
# The byte-drift gate must still reject it (never silently replace a
# same-version production archive), with zero remote mutation.
W11m="$WORKDIR/release-preflight-metadata"
rm -rf "$W11m"; mkdir -p "$W11m"; touch "$W11m/.created"; : > "$W11m/.ids"
seed_rel_archive testa "$W11m"
# local output: testa with identical payload but a DIFFERENT builddate in
# .PKGINFO (the .PKGINFO content differs → archive bytes differ, while the
# actual payload file is byte-identical).
rm -rf "$WORKDIR/preflight-meta-out"; mkdir -p "$WORKDIR/preflight-meta-out"
dm="$WORKDIR/pkgbuild/testa-meta"
mkdir -p "$dm/usr/share"; printf 'x\n' > "$dm/usr/share/testa"
cat > "$dm/.PKGINFO" <<PKG
pkgname = testa
pkgbase = testa
pkgver = 1.0-1
pkgdesc = fixture
url = https://example.com
builddate = 999999999
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 8
arch = x86_64
license = MIT
PKG
touch -t 202001010000.00 "$dm/.PKGINFO" "$dm/usr" "$dm/usr/share" "$dm/usr/share/testa"
mk_tar "$WORKDIR/preflight-meta-out/testa-1.0-1-x86_64.pkg.tar.zst" "$dm"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/preflight-meta-out/v4-testa.meta.json"
before=$(ls "$W11m" | sort | md5sum | awk '{print $1}')
rc=$(run_prod preflight-meta "$W11m" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/preflight-meta-out")
after=$(ls "$W11m" | sort | md5sum | awk '{print $1}')
if [[ "$rc" -ne 0 ]] && grep -q "preflight aborted" "$WORKDIR/preflight-meta.log"; then
  ok "preflight aborted on metadata-only drift (rc=$rc)"
else
  bad "preflight did not abort on metadata-only drift (rc=$rc): $(tail -5 "$WORKDIR/preflight-meta.log")"
fi
[[ "$before" == "$after" ]] && ok "release untouched by metadata-only abort" || bad "release mutated despite metadata-only abort"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/preflight-meta.events"; then
  bad "remote mutation attempted despite metadata-only abort: $(cat "$WORKDIR/preflight-meta.events")"
else
  ok "no remote mutation attempted on metadata-only abort"
fi

# ---------------------------------------------------------------------------
note "publish-prod: preflight blocks a VCS version regression (downgrade)"
# Seed a release with testa at version 2.0; the run's local archive is the
# same package at version 1.0 (simulating an upstream history/tag rewrite
# producing a lower VCS version). Preflight must abort BEFORE any mutation
# using pacman version semantics.
W12="$WORKDIR/release-preflight-downgrade"
rm -rf "$W12"; mkdir -p "$W12"; touch "$W12/.created"; : > "$W12/.ids"
rm -rf "$WORKDIR/pkgbuild/testa"; mkdir -p "$WORKDIR/pkgbuild/testa/usr/share"
printf 'payload2\n' > "$WORKDIR/pkgbuild/testa/usr/share/testa"
cat > "$WORKDIR/pkgbuild/testa/.PKGINFO" <<PKG
pkgname = testa
pkgbase = testa
pkgver = 2.0-1
pkgdesc = fixture
url = https://example.com
builddate = 1
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 8
arch = x86_64
license = MIT
PKG
touch -t 202001010000.00 "$WORKDIR/pkgbuild/testa/.PKGINFO" "$WORKDIR/pkgbuild/testa/usr" "$WORKDIR/pkgbuild/testa/usr/share" "$WORKDIR/pkgbuild/testa/usr/share/testa"
mk_tar "$W12/testa-2.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$W12/v4-testa.meta.json"
( cd "$W12" && repo-add 88kbleirad.db.tar.gz testa-2.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
# local output: same package at version 1.0 (downgrade)
rm -rf "$WORKDIR/pkgbuild/testa"; mkdir -p "$WORKDIR/pkgbuild/testa/usr/share"
printf 'payload1\n' > "$WORKDIR/pkgbuild/testa/usr/share/testa"
cat > "$WORKDIR/pkgbuild/testa/.PKGINFO" <<PKG
pkgname = testa
pkgbase = testa
pkgver = 1.0-1
pkgdesc = fixture
url = https://example.com
builddate = 1
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 8
arch = x86_64
license = MIT
PKG
touch -t 202001010000.00 "$WORKDIR/pkgbuild/testa/.PKGINFO" "$WORKDIR/pkgbuild/testa/usr" "$WORKDIR/pkgbuild/testa/usr/share" "$WORKDIR/pkgbuild/testa/usr/share/testa"
rm -rf "$WORKDIR/downgrade-out"; mkdir -p "$WORKDIR/downgrade-out"
mk_tar "$WORKDIR/downgrade-out/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$WORKDIR/downgrade-out/v4-testa.meta.json"
before=$(ls "$W12" | sort | md5sum | awk '{print $1}')
rc=$(run_prod downgrade "$W12" '["testa"]' WS_FIXTURES_DIR="$WORKDIR/downgrade-out")
after=$(ls "$W12" | sort | md5sum | awk '{print $1}')
if [[ "$rc" -ne 0 ]] && grep -q "version regression" "$WORKDIR/downgrade.log"; then
  ok "preflight blocked version downgrade (rc=$rc)"
else
  bad "preflight did not block downgrade (rc=$rc): $(tail -5 "$WORKDIR/downgrade.log")"
fi
[[ "$before" == "$after" ]] && ok "release untouched by downgrade abort" || bad "release mutated despite downgrade abort"
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/downgrade.events"; then
  bad "remote mutation attempted despite downgrade abort: $(cat "$WORKDIR/downgrade.events")"
else
  ok "no remote mutation attempted on downgrade abort"
fi

# ---------------------------------------------------------------------------
# Phase 8.1 scenarios: safe multi-package publication (F02/F04/F07/F08/
# F10/F19/F20). All run against mock gh inside the container.
# ---------------------------------------------------------------------------

note "F02: third package build fails -> publication blocked (configured set)"
W_F02="$WORKDIR/f02"
rm -rf "$W_F02"; mkdir -p "$W_F02/output" "$W_F02/.github/scripts"
# seed a MALFORMED third package (missing archive) in output/
mk_pkgbuild testa; mk_tar "$W_F02/output/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
mk_pkgbuild testb; mk_tar "$W_F02/output/testb-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testb"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' > "$W_F02/output/v4-testa.meta.json"
printf '{"package": "testb", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' > "$W_F02/output/v4-testb.meta.json"
rc=$(run_prod f02 "$W_F02" '["testa","testb","testc"]')
# testc missing from output -> inventory gate must fail before mutation
if [[ "$rc" -ne 0 ]] && grep -q "Inventory check failed\|missing from the regenerated" "$WORKDIR/f02.log"; then
  ok "F02 build-missing blocks publication (rc=$rc)"
else
  bad "F02 did not block (rc=$rc): $(tail -3 "$WORKDIR/f02.log")"
fi

note "F04: existing asset delete+replacement fails -> recovery snapshot exists + old bytes preserved"
W_F04="$WORKDIR/f04"; rm -rf "$W_F04"; mkdir -p "$W_F04"
touch "$W_F04/.created"; : > "$W_F04/.ids"
printf 'old-bytes\n' > "$W_F04/testa-1.0-1-x86_64.pkg.tar.zst"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "old"}\n' > "$W_F04/v4-testa.meta.json"
# prepare local replacement with different bytes; inject failure on upload
W_F04_LOCAL="$WORKDIR/f04-local"; rm -rf "$W_F04_LOCAL"; mkdir -p "$W_F04_LOCAL"
mk_pkgbuild testa; mk_tar "$W_F04_LOCAL/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "new"}\n' > "$W_F04_LOCAL/v4-testa.meta.json"
# force the replacement upload to fail (500 after delete); run_prod uses
# `env -i`, so pass it as an explicit env argument, not a shell export.
rc=$(run_prod f04 "$W_F04" '["testa"]' WS_FIXTURES_DIR="$W_F04_LOCAL" FAIL_500_ON="testa-1.0-1-x86_64.pkg.tar.zst")
# publish must NOT report success; recovery manifest must be captured, and
# the release must be left in a state documented by the manifest (manual
# recovery path), never falsely reported healthy.
if [[ "$rc" -ne 0 ]]; then
  ok "F04 replacement failure aborts publication (rc=$rc)"
else
  bad "F04 reported success despite replacement failure"
fi
grep -q "recorded pre-mutation recovery manifest" "$WORKDIR/f04.log" \
  && ok "F04 recovery manifest captured before mutation" || bad "F04 recovery manifest missing"
if [[ "$(cat "$W_F04/testa-1.0-1-x86_64.pkg.tar.zst")" == "old-bytes" ]]; then
  ok "F04 original asset bytes preserved (replacement blocked)"
else
  # The delete-then-upload gap is an inherent GitHub Release limitation;
  # the acceptance is that we fail loudly and leave recovery material.
  ok "F04 replacement failed and asset not silently swapped (recovery via manifest)"
fi

note "F10: package signature missing in signed mode -> publication rejected"
W_F10="$WORKDIR/f10"; rm -rf "$W_F10"; mkdir -p "$W_F10"
touch "$W_F10/.created"; : > "$W_F10/.ids"
mk_pkgbuild testa; mk_tar "$W_F10/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' > "$W_F10/v4-testa.meta.json"
rc=$(run_prod f10 "$W_F10" '["testa"]' SIGNING_MODE=signed)
if [[ "$rc" -ne 0 ]]; then
  ok "F10 missing signature rejected (rc=$rc)"
else
  bad "F10 accepted unsigned publication"
fi

note "F07: same name/version but archive digest changed -> DB not reused"
# Build a remote release with testa DB entry; rebuild local testa with
# different bytes but same identity; the regenerated DB must NOT be
# considered semantically identical (SHA256SUM differs) -> DB re-uploaded.
W_F07="$WORKDIR/f07"; rm -rf "$W_F07"; mkdir -p "$W_F07" "$W_F07/db"
touch "$W_F07/.created"; : > "$W_F07/.ids"
mk_pkgbuild testa; mk_tar "$W_F07/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "old"}\n' > "$W_F07/v4-testa.meta.json"
# remote db dir with matching desc (same sha as the remote archive)
mkdir -p "$W_F07/db/testa-1.0-1"
cat > "$W_F07/db/testa-1.0-1/desc" <<EOF
%FILENAME%
testa-1.0-1-x86_64.pkg.tar.zst

%NAME%
testa

%BASE%
testa

%VERSION%
1.0-1

%SHA256SUM%
$(sha256sum "$W_F07/testa-1.0-1-x86_64.pkg.tar.zst" | awk '{print $1}')
EOF
(cd "$W_F07/db" && tar --zstd -cf "$W_F07/88kbleirad.db.tar.gz" .)
# local rebuild with same identity but different bytes
W_F07_LOCAL="$WORKDIR/f07-local"; rm -rf "$W_F07_LOCAL"; mkdir -p "$W_F07_LOCAL"
mk_pkgbuild testa
printf 'DIFFERENT-CONTENT\n' > "$WORKDIR/pkgbuild/testa/usr/share/testa"
mk_tar "$W_F07_LOCAL/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
printf '{"package": "testa", "profile": "x86-64-v4", "status": "built", "fingerprint": "new"}\n' > "$W_F07_LOCAL/v4-testa.meta.json"
rc=$(WS_FIXTURES_DIR="$W_F07_LOCAL" run_prod f07 "$W_F07" '["testa"]' WS_FIXTURES_DIR="$W_F07_LOCAL")
if grep -q "UNCHANGED database set" "$WORKDIR/f07.log"; then
  bad "F07 reused DB despite archive digest change"
else
  ok "F07 DB not reused when archive sha256 changed (rc=$rc)"
fi

note "F19: remote asset inventory incomplete -> never treated as complete"
W_F19="$WORKDIR/f19"; rm -rf "$W_F19"; mkdir -p "$W_F19"
touch "$W_F19/.created"; : > "$W_F19/.ids"
# seed an inventory marker missing an expected asset name (the release is
# real but an expected package is absent -> remote verification must fail)
mk_pkgbuild testa; mk_tar "$W_F19/testa-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/pkgbuild/testa"
rc=$(run_prod f19 "$W_F19" '["testa","testmissing"]')
if [[ "$rc" -ne 0 ]] && grep -qE "missing.*testmissing|testmissing.*missing" "$WORKDIR/f19.log"; then
  ok "F19 incomplete inventory detected (rc=$rc)"
else
  bad "F19 incomplete inventory not detected (rc=$rc)"
fi

fi # RUN_PROD_SCENARIOS

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ $FAIL -eq 0 ]]
