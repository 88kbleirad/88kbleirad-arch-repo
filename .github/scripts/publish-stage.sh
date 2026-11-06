#!/usr/bin/env bash
#
# Runs inside the archlinux publish container: installs tools, validates the
# downloaded artifacts, generates the pacman database, and publishes to the
# staging release. Mirrors the logic previously inlined in build-staging.yml.

set -euo pipefail

RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
REPO_DB_NAME="${REPO_DB_NAME:?REPO_DB_NAME is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"

# Fail closed on any dry-run request: publish-stage.sh mutates via the
# legacy `gh release create/upload` subcommands, which have no dry-run
# mode. The staging workflow never passes DRY_RUN (only build-release.yml
# does, with the lib-based publish-prod.sh path); if a dry-run request
# ever reaches this script, abort BEFORE any remote mutation rather than
# silently publishing.
case "${DRY_RUN:-0}" in
  0|false|FALSE|no|NO|'') ;;
  *)
    echo "::error::publish-stage.sh does not support DRY_RUN=${DRY_RUN}; refusing to publish staging."
    exit 1
    ;;
esac

pacman -Syu --noconfirm --needed \
  github-cli pacman-contrib jq libarchive gnupg

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

# usage: gh_download_retry <pattern> <dir>
# Returns 0 when the file was downloaded and is non-empty. `gh release
# download` exits 0 even when the pattern matched nothing, so the file is
# verified explicitly. Returns 2 for a clean miss (no asset matching).
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

# -- non-destructive merge with the previously published staging release ---
#
# A staging matrix may cover only a subset of the repository. Without a
# merge, regenerating the database from this run's archives alone would
# silently drop every package not in the matrix. To keep previously valid
# staging packages available:
#   1. pull the current release database and list its entries
#   2. keep (and re-upload) every entry that this run did NOT supersede
#   3. fail loudly if the current release/database cannot be read, instead
#      of proceeding with a partial database
# An entry is superseded only when its base package was processed in this
# run with a non-failed status (built/skipped/restored) and a fresh
# archive for it is present below.
MERGE_DIR="$(mktemp -d)"
shopt -s nullglob
merged_assets=( *.pkg.tar.zst )
MERGED=0

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  if ! gh_download_retry "${REPO_DB_NAME}.db.tar.gz" "$MERGE_DIR"; then
    echo "::error::Current staging release exists but its database cannot be read; refusing to publish a partial repository."
    exit 1
  fi
  mkdir -p "$MERGE_DIR/db"
  if ! bsdtar -xf "$MERGE_DIR/${REPO_DB_NAME}.db.tar.gz" -C "$MERGE_DIR/db"; then
    echo "::error::Cannot extract current staging database; refusing to publish a partial repository."
    exit 1
  fi

  # bases processed this run, with their status
  declare -A PROCESSED_STATUS=()
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
        # Carry the previously published signature forward when it exists
        # and verifies against the current signing key.
        if gh_download_retry "$fname.sig" "$PWD"; then
          if ! verify_detached "$fname" "$fname.sig"; then
            echo "::error::Previously published signature for $fname failed verification; refusing to publish."
            rm -rf "$MERGE_DIR"
            exit 1
          fi
          echo "Kept previously published signature: $fname.sig"
        fi
        # also carry its architecture metadata forward (validation requires
        # a v4-<base>.meta.json for every package in the database). This
        # overwrites a local meta file from a failed build of the same
        # base: the restored archive belongs to the previous release, so
        # its metadata must describe that release, not the failed run.
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
else
  echo "Staging release $TAG does not exist yet; nothing to merge."
fi
rm -rf "$MERGE_DIR"

echo "== Sign package archives =="
if ! ensure_all_packages_signed; then
  echo "::error::Package signing/verification failed; refusing to publish."
  exit 1
fi

echo "== Generate fresh pacman database for staging =="
rm -f status-*.txt protect-*.txt
repo-add --include-sigs "${REPO_DB_NAME}.db.tar.gz" "${merged_assets[@]}"

echo "== Sign repository database =="
if ! sign_and_publish_db_signatures; then
  echo "::error::Database signing/verification failed; refusing to publish."
  exit 1
fi

echo "== Validate repository consistency =="
if ! bash "$GITHUB_WORKSPACE/.github/scripts/validate-release.sh" "$PWD" "$REPO_DB_NAME" | tee "$GITHUB_STEP_SUMMARY"; then
  echo "::error::Staging validation failed; refusing to publish."
  exit 1
fi

# -- expected package inventory enforcement (mirrors production) ------------
# Every package the staging matrix selected MUST be present as a validated
# archive in the fresh database. A silent miss (failed/restored/no-archive
# metadata) fails here BEFORE any Release mutation.
if [[ -n "${EXPECTED_PACKAGES:-}" ]]; then
  echo "== Verify expected staging inventory =="
  expected_names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && expected_names+=("$name")
  done < <(printf '%s\n' "$EXPECTED_PACKAGES" | jq -r '.[]')
  (( ${#expected_names[@]} > 0 )) || { echo "::error::Expected package list parsed empty; refusing to publish."; exit 1; }

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
      echo "::error::Expected package '${name}' is missing from the regenerated staging database (silent-miss check)."
      missing_count=$(( missing_count + 1 ))
    fi
  done
  if (( missing_count > 0 )); then
    echo "::error::Staging inventory check failed (${missing_count} missing). Refusing to publish; staging Release was not modified."
    exit 1
  fi
  echo "Inventory OK: all ${#expected_names[@]} requested staging packages are present and validated."
fi

echo "== Publish to staging release =="

pkg_assets=( *.pkg.tar.zst *.pkg.tar.zst.sig )
if (( ${#pkg_assets[@]} == 0 )); then
  echo "::error::No package files in output/; refusing to publish."
  exit 1
fi
db_assets=( "${REPO_DB_NAME}".db* "${REPO_DB_NAME}".files* )
if (( ${#db_assets[@]} == 0 )); then
  echo "::error::No pacman database files in output/; refusing to publish a repository without a database."
  exit 1
fi
meta_assets=( v4-*.meta.json )
if (( ${#meta_assets[@]} == 0 )); then
  echo "::error::No architecture metadata files; refusing to publish."
  exit 1
fi
if ! export_public_key; then
  echo "::error::Failed to export the public signing key; refusing to publish."
  exit 1
fi
pub_assets=( "${REPO_DB_NAME}.pub.asc" )

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Staging release $TAG exists; merging this run into it."
else
  echo "Creating staging release $TAG."
  gh release create "$TAG" --repo "$REPO" \
    --title "Staging repository (v4 test)" \
    --notes "Staging buildup: $(date -u '+%Y-%m-%d %H:%M UTC') — x86-64-v4"
fi
gh release upload "$TAG" "${pkg_assets[@]}" "${db_assets[@]}" "${meta_assets[@]}" "${pub_assets[@]}" \
  --repo "$REPO" --clobber
echo "Published staging release: $REPO/releases/tag/$TAG"

# -- mandatory remote post-publish verification ----------------------------
echo "== Remote post-publish verification (staging) =="
if ! bash "$GITHUB_WORKSPACE/.github/scripts/verify-remote-release.sh" \
    "$TAG" "$REPO" "${EXPECTED_PACKAGES:-}" \
    --manifest-dir "$PWD" \
    --signing-mode "signed" | tee -a "$GITHUB_STEP_SUMMARY"; then
  echo "::error::Staging remote verification failed; the Release may be incomplete. Refusing to report success."
  exit 1
fi
echo "== Staging remote verification passed =="
