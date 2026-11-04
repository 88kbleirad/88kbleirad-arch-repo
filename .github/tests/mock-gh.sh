#!/usr/bin/env bash
#
# Shared mock `gh` CLI for publish/build regression tests. Serves both
# styles of invocation used by the pipeline from a LOCAL fake-release
# directory (no network, no secrets, no live GitHub):
#
#   Legacy subcommands (used by publish-stage.sh / build-package.sh):
#     gh release view <tag> --repo <repo> [--json assets -q '.assets[].name']
#     gh release download <tag> --repo <repo> --dir <dir> --pattern <p>
#     gh release upload <tag> <files...> --repo <repo> --clobber
#     gh release create <tag> --repo <repo> --title ... --notes ...
#     gh release delete-asset <tag> <name> --repo <repo> -y
#
#   Raw API (used by gh-release-lib.sh): `gh api --include ...`
#     - GET  /repos/{owner}/{repo}/releases/tags/{tag}
#            -> 404 when the release marker (.created) is absent; else a
#               release JSON document with id/tag_name/name/upload_url and
#               an assets[] array. The upload_url is a real RFC-6570
#               template so gh_release_upload_url() strips it correctly.
#     - POST /repos/{owner}/{repo}/releases
#            -> creates the release (marker) with 201
#     - DELETE /repos/{owner}/{repo}/releases/assets/{id}
#            -> 204 on success, 404 when the id is unknown
#     - POST <upload_url-base>?name=<n>   (asset upload)
#            -> copies the --input file into the fake release, 201
#
#   `--jq` filters are applied with real jq to the JSON body, exactly like
#   `gh api --jq`. `--include` semantics are reproduced: HTTP response
#   headers, blank line, then the body (or the jq-filtered result).
#
#   Fault injection (control via environment):
#     FAIL_500_ON=<asset>      : that operation returns HTTP 500 always
#     FAIL_429_ON=<asset>      : returns HTTP 429 + retry-after: 1
#     FAIL_ONCE_ON=<asset>     : fails once (500), then succeeds
#     PERMANENT_ON=<asset>     : returns HTTP 400 always (non-retryable)
#     FAIL_500_ONNE=<asset>    : once-only 500 (same as FAIL_ONCE_ON)
#
# Required env: FAKE_RELEASE_DIR. Optional: FAKE_EVENTS_LOG.
#
# The shim never touches the network. Asset ids are stable: a side file
# <release-dir>/.ids maps id|name; ids are assigned on first sight and
# persisted so DELETE-by-id works for fixtures seeded without .ids.

set -uo pipefail

FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?FAKE_RELEASE_DIR is required}"
FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"

event() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$FAKE_EVENTS_LOG"
}

rel_exists() { [[ -f "$FAKE_RELEASE_DIR/.created" ]]; }

# assign deterministic ids to every file that lacks one
sync_ids() {
  mkdir -p "$FAKE_RELEASE_DIR"
  [[ -f "$FAKE_RELEASE_DIR/.ids" ]] || : > "$FAKE_RELEASE_DIR/.ids"
  next=1
  if [[ -s "$FAKE_RELEASE_DIR/.ids" ]]; then
    next=$(awk -F'|' 'END{print $1+1}' "$FAKE_RELEASE_DIR/.ids")
    [[ "$next" -ge 1 ]] || next=1
  fi
  for f in "$FAKE_RELEASE_DIR"/*; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f")
    [[ "$name" == .* ]] && continue
    if ! awk -F'|' -v n="$name" '$2==n{found=1} END{exit !found}' "$FAKE_RELEASE_DIR/.ids"; then
      printf '%s|%s\n' "$next" "$name" >> "$FAKE_RELEASE_DIR/.ids"
      next=$(( next + 1 ))
    fi
  done
}

# id_for_name <name> -> id or empty
id_for_name() {
  local name="$1"
  awk -F'|' -v n="$name" '$2==n{print $1; exit}' "$FAKE_RELEASE_DIR/.ids" 2>/dev/null
}

# name_for_id <id> -> name or empty
name_for_id() {
  local id="$1"
  awk -F'|' -v i="$id" '$1==i{print $2; exit}' "$FAKE_RELEASE_DIR/.ids" 2>/dev/null
}

# list asset names (private dotfiles are never assets)
asset_names() {
  for f in "$FAKE_RELEASE_DIR"/*; do
    [[ -f "$f" ]] || continue
    local b
    b=$(basename "$f")
    [[ "$b" == .* ]] && continue
    printf '%s\n' "$b"
  done
}

# build the release JSON document
# MOCK_GH_NO_DIGEST=1 omits the digest field (simulates the pre-digest API
# or an unavailable remote checksum); MOCK_GH_BAD_DIGEST=1 emits a
# malformed digest (algorithm/size violation) for negative tests.
release_json() {
  local tag="${1:-repository}" first=1
  printf '{\n  "id": 1,\n  "tag_name": %s,\n  "name": "Arch Package Repository",\n' "$(printf '%s' "$tag" | jq -R .)"
  printf '  "upload_url": "https://uploads.github.com/repos/FAKE/releases/1/assets{?name,label}",\n'
  printf '  "assets": [\n'
  local name id size digest digest_field
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    id=$(id_for_name "$name")
    size=$(stat -c %s "$FAKE_RELEASE_DIR/$name" 2>/dev/null || echo 0)
    digest_field=""
    if [[ "${MOCK_GH_NO_DIGEST:-0}" != "1" ]]; then
      if [[ "${MOCK_GH_BAD_DIGEST:-0}" == "1" ]]; then
        digest="sha1:deadbeef"
      else
        digest="sha256:$(sha256sum "$FAKE_RELEASE_DIR/$name" 2>/dev/null | awk '{print $1}')"
      fi
      digest_field=$(printf ', "digest": %s' "$(printf '%s' "$digest" | jq -R .)")
    fi
    [[ $first -eq 0 ]] && printf ',\n'
    printf '    {"id": %s, "name": %s, "size": %s, "browser_download_url": "https://example.com/%s"%s}' \
      "$id" "$(printf '%s' "$name" | jq -R .)" "$size" "$(printf '%s' "$name" | jq -R -s . | tr -d '"')" "$digest_field"
    first=0
  done < <(asset_names)
  printf '\n  ]\n}\n'
}

# simulate `gh api --include` style output
api_response() { # status body
  local status="$1" body="$2"
  printf 'HTTP/2 %s\n' "$status"
  printf 'content-type: application/json\n'
  printf '\n'
  [[ -n "$body" ]] && printf '%s\n' "$body"
}

api_error() { # status message
  api_response "$1" "{\"message\":\"$2\"}"
}

# fault injection for an asset operation; returns 0 when the call should
# proceed, otherwise emits the faulted response and exits.
inject_fault() { # name
  local name="$1"
  if [[ "${FAIL_500_ON:-}" == "$name" ]]; then
    api_error 500 "Internal Server Error"; exit 0
  fi
  if [[ "${FAIL_429_ON:-}" == "$name" ]]; then
    printf 'HTTP/2 429\n'
    printf 'retry-after: 1\n'
    printf 'content-type: application/json\n\n'
    printf '{"message":"Too Many Requests"}\n'
    exit 0
  fi
  if [[ "${PERMANENT_ON:-}" == "$name" ]]; then
    api_error 400 "Bad Request"; exit 0
  fi
  if [[ "${FAIL_ONCE_ON:-}" == "$name" || "${FAIL_500_ONCE:-}" == "$name" ]]; then
    local marker="$FAKE_RELEASE_DIR/.fail_once_$name"
    if [[ ! -f "$marker" ]]; then
      touch "$marker"
      api_error 500 "Internal Server Error"; exit 0
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# gh release view <tag> --repo <repo> [--json assets -q ...]
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "release" && "${2:-}" == "view" ]]; then
  shift 2
  tag=""
  json=""
  query=""
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
  if ! rel_exists; then
    echo "error: release not found" >&2
    exit 1
  fi
  if [[ "${json:-}" == "assets" ]]; then
    if [[ -n "${query:-}" && "$query" == *".assets[].name"* ]]; then
      asset_names
      exit 0
    fi
    {
      printf '{"assets":['
      first=1
      local name
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        [[ $first -eq 0 ]] && printf ','
        printf '{"name":%s}' "$(printf '%s' "$name" | jq -R .)"
        first=0
      done < <(asset_names)
      printf ']}\n'
    }
  else
    echo "$tag"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# gh release download <tag> --repo <repo> --dir <dir> --pattern <p>
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then
  shift 2
  dir=""
  pattern=""
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
  # transient download fault injection: FAIL_DOWNLOAD_ON=<pattern> makes
  # every download of that pattern fail (transport-style); one-shot
  # variant fails exactly once. Both let tests verify the pipeline
  # distinguishes transient failures from a clean miss.
  if [[ "${FAIL_DOWNLOAD_ON:-}" == "$pattern" ]]; then
    echo "HTTP 502: bad gateway (simulated transient download failure)" >&2
    exit 1
  fi
  if [[ "${FAIL_DOWNLOAD_ONCE_ON:-}" == "$pattern" ]]; then
    if [[ ! -f "$FAKE_RELEASE_DIR/.fail_dl_once_$pattern" ]]; then
      touch "$FAKE_RELEASE_DIR/.fail_dl_once_$pattern"
      echo "HTTP 502: bad gateway (simulated transient download failure)" >&2
      exit 1
    fi
  fi
  for f in "$FAKE_RELEASE_DIR"/$(basename "$pattern"); do
    if [[ -f "$f" ]]; then
      cp "$f" "$dir/$(basename "$f")"
      found=1
    fi
  done
  # real `gh release download` exits 1 with this exact stderr on a clean
  # miss (no matching asset); the pipeline classifies it as a clean miss
  [[ $found -eq 1 ]] || { echo "no assets match the file pattern" >&2; exit 1; }
  exit 0
fi

# ---------------------------------------------------------------------------
# gh release upload <tag> <files...> --repo <repo> --clobber
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "release" && "${2:-}" == "upload" ]]; then
  shift 2
  shift  # tag
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

# ---------------------------------------------------------------------------
# gh release create <tag> --repo <repo> --title ... --notes ...
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "release" && "${2:-}" == "create" ]]; then
  shift 2
  tag="${1:-}"
  mkdir -p "$FAKE_RELEASE_DIR"
  touch "$FAKE_RELEASE_DIR/.created"
  event "create $tag"
  exit 0
fi

# ---------------------------------------------------------------------------
# gh release delete-asset <tag> <name> --repo <repo> -y
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "release" && "${2:-}" == "delete-asset" ]]; then
  shift 2
  shift  # tag
  asset="${1:-}"
  rm -f "$FAKE_RELEASE_DIR/$asset"
  event "delete-asset $asset"
  exit 0
fi

# ---------------------------------------------------------------------------
# gh api --include [--method M] [--jq EXPR] [--field k=v] [--input FILE]
#              [-H HDR] <path-or-url>
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "api" ]]; then
  shift
  method="GET"
  jq_query=""
  infile=""
  args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method|-X) method="$2"; shift 2; continue ;;
      --jq) jq_query="$2"; shift 2; continue ;;
      --input) infile="$2"; shift 2; continue ;;
      --field|-f|-F|-H) shift 2; continue ;;
      -H*) shift; continue ;;
      --include) shift; continue ;;
      *) args+=("$1"); shift ;;
    esac
  done

  url="${args[0]:-}"

  # --- GET release by tag -------------------------------------------------
  if [[ "$method" == "GET" && "$url" == */releases/tags/* ]]; then
    if ! rel_exists; then
      api_error 404 "Not Found"
    else
      sync_ids
      tag=""
      tag=$(basename "$url")
      response=$(release_json "$tag")
      if [[ -n "$jq_query" ]]; then
        api_response 200 "$(printf '%s\n' "$response" | jq -r "$jq_query")"
      else
        api_response 200 "$response"
      fi
    fi
    exit 0
  fi

  # --- POST release (create) ---------------------------------------------
  if [[ "$method" == "POST" && "$url" == */releases ]]; then
    mkdir -p "$FAKE_RELEASE_DIR"; touch "$FAKE_RELEASE_DIR/.created"
    event "create ${RELEASE_TAG:-repository}"
    api_response 201 '{"id":1,"tag_name":"repository"}'
    exit 0
  fi

  # --- asset upload: POST <upload_url-base>?name=<n> ----------------------
  if [[ "$method" == "POST" && "$url" == */releases/*/assets?* ]]; then
    name="${url#*?name=}"
    name="${name%%&*}"
    [[ -n "$name" ]] || { api_error 422 "missing name"; exit 0; }
    inject_fault "$name"
    # upload body comes from --input, --field, or stdin
    body=""
    if [[ -n "$infile" ]]; then
      body="$infile"
    elif [[ -f "${args[1]:-}" ]]; then
      body="${args[1]}"
    fi
    mkdir -p "$FAKE_RELEASE_DIR"
    if [[ -n "$body" && -f "$body" && "$body" != "$FAKE_RELEASE_DIR/$name" ]]; then
      cp "$body" "$FAKE_RELEASE_DIR/$name"
    else
      : > "$FAKE_RELEASE_DIR/$name"
    fi
    sync_ids
    id=""
    id=$(id_for_name "$name")
    event "upload $name"
    api_response 201 "{\"name\":\"$name\",\"id\":${id:-1}}"
    exit 0
  fi

  # --- DELETE asset by id --------------------------------------------------
  if [[ "$method" == "DELETE" && "$url" == */releases/assets/* ]]; then
    id=""
    name=""
    id=$(basename "$url")
    name=$(name_for_id "$id")
    if [[ -z "$name" ]]; then
      api_error 404 "Not Found"
      exit 0
    fi
    inject_fault "$name"
    rm -f "$FAKE_RELEASE_DIR/$name"
    event "delete-asset $name"
    api_response 204 ""
    exit 0
  fi

  api_error 404 "Not Found"
  exit 0
fi

echo "error: unhandled mock gh invocation: $*" >&2
exit 2
