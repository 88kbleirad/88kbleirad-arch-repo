#!/usr/bin/env bash
#
# Regression tests for remote post-publish verification (Objective B).
#
# Builds a fake release (via mock-gh), generates a valid pacman database
# with repo-add (requires pacman-contrib — run inside the pinned container),
# and runs verify-remote-release.sh against it. Negative tests cover:
# missing package, missing alias, missing index, corrupt db, mismatched
# metadata, wrong version, db referencing a missing asset, signed/unsigned
# mode mismatch, transient download failure.
#
# Run inside the archlinux container (pacman-contrib available), like the
# other publish tests.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# -- mock gh environment ----------------------------------------------------
export MOCK_GH="$REPO_ROOT/.github/tests/mock-gh.sh"
mkdir -p "$WORKDIR/mockbin"
cat > "$WORKDIR/mockbin/gh" <<'SHIM'
#!/usr/bin/env bash
export FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?}"
export FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"
exec bash "$MOCK_GH" "$@"
SHIM
chmod +x "$WORKDIR/mockbin/gh"
export PATH="$WORKDIR/mockbin:$PATH"

# -- build a fake release with 3 packages + db ------------------------------
REL="$WORKDIR/release"
mkdir -p "$REL"
touch "$REL/.created"
: > "$REL/.ids"

mk_pkg() { # name outdir
  local name="$1" out="$2"
  local d="$WORKDIR/pkgbuild/$name"
  mkdir -p "$d/usr/share"
  printf 'fixture %s\n' "$name" > "$d/usr/share/$name"
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
  ( cd "$d" && tar --zstd -cf "$out/$name-1.0-1-x86_64.pkg.tar.zst" .PKGINFO usr )
  printf '{"package": "%s", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' "$name" \
    > "$out/v4-$name.meta.json"
}

mk_pkg testa "$REL"
mk_pkg testb "$REL"
mk_pkg testc "$REL"
( cd "$REL" && repo-add 88kbleirad.db.tar.gz \
    testa-1.0-1-x86_64.pkg.tar.zst \
    testb-1.0-1-x86_64.pkg.tar.zst \
    testc-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
# repo-add creates the plain .db/.files aliases as symlinks to the
# canonical compressed files; the mock follows them for digest computation.

export FAKE_RELEASE_DIR="$REL"
export GITHUB_REPOSITORY="owner/repo"
export RELEASE_TAG="repository"
export GH_TOKEN=dummy
export SIGNING_MODE=unsigned
export REPO_DB_NAME=88kbleirad

EXPECTED='["testa","testb","testc"]'

# run_verify <rel> [extra args...]
# runs the verification against the given fake release dir and returns its
# exit code via VERIFY_RC, with output in $WORKDIR/verify.log
run_verify() {
  local rel="$1"; shift
  set +e
  FAKE_RELEASE_DIR="$rel" \
    bash "$REPO_ROOT/.github/scripts/verify-remote-release.sh" \
      repository owner/repo "$EXPECTED" "$@" > "$WORKDIR/verify.log" 2>&1
  VERIFY_RC=$?
  set -e
}

# ---------------------------------------------------------------------------
note "remote verify: valid release passes"
run_verify "$REL" --manifest-dir "$REL"
if [[ $VERIFY_RC -eq 0 ]]; then
  ok "valid release passes remote verification"
else
  bad "valid release failed: $(tail -5 "$WORKDIR/verify.log")"
fi
grep -q "Packages expected: 3" "$WORKDIR/verify.log" && ok "expected count reported" || bad "expected count missing"
grep -q "Database assets: 4/4" "$WORKDIR/verify.log" && ok "4/4 db assets confirmed" || bad "db asset count wrong"
grep -q "Result: PASS" "$WORKDIR/verify.log" && ok "result PASS" || bad "result not PASS"

# ---------------------------------------------------------------------------
note "remote verify: missing package archive fails"
cp -r "$REL" "$WORKDIR/rel-missing-pkg"
rm -f "$WORKDIR/rel-missing-pkg/testc-1.0-1-x86_64.pkg.tar.zst"
run_verify "$WORKDIR/rel-missing-pkg"
[[ $VERIFY_RC -ne 0 ]] && grep -q "missing package archive: testc" "$WORKDIR/verify.log" \
  && ok "missing package archive detected" || bad "missing package not detected (rc=$VERIFY_RC)"

# ---------------------------------------------------------------------------
note "remote verify: missing database alias fails"
cp -r "$REL" "$WORKDIR/rel-missing-alias"
rm -f "$WORKDIR/rel-missing-alias/88kbleirad.db"
run_verify "$WORKDIR/rel-missing-alias"
[[ $VERIFY_RC -ne 0 ]] && grep -q "missing database asset: 88kbleirad.db" "$WORKDIR/verify.log" \
  && ok "missing db alias detected" || bad "missing alias not detected (rc=$VERIFY_RC)"

# ---------------------------------------------------------------------------
note "remote verify: missing file index fails"
cp -r "$REL" "$WORKDIR/rel-missing-index"
rm -f "$WORKDIR/rel-missing-index/88kbleirad.files.tar.gz"
run_verify "$WORKDIR/rel-missing-index"
[[ $VERIFY_RC -ne 0 ]] && grep -q "missing database asset: 88kbleirad.files.tar.gz" "$WORKDIR/verify.log" \
  && ok "missing file index detected" || bad "missing index not detected (rc=$VERIFY_RC)"

# ---------------------------------------------------------------------------
note "remote verify: corrupted database fails"
cp -r "$REL" "$WORKDIR/rel-corrupt-db"
printf 'garbage-not-a-tar\n' > "$WORKDIR/rel-corrupt-db/88kbleirad.db.tar.gz"
printf 'garbage-not-a-tar\n' > "$WORKDIR/rel-corrupt-db/88kbleirad.db"
run_verify "$WORKDIR/rel-corrupt-db"
[[ $VERIFY_RC -ne 0 ]] && grep -qE "corrupt|not readable|cannot extract" "$WORKDIR/verify.log" \
  && ok "corrupted database detected" || bad "corrupt db not detected (rc=$VERIFY_RC)"

# ---------------------------------------------------------------------------
note "remote verify: mismatched metadata fails"
# the manifest dir must differ from the release: the release keeps the
# original metadata while the manifest carries a changed file, so the
# remote digest cannot match the manifest
cp -r "$REL" "$WORKDIR/manifest-bad-meta"
printf '{"package":"testa","profile":"x86-64-v3","status":"built","fingerprint":"x"}\n' \
  > "$WORKDIR/manifest-bad-meta/v4-testa.meta.json"
run_verify "$REL" --manifest-dir "$WORKDIR/manifest-bad-meta"
[[ $VERIFY_RC -ne 0 ]] && grep -q "checksum mismatch: v4-testa.meta.json" "$WORKDIR/verify.log" \
  && ok "mismatched metadata detected via checksum" || bad "mismatched metadata not detected (rc=$VERIFY_RC)"

# ---------------------------------------------------------------------------
note "remote verify: wrong package version fails"
cp -r "$REL" "$WORKDIR/rel-wrong-ver"
rm -f "$WORKDIR/rel-wrong-ver/testb-1.0-1-x86_64.pkg.tar.zst"
d="$WORKDIR/pkgbuild/testb"
( cd "$d" && tar --zstd -cf "$WORKDIR/rel-wrong-ver/testb-2.0-1-x86_64.pkg.tar.zst" .PKGINFO usr )
run_verify "$WORKDIR/rel-wrong-ver"
# the db references testb-1.0 which is no longer present -> asset reference failure
[[ $VERIFY_RC -ne 0 ]] && grep -q "database references missing release asset" "$WORKDIR/verify.log" \
  && ok "database referencing unavailable asset detected" || bad "wrong version not detected (rc=$VERIFY_RC)"

# ---------------------------------------------------------------------------
note "remote verify: signed mode requires signatures"
set +e
FAKE_RELEASE_DIR="$REL" \
  bash "$REPO_ROOT/.github/scripts/verify-remote-release.sh" \
    repository owner/repo "$EXPECTED" --signing-mode signed \
    > "$WORKDIR/verify.log" 2>&1
VERIFY_RC=$?
set -e
if [[ $VERIFY_RC -ne 0 ]] && grep -q "missing detached signature" "$WORKDIR/verify.log"; then
  ok "signed mode requires signatures"
else
  bad "signed mode did not require signatures (rc=$VERIFY_RC)"
fi

# ---------------------------------------------------------------------------
note "remote verify: unsigned mode rejects stale signatures"
cp -r "$REL" "$WORKDIR/rel-sig"
printf 'garbage' > "$WORKDIR/rel-sig/testa-1.0-1-x86_64.pkg.tar.zst.sig"
run_verify "$WORKDIR/rel-sig"
[[ $VERIFY_RC -ne 0 ]] && grep -q "stale detached signature" "$WORKDIR/verify.log" \
  && ok "unsigned mode rejects stale signatures" || bad "stale signature not detected (rc=$VERIFY_RC)"

# ---------------------------------------------------------------------------
note "remote verify: transient download failure retried"
cp -r "$REL" "$WORKDIR/rel-transient"
set +e
export FAIL_DOWNLOAD_ONCE_ON="88kbleirad.db.tar.gz"
FAKE_RELEASE_DIR="$WORKDIR/rel-transient" \
  bash "$REPO_ROOT/.github/scripts/verify-remote-release.sh" \
    repository owner/repo "$EXPECTED" > "$WORKDIR/verify.log" 2>&1
VERIFY_RC=$?
unset FAIL_DOWNLOAD_ONCE_ON
set -e
[[ $VERIFY_RC -eq 0 ]] && ok "transient download failure retried to success" || bad "transient download failure rc=$VERIFY_RC"

# ---------------------------------------------------------------------------
note "remote verify: split package (base != subpackage name) passes"
# The expected inventory names the base (splitbase); the database contains
# the subpackage (sublib). The required-archive set is derived from the
# database filenames, not from a prefix guess on the expected name.
SPLIT_REL="$WORKDIR/release-split"
mkdir -p "$SPLIT_REL"; touch "$SPLIT_REL/.created"; : > "$SPLIT_REL/.ids"
d="$WORKDIR/pkgbuild/sublib"; mkdir -p "$d/usr/lib"; printf 'x\n' > "$d/usr/lib/sublib.so"
cat > "$d/.PKGINFO" <<'PKG'
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
( cd "$d" && tar --zstd -cf "$SPLIT_REL/sublib-1.0-1-x86_64.pkg.tar.zst" .PKGINFO usr )
printf '{"package": "splitbase", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' \
  > "$SPLIT_REL/v4-splitbase.meta.json"
( cd "$SPLIT_REL" && repo-add 88kbleirad.db.tar.gz sublib-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
EXPECTED='["splitbase"]'
run_verify "$SPLIT_REL" --signing-mode unsigned
if [[ $VERIFY_RC -eq 0 ]] && grep -q "Packages available: 1" "$WORKDIR/verify.log"; then
  ok "split base verified via database filenames"
else
  bad "split base verification failed (rc=$VERIFY_RC): $(tail -5 "$WORKDIR/verify.log")"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
