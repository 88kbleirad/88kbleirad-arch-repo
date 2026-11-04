#!/usr/bin/env bash
#
# Validate a pacman repository directory before/after publishing:
#   - every package archive is a readable tar.zst with .PKGINFO
#   - every expected package from <db>.db.tar.gz has one archive on disk
#   - every archive on disk is present in <db>.db.tar.gz (no drift)
#   - per-package v4-<pkg>.meta.json metadata exists
#   - repository database name matches the expected identity
#   - every archive and both database files carry a valid detached .sig
#     signature (when signature validation is enabled — the publish
#     pipeline always enables it via REQUIRE_SIGNATURES=1)
#
# Usage: validate-release.sh <dir> <repo-db-name>
# Exit 1 on any consistency failure.
#
# Signature validation is controlled by REQUIRE_SIGNATURES:
#   - "1" (publish flow): every package + database signature must exist
#     and verify with the current GNUPGHOME keyring.
#   - "0": signature checks are skipped (legacy standalone runs).
#   - unset: auto — verify when $GNUPGHOME is set (gpg available).
# The publishing scripts source sign-helpers.sh, which exports GNUPGHOME
# and imports the signing key, so signature verification there always
# runs against the repository's own key.

set -euo pipefail

DIR="${1:?usage: validate-release.sh <dir> <repo-db-name>}"
DB="${2:?usage: validate-release.sh <dir> <repo-db-name>}"

FAIL=0
fail() { echo "::error::$*"; FAIL=1; }
ok()  { echo "OK: $*"; }

REQUIRE_SIGNATURES="${REQUIRE_SIGNATURES:-auto}"
if [[ "$REQUIRE_SIGNATURES" == "auto" ]]; then
  if [[ -n "${GNUPGHOME:-}" && -d "$GNUPGHOME" ]]; then
    REQUIRE_SIGNATURES=1
  else
    REQUIRE_SIGNATURES=0
  fi
fi

# helper: extract .PKGINFO (GNU tar zstd first, bsdtar fallback).
# MUST be defined before use: bash executes top-down.
extract_pkginfo() {
  local f="$1" tmp
  tmp=$(mktemp)
  if tar --zstd -xOf "$f" .PKGINFO > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    cat "$tmp"; rm -f "$tmp"; return 0
  fi
  if bsdtar -xOf "$f" .PKGINFO > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    cat "$tmp"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

[[ -d "$DIR" ]] || { echo "::error::directory not found: $DIR"; exit 2; }
cd "$DIR"

shopt -s nullglob
PKG_ASSETS=( *.pkg.tar.zst )

if (( ${#PKG_ASSETS[@]} == 0 )); then
  echo "::error::no package archives in $DIR"
  exit 2
fi

# 1. validate every archive (+ detached signature when required)
for f in "${PKG_ASSETS[@]}"; do
  if ! tar --zstd -tf "$f" >/dev/null 2>&1 && ! bsdtar -tf "$f" >/dev/null 2>&1; then
    fail "corrupt archive: $f"
    continue
  fi
  if ! extract_pkginfo "$f" | grep -q '^pkgname = '; then
    fail "missing .PKGINFO: $f"
  else
    ok "archive valid: $f"
  fi
  if [[ "$REQUIRE_SIGNATURES" == "1" ]]; then
    if [[ ! -s "$f.sig" ]]; then
      fail "missing package signature: $f.sig"
    elif ! gpg --verify "$f.sig" "$f" >/dev/null 2>&1; then
      fail "package signature verification failed: $f.sig"
    else
      ok "signature valid: $f.sig"
    fi
  fi
done

# 2. repository database identity (+ detached signatures when required)
[[ -f "$DB.db.tar.gz" ]] || { echo "::error::$DB.db.tar.gz not found in $DIR"; exit 2; }
[[ -f "$DB.files.tar.gz" ]] || { echo "::error::$DB.files.tar.gz not found in $DIR"; exit 2; }
ok "database files present: $DB.db.tar.gz + $DB.files.tar.gz"
if [[ "$REQUIRE_SIGNATURES" == "1" ]]; then
  for db in "$DB.db.tar.gz" "$DB.files.tar.gz"; do
    if [[ ! -s "$db.sig" ]]; then
      fail "missing database signature: $db.sig"
    elif ! gpg --verify "$db.sig" "$db" >/dev/null 2>&1; then
      fail "database signature verification failed: $db.sig"
    else
      ok "database signature valid: $db.sig"
    fi
  done
fi

# 3. decode db -> expected package filenames
rm -rf .validate-db
mkdir -p .validate-db
bsdtar -xf "$DB.db.tar.gz" -C .validate-db

DB_ASSETS=()
for desc in .validate-db/*/desc; do
  fname=$(awk '/^%FILENAME%/{getline; print}' "$desc")
  [[ -n "$fname" ]] || { fail "desc entry missing %FILENAME%: $desc"; continue; }
  DB_ASSETS+=("$fname")
done

# 4. db -> disk consistency
for f in "${DB_ASSETS[@]}"; do
  [[ -f "$f" ]] || fail "db references missing archive: $f"
done
for f in "${PKG_ASSETS[@]}"; do
  found=0
  for d in "${DB_ASSETS[@]}"; do
    [[ "$d" == "$f" ]] && { found=1; break; }
  done
  [[ $found -eq 1 ]] || fail "archive not present in db: $f"
done
(( ${#DB_ASSETS[@]} == ${#PKG_ASSETS[@]} )) || fail "db asset count ${#DB_ASSETS[@]} != archive count ${#PKG_ASSETS[@]}"
ok "db/assets consistent: ${#DB_ASSETS[@]} packages"

# 5. per-package v4 metadata (base name comes from the db desc entry)
for f in "${PKG_ASSETS[@]}"; do
  desc=""
  for candidate in .validate-db/*/desc; do
    if [[ "$(awk '/^%FILENAME%/{getline; print}' "$candidate")" == "$f" ]]; then
      desc="$candidate"
      break
    fi
  done
  if [[ -z "$desc" ]]; then
    fail "no db entry for $f"
    continue
  fi
  base=$(awk '/^%BASE%/{getline; print}' "$desc")
  [[ -n "$base" ]] || base=$(awk '/^%NAME%/{getline; print}' "$desc")
  meta="v4-${base}.meta.json"
  if [[ ! -f "$meta" ]]; then
    fail "missing architecture metadata for ${base}: ${meta}"
  elif ! jq -e '.profile == "x86-64-v4" and (.fingerprint | length > 0) and (.status == "built" or .status == "skipped" or .status == "restored")' "$meta" >/dev/null 2>&1; then
    fail "invalid architecture metadata (must be profile=v4, status=built|skipped|restored): ${meta}"
  else
    ok "metadata ok: ${meta}"
  fi
done

rm -rf .validate-db

if [[ $FAIL -eq 0 ]]; then
  echo "VALIDATION_PASSED=true"
else
  echo "VALIDATION_PASSED=false"
fi
exit $FAIL
