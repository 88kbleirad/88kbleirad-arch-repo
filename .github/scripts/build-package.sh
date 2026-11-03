#!/usr/bin/env bash
#
# Build one package from the 88kbleirad repository.
#
# Environment:
#   PKG                  - repository directory / base package name (matrix entry)
#   RELEASE_TAG          - GitHub release tag holding the repository assets
#   REPO_DB_NAME         - pacman repository database name
#   GH_TOKEN             - GitHub token for gh CLI
#   GITHUB_REPOSITORY    - owner/repo (REQUIRED for gh calls)
#   GITHUB_WORKSPACE     - workspace root (optional, defaults to PWD)
#   BUILD_PROFILE        - architecture profile, default "x86-64-v4"
#
# The script implements architecture-aware caching: a package from the
# release is reused ONLY when ALL of the following hold:
#   1. the package filename exists in the previously published repository db
#   2. a profile metadata file (v4-<pkg>.meta.json) exists for it
#   3. the stored fingerprint matches the CURRENT PKGBUILD + compiler config
#   4. every expected sub-package file downloads and passes a tar sanity check
# This prevents reuse of x86-64-v3-era binaries even when versions match.

set -uo pipefail

PKG="${PKG:?PKG is required}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
REPO_DB_NAME="${REPO_DB_NAME:?REPO_DB_NAME is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
BUILD_PROFILE="${BUILD_PROFILE:-x86-64-v4}"

META_PREFIX="v4"
META_FILE="${META_PREFIX}-${PKG}.meta.json"
START_TS=$(date +%s)

mkdir -p "$WORKSPACE/output" /tmp/repo-files /tmp/repo-db

say()  { printf '[%s] %s\n' "$PKG" "$*"; }
warn() { printf '::warning::[%s] %s\n' "$PKG" "$*"; }
note() { printf '::notice::[%s] %s\n' "$PKG" "$*"; }

# -- helpers ---------------------------------------------------------------

gh_download_retry() {
  # usage: gh_download_retry <pattern> <dir>
  # Returns:
  #   0 - downloaded and verified (file exists, non-empty)
  #   1 - command failed
  #   2 - command succeeded but no/empty file was produced (pattern matched nothing)
  local pattern="$1" dir="$2" attempt rc
  for attempt in 1 2 3; do
    gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
        --dir "$dir" --pattern "$pattern" 2>/dev/null
    rc=$?
    if [[ $rc -eq 0 ]]; then
      # gh exits 0 even when the pattern matches nothing; verify the file.
      local f=""
      shopt -s nullglob
      for candidate in "$dir"/$(basename "$pattern"); do
        [[ -s "$candidate" ]] && f="$candidate"
      done
      shopt -u nullglob
      if [[ -n "$f" ]]; then
        return 0
      fi
      warn "download reported success for '$pattern' but no file was produced"
      return 2
    fi
    warn "download attempt $attempt/3 failed for '$pattern' (rc=$rc)"
    [[ $attempt -lt 3 ]] && sleep 5
  done
  return 1
}

tar_probe() {
  # usage: tar_probe <archive> ; exits 0 when readable
  local f="$1"
  tar --zstd -tf "$f" >/dev/null 2>&1 && return 0
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -tf "$f" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Extract .PKGINFO from a .pkg.tar.zst. Try GNU tar (zstd) first; fall
# back to bsdtar (which on some images lists members but cannot decompress
# zstd). Prints nothing on failure.
extract_pkginfo() {
  local f="$1"
  local tmp
  tmp=$(mktemp)
  if tar --zstd -xOf "$f" .PKGINFO > "$tmp" 2>/dev/null; then
    if [[ -s "$tmp" ]]; then
      cat "$tmp"
      rm -f "$tmp"
      return 0
    fi
  fi
  if command -v bsdtar >/dev/null 2>&1; then
    if bsdtar -xOf "$f" .PKGINFO > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      cat "$tmp"
      rm -f "$tmp"
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

# Fingerprint = current PKGBUILD + compiler configuration. Any change to
# either invalidates the cache for this package.
compute_fingerprint() {
  local pkgbuild="$WORKSPACE/$PKG/PKGBUILD"
  {
    cat "$pkgbuild"
    [[ -f /etc/makepkg.conf ]] && cat /etc/makepkg.conf
    for f in /etc/makepkg.conf.d/*.conf; do
      [[ -f "$f" ]] && cat "$f"
    done
  } | sha256sum | awk '{print $1}'
}

validate_pkg_file() {
  # usage: validate_pkg_file <path> ; exits 1 on invalid package
  local f="$1"
  [[ -s "$f" ]] || { warn "package file is empty: $f"; return 1; }
  tar_probe "$f" || { warn "package archive is corrupt/not readable: $f"; return 1; }
  # verify pkg metadata inside archive
  local tmp pkginfo pkgname pkgver pkgrel arch
  tmp=$(mktemp -d)
  if extract_pkginfo "$f" > "$tmp/PKGINFO"; then
    pkginfo="$tmp/PKGINFO"
  else
    pkginfo=""
  fi
  if [[ -z "$pkginfo" || ! -s "$pkginfo" ]]; then
    warn "package has no readable .PKGINFO: $f"
    rm -rf "$tmp"
    return 1
  fi
  pkgname=$(awk -F' = ' '/^pkgname/{print $2; exit}' "$pkginfo")
  pkgver=$(awk -F' = ' '/^pkgver/{print $2; exit}' "$pkginfo")
  pkgrel=$(awk -F' = ' '/^pkgrel/{print $2; exit}' "$pkginfo")
  arch=$(awk -F' = ' '/^arch/{print $2; exit}' "$pkginfo")
  rm -rf "$tmp"
  [[ -n "$pkgname" && -n "$pkgver" && -n "$arch" ]] || {
    warn "incomplete metadata in $f"; return 1; }
  # modern makepkg (pacman 7) emits pkgver with the release embedded
  # (e.g. "0.4-2"); legacy makepkg has separate pkgrel.
  local version_full
  if [[ -n "$pkgrel" ]]; then
    version_full="${pkgver}-${pkgrel}"
  else
    version_full="$pkgver"
  fi
  local expected="$pkgname-$version_full-$arch.pkg.tar.zst"
  if [[ "$(basename "$f")" != "$expected" ]]; then
    warn "filename mismatch: expected '$expected', got '$(basename "$f")'"
    return 1
  fi
  return 0
}

write_meta() {
  # usage: write_meta <status> <fingerprint> [extra_json]
  local status="$1" fp="$2" extra="${3:-}"
  {
    printf '{\n'
    printf '  "package": %s,\n' "$(printf '%s' "$PKG" | jq -R .)"
    printf '  "profile": %s,\n' "$(printf '%s' "$BUILD_PROFILE" | jq -R .)"
    printf '  "status": %s,\n' "$(printf '%s' "$status" | jq -R .)"
    printf '  "fingerprint": %s,\n' "$(printf '%s' "$fp" | jq -R .)"
    printf '  "built_at": %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ | jq -R .)"
    [[ -n "$extra" ]] && printf ',%s\n' "$extra"
    printf '}\n'
  } > "$WORKSPACE/output/$META_FILE"
}

# -- fetch previous repository metadata -----------------------------------

say "Fetching repository database metadata"
if gh_download_retry "${REPO_DB_NAME}.files.tar.gz" /tmp/repo-db; then
  if ! tar -xzf "/tmp/repo-db/${REPO_DB_NAME}.files.tar.gz" -C /tmp/repo-files; then
    warn "cannot extract ${REPO_DB_NAME}.files.tar.gz; every package will be rebuilt"
  fi
else
  # rc=2 means the release has no such asset yet: expected on the very first
  # run against a new tag; rc=1 means the command itself failed.
  say "no ${REPO_DB_NAME}.files.tar.gz in release '$RELEASE_TAG' (expected on first run); every package will be rebuilt"
fi

PREV_META=""
if gh_download_retry "$META_FILE" /tmp/repo-db; then
  [[ -f "/tmp/repo-db/$META_FILE" ]] && PREV_META="/tmp/repo-db/$META_FILE"
fi

# -- prepare ------------------------------------------------------------------

VCS_PREPASS_OK=true
if grep -q 'pkgver()' "$WORKSPACE/$PKG/PKGBUILD"; then
  if ! sudo -u builder bash -lc "cd '$WORKSPACE/$PKG' && makepkg -od --noprepare --skipinteg"; then
    warn "pkgver() pre-pass failed for $PKG; forcing rebuild (cached version cannot be trusted)"
    VCS_PREPASS_OK=false
  fi
fi

EXPECTED_PKGS=""
if ! EXPECTED_PKGS=$(sudo -u builder bash -lc "cd '$WORKSPACE/$PKG' && makepkg --packagelist"); then
  warn "makepkg --packagelist failed for $PKG; forcing rebuild"
  EXPECTED_PKGS=""
else
  EXPECTED_PKGS="${EXPECTED_PKGS//:/.}"
fi

FINGERPRINT=$(compute_fingerprint)
NEEDS_BUILD=false
if [[ "$VCS_PREPASS_OK" != "true" || -z "$EXPECTED_PKGS" || -z "$PREV_META" ]]; then
  NEEDS_BUILD=true
else
  # architecture-aware gate: profile must be the current one
  prev_profile=$(jq -r '.profile // empty' "$PREV_META" 2>/dev/null)
  prev_fp=$(jq -r '.fingerprint // empty' "$PREV_META" 2>/dev/null)
  prev_status=$(jq -r '.status // empty' "$PREV_META" 2>/dev/null)
  if [[ "$prev_status" != "built" && "$prev_status" != "skipped" ]]; then
    note "previous build status '$prev_status' is not reusable; forcing rebuild"
    NEEDS_BUILD=true
  elif [[ "$prev_profile" != "$BUILD_PROFILE" ]]; then
    note "previous build profile '$prev_profile' != '$BUILD_PROFILE'; forcing rebuild"
    NEEDS_BUILD=true
  elif [[ "$prev_fp" != "$FINGERPRINT" ]]; then
    note "PKGBUILD/compiler fingerprint changed; forcing rebuild"
    NEEDS_BUILD=true
  else
    for pkg_path in $EXPECTED_PKGS; do
      pkg_basename=$(basename "$pkg_path")
      if ! grep -q -x "$pkg_basename" /tmp/repo-files/*/desc 2>/dev/null; then
        NEEDS_BUILD=true
        break
      fi
    done
  fi
fi

# -- reuse from release (cache hit) --------------------------------------------

if [[ "$NEEDS_BUILD" == "false" ]]; then
  say "package is up to date (profile=$BUILD_PROFILE); fetching cached binaries"
  CACHE_OK=true
  for pkg_path in $EXPECTED_PKGS; do
    pkg_basename=$(basename "$pkg_path")
    gh_download_retry "$pkg_basename" "$WORKSPACE/output"
    download_rc=$?
    if [[ $download_rc -ne 0 ]]; then
      if [[ $download_rc -eq 2 ]]; then
        warn "cached binary $pkg_basename not in release (expected after an update); forcing rebuild"
      else
        warn "failed to fetch $pkg_basename (rc=$download_rc); forcing rebuild"
      fi
      CACHE_OK=false
      break
    fi
    if ! validate_pkg_file "$WORKSPACE/output/$pkg_basename"; then
      warn "cached binary failed validation: $pkg_basename; forcing rebuild"
      CACHE_OK=false
      break
    fi
  done
  if [[ "$CACHE_OK" == "true" ]]; then
    echo "$PKG" > "$WORKSPACE/output/status-skipped-$PKG.txt"
    write_meta skipped "$FINGERPRINT"
    say "cache hit: $PKG"
  else
    NEEDS_BUILD=true
  fi
fi

# -- build ---------------------------------------------------------------------

if [[ "$NEEDS_BUILD" == "true" ]]; then
  say "updating checksums for $PKG"
  if sudo -u builder bash -lc "cd '$WORKSPACE/$PKG' && updpkgsums"; then
    # updpkgsums may rewrite the PKGBUILD; re-fingerprint afterwards so the
    # stored fingerprint matches the PKGBUILD state that will be committed.
    # Otherwise every later run would miss the cache once.
    FINGERPRINT=$(compute_fingerprint)
  else
    warn "updpkgsums failed for $PKG; proceeding with existing checksums"
  fi

  say "building $PKG"
  ASSUME_PKGS=$(sudo -u builder bash -lc "cd '$WORKSPACE/$PKG' && source PKGBUILD && echo \${pkgname[@]}")
  ASSUME_ARGS=""
  for subpkg in $ASSUME_PKGS; do
    ASSUME_ARGS="$ASSUME_ARGS --assume-installed $subpkg"
  done

  # Build driver selection. paru is the AUR helper used in the CachyOS
  # environment; the generic Arch build environment has no paru (it lives
  # in the AUR / CachyOS repos, whose binaries are v4-tuned and unsafe to
  # execute on non-AVX-512 hosts). When paru is absent, fall back to
  # makepkg directly -- all staging dependencies resolve from the official
  # Arch repositories, so no AUR helper is required.
  PARU_RC=0
  if command -v paru >/dev/null 2>&1; then
    BUILDER_NAME="paru"
    PARU_FLAGS="--noconfirm --skipreview --useask --removemake --nocheck -B$ASSUME_ARGS"
    sudo -u builder bash -lc "cd '$WORKSPACE/$PKG' && paru $PARU_FLAGS '$WORKSPACE/$PKG'" || PARU_RC=$?
  else
    BUILDER_NAME="makepkg"
    warn "paru not found; using makepkg (dependencies must resolve from official repos)"
    sudo -u builder bash -lc "cd '$WORKSPACE/$PKG' && makepkg --noconfirm --nocheck --syncdeps --needed" || PARU_RC=$?
  fi

  # distinct diagnostics for the most common failure modes
  case "$PARU_RC" in
    0) ;;
    137)
      warn "${BUILDER_NAME} was killed with exit code 137 (OOM / out of memory). Build environment may need more memory."
      ;;
    1)
      warn "${BUILDER_NAME} exited with code 1 (build error) for $PKG; checking whether package files were produced anyway."
      ;;
    128)
      warn "${BUILDER_NAME} exited with code 128 (fatal) for $PKG; checking whether package files were produced anyway."
      ;;
    *)
      warn "${BUILDER_NAME} exited with code $PARU_RC for $PKG; checking whether package files were produced anyway."
      ;;
  esac

  BUILT_FILES=()
  shopt -s nullglob
  for f in "$WORKSPACE/$PKG"/*.pkg.tar.zst; do
    if validate_pkg_file "$f"; then
      mv "$f" "$WORKSPACE/output/"
      BUILT_FILES+=("$(basename "$f")")
    else
      warn "produced package failed validation and will not be published: $(basename "$f")"
    fi
  done
  shopt -u nullglob

  if (( ${#BUILT_FILES[@]} > 0 )); then
    echo "Build OK: $PKG (${BUILT_FILES[*]})"
    echo "$PKG" > "$WORKSPACE/output/status-built-$PKG.txt"
    write_meta built "$FINGERPRINT"
  else
    echo "Build failed for $PKG (${BUILDER_NAME} rc=$PARU_RC)"
    echo "Triggering fallback mechanism for $PKG..."
    FALLBACK_CANDIDATES=()
    PROTECT_NAMES=()
    RESTORED_COUNT=0
    declare -A candidate_seen=()
    add_candidate() {
      [[ -n "$1" ]] || return 0
      [[ -n "${candidate_seen[$1]:-}" ]] && return 0
      candidate_seen["$1"]=1
      FALLBACK_CANDIDATES+=("$1")
    }

    if [[ -d /tmp/repo-files ]]; then
      for desc_file in /tmp/repo-files/*/desc; do
        [[ -f "$desc_file" ]] || continue
        base_pkg=$(awk '/^%BASE%/{getline; print; exit}' "$desc_file")
        pkg_name=$(awk '/^%NAME%/{getline; print; exit}' "$desc_file")
        check_name="${base_pkg:-$pkg_name}"
        [[ "$check_name" == "$PKG" ]] || continue
        add_candidate "$(awk '/^%FILENAME%/{getline; print; exit}' "$desc_file")"
      done
    fi

    RELEASE_ASSETS=""
    if RELEASE_ASSETS=$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json assets -q '.assets[].name'); then
      for pkg_name in $ASSUME_PKGS; do
        while IFS= read -r asset; do
          [[ "$asset" == "$pkg_name"-*.pkg.tar.zst ]] && add_candidate "$asset"
        done <<< "$RELEASE_ASSETS"
      done
    else
      warn "cannot list release assets while restoring $PKG; assets will be protected from deletion in this run"
      printf '*\n' > "$WORKSPACE/output/protect-all.txt"
    fi
    if [[ -z "$ASSUME_PKGS" ]]; then
      warn "cannot determine the package names of $PKG; assets will be protected from deletion in this run"
      printf '*\n' > "$WORKSPACE/output/protect-all.txt"
    fi

    for file_name in "${FALLBACK_CANDIDATES[@]}"; do
      echo "Restoring $file_name from previous release"
      gh_download_retry "$file_name" "$WORKSPACE/output"
      restore_rc=$?
      if [[ $restore_rc -eq 0 ]]; then
        RESTORED_COUNT=$(( RESTORED_COUNT + 1 ))
      elif [[ $restore_rc -eq 2 ]]; then
        warn "restore candidate $file_name is no longer in the release; skipping"
      else
        warn "could not restore $file_name for $PKG; it will be kept in the release"
        PROTECT_NAMES+=("$file_name")
      fi
    done

    if (( ${#PROTECT_NAMES[@]} > 0 )); then
      printf '%s\n' "${PROTECT_NAMES[@]}" > "$WORKSPACE/output/protect-$PKG.txt"
    fi
    if (( RESTORED_COUNT > 0 )); then
      echo "Restored $RESTORED_COUNT file(s) of $PKG from the previous release"
      echo "$PKG" > "$WORKSPACE/output/status-restored-$PKG.txt"
      write_meta restored "$FINGERPRINT" '"restored_legacy": true'
    else
      echo "Fallback failed for $PKG: no previous files found. Gracefully exiting to ignore package."
      echo "$PKG" > "$WORKSPACE/output/status-failed-$PKG.txt"
      write_meta failed "$FINGERPRINT"
    fi
    exit 0
  fi
fi

# -- cleanup --------------------------------------------------------------------

for f in "$WORKSPACE/output/"*:* ; do
  if [[ -f "$f" ]]; then
    new_f="${f//:/.}"
    echo "Renaming $f to $new_f"
    mv "$f" "$new_f"
  fi
done

sudo -u builder rm -rf "$WORKSPACE/$PKG/src" "$WORKSPACE/$PKG/pkg"

DURATION=$(( $(date +%s) - START_TS ))
{
  echo "## Build report: $PKG"
  echo ""
  echo "- Status: $([[ "$NEEDS_BUILD" == "false" ]] && echo skipped || echo built)"
  echo "- Profile: $BUILD_PROFILE"
  echo "- Duration: ${DURATION}s"
  echo "- Expected packages: $(echo $EXPECTED_PKGS | tr '\n' ' ')"
} >> "$GITHUB_STEP_SUMMARY"

say "finished in ${DURATION}s"
