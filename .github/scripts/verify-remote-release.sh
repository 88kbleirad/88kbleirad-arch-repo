#!/usr/bin/env bash
#
# Remote post-publish verification (Objective B).
#
# After publishing, verify the ACTUAL remote GitHub Release: enumerate
# assets, confirm every required package archive, architecture metadata,
# and database/index asset exists, download and structurally validate the
# database, compare its package inventory against the expected inventory,
# confirm the database references only available assets, and reconcile
# remote digests against the intended local release manifest (the current
# output/ directory).
#
# Mandatory for successful production publication: on failure this script
# exits nonzero with a clear asset-level diagnostic. It never mutates the
# release, never deletes assets, and never rebuilds anything.
#
# Usage:
#   verify-remote-release.sh <tag> <repo> <expected-inventory-json>
#       [--manifest-dir <dir>] [--signing-mode unsigned|signed]
#
# Environment:
#   GH_TOKEN, RELEASE_TAG (for convenience), GITHUB_REPOSITORY
#   REPO_DB_NAME (default 88kbleirad)
#   SIGNING_MODE (default unsigned)
#
# Expected inventory JSON: ["pkgname", ...] (the prepare matrix output).

set -euo pipefail

TAG="${1:-${RELEASE_TAG:?RELEASE_TAG is required}}"
REPO="${2:-${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}}"
EXPECTED_JSON="${3:-${EXPECTED_PACKAGES:-}}"
MANIFEST_DIR=""
SIGNING_MODE="${SIGNING_MODE:-unsigned}"
REPO_DB_NAME="${REPO_DB_NAME:-88kbleirad}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-dir) shift; MANIFEST_DIR="$1" ;;
    --signing-mode) shift; SIGNING_MODE="$1" ;;
  esac
  shift
done

source "$(dirname "${BASH_SOURCE[0]}")/gh-release-lib.sh"

FAIL=0
fail() { echo "::error::$*"; FAIL=1; }
ok()  { echo "OK: $*"; }

echo "REMOTE RELEASE VERIFICATION"
echo "Release: $TAG"
echo "Repository: $REPO"

# -- expected inventory -----------------------------------------------------
expected_names=()
if [[ -n "$EXPECTED_JSON" ]]; then
  while IFS= read -r name; do
    [[ -n "$name" ]] && expected_names+=("$name")
  done < <(printf '%s\n' "$EXPECTED_JSON" | jq -r '.[]')
fi
echo "Packages expected: ${#expected_names[@]}"

# -- enumerate remote assets --------------------------------------------------
declare -A REMOTE_NAME_TO_DIGEST=()
declare -A REMOTE_NAME_TO_ID=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  name="${line%%|*}"
  rest="${line#*|}"
  id="${rest%%|*}"
  digest="${rest#*|}"
  REMOTE_NAME_TO_ID["$name"]="$id"
  REMOTE_NAME_TO_DIGEST["$name"]="$digest"
done < <(gh_api_retry "list assets (${TAG})" \
    "/repos/${REPO}/releases/tags/${TAG}" \
    --jq '.assets[] | "\(.name)|\(.id)|\(.digest // "")"' 2>/dev/null)

echo "Assets found: ${#REMOTE_NAME_TO_ID[@]}"

# -- architecture metadata -----------------------------------------------------
meta_validated=0
for name in "${expected_names[@]}"; do
  meta="${META_PREFIX:-v4}-${name}.meta.json"
  if [[ -n "${REMOTE_NAME_TO_ID[$meta]:-}" ]]; then
    meta_validated=$(( meta_validated + 1 ))
  else
    fail "missing metadata asset: $meta"
  fi
done
echo "Metadata validated: $meta_validated"

# -- canonical database/index assets + aliases ----------------------------------
db_assets=( "${REPO_DB_NAME}.db" "${REPO_DB_NAME}.db.tar.gz" \
            "${REPO_DB_NAME}.files" "${REPO_DB_NAME}.files.tar.gz" )
db_present=0
for a in "${db_assets[@]}"; do
  if [[ -n "${REMOTE_NAME_TO_ID[$a]:-}" ]]; then
    db_present=$(( db_present + 1 ))
  else
    fail "missing database asset: $a"
  fi
done
echo "Database assets: $db_present/4"

# -- download + verify database structure ----------------------------------------
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
if ! gh_download_asset_retry "$TAG" "$REPO" "${REPO_DB_NAME}.db.tar.gz" "$VERIFY_DIR"; then
  fail "cannot download database ${REPO_DB_NAME}.db.tar.gz"
fi
if [[ -f "$VERIFY_DIR/${REPO_DB_NAME}.db.tar.gz" ]] && \
   ! bsdtar -tf "$VERIFY_DIR/${REPO_DB_NAME}.db.tar.gz" >/dev/null 2>&1; then
  fail "database archive is corrupt/not readable"
fi
mkdir -p "$VERIFY_DIR/db"
if ! bsdtar -xf "$VERIFY_DIR/${REPO_DB_NAME}.db.tar.gz" -C "$VERIFY_DIR/db"; then
  fail "cannot extract database"
fi

# -- compare inventory against expected --------------------------------------------
declare -A DB_NAMES=()
declare -A DB_BASES=()
declare -A DB_FILENAMES=()
for desc in "$VERIFY_DIR/db"/*/desc; do
  [[ -f "$desc" ]] || continue
  dn=$(awk '/^%NAME%/{getline; print}' "$desc")
  dbase=$(awk '/^%BASE%/{getline; print}' "$desc")
  dfn=$(awk '/^%FILENAME%/{getline; print}' "$desc")
  [[ -n "$dn" ]] && DB_NAMES["$dn"]=1
  [[ -n "$dbase" ]] && DB_BASES["$dbase"]=1
  [[ -n "$dfn" ]] && DB_FILENAMES["$dfn"]=1
done

for name in "${expected_names[@]}"; do
  # split packages: the matrix entry is the base name; accept a match by
  # package name OR base in the remote database.
  if [[ -z "${DB_NAMES[$name]:-}" && -z "${DB_BASES[$name]:-}" ]]; then
    fail "expected package not present in remote database: $name"
  fi
done

# Every package the database references must exist as a release asset.
# For split packages the archive filename starts with the SUBPACKAGE name
# (e.g. base=splitbase -> sublib-1.0-1-x86_64.pkg.tar.zst), so the
# expected-inventory prefix match is insufficient by design; using the
# database's own %FILENAME% list is the exact, base-agnostic source of
# truth for the required archives.
for fn in "${!DB_FILENAMES[@]}"; do
  if [[ -z "${REMOTE_NAME_TO_ID[$fn]:-}" ]]; then
    fail "database references missing release asset: $fn"
  fi
done

# -- required package archives (from the database filenames) -----------------
pkg_needed=()
for fn in "${!DB_FILENAMES[@]}"; do
  [[ "$fn" == *.pkg.tar.zst ]] && pkg_needed+=("$fn")
done
pkg_available=0
pkg_validated=0
for fn in "${pkg_needed[@]}"; do
  if [[ -z "${REMOTE_NAME_TO_ID[$fn]:-}" ]]; then
    fail "missing package archive: $fn"
    continue
  fi
  pkg_available=$(( pkg_available + 1 ))
  if gh_download_asset_retry "$TAG" "$REPO" "$fn" "$(mktemp -d)"; then
    pkg_validated=$(( pkg_validated + 1 ))
  else
    fail "cannot download package archive: $fn"
  fi
done
echo "Packages available: $pkg_available"
echo "Packages validated: $pkg_validated"

# -- plain aliases correspond to canonical compressed counterparts ----------------
if [[ -f "$VERIFY_DIR/${REPO_DB_NAME}.db.tar.gz" ]]; then
  if ! gh_download_asset_retry "$TAG" "$REPO" "${REPO_DB_NAME}.db" "$VERIFY_DIR"; then
    fail "cannot download alias ${REPO_DB_NAME}.db"
  else
    d1=$(sha256sum "$VERIFY_DIR/${REPO_DB_NAME}.db.tar.gz" | awk '{print $1}')
    d2=$(sha256sum "$VERIFY_DIR/${REPO_DB_NAME}.db" | awk '{print $1}')
    [[ "$d1" == "$d2" ]] || fail "alias ${REPO_DB_NAME}.db digest differs from ${REPO_DB_NAME}.db.tar.gz"
  fi
  if ! gh_download_asset_retry "$TAG" "$REPO" "${REPO_DB_NAME}.files.tar.gz" "$VERIFY_DIR"; then
    fail "cannot download file index ${REPO_DB_NAME}.files.tar.gz"
  fi
  if ! gh_download_asset_retry "$TAG" "$REPO" "${REPO_DB_NAME}.files" "$VERIFY_DIR"; then
    fail "cannot download alias ${REPO_DB_NAME}.files"
  else
    d1=$(sha256sum "$VERIFY_DIR/${REPO_DB_NAME}.files.tar.gz" | awk '{print $1}')
    d2=$(sha256sum "$VERIFY_DIR/${REPO_DB_NAME}.files" | awk '{print $1}')
    [[ "$d1" == "$d2" ]] || fail "alias ${REPO_DB_NAME}.files digest differs from ${REPO_DB_NAME}.files.tar.gz"
  fi
fi

# -- checksum reconciliation against the local manifest (when available) ----------
checksum_fail=0
db_semantic_ok=1
if [[ -n "$MANIFEST_DIR" && -d "$MANIFEST_DIR" ]]; then
  # Database/index assets are reconciled SEMANTICALLY: repo-add embeds
  # timestamps, so byte-identical package sets still produce different
  # bytes. The content-aware publisher intentionally skips uploading a
  # semantically-unchanged database, so byte equality must not be
  # required for these four assets.
  db_semantic_ok=1
  mdb="$MANIFEST_DIR/${REPO_DB_NAME}.db.tar.gz"
  rdb="$VERIFY_DIR/${REPO_DB_NAME}.db.tar.gz"
  if [[ -f "$mdb" && -f "$rdb" ]]; then
    norm_db() { # file -> sorted "name|version|filename" lines
      local dir; dir="$(mktemp -d)"
      bsdtar -xf "$1" -C "$dir" 2>/dev/null
      for desc in "$dir"/*/desc; do
        [[ -f "$desc" ]] || continue
        local n v fn
        n=$(awk '/^%NAME%/{getline; print}' "$desc")
        v=$(awk '/^%VERSION%/{getline; print}' "$desc")
        fn=$(awk '/^%FILENAME%/{getline; print}' "$desc")
        printf '%s|%s|%s\n' "$n" "$v" "$fn"
      done | sort
      rm -rf "$dir"
    }
    if [[ "$(norm_db "$mdb")" != "$(norm_db "$rdb")" ]]; then
      fail "database semantic mismatch between manifest and remote"
      db_semantic_ok=0
    fi
  fi
  for f in "$MANIFEST_DIR"/*; do
    [[ -f "$f" ]] || continue
    bn=$(basename "$f")
    [[ -n "${REMOTE_NAME_TO_ID[$bn]:-}" ]] || continue
    case "$bn" in
      "${REPO_DB_NAME}.db"|"${REPO_DB_NAME}.db.tar.gz"|"${REPO_DB_NAME}.files"|"${REPO_DB_NAME}.files.tar.gz")
        [[ $db_semantic_ok -eq 1 ]] && continue
        ;;
    esac
    local_hex=$(sha256sum "$f" | awk '{print $1}')
    remote_hex="${REMOTE_NAME_TO_DIGEST[$bn]}"
    remote_hex="${remote_hex#sha256:}"
    if [[ -n "$remote_hex" ]] && [[ "$remote_hex" != "$local_hex" ]]; then
      fail "checksum mismatch: $bn (local $local_hex remote $remote_hex)"
      checksum_fail=1
    elif [[ -z "$remote_hex" ]]; then
      echo "WARNING: no remote digest for $bn; skipped checksum check"
    fi
  done
  if [[ $checksum_fail -eq 0 && $db_semantic_ok -eq 1 ]]; then
    echo "Checksums: PASS"
  fi
else
  echo "Checksums: N/A (no manifest dir)"
fi

# -- signing mode consistency ----------------------------------------------------------
if [[ "$SIGNING_MODE" == "signed" ]]; then
  for name in "${expected_names[@]}"; do
    found=""
    for rn in "${!REMOTE_NAME_TO_ID[@]}"; do
      if [[ "$rn" == "$name"-*.pkg.tar.zst ]]; then
        found="$rn"
        break
      fi
    done
    if [[ -n "$found" && -z "${REMOTE_NAME_TO_ID[$found.sig]:-}" ]]; then
      fail "signed mode: missing detached signature: $found.sig"
    fi
  done
  [[ -n "${REMOTE_NAME_TO_ID[${REPO_DB_NAME}.db.sig]:-}" ]] || fail "signed mode: missing db signature"
  [[ -n "${REMOTE_NAME_TO_ID[${REPO_DB_NAME}.files.sig]:-}" ]] || fail "signed mode: missing files signature"
  echo "Signing mode: signed (signatures required)"
else
  stale=0
  for rn in "${!REMOTE_NAME_TO_ID[@]}"; do
    case "$rn" in
      *.pkg.tar.zst.sig|"${REPO_DB_NAME}.db.sig"|"${REPO_DB_NAME}.db.tar.gz.sig"|"${REPO_DB_NAME}.files.sig"|"${REPO_DB_NAME}.files.tar.gz.sig")
        fail "unsigned mode: stale detached signature present: $rn"
        stale=1
        ;;
    esac
  done
  [[ $stale -eq 0 ]] && echo "Signing mode: unsigned (no stale signatures)"
fi

# -- summary ----------------------------------------------------------------------------
echo "Database consistency: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
echo "Result: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
[[ $FAIL -eq 0 ]]
