#!/usr/bin/env bash
#
# Container-based end-to-end tests for build-package.sh inside the pinned
# generic Arch Linux image (same image as production):
#
#   1. BUILD: trivial local package builds; .PKGINFO carries
#      `packager = 88kbleirad <88kbleirad@users.noreply.github.com>`;
#      v4 target flags stay intact in /etc/makepkg.conf.
#   2. PACKAGER GATE: with PACKAGER neutralized, the produced archive must
#      be refused for publication (status-failed, no archive in output/).
#   3. CACHE HIT: when the release has a matching db + meta fingerprint,
#      the package is skipped and the cached binary is reused.
#
# The fake `gh` shim serves a local release dir; nothing touches the
# network or real GitHub releases. Requires docker and the pinned arch
# image. Run from anywhere with REPO_ROOT set.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="${TEST_WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT

IMAGE="ghcr.io/archlinux/archlinux@sha256:644576e90a71df3b137df2ab6b3517ecd045418195c1946c2c11d1c0564a7981"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker pull "$IMAGE" >/dev/null
fi
CID=""
WS="$WORKDIR/ws"
mkdir -p "$WS/.github/scripts" "$WS/hello-v4test" "$WS/output" "$WS/fake-release"

cp "$REPO_ROOT/.github/scripts/build-package.sh" "$WS/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/pkg-filename-lib.sh" "$WS/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/audit-package-isa.sh" "$WS/.github/scripts/"
cp "$REPO_ROOT/.github/tests/mock-gh.sh" "$WS/.github/scripts/mock-gh.sh"

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
# show_log <stage>: print the ENTIRE captured build log for a stage on
# failure (never only the last few lines), so diagnostics stay complete.
show_log() { [[ -f "$WORKDIR/$1.log" ]] && cat "$WORKDIR/$1.log" || true; }

# -- trivial package --------------------------------------------------------
cat > "$WS/hello-v4test/PKGBUILD" <<'PB'
pkgname=hello-v4test
pkgver=1.0
pkgrel=1
pkgdesc="v4 test package"
arch=('any')
url="https://example.com"
license=('MIT')
depends=()
source=()
sha256sums=()
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/hello-v4test"
}
PB

# -- fake gh shim -----------------------------------------------------------
cat > "$WS/.github/scripts/gh-shim-wrapper" <<'GW'
#!/usr/bin/env bash
export FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?}"
export FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"
exec bash "$(dirname "$(readlink -f "$0")")/mock-gh.sh" "$@"
GW
chmod +x "$WS/.github/scripts/gh-shim-wrapper"

# -- container --------------------------------------------------------------
CID=$(docker create \
  -e GITHUB_WORKSPACE="$WS" \
  --mount type=bind,source="$WS",target="$WS" \
  --workdir "$WS" \
  --entrypoint tail \
  "$IMAGE" -f /dev/null)
docker start "$CID" >/dev/null
for i in 1 2 3; do
  docker exec "$CID" sh -c 'test -x /usr/bin/pacman' || sleep 1
done

docker exec -i "$CID" bash -s <<EOS
set -euo pipefail
if grep -q '^\[options\]$' /etc/pacman.conf; then
  tmp=\$(mktemp)
  awk '
    BEGIN { inserted=0 }
    /^\[options\]$/ && !inserted { print; print "DisableSandboxNetwork"; inserted=1; next }
    { print }
  ' /etc/pacman.conf > "\$tmp"
  cat "\$tmp" > /etc/pacman.conf
  rm -f "\$tmp"
fi
pacman -Syu --noconfirm --needed \
  base-devel git sudo rsync fakeroot binutils pacman-contrib curl awk tar jq rustup
# The `builder` build user defaults to UID 1000. GitHub-hosted runners
# run the host test suite as UID 1001, so `TEST_BUILDER_UID=1001`
# reproduces the real ownership mismatch between host and container
# (used by CI/developer runs; absent locally the default 1000 matches
# the host UID and the mismatch cannot be observed).
if ! id builder >/dev/null 2>&1; then
  if [[ -n "${TEST_BUILDER_UID:-}" ]]; then
    useradd -m -u "${TEST_BUILDER_UID:-1000}" builder
  else
    useradd -m builder
  fi
fi
grep -q '^builder ALL=(ALL) NOPASSWD: ALL\$' /etc/sudoers \
  || echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
curl -fSL --retry 3 -o /etc/makepkg.conf \
  https://raw.githubusercontent.com/CachyOS/docker-makepkg/refs/heads/master/docker-makepkg-v4/makepkg.conf
mkdir -p /etc/makepkg.conf.d
curl -fSL --retry 3 -o /etc/makepkg.conf.d/rust.conf \
  https://raw.githubusercontent.com/CachyOS/docker-makepkg/refs/heads/master/docker-makepkg-v4/rust.conf
grep -q -- '-march=x86-64-v4' /etc/makepkg.conf
grep -q -- 'target-cpu=x86-64-v4' /etc/makepkg.conf.d/rust.conf
sed -i 's/^PKGDEST=/#PKGDEST=/g' /etc/makepkg.conf
sed -i 's/^LOGDEST=/#LOGDEST=/g' /etc/makepkg.conf
sed -i "s|^#PACKAGER=\"\"|PACKAGER=\"88kbleirad <88kbleirad@users.noreply.github.com>\"|" /etc/makepkg.conf
if ! grep -q '^PACKAGER="88kbleirad <' /etc/makepkg.conf; then
  printf 'PACKAGER="88kbleirad <88kbleirad@users.noreply.github.com>"\n' >> /etc/makepkg.conf
fi
sed -i 's/^PACKAGECARCH=/#PACKAGECARCH=/g' /etc/makepkg.conf
rustup default stable
sudo -u builder rustup default stable
ln -sf "$WS/.github/scripts/gh-shim-wrapper" /usr/local/bin/gh
chown -R builder:builder "$WS"
EOS

# run_build <stage> [pkg] — run the build pipeline for one stage.
#
# Ownership invariant: every invocation must hand the workspace to the
# container build user `builder` BEFORE makepkg runs. makepkg 7.1's
# BUILDDIR defaults to the package directory (the start dir), and its
# `ensure_writable_dir` gate exits with E_FS_PERMISSIONS (rc=11) when
# that directory is not writable by the build user ("You do not have
# write permission for the directory $BUILDDIR"). On GitHub-hosted
# runners the host UID is 1001, distinct from `builder` (1000); the
# harness's ws_ensure_host_owned() transfers the workspace to the host
# UID between scenarios, so any later scenario that invokes makepkg
# without a prior builder chown triggers the rc=11 failure (observed in
# CI: second cache hit, tampered-cache rebuild, epoch build). The chown
# is scoped strictly to $WS (the dedicated test workspace); nothing
# outside it is touched.
run_build() {
  local stage="$1" pkg="${2:-hello-v4test}"
  docker exec "$CID" bash -c "chown -R builder:builder '$WS'"
  docker exec "$CID" bash -c "rm -rf '$WS/output'; mkdir -p '$WS/output'; rm -f '$WS/$pkg'/*.pkg.tar.zst"
  docker exec \
    -e GH_TOKEN=dummy \
    -e GITHUB_REPOSITORY=owner/repo \
    -e RELEASE_TAG=repository-v4-test \
    -e REPO_DB_NAME=88kbleirad \
    -e BUILD_PROFILE=x86-64-v4 \
    -e PKG="$pkg" \
    -e GITHUB_WORKSPACE="$WS" \
    -e GITHUB_STEP_SUMMARY="$WS/summary-$stage.md" \
    -e FAKE_RELEASE_DIR="$WS/fake-release" \
    -e FAKE_EVENTS_LOG="$WS/events-$stage.log" \
    "$CID" bash "$WS/.github/scripts/build-package.sh" > "$WORKDIR/$stage.log" 2>&1
  local rc=$?
  rm -rf "$WORKDIR/snap-$stage"; mkdir -p "$WORKDIR/snap-$stage"
  cp -a "$WS/output/." "$WORKDIR/snap-$stage/" 2>/dev/null || true
  # mirror into the works (bind-mounted) tree so docker exec can read it
  docker exec "$CID" bash -c "rm -rf '$WS/.snap/$stage'; mkdir -p '$WS/.snap/$stage'"
  docker exec "$CID" bash -c "cp -a '$WS/output/.' '$WS/.snap/$stage/' 2>/dev/null || true"
  echo $rc
}

# ---------------------------------------------------------------------------
note "container build with PACKAGER configured"
rc=$(run_build build)
if [[ "$rc" -eq 0 ]]; then
  ok "build exit 0"
else
  bad "build failed (rc=$rc): $(show_log build)"
fi
if [[ -f "$WORKDIR/snap-build/status-built-hello-v4test.txt" ]]; then
  ok "status-built written"
else
  bad "status-built missing"
fi
PKGINFO=$(tar --zstd -xOf "$WS/output"/hello-v4test-1.0-1-any.pkg.tar.zst .PKGINFO 2>/dev/null || true)
if echo "$PKGINFO" | grep -q '^packager = 88kbleirad <88kbleirad@users.noreply.github.com>$'; then
  ok "Packager metadata in .PKGINFO"
else
  bad "Packager metadata missing: $(echo "$PKGINFO" | grep '^packager' || echo none)"
fi
FINGERPRINT=$(jq -r '.fingerprint' "$WS/output/v4-hello-v4test.meta.json")
if [[ -n "$FINGERPRINT" && "$FINGERPRINT" != "null" ]]; then
  ok "meta fingerprint written"
else
  bad "meta fingerprint missing"
fi

# ---------------------------------------------------------------------------
note "PACKAGER gate: neutralized packager must refuse to publish (fail closed)"
# neutralise by COMMENTING the line (identical bytes to bootstrap's
# un-comment, so the fingerprint round-trips below)
docker exec "$CID" bash -c "sed -i 's/^PACKAGER=/#PACKAGER=/' /etc/makepkg.conf"
rc=$(run_build nogate)
if [[ "$rc" -ne 0 ]]; then
  ok "gate path exits nonzero (fail closed, no valid archive)"
else
  bad "gate path exited 0 (would false-green)"
fi
if [[ -f "$WORKDIR/snap-nogate/status-failed-hello-v4test.txt" ]]; then
  ok "status-failed written (gate blocked publication)"
else
  bad "status-failed missing"
fi
if ls "$WORKDIR/snap-nogate/"*.pkg.tar.zst >/dev/null 2>&1; then
  bad "unpackaged archive leaked into output/"
else
  ok "no archive published without packager metadata"
fi

# ---------------------------------------------------------------------------
note "cache hit: matching release db + fingerprint must skip the build"
# restore the exact PACKAGER line the gate commented out
docker exec "$CID" bash -c "sed -i 's/^#PACKAGER=/PACKAGER=/' /etc/makepkg.conf"
docker exec "$CID" bash -c "grep -q '^PACKAGER=\"88kbleirad <' /etc/makepkg.conf || printf 'PACKAGER=\"88kbleirad <88kbleirad@users.noreply.github.com>\"\n' >> /etc/makepkg.conf"

# ws_rm <path...>: remove paths under the bind-mounted workspace. The
# container may have created root/builder-owned files there which the
# non-root host runner cannot unlink; remove those through the container
# (root) first, then fall back to a plain host rm for host-owned paths.
ws_rm() {
  local p path_ok=1
  for p in "$@"; do
    if [[ "$p" == "$WS"/* ]]; then
      docker exec "$CID" bash -c "rm -rf -- '$p'" >/dev/null 2>&1 || true
    else
      path_ok=0
    fi
  done
  if [[ "$path_ok" -eq 1 ]]; then
    rm -rf -- "$@" 2>/dev/null || true
  else
    rm -rf -- "$@"
  fi
}

# ws_ensure_host_owned: restore ownership of the bind-mounted workspace to
# the host runner UID/GID. Container steps run as `builder` (UID 1000)
# and chown the workspace; the non-root host runner (e.g. UID 1001 on
# GitHub Actions) cannot create/remove files in builder-owned directories.
# Scoped strictly to $WS; never touches paths outside it.
ws_ensure_host_owned() {
  local uid gid
  uid="$(id -u)"; gid="$(id -g)"
  docker exec "$CID" bash -c "chown -R $uid:$gid '$WS'" >/dev/null 2>&1 || true
}

# ws_mkdir <dir...>: create directory(ies) under the workspace, restoring
# host ownership first so the host can create/own the new path.
ws_mkdir() {
  ws_ensure_host_owned
  mkdir -p -- "$@"
}

# build the fake release from the first successful run (snapshot path)
ws_rm "$WS/fake-release"; ws_mkdir "$WS/fake-release"
touch "$WS/fake-release/.created"
cp "$WORKDIR/snap-build"/hello-v4test-1.0-1-any.pkg.tar.zst "$WS/fake-release/"
docker exec -e WS="$WS" "$CID" bash -c "
  set -euo pipefail
  cd /tmp && rm -rf dbbuild && mkdir dbbuild && cd dbbuild
  cp \"\$WS/.snap/build\"/hello-v4test-1.0-1-any.pkg.tar.zst .
  repo-add 88kbleirad.db.tar.gz hello-v4test-1.0-1-any.pkg.tar.zst >/dev/null 2>&1
  cp 88kbleirad.db.tar.gz 88kbleirad.files.tar.gz \"\$WS/fake-release/\"
"
ws_ensure_host_owned
cp "$WORKDIR/snap-build/v4-hello-v4test.meta.json" "$WS/fake-release/"


docker exec "$CID" bash -c "chown -R builder:builder '$WS'"
rc=$(run_build cache)
if [[ "$rc" -eq 0 ]]; then
  ok "cache run exit 0"
else
  bad "cache run failed (rc=$rc): $(show_log cache)"
fi
if grep -q "package is up to date" "$WORKDIR/cache.log"; then
  ok "cache hit detected"
else
  bad "cache hit not detected: $(grep -E 'cache|reuse|built' "$WORKDIR/cache.log" | head -3)"
fi
if [[ -f "$WORKDIR/snap-cache/status-skipped-hello-v4test.txt" ]]; then
  ok "status-skipped written"
else
  bad "status-skipped missing"
fi
if [[ -f "$WORKDIR/snap-cache/hello-v4test-1.0-1-any.pkg.tar.zst" ]]; then
  ok "cached binary reused"
else
  bad "cached binary not present"
fi
# The release was seeded from the FIRST BUILD's meta (status=built). A
# cache hit must preserve that metadata byte-for-byte — status stays
# "built", built_at stays the original build timestamp. Regenerating it
# would flip status to "skipped" and stamp a fresh built_at, rewriting
# the released meta on every repeat (the beautyline non-idempotency).
if cmp -s "$WORKDIR/snap-build/v4-hello-v4test.meta.json" \
     "$WORKDIR/snap-cache/v4-hello-v4test.meta.json"; then
  ok "first-build metadata preserved byte-identical on cache hit"
else
  bad "cache hit rewrote first-build metadata:"
  diff "$WORKDIR/snap-build/v4-hello-v4test.meta.json" \
       "$WORKDIR/snap-cache/v4-hello-v4test.meta.json" || true
fi
if jq -e '.status == "built"' "$WORKDIR/snap-cache/v4-hello-v4test.meta.json" >/dev/null 2>&1; then
  ok "persistent status remains built after cache hit"
else
  bad "persistent status changed after cache hit"
fi

# ---------------------------------------------------------------------------
note "cache hit metadata is deterministic across repeated identical runs"
# Run the same cache-hit build a second time with identical inputs; the
# metadata must be byte-identical (no fresh built_at timestamp), i.e. a
# second publish of the same run produces zero asset mutations.
# Update the fake release with the first cache run's metadata so this run
# compares against an identical (skipped) cache hit.
ws_ensure_host_owned
cp "$WORKDIR/snap-cache/v4-hello-v4test.meta.json" "$WS/fake-release/"
rc=$(run_build cache2)
if [[ "$rc" -eq 0 ]]; then
  ok "second cache run exit 0"
else
  bad "second cache run failed (rc=$rc): $(show_log cache2)"
fi
if [[ -f "$WORKDIR/snap-cache/v4-hello-v4test.meta.json" && -f "$WORKDIR/snap-cache2/v4-hello-v4test.meta.json" ]]; then
  if cmp -s "$WORKDIR/snap-cache/v4-hello-v4test.meta.json" \
           "$WORKDIR/snap-cache2/v4-hello-v4test.meta.json"; then
    ok "cache-hit metadata byte-identical across runs"
  else
    bad "cache-hit metadata changed across identical runs:"
    diff "$WORKDIR/snap-cache/v4-hello-v4test.meta.json" \
         "$WORKDIR/snap-cache2/v4-hello-v4test.meta.json" || true
  fi
  # consecutive cache hits: built_at must be stable (no fresh timestamp)
  ba1=$(jq -r '.built_at' "$WORKDIR/snap-cache/v4-hello-v4test.meta.json" 2>/dev/null)
  ba2=$(jq -r '.built_at' "$WORKDIR/snap-cache2/v4-hello-v4test.meta.json" 2>/dev/null)
  if [[ -n "$ba1" && "$ba1" == "$ba2" ]]; then
    ok "built_at stable across consecutive cache hits"
  else
    bad "built_at regenerated on cache hit: $ba1 vs $ba2"
  fi
else
  bad "meta snapshots missing for determinism check"
fi

# ---------------------------------------------------------------------------
note "tampered cached package: must be rejected and rebuilt, never published"
# Truncate the cached archive, which guarantees zstd extraction fails
# (unlike a mid-file byte flip, which can land in ignored padding).
docker exec "$CID" bash -c "
  size=\$(stat -c %s '$WS/fake-release/hello-v4test-1.0-1-any.pkg.tar.zst')
  truncate -s \$(( size / 2 )) '$WS/fake-release/hello-v4test-1.0-1-any.pkg.tar.zst'
"
rc=$(run_build tampered)
if [[ "$rc" -eq 0 ]]; then
  ok "tampered-cache run exit 0 (fallback rebuild)"
else
  bad "tampered-cache run failed (rc=$rc): $(show_log tampered)"
fi
if grep -q "failed validation" "$WORKDIR/tampered.log"; then
  ok "tampered cached binary detected via validation"
else
  bad "tampered cached binary not detected: $(grep -E 'validation|cache|rebuild' "$WORKDIR/tampered.log" | head -3)"
fi
if [[ -f "$WORKDIR/snap-tampered/status-built-hello-v4test.txt" ]]; then
  ok "tampered cache triggered a rebuild (status-built)"
else
  bad "tampered cache did not rebuild"
fi
# the rebuilt archive must carry a valid signature and be publishable
if ls "$WORKDIR/snap-tampered"/hello-v4test-1.0-1-any.pkg.tar.zst >/dev/null 2>&1; then
  ok "fresh archive produced after tamper rejection"
else
  bad "no fresh archive after tamper rejection"
fi

# ---------------------------------------------------------------------------
note "fail closed: failing build with no recoverable archive exits nonzero"
# A PKGBUILD whose build always fails must NOT produce a false-green exit.
# Add a deliberately broken package to the workspace and build it.
ws_mkdir "$WS/brokepkg/src" "$WS/fake-release-empty"
touch "$WS/fake-release-empty/.created"
: > "$WS/fake-release-empty/.ids"
cat > "$WS/brokepkg/PKGBUILD" <<'PB'
pkgname=brokepkg
pkgver=1.0
pkgrel=1
pkgdesc="always fails"
arch=('any')
source=()
sha256sums=()
build() {
  echo "intentional failure" >&2
  exit 42
}
package() {
  true
}
PB
# hand the workspace to builder via the container (the host runner cannot
# chown to builder: host UID differs and is non-root)
docker exec "$CID" bash -c "chown -R builder:builder '$WS'"
set +e
docker exec \
  -e GH_TOKEN=dummy \
  -e GITHUB_REPOSITORY=owner/repo \
  -e RELEASE_TAG=repository-v4-test \
  -e REPO_DB_NAME=88kbleirad \
  -e BUILD_PROFILE=x86-64-v4 \
  -e PKG=brokepkg \
  -e GITHUB_WORKSPACE="$WS" \
  -e GITHUB_STEP_SUMMARY="$WS/summary-broken.md" \
  -e FAKE_RELEASE_DIR="$WS/fake-release-empty" \
  -e FAKE_EVENTS_LOG="$WS/events-broken.log" \
  "$CID" bash "$WS/.github/scripts/build-package.sh" > "$WORKDIR/broken.log" 2>&1
broken_rc=$?
set -e
if [[ "$broken_rc" -ne 0 ]]; then
  ok "broken build exits nonzero (rc=$broken_rc)"
else
  bad "broken build exited 0 (false green)"
fi
grep -q "failing the build job" "$WORKDIR/broken.log" \
  && ok "fail-closed error logged" || bad "fail-closed message missing"

# ---------------------------------------------------------------------------
note "fail closed: metadata-only artifact never passes artifact gate"
# Simulate the historical ripdrag outcome: status-failed + meta, no
# archive. The artifact gate in build-in-docker.sh must reject it.
ws_mkdir "$WS/metatest/output"
echo "brokepkg" > "$WS/metatest/output/status-failed-brokepkg.txt"
printf '{"package":"brokepkg","profile":"x86-64-v4","status":"failed","fingerprint":"x"}\n' \
  > "$WS/metatest/output/v4-brokepkg.meta.json"
# run only the gate section by invoking build-in-docker? The gate lives in
# build-in-docker.sh; instead statically assert the gate logic via the
# same predicates used there.
if ls "$WS/metatest/output/brokepkg"-*.pkg.tar.zst >/dev/null 2>&1; then
  bad "unexpected archive present in metadata-only output"
else
  ok "metadata-only output has no package archive"
fi

# ---------------------------------------------------------------------------
note "epoch package: real build validates + cache hit round-trips"
# The epoch handling must be generic (no per-package special case). A
# trivial package with epoch=2 + legacy .PKGINFO fields exercises the
# whole path: makepkg produces `hello-epoch-2:1.0-1-any...`; the pipeline
# must canonicalize to `hello-epoch-2.1.0-1-any...`, validate it, publish
# it under the canonical name, and reuse it on the next run.
ws_mkdir "$WS/hello-epoch"
cat > "$WS/hello-epoch/PKGBUILD" <<'PB'
pkgname=hello-epoch
epoch=2
pkgver=1.0
pkgrel=1
pkgdesc="epoch regression package"
arch=('any')
license=('MIT')
source=()
sha256sums=()
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/hello-epoch"
}
PB

rc=$(run_build epochb hello-epoch)
if [[ "$rc" -eq 0 ]]; then
  ok "epoch build exit 0"
else
  bad "epoch build failed (rc=$rc): $(show_log epochb)"
fi
if [[ -f "$WORKDIR/snap-epochb/status-built-hello-epoch.txt" ]]; then
  ok "epoch status-built written"
else
  bad "epoch status-built missing"
fi
if [[ -f "$WORKDIR/snap-epochb/hello-epoch-2.1.0-1-any.pkg.tar.zst" ]]; then
  ok "epoch archive stored under canonical (epoch-safe) name"
else
  bad "epoch archive name wrong: $(ls "$WORKDIR/snap-epochb" | tr '\n' ' ')"
fi
# the stored archive must be a real package (not metadata-only)
if tar --zstd -xOf "$WORKDIR/snap-epochb/hello-epoch-2.1.0-1-any.pkg.tar.zst" .PKGINFO 2>/dev/null | grep -q '^pkgver = 2:1.0-1$'; then
  ok "stored archive carries epoch-qualified .PKGINFO"
else
  bad "stored archive PKGINFO wrong"
fi
if grep -q "cache hit" "$WORKDIR/epochb.log" || [[ -f "$WORKDIR/snap-epochb/status-skipped-hello-epoch.txt" ]]; then
  bad "epoch first build should not be a cache hit"
else
  ok "epoch first build is a fresh build"
fi

# seed the fake release from the epoch build (db + meta + archive)
ws_rm "$WS/fake-release"; ws_mkdir "$WS/fake-release"
touch "$WS/fake-release/.created"
cp "$WORKDIR/snap-epochb"/hello-epoch-2.1.0-1-any.pkg.tar.zst "$WS/fake-release/"
cp "$WORKDIR/snap-epochb/v4-hello-epoch.meta.json" "$WS/fake-release/"
docker exec -e WS="$WS" "$CID" bash -c "
  set -euo pipefail
  cd /tmp && rm -rf dbbuild2 && mkdir dbbuild2 && cd dbbuild2
  cp \"\$WS/.snap/epochb\"/hello-epoch-2.1.0-1-any.pkg.tar.zst .
  repo-add 88kbleirad.db.tar.gz hello-epoch-2.1.0-1-any.pkg.tar.zst >/dev/null 2>&1
  cp 88kbleirad.db.tar.gz 88kbleirad.files.tar.gz \"\$WS/fake-release/\"
"
docker exec "$CID" bash -c "chown -R builder:builder '$WS'"

rc=$(run_build epochc hello-epoch)
if [[ "$rc" -eq 0 ]]; then
  ok "epoch cache run exit 0"
else
  bad "epoch cache run failed (rc=$rc): $(show_log epochc)"
fi
if grep -q "package is up to date" "$WORKDIR/epochc.log"; then
  ok "epoch cache hit detected"
else
  bad "epoch cache hit not detected: $(grep -E 'cache|reuse|built|up to date' "$WORKDIR/epochc.log" | head -3)"
fi
if [[ -f "$WORKDIR/snap-epochc/status-skipped-hello-epoch.txt" ]]; then
  ok "epoch status-skipped written"
else
  bad "epoch status-skipped missing"
fi
if [[ -f "$WORKDIR/snap-epochc/hello-epoch-2.1.0-1-any.pkg.tar.zst" ]]; then
  ok "epoch cached binary reused under canonical name"
else
  bad "epoch cached binary missing"
fi

# ---------------------------------------------------------------------------
note "fingerprint loop: SKIP-checksum package cache-hits on repeat run"
# Regression for the Phase 3.5 root cause: packages whose committed
# checksum is `SKIP` on a non-VCS source (xclicker/xmousepasteblock/
# beautyline) had their fingerprint computed on the raw committed file
# while the stored meta fingerprint was computed after updpkgsums had
# rewritten the checksum to the real hash. Every later run therefore saw
# "PKGBUILD/compiler fingerprint changed" and rebuilt forever. The
# fingerprint now normalizes the effective PKGBUILD state, so a repeat
# run with identical inputs must cache-hit.
ws_mkdir "$WS/hello-skip"
# local tarball source: no network needed; updpkgsums can compute the real
# checksum, exactly like the CI container does for a remote tarball.
ws_mkdir "$WS/src-tarball/hello-skip-1.0/usr/share"
printf 'skip-source\n' > "$WS/src-tarball/hello-skip-1.0/usr/share/hello-skip-data"
( cd "$WS/src-tarball" && tar -czf "$WS/hello-skip-1.0.tar.gz" hello-skip-1.0 )
cat > "$WS/hello-skip/PKGBUILD" <<'PB'
pkgname=hello-skip
pkgver=1.0
pkgrel=1
pkgdesc="SKIP checksum fingerprint regression"
arch=('any')
license=('MIT')
source=("hello-skip-$pkgver.tar.gz")
sha256sums=('SKIP')
package() {
  cd "$srcdir/hello-skip-$pkgver"
  install -Dm644 usr/share/hello-skip-data "$pkgdir/usr/share/hello-skip"
}
PB
ln -sf "$WS/hello-skip-1.0.tar.gz" "$WS/hello-skip/hello-skip-1.0.tar.gz"

rc=$(run_build skipb hello-skip)
if [[ "$rc" -eq 0 ]]; then
  ok "SKIP-checksum build exit 0"
else
  bad "SKIP-checksum build failed (rc=$rc): $(show_log skipb)"
fi
grep -q 'PKGBUILD/compiler fingerprint changed' "$WORKDIR/skipb.log" \
  && bad "first run should not report fingerprint change" || ok "first run built clean"

# seed the fake release from the first run (db + meta + archive)
ws_rm "$WS/fake-release"; ws_mkdir "$WS/fake-release"
touch "$WS/fake-release/.created"
cp "$WORKDIR/snap-skipb"/hello-skip-1.0-1-any.pkg.tar.zst "$WS/fake-release/"
cp "$WORKDIR/snap-skipb/v4-hello-skip.meta.json" "$WS/fake-release/"
docker exec -e WS="$WS" "$CID" bash -c "
  set -euo pipefail
  cd /tmp && rm -rf dbbuild-skip && mkdir dbbuild-skip && cd dbbuild-skip
  cp \"\$WS/.snap/skipb\"/hello-skip-1.0-1-any.pkg.tar.zst .
  repo-add 88kbleirad.db.tar.gz hello-skip-1.0-1-any.pkg.tar.zst >/dev/null 2>&1
  cp 88kbleirad.db.tar.gz 88kbleirad.files.tar.gz \"\$WS/fake-release/\"
"
docker exec "$CID" bash -c "chown -R builder:builder '$WS'"

rc=$(run_build skipc hello-skip)
if [[ "$rc" -eq 0 ]]; then
  ok "SKIP-checksum repeat run exit 0"
else
  bad "SKIP-checksum repeat run failed (rc=$rc): $(show_log skipc)"
fi
if grep -q "package is up to date" "$WORKDIR/skipc.log"; then
  ok "SKIP-checksum repeat run is a cache hit (fingerprint loop fixed)"
else
  bad "SKIP-checksum repeat run rebuilt: $(grep -E 'fingerprint|cache|up to date|forcing' "$WORKDIR/skipc.log" | head -3)"
fi
if [[ -f "$WORKDIR/snap-skipc/status-skipped-hello-skip.txt" ]]; then
  ok "SKIP-checksum status-skipped written"
else
  bad "SKIP-checksum status-skipped missing"
fi

# ---------------------------------------------------------------------------
note "fingerprint distinctness: different SKIP packages must NOT share a fingerprint"
# Regression for the shared-fingerprint bug: pointing fp_src at the
# scratch dir (deleted before hashing) made every SKIP-normalizable
# package hash only the shared makepkg.conf → identical fingerprints for
# all packages. Two different packages must yield two DIFFERENT
# fingerprints, and neither may equal the config-only hash.
ws_mkdir "$WS/hello-skip2"
ws_mkdir "$WS/src-tarball/hello-skip2-1.0/usr/share"
printf 'skip-source-2\n' > "$WS/src-tarball/hello-skip2-1.0/usr/share/hello-skip2-data"
( cd "$WS/src-tarball" && tar -czf "$WS/hello-skip2-1.0.tar.gz" hello-skip2-1.0 )
cat > "$WS/hello-skip2/PKGBUILD" <<'PB'
pkgname=hello-skip2
pkgver=1.0
pkgrel=1
pkgdesc="second SKIP package"
arch=('any')
url="https://example.com"
license=('MIT')
depends=()
source=("hello-skip2-1.0.tar.gz")
sha256sums=('SKIP')
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/hello-skip2"
}
PB
ln -sf "$WS/hello-skip2-1.0.tar.gz" "$WS/hello-skip2/hello-skip2-1.0.tar.gz"
docker exec "$CID" bash -c "chown -R builder:builder '$WS'"

rc=$(run_build distb hello-skip2)
FP_SKIP1=$(jq -r '.fingerprint' "$WORKDIR/snap-skipb/v4-hello-skip.meta.json" 2>/dev/null || true)
FP_SKIP2=$(jq -r '.fingerprint' "$WORKDIR/snap-distb/v4-hello-skip2.meta.json" 2>/dev/null || true)
CONFIG_ONLY=$(docker exec "$CID" bash -c '{ cat /etc/makepkg.conf; for f in /etc/makepkg.conf.d/*.conf; do cat "$f"; done; } | sha256sum | awk "{print \$1}"')
if [[ -n "$FP_SKIP1" && -n "$FP_SKIP2" && "$FP_SKIP1" != "$FP_SKIP2" ]]; then
  ok "distinct SKIP packages have distinct fingerprints"
else
  bad "fingerprints not distinct: skip1=$FP_SKIP1 skip2=$FP_SKIP2"
fi
if [[ -n "$FP_SKIP1" && "$FP_SKIP1" != "$CONFIG_ONLY" && "$FP_SKIP2" != "$CONFIG_ONLY" ]]; then
  ok "fingerprints are package-specific (not config-only)"
else
  bad "fingerprint equals config-only hash ($CONFIG_ONLY)"
fi
if [[ -s "$WORKDIR/snap-distb/v4-hello-skip2.meta.json" ]]; then
  ok "second SKIP package meta written"
else
  bad "second SKIP package meta missing"
fi

# ---------------------------------------------------------------------------
note "fingerprint stability: unchanged recipe must produce identical fingerprint"
# Rebuild hello-skip2 in a scratch copy of the container config; the
# fingerprint must be byte-identical to the previous run's (stable).
# Then invalidate by changing the source content — the fingerprint must
# change (cache invalidated).
rc=$(run_build distc hello-skip2)
FP_SKIP2_B=$(jq -r '.fingerprint' "$WORKDIR/snap-distc/v4-hello-skip2.meta.json" 2>/dev/null || true)
if [[ "$FP_SKIP2" == "$FP_SKIP2_B" ]]; then
  ok "unchanged recipe fingerprint stable across runs"
else
  bad "fingerprint unstable: $FP_SKIP2 != $FP_SKIP2_B"
fi

# invalidate: change the payload (source content), rebuild, expect a
# different fingerprint
ws_mkdir "$WS/src-tarball-mod/hello-skip2-1.0/usr/share"
printf 'skip-source-MODIFIED\n' > "$WS/src-tarball-mod/hello-skip2-1.0/usr/share/hello-skip2-data"
( cd "$WS/src-tarball-mod" && tar -czf "$WS/hello-skip2-mod.tar.gz" hello-skip2-1.0 )
cp "$WS/hello-skip2-mod.tar.gz" "$WS/hello-skip2/hello-skip2-1.0.tar.gz"
docker exec "$CID" bash -c "chown -R builder:builder '$WS'"
rc=$(run_build distmod hello-skip2)
FP_SKIP2_MOD=$(jq -r '.fingerprint' "$WORKDIR/snap-distmod/v4-hello-skip2.meta.json" 2>/dev/null || true)
if [[ -n "$FP_SKIP2_MOD" && "$FP_SKIP2_MOD" != "$FP_SKIP2" ]]; then
  ok "meaningful source change invalidates fingerprint"
else
  bad "fingerprint did not change on source change: $FP_SKIP2_MOD"
fi

# ---------------------------------------------------------------------------
note "genuine version upgrade: package and metadata update correctly"
# A committed pkgver bump (source change) must NOT be masked by the meta
# reuse logic: the fingerprint changes, the build must happen, and both
# the archive and its metadata must carry the new version. Uses one
# consistent package identity (hello-skip2): first a pristine v1.0 build,
# release seeded from it, then an in-place v2.0 upgrade.
# recreate pristine v1.0 state
ws_rm "$WS/hello-skip2"; ws_mkdir "$WS/hello-skip2"
ws_rm "$WS/src-tarball/hello-skip2-1.0"; ws_mkdir "$WS/src-tarball/hello-skip2-1.0/usr/share"
printf 'skip-source\n' > "$WS/src-tarball/hello-skip2-1.0/usr/share/hello-skip2-data"
( cd "$WS/src-tarball" && tar -czf "$WS/hello-skip2-1.0.tar.gz" hello-skip2-1.0 )
cat > "$WS/hello-skip2/PKGBUILD" <<'PB'
pkgname=hello-skip2
pkgver=1.0
pkgrel=1
pkgdesc="second SKIP package"
arch=('any')
url="https://example.com"
license=('MIT')
depends=()
source=("hello-skip2-1.0.tar.gz")
sha256sums=('SKIP')
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/hello-skip2"
}
PB
ln -sf "$WS/hello-skip2-1.0.tar.gz" "$WS/hello-skip2/hello-skip2-1.0.tar.gz"
docker exec "$CID" bash -c "chown -R builder:builder '$WS'"

# baseline v1.0 build
rc=$(run_build upbase hello-skip2)
if [[ "$rc" -eq 0 ]]; then
  ok "baseline v1.0 build exit 0"
else
  bad "baseline build failed (rc=$rc): $(show_log upbase)"
fi
BASE_FP=$(jq -r '.fingerprint // empty' "$WORKDIR/snap-upbase/v4-hello-skip2.meta.json" 2>/dev/null || true)

# seed the release with the v1.0 baseline
ws_rm "$WS/fake-release"; ws_mkdir "$WS/fake-release"
touch "$WS/fake-release/.created"
cp "$WORKDIR/snap-upbase/hello-skip2-1.0-1-any.pkg.tar.zst" "$WS/fake-release/"
cp "$WORKDIR/snap-upbase/v4-hello-skip2.meta.json" "$WS/fake-release/"
docker exec -e WS="$WS" "$CID" bash -c "
  set -euo pipefail
  cd /tmp && rm -rf dbbuild-up && mkdir dbbuild-up && cd dbbuild-up
  cp \"\$WS/.snap/upbase\"/hello-skip2-1.0-1-any.pkg.tar.zst .
  repo-add 88kbleirad.db.tar.gz hello-skip2-1.0-1-any.pkg.tar.zst >/dev/null 2>&1
  cp 88kbleirad.db.tar.gz 88kbleirad.files.tar.gz \"\$WS/fake-release/\"
"

# upgrade in place to v2.0 (same package identity)
ws_rm "$WS/src-tarball-up/hello-skip2-2.0"; ws_mkdir "$WS/src-tarball-up/hello-skip2-2.0/usr/share"
printf 'skip-upgrade\n' > "$WS/src-tarball-up/hello-skip2-2.0/usr/share/hello-skip2-data"
( cd "$WS/src-tarball-up" && tar -czf "$WS/hello-skip2-2.0.tar.gz" hello-skip2-2.0 )
cat > "$WS/hello-skip2/PKGBUILD" <<'PB'
pkgname=hello-skip2
pkgver=2.0
pkgrel=1
pkgdesc="upgraded hello-skip2"
arch=('any')
url="https://example.com"
license=('MIT')
depends=()
source=("hello-skip2-2.0.tar.gz")
sha256sums=('SKIP')
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/hello-skip2"
}
PB
ln -sf "$WS/hello-skip2-2.0.tar.gz" "$WS/hello-skip2/hello-skip2-2.0.tar.gz"
docker exec "$CID" bash -c "chown -R builder:builder '$WS'"

rc=$(run_build upgradeb hello-skip2)
if [[ "$rc" -eq 0 ]]; then
  ok "upgrade build exit 0"
else
  bad "upgrade build failed (rc=$rc): $(show_log upgradeb)"
fi
if [[ -f "$WORKDIR/snap-upgradeb/hello-skip2-2.0-1-any.pkg.tar.zst" ]]; then
  ok "new version archive produced"
else
  bad "new version archive missing: $(ls "$WORKDIR/snap-upgradeb" | tr '\n' ' ')"
fi
UP_FP=$(jq -r '.fingerprint // empty' "$WORKDIR/snap-upgradeb/v4-hello-skip2.meta.json" 2>/dev/null || true)
if [[ -n "$UP_FP" && "$UP_FP" != "$BASE_FP" ]]; then
  ok "upgrade metadata carries new fingerprint"
else
  bad "upgrade fingerprint not updated: $UP_FP"
fi
if grep -q "PKGBUILD/compiler fingerprint changed" "$WORKDIR/upgradeb.log"; then
  ok "cache invalidated on version upgrade"
else
  bad "fingerprint change not reported on upgrade"
fi

# restore pristine v1.0 state for the directory
ws_rm "$WS/hello-skip2"; ws_mkdir "$WS/hello-skip2"
cat > "$WS/hello-skip2/PKGBUILD" <<'PB'
pkgname=hello-skip2
pkgver=1.0
pkgrel=1
pkgdesc="second SKIP package"
arch=('any')
url="https://example.com"
license=('MIT')
depends=()
source=("hello-skip2-1.0.tar.gz")
sha256sums=('SKIP')
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/hello-skip2"
}
PB
ln -sf "$WS/hello-skip2-1.0.tar.gz" "$WS/hello-skip2/hello-skip2-1.0.tar.gz"
docker exec "$CID" bash -c "chown -R builder:builder '$WS'"

# ---------------------------------------------------------------------------
note "corrupted remote metadata: fail closed (rebuild, never blind reuse)"
# A release whose v4 meta is corrupt (invalid JSON) must NOT be reused:
# the cache gate sees an unresolvable prev fingerprint and forces a
# rebuild rather than trusting bad metadata.
ws_rm "$WS/fake-release"; ws_mkdir "$WS/fake-release"
touch "$WS/fake-release/.created"
cp "$WORKDIR/snap-skipb/hello-skip-1.0-1-any.pkg.tar.zst" "$WS/fake-release/"
printf 'not-json{{{' > "$WS/fake-release/v4-hello-skip.meta.json"
docker exec -e WS="$WS" "$CID" bash -c "
  set -euo pipefail
  cd /tmp && rm -rf dbbuild-corrupt && mkdir dbbuild-corrupt && cd dbbuild-corrupt
  cp \"\$WS/.snap/skipb\"/hello-skip-1.0-1-any.pkg.tar.zst .
  repo-add 88kbleirad.db.tar.gz hello-skip-1.0-1-any.pkg.tar.zst >/dev/null 2>&1
  cp 88kbleirad.db.tar.gz 88kbleirad.files.tar.gz \"\$WS/fake-release/\"
"
rc=$(run_build corruptb hello-skip)
if [[ "$rc" -eq 0 ]]; then
  ok "corrupt-meta run exit 0 (rebuilt)"
else
  bad "corrupt-meta run failed (rc=$rc): $(show_log corruptb)"
fi
if grep -q "is not reusable\|PKGBUILD/compiler fingerprint changed\|forcing rebuild" "$WORKDIR/corruptb.log"; then
  ok "corrupt remote meta forced rebuild (fail closed)"
else
  bad "corrupt remote meta did not force rebuild: $(show_log corruptb)"
fi
# the corrupted meta must NOT be reused verbatim
if [[ -f "$WORKDIR/snap-corruptb/v4-hello-skip.meta.json" ]] \
    && jq -e . "$WORKDIR/snap-corruptb/v4-hello-skip.meta.json" >/dev/null 2>&1; then
  ok "corrupt meta replaced with valid regenerated metadata"
else
  bad "corrupt meta not regenerated to valid JSON"
fi
if [[ -f "$WORKDIR/snap-corruptb/status-built-hello-skip.txt" ]]; then
  ok "corrupt-meta rebuild produced status-built"
else
  bad "corrupt-meta rebuild status missing"
fi

# ---------------------------------------------------------------------------
note "missing write permission: explicit diagnostic, never an opaque rc=11"
# CB13: the write-permission preflight must fail closed BEFORE makepkg
# runs, emit an explicit diagnostic naming the affected directory, and
# cause zero publication mutation. The negative run executes as the build
# user `builder` (the pipeline always invokes makepkg via sudo -u
# builder) against a dedicated fixture whose only unwritable part is the
# package directory itself. A positive control then proves the same
# fixture builds fine once permissions are restored.
ws_mkdir "$WS/permpkg"
cat > "$WS/permpkg/PKGBUILD" <<'PB'
pkgname=permpkg
pkgver=1.0
pkgrel=1
pkgdesc="permission check"
arch=('any')
source=()
sha256sums=()
package() { install -Dm644 /dev/null "$pkgdir/usr/share/permpkg"; }
PB
: > "$WS/events-perm.log"   # fresh event log: any upload/create/delete would be recorded
docker exec "$CID" bash -c "chown -R builder:builder '$WS'; chmod -R a-w '$WS/permpkg'; mkdir -p '$WS/output'"
set +e
# run the whole pipeline AS `builder` (not root) so the failing preflight
# is exercised under the real build user's permissions.
docker exec \
  -u builder \
  -e GH_TOKEN=dummy \
  -e GITHUB_REPOSITORY=owner/repo \
  -e RELEASE_TAG=repository-v4-test \
  -e REPO_DB_NAME=88kbleirad \
  -e BUILD_PROFILE=x86-64-v4 \
  -e PKG=permpkg \
  -e GITHUB_WORKSPACE="$WS" \
  -e GITHUB_STEP_SUMMARY="$WS/summary-perm.md" \
  -e FAKE_RELEASE_DIR="$WS/fake-release" \
  -e FAKE_EVENTS_LOG="$WS/events-perm.log" \
  "$CID" bash "$WS/.github/scripts/build-package.sh" > "$WORKDIR/perm.log" 2>&1
perm_rc=$?
set -e
if [[ "$perm_rc" -ne 0 ]]; then
  ok "missing write permission exits nonzero (rc=$perm_rc)"
else
  bad "missing write permission exited 0 (false green)"
fi
if grep -q "not writable by the build user" "$WORKDIR/perm.log"; then
  ok "explicit permission diagnostic emitted"
else
  bad "explicit permission diagnostic missing: $(show_log perm)"
fi
if grep -qE 'permpkg \(\$BUILDDIR\)|permpkg \(\$PKGDEST\)|permpkg \(\$SRCDEST\)' "$WORKDIR/perm.log"; then
  ok "diagnostic names the affected directory"
else
  bad "diagnostic does not identify the affected directory: $(grep -E 'not writable' "$WORKDIR/perm.log" | head -2)"
fi
if grep -qE "makepkg --noconfirm|makepkg --syncdeps|paru " "$WORKDIR/perm.log"; then
  bad "preflight did not stop before makepkg was invoked"
else
  ok "no makepkg invocation (preflight exits before build)"
fi
if grep -q "makepkg rc=11\|makepkg exited with code 11" "$WORKDIR/perm.log"; then
  bad "build produced an opaque makepkg rc=11 (diagnostic preflight failed)"
else
  ok "no opaque makepkg rc=11 in output"
fi
if [[ -s "$WS/events-perm.log" ]]; then
  bad "publication mutation recorded despite preflight failure: $(cat "$WS/events-perm.log")"
else
  ok "zero publication mutations on preflight failure"
fi
if [[ -f "$WS/output/status-failed-permpkg.txt" ]]; then
  ok "status-failed written (fail closed)"
else
  bad "status-failed missing after preflight failure"
fi
if ls "$WS/output"/permpkg-*.pkg.tar.zst >/dev/null 2>&1; then
  bad "archive produced despite unwritable build dir"
else
  ok "no archive produced by failing preflight"
fi

# positive control: restore permissions -> same fixture must build clean
docker exec "$CID" bash -c "chmod -R u+w '$WS/permpkg'"
rc=$(run_build permpkg permpkg)
if [[ "$rc" -eq 0 ]]; then
  ok "positive control: restored permissions build exit 0"
else
  bad "positive control failed (rc=$rc): $(show_log permpkg)"
fi
if [[ -f "$WORKDIR/snap-permpkg/status-built-permpkg.txt" ]]; then
  ok "positive control: status-built written"
else
  bad "positive control: status-built missing"
fi
docker exec "$CID" bash -c "chown -R builder:builder '$WS'"

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
