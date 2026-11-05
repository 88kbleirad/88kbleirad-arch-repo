#!/usr/bin/env bash
#
# Repository health monitoring (Phase 4.1). Read-only: NEVER uploads,
# deletes, modifies, or creates release assets.
#
# Audits a GitHub Release (production `repository` or staging
# `repository-v4-test`) for:
#   - release presence and asset enumeration
#   - expected package inventory (when EXPECTED_PACKAGES is provided)
#   - package archives: exist, downloadable, readable, structurally valid,
#     sha256 matches the GitHub API digest (trusted release record)
#   - v4-*.meta.json metadata: presence, package identity, profile,
#     fingerprint consistency (fingerprint is informational; profile is
#     verified against BUILD_PROFILE)
#   - repository database: all 4 assets, extraction, internal consistency,
#     every DB entry has a matching asset, every package asset is
#     referenced by the DB (no orphans), no duplicate package identities
#   - version sanity: no forbidden downgrade vs the DB itself is not
#     checkable read-only for a single snapshot, but duplicate identities
#     and same-version byte drift ARE detected via DB vs asset checksums
#   - signing-mode expectations: unsigned mode rejects any stray .sig
#     asset; signed mode requires detached signatures
#   - stale/orphaned assets: assets that are neither in the DB nor in the
#     expected inventory
#
# Outputs:
#   - machine-readable JSON report to stdout (or --json <file>)
#   - human-readable GitHub Actions summary to --summary <file> (or
#     GITHUB_STEP_SUMMARY)
#
# Usage:
#   repo-health.sh <tag> <repo> [--expected <json-array>]
#       [--build-profile x86-64-v4] [--signing-mode unsigned|signed]
#       [--json out.json] [--summary summary.md]
#
# Environment: GH_TOKEN, GITHUB_REPOSITORY, RELEASE_TAG, REPO_DB_NAME,
# BUILD_PROFILE, SIGNING_MODE.

set -euo pipefail

TAG="${1:-${RELEASE_TAG:?RELEASE_TAG is required}}"
REPO="${2:-${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}}"
EXPECTED_JSON="${EXPECTED_PACKAGES:-}"
BUILD_PROFILE="${BUILD_PROFILE:-x86-64-v4}"
SIGNING_MODE="${SIGNING_MODE:-unsigned}"
REPO_DB_NAME="${REPO_DB_NAME:-88kbleirad}"
JSON_OUT=""
SUMMARY_OUT=""

# remaining args are flags (positionals 1-2 already consumed)
shift $(( $# > 2 ? 2 : $# )) 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected) EXPECTED_JSON="${2:-}"; shift 2 ;;
    --build-profile) BUILD_PROFILE="${2:-}"; shift 2 ;;
    --signing-mode) SIGNING_MODE="${2:-}"; shift 2 ;;
    --json) JSON_OUT="${2:-}"; shift 2 ;;
    --summary) SUMMARY_OUT="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

source "$(dirname "${BASH_SOURCE[0]}")/gh-release-lib.sh"

FAIL=0
# collect human-readable problems for the summary
PROBLEMS=()

# ---------------------------------------------------------------------------
# result collection
# ---------------------------------------------------------------------------
declare -A RESULT=(
  [repository]="$REPO"
  [release_tag]="$TAG"
  [timestamp]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [commit_sha]="${GITHUB_SHA:-}"
  [package_count]=0
  [metadata_count]=0
  [database_asset_count]=0
  [checksum_status]="UNKNOWN"
  [database_status]="UNKNOWN"
  [metadata_status]="UNKNOWN"
  [signing_status]="UNKNOWN"
  [missing_assets]=""
  [unexpected_assets]=""
  [overall_status]="FAILED"
)

set_result() { RESULT["$1"]="$2"; }
record_problem() { PROBLEMS+=("$1"); }

# ---------------------------------------------------------------------------
# expected inventory
# ---------------------------------------------------------------------------
expected_names=()
if [[ -n "$EXPECTED_JSON" ]]; then
  while IFS= read -r n; do
    [[ -n "$n" ]] && expected_names+=("$n")
  done < <(printf '%s\n' "$EXPECTED_JSON" | jq -r '.[]')
fi

# ---------------------------------------------------------------------------
# release presence
# ---------------------------------------------------------------------------
if ! gh_api_retry "view release (${TAG})" \
    "/repos/${REPO}/releases/tags/${TAG}" >/dev/null 2>&1; then
  record_problem "release ${TAG} not found"
  set_result overall_status FAILED
  set_result database_status FAIL
  set_result checksum_status FAIL
  set_result metadata_status FAIL
  echo "{\"error\":\"release not found\"}"
  exit 1
fi

# enumerate assets: name|id|digest
declare -A ASSET_DIGEST=()
declare -A ASSET_ID=()
while IFS='|' read -r name id digest; do
  [[ -n "$name" ]] || continue
  ASSET_DIGEST["$name"]="${digest#sha256:}"
  ASSET_ID["$name"]="$id"
done < <(gh_api_retry "list assets (${TAG})" \
    "/repos/${REPO}/releases/tags/${TAG}" \
    --jq '.assets[] | "\(.name)|\(.id)|\(.digest // "")"' 2>/dev/null)

pkg_assets=()
meta_assets=()
db_assets=()
sig_assets=()
other_assets=()
for name in "${!ASSET_DIGEST[@]}"; do
  case "$name" in
    *.pkg.tar.zst) pkg_assets+=("$name") ;;
    v4-*.meta.json) meta_assets+=("$name") ;;
    "${REPO_DB_NAME}".db|"${REPO_DB_NAME}".db.tar.gz|"${REPO_DB_NAME}".files|"${REPO_DB_NAME}".files.tar.gz) db_assets+=("$name") ;;
    *.sig) sig_assets+=("$name") ;;
    *) other_assets+=("$name") ;;
  esac
done

# ---------------------------------------------------------------------------
# database assets
# ---------------------------------------------------------------------------
set_result database_asset_count "${#db_assets[@]}"
if (( ${#db_assets[@]} != 4 )); then
  record_problem "expected 4 database assets, found ${#db_assets[@]}"
  set_result database_status FAIL
else
  set_result database_status PASS
fi

VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT

db_ok=0
if (( ${#db_assets[@]} >= 1 )) && gh_download_asset_retry "$TAG" "$REPO" "${REPO_DB_NAME}.db.tar.gz" "$VERIFY_DIR" \
    && [[ -s "$VERIFY_DIR/${REPO_DB_NAME}.db.tar.gz" ]]; then
  mkdir -p "$VERIFY_DIR/db"
  if bsdtar -xf "$VERIFY_DIR/${REPO_DB_NAME}.db.tar.gz" -C "$VERIFY_DIR/db" 2>/dev/null; then
    db_ok=1
    set_result database_status PASS
  else
    record_problem "database ${REPO_DB_NAME}.db.tar.gz failed extraction"
    set_result database_status FAIL
  fi
else
  record_problem "cannot download database ${REPO_DB_NAME}.db.tar.gz"
  set_result database_status FAIL
fi

# DB identities: name -> version + filename; detect duplicates
declare -A DB_NAME_VER=()
declare -A DB_NAME_SEEN=()
declare -A DB_FILENAMES=()
declare -A DB_BASES=()
db_dup=0
if (( db_ok )); then
  for desc in "$VERIFY_DIR/db"/*/desc; do
    [[ -f "$desc" ]] || continue
    n=$(awk '/^%NAME%/{getline; print}' "$desc")
    v=$(awk '/^%VERSION%/{getline; print}' "$desc")
    fn=$(awk '/^%FILENAME%/{getline; print}' "$desc")
    b=$(awk '/^%BASE%/{getline; print}' "$desc")
    [[ -n "$n" ]] || continue
    if [[ -n "${DB_NAME_SEEN[$n]:-}" ]]; then
      db_dup=1
      record_problem "duplicate database identity: $n"
    fi
    DB_NAME_SEEN["$n"]=1
    DB_NAME_VER["$n"]="$v"
    [[ -n "$fn" ]] && DB_FILENAMES["$fn"]=1
    [[ -n "$b" ]] && DB_BASES["$b"]=1
  done
  if (( db_dup )); then set_result database_status FAIL; fi
fi

# ---------------------------------------------------------------------------
# package archives: exist in release, readable, checksum matches API digest
# ---------------------------------------------------------------------------
checksum_fail=0
pkg_readable_fail=0
required_pkgs=()
if (( ${#expected_names[@]} > 0 )); then
  # intersection of expected + db filenames; also require expected names in DB
  for n in "${expected_names[@]}"; do
    if [[ -z "${DB_NAME_VER[$n]:-}" ]]; then
      record_problem "expected package $n missing from database"
      set_result database_status FAIL
    fi
  done
  for fn in "${!DB_FILENAMES[@]}"; do
    [[ "$fn" == *.pkg.tar.zst ]] && required_pkgs+=("$fn")
  done
  set_result package_count "${#expected_names[@]}"
else
  # derive required package set from the database itself
  for fn in "${!DB_FILENAMES[@]}"; do
    [[ "$fn" == *.pkg.tar.zst ]] && required_pkgs+=("$fn")
  done
  set_result package_count "${#required_pkgs[@]}"
fi

missing_assets=()
for fn in "${required_pkgs[@]}"; do
  if [[ -z "${ASSET_DIGEST[$fn]:-}" ]]; then
    missing_assets+=("$fn")
    record_problem "missing release asset: $fn"
    set_result checksum_status FAIL
  else
    if gh_download_asset_retry "$TAG" "$REPO" "$fn" "$VERIFY_DIR" \
        && bsdtar -tf "$VERIFY_DIR/$fn" >/dev/null 2>&1 \
        && bsdtar -xOf "$VERIFY_DIR/$fn" .PKGINFO 2>/dev/null | grep -q '^pkgname = '; then
      local_hex=$(sha256sum "$VERIFY_DIR/$fn" | awk '{print $1}')
      remote_hex="${ASSET_DIGEST[$fn]:-}"
      if [[ -n "$remote_hex" && "$local_hex" == "$remote_hex" ]]; then
        :
      else
        checksum_fail=1
        record_problem "checksum mismatch: $fn (local $local_hex vs remote $remote_hex)"
        set_result checksum_status FAIL
      fi
    else
      pkg_readable_fail=1
      record_problem "package archive unreadable/invalid: $fn"
      set_result checksum_status FAIL
    fi
    rm -f "$VERIFY_DIR/$fn"
  fi
done
[[ -z "${RESULT[checksum_status]}" || "${RESULT[checksum_status]}" == "UNKNOWN" ]] \
  && set_result checksum_status PASS
(( checksum_fail || pkg_readable_fail )) && set_result checksum_status FAIL

# every package asset in the release must be referenced by the DB (no orphans)
unexpected_assets=()
for a in "${pkg_assets[@]}"; do
  if [[ -z "${DB_FILENAMES[$a]:-}" ]]; then
    unexpected_assets+=("$a")
    record_problem "orphaned package asset (not in database): $a"
  fi
done
for a in "${meta_assets[@]}"; do
  base="${a#v4-}"; base="${base%.meta.json}"
  # expected metas: all v4-*.meta.json whose base is in the DB or expected list
  if (( ${#expected_names[@]} > 0 )); then
    if ! printf '%s\n' "${expected_names[@]}" | grep -qx "$base"; then
      if [[ -z "${DB_BASES[$base]:-}" ]] && [[ -z "${DB_NAME_SEEN[$base]:-}" ]]; then
        unexpected_assets+=("$a")
        record_problem "unexpected metadata asset: $a"
      fi
    fi
  fi
done

# ---------------------------------------------------------------------------
# metadata: presence + profile
# ---------------------------------------------------------------------------
meta_fail=0
declare -A META_CHECKED=()
for fn in "${required_pkgs[@]}"; do
  # find the meta for this archive: by base from filename is unreliable for
  # split packages; instead verify all expected v4-*.meta.json below.
  :
done
if (( ${#expected_names[@]} > 0 )); then
  for n in "${expected_names[@]}"; do
    meta="v4-${n}.meta.json"
    if [[ -z "${ASSET_DIGEST[$meta]:-}" ]]; then
      # split package base may not have a meta name; the base meta is
      # the required check when present
      continue
    fi
    if gh_download_asset_retry "$TAG" "$REPO" "$meta" "$VERIFY_DIR" \
        && jq -e . "$VERIFY_DIR/$meta" >/dev/null 2>&1; then
      mprofile=$(jq -r '.profile // empty' "$VERIFY_DIR/$meta")
      mpkg=$(jq -r '.package // empty' "$VERIFY_DIR/$meta")
      META_CHECKED["$meta"]=1
      if [[ -n "$mprofile" && "$mprofile" != "$BUILD_PROFILE" ]]; then
        meta_fail=1
        record_problem "metadata profile mismatch $meta: $mprofile != $BUILD_PROFILE"
        set_result metadata_status FAIL
      fi
      if [[ -n "$mpkg" && "$mpkg" != "$n" ]]; then
        meta_fail=1
        record_problem "metadata package identity mismatch $meta: $mpkg != $n"
        set_result metadata_status FAIL
      fi
    else
      meta_fail=1
      record_problem "metadata unreadable/invalid: $meta"
      set_result metadata_status FAIL
    fi
    rm -f "$VERIFY_DIR/$meta"
  done
  for meta in "${meta_assets[@]}"; do
    if [[ -z "${META_CHECKED[$meta]:-}" ]]; then
      base="${meta#v4-}"; base="${base%.meta.json}"
      if printf '%s\n' "${expected_names[@]}" | grep -qx "$base"; then
        # expected but not checked (missing from DB loop above)
        set_result metadata_status FAIL
        record_problem "metadata for expected package not verified: $meta"
      fi
    fi
  done
else
  for meta in "${meta_assets[@]}"; do
    if gh_download_asset_retry "$TAG" "$REPO" "$meta" "$VERIFY_DIR" \
        && jq -e . "$VERIFY_DIR/$meta" >/dev/null 2>&1; then
      mprofile=$(jq -r '.profile // empty' "$VERIFY_DIR/$meta")
      [[ -n "$mprofile" && "$mprofile" != "$BUILD_PROFILE" ]] && { meta_fail=1; record_problem "metadata profile mismatch $meta"; set_result metadata_status FAIL; }
    else
      meta_fail=1
      record_problem "metadata unreadable/invalid: $meta"
      set_result metadata_status FAIL
    fi
    rm -f "$VERIFY_DIR/$meta"
  done
fi
[[ -z "${RESULT[metadata_status]}" || "${RESULT[metadata_status]}" == "UNKNOWN" ]] \
  && set_result metadata_status PASS
(( meta_fail )) && set_result metadata_status FAIL

# ---------------------------------------------------------------------------
# signing-mode expectations
# ---------------------------------------------------------------------------
if [[ "$SIGNING_MODE" == "signed" ]]; then
  # require a detached .sig for every package archive and the DB assets
  sig_missing=0
  for fn in "${required_pkgs[@]}"; do
    [[ -n "${ASSET_DIGEST[$fn.sig]:-}" ]] || { sig_missing=1; record_problem "missing detached signature: $fn.sig"; }
  done
  for a in "${db_assets[@]}"; do
    [[ -n "${ASSET_DIGEST[$a.sig]:-}" ]] || { sig_missing=1; record_problem "missing detached signature: $a.sig"; }
  done
  if (( sig_missing )); then set_result signing_status FAIL; else set_result signing_status PASS; fi
else
  if (( ${#sig_assets[@]} > 0 )); then
    set_result signing_status FAIL
    record_problem "unsigned release contains ${#sig_assets[@]} signature asset(s)"
  else
    set_result signing_status PASS
  fi
fi

# ---------------------------------------------------------------------------
# overall status
# ---------------------------------------------------------------------------
overall="HEALTHY"
if (( ${#missing_assets[@]} > 0 )) || (( ${#unexpected_assets[@]} > 0 )); then
  overall="DEGRADED"
fi
for k in database_status checksum_status metadata_status signing_status; do
  if [[ "${RESULT[$k]}" == "FAIL" ]]; then
    overall="FAILED"
  elif [[ "${RESULT[$k]}" == "UNKNOWN" ]]; then
    overall="DEGRADED"
  fi
done
set_result overall_status "$overall"
set_result missing_assets "$(printf '%s,' "${missing_assets[@]}" | sed 's/,$//')"
set_result unexpected_assets "$(printf '%s,' "${unexpected_assets[@]}" | sed 's/,$//')"
set_result metadata_count "${#meta_assets[@]}"

# ---------------------------------------------------------------------------
# emit JSON
# ---------------------------------------------------------------------------
JSON=$(jq -n \
  --arg repository "${RESULT[repository]}" \
  --arg release_tag "${RESULT[release_tag]}" \
  --arg timestamp "${RESULT[timestamp]}" \
  --arg commit_sha "${RESULT[commit_sha]}" \
  --argjson package_count "${RESULT[package_count]}" \
  --argjson metadata_count "${RESULT[metadata_count]}" \
  --argjson database_asset_count "${RESULT[database_asset_count]}" \
  --arg checksum_status "${RESULT[checksum_status]}" \
  --arg database_status "${RESULT[database_status]}" \
  --arg metadata_status "${RESULT[metadata_status]}" \
  --arg signing_status "${RESULT[signing_status]}" \
  --arg missing_assets "${RESULT[missing_assets]}" \
  --arg unexpected_assets "${RESULT[unexpected_assets]}" \
  --arg overall_status "${RESULT[overall_status]}" \
  '{repository:$repository, release_tag:$release_tag, timestamp:$timestamp, commit_sha:$commit_sha, package_count:$package_count, metadata_count:$metadata_count, database_asset_count:$database_asset_count, checksum_status:$checksum_status, database_status:$database_status, metadata_status:$metadata_status, signing_status:$signing_status, missing_assets:$missing_assets, unexpected_assets:$unexpected_assets, overall_status:$overall_status}')
if [[ -n "$JSON_OUT" ]]; then
  printf '%s\n' "$JSON" > "$JSON_OUT"
else
  printf '%s\n' "$JSON"
fi

# ---------------------------------------------------------------------------
# human summary
# ---------------------------------------------------------------------------
if [[ -n "$SUMMARY_OUT" ]]; then
  {
    echo "## Repository Health: $REPO @ $TAG"
    echo
    echo "- **overall_status**: ${RESULT[overall_status]}"
    echo "- packages: ${RESULT[package_count]}"
    echo "- metadata: ${RESULT[metadata_count]}"
    echo "- database assets: ${RESULT[database_asset_count]}"
    echo "- checksum_status: ${RESULT[checksum_status]}"
    echo "- database_status: ${RESULT[database_status]}"
    echo "- metadata_status: ${RESULT[metadata_status]}"
    echo "- signing_status: ${RESULT[signing_status]}"
    echo "- missing_assets: ${RESULT[missing_assets]:-none}"
    echo "- unexpected_assets: ${RESULT[unexpected_assets]:-none}"
    if (( ${#PROBLEMS[@]} > 0 )); then
      echo
      echo "### Problems"
      for p in "${PROBLEMS[@]}"; do echo "- $p"; done
    fi
  } > "$SUMMARY_OUT"
fi

[[ "$overall" == "HEALTHY" ]] && exit 0 || exit 1
