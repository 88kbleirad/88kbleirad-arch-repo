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

# Verify every build dependency resolves to an official repository package
# or to a package built within this repository. AUR-only dependencies
# would otherwise make `makepkg` fail in opaque ways (or be silently
# bypassed); fail loudly instead with a precise list.
check_dependencies_resolvable() {
  local srcinfo deps
  srcinfo=$(sudo -u builder bash -lc \
    "cd '$WORKSPACE/$PKG' && makepkg --printsrcinfo" 2>/dev/null) || {
      warn "makepkg --printsrcinfo failed; cannot verify dependencies (will attempt build)"
      return 0
    }
  deps=$(printf '%s\n' "$srcinfo" | awk -F' = ' '
    /^\s*(depends|makedepends|checkdepends) = / { print $2 }' | sed -E 's/[<>=].*$//' | sort -u)

  local -A unresolved=()
  local dep
  for dep in $deps; do
    [[ -n "$dep" ]] || continue
    if [[ -d "$WORKSPACE/$dep" && -f "$WORKSPACE/$dep/PKGBUILD" ]]; then
      # dependency built within this repository
      :
    elif pacman -S --print-format '%n' --noconfirm --needed "$dep" \
        >/dev/null 2>&1; then
      # resolvable from official repos, including virtual providers
      # (e.g. 'cargo' is provided by 'rust', 'libgcc_s.so' by
      # 'gcc-libs'): pacman resolves providers here, so a package
      # name missing from -Si is still installable.
      :
    else
      unresolved["$dep"]=1
    fi
  done

  if (( ${#unresolved[@]} > 0 )); then
    local names
    names=$(printf '%s\n' "${!unresolved[@]}" | sort)
    echo "::error::[$PKG] build dependencies not resolvable from official repos or this repository (AUR-only?):"
    printf '::error::  %s\n' $names
    echo "::error::[$PKG] refusing to build with unresolved dependencies; add them to packages.txt or use official packages."
    return 1
  fi
  return 0
}

# Fingerprint = current PKGBUILD + compiler configuration. Any change to
# either invalidates the cache for this package.
#
# The fingerprint hashes the *effective* PKGBUILD state, not the raw
# committed bytes. `makepkg`/`updpkgsums` normalize checksum lines when
# resolving sources (e.g. a committed `sha512sums=('SKIP')` on a tarball
# source becomes the real sha512). Hashing the raw committed file would
# produce a fingerprint that differs from the state recorded after a
# build, so the same package would be treated as changed on every run.
# To make the fingerprint stable across runs, we apply the same
# normalization in a scratch copy (the checkout itself is never mutated).
# If the normalization cannot run (e.g. source fetch fails), the committed
# file is used — still deterministic, but the build path re-runs
# updpkgsums, so the stored fingerprint matches the normalized state.
compute_fingerprint() {
  local pkgbuild="$WORKSPACE/$PKG/PKGBUILD"
  local fp_src="$pkgbuild"
  # Only checksum normalization can change the PKGBUILD state:
  # `updpkgsums` replaces a committed `SKIP` on a source whose checksum
  # it can compute — a plain tarball or a VCS source pinned to a specific
  # revision (`git+...#commit=…`/`#tag=…`). A branch/HEAD `git+` source
  # keeps `SKIP` (no fixed revision to hash). Normalizing only for the
  # former avoids re-downloading sources for the already-pinned case.
  # The normalization runs in a scratch copy; the checkout is never
  # mutated. If it fails (e.g. source fetch blocked), the committed file
  # is used — still deterministic, and the stored fingerprint then
  # matches the committed state (the build proceeds with those checksums).
  if [[ -f "$pkgbuild" ]] \
      && grep -qE 'SKIP' "$pkgbuild" \
      && awk '/^source=\(/{in_src=1} in_src && /git\+/ && !/#(commit|tag)=/{plain_vcs=1} /^\)/{if (in_src) exit} END{exit (plain_vcs==1)}' "$pkgbuild" \
      && [[ -d "$WORKSPACE/$PKG" ]]; then
    local scratch
    scratch="$(mktemp -d "$WORKSPACE/.fp.XXXXXX")" || true
    if [[ -n "${scratch:-}" ]]; then
      if cp -r "$WORKSPACE/$PKG"/. "$scratch/" 2>/dev/null \
          && rm -rf "$scratch/src" "$scratch/pkg" 2>/dev/null \
          && chown -R builder:builder "$scratch" 2>/dev/null \
          && sudo -u builder bash -lc "cd '$scratch' && updpkgsums" >/dev/null 2>&1 \
          && [[ -s "$scratch/PKGBUILD" ]]; then
        # Preserve the normalized PKGBUILD to a byte-exact file BEFORE the
        # scratch dir is removed: pointing fp_src into the scratch dir
        # would break the hash below (the dir is gone by then), silently
        # producing a config-only fingerprint identical for ALL packages.
        local norm_src
        norm_src="$(mktemp "$WORKSPACE/.fp.norm.XXXXXX")" || norm_src=""
        if [[ -n "$norm_src" ]] && cp "$scratch/PKGBUILD" "$norm_src" 2>/dev/null; then
          fp_src="$norm_src"
        elif [[ -n "$norm_src" ]]; then
          rm -f "$norm_src" 2>/dev/null || true
        fi
      fi
      rm -rf "$scratch" 2>/dev/null || true
    fi
  fi
  local fp_raw fp_eff
  fp_raw="$({ cat "$pkgbuild"; [[ -f /etc/makepkg.conf ]] && cat /etc/makepkg.conf; for f in /etc/makepkg.conf.d/*.conf; do [[ -f "$f" ]] && cat "$f"; done; } | sha256sum | awk '{print $1}')"
  fp_eff="$({ cat "$fp_src"; [[ -f /etc/makepkg.conf ]] && cat /etc/makepkg.conf; for f in /etc/makepkg.conf.d/*.conf; do [[ -f "$f" ]] && cat "$f"; done; } | sha256sum | awk '{print $1}')"
  # cleanup the temporary normalized copy (never the committed pkgbuild)
  if [[ "$fp_src" != "$pkgbuild" ]]; then
    rm -f "$fp_src" 2>/dev/null || true
  fi
  # line 1 = effective (normalized) fingerprint; line 2 = raw committed
  # fingerprint. Callers parse both; when they differ, updpkgsums had
  # changed the PKGBUILD form (checksum normalization) and the effective
  # fingerprint is the one that must be stored/compared.
  printf '%s\n%s\n' "$fp_eff" "$fp_raw"
}

# Package archive filename semantics (epoch-aware, GitHub-asset-safe).
# Single source of truth for canonical archive basenames.
. "$(dirname "${BASH_SOURCE[0]}")/pkg-filename-lib.sh"

validate_pkg_file() {
  # usage: validate_pkg_file <path> ; exits 1 on invalid package
  local f="$1"
  [[ -s "$f" ]] || { warn "package file is empty: $f"; return 1; }
  tar_probe "$f" || { warn "package archive is corrupt/not readable: $f"; return 1; }
  # verify pkg metadata inside archive
  local tmp pkginfo expected
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
  if ! expected=$(archive_basename "$pkginfo"); then
    warn "incomplete metadata in $f"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  if [[ "$(basename "$f")" != "$expected" ]]; then
    warn "filename mismatch: expected '$expected', got '$(basename "$f")'"
    return 1
  fi
  return 0
}

write_meta() {
  # usage: write_meta <status> <fingerprint> [extra_json] [built_at_override]
  # built_at_override makes serialization deterministic (e.g. reuse of the
  # previously published timestamp on a cache hit); when empty a fresh UTC
  # timestamp is used.
  #
  # The schema is deliberately minimal and STABLE: only package/profile/
  # status/fingerprint/built_at. It is NOT expanded with new provenance
  # fields because that would rewrite every published v4-*.meta.json on the
  # next run (a spurious 20-asset mutation), violating the zero-mutation
  # goal and "a valid unchanged metadata file must never be replaced". The
  # fingerprint already encodes source/cfg identity; the built archive is
  # verified by checksum at publish time.
  local status="$1" fp="$2" extra="${3:-}" bat="${4:-}"
  [[ -n "$bat" ]] || bat="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '{\n'
    printf '  "package": %s,\n' "$(printf '%s' "$PKG" | jq -R .)"
    printf '  "profile": %s,\n' "$(printf '%s' "$BUILD_PROFILE" | jq -R .)"
    printf '  "status": %s,\n' "$(printf '%s' "$status" | jq -R .)"
    printf '  "fingerprint": %s,\n' "$(printf '%s' "$fp" | jq -R .)"
    printf '  "built_at": %s\n' "$(printf '%s' "$bat" | jq -R .)"
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
fi

FINGERPRINT=""
FINGERPRINT_RAW=""
# compute_fingerprint prints: <effective> <raw> (one per line)
{
  IFS= read -r FINGERPRINT
  IFS= read -r FINGERPRINT_RAW
} < <(compute_fingerprint)
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
    if [[ -n "${FINGERPRINT_RAW:-}" && "$FINGERPRINT_RAW" != "$FINGERPRINT" ]]; then
      note "effective PKGBUILD differs from committed (checksum normalization applied): raw=$FINGERPRINT_RAW effective=$FINGERPRINT"
    elif [[ -n "${FINGERPRINT_RAW:-}" && "$FINGERPRINT_RAW" == "$prev_fp" ]]; then
      note "committed PKGBUILD is unchanged; the stored fingerprint came from a differently-normalized state (legacy entry) — rebuild aligns it, subsequent runs cache-hit"
    fi
    NEEDS_BUILD=true
  else
    for pkg_path in $EXPECTED_PKGS; do
      pkg_basename=$(_archive_mangle_name "$(basename "$pkg_path")")
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
    pkg_basename=$(_archive_mangle_name "$(basename "$pkg_path")")
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
    # Deterministic metadata on a cache hit: the content is byte-identical
    # to the previously published meta (same profile/status/fingerprint),
    # so reuse the previous built_at instead of stamping a fresh timestamp.
    # This keeps serialization deterministic and makes repeated identical
    # runs produce no asset mutations. built_at is informational and has no
    # functional consumers.
    prev_built_at=""
    if [[ -n "$PREV_META" && -f "$PREV_META" ]]; then
      prev_status=$(jq -r '.status // empty' "$PREV_META" 2>/dev/null)
      prev_fp=$(jq -r '.fingerprint // empty' "$PREV_META" 2>/dev/null)
      if [[ "$prev_status" == "skipped" && "$prev_fp" == "$FINGERPRINT" ]]; then
        prev_built_at=$(jq -r '.built_at // empty' "$PREV_META" 2>/dev/null)
      fi
    fi
    if [[ -n "$prev_built_at" ]]; then
      write_meta skipped "$FINGERPRINT" "" "$prev_built_at"
    else
      write_meta skipped "$FINGERPRINT"
    fi
    say "cache hit: $PKG"
  else
    NEEDS_BUILD=true
  fi
fi

# -- build ---------------------------------------------------------------------

if [[ "$NEEDS_BUILD" == "true" ]]; then
  # The fingerprint normalization (compute_fingerprint) already applied
  # updpkgsums in a scratch copy and produced the effective PKGBUILD
  # state, so the stored meta fingerprint equals the canonical state for
  # repeated runs. The real checkout is left untouched; makepkg skips
  # checksum verification for committed SKIP sources (as it always has)
  # and validates real checksums against the committed file.
  say "building $PKG"
  ASSUME_PKGS=$(sudo -u builder bash -lc "cd '$WORKSPACE/$PKG' && source PKGBUILD && echo \${pkgname[@]}")
  ASSUME_ARGS=""
  for subpkg in $ASSUME_PKGS; do
    ASSUME_ARGS="$ASSUME_ARGS --assume-installed $subpkg"
  done

  # Loud dependency gate: refuse to attempt a build when any build
  # dependency cannot resolve from official repositories or from this
  # repository (AUR-only dependencies would fail inside makepkg, or get
  # bypassed by the makepkg fallback in older setups). Falling back to the
  # restore/protect path keeps the last published binaries available until
  # the dependency is resolved.
  DEP_GATE_OK=true
  PARU_RC=1
  BUILDER_NAME="dependency-gate (unresolved build dependencies)"
  if ! check_dependencies_resolvable; then
    DEP_GATE_OK=false
  fi

  if [[ "$DEP_GATE_OK" == "true" ]]; then
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
  fi

  BUILT_FILES=()
  shopt -s nullglob
  for f in "$WORKSPACE/$PKG"/*.pkg.tar.zst; do
    # Canonicalize the archive filename BEFORE validation: makepkg names
    # epoch packages with a literal `:` (beautyline-2:3.0.5-1-any...),
    # which GitHub Release assets cannot store. archive_basename derives
    # the stored (epoch-safe) name from .PKGINFO; without the rename the
    # pipeline-wide basename equality would break for epoch packages.
    canon_info=$(mktemp)
    canon_basename=""
    if extract_pkginfo "$f" > "$canon_info" 2>/dev/null; then
      canon_basename=$(archive_basename "$canon_info" 2>/dev/null || true)
    fi
    rm -f "$canon_info"
    if [[ -z "$canon_basename" ]]; then
      warn "produced package has unreadable metadata; will not be published: $(basename "$f")"
      continue
    fi
    if [[ "$(basename "$f")" != "$canon_basename" ]]; then
      say "canonicalizing archive name: $(basename "$f") -> $canon_basename (epoch-safe)"
      mv "$f" "$WORKSPACE/$PKG/$canon_basename"
      f="$WORKSPACE/$PKG/$canon_basename"
    fi
    if validate_pkg_file "$f"; then
      # Packager metadata gate: every freshly built archive must carry the
      # repository identity in .PKGINFO (PACKAGER configured in
      # build-in-docker.sh). A missing/unknown packager means the build
      # environment did not apply the profile — refuse to publish it.
      if ! extract_pkginfo "$f" | grep -Eq '^packager = 88kbleirad <'; then
        warn "produced package has no 88kbleirad packager metadata; will not be published: $(basename "$f")"
      else
        mv "$f" "$WORKSPACE/output/"
        BUILT_FILES+=("$(basename "$f")")
      fi
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
        # A restored archive must be a real, valid package archive (not a
        # metadata-only or corrupt artifact) before it counts as recovery.
        if validate_pkg_file "$WORKSPACE/output/$file_name"; then
          RESTORED_COUNT=$(( RESTORED_COUNT + 1 ))
        else
          warn "restore candidate $file_name failed validation; discarding"
          rm -f "$WORKSPACE/output/$file_name"
        fi
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
      exit 0
    else
      # FAIL CLOSED: a requested package whose build failed and for which
      # NO valid previously-published archive could be recovered MUST fail
      # the build job. "Gracefully ignoring" an explicitly requested
      # package is never allowed (it produces metadata-only uploads and
      # false-green staging runs). status-failed + meta are still written
      # so the publisher can protect last-known-good assets if it runs.
      echo "::error::[$PKG] build failed (${BUILDER_NAME} rc=$PARU_RC) and no valid previously published archive could be restored; failing the build job."
      echo "Fallback failed for $PKG: no valid previous files recovered."
      echo "$PKG" > "$WORKSPACE/output/status-failed-$PKG.txt"
      write_meta failed "$FINGERPRINT"
      exit 1
    fi
  fi
fi

# -- cleanup --------------------------------------------------------------------

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
