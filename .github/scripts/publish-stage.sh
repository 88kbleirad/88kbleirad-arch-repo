#!/usr/bin/env bash
#
# Runs inside the archlinux publish container: installs tools, validates the
# downloaded artifacts, generates the pacman database, and publishes to the
# staging release. Mirrors the logic previously inlined in build-staging.yml.

set -euo pipefail

RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
REPO_DB_NAME="${REPO_DB_NAME:?REPO_DB_NAME is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"

pacman -Syu --noconfirm --needed \
  github-cli pacman-contrib jq libarchive

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

echo "== Generate fresh pacman database for staging =="
rm -f status-*.txt protect-*.txt
repo-add "${REPO_DB_NAME}.db.tar.gz" "${pkgs[@]}"

echo "== Validate repository consistency =="
bash "$GITHUB_WORKSPACE/.github/scripts/validate-release.sh" "$PWD" "$REPO_DB_NAME" | tee "$GITHUB_STEP_SUMMARY"

echo "== Publish to staging release =="
REPO="$GITHUB_REPOSITORY"
TAG="$RELEASE_TAG"

pkg_assets=( *.pkg.tar.zst )
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

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Staging release $TAG exists; replacing it."
  gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag
fi
echo "Creating staging release $TAG."
gh release create "$TAG" --repo "$REPO" \
  --title "Staging repository (v4 test)" \
  --notes "Staging buildup: $(date -u '+%Y-%m-%d %H:%M UTC') — x86-64-v4"
gh release upload "$TAG" "${pkg_assets[@]}" "${db_assets[@]}" "${meta_assets[@]}" \
  --repo "$REPO" --clobber
echo "Published staging release: $REPO/releases/tag/$TAG"
