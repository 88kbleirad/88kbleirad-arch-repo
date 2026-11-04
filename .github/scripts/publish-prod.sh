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

pacman -Syu --noconfirm --needed \
  github-cli pacman-contrib jq libarchive

# usage: gh_download_retry <pattern> <dir>
# Returns 0 when the file was downloaded and is non-empty. Returns 2 for
# a clean miss (no matching asset).
gh_download_retry() {
  local pattern="$1" dir="$2" attempt rc f=""
  for attempt in 1 2 3; do
    gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
        --dir "$dir" --pattern "$pattern" 2>/dev/null
    rc=$?
    if [[ $rc -eq 0 ]]; then
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
    echo "[publish] download attempt $attempt/3 failed for '$pattern' (rc=$rc)"
    [[ $attempt -lt 3 ]] && sleep 5
  done
  return 1
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

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  if ! gh_download_retry "${REPO_DB_NAME}.db.tar.gz" "$MERGE_DIR"; then
    echo "::error::Production release exists but its database cannot be read; refusing to publish a partial repository."
    exit 1
  fi
  mkdir -p "$MERGE_DIR/db"
  if ! bsdtar -xf "$MERGE_DIR/${REPO_DB_NAME}.db.tar.gz" -C "$MERGE_DIR/db"; then
    echo "::error::Cannot extract production database; refusing to publish a partial repository."
    exit 1
  fi

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
else
  echo "Production release $TAG does not exist yet; nothing to merge."
fi

echo "== Generate fresh pacman database =="
rm -f status-*.txt protect-*.txt
repo-add "${REPO_DB_NAME}.db.tar.gz" "${merged_assets[@]}"

echo "== Validate repository consistency =="
if ! bash "$GITHUB_WORKSPACE/.github/scripts/validate-release.sh" "$PWD" "$REPO_DB_NAME" | tee "$GITHUB_STEP_SUMMARY"; then
  echo "::error::Validation failed; refusing to publish."
  rm -rf "$MERGE_DIR"
  exit 1
fi

echo "== Publish to production release (non-destructive) =="
pkg_assets=( *.pkg.tar.zst )
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

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG exists; merging this run into it."
else
  echo "Creating release $TAG."
  gh release create "$TAG" --repo "$REPO" \
    --title "Arch Package Repository" \
    --notes "Auto-built pacman repository."
fi
gh release upload "$TAG" "${pkg_assets[@]}" "${db_assets[@]}" "${meta_assets[@]}" \
  --repo "$REPO" --clobber

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
  done < <(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name')
fi
rm -rf "$MERGE_DIR"

if (( ${#stale_assets[@]} > 0 )); then
  echo "Deleting stale assets that are no longer part of the repository:"
  for stale in "${stale_assets[@]}"; do
    echo "  - $stale"
    if ! gh release delete-asset "$TAG" "$stale" --repo "$REPO" -y; then
      echo "::error::Cannot delete stale asset $stale; the next run will retry."
      exit 1
    fi
  done
else
  echo "No stale assets to delete."
fi

echo "Published production release: $REPO/releases/tag/$TAG"
