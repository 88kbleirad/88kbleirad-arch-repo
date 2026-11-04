#!/usr/bin/env bash
#
# Run a staging publish inside a ghcr.io/archlinux/archlinux container with an
# explicitly managed lifecycle and phase diagnostics (same rationale and
# failure mode as build-in-docker.sh on 2026-11-03 hosted runners):
#
#   1. create the container with a long-running PID 1
#   2. start it and require 3 consecutive successful exec probes 1s apart
#      (catches containers that die ~150ms after start)
#   3. run the publish via `docker exec`
#   4. on failure, capture docker inspect state + logs before cleanup
#   5. always remove the container (trap) and propagate the exit code
#
# Environment:
#   RELEASE_TAG          - GitHub release tag holding the repository assets
#   REPO_DB_NAME         - pacman repository database name
#   GH_TOKEN             - GitHub token for gh CLI
#   GITHUB_REPOSITORY    - owner/repo (REQUIRED for gh calls)
#   GITHUB_WORKSPACE     - workspace root (mounted at the same path)
#   IMAGE                - container image (default ghcr.io/archlinux/archlinux:latest)
#   MAX_BOOT_ATTEMPTS    - boot retries (default 6)
#   PID1_MODE            - PID 1 command: "tail" (default) or "sleep"
#
# GPG signing material (optional but required for a signed publish):
#   GPG_KEY_FILE         - host path to the armored private signing key
#   GPG_PASSPHRASE_FILE  - host path to the key passphrase (may be absent)
# Both are bind-mounted read-only into the container. The secret values
# are never passed as environment values or argv, so they never appear in
# `docker inspect` or the host process list.

set -uo pipefail

GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
WS="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
IMAGE="${IMAGE:-ghcr.io/archlinux/archlinux@sha256:644576e90a71df3b137df2ab6b3517ecd045418195c1946c2c11d1c0564a7981}"
# publish script to run inside the container (default: staging publish)
PUBLISH_SCRIPT="${PUBLISH_SCRIPT:-publish-stage.sh}"
MAX_BOOT_ATTEMPTS="${MAX_BOOT_ATTEMPTS:-6}"
PID1_MODE="${PID1_MODE:-tail}"
GPG_KEY_FILE="${GPG_KEY_FILE:-}"
GPG_PASSPHRASE_FILE="${GPG_PASSPHRASE_FILE:-}"

CID=""
SUMMARY_FILE="$WS/.step-summary-publish.md"
rm -f "$SUMMARY_FILE"

die() { echo "::error::[publish] $*" >&2; exit 1; }
phase() { echo "[publish] [phase=$1] $2"; }

cleanup() { [[ -n "$CID" ]] && docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

collect_diagnostics() {
  local why="$1"
  echo "::warning::[publish] ${why}; capturing container diagnostics before removal"
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

pid1_cmd() {
  case "$PID1_MODE" in
    sleep) printf '%s\n' "sh" "-c" "trap '' INT TERM; while :; do sleep 60; done" ;;
    *)     printf '%s\n' "tail" "-f" "/dev/null" ;;
  esac
}

create_container() {
  local rc
  local -a PID1_ARGS=()
  local -a MOUNTS=(-v "$WS":"$WS")
  while IFS= read -r a; do PID1_ARGS+=("$a"); done < <(pid1_cmd)
  # GPG signing material: bind-mount the secret files read-only instead of
  # passing them as environment values or argv. Container secrets are not
  # exposed by `docker inspect`.
  if [[ -n "$GPG_KEY_FILE" ]]; then
    [[ -f "$GPG_KEY_FILE" ]] || die "GPG_KEY_FILE does not exist: $GPG_KEY_FILE"
    MOUNTS+=(-v "$GPG_KEY_FILE":/run/secrets/gpg-key:ro)
  fi
  if [[ -n "$GPG_PASSPHRASE_FILE" ]]; then
    [[ -f "$GPG_PASSPHRASE_FILE" ]] || die "GPG_PASSPHRASE_FILE does not exist: $GPG_PASSPHRASE_FILE"
    MOUNTS+=(-v "$GPG_PASSPHRASE_FILE":/run/secrets/gpg-passphrase:ro)
  fi
  docker create \
    -e GITHUB_WORKSPACE="$WS" \
    "${MOUNTS[@]}" \
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

phase info "image=$IMAGE pid1=$PID1_MODE attempts=$MAX_BOOT_ATTEMPTS"

boot_rc=1
for attempt in $(seq 1 "$MAX_BOOT_ATTEMPTS"); do
  [[ -n "$CID" ]] && { docker rm -f "$CID" >/dev/null 2>&1 || true; CID=""; }

  if create_container && start_stable; then
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

set -o pipefail
docker exec \
  -e GH_TOKEN \
  -e GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
  -e RELEASE_TAG="$RELEASE_TAG" \
  -e REPO_DB_NAME="$REPO_DB_NAME" \
  -e GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
  -e EXCLUDED_BASES_FILE="${EXCLUDED_BASES_FILE:-}" \
  -e SIGNING_MODE="${SIGNING_MODE:-unsigned}" \
  -e GPG_KEY_FILE="/run/secrets/gpg-key" \
  -e GPG_PASSPHRASE_FILE="${GPG_PASSPHRASE_FILE:+/run/secrets/gpg-passphrase}" \
  "$CID" bash "$WS/.github/scripts/$PUBLISH_SCRIPT"
rc=$?

if [[ $rc -ne 0 ]]; then
  collect_diagnostics "publish script exited rc=$rc"
  [[ -s "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" > "$GITHUB_STEP_SUMMARY"
  exit "$rc"
fi

[[ -s "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" > "$GITHUB_STEP_SUMMARY"
docker rm -f "$CID" >/dev/null 2>&1
CID=""
exit 0
