#!/usr/bin/env bash
#
# Run a package build inside a cachyos/cachyos-v4 container with an
# explicitly managed lifecycle and full phase diagnostics.
#
# Observed failure mode (runs #1-#3 + production on 2026-11-03): the
# runner-hosted Docker daemon intermittently kills freshly started
# containers within ~150ms of `docker start` (container reports "Up" then
# immediately "exited"; subsequent execs fail with "cannot exec in a
# stopped container" / exit 128). The image itself is fine — the same
# digest builds successfully when the container survives.
#
# This script:
#   1. prints runner/docker context (no secrets) so a failure is
#      self-explanatory
#   2. splits the boot into explicit phases — create, start, probe, stable
#      hold, bootstrap — logging the exact exit code of each command
#   3. requires 3 consecutive successful exec probes 1s apart before
#      considering the container stable (a container that dies 150ms
#      after start is caught immediately)
#   4. on any phase failure, captures the container's corpse: inspect
#      state (status/exit code/OOMKilled/StartedAt/FinishedAt), logs,
#      `docker ps` — before removing it
#   5. retries the whole boot cycle up to MAX_BOOT_ATTEMPTS with backoff
#   6. runs the build via `docker exec`, then removes the container
#      (trap) and propagates the build exit code
#
# Environment:
#   PKG                  - repository directory / base package name (matrix entry)
#   RELEASE_TAG          - GitHub release tag holding the repository assets
#   REPO_DB_NAME         - pacman repository database name
#   GH_TOKEN             - GitHub token for gh CLI (passed to exec only)
#   GITHUB_REPOSITORY    - owner/repo (REQUIRED for gh calls)
#   GITHUB_WORKSPACE     - workspace root (mounted at the same path)
#   BUILD_PROFILE        - architecture profile, default "x86-64-v4"
#   IMAGE                - container image (default cachyos/cachyos-v4@sha256:068fe3…)
#   MAX_BOOT_ATTEMPTS    - boot retries (default 6)
#   PID1_MODE            - PID 1 command: "tail" (default) or "sleep"

set -uo pipefail

PKG="${PKG:?PKG is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
WS="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
IMAGE="${IMAGE:-cachyos/cachyos-v4@sha256:068fe3e3e3f088590cef1fe542ee26eb392413d6d9dbdbfb22a64c6b0e6aed23}"
MAX_BOOT_ATTEMPTS="${MAX_BOOT_ATTEMPTS:-6}"
PID1_MODE="${PID1_MODE:-tail}"

CID=""
SUMMARY_FILE="$WS/.step-summary-$PKG.md"
rm -f "$SUMMARY_FILE"

die() { echo "::error::[$PKG] $*" >&2; exit 1; }
phase() { echo "[$PKG] [phase=$1] $2"; }

cleanup() { [[ -n "$CID" ]] && docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# -- diagnostics ------------------------------------------------------------

docker_ctx() {
  phase diag "docker client: $(docker version --format '{{.Client.Version}}' 2>/dev/null || echo unavailable)"
  phase diag "docker server: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)"
  phase diag "docker server api: $(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo unavailable)"
  phase diag "storage driver: $(docker info --format '{{.Driver}}' 2>/dev/null || echo unavailable)"
  phase diag "runtime: $(docker info --format '{{.Runtimes}}' 2>/dev/null || echo unavailable)"
}

# Capture corpse diagnostics before removal. Never prints env/token values.
collect_diagnostics() {
  local why="$1"
  echo "::warning::[$PKG] ${why}; capturing container diagnostics before removal"
  if [[ -n "$CID" ]]; then
    {
      echo "--- docker inspect state ---"
      docker inspect -f \
        'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} error={{.State.Error}}' \
        "$CID" 2>&1 || true
      echo "--- docker ps ---"
      docker ps -a --filter "id=$CID" --no-trunc --format '{{.ID}} {{.State}} {{.Status}}' 2>&1 || true
      echo "--- docker logs (last 40) ---"
      docker logs "$CID" 2>&1 | tail -40 || true
    } | sed 's/^/  /'
  fi
}

# -- lifecycle --------------------------------------------------------------

pid1_cmd() {
  case "$PID1_MODE" in
    sleep) printf '%s\n' "sh" "-c" "trap '' INT TERM; while :; do sleep 60; done" ;;
    *)     printf '%s\n' "tail" "-f" "/dev/null" ;;
  esac
}

# Create the container. Returns 0 and sets CID on success.
create_container() {
  local rc
  local -a PID1_ARGS=()
  while IFS= read -r a; do PID1_ARGS+=("$a"); done < <(pid1_cmd)
  docker create \
    -e GITHUB_WORKSPACE="$WS" \
    -v "$WS":"$WS" \
    --workdir "$WS" \
    --entrypoint "${PID1_ARGS[0]}" \
    "$IMAGE" "${PID1_ARGS[@]:1}" \
    > /tmp/container-id.$$ 2>/tmp/container-create.err.$$
  rc=$?
  if [[ $rc -ne 0 ]]; then
    phase create "docker create failed rc=$rc"; cat /tmp/container-create.err.$$ >&2
    return 1
  fi
  CID=$(cat /tmp/container-id.$$)
  rm -f /tmp/container-id.$$ /tmp/container-create.err.$$
  phase create "docker create ok id=${CID:0:12}"
}

# Start + require the container to stay alive through 3 probes, 1s apart.
start_stable() {
  local rc i
  phase start "docker start ${CID:0:12}"
  docker start "$CID" >/dev/null 2>/tmp/container-start.err.$$
  rc=$?
  if [[ $rc -ne 0 ]]; then
    phase start "docker start failed rc=$rc"; cat /tmp/container-start.err.$$ >&2
    return 1
  fi
  rm -f /tmp/container-start.err.$$
  for i in 1 2 3; do
    docker exec "$CID" sh -c 'test -x /usr/bin/pacman' >/dev/null 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
      phase probe "probe $i/3 failed rc=$rc (container died shortly after start?)"
      return 1
    fi
    phase probe "probe $i/3 ok"
    if [[ $i -lt 3 ]]; then
      sleep 1
    fi
  done
  return 0
}

bootstrap_container() {
  # Install build tooling, create the builder user, and apply the CachyOS
  # v4 compiler profiles (same content as the former workflow steps).
  local rc
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
  rc=$?

  if [[ $rc -ne 0 ]]; then
    phase bootstrap "docker exec bootstrap failed rc=$rc"
    return 1
  fi

  # Workspace is mounted from the host (checked out by the runner user);
  # give builder full ownership so makepkg can create src/pkg dirs and
  # update checksums (same step as the former workflow).
  docker exec "$CID" chown -R builder:builder "$WS" || {
    phase bootstrap "chown failed rc=$?"
    return 1
  }
}

# -- main -------------------------------------------------------------------

docker_ctx
phase info "image=$IMAGE pid1=$PID1_MODE attempts=$MAX_BOOT_ATTEMPTS"

boot_rc=1
for attempt in $(seq 1 "$MAX_BOOT_ATTEMPTS"); do
  [[ -n "$CID" ]] && { docker rm -f "$CID" >/dev/null 2>&1 || true; CID=""; }

  if create_container && start_stable && bootstrap_container; then
    phase info "container ready on attempt $attempt/$MAX_BOOT_ATTEMPTS (id=${CID:0:12})"
    boot_rc=0
    break
  fi

  collect_diagnostics "attempt $attempt/$MAX_BOOT_ATTEMPTS failed"
  if [[ "$attempt" -lt "$MAX_BOOT_ATTEMPTS" ]]; then
    backoff=$(( attempt * 3 ))
    phase info "retrying in ${backoff}s"
    sleep "$backoff"
  fi
done

if [[ $boot_rc -ne 0 ]]; then
  die "container could not be brought to a healthy state after $MAX_BOOT_ATTEMPTS attempts"
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
  collect_diagnostics "build script exited rc=$build_rc"
  [[ -s "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" > "$GITHUB_STEP_SUMMARY"
  exit "$build_rc"
fi

[[ -s "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" > "$GITHUB_STEP_SUMMARY"
phase info "container final state: $(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}})' "$CID")"

docker rm -f "$CID" >/dev/null 2>&1
CID=""
exit 0
