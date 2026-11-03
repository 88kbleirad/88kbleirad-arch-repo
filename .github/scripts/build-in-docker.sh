#!/usr/bin/env bash
#
# Run a package build inside a cachyos/cachyos-v4 container with an
# explicitly managed lifecycle.
#
# The runner-managed job-container model (`container:` key) proved
# unreliable for this image: the runner's injected PID 1
# (`tail -f /dev/null`) intermittently died between container start and the
# first `docker exec`, producing "cannot exec in a stopped container" /
# "FailedPrecondition: container init process is not running" (exit 128)
# on a random sibling job before any build step could run.
#
# This script replaces that model with an explicit lifecycle:
#   1. create the container with a long-running PID 1 (tail -f /dev/null)
#   2. start it
#   3. probe it with a real `docker exec` and bootstrap the build
#      environment (base deps, builder user, v4 compiler profiles); the
#      whole create/start/probe/bootstrap cycle retries up to 3 times on
#      failure instead of killing the job
#   4. run the build via `docker exec`
#   5. on build failure, capture `docker logs` before cleanup
#   6. always remove the container (trap) and propagate the build exit code
#
# Environment:
#   PKG                  - repository directory / base package name (matrix entry)
#   RELEASE_TAG          - GitHub release tag holding the repository assets
#   REPO_DB_NAME         - pacman repository database name
#   GH_TOKEN             - GitHub token for gh CLI
#   GITHUB_REPOSITORY    - owner/repo (REQUIRED for gh calls)
#   GITHUB_WORKSPACE     - workspace root (mounted at the same path)
#   BUILD_PROFILE        - architecture profile, default "x86-64-v4"
#   IMAGE                - container image (default cachyos/cachyos-v4:latest)

set -uo pipefail

PKG="${PKG:?PKG is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
WS="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
IMAGE="${IMAGE:-cachyos/cachyos-v4:latest}"
MAX_BOOT_ATTEMPTS="${MAX_BOOT_ATTEMPTS:-3}"

CID=""
SUMMARY_FILE="$WS/.step-summary-$PKG.md"
rm -f "$SUMMARY_FILE"
cleanup() {
  if [[ -n "$CID" ]]; then
    docker rm -f "$CID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

bootstrap_container() {
  # Install build tooling, create the builder user, and apply the CachyOS
  # v4 compiler profiles (same content as the former workflow steps).
  docker exec -i "$CID" bash -s <<'EOS'
set -euo pipefail

# pacman sandbox network isolation (unshare) is not permitted inside this
# container environment; disable it (same setting as the production workflow).
tmp=$(mktemp)
awk '
  BEGIN { inserted=0 }
  /^\[options\]$/ && !inserted { print; print "DisableSandboxNetwork"; inserted=1; next }
  { print }
  END { if (!inserted) exit 1 }
' /etc/pacman.conf > "$tmp"
cat "$tmp" > /etc/pacman.conf
rm -f "$tmp"

pacman -Syu --noconfirm --needed \
  git subversion mercurial sudo rsync github-cli fakeroot binutils \
  pacman-contrib paru curl awk tar jq rustup

id builder >/dev/null 2>&1 || useradd -m builder
grep -q '^builder ALL=(ALL) NOPASSWD: ALL$' /etc/sudoers \
  || echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

rustup default stable
sudo -u builder rustup default stable

curl -fSL --retry 3 -o /etc/makepkg.conf \
  https://raw.githubusercontent.com/CachyOS/docker-makepkg/refs/heads/master/docker-makepkg-v4/makepkg.conf
mkdir -p /etc/makepkg.conf.d
curl -fSL --retry 3 -o /etc/makepkg.conf.d/rust.conf \
  https://raw.githubusercontent.com/CachyOS/docker-makepkg/refs/heads/master/docker-makepkg-v4/rust.conf

if ! grep -q -- '-march=x86-64-v4' /etc/makepkg.conf; then
  echo "::error::CachyOS v4 makepkg.conf does not contain -march=x86-64-v4"
  exit 1
fi
if ! grep -q -- 'target-cpu=x86-64-v4' /etc/makepkg.conf.d/rust.conf; then
  echo "::error::CachyOS v4 rust.conf does not contain target-cpu=x86-64-v4"
  exit 1
fi
echo "Confirmed x86-64-v4 compiler flags."

sed -i 's/^PKGDEST=/#PKGDEST=/g' /etc/makepkg.conf
sed -i 's/^LOGDEST=/#LOGDEST=/g' /etc/makepkg.conf
sed -i 's/^PACKAGECARCH=/#PACKAGECARCH=/g' /etc/makepkg.conf
EOS

  # Workspace is mounted from the host (checked out by the runner user);
  # give builder full ownership so makepkg can create src/pkg dirs and
  # update checksums (same step as the former workflow).
  docker exec "$CID" chown -R builder:builder "$WS"
}

start_container() {
  CID=$(docker create \
    -e GITHUB_WORKSPACE="$WS" \
    -v "$WS":"$WS" \
    --workdir "$WS" \
    --entrypoint tail \
    "$IMAGE" -f /dev/null) || return 1
  docker start "$CID" >/dev/null || return 1
  # Probe proves both "container is running" AND "exec works".
  docker exec "$CID" sh -c 'test -x /usr/bin/pacman' >/dev/null 2>&1
}

boot_rc=1
for attempt in $(seq 1 "$MAX_BOOT_ATTEMPTS"); do
  [[ -n "$CID" ]] && { docker rm -f "$CID" >/dev/null 2>&1 || true; CID=""; }
  if start_container && bootstrap_container; then
    echo "[$PKG] container ready on attempt $attempt/$MAX_BOOT_ATTEMPTS (id=$CID)"
    boot_rc=0
    break
  fi
  echo "::warning::[$PKG] container init/bootstrap failed on attempt $attempt/$MAX_BOOT_ATTEMPTS; removing and retrying"
  if [[ "$attempt" -lt "$MAX_BOOT_ATTEMPTS" ]]; then
    sleep 5
  fi
done

if [[ $boot_rc -ne 0 ]]; then
  echo "::error::[$PKG] container could not be brought to a healthy state after $MAX_BOOT_ATTEMPTS attempts"
  exit 128
fi

# Run the build. Explicit env propagation into the exec'ed process.
set -o pipefail
docker exec \
  -e GH_TOKEN="$GH_TOKEN" \
  -e GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
  -e RELEASE_TAG="$RELEASE_TAG" \
  -e REPO_DB_NAME="$REPO_DB_NAME" \
  -e BUILD_PROFILE="$BUILD_PROFILE" \
  -e PKG="$PKG" \
  -e GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
  "$CID" bash "$WS/.github/scripts/build-package.sh"
build_rc=$?

if [[ $build_rc -ne 0 ]]; then
  echo "::error::[$PKG] build script exited with code $build_rc; capturing container logs before cleanup"
  docker logs "$CID" 2>&1 | tail -100 || true
  [[ -s "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" > "$GITHUB_STEP_SUMMARY"
  exit "$build_rc"
fi

[[ -s "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" > "$GITHUB_STEP_SUMMARY"
echo "[$PKG] container final state: $(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}})' "$CID")"
exit 0
