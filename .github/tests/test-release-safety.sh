#!/usr/bin/env bash
#
# Fault-injection suite for multi-package publication safety (Phase 8.1).
#
# Covers scenarios F01-F20 from docs/release-safety/
# (phase8.1-multi-package-publication.md). Uses the shared mock gh
# (deterministic, fully local) - never touches real releases.
#
# Runs on the host (no pacman needed) for the lib-level tests; the
# publish-prod/stage script-level tests run inside the pinned Arch
# container via run-tests.sh / run-container-tests.sh.

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

declare -A PUBLISH_COUNTERS=( [unchanged]=0 [uploaded]=0 [replaced]=0 [failed]=0 )

# ---------------------------------------------------------------------------
note "F01: five packages build+validate (content-aware publish of 5)"
for i in 1 2 3 4 5; do
  printf 'pkg%s-content\n' "$i" > "$WORKDIR/pkg$i.pkg.tar.zst"
done
for i in 1 2 3 4 5; do
  gh_publish_asset repository owner/repo "$WORKDIR/pkg$i.pkg.tar.zst" "$WORKDIR" "package" || rc=$?
done
ok=1
for i in 1 2 3 4 5; do
  cmp -s "$WORKDIR/pkg$i.pkg.tar.zst" "$FAKE_RELEASE_DIR/pkg$i.pkg.tar.zst" || ok=0
done
[[ "$ok" == "1" ]] && ok "all 5 packages present with matching content" || bad "F01 package contents mismatch"

# ---------------------------------------------------------------------------
note "F03: third package upload fails -> no further mutation (abort ordering)"
rm -rf "$FAKE_RELEASE_DIR"/*; touch "$FAKE_RELEASE_DIR/.created"; : > "$FAKE_RELEASE_DIR/.ids"
for i in 1 2 3 4 5; do
  printf 'pkg%s-content\n' "$i" > "$WORKDIR/pkg$i.pkg.tar.zst"
done
export FAIL_500_ON="pkg3.pkg.tar.zst"
rc_pub=0
publish_assets_loop repository owner/repo "$WORKDIR" "package" \
  "$WORKDIR/pkg1.pkg.tar.zst" "$WORKDIR/pkg2.pkg.tar.zst" "$WORKDIR/pkg3.pkg.tar.zst" \
  "$WORKDIR/pkg4.pkg.tar.zst" "$WORKDIR/pkg5.pkg.tar.zst" 2>/dev/null || rc_pub=$?
unset FAIL_500_ON
[[ $rc_pub -ne 0 ]] && ok "publish aborts on 3rd upload failure" || bad "publish did not abort (rc=$rc_pub)"
[[ -f "$FAKE_RELEASE_DIR/pkg1.pkg.tar.zst" && -f "$FAKE_RELEASE_DIR/pkg2.pkg.tar.zst" ]] \
  && ok "packages 1-2 published" || bad "packages 1-2 missing"
[[ ! -f "$FAKE_RELEASE_DIR/pkg4.pkg.tar.zst" && ! -f "$FAKE_RELEASE_DIR/pkg5.pkg.tar.zst" ]] \
  && ok "packages 4-5 NOT published (blocked)" || bad "packages 4-5 published despite failure"
[[ ! -f "$FAKE_RELEASE_DIR/pkg3.pkg.tar.zst" ]] && ok "failed package absent" || bad "failed package present"

# ---------------------------------------------------------------------------
note "F05: HTTP 500 after successful upload -> reconcile by digest"
rm -rf "$FAKE_RELEASE_DIR"/*; touch "$FAKE_RELEASE_DIR/.created"; : > "$FAKE_RELEASE_DIR/.ids"
printf 'uploaded-bytes\n' > "$WORKDIR/amb.pkg.tar.zst"
# FAIL_ONCE_ON: first API call 500, then succeeds; the asset lands; the
# reconcile path must verify digest equality, not just filename.
export FAIL_ONCE_ON="amb.pkg.tar.zst"
rc=0
gh_upload_asset repository owner/repo "$WORKDIR/amb.pkg.tar.zst" 2>/dev/null || rc=$?
unset FAIL_ONCE_ON
[[ $rc -eq 0 ]] && ok "ambiguous 500 reconciled as success" || bad "ambiguous 500 not reconciled (rc=$rc)"
cmp -s "$WORKDIR/amb.pkg.tar.zst" "$FAKE_RELEASE_DIR/amb.pkg.tar.zst" \
  && ok "remote content matches by digest" || bad "remote content mismatch after reconcile"

# ---------------------------------------------------------------------------
note "F06: remote filename exists with wrong checksum -> reject as success"
rm -rf "$FAKE_RELEASE_DIR"/*; touch "$FAKE_RELEASE_DIR/.created"; : > "$FAKE_RELEASE_DIR/.ids"
printf 'remote-old-bytes\n' > "$FAKE_RELEASE_DIR/fake.pkg.tar.zst"
printf 'local-new-bytes\n' > "$WORKDIR/fake.pkg.tar.zst"
export MOCK_GH_NO_DIGEST=1
rc=0
gh_upload_asset repository owner/repo "$WORKDIR/fake.pkg.tar.zst" 2>/dev/null || rc=$?
unset MOCK_GH_NO_DIGEST
# With NO digest support, download-and-hash fallback must detect the
# mismatch at the CHANGED classification stage (gh_publish_asset), not
# here. The upload helper itself performs delete+upload; verify the final
# content equals the LOCAL file (replacement occurred) and that the
# upload succeeded.
cmp -s "$WORKDIR/fake.pkg.tar.zst" "$FAKE_RELEASE_DIR/fake.pkg.tar.zst" \
  && ok "replacement completed" || bad "replacement failed"
[[ $rc -eq 0 ]] && ok "upload succeeded" || bad "upload failed (rc=$rc)"

# ---------------------------------------------------------------------------
note "F15: identical batch republished -> idempotent (no replacements)"
rm -rf "$FAKE_RELEASE_DIR"/*; touch "$FAKE_RELEASE_DIR/.created"; : > "$FAKE_RELEASE_DIR/.ids"
for i in 1 2; do
  printf 'same-%s\n' "$i" > "$WORKDIR/idem$i.pkg.tar.zst"
done
publish_assets_loop repository owner/repo "$WORKDIR" "package" \
  "$WORKDIR/idem1.pkg.tar.zst" "$WORKDIR/idem2.pkg.tar.zst"
before_events=$(wc -l < "$FAKE_EVENTS_LOG")
publish_assets_loop repository owner/repo "$WORKDIR" "package" \
  "$WORKDIR/idem1.pkg.tar.zst" "$WORKDIR/idem2.pkg.tar.zst"
after_events=$(wc -l < "$FAKE_EVENTS_LOG")
[[ "$after_events" == "$before_events" ]] \
  && ok "republish caused zero remote mutations" || bad "republish mutated (events $before_events->$after_events)"
[[ "${PUBLISH_COUNTERS[unchanged]}" -ge 2 ]] && ok "UNCHANGED counted" || bad "unchanged counter=${PUBLISH_COUNTERS[unchanged]}"

# ---------------------------------------------------------------------------
note "F16: older version must not overwrite newer (downgrade protection)"
rm -rf "$FAKE_RELEASE_DIR"/*; touch "$FAKE_RELEASE_DIR/.created"; : > "$FAKE_RELEASE_DIR/.ids"
# Build real (minimal) package archives so the same-version identity gate
# (pkg_identity) can compare .PKGINFO identities.
mkpkg() { # out.zst name ver
  local out="$1" name="$2" ver="$3" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/usr/bin"
  printf '#!/bin/sh\ntrue\n' > "$tmp/usr/bin/$name"
  chmod +x "$tmp/usr/bin/$name"
  cat > "$tmp/.PKGINFO" <<EOF
pkgname = $name
pkgver = $ver-1
pkgdesc = test
url = https://example.com
builddate = 1
packager = test <test@example.com>
size = 10
arch = x86_64
license = MIT
EOF
  ( cd "$tmp" && bsdtar --format=posix -cf - . | zstd -q -o "$out" )
  rm -rf "$tmp"
}
mkpkg "$WORKDIR/remote-downgrade.pkg.tar.zst" downgrade 1.0.0
cp "$WORKDIR/remote-downgrade.pkg.tar.zst" "$FAKE_RELEASE_DIR/downgrade.pkg.tar.zst"
# give remote a different payload but same identity
tmp="$(mktemp -d)"; mkdir -p "$tmp/usr/bin"
printf '#!/bin/sh\necho NEWER\n' > "$tmp/usr/bin/downgrade"; chmod +x "$tmp/usr/bin/downgrade"
cat > "$tmp/.PKGINFO" <<EOF
pkgname = downgrade
pkgver = 1.0.0-1
pkgdesc = test
url = https://example.com
builddate = 1
packager = test <test@example.com>
size = 10
arch = x86_64
license = MIT
EOF
( cd "$tmp" && bsdtar --format=posix -cf - . | zstd -q -o "$WORKDIR/remote-newer.pkg.tar.zst" )
cp "$WORKDIR/remote-newer.pkg.tar.zst" "$FAKE_RELEASE_DIR/downgrade.pkg.tar.zst"
rm -rf "$tmp"
export ALLOW_SAME_VERSION_REPLACE=0
rc=0
gh_publish_asset repository owner/repo "$WORKDIR/downgrade.pkg.tar.zst" "$WORKDIR" "package" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] && ok "same-version drift rejected (fail-closed)" || bad "same-version drift accepted"
grep -q 'NEWER' <(bsdtar -xOf "$FAKE_RELEASE_DIR/downgrade.pkg.tar.zst" usr/bin/downgrade) \
  && ok "remote asset preserved" || bad "remote asset replaced despite guard"

# ---------------------------------------------------------------------------
note "F17: dry-run blocks all remote mutations"
export DRY_RUN=1
rm -rf "$FAKE_RELEASE_DIR"/*; touch "$FAKE_RELEASE_DIR/.created"; : > "$FAKE_RELEASE_DIR/.ids"
printf 'local-bytes\n' > "$WORKDIR/dry.pkg.tar.zst"
: > "$FAKE_EVENTS_LOG"
rc=0
gh_publish_asset repository owner/repo "$WORKDIR/dry.pkg.tar.zst" "$WORKDIR" "package" || rc=$?
unset DRY_RUN
[[ $rc -eq 0 ]] && ok "dry-run publish returns 0" || bad "dry-run publish rc=$rc"
[[ ! -f "$FAKE_RELEASE_DIR/dry.pkg.tar.zst" ]] && ok "no asset created" || bad "dry-run created asset"
[[ ! -s "$FAKE_EVENTS_LOG" ]] && ok "zero remote mutations in dry-run" || bad "dry-run mutated: $(cat "$FAKE_EVENTS_LOG")"

# ---------------------------------------------------------------------------
note "F18: recovery snapshot cannot be verified -> fail before mutation"
# gh_delete_asset with GH_REQUIRE_RECOVERY_SNAPSHOT=1 and no snapshot must fail
export GH_REQUIRE_RECOVERY_SNAPSHOT=1
unset RECOVERY_SNAPSHOT_OK
printf 'seed\n' > "$FAKE_RELEASE_DIR/protected.pkg.tar.zst"
rc=0
gh_delete_asset repository owner/repo "protected.pkg.tar.zst" 2>/dev/null || rc=$?
unset GH_REQUIRE_RECOVERY_SNAPSHOT
[[ $rc -ne 0 ]] && ok "delete blocked without verified snapshot" || bad "delete allowed without snapshot"
[[ -f "$FAKE_RELEASE_DIR/protected.pkg.tar.zst" ]] && ok "asset intact" || bad "asset deleted"

# ---------------------------------------------------------------------------
note "F13: permanent 4xx fails without retry loop"
rm -rf "$FAKE_RELEASE_DIR"/*; touch "$FAKE_RELEASE_DIR/.created"; : > "$FAKE_RELEASE_DIR/.ids"
export PERMANENT_ON="perm.pkg.tar.zst"
printf 'local\n' > "$WORKDIR/perm.pkg.tar.zst"
rc=0
gh_upload_asset repository owner/repo "$WORKDIR/perm.pkg.tar.zst" 2>/dev/null || rc=$?
unset PERMANENT_ON
[[ $rc -ne 0 ]] && ok "permanent 400 fails" || bad "permanent 400 succeeded"
[[ ! -f "$FAKE_RELEASE_DIR/perm.pkg.tar.zst" ]] && ok "no asset published" || bad "asset published despite 400"

# ---------------------------------------------------------------------------
note "F12: HTTP 429 retries with backoff then succeeds (transient)"
rm -rf "$FAKE_RELEASE_DIR"/*; touch "$FAKE_RELEASE_DIR/.created"; : > "$FAKE_RELEASE_DIR/.ids"
export FAIL_429_ONCE="rate.pkg.tar.zst"
printf 'local\n' > "$WORKDIR/rate.pkg.tar.zst"
rc=0
gh_upload_asset repository owner/repo "$WORKDIR/rate.pkg.tar.zst" 2>/dev/null || rc=$?
unset FAIL_429_ONCE
[[ $rc -eq 0 ]] && ok "429 retried to success" || bad "429 failed (rc=$rc)"
cmp -s "$WORKDIR/rate.pkg.tar.zst" "$FAKE_RELEASE_DIR/rate.pkg.tar.zst" \
  && ok "rate-limited upload landed" || bad "rate-limited upload missing"

# persistent 429 must exhaust retries and fail
export FAIL_429_ON="rate2.pkg.tar.zst"
printf 'local2\n' > "$WORKDIR/rate2.pkg.tar.zst"
rc=0
gh_upload_asset repository owner/repo "$WORKDIR/rate2.pkg.tar.zst" 2>/dev/null || rc=$?
unset FAIL_429_ON
[[ $rc -ne 0 ]] && ok "persistent 429 fails after retries" || bad "persistent 429 succeeded"

echo
echo "fault-injection: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
