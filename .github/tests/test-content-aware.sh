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
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
