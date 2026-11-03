#!/usr/bin/env bash
#
# Run a staging publish inside a ghcr.io/archlinux/archlinux container with an
# explicitly managed lifecycle (same rationale as build-in-docker.sh:
# runner-managed job containers intermittently died with "cannot exec in a
# stopped container" before the first step).
#
# Environment:
#   RELEASE_TAG          - GitHub release tag holding the repository assets
#   REPO_DB_NAME         - pacman repository database name
#   GH_TOKEN             - GitHub token for gh CLI
#   GITHUB_REPOSITORY    - owner/repo (REQUIRED for gh calls)
#   GITHUB_WORKSPACE     - workspace root (mounted at the same path)
#   IMAGE                - container image (default ghcr.io/archlinux/archlinux:latest)

set -uo pipefail

GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
WS="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
IMAGE="${IMAGE:-ghcr.io/archlinux/archlinux:latest}"

CID=""
SUMMARY_FILE="$WS/.step-summary-publish.md"
rm -f "$SUMMARY_FILE"
cleanup() {
  if [[ -n "$CID" ]]; then
    docker rm -f "$CID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

CID=$(docker create \
  -e GITHUB_WORKSPACE="$WS" \
  -v "$WS":"$WS" \
  --workdir "$WS" \
  --entrypoint tail \
  "$IMAGE" -f /dev/null) || exit 128
docker start "$CID" >/dev/null || exit 128
if ! docker exec "$CID" sh -c 'test -x /usr/bin/pacman' >/dev/null 2>&1; then
  echo "::error::publish container init failed"
  docker logs "$CID" 2>&1 | tail -50 || true
  exit 128
fi
echo "publish container ready (id=$CID)"

set -o pipefail
docker exec \
  -e GH_TOKEN="$GH_TOKEN" \
  -e GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
  -e RELEASE_TAG="$RELEASE_TAG" \
  -e REPO_DB_NAME="$REPO_DB_NAME" \
  -e GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
  "$CID" bash "$WS/.github/scripts/publish-stage.sh"
rc=$?

[[ -s "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" > "$GITHUB_STEP_SUMMARY"
docker logs "$CID" 2>&1 | tail -50 || true
exit "$rc"
