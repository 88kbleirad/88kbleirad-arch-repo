#!/usr/bin/env bash
#
# Phase D: build candidate packages through the REAL pipeline path
# (.github/scripts/build-package.sh) inside the pinned generic Arch
# container with the production x86-64-v4 toolchain profile. Uses the
# mock gh shim with an empty release (no network/GitHub). Host-only,
# never touches GitHub.
#
# Usage:
#   bash .github/scripts/local-build-candidates.sh <package1> [package2...]
#
# Environment:
#   BUILD_IMAGE (default pinned digest)
#   KEEP=1 to keep the container after builds (debug)
#   EXTRA_REPO (optional, forwarded to build-package.sh, e.g.
#     EXTRA_REPO="88kbleirad|https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository")
#   EXTRA_REPO_FINGERPRINT (optional, expected signing-key fingerprint)
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PKGS=("$@")
[[ ${#PKGS[@]} -gt 0 ]] || PKGS=(anpan-git pwvucontrol pvpn-go obs-pipewire-audio-capture rate-mirrors beautyline)
IMAGE="${BUILD_IMAGE:-ghcr.io/archlinux/archlinux@sha256:644576e90a71df3b137df2ab6b3517ecd045418195c1946c2c11d1c0564a7981}"
WS="${LOCAL_BUILD_WS:-/tmp/cand-ws}"
OUT="${LOCAL_BUILD_OUT:-/tmp/local-candidate-builds}"
mkdir -p "$WS" "$OUT"

# --- scratch workspace -----------------------------------------------------
rm -rf "$WS"
mkdir -p "$WS/.github/scripts" "$WS/fake-release"
cp "$REPO_ROOT/.github/scripts/build-package.sh" "$WS/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/pkg-filename-lib.sh" "$WS/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/extra-repo-lib.sh" "$WS/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/audit-package-isa.sh" "$WS/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/critical-packages.sh" "$WS/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/rustc-v4-safe.sh" "$WS/.github/scripts/"
cp "$REPO_ROOT/.github/tests/mock-gh.sh" "$WS/.github/scripts/mock-gh.sh"
touch "$WS/fake-release/.created" "$WS/fake-release/.ids"
for pkg in "${PKGS[@]}"; do
  [[ -f "$REPO_ROOT/$pkg/PKGBUILD" ]] || { echo "MISSING $pkg PKGBUILD"; exit 2; }
  cp -r "$REPO_ROOT/$pkg" "$WS/"
  rm -rf "$WS/$pkg/src" "$WS/$pkg/pkg" "$WS/$pkg/"*.pkg.tar.zst 2>/dev/null || true
done

cat > "$WS/.github/scripts/gh-shim-wrapper" <<'GW'
#!/usr/bin/env bash
export FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?}"
export FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"
exec bash "$(dirname "$(readlink -f "$0")")/mock-gh.sh" "$@"
GW
chmod +x "$WS/.github/scripts/gh-shim-wrapper"

CID=""
cleanup() { [[ -n "$CID" && "${KEEP:-0}" != "1" ]] && docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

CID=$(docker create \
  -e EXTRA_REPO="${EXTRA_REPO:-}" \
  -e EXTRA_REPO_FINGERPRINT="${EXTRA_REPO_FINGERPRINT:-}" \
  -v "$WS":/ws -w /ws --entrypoint tail "$IMAGE" -f /dev/null)
docker start "$CID" >/dev/null

docker exec -i "$CID" bash -s <<'EOS'
set -euo pipefail
if grep -q '^\[options\]$' /etc/pacman.conf; then
  tmp=$(mktemp)
  awk '
    BEGIN { inserted=0 }
    /^\[options\]$/ && !inserted { print; print "DisableSandboxNetwork"; inserted=1; next }
    { print }
  ' /etc/pacman.conf > "$tmp"
  cat "$tmp" > /etc/pacman.conf
  rm -f "$tmp"
fi
# Optional extra pacman repo with strict signature enforcement (shared helper).
# The host workspace is bind-mounted at /ws, so the lib lives at /ws/....
source /ws/.github/scripts/extra-repo-lib.sh
# The pinned image ships a keyring without a pacman secret key; --init is
# idempotent and required before --lsign-key can certify trust.
pacman-key --init >/dev/null 2>&1
configure_extra_repo
pacman -Syu --noconfirm --needed \
  base-devel git subversion mercurial sudo rsync github-cli fakeroot \
  binutils pacman-contrib curl awk tar jq rustup
id builder >/dev/null 2>&1 || useradd -m builder
grep -q '^builder ALL=(ALL) NOPASSWD: ALL$' /etc/sudoers \
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
install -Dm755 /ws/.github/scripts/rustc-v4-safe.sh /usr/local/bin/rustc-v4-safe 2>/dev/null || true
printf 'export RUSTC_WRAPPER=/usr/local/bin/rustc-v4-safe\n' > /etc/profile.d/rustc-wrapper.sh
ln -sf /ws/.github/scripts/gh-shim-wrapper /usr/local/bin/gh
chown -R builder:builder /ws
EOS

for pkg in "${PKGS[@]}"; do
  echo "===== PIPELINE BUILD $pkg ====="
  docker exec "$CID" bash -c "rm -rf /ws/output; mkdir -p /ws/output; chown -R builder:builder /ws"
  set +e
  docker exec \
    -e GH_TOKEN=dummy \
    -e GITHUB_REPOSITORY=88kbleirad/88kbleirad-arch-repo \
    -e RELEASE_TAG=repository-v4-test \
    -e REPO_DB_NAME=88kbleirad \
    -e BUILD_PROFILE=x86-64-v4 \
    -e PKG="$pkg" \
    -e GITHUB_WORKSPACE=/ws \
    -e GITHUB_STEP_SUMMARY=/ws/summary-$pkg.md \
    -e FAKE_RELEASE_DIR=/ws/fake-release \
    -e FAKE_EVENTS_LOG=/ws/events-$pkg.log \
    -e EXTRA_REPO="${EXTRA_REPO:-}" \
    -e EXTRA_REPO_FINGERPRINT="${EXTRA_REPO_FINGERPRINT:-}" \
    "$CID" bash /ws/.github/scripts/build-package.sh > "$OUT/$pkg.log" 2>&1
  rc=$?
  set -e
  echo "build rc=$rc"
  docker cp "$CID:/ws/output" "$OUT/$pkg-output/" 2>/dev/null || true
done

echo "DONE artifacts in $OUT"
