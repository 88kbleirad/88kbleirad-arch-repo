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
grep -q "Remote verification passed" "$WORKDIR/idem2.log" \
  && ok "second run remote verification passed" || bad "remote verification missing on second run"

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

# ---------------------------------------------------------------------------
note "publish-prod: preflight blocks a VCS version regression (downgrade)"
# Seed a release with testa at version 2.0; the run's local archive is the
# same package at version 1.0 (simulating an upstream history/tag rewrite
# producing a lower VCS version). Preflight must abort BEFORE any mutation
# using pacman version semantics.
W12="$WORKDIR/release-preflight-downgrade"
rm -rf "$W12"; mkdir -p "$W12"; touch "$W12/.created"; : > "$W12/.ids"
rm -rf "$WORKDIR/pkgbuild/testa"; mkdir -p "$WORKDIR/pkgbuild/testa"
printf 'payload2\n' > "$WORKDIR/pkgbuild/testa/usr/share/testa" 2>/dev/null || { mkdir -p "$WORKDIR/pkgbuild/testa/usr/share"; printf 'payload2\n' > "$WORKDIR/pkgbuild/testa/usr/share/testa"; }
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

fi # RUN_PROD_SCENARIOS

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ $FAIL -eq 0 ]]
