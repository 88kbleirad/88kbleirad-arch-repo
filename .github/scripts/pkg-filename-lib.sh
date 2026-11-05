#!/usr/bin/env bash
#
# Shared package-archive filename semantics for the 88kbleirad repository.
#
# pacman encodes the epoch inside an archive filename as `epoch:pkgver`:
#   <pkgname>-<epoch>:<pkgver>-<pkgrel>-<arch>.pkg.tar.zst
# (e.g. beautyline epoch=2 pkgver=3.0.5 ->
#  beautyline-2:3.0.5-1-any.pkg.tar.zst)
#
# GitHub Release assets do not permit `:` in names: gh sanitizes every
# character outside [a-z0-9-_+@] to `.` (gh sanitizeFileName) and refuses
# uploads that collide with an existing sanitized name. This repository
# therefore stores archives with the epoch `:` rendered as `.`
# (beautyline-2.3.0.5-1-any.pkg.tar.zst).
#
# Rules of use:
#   - `archive_basename` is the SINGLE source of truth for the canonical
#     stored (GitHub-safe) archive basename of a package. Every derived
#     filename in the pipeline (build validation, cache expected names,
#     database matching, publish manifests) MUST come from it, never from
#     hand-reconstructed strings.
#   - The transform only affects the *filename*: `.PKGINFO` still carries
#     the plain epoch-qualified version, and repo-add records the stored
#     (mangled) filename — so db->asset consistency holds by construction.
#
# This file is sourced by build-package.sh (inside the build container) and
# by the host test suite (test-epoch-filenames.sh). Keep it dependency-free
# (POSIX-ish bash, awk, sed only): it runs where jq/tar may not exist yet.

set -uo pipefail

# _archive_mangle_name <filename> -> epoch-safe filename
# Replaces every `:` (epoch marker) with `.` and collapses dot runs; this
# mirrors gh's sanitizeFileName so the stored name always equals the name
# the platform/gh will serve back.
_archive_mangle_name() {
  printf '%s\n' "$1" | sed -E 's/:+/./g; s/\.{2,}/./g'
}

# archive_basename <pkginfo-file> -> canonical stored archive basename
# Prints `<pkgname>-<epoch-safe-evr>-<arch>.pkg.tar.zst` for the package
# described by the .PKGINFO file, or returns 1 on incomplete metadata.
#
# Modern makepkg (pacman 7) writes the full EVR (with epoch and release)
# into `pkgver`; legacy makepkg writes separate pkgver/pkgrel/epoch lines.
# Both shapes are handled.
archive_basename() {
  local pkginfo="$1" pkgname pkgver pkgrel epoch arch evr
  pkgname=$(awk -F' = ' '/^pkgname/{print $2; exit}' "$pkginfo")
  pkgver=$(awk -F' = ' '/^pkgver/{print $2; exit}' "$pkginfo")
  pkgrel=$(awk -F' = ' '/^pkgrel/{print $2; exit}' "$pkginfo")
  epoch=$(awk -F' = ' '/^epoch/{print $2; exit}' "$pkginfo")
  arch=$(awk -F' = ' '/^arch/{print $2; exit}' "$pkginfo")
  [[ -n "$pkgname" && -n "$pkgver" && -n "$arch" ]] || return 1
  if [[ -n "$pkgrel" ]]; then
    evr="${pkgver}-${pkgrel}"
  else
    evr="$pkgver"
  fi
  # legacy .PKGINFO (separate epoch field) — modern pkgver already embeds
  # the epoch, so it never carries both.
  if [[ -n "$epoch" && "$epoch" != "0" ]]; then
    evr="${epoch}:${evr}"
  fi
  _archive_mangle_name "${pkgname}-${evr}-${arch}.pkg.tar.zst"
}
