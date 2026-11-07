#!/usr/bin/env bash
#
# Robust GitHub Release asset helpers with bounded retries.
#
# Sourced by publish-prod.sh (and available to tests). All GitHub API
# traffic goes through gh_api_retry, which:
#   - retries ONLY retryable failures: HTTP 5xx, HTTP 429, and transport
#     errors (curl-level failures surfaced by `gh`).
#   - never retries non-retryable 4xx (e.g. 404/422), except 429.
#   - honours the `Retry-After` header when present (seconds).
#   - uses exponential backoff with jitter between attempts.
#   - logs, sanitized, the operation, the filename, the HTTP status and
#     the attempt number — never any token or secret.
#   - after an AMBIGUOUS failure of a mutation (a write whose outcome is
#     unknown), reconciles the remote asset state before deciding.
#
# Mutations are implemented with `gh api` (not `gh release upload
# --clobber`) so we can observe the exact HTTP status and always replace
# an asset by DELETE-then-POST rather than PATCH. That removes the
# PATCH /releases/assets/<id> request that returned HTTP 500, and it makes
# the outcome of every mutation observable/reconcilable.
#
# Environment:
#   RELEASE_TAG, GITHUB_REPOSITORY (owner/repo), GH_TOKEN
#   GH_API_MAX_ATTEMPTS (default 5)
#   GH_API_BASE_DELAY   (default 2 seconds)

set -uo pipefail

GH_API_MAX_ATTEMPTS="${GH_API_MAX_ATTEMPTS:-5}"
GH_API_BASE_DELAY="${GH_API_BASE_DELAY:-2}"

# counters for content-aware publishing; the publisher may reset them
if [[ -z "${PUBLISH_COUNTERS+x}" ]]; then
  declare -A PUBLISH_COUNTERS=( [unchanged]=0 [uploaded]=0 [replaced]=0 [failed]=0 [api_requests]=0 )
fi

# Diagnostic logging goes to stderr: stdout is reserved for function
# *return values* (checksums, ids, bodies) captured via command
# substitution. Mixing them silently corrupts every returned value.
gh_log() { printf '[gh] %s\n' "$*" >&2; }
gh_err() { printf '::error::[gh] %s\n' "$*" >&2; }

# sleep_for_attempt <attempt> [retry_after]
sleep_for_attempt() {
  local attempt="$1" retry_after="${2:-}" delay
  if [[ -n "$retry_after" && "$retry_after" =~ ^[0-9]+$ ]]; then
    delay="$retry_after"
    gh_log "honouring Retry-After=${retry_after}s"
  else
    delay=$(( GH_API_BASE_DELAY * (1 << (attempt - 1)) ))
    # jitter: up to 25% of the delay
    local jitter=$(( RANDOM % (delay / 4 + 1) ))
    delay=$(( delay + jitter ))
  fi
  (( delay > 60 )) && delay=60
  gh_log "backing off ${delay}s before retry ${attempt}"
  sleep "$delay"
}

# parse_status <headers+body> -> prints the HTTP status code or empty
parse_status() {
  printf '%s\n' "$1" | awk 'NR==1 && /^HTTP\//{print $2; exit}'
}

# parse_retry_after <headers+body> -> seconds or empty
parse_retry_after() {
  printf '%s\n' "$1" | awk 'BEGIN{IGNORECASE=1} /^retry-after:/{gsub(/\r/,""); print $2; exit}'
}

# is_retryable_status <code> <rc>
is_retryable_status() {
  local code="$1" rc="$2"
  # transport/curl error with no HTTP status -> retryable
  [[ -z "$code" && "$rc" -ne 0 ]] && return 0
  # 5xx and 429 -> retryable
  [[ "$code" =~ ^5[0-9][0-9]$ ]] && return 0
  [[ "$code" == "429" ]] && return 0
  return 1
}

# gh_api_call <gh api args...>
# Runs `gh api --include <args>`. Prints the RAW response (headers+body)
# to stdout via GH_LAST_RAW and returns gh's exit code via GH_LAST_RC.
GH_LAST_RAW=""
GH_LAST_RC=0
gh_api_call() {
  local out rc
  PUBLISH_COUNTERS[api_requests]=$(( PUBLISH_COUNTERS[api_requests] + 1 ))
  out="$(gh api --include "$@" 2>&1)"
  rc=$?
  GH_LAST_RAW="$out"
  GH_LAST_RC="$rc"
  return "$rc"
}

# gh_api_retry <desc> <gh api args...>
# Prints the response BODY (headers stripped) on success. Returns 0 on
# success, non-zero after exhausting retries.
gh_api_retry() {
  local desc="$1"; shift
  local attempt=1 code retry_after
  while :; do
    gh_api_call "$@" || true
    code="$(parse_status "$GH_LAST_RAW")"

    if [[ "$GH_LAST_RC" -eq 0 ]] && { [[ -z "$code" ]] || [[ "$code" -lt 400 ]]; }; then
      # success: strip leading header block
      printf '%s\n' "$GH_LAST_RAW" | awk 'seen{print} /^\r?$/{seen=1}'
      return 0
    fi

    gh_log "op='${desc}' attempt=${attempt}/${GH_API_MAX_ATTEMPTS} http_status=${code:-<transport-error>} rc=${GH_LAST_RC}"

    if ! is_retryable_status "$code" "$GH_LAST_RC" || (( attempt >= GH_API_MAX_ATTEMPTS )); then
      gh_err "op='${desc}' failed permanently (http_status=${code:-<transport-error>} rc=${GH_LAST_RC})"
      printf '%s\n' "$GH_LAST_RAW" >&2
      return 1
    fi

    retry_after="$(parse_retry_after "$GH_LAST_RAW")"
    sleep_for_attempt "$attempt" "$retry_after"
    attempt=$(( attempt + 1 ))
  done
}

# gh_release_upload_url -> prints the upload_url template-less base or empty
gh_release_upload_url() {
  local tag="$1" repo="$2" url
  url="$(gh_api_retry "get upload_url (${tag})" \
      "/repos/${repo}/releases/tags/${tag}" \
      --jq '.upload_url' 2>/dev/null | tr -d '"')" || return 1
  # strip the RFC-6570 template, e.g. ".../releases/1/assets{?name,label}"
  printf '%s\n' "${url%%\{*}"
}

# gh_asset_id <tag> <repo> <name> -> id or empty
gh_asset_id() {
  local tag="$1" repo="$2" name="$3" id
  id="$(gh_api_retry "find asset (${name})" \
      "/repos/${repo}/releases/tags/${tag}" \
      --jq ".assets[] | select(.name == \"${name}\") | .id" 2>/dev/null | head -n1 | tr -d '"')" || true
  printf '%s\n' "$id"
}

# gh_list_assets <tag> <repo> -> one asset name per line (empty when none)
gh_list_assets() {
  local tag="$1" repo="$2"
  gh_api_retry "list assets (${tag})" \
    "/repos/${repo}/releases/tags/${tag}" \
    --jq '.assets[].name' 2>/dev/null | tr -d '"'
}

# gh_delete_asset <tag> <repo> <name>
# Reconciliation-safe: if the asset is already gone (404), that is success.
gh_delete_asset() {
  local tag="$1" repo="$2" name="$3" id
  # Dry-run: block the write BEFORE any API call (no remote state query).
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    gh_log "DRY-RUN: would delete '${name}' (no mutation)"
    return 0
  fi
  id="$(gh_asset_id "$tag" "$repo" "$name")"
  if [[ -z "$id" ]]; then
    gh_log "delete '${name}': already absent (nothing to do)"
    return 0
  fi
  # Destructive guard (opt-in via GH_REQUIRE_RECOVERY_SNAPSHOT=1):
  # replacing (delete + re-upload) an EXISTING asset is only allowed once a
  # verified pre-mutation recovery snapshot exists. GitHub Releases have no
  # atomic same-name replace, so a failed upload after this delete would
  # leave the previous asset missing; the snapshot is the only way back.
  # Publish entrypoints set this after capturing+validating the snapshot.
  # Legacy call paths (tests, tools) that do not set it keep the previous
  # behavior.
  if [[ "${GH_REQUIRE_RECOVERY_SNAPSHOT:-0}" == "1" && "${RECOVERY_SNAPSHOT_OK:-0}" != "1" ]]; then
    gh_err "delete '${name}': refusing to remove an existing release asset without a verified pre-mutation recovery snapshot (GH_REQUIRE_RECOVERY_SNAPSHOT=1 but RECOVERY_SNAPSHOT_OK != 1). Capture the release snapshot first."
    return 1
  fi
  gh_log "delete '${name}' (id=${id})"
  gh_api_retry "delete asset (${name})" \
    --method DELETE "/repos/${repo}/releases/assets/${id}" >/dev/null 2>&1
}

# gh_upload_asset <tag> <repo> <file>
# Replaces any existing asset of the same name via DELETE + upload POST
# (never PATCH). After an ambiguous upload failure, reconciles by
# checking whether the asset exists before retrying.
gh_upload_asset() {
  local tag="$1" repo="$2" file="$3"
  local name upload_url attempt=1 code

  name="$(basename "$file")"
  [[ -s "$file" ]] || { gh_err "upload '${name}': local file missing/empty"; return 1; }

  # Dry-run: block the write BEFORE any API call. Remote state is never
  # touched; the plan is reported by the caller (gh_publish_asset).
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    gh_log "DRY-RUN: would upload '${name}' (no mutation)"
    return 0
  fi

  # always drop any pre-existing asset first (clobber semantics without PATCH)
  gh_delete_asset "$tag" "$repo" "$name" || return 1

  upload_url="$(gh_release_upload_url "$tag" "$repo")" || return 1
  [[ -n "$upload_url" ]] || { gh_err "upload '${name}': could not resolve release upload_url"; return 1; }

  while :; do
    gh_api_call --method POST \
      -H "Content-Type: application/octet-stream" \
      --input "$file" \
      "${upload_url}?name=${name}" || true
    code="$(parse_status "$GH_LAST_RAW")"

    if [[ "$GH_LAST_RC" -eq 0 ]] && { [[ -z "$code" ]] || [[ "$code" -lt 400 ]]; }; then
      gh_log "uploaded '${name}' (http_status=${code:-ok})"
      return 0
    fi

    gh_log "op='upload (${name})' attempt=${attempt}/${GH_API_MAX_ATTEMPTS} http_status=${code:-<transport-error>} rc=${GH_LAST_RC}"

    # Ambiguous outcome: an upload may have actually landed before the
    # error. Reconcile the remote state before deciding what to do.
    # Filename presence is NOT sufficient proof of correct content: the
    # remote asset must carry a trustworthy SHA-256 digest that matches
    # the local file before we treat the upload as successful.
    if [[ -n "$(gh_asset_id "$tag" "$repo" "$name")" ]]; then
      if { [[ "$code" =~ ^5 ]] || [[ -z "$code" ]]; }; then
        local remote_digest local_digest
        remote_digest="$(gh_asset_digest "$tag" "$repo" "$name")" || remote_digest=""
        local_digest="$(sha256_hex "$file")"
        if [[ -n "$remote_digest" && -n "$local_digest" && "$remote_digest" == "$local_digest" ]]; then
          gh_log "reconcile '${name}': remote asset digest matches local content; treating as uploaded after all"
          return 0
        fi
        # No trustworthy digest (or mismatch): do NOT treat as success.
        # Fall through to retry / permanent-failure handling below.
        gh_log "reconcile '${name}': remote asset present but digest unavailable/mismatch (remote=${remote_digest:-<none>} local=${local_digest:-<none>}); refusing to claim success"
      fi
    fi

    if ! is_retryable_status "$code" "$GH_LAST_RC" || (( attempt >= GH_API_MAX_ATTEMPTS )); then
      gh_err "upload '${name}' failed permanently (http_status=${code:-<transport-error>} rc=${GH_LAST_RC})"
      return 1
    fi
    sleep_for_attempt "$attempt" "$(parse_retry_after "$GH_LAST_RAW")"
    attempt=$(( attempt + 1 ))
  done
}

# ---------------------------------------------------------------------------
# Content-aware asset publishing (Objective A)
# ---------------------------------------------------------------------------
# Asset status classification:
#   UNCHANGED -> remote content identical to local (trustworthy checksum)
#   NEW       -> remote asset does not exist yet
#   CHANGED   -> remote asset exists with different content
#   MISSING   -> remote asset absent (query succeeded, nothing to compare)
#   UNKNOWN   -> remote checksum could not be obtained/verified
#   FAILED    -> remote state could not be queried at all

# sha256_hex <file> -> lowercase hex sha256 (or empty on error)
sha256_hex() {
  local f="$1"
  [[ -f "$f" ]] || { echo ""; return 1; }
  sha256sum "$f" 2>/dev/null | awk '{print $1}'
}

# valid_sha256_hex <string> -> 0 when it is a 64-char lowercase hex sha256
valid_sha256_hex() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

# gh_asset_digest <tag> <repo> <name> -> prints hex sha256 or empty
# Uses the GitHub `digest` field when present and plausibly valid; a
# malformed digest is treated as absent (the caller must fall back).
gh_asset_digest() {
  local tag="$1" repo="$2" name="$3" d
  d="$(gh_api_retry "asset digest (${name})" \
      "/repos/${repo}/releases/tags/${tag}" \
      --jq ".assets[] | select(.name == \"${name}\") | .digest // empty" \
      2>/dev/null | tr -d '"')" || true
  d="${d#sha256:}"
  if valid_sha256_hex "$d"; then
    printf '%s\n' "$d"
    return 0
  fi
  return 1
}

# gh_asset_sha256 <tag> <repo> <name> <dir>
# Returns a trustworthy remote checksum:
#   1. the API `digest` field when present and valid;
#   2. otherwise a safe download-and-hash fallback (sha256 over the
#      downloaded asset bytes).
# Prints the hex on success (0); prints nothing and returns 1 when the
# checksum cannot be obtained (unknown).
gh_asset_sha256() {
  local tag="$1" repo="$2" name="$3" dir="$4" hex

  hex="$(gh_asset_digest "$tag" "$repo" "$name")" || true
  if [[ -n "$hex" ]]; then
    printf '%s\n' "$hex"
    return 0
  fi

  gh_log "no API digest for '${name}'; falling back to download-and-hash"
  if gh_download_asset_retry "$tag" "$repo" "$name" "$dir"; then
    hex="$(sha256_hex "$dir/$name")"
    if [[ -n "$hex" ]]; then
      printf '%s\n' "$hex"
      return 0
    fi
  fi
  return 1
}

# gh_download_asset_retry <tag> <repo> <name> <dir>
# Download one asset by name with bounded retries. Returns 0 when the
# file exists and is non-empty.
gh_download_asset_retry() {
  local tag="$1" repo="$2" name="$3" dir="$4" attempt rc
  mkdir -p "$dir"
  for attempt in 1 2 3; do
    gh release download "$tag" --repo "$repo" --dir "$dir" --pattern "$name" \
      2>"$dir/.dl-err" && rc=0 || rc=$?
    if [[ $rc -eq 0 && -s "$dir/$name" ]]; then
      return 0
    fi
    gh_log "download '${name}' attempt ${attempt}/3 failed (rc=${rc})"
    sleep 2
  done
  return 1
}

# gh_asset_status <tag> <repo> <file> <workdir>
# Classify the local file against the remote asset. Sets ASSET_STATUS and
# ASSET_REMOTE_HEX (remote sha256 when obtainable).
#
# Return codes:
#   0 -> UNCHANGED (skip upload)
#   1 -> NEW / CHANGED / MISSING (upload required)
#   2 -> UNKNOWN / FAILED (do NOT mutate; caller decides)
gh_asset_status() {
  local tag="$1" repo="$2" file="$3" workdir="$4"
  local name hex remote_hex status
  name="$(basename "$file")"
  ASSET_STATUS="FAILED"
  ASSET_REMOTE_HEX=""

  hex="$(sha256_hex "$file")"
  if [[ -z "$hex" ]]; then
    gh_err "asset status '${name}': cannot hash local file"
    return 2
  fi

  if ! gh_api_retry "asset status (${name})" \
      "/repos/${repo}/releases/tags/${tag}" \
      --jq ".assets[] | select(.name == \"${name}\") | {id,digest}" \
      >/dev/null 2>&1; then
    # A failed release-by-tag query can mean the release itself does not
    # exist (404). Then no remote asset can exist, so every local file is
    # NEW. Only in that case classify MISSING without guessing; any other
    # failure (release exists but list/transport failed) stays FAILED —
    # never mutate on an unverifiable state. Distinguish by asking for the
    # release again: a second failure is a missing release (or a double
    # transient failure, which the subsequent publish loop re-checks via
    # gh_asset_status before any mutation anyway).
    if gh_api_retry "view release (${tag})" \
        "/repos/${repo}/releases/tags/${tag}" >/dev/null 2>&1; then
      gh_err "asset status '${name}': failed to query release assets"
      ASSET_STATUS="FAILED"
      return 2
    fi
    gh_log "asset status '${name}': release ${tag} not found; classifying as NEW/MISSING"
    ASSET_STATUS="MISSING"
    return 1
  fi

  local found
  found="$(gh_api_retry "asset status (${name})" \
      "/repos/${repo}/releases/tags/${tag}" \
      --jq ".assets[] | select(.name == \"${name}\") | .id" \
      2>/dev/null | head -n1 | tr -d '"')" || true

  if [[ -z "$found" ]]; then
    ASSET_STATUS="MISSING"
    return 1
  fi

  remote_hex="$(gh_asset_sha256 "$tag" "$repo" "$name" "$workdir/.remote-assets")" || true
  if [[ -z "$remote_hex" ]]; then
    gh_err "asset status '${name}': remote checksum unavailable (no digest, download failed)"
    ASSET_STATUS="UNKNOWN"
    return 2
  fi
  ASSET_REMOTE_HEX="$remote_hex"

  if [[ "$remote_hex" == "$hex" ]]; then
    ASSET_STATUS="UNCHANGED"
    return 0
  fi
  ASSET_STATUS="CHANGED"
  return 1
}

# pkg_identity <archive> -> canonical package identity "name|version|arch"
# (or empty). Extracts .PKGINFO; handles pacman-7 embedded EVR and legacy
# separate epoch/pkgrel lines. Used by the same-version replacement policy
# to compare local vs remote package identity independently of bytes.
pkg_identity() {
  local archive="$1" tmp pkginfo name evr arch epoch pkgver pkgrel
  tmp="$(mktemp)"
  if tar --zstd -xOf "$archive" .PKGINFO > "$tmp" 2>/dev/null \
      && [[ -s "$tmp" ]]; then
    :
  elif command -v bsdtar >/dev/null 2>&1 \
      && bsdtar -xOf "$archive" .PKGINFO > "$tmp" 2>/dev/null \
      && [[ -s "$tmp" ]]; then
    :
  else
    rm -f "$tmp"
    return 1
  fi
  name=$(awk -F' = ' '/^pkgname/{print $2; exit}' "$tmp")
  pkgver=$(awk -F' = ' '/^pkgver/{print $2; exit}' "$tmp")
  pkgrel=$(awk -F' = ' '/^pkgrel/{print $2; exit}' "$tmp")
  epoch=$(awk -F' = ' '/^epoch/{print $2; exit}' "$tmp")
  arch=$(awk -F' = ' '/^arch/{print $2; exit}' "$tmp")
  rm -f "$tmp"
  [[ -n "$name" && -n "$pkgver" && -n "$arch" ]] || return 1
  if [[ -n "$pkgrel" ]]; then
    evr="${pkgver}-${pkgrel}"
  else
    evr="$pkgver"
  fi
  if [[ -n "$epoch" && "$epoch" != "0" ]]; then
    evr="${epoch}:${evr}"
  fi
  printf '%s|%s|%s\n' "$name" "$evr" "$arch"
}

# gh_publish_asset <tag> <repo> <file> <workdir> [kind]
# Content-aware upload: skips identical content, replaces changed content,
# uploads new content. Logs the required classification lines and updates
# the counters in PUBLISH_COUNTERS (initialized on first use). Returns 0
# on success/no-op, 1 on failure (no partial mutation is attempted after a
# failure).
gh_publish_asset() {
  local tag="$1" repo="$2" file="$3" workdir="$4" kind="${5:-asset}"
  local name status
  name="$(basename "$file")"

  gh_asset_status "$tag" "$repo" "$file" "$workdir" || true
  status="$ASSET_STATUS"

  case "$status" in
    UNCHANGED)
      echo "[publish] UNCHANGED ${kind}: ${name}"
      PUBLISH_COUNTERS[unchanged]=$(( PUBLISH_COUNTERS[unchanged] + 1 ))
      return 0
      ;;
    MISSING|NEW)
      echo "[publish] NEW ${kind}: ${name}"
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[publish] DRY-RUN: would upload ${kind}: ${name}"
        PUBLISH_COUNTERS[uploaded]=$(( PUBLISH_COUNTERS[uploaded] + 1 ))
        return 0
      fi
      if ! gh_upload_asset "$tag" "$repo" "$file"; then
        echo "[publish] FAILED ${kind}: ${name}"
        PUBLISH_COUNTERS[failed]=$(( PUBLISH_COUNTERS[failed] + 1 ))
        return 1
      fi
      PUBLISH_COUNTERS[uploaded]=$(( PUBLISH_COUNTERS[uploaded] + 1 ))
      return 0
      ;;
    CHANGED)
      # Package-version integrity gate: a package archive that changed
      # bytes while keeping the same name/version/pkgrel/arch identity is
      # NEVER silently replaced. This is a deliberate, fail-closed
      # safeguard (Phase D): it forces an explicit, intentional release
      # (e.g. a pkgrel bump or an explicit ALLOW_SAME_VERSION_REPLACE=1
      # override) before different bytes are published under the same
      # version. Necessary recovery of MISSING assets is handled by the
      # NEW path, and recovery of a CORRUPT remote asset is allowed below
      # (a remote archive that cannot be read/validated is not a valid
      # reference to protect). The database and metadata kinds do not
      # carry a package identity and are unaffected.
      if [[ "$kind" == "package" && "${ALLOW_SAME_VERSION_REPLACE:-0}" != "1" ]]; then
        local local_id remote_archive remote_id
        local_id="$(pkg_identity "$file")"
        remote_archive="$workdir/.remote-samever/$(basename "$file")"
        if [[ -n "$local_id" ]] \
            && mkdir -p "$(dirname "$remote_archive")" \
            && gh_download_asset_retry "$tag" "$repo" "$(basename "$file")" "$(dirname "$remote_archive")"; then
          if remote_id="$(pkg_identity "$remote_archive")" && [[ "$remote_id" == "$local_id" ]]; then
            gh_err "asset '$(basename "$file")' has the same package identity ($local_id) as the published asset but different bytes; refusing to silently replace a same-version archive. Bump pkgrel/version or set ALLOW_SAME_VERSION_REPLACE=1 to force."
            echo "[publish] FAILED ${kind}: $(basename "$file") (same-version byte drift; fail-closed)"
            PUBLISH_COUNTERS[failed]=$(( PUBLISH_COUNTERS[failed] + 1 ))
            return 1
          fi
          # remote archive exists but is unreadable/invalid (no identity):
          # a corrupt asset — allow the replacement (legitimate recovery).
          if [[ -z "${remote_id:-}" ]]; then
            gh_log "asset '$(basename "$file")': remote archive is unreadable (corrupt); allowing recovery replacement"
          fi
        fi
      fi
      echo "[publish] CHANGED ${kind}: ${name}"
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[publish] DRY-RUN: would replace ${kind}: ${name}"
        PUBLISH_COUNTERS[replaced]=$(( PUBLISH_COUNTERS[replaced] + 1 ))
        return 0
      fi
      if ! gh_upload_asset "$tag" "$repo" "$file"; then
        echo "[publish] FAILED ${kind}: ${name}"
        PUBLISH_COUNTERS[failed]=$(( PUBLISH_COUNTERS[failed] + 1 ))
        return 1
      fi
      PUBLISH_COUNTERS[replaced]=$(( PUBLISH_COUNTERS[replaced] + 1 ))
      return 0
      ;;
    UNKNOWN)
      # A hard-to-verify remote state must never be treated as a cache
      # hit, but we must also never delete a valid asset merely because
      # its checksum could not be retrieved. Fail closed.
      gh_err "asset status '${name}': remote checksum unknown; refusing to delete/replace an unverifiable asset"
      echo "[publish] FAILED ${kind}: ${name} (remote checksum unknown)"
      PUBLISH_COUNTERS[failed]=$(( PUBLISH_COUNTERS[failed] + 1 ))
      return 1
      ;;
    *)
      gh_err "asset status '${name}': failed to query remote state"
      echo "[publish] FAILED ${kind}: ${name}"
      PUBLISH_COUNTERS[failed]=$(( PUBLISH_COUNTERS[failed] + 1 ))
      return 1
      ;;
  esac
}

# publish_assets_loop <tag> <repo> <workdir> <kind> <files...>
# Ordered content-aware publish of a list of files; aborts on the first
# failure (dependent mutations must stop).
publish_assets_loop() {
  local tag="$1" repo="$2" workdir="$3" kind="$4"; shift 4
  local f
  for f in "$@"; do
    if ! gh_publish_asset "$tag" "$repo" "$f" "$workdir" "$kind"; then
      echo "::error::Publish failed for $(basename "$f"); aborting before any further mutation."
      return 1
    fi
  done
  return 0
}
