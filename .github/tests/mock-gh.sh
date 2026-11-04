#!/usr/bin/env bash
#
# Mock `gh` CLI for publish regression tests. Intercepts the exact gh
# invocations used by publish-prod.sh / publish-stage.sh and serves them
# from a local fake-release directory:
#
#   gh release view  <tag> --repo <owner/repo>
#       -> lists assets from FAKE_RELEASE_DIR (no network)
#   gh release download <tag> --repo ... --dir <dir> --pattern <p>
#       -> copies matching file from FAKE_RELEASE_DIR to <dir>
#   gh release upload <tag> <files...> --repo ... --clobber
#       -> appends an event to FAKE_EVENTS_LOG
#   gh release create <tag> --repo ... --title ... --notes ...
#       -> touches FAKE_RELEASE_DIR/.created and logs event
#   gh release delete-asset <tag> <name> --repo ... -y
#       -> removes from FAKE_RELEASE_DIR and logs event
#
# Set FAKE_RELEASE_DIR (required) and FAKE_EVENTS_LOG (optional) before
# calling. The shim never touches the network.

set -uo pipefail

FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?FAKE_RELEASE_DIR is required}"
FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"

event() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$FAKE_EVENTS_LOG"
}

# gh release view <tag> --repo <repo> [--json assets -q ...]
if [[ "${1:-}" == "release" && "${2:-}" == "view" ]]; then
  shift 2
  tag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) shift; repo="$1" ;;
      --json) shift; json="$1" ;;
      -q) shift; query="$1" ;;
      -*) ;;
      *) tag="${tag:-$1}" ;;
    esac
    shift
  done
  if [[ ! -d "$FAKE_RELEASE_DIR" ]]; then
    echo "error: release not found" >&2
    exit 1
  fi
  if [[ "${json:-}" == "assets" ]]; then
    # real gh with `--json assets -q '.assets[].name'` prints one bare
    # asset name per line; mimic that when a query is present
    if [[ -n "${query:-}" && "${query}" == *".assets[].name"* ]]; then
      for f in "$FAKE_RELEASE_DIR"/*; do
        [[ -f "$f" ]] || continue
        printf '%s\n' "$(basename "$f")"
      done
      exit 0
    fi
    # emit a JSON array of asset names
    printf '{"assets":['
    first=1
    for f in "$FAKE_RELEASE_DIR"/*; do
      [[ -f "$f" ]] || continue
      if [[ $first -eq 0 ]]; then printf ','; fi
      printf '{"name":%s}' "$(basename "$f" | jq -R .)"
      first=0
    done
    printf ']}'
    echo
  else
    echo "$tag"
  fi
  exit 0
fi

# gh release download <tag> --repo <repo> --dir <dir> --pattern <p>
if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) shift; repo="$1" ;;
      --dir) shift; dir="$1" ;;
      --pattern) shift; pattern="$1" ;;
      -) ;;
      *) ;;
    esac
    shift
  done
  mkdir -p "$dir"
  found=0
  for f in "$FAKE_RELEASE_DIR"/$(basename "$pattern"); do
    if [[ -f "$f" ]]; then
      cp "$f" "$dir/$(basename "$f")"
      found=1
    fi
  done
  [[ $found -eq 1 ]] || { echo "warning: no asset matched pattern $pattern" >&2; exit 0; }
  exit 0
fi

# gh release upload <tag> <files...> --repo <repo> --clobber
if [[ "${1:-}" == "release" && "${2:-}" == "upload" ]]; then
  shift 2
  tag="${1:-}"
  shift
  files=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) shift; repo="$1" ;;
      --clobber) ;;
      -*) ;;
      *) files+=("$1") ;;
    esac
    shift
  done
  mkdir -p "$FAKE_RELEASE_DIR"
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || { echo "error: upload file missing: $f" >&2; exit 1; }
    cp "$f" "$FAKE_RELEASE_DIR/$(basename "$f")"
    event "upload $(basename "$f")"
  done
  exit 0
fi

# gh release create <tag> --repo <repo> --title ... --notes ...
if [[ "${1:-}" == "release" && "${2:-}" == "create" ]]; then
  shift 2
  tag="${1:-}"
  shift
  mkdir -p "$FAKE_RELEASE_DIR"
  touch "$FAKE_RELEASE_DIR/.created"
  event "create $tag"
  exit 0
fi

# gh release delete-asset <tag> <name> --repo <repo> -y
if [[ "${1:-}" == "release" && "${2:-}" == "delete-asset" ]]; then
  shift 2
  tag="${1:-}"
  shift
  asset="${1:-}"
  shift
  rm -f "$FAKE_RELEASE_DIR/$asset"
  event "delete-asset $asset"
  exit 0
fi

echo "error: unhandled mock gh invocation: $*" >&2
exit 2
