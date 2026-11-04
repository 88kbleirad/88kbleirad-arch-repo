#!/usr/bin/env bash
#
# Test suite for the GPG signing pipeline:
#   1. key import into scratch GNUPGHOME
#   2. package + database detached signing and verification
#   3. publish-prod.sh / publish-stage.sh end-to-end against a mock gh
#      release, asserting signed assets, verified signatures, db sigs,
#      public key export, and validation gating
#   4. negative tests: missing key, invalid signature, unsigned assets
#
# Requires a container with gnupg, jq, libarchive, bash. Run inside the
# pinned archlinux container (see run-tests.sh).

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Generate a test key (no passphrase for the local harness)
note "preparing test signing key"
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

# ---------------------------------------------------------------------------
note "sign-helpers: import + sign package + verify"
mkdir -p "$WORKDIR/out" && cd "$WORKDIR/out"
source "$REPO_ROOT/.github/scripts/sign-helpers.sh"
gpg_init_homedir
# import with the secret env var
gpg_import_signing_key && ok "key import"
[[ -n "$SIGNING_KEYID" ]] && ok "keyid resolved ($SIGNING_KEYID)" || bad "keyid empty"

# fabricate a valid package archive
mkdir -p pkg/usr/share/test
echo hi > pkg/usr/share/test/a.txt
cat > pkg/.PKGINFO <<'PKG'
pkgname = testpkg
pkgbase = testpkg
pkgver = 1.0-1
pkgdesc = test
url = http://test
builddate = 1
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 4
arch = x86_64
license = MIT
PKG
( cd pkg && tar --zstd -cf ../testpkg-1.0-1-x86_64.pkg.tar.zst .PKGINFO usr )

# second package (never rebuilt by the E2E stages) exercises the keep/merge
# and previously-published-signature paths
mkdir -p pkg2/usr/share/stay
echo stay > pkg2/usr/share/stay/b.txt
cat > pkg2/.PKGINFO <<'PKG'
pkgname = staypkg
pkgbase = staypkg
pkgver = 1.0-1
pkgdesc = stay
url = http://test
builddate = 1
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 4
arch = x86_64
license = MIT
PKG
( cd pkg2 && tar --zstd -cf ../staypkg-1.0-1-x86_64.pkg.tar.zst .PKGINFO usr )
printf '{"package": "staypkg", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc456"}\n' \
  > v4-staypkg.meta.json

sign_detached testpkg-1.0-1-x86_64.pkg.tar.zst && ok "package signed" || bad "package signing failed"
verify_detached testpkg-1.0-1-x86_64.pkg.tar.zst testpkg-1.0-1-x86_64.pkg.tar.zst.sig \
  && ok "package signature verified" || bad "package signature verification failed"

# tamper -> must fail
cp testpkg-1.0-1-x86_64.pkg.tar.zst testpkg-tampered.pkg.tar.zst
printf 'x' | dd of=testpkg-tampered.pkg.tar.zst bs=1 seek=1000 count=1 conv=notrunc 2>/dev/null
gpg --verify testpkg-1.0-1-x86_64.pkg.tar.zst.sig testpkg-tampered.pkg.tar.zst >/dev/null 2>&1 \
  && bad "tampered package accepted" || ok "tampered package rejected"

# ---------------------------------------------------------------------------
note "ensure_all_packages_signed"
rm -f testpkg-1.0-1-x86_64.pkg.tar.zst.sig
rm -f testpkg-tampered.pkg.tar.zst
ensure_all_packages_signed && ok "all packages signed+verified" || bad "ensure_all_packages_signed failed"

# ---------------------------------------------------------------------------
note "database signing (repo-add + sign_and_publish_db_signatures)"
rm -f 88kbleirad.db.tar.gz 88kbleirad.files.tar.gz 88kbleirad.db* 88kbleirad.files*
REPO_DB_NAME=88kbleirad
repo-add --include-sigs "$REPO_DB_NAME.db.tar.gz" \
  testpkg-1.0-1-x86_64.pkg.tar.zst staypkg-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1
sign_and_publish_db_signatures && ok "db signed + verified" || bad "db signing failed"
[[ -s 88kbleirad.db.sig ]] && [[ -s 88kbleirad.files.sig ]] && ok "plain .db.sig/.files.sig published" || bad "plain db sig names missing"
gpg --verify 88kbleirad.db.sig 88kbleirad.db >/dev/null 2>&1 && ok "88kbleirad.db.sig verifies" || bad "88kbleirad.db.sig verification failed"

# db tamper -> must fail
cp 88kbleirad.db.tar.gz 88kbleirad-db-tampered.tar.gz
printf 'x' | dd of=88kbleirad-db-tampered.tar.gz bs=1 seek=100 count=1 conv=notrunc 2>/dev/null
gpg --verify 88kbleirad.db.sig 88kbleirad-db-tampered.tar.gz >/dev/null 2>&1 \
  && bad "tampered db accepted" || ok "tampered db rejected"
rm -f 88kbleirad-db-tampered.tar.gz

export_public_key && [[ -s 88kbleirad.pub.asc ]] && ok "public key exported" || bad "public key export failed"

# ---------------------------------------------------------------------------
note "validation gate (validate-release.sh with REQUIRE_SIGNATURES=1)"
# validate-release.sh requires a v4-<base>.meta.json for every package
printf '{"package": "testpkg", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc123"}\n' \
  > v4-testpkg.meta.json
REQUIRE_SIGNATURES=1 bash "$REPO_ROOT/.github/scripts/validate-release.sh" "$PWD" "88kbleirad" >/dev/null 2>&1 \
  && ok "validate-release passes with signatures" || bad "validate-release failed (unexpected)"

# unsigned package must fail validation
rm -f testpkg-1.0-1-x86_64.pkg.tar.zst.sig
REQUIRE_SIGNATURES=1 bash "$REPO_ROOT/.github/scripts/validate-release.sh" "$PWD" "88kbleirad" >/dev/null 2>&1 \
  && bad "validation accepted unsigned package" || ok "validation rejects unsigned package"
gpg --batch --yes --detach-sign --no-armor -u "$SIGNING_KEYID" \
  -o testpkg-1.0-1-x86_64.pkg.tar.zst.sig testpkg-1.0-1-x86_64.pkg.tar.zst

# invalid signature must fail validation: sign a DIFFERENT file then
# attach that signature to the real archive
echo different-content > "$WORKDIR/other-content"
gpg --batch --yes --detach-sign --no-armor -u "$SIGNING_KEYID" \
  -o /tmp/other.sig "$WORKDIR/other-content"
mv /tmp/other.sig testpkg-1.0-1-x86_64.pkg.tar.zst.sig
REQUIRE_SIGNATURES=1 bash "$REPO_ROOT/.github/scripts/validate-release.sh" "$PWD" "88kbleirad" >/dev/null 2>&1 \
  && bad "validation accepted bad signature" || ok "validation rejects bad signature"
gpg --batch --yes --detach-sign --no-armor -u "$SIGNING_KEYID" \
  -o testpkg-1.0-1-x86_64.pkg.tar.zst.sig testpkg-1.0-1-x86_64.pkg.tar.zst

# ---------------------------------------------------------------------------
note "negative: missing key must abort"
echo "--- publish-prod without key ---"
env -u GPG_PRIVATE_KEY -u GPG_KEY_FILE \
  GPG_PASSPHRASE= \
  bash "$REPO_ROOT/.github/scripts/publish-prod.sh" >/dev/null 2>&1 \
  && bad "publish-prod succeeded without key" \
  || ok "publish-prod aborts without key"

# ---------------------------------------------------------------------------
note "publish-stage.sh end-to-end against mock gh"

# copy scripts to a repo-root-like layout (the publish script sources
# sign-helpers.sh from GITHUB_WORKSPACE)
REPO_COPY="$WORKDIR/repo"
mkdir -p "$REPO_COPY/.github/scripts"
cp "$REPO_ROOT/.github/scripts/sign-helpers.sh" "$REPO_COPY/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/publish-stage.sh" "$REPO_COPY/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/validate-release.sh" "$REPO_COPY/.github/scripts/"

export GITHUB_REPOSITORY="owner/repo"
export RELEASE_TAG="repository-v4-test"
export REPO_DB_NAME=88kbleirad
export GH_TOKEN=dummy
export GITHUB_STEP_SUMMARY="$WORKDIR/sum-stage.md"
export GPG_KEY_FILE=""
export GPG_PASSPHRASE_FILE=""
export GPG_PRIVATE_KEY="$GPG_PRIVATE_KEY"

# the mock gh must be reachable as `gh` on PATH (publish-stage.sh installs
# the real github-cli; the shim must take precedence)
SHIM_BIN="$WORKDIR/bin"
mkdir -p "$SHIM_BIN"
cat > "$SHIM_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
exec bash "$MOCK_GH" "$@"
SHIM
chmod +x "$SHIM_BIN/gh"
export MOCK_GH="$REPO_ROOT/.github/tests/mock-gh.sh"

# helper: run publish-stage.sh with a fresh output/ dir holding the given
# assets; the mock gh serves <releasedir> as the release. GITHUB_WORKSPACE
# must contain .github/scripts/sign-helpers.sh (REPO_COPY provides it).
run_stage() {
  # usage: run_stage <releasedir> <eventslog> <logfile> [assets...]
  local rel="$1" events="$2" log="$3"; shift 3
  rm -rf "$REPO_COPY/output"; mkdir -p "$REPO_COPY/output"
  local a
  for a in "$@"; do cp "$a" "$REPO_COPY/output/"; done
  ( cd "$REPO_COPY" && \
    GITHUB_WORKSPACE="$REPO_COPY" \
    REPO_DB_NAME="$REPO_DB_NAME" \
    GH_TOKEN="$GH_TOKEN" \
    GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
    FAKE_RELEASE_DIR="$rel" \
    FAKE_EVENTS_LOG="$events" \
    PATH="$SHIM_BIN:$REPO_ROOT/.github/tests:$PATH" \
    $REPO_ROOT/.github/scripts/publish-stage.sh > "$log" 2>&1 )
  echo $?
}

# stage 1: publish a fresh release (no previous release exists)
echo "--- fresh release ---"
FRESH_DIR="$WORKDIR/fresh-release"
rm -rf "$FRESH_DIR"
rc=$(run_stage "$FRESH_DIR" "$WORKDIR/events-fresh.log" "$WORKDIR/fresh.log" \
  testpkg-1.0-1-x86_64.pkg.tar.zst v4-testpkg.meta.json \
  staypkg-1.0-1-x86_64.pkg.tar.zst v4-staypkg.meta.json)
if [[ $rc -eq 0 ]] && [[ -f "$FRESH_DIR/.created" ]]; then
  ok "fresh publish created release (rc=0)"
else
  bad "fresh publish failed (rc=$rc): $(tail -3 "$WORKDIR/fresh.log")"
fi
[[ -f "$FRESH_DIR/88kbleirad.db.sig" ]] && ok "published .db.sig" || bad "missing .db.sig"
[[ -f "$FRESH_DIR/88kbleirad.db.tar.gz.sig" ]] && ok "published .db.tar.gz.sig" || bad "missing .db.tar.gz.sig"
[[ -f "$FRESH_DIR/88kbleirad.pub.asc" ]] && ok "published public key" || bad "missing public key"
[[ -f "$FRESH_DIR/testpkg-1.0-1-x86_64.pkg.tar.zst.sig" ]] && ok "published package signature" || bad "missing package signature"
[[ -f "$FRESH_DIR/staypkg-1.0-1-x86_64.pkg.tar.zst.sig" ]] && ok "published second package signature" || bad "missing second package signature"

# fresh release db must validate with signatures enforced
REQUIRE_SIGNATURES=1 bash "$REPO_ROOT/.github/scripts/validate-release.sh" "$FRESH_DIR" "88kbleirad" >/dev/null 2>&1 \
  && ok "fresh release validates" || bad "fresh release validation failed"

# stage 2: subset republish — only testpkg is rebuilt; staypkg must be
# merged from the previous release with its signature carried and verified
echo "--- subset republish with merge ---"
FAB_DIR="$WORKDIR/fabricate"
rm -rf "$FAB_DIR"; mkdir -p "$FAB_DIR"
cp "$FRESH_DIR"/88kbleirad.db.tar.gz "$FAB_DIR/"
cp "$FRESH_DIR"/88kbleirad.files.tar.gz "$FAB_DIR/"
cp "$FRESH_DIR"/testpkg-1.0-1-x86_64.pkg.tar.zst "$FAB_DIR/"
cp "$FRESH_DIR"/testpkg-1.0-1-x86_64.pkg.tar.zst.sig "$FAB_DIR/"
cp "$FRESH_DIR"/staypkg-1.0-1-x86_64.pkg.tar.zst "$FAB_DIR/"
cp "$FRESH_DIR"/staypkg-1.0-1-x86_64.pkg.tar.zst.sig "$FAB_DIR/"
cp "$FRESH_DIR"/v4-testpkg.meta.json "$FAB_DIR/"
cp "$FRESH_DIR"/v4-staypkg.meta.json "$FAB_DIR/"
rc=$(run_stage "$FAB_DIR" "$WORKDIR/events-sub.log" "$WORKDIR/sub.log" \
  testpkg-1.0-1-x86_64.pkg.tar.zst v4-testpkg.meta.json)
if [[ $rc -eq 0 ]] && grep -q "Kept previously published package: staypkg-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/sub.log"; then
  ok "merge kept previously published package"
else
  bad "merge failed (rc=$rc): $(tail -3 "$WORKDIR/sub.log")"
fi
REQUIRE_SIGNATURES=1 bash "$REPO_ROOT/.github/scripts/validate-release.sh" "$FAB_DIR" "88kbleirad" >/dev/null 2>&1 \
  && ok "merged release validates" || bad "merged release validation failed"

# stage 2b: previous release with an UNSIGNED kept package (pre-signing
# era) — merge must retain it and sign it fresh on this run
echo "--- retained unsigned package migration ---"
UNS_DIR="$WORKDIR/unsigned-release"
rm -rf "$UNS_DIR"; mkdir -p "$UNS_DIR"
cp "$FRESH_DIR"/88kbleirad.db.tar.gz "$UNS_DIR/"
cp "$FRESH_DIR"/88kbleirad.files.tar.gz "$UNS_DIR/"
cp "$FRESH_DIR"/testpkg-1.0-1-x86_64.pkg.tar.zst "$UNS_DIR/"
cp "$FRESH_DIR"/staypkg-1.0-1-x86_64.pkg.tar.zst "$UNS_DIR/"
# NOTE: staypkg has NO .sig in this "old" release (pre-signing state)
cp "$FRESH_DIR"/v4-testpkg.meta.json "$UNS_DIR/"
cp "$FRESH_DIR"/v4-staypkg.meta.json "$UNS_DIR/"
rm -f "$WORKDIR/events-uns.log"; touch "$WORKDIR/events-uns.log"
rc=$(run_stage "$UNS_DIR" "$WORKDIR/events-uns.log" "$WORKDIR/uns.log" \
  testpkg-1.0-1-x86_64.pkg.tar.zst v4-testpkg.meta.json)
if [[ $rc -eq 0 ]] && [[ -f "$UNS_DIR/staypkg-1.0-1-x86_64.pkg.tar.zst.sig" ]]; then
  ok "retained unsigned package was signed on this run"
else
  bad "unsigned retained package not signed (rc=$rc): $(tail -3 "$WORKDIR/uns.log")"
fi
REQUIRE_SIGNATURES=1 bash "$REPO_ROOT/.github/scripts/validate-release.sh" "$UNS_DIR" "88kbleirad" >/dev/null 2>&1 \
  && ok "migrated unsigned release validates" || bad "migrated unsigned release failed validation"
if grep -q "Kept previously published package: staypkg-1.0-1-x86_64.pkg.tar.zst" "$WORKDIR/uns.log"; then
  ok "previously published package retained"
else
  bad "previously published package not retained"
fi

# stage 3: tampered previously-published signature (staypkg) must abort the
# publish before upload
echo "--- tampered previous signature abort ---"
BAD_DIR="$WORKDIR/bad-release"
rm -rf "$BAD_DIR"; mkdir -p "$BAD_DIR"
cp "$FRESH_DIR"/88kbleirad.db.tar.gz "$BAD_DIR/"
cp "$FRESH_DIR"/88kbleirad.files.tar.gz "$BAD_DIR/"
cp "$FRESH_DIR"/testpkg-1.0-1-x86_64.pkg.tar.zst "$BAD_DIR/"
cp "$FRESH_DIR"/staypkg-1.0-1-x86_64.pkg.tar.zst "$BAD_DIR/"
cp "$FRESH_DIR"/v4-testpkg.meta.json "$BAD_DIR/"
cp "$FRESH_DIR"/v4-staypkg.meta.json "$BAD_DIR/"
printf 'garbage' > "$BAD_DIR/staypkg-1.0-1-x86_64.pkg.tar.zst.sig"
rm -f "$WORKDIR/events-bad.log"; touch "$WORKDIR/events-bad.log"
rc=$(run_stage "$BAD_DIR" "$WORKDIR/events-bad.log" "$WORKDIR/bad.log" \
  testpkg-1.0-1-x86_64.pkg.tar.zst v4-testpkg.meta.json)
if [[ $rc -ne 0 ]] && grep -q "failed verification" "$WORKDIR/bad.log"; then
  ok "tampered signature aborts publish"
else
  bad "tampered signature did not abort (rc=$rc): $(tail -3 "$WORKDIR/bad.log")"
fi
if [[ ! -s "$WORKDIR/events-bad.log" ]]; then
  ok "no assets uploaded on abort"
else
  bad "assets uploaded despite abort: $(cat "$WORKDIR/events-bad.log")"
fi

# publish-stage without key (all GPG material unset) must abort
echo "--- publish-stage without key ---"
rm -f "$WORKDIR/events-nokey.log"; touch "$WORKDIR/events-nokey.log"
rm -rf "$REPO_COPY/output"; mkdir -p "$REPO_COPY/output"
rc=0
( cd "$REPO_COPY" && \
  env -u GPG_PRIVATE_KEY -u GPG_KEY_FILE -u GPG_PASSPHRASE_FILE \
  GITHUB_WORKSPACE="$REPO_COPY" \
  REPO_DB_NAME="$REPO_DB_NAME" \
  GH_TOKEN="$GH_TOKEN" \
  GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
  FAKE_RELEASE_DIR="$FRESH_DIR" \
  FAKE_EVENTS_LOG="$WORKDIR/events-nokey.log" \
  PATH="$SHIM_BIN:$REPO_ROOT/.github/tests:$PATH" \
  $REPO_ROOT/.github/scripts/publish-stage.sh > "$WORKDIR/nokey.log" 2>&1 ) || rc=$?
if [[ $rc -ne 0 ]] && grep -q "No signing key" "$WORKDIR/nokey.log"; then
  ok "publish-stage aborts without key"
else
  bad "publish-stage did not abort without key (rc=$rc): $(tail -3 "$WORKDIR/nokey.log")"
fi
if [[ ! -s "$WORKDIR/events-nokey.log" ]]; then
  ok "no assets uploaded without key"
else
  bad "assets uploaded without key: $(cat "$WORKDIR/events-nokey.log")"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
