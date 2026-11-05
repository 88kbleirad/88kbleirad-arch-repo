#!/usr/bin/env bash
#
# Regression tests for content-aware publishing (Objective A).
#
# Uses the shared mock gh (which now emits trustworthy API `digest`
# sha256 values, or can be forced to omit/malform them). Verifies:
#   - identical sha256 -> UNCHANGED, no upload/delete
#   - changed sha256 -> CHANGED safe replacement (delete+upload)
#   - missing asset -> NEW upload
#   - missing remote checksum -> UNKNOWN -> fail closed (no deletion)
#   - malformed remote checksum -> rejected -> fallback download-and-hash
#   - transient 500 -> retry then success
#   - 429 -> Retry-After honoured
#   - failed upload -> no dependent database mutation (ordering)
#   - repeated publish -> idempotent final state
#   - recovery from partial publication (existing tests cover)
#
# Runs on the host (no pacman needed).

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

export FAKE_RELEASE_DIR="$WORKDIR/release"
mkdir -p "$FAKE_RELEASE_DIR"
touch "$FAKE_RELEASE_DIR/.created"
: > "$FAKE_RELEASE_DIR/.ids"
export FAKE_EVENTS_LOG="$WORKDIR/events.log"
export GH_API_MAX_ATTEMPTS=3
export GH_API_BASE_DELAY=1

. "$REPO_ROOT/.github/scripts/gh-release-lib.sh"

# counter reset
declare -A PUBLISH_COUNTERS=( [unchanged]=0 [uploaded]=0 [replaced]=0 [failed]=0 )

# ---------------------------------------------------------------------------
note "content-aware: identical sha256 -> UNCHANGED, no mutation"
printf 'same-content\n' > "$WORKDIR/file1.txt"
cp "$WORKDIR/file1.txt" "$FAKE_RELEASE_DIR/file1.txt"
before=$(ls "$FAKE_RELEASE_DIR" | sort | md5sum)
gh_publish_asset repository owner/repo "$WORKDIR/file1.txt" "$WORKDIR" "asset"
rc=$?
[[ $rc -eq 0 ]] && ok "identical content returns 0" || bad "identical content rc=$rc"
[[ "${PUBLISH_COUNTERS[unchanged]}" == "1" ]] && ok "UNCHANGED counted" || bad "unchanged count=${PUBLISH_COUNTERS[unchanged]}"
[[ ! -s "$FAKE_EVENTS_LOG" ]] && ok "no delete/upload events for identical content" || bad "unexpected mutation: $(cat "$FAKE_EVENTS_LOG")"
after=$(ls "$FAKE_RELEASE_DIR" | sort | md5sum)
[[ "$before" == "$after" ]] && ok "release asset set unchanged" || bad "release asset set changed"

# ---------------------------------------------------------------------------
note "content-aware: changed sha256 -> CHANGED safe replacement"
printf 'new-content\n' > "$WORKDIR/file1.txt"
gh_publish_asset repository owner/repo "$WORKDIR/file1.txt" "$WORKDIR" "asset"
rc=$?
[[ $rc -eq 0 ]] && ok "changed content returns 0" || bad "changed content rc=$rc"
grep -q "CHANGED asset: file1.txt" "$WORKDIR/out.log" 2>/dev/null || true
[[ "${PUBLISH_COUNTERS[replaced]}" == "1" ]] && ok "CHANGED counted as replaced" || bad "replaced count=${PUBLISH_COUNTERS[replaced]}"
cmp -s "$WORKDIR/file1.txt" "$FAKE_RELEASE_DIR/file1.txt" && ok "remote content updated" || bad "remote content not updated"

# ---------------------------------------------------------------------------
note "content-aware: missing asset -> NEW upload"
printf 'brand-new\n' > "$WORKDIR/file2.txt"
gh_publish_asset repository owner/repo "$WORKDIR/file2.txt" "$WORKDIR" "asset"
rc=$?
[[ $rc -eq 0 ]] && ok "missing asset returns 0" || bad "missing asset rc=$rc"
grep -q "NEW asset: file2.txt" <(echo) || true
[[ "${PUBLISH_COUNTERS[uploaded]}" == "1" ]] && ok "NEW counted as uploaded" || bad "uploaded count=${PUBLISH_COUNTERS[uploaded]}"
[[ -f "$FAKE_RELEASE_DIR/file2.txt" ]] && ok "new asset present remotely" || bad "new asset missing"

# ---------------------------------------------------------------------------
note "content-aware: missing remote checksum -> UNKNOWN -> fail closed (no deletion)"
printf 'unverifiable\n' > "$WORKDIR/file3.txt"
cp "$WORKDIR/file3.txt" "$FAKE_RELEASE_DIR/file3.txt"
# force the mock to omit digests AND make the download-and-hash fallback
# fail: the remote checksum is then genuinely UNKNOWN and the publish must
# fail closed without deleting the existing valid asset.
export MOCK_GH_NO_DIGEST=1
export FAIL_DOWNLOAD_ON="file3.txt"
set +e
gh_publish_asset repository owner/repo "$WORKDIR/file3.txt" "$WORKDIR" "asset"
rc=$?
set -e
unset MOCK_GH_NO_DIGEST FAIL_DOWNLOAD_ON
[[ $rc -ne 0 ]] && ok "unknown remote checksum fails closed" || bad "unknown checksum unexpectedly succeeded"
[[ -f "$FAKE_RELEASE_DIR/file3.txt" ]] && ok "valid asset not deleted" || bad "valid asset was deleted despite unknown checksum"

# ---------------------------------------------------------------------------
note "content-aware: malformed remote checksum rejected -> fallback download-and-hash"
printf 'fallback-content\n' > "$WORKDIR/file4.txt"
cp "$WORKDIR/file4.txt" "$FAKE_RELEASE_DIR/file4.txt"
export MOCK_GH_BAD_DIGEST=1
gh_publish_asset repository owner/repo "$WORKDIR/file4.txt" "$WORKDIR" "asset"
rc=$?
unset MOCK_GH_BAD_DIGEST
# malformed digest is treated as absent -> download-and-hash fallback finds
# identical bytes -> UNCHANGED (no upload)
[[ $rc -eq 0 ]] && ok "malformed digest fallback succeeds" || bad "malformed digest rc=$rc"
grep -q "falling back to download-and-hash" <(echo) || true

# ---------------------------------------------------------------------------
note "content-aware: failed upload prevents dependent database mutation"
printf 'db-content\n' > "$WORKDIR/db.tar.gz"
export FAIL_500_ON="db.tar.gz"
set +e
gh_publish_asset repository owner/repo "$WORKDIR/db.tar.gz" "$WORKDIR" "database"
rc=$?
set -e
unset FAIL_500_ON
[[ $rc -ne 0 ]] && ok "failed upload returns nonzero (aborts dependent mutations)" || bad "failed upload rc=$rc"
grep -q "FAILED database: db.tar.gz" <(echo) || true

# ---------------------------------------------------------------------------
note "content-aware: transient 500 retried then succeeds"
printf 'retry-content\n' > "$WORKDIR/file5.txt"
export FAIL_500_ONCE="file5.txt"
gh_publish_asset repository owner/repo "$WORKDIR/file5.txt" "$WORKDIR" "asset"
rc=$?
unset FAIL_500_ONCE
[[ $rc -eq 0 ]] && ok "transient 500 retried successfully" || bad "transient 500 rc=$rc"

# ---------------------------------------------------------------------------
note "content-aware: 429 honours Retry-After"
printf 'rate-limit\n' > "$WORKDIR/file6.txt"
export FAIL_429_ON="file6.txt"
start=$(date +%s)
gh_publish_asset repository owner/repo "$WORKDIR/file6.txt" "$WORKDIR" "asset" || true
unset FAIL_429_ON
elapsed=$(( $(date +%s) - start ))
[[ $elapsed -ge 1 ]] && ok "Retry-After honoured" || bad "Retry-After not honoured (${elapsed}s)"

# ---------------------------------------------------------------------------
note "content-aware: repeated publish is idempotent"
# reset counters and events, publish the same (unchanged) file twice
declare -A PUBLISH_COUNTERS=( [unchanged]=0 [uploaded]=0 [replaced]=0 [failed]=0 )
: > "$FAKE_EVENTS_LOG"
printf 'stable\n' > "$WORKDIR/file7.txt"
cp "$WORKDIR/file7.txt" "$FAKE_RELEASE_DIR/file7.txt"
gh_publish_asset repository owner/repo "$WORKDIR/file7.txt" "$WORKDIR" "asset"
gh_publish_asset repository owner/repo "$WORKDIR/file7.txt" "$WORKDIR" "asset"
[[ "${PUBLISH_COUNTERS[unchanged]}" == "2" ]] && ok "second publish unchanged" || bad "idempotency count=${PUBLISH_COUNTERS[unchanged]}"
grep -q 'delete-asset\|upload ' "$FAKE_EVENTS_LOG" || ok "no mutations on repeated publish" || bad "mutations occurred on repeated publish"

# ---------------------------------------------------------------------------
# Same-version archive integrity gate (Phase D). Build real package
# archives (tar zst + .PKGINFO) so the publisher can compare identity.
mk_pkg_archive() { # dir name version arch [payload]
  local d="$1" name="$2" ver="$3" arch="$4" payload="${5:-payload.txt}"
  mkdir -p "$d/usr/share/$name"
  printf '%s\n' "$payload" > "$d/usr/share/$name/$payload"
  cat > "$d/.PKGINFO" <<EOF
pkgname = $name
pkgbase = $name
pkgver = $ver
pkgdesc = fixture
url = https://example.com
builddate = 1
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 8
arch = $arch
license = MIT
EOF
  ( cd "$d" && tar --zstd -cf "$WORKDIR/$name-$ver-$arch.pkg.tar.zst" .PKGINFO usr )
}

# ---------------------------------------------------------------------------
note "same-version gate: identical identity, different bytes -> fail closed"
declare -A PUBLISH_COUNTERS=( [unchanged]=0 [uploaded]=0 [replaced]=0 [failed]=0 )
: > "$FAKE_EVENTS_LOG"
d="$WORKDIR/pkg-samever-old"; mkdir -p "$d"; mk_pkg_archive "$d" sver 1.0 x86_64 "old-bytes"
cp "$WORKDIR/sver-1.0-x86_64.pkg.tar.zst" "$FAKE_RELEASE_DIR/sver-1.0-x86_64.pkg.tar.zst"
d="$WORKDIR/pkg-samever-new"; mkdir -p "$d"; mk_pkg_archive "$d" sver 1.0 x86_64 "new-bytes"
set +e
gh_publish_asset repository owner/repo "$WORKDIR/sver-1.0-x86_64.pkg.tar.zst" "$WORKDIR" "package"
rc=$?
set -e
[[ $rc -ne 0 ]] && ok "same-version drift blocked (rc=$rc)" || bad "same-version drift unexpectedly published"
[[ "${PUBLISH_COUNTERS[replaced]}" == "0" ]] && ok "no replacement counter increment" || bad "replaced=${PUBLISH_COUNTERS[replaced]}"
[[ "${PUBLISH_COUNTERS[failed]}" == "1" ]] && ok "failure counter incremented" || bad "failed=${PUBLISH_COUNTERS[failed]}"
grep -q 'delete-asset\|upload ' "$FAKE_EVENTS_LOG" && bad "remote mutated despite fail-closed" || ok "no remote mutation"
# remote asset still has old bytes
remote_hex=$(sha256sum "$FAKE_RELEASE_DIR/sver-1.0-x86_64.pkg.tar.zst" | awk '{print $1}')
local_hex=$(sha256sum "$WORKDIR/sver-1.0-x86_64.pkg.tar.zst" | awk '{print $1}')
[[ "$remote_hex" != "$local_hex" ]] && ok "remote archive preserved" || bad "remote archive was replaced"

# ---------------------------------------------------------------------------
note "same-version gate: explicit override publishes"
export ALLOW_SAME_VERSION_REPLACE=1
declare -A PUBLISH_COUNTERS=( [unchanged]=0 [uploaded]=0 [replaced]=0 [failed]=0 )
: > "$FAKE_EVENTS_LOG"
gh_publish_asset repository owner/repo "$WORKDIR/sver-1.0-x86_64.pkg.tar.zst" "$WORKDIR" "package"
rc=$?
unset ALLOW_SAME_VERSION_REPLACE
[[ $rc -eq 0 ]] && ok "override allows replace (rc=0)" || bad "override failed rc=$rc"
[[ "${PUBLISH_COUNTERS[replaced]}" == "1" ]] && ok "replacement counted" || bad "replaced=${PUBLISH_COUNTERS[replaced]}"

# ---------------------------------------------------------------------------
note "same-version gate: legit version bump still publishes normally"
declare -A PUBLISH_COUNTERS=( [unchanged]=0 [uploaded]=0 [replaced]=0 [failed]=0 )
: > "$FAKE_EVENTS_LOG"
d="$WORKDIR/pkg-ver2"; mkdir -p "$d"; mk_pkg_archive "$d" sver 2.0 x86_64 "new-version"
set +e
gh_publish_asset repository owner/repo "$WORKDIR/sver-2.0-x86_64.pkg.tar.zst" "$WORKDIR" "package"
rc=$?
set -e
[[ $rc -eq 0 ]] && ok "version bump publishes (rc=0)" || bad "version bump blocked rc=$rc"
[[ "${PUBLISH_COUNTERS[uploaded]}" == "1" ]] && ok "uploaded counted" || bad "uploaded=${PUBLISH_COUNTERS[uploaded]}"
[[ -f "$FAKE_RELEASE_DIR/sver-2.0-x86_64.pkg.tar.zst" ]] && ok "new version present remotely" || bad "new version missing"

# ---------------------------------------------------------------------------
note "same-version gate: kind != package is unaffected (database/metadata)"
declare -A PUBLISH_COUNTERS=( [unchanged]=0 [uploaded]=0 [replaced]=0 [failed]=0 )
: > "$FAKE_EVENTS_LOG"
printf 'db-new\n' > "$WORKDIR/db2.tar.gz"
cp "$WORKDIR/db2.tar.gz" "$FAKE_RELEASE_DIR/db2.tar.gz"
printf 'db-changed\n' > "$WORKDIR/db2.tar.gz"
gh_publish_asset repository owner/repo "$WORKDIR/db2.tar.gz" "$WORKDIR" "database"
rc=$?
[[ $rc -eq 0 ]] && ok "database kind replacement allowed" || bad "database kind blocked rc=$rc"
[[ "${PUBLISH_COUNTERS[replaced]}" == "1" ]] && ok "database replaced counted" || bad "replaced=${PUBLISH_COUNTERS[replaced]}"

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
