#!/usr/bin/env bash
#
# Runs inside the archlinux publish container (same lifecycle wrapper as
# publish-in-docker.sh) for the PRODUCTION release. Non-destructive:
#   - uploads refreshed package/db/meta assets into the existing release
#     with `--clobber`; the release is never deleted/recreated,
#   - merges the previously published repository database so a partial or
#     failed matrix run cannot silently drop valid packages,
#   - deletes only stale .pkg.tar.zst assets that are absent from the new
#     database AND not protected by a failed build (protect-*.txt),
#   - fails loudly when the previous release/database cannot be read,
#     instead of publishing a partial repository.
#
# Validation mirror of publish-stage.sh, plus drift cleanup.

set -euo pipefail

RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
REPO_DB_NAME="${REPO_DB_NAME:?REPO_DB_NAME is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
SIGNING_MODE="${SIGNING_MODE:-unsigned}"

case "$SIGNING_MODE" in
  unsigned|signed) ;;
  *) echo "::error::Invalid SIGNING_MODE '$SIGNING_MODE' (expected unsigned|signed)."; exit 1 ;;
esac

pacman -Syu --noconfirm --needed \
  github-cli pacman-contrib jq libarchive gnupg

# robust GitHub Release asset operations (retries, backoff, Retry-After,
# mutation reconciliation, sanitized logging)
. "$GITHUB_WORKSPACE/.github/scripts/gh-release-lib.sh"

if [[ "$SIGNING_MODE" == "signed" ]]; then
  # GPG signing: import the dedicated signing key into a scratch keyring
  # inside this publish job only. Build jobs never receive the key. All
  # signatures are created and verified below; any failure aborts the run
  # before anything is uploaded.
  . "$GITHUB_WORKSPACE/.github/scripts/sign-helpers.sh"
  gpg_init_homedir
  if ! gpg_import_signing_key; then
    echo "::error::No signing key available; aborting publication."
    exit 1
  fi
  export REQUIRE_SIGNATURES=1
else
  echo "== Unsigned publish mode (no GPG, per optional-signing configuration) =="
  export REQUIRE_SIGNATURES=0
fi

# usage: gh_download_retry <pattern> <dir>
# Returns 0 when the file was downloaded and is non-empty. Returns 2 for
# a clean miss (the release has no matching asset — distinct from a
# transient API/transport failure). Returns 1 after exhausted retries on
# genuine failures. stderr is surfaced (sanitized) instead of dropped so
# the exact failure (HTTP/transport) is visible in the job log.
gh_download_retry() {
  local pattern="$1" dir="$2" attempt rc f=""
  for attempt in 1 2 3; do
    local err
    err="$(mktemp)"
    gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
        --dir "$dir" --pattern "$pattern" 2>"$err"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      rm -f "$err"
      local candidate
      for candidate in "$dir"/$(basename "$pattern"); do
        [[ -s "$candidate" ]] && f="$candidate"
      done
      if [[ -n "$f" ]]; then
        return 0
      fi
      echo "[publish] download reported success for '$pattern' but no file was produced"
      return 2
    fi
    local msg
    msg="$(cat "$err")"
    rm -f "$err"
    if grep -q 'no assets match the file pattern' <<<"$msg"; then
      echo "[publish] asset '$pattern' does not exist in the release (clean miss)"
      return 2
    fi
    echo "[publish] download attempt $attempt/3 failed for '$pattern' (rc=$rc): $msg"
    [[ $attempt -lt 3 ]] && sleep 5
  done
  return 1
}

# usage: validate_pkg_archive <file>
# True when the file is a readable package archive carrying a pkgname in
# .PKGINFO. Used by the database-recovery path before trusting an existing
# release asset.
validate_pkg_archive() {
  local f="$1" name
  [[ -s "$f" ]] || return 1
  bsdtar -tf "$f" >/dev/null 2>&1 || return 1
  name=$(bsdtar -xOf "$f" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgname/{print $2; exit}')
  [[ -n "$name" ]]
}

cd "$GITHUB_WORKSPACE/output"

echo "== Validate package archives and metadata =="
shopt -s nullglob
pkgs=( *.pkg.tar.zst )
if (( ${#pkgs[@]} == 0 )); then
  echo "::error::No package files produced in this run."
  exit 1
fi
for pkg in "${pkgs[@]}"; do
  if ! bsdtar -tf "$pkg" >/dev/null 2>&1; then
    echo "::error::Package archive corrupt: $pkg"
    exit 1
  fi
  if ! bsdtar -xOf "$pkg" .PKGINFO 2>/dev/null | grep -q '^pkgname = '; then
    echo "::error::Package missing .PKGINFO: $pkg"
    exit 1
  fi
  echo "Validated: $pkg"
done

REPO="$GITHUB_REPOSITORY"
TAG="$RELEASE_TAG"

# -- non-destructive merge with the previously published release ----------
MERGE_DIR="$(mktemp -d)"
merged_assets=( *.pkg.tar.zst )
MERGED=0
declare -A PROCESSED_STATUS
PREV_DB_MODE="none"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  mkdir -p "$MERGE_DIR/db"
  # Distinguish three outcomes for the canonical database asset:
  #   0 -> downloaded
  #   2 -> clean miss (asset absent) — the packages may still be present;
  #        this is NOT a reason to abort, but it IS a reason to recover.
  #   1 -> genuine transient failure after retries -> abort (never risk a
  #        partial publish because of a flaky API).
  db_dl_rc=0
  gh_download_retry "${REPO_DB_NAME}.db.tar.gz" "$MERGE_DIR" || db_dl_rc=$?
  case "$db_dl_rc" in
    0)
      PREV_DB_MODE="db"
      ;;
    2)
      PREV_DB_MODE="missing"
      echo "::warning::Release $TAG has no ${REPO_DB_NAME}.db.tar.gz asset (asset absent — not a transient failure)."
      ;;
    *)
      echo "::error::Release $TAG exists but its ${REPO_DB_NAME}.db.tar.gz could not be downloaded (transient API/transport failure after retries); refusing to publish."
      rm -rf "$MERGE_DIR"
      exit 1
      ;;
  esac

  # bases processed this run with their status (from metadata written by
  # build-package.sh: built | skipped | restored | failed)
  for meta in v4-*.meta.json; do
    base=$(jq -r '.package // empty' "$meta")
    status=$(jq -r '.status // empty' "$meta")
    [[ -n "$base" ]] && PROCESSED_STATUS["$base"]="$status"
  done

  # names of packages this run produced fresh
  declare -A NEW_NAMES=()
  for pkg in "${pkgs[@]}"; do
    name=$(bsdtar -xOf "$pkg" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgname/{print $2; exit}')
    [[ -n "$name" ]] && NEW_NAMES["$name"]=1
  done

  if [[ "$PREV_DB_MODE" == "db" ]]; then
  if ! bsdtar -xf "$MERGE_DIR/${REPO_DB_NAME}.db.tar.gz" -C "$MERGE_DIR/db"; then
    echo "::error::Cannot extract production database; refusing to publish a partial repository."
    rm -rf "$MERGE_DIR"
    exit 1
  fi

  for desc in "$MERGE_DIR/db"/*/desc; do
    [[ -f "$desc" ]] || continue
    fname=$(awk '/^%FILENAME%/{getline; print}' "$desc")
    base=$(awk '/^%BASE%/{getline; print}' "$desc")
    name=$(awk '/^%NAME%/{getline; print}' "$desc")
    [[ -n "$fname" ]] || continue
    if [[ -n "${NEW_NAMES[$name]:-}" ]]; then
      # superseded by a fresh archive in this run
      continue
    fi
    if [[ -n "$base" && -n "${PROCESSED_STATUS[$base]:-}" \
        && "${PROCESSED_STATUS[$base]}" != "failed" ]]; then
      # base was processed with a non-failed status but produced no
      # archive with this name: dropped (split package changed)
      echo "Not superseded but processed without this subpackage; dropping: $fname"
      continue
    fi
    if [[ ! -f "$fname" ]]; then
      if gh_download_retry "$fname" "$PWD"; then
        merged_assets+=("$fname")
        MERGED=$(( MERGED + 1 ))
        echo "Kept previously published package: $fname"
        # Signed mode: carry the previously published signature forward when
        # it exists and verifies against the current signing key. A
        # signature that fails verification means the asset was tampered
        # with or signed by a different key — refuse to publish it.
        if [[ "$SIGNING_MODE" == "signed" ]]; then
          if gh_download_retry "$fname.sig" "$PWD"; then
            if ! verify_detached "$fname" "$fname.sig"; then
              echo "::error::Previously published signature for $fname failed verification; refusing to publish."
              rm -rf "$MERGE_DIR"
              exit 1
            fi
            echo "Kept previously published signature: $fname.sig"
          fi
        fi
        local_meta="v4-${base}.meta.json"
        if [[ -f "$local_meta" ]]; then
          rm -f "$local_meta"
        fi
        if gh_download_retry "v4-${base}.meta.json" "$PWD"; then
          echo "Kept architecture metadata: v4-${base}.meta.json"
        else
          echo "::warning::No released metadata for kept package ${base}; writing a placeholder that forces a rebuild on the next run."
          printf '{\n  "package": %s,\n  "profile": "x86-64-v4",\n  "status": "restored",\n  "fingerprint": "placeholder-unavailable",\n  "built_at": %s\n}\n' \
            "$(printf '%s' "$base" | jq -R .)" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ | jq -R .)" \
            > "$local_meta"
        fi
      else
        echo "::error::Previously published package $fname cannot be restored; refusing to publish a partial repository."
        rm -rf "$MERGE_DIR"
        exit 1
      fi
    fi
  done

  # remember protected asset names for drift cleanup (failed bases and
  # excluded system-critical bases keep their previously published files)
  declare -A PROTECTED=()
  if shopt -s nullglob; then
    for pf in protect-*.txt; do
      while IFS= read -r name; do
        [[ -n "$name" ]] && PROTECTED["$name"]=1
      done < "$pf"
    done
  fi
  if [[ -n "${EXCLUDED_BASES_FILE:-}" && -f "$EXCLUDED_BASES_FILE" ]]; then
    while IFS= read -r base; do
      [[ -n "$base" ]] || continue
      for desc in "$MERGE_DIR/db"/*/desc; do
        [[ -f "$desc" ]] || continue
        if [[ "$(awk '/^%BASE%/{getline; print}' "$desc")" == "$base" ]]; then
          asset=$(awk '/^%FILENAME%/{getline; print}' "$desc")
          [[ -n "$asset" ]] && PROTECTED["$asset"]=1
        fi
      done
    done < "$EXCLUDED_BASES_FILE"
  fi
  fi # PREV_DB_MODE == db

  # -- controlled recovery: the canonical database asset is absent from
  # the release (it was never uploaded or was lost), but the package
  # archives may still be intact. Reconstruct the database from the
  # release's EXISTING, validated package archives, then reconcile with
  # the expected inventory below. This is fail-closed:
  #   - every candidate archive is downloaded and fully validated
  #     (readable, .PKGINFO present) before it is trusted;
  #   - if a package in the complete expected inventory is neither built
  #     this run nor present as a validated release asset, publication is
  #     refused BEFORE any mutation;
  #   - the release assets themselves are never deleted here (drift
  #     cleanup below runs only against the regenerated database).
  if [[ "$PREV_DB_MODE" == "missing" ]]; then
    echo "::warning::Release $TAG has no ${REPO_DB_NAME}.db.tar.gz; reconstructing the repository database from existing validated release package archives."
    local_assets=()
    while IFS= read -r asset; do
      [[ -n "$asset" && "$asset" == *.pkg.tar.zst ]] || continue
      if [[ -f "$asset" ]]; then
        # already fresh in output/ this run (superseded copy)
        continue
      fi
      if gh_download_retry "$asset" "$PWD"; then
        local_assets+=("$asset")
      else
        echo "::error::Recovery: cannot download release archive $asset; refusing to publish a reconstructed partial repository."
        rm -rf "$MERGE_DIR"
        exit 1
      fi
    done < <(gh_list_assets "$TAG" "$REPO")

    recovered=0
    for f in "${local_assets[@]}"; do
      if validate_pkg_archive "$f"; then
        merged_assets+=("$f")
        recovered=$(( recovered + 1 ))
        echo "Recovered previously published package: $f"
        # preserve architecture-aware metadata: reuse the released meta when
        # it exists, else write a placeholder that forces a rebuild next run
        base=""
        base=$(bsdtar -xOf "$f" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgbase/{print $2; exit}')
        [[ -n "$base" ]] || base=$(bsdtar -xOf "$f" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgname/{print $2; exit}')
        if [[ -n "$base" ]]; then
          local_meta="v4-${base}.meta.json"
          if [[ ! -f "$local_meta" ]]; then
            if gh_download_retry "$local_meta" "$PWD"; then
              echo "Kept architecture metadata: $local_meta"
            else
              echo "::warning::No released metadata for recovered package ${base}; writing a placeholder that forces a rebuild on the next run."
              printf '{\n  "package": %s,\n  "profile": "x86-64-v4",\n  "status": "restored",\n  "fingerprint": "placeholder-unavailable",\n  "built_at": %s\n}\n' \
                "$(printf '%s' "$base" | jq -R .)" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ | jq -R .)" \
                > "$local_meta"
            fi
          fi
        fi
      else
        echo "::error::Recovery: release archive $f failed validation; refusing to publish a reconstructed partial repository."
        rm -rf "$MERGE_DIR"
        exit 1
      fi
    done
    if (( recovered > 0 )); then
      echo "Recovery complete: ${recovered} previously published package(s) merged back into the database."
    fi
  fi
else
  echo "Production release $TAG does not exist yet; nothing to merge."
fi

if [[ "$SIGNING_MODE" == "signed" ]]; then
  echo "== Sign package archives =="
  if ! ensure_all_packages_signed; then
    echo "::error::Package signing/verification failed; refusing to publish."
    rm -rf "$MERGE_DIR"
    exit 1
  fi
fi

echo "== Generate fresh pacman database =="
rm -f status-*.txt protect-*.txt
if [[ "$SIGNING_MODE" == "signed" ]]; then
  repo-add --include-sigs "${REPO_DB_NAME}.db.tar.gz" "${merged_assets[@]}"
else
  repo-add "${REPO_DB_NAME}.db.tar.gz" "${merged_assets[@]}"
fi

# repo-add (pacman >= 7) already creates the plain <db>.db / <db>.files
# aliases as symlinks to the canonical compressed counterparts; they are
# uploaded as distinct assets with identical bytes/digests. No extra copy
# is needed (and `cp` over the symlink would error as "same file").

# Database changed-detection is SEMANTIC: `repo-add` embeds current
# timestamps (verified: byte-identical re-add yields different sha256), so
# byte comparison can never be stable. Compare the canonical package set
# (FILENAME/NAME/BASE/VERSION) instead. When the remote database references
# exactly the same set, it is UNCHANGED and must not be re-uploaded.
DB_SEMANTIC_SAME="no"
if [[ -f "$MERGE_DIR/${REPO_DB_NAME}.db.tar.gz" ]]; then
  rm -rf "$MERGE_DIR/db-new"
  mkdir -p "$MERGE_DIR/db-new"
  if bsdtar -xf "${REPO_DB_NAME}.db.tar.gz" -C "$MERGE_DIR/db-new"; then
    local_db_keys=""
    for desc in "$MERGE_DIR/db-new"/*/desc; do
      [[ -f "$desc" ]] || continue
      local_db_keys+="$(awk '/^%FILENAME%/{getline; print; next} /^%NAME%/{getline; print; next} /^%BASE%/{getline; print; next} /^%VERSION%/{getline; print; next}' "$desc" | tr '\n' '|')"
      local_db_keys+=$'\n'
    done
    local_db_keys="$(printf '%s' "$local_db_keys" | sort)"
    remote_db_keys=""
    for desc in "$MERGE_DIR/db"/*/desc; do
      [[ -f "$desc" ]] || continue
      remote_db_keys+="$(awk '/^%FILENAME%/{getline; print; next} /^%NAME%/{getline; print; next} /^%BASE%/{getline; print; next} /^%VERSION%/{getline; print; next}' "$desc" | tr '\n' '|')"
      remote_db_keys+=$'\n'
    done
    remote_db_keys="$(printf '%s' "$remote_db_keys" | sort)"
    if [[ "$local_db_keys" == "$remote_db_keys" ]]; then
      DB_SEMANTIC_SAME="yes"
    fi
    rm -rf "$MERGE_DIR/db-new"
  fi
fi

if [[ "$SIGNING_MODE" == "signed" ]]; then
  echo "== Sign repository database =="
  if ! sign_and_publish_db_signatures; then
    echo "::error::Database signing/verification failed; refusing to publish."
    rm -rf "$MERGE_DIR"
    exit 1
  fi
fi

echo "== Validate repository consistency =="
if ! bash "$GITHUB_WORKSPACE/.github/scripts/validate-release.sh" "$PWD" "$REPO_DB_NAME" | tee "$GITHUB_STEP_SUMMARY"; then
  echo "::error::Validation failed; refusing to publish."
  rm -rf "$MERGE_DIR"
  exit 1
fi

# -- expected package inventory enforcement --------------------------------
# Every package the prepare matrix selected MUST be present as a validated
# archive in the new database. A silent miss (failed/restored/no-archive
# metadata) must fail here BEFORE any Release mutation — never accept
# VALIDATION_PASSED=true when a requested package is missing.
if [[ -n "${EXPECTED_PACKAGES:-}" ]]; then
  echo "== Verify expected package inventory =="
  # EXPECTED_PACKAGES arrives as JSON array from the prepare matrix
  expected_names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && expected_names+=("$name")
  done < <(printf '%s\n' "$EXPECTED_PACKAGES" | jq -r '.[]')
  (( ${#expected_names[@]} > 0 )) || { echo "::error::Expected package list parsed empty; refusing to publish."; rm -rf "$MERGE_DIR"; exit 1; }

  # package filenames in the freshly generated database
  rm -rf .inv-db; mkdir -p .inv-db
  bsdtar -xf "${REPO_DB_NAME}.db.tar.gz" -C .inv-db
  db_pkg_names=()
  db_pkg_bases=()
  for desc in .inv-db/*/desc; do
    [[ -f "$desc" ]] || continue
    db_pkg_names+=("$(awk '/^%NAME%/{getline; print}' "$desc")")
    base=$(awk '/^%BASE%/{getline; print}' "$desc")
    [[ -n "$base" ]] && db_pkg_bases+=("$base")
  done
  rm -rf .inv-db

  missing_count=0
  for name in "${expected_names[@]}"; do
    # a requested package is present when the database contains it by
    # package name OR by package base (split packages: the matrix base
    # may not equal any subpackage name).
    if ! printf '%s\n' "${db_pkg_names[@]}" "${db_pkg_bases[@]}" | grep -qx "$name"; then
      echo "::error::Expected package '${name}' is missing from the regenerated production database (silent-miss check)."
      missing_count=$(( missing_count + 1 ))
    fi
  done
  if (( missing_count > 0 )); then
    echo "::error::Inventory check failed (${missing_count} missing). Refusing to publish; the Release was not modified."
    rm -rf "$MERGE_DIR"
    exit 1
  fi
  echo "Inventory OK: all ${#expected_names[@]} requested packages are present and validated."
fi

echo "== Publish to production release (non-destructive) =="
if [[ "$SIGNING_MODE" == "signed" ]]; then
  pkg_assets=( *.pkg.tar.zst *.pkg.tar.zst.sig )
else
  pkg_assets=( *.pkg.tar.zst )
fi
db_assets=( "${REPO_DB_NAME}".db* "${REPO_DB_NAME}".files* )
meta_assets=( v4-*.meta.json )
if (( ${#pkg_assets[@]} == 0 )); then
  echo "::error::No package files in output/; refusing to publish."
  rm -rf "$MERGE_DIR"
  exit 1
fi
if (( ${#db_assets[@]} == 0 )); then
  echo "::error::No pacman database files in output/; refusing to publish a repository without a database."
  rm -rf "$MERGE_DIR"
  exit 1
fi
if (( ${#meta_assets[@]} == 0 )); then
  echo "::error::No architecture metadata files; refusing to publish."
  rm -rf "$MERGE_DIR"
  exit 1
fi
pub_assets=()
if [[ "$SIGNING_MODE" == "signed" ]]; then
  if ! export_public_key; then
    echo "::error::Failed to export the public signing key; refusing to publish."
    rm -rf "$MERGE_DIR"
    exit 1
  fi
  pub_assets=( ${REPO_DB_NAME}.pub.asc )
fi

# Ensure the release exists (with retries via the lib)
if gh_api_retry "view release (${TAG})" \
    "/repos/${REPO}/releases/tags/${TAG}" >/dev/null 2>&1; then
  echo "Release $TAG exists; merging this run into it."
else
  echo "Creating release $TAG."
  gh_api_retry "create release (${TAG})" \
    --method POST "/repos/${REPO}/releases" \
    --field tag_name="$TAG" \
    --field name="Arch Package Repository" \
    --field body="Auto-built pacman repository." >/dev/null 2>&1
fi

# -- preflight: detect every package conflict BEFORE any mutation ---------
# Scan all local package assets against the remote release (via the
# published database and per-asset state). Two hard errors abort the run
# before a single upload/delete happens:
#   1. same-version byte drift (identical name/version/pkgrel/arch,
#      different bytes) — never silently replaced;
#   2. version regression — a local package version lower than the
#      published version (pacman vercmp semantics), e.g. a VCS package
#      resolving below its published version after an upstream history
#      rewrite/tag deletion. The repository must never be downgraded.
# The per-asset gate in gh_publish_asset remains as a second line of
# defense.
preflight_package_assets() {
  # remote published name -> version (from the downloaded production DB)
  local -A REMOTE_VER=()
  if [[ "$PREV_DB_MODE" == "db" ]]; then
    local desc
    for desc in "$MERGE_DIR/db"/*/desc; do
      [[ -f "$desc" ]] || continue
      local dn dv
      dn=$(awk '/^%NAME%/{getline; print}' "$desc")
      dv=$(awk '/^%VERSION%/{getline; print}' "$desc")
      [[ -n "$dn" && -n "$dv" ]] && REMOTE_VER["$dn"]="$dv"
    done
  fi

  local conflict=0
  local f
  for f in "${pkg_assets[@]}"; do
    local name
    name="$(basename "$f")"
    # signed mode includes detached .sig assets in pkg_assets; they are
    # not package archives and carry no identity to compare
    [[ "$name" == *.pkg.tar.zst ]] || continue
    local local_id
    local_id="$(pkg_identity "$f")"
    [[ -n "$local_id" ]] || { echo "::error::preflight: cannot read package identity for $name"; conflict=1; continue; }
    local lname lver larch
    IFS='|' read -r lname lver larch <<< "$local_id"

    gh_asset_status "$TAG" "$REPO" "$f" "$PWD" || true
    case "$ASSET_STATUS" in
      CHANGED)
        if [[ "${ALLOW_SAME_VERSION_REPLACE:-0}" != "1" ]]; then
          local remote_archive remote_id
          remote_archive="$PWD/.remote-samever/$name"
          if [[ -n "$local_id" ]] \
              && mkdir -p "$(dirname "$remote_archive")" \
              && gh_download_asset_retry "$TAG" "$REPO" "$name" "$(dirname "$remote_archive")"; then
            if remote_id="$(pkg_identity "$remote_archive")" && [[ "$remote_id" == "$local_id" ]]; then
              echo "::error::preflight: package $name has the same identity ($local_id) as the published asset but different bytes; refusing to publish (set ALLOW_SAME_VERSION_REPLACE=1 only for an intentional override)."
              conflict=1
            fi
          fi
        fi
        ;;
    esac

    # version regression check against the published database: if the same
    # package name exists remotely with a HIGHER version, this run would
    # downgrade it.
    local rver="${REMOTE_VER[$lname]:-}"
    if [[ -n "$rver" ]]; then
      local sign
      sign=$(vercmp "$lver" "$rver")
      if [[ "$sign" == "-1" ]]; then
        echo "::error::preflight: package $lname version regression: local $lver < published $rver (pacman semantics); refusing to downgrade. Upstream history/tag change or wrong pkgver() requires explicit approval."
        conflict=1
      fi
    fi
  done
  if [[ "$conflict" -eq 1 ]]; then
    echo "::error::preflight aborted: package conflict/regression detected; no Release assets were modified."
    rm -rf "$MERGE_DIR"
    exit 1
  fi
  echo "preflight: all ${#pkg_assets[@]} package assets conflict-free"
}
preflight_package_assets

# Publish content-aware (Objective A): skip identical checksums, upload
# only new/changed assets, never delete a valid asset because its checksum
# could not be retrieved. Order matters: packages first, then metadata,
# then the database (the DB must never be published before the archives it
# references exist). A single failure aborts all later dependent mutations.
declare -A PUBLISH_COUNTERS=( [unchanged]=0 [uploaded]=0 [replaced]=0 [failed]=0 )

# packages + metadata first
publish_assets_loop "$TAG" "$REPO" "$PWD" "package" "${pkg_assets[@]}" || exit 1
publish_assets_loop "$TAG" "$REPO" "$PWD" "metadata" "${meta_assets[@]}" || exit 1
if (( ${#pub_assets[@]} > 0 )); then
  publish_assets_loop "$TAG" "$REPO" "$PWD" "public-key" "${pub_assets[@]}" || exit 1
fi

# database assets: if the regenerated DB is semantically identical to the
# previously published one, skip ALL database assets (the canonical files
# and their aliases). repo-add embeds timestamps, so the bytes always
# differ even for an identical package set; semantic equality is the only
# stable signal and avoids pointless re-uploads.
db_files=()
if [[ "$DB_SEMANTIC_SAME" == "yes" ]]; then
  echo "[publish] UNCHANGED database set (semantic): ${REPO_DB_NAME}.db/.files ..."
  PUBLISH_COUNTERS[unchanged]=$(( PUBLISH_COUNTERS[unchanged] + ${#db_assets[@]} ))
else
  db_files=( "${db_assets[@]}" )
  publish_assets_loop "$TAG" "$REPO" "$PWD" "database" "${db_files[@]}" || exit 1
fi

echo "[publish] SUMMARY unchanged=${PUBLISH_COUNTERS[unchanged]} uploaded=${PUBLISH_COUNTERS[uploaded]} replaced=${PUBLISH_COUNTERS[replaced]} failed=${PUBLISH_COUNTERS[failed]}"

# -- drift cleanup: delete only stale un-protected package assets ---------
stale_assets=()
if [[ -f "$MERGE_DIR/${REPO_DB_NAME}.db.tar.gz" ]]; then
  while IFS= read -r asset; do
    [[ -n "$asset" ]] || continue
    [[ "$asset" == *.pkg.tar.zst ]] || continue
    # still part of the new repository? keep
    in_db=0
    for d in "${merged_assets[@]}"; do
      [[ "$d" == "$asset" ]] && { in_db=1; break; }
    done
    [[ $in_db -eq 1 ]] && continue
    # protected by a failed build (or explicit protect-*.txt)?
    if [[ -n "${PROTECTED[$asset]:-}" || -n "${PROTECTED["*"]:-}" ]]; then
      echo "Keeping protected asset: $asset"
      continue
    fi
    # base package status failed -> keep last-known-good
    base=""
    for desc in "$MERGE_DIR/db"/*/desc; do
      [[ -f "$desc" ]] || continue
      if [[ "$(awk '/^%FILENAME%/{getline; print}' "$desc")" == "$asset" ]]; then
        base=$(awk '/^%BASE%/{getline; print}' "$desc")
        [[ -z "$base" ]] && base=$(awk '/^%NAME%/{getline; print}' "$desc")
        break
      fi
    done
    if [[ -n "$base" && -n "${PROCESSED_STATUS[$base]:-}" \
        && "${PROCESSED_STATUS[$base]}" == "failed" ]]; then
      echo "Keeping failed-base asset: $asset"
      continue
    fi
    stale_assets+=("$asset")
  done < <(gh_list_assets "$TAG" "$REPO")
fi
rm -rf "$MERGE_DIR"

if (( ${#stale_assets[@]} > 0 )); then
  echo "Deleting stale assets that are no longer part of the repository:"
  for stale in "${stale_assets[@]}"; do
    echo "  - $stale"
    if ! gh_delete_asset "$TAG" "$REPO" "$stale"; then
      echo "::error::Cannot delete stale asset $stale; the next run will retry."
      exit 1
    fi
    # its detached signature is stale with it (the archive is gone, so
    # a leftover .sig would be an orphan asset)
    if gh_list_assets "$TAG" "$REPO" | grep -qx "${stale}.sig"; then
      gh_delete_asset "$TAG" "$REPO" "${stale}.sig" \
        || echo "::warning::Cannot delete orphaned signature ${stale}.sig; the next run will retry."
    fi
  done
else
  echo "No stale assets to delete."
fi

# Unsigned mode: the released repository is unsigned by design; remove any
# leftover detached signatures so no mismatched/invalid .sig remains
# published (e.g. from an earlier signed run that is now superseded).
if [[ "$SIGNING_MODE" == "unsigned" ]]; then
  echo "== Purging detached signatures (unsigned mode) =="
  while IFS= read -r asset; do
    [[ -n "$asset" ]] || continue
    case "$asset" in
      *.pkg.tar.zst.sig|"${REPO_DB_NAME}.db.sig"|"${REPO_DB_NAME}.db.tar.gz.sig"|"${REPO_DB_NAME}.files.sig"|"${REPO_DB_NAME}.files.tar.gz.sig")
        echo "Deleting superseded signature asset: $asset"
        gh_delete_asset "$TAG" "$REPO" "$asset" \
          || echo "::warning::Cannot delete stale signature $asset; the next run will retry."
        ;;
    esac
  done < <(gh_list_assets "$TAG" "$REPO")
fi

echo "Published production release: $REPO/releases/tag/$TAG"

# -- remote post-publish verification (Objective B) -------------------------
# Mandatory: the local repository may be consistent while the remote
# Release is incomplete (the historical failure mode). Verify the actual
# remote state before declaring success. Never mutates the release.
echo "== Remote post-publish verification =="
if ! bash "$GITHUB_WORKSPACE/.github/scripts/verify-remote-release.sh" \
    "$TAG" "$REPO" "${EXPECTED_PACKAGES:-}" \
    --manifest-dir "$PWD" \
    --signing-mode "$SIGNING_MODE" | tee -a "$GITHUB_STEP_SUMMARY"; then
  echo "::error::Remote verification failed; the Release may be incomplete. Refusing to report success."
  exit 1
fi
echo "== Remote verification passed =="
