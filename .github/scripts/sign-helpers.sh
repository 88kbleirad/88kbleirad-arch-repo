#!/usr/bin/env bash
#
# Shared GPG signing helpers for the publish scripts.
# Sourced by publish-prod.sh / publish-stage.sh — never executed standalone.
#
# Security model:
#   - The private key is read exclusively from the environment variable
#     GPG_PRIVATE_KEY (set by the runner from a GitHub secret). It is
#     never written into the repository, never passed on a command line,
#     and never echoed.
#   - A dedicated scratch GNUPGHOME (/tmp/gnupg-publish) is used for the
#     publish job only; build jobs never receive the key.
#   - Shell tracing must remain off in any script that sources this file
#     (no `set -x`): key material would otherwise leak to job logs.
#   - gpg is always invoked with --pinentry-mode loopback and the
#     passphrase on fd 0 — never as argv (protected against process-list
#     exposure). Empty passphrase ⇒ --passphrase-fd is omitted.
#
# Why repo-add --sign is NOT used here: repo-add invokes gpg itself and
# cannot provide a passphrase non-interactively, so a passphrase-protected
# key would make repo-add's signing fail. We therefore let repo-add build
# the database unsigned and create all detached signatures (packages +
# database) with our own gpg wrapper below.
#
# Environment:
#   GPG_PRIVATE_KEY   - armored secret signing key (REQUIRED)
#   GPG_PASSPHRASE   - optional passphrase (kept empty for CI keys)
#   SIGNING_KEYID     - set after gpg_import_signing_key succeeds
#   GNUPGHOME         - scratch keyring (default /tmp/gnupg-publish)

set -uo pipefail

export GNUPGHOME="${GNUPGHOME:-/tmp/gnupg-publish}"
SIGNING_KEYID=""

# Wrap gpg with loopback pinentry when a passphrase is configured.
run_gpg() {
  local -a args=(--batch --yes --pinentry-mode loopback)
  local pass
  pass="$(gpg_resolve_passphrase)"
  if [[ -n "$pass" ]]; then
    printf '%s\n' "$pass" | gpg "${args[@]}" --passphrase-fd 0 "$@"
  else
    gpg "${args[@]}" "$@"
  fi
}

gpg_init_homedir() {
  rm -rf "$GNUPGHOME"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
}

# gpg_import_signing_key reads the private key from one of:
#   - $GPG_KEY_FILE (host-configured secret file, bind-mounted read-only
#     into the container — the publish flow)
#   - $GPG_PRIVATE_KEY (environment variable fallback for local testing)
#
# The armored input is normalized before import (UTF-8 BOM removal, any
# leading whitespace indentation stripped line-by-line, trailing newline
# ensured) so common paste artifacts (e.g. indented text from a code block)
# cannot cause a spurious import failure. Normalization is strictly
# whitespace — it never alters key material.
#
# Diagnostics are sanitized: gpg's exit status and a scrubbed stderr are
# reported, never any key content or passphrase.
gpg_import_signing_key() {
  local keyfile tmpfile rc gpg_err
  if [[ -n "${GPG_KEY_FILE:-}" && -f "$GPG_KEY_FILE" ]]; then
    keyfile="$GPG_KEY_FILE"
  elif [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then
    keyfile="$(mktemp)"
    printf '%s\n' "$GPG_PRIVATE_KEY" > "$keyfile"
    chmod 600 "$keyfile"
  else
    echo "::error::GPG signing key secret is not available (GPG_KEY_FILE / GPG_PRIVATE_KEY); refusing to publish unsigned repository assets."
    return 1
  fi

  if [[ ! -s "$keyfile" ]]; then
    echo "::error::GPG signing key file is empty; aborting publication."
    if [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then rm -f "$keyfile"; fi
    return 1
  fi

  # Normalize armor: strip BOM, strip leading/trailing whitespace per
  # line, ensure a trailing newline. (Armor ignores surrounding
  # whitespace, but indentation breaks gpg's parser — normalize it.)
  tmpfile="$(mktemp)"
  if ! sed '1s/^\xEF\xBB\xBF//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$keyfile" > "$tmpfile"; then
    echo "::error::Failed to normalize the GPG signing key file."
    rm -f "$tmpfile"
    if [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then rm -f "$keyfile"; fi
    return 1
  fi
  printf '\n' >> "$tmpfile"

  gpg_err="$(mktemp)"
  if ! gpg --batch --import "$tmpfile" >/dev/null 2>"$gpg_err"; then
    rc=$?
    echo "::error::Failed to import the GPG signing key (gpg exit $rc)."
    # Sanitized diagnostic: only gpg's own stderr (never key bytes) and
    # structural facts about the provided file.
    if [[ -s "$gpg_err" ]]; then
      sed 's/^/::error::  gpg: /' "$gpg_err" >&2 || true
    fi
    {
      echo "::error::  import source: ${GPG_KEY_FILE:+\"GPG_KEY_FILE\" mount}${GPG_PRIVATE_KEY:+environment variable} (size $(wc -c < "$tmpfile" | tr -d ' ') bytes after normalization)"
      head -1 "$tmpfile" | grep -q '^-----BEGIN PGP PRIVATE KEY BLOCK-----$' \
        && echo "::error::  armor header: present" \
        || echo "::error::  armor header: MISSING (not an armored private key?)"
      tail -1 "$tmpfile" | grep -q '^-----END PGP PRIVATE KEY BLOCK-----$' \
        && echo "::error::  armor footer: present" \
        || echo "::error::  armor footer: MISSING (truncated armor?)"
    } >&2
    rm -f "$tmpfile" "$gpg_err"
    if [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then rm -f "$keyfile"; fi
    return 1
  fi
  rm -f "$tmpfile" "$gpg_err"

  if [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then rm -f "$keyfile"; fi
  SIGNING_KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
  if [[ -z "$SIGNING_KEYID" ]]; then
    # import succeeded but no secret key is present, e.g. a public-only
    # key was supplied instead of a private one
    if gpg --list-keys --with-colons | grep -q '^pub:'; then
      echo "::error::No secret signing key found after import (a public key was imported, not a private key)."
    else
      echo "::error::No signing key found after import; aborting publication."
    fi
    return 1
  fi
  echo "[sign] imported signing key ${SIGNING_KEYID}"
}

# Resolve the passphrase from the mounted secret file if one is provided.
gpg_resolve_passphrase() {
  if [[ -n "${GPG_PASSPHRASE_FILE:-}" && -f "$GPG_PASSPHRASE_FILE" ]]; then
    cat "$GPG_PASSPHRASE_FILE"
  elif [[ -n "${GPG_PASSPHRASE:-}" ]]; then
    printf '%s\n' "$GPG_PASSPHRASE"
  fi
}

# Sign a file with a detached binary signature; passphrase via fd 0 only.
sign_detached() {
  local file="$1" sig="${1}.sig"
  if ! run_gpg --detach-sign --no-armor -u "$SIGNING_KEYID" -o "$sig" "$file"; then
    echo "::error::gpg failed to sign $(basename "$file")"
    return 1
  fi
  echo "[sign] signed $(basename "$file")"
}

verify_detached() {
  local file="$1" sig="$2"
  [[ -s "$sig" ]] || { echo "::error::missing signature: $sig"; return 1; }
  if ! gpg --verify "$sig" "$file" >/dev/null 2>&1; then
    echo "::error::signature verification failed: $sig"
    return 1
  fi
}

# Sign every package archive in the current directory that does not yet
# carry a signature, then verify all of them. Exits 1 on any failure.
ensure_all_packages_signed() {
  local ok=1 pkg
  shopt -s nullglob
  for pkg in *.pkg.tar.zst; do
    if [[ ! -s "${pkg}.sig" ]]; then
      sign_detached "$pkg" || { ok=0; continue; }
    fi
    verify_detached "$pkg" "${pkg}.sig" || ok=0
  done
  shopt -u nullglob
  [[ $ok -eq 1 ]]
}

# Sign and verify the pacman database archives produced by repo-add and
# create the plain-name (.db.sig / .files.sig) copies pacman fetches as
# <db>.sig/<files>.sig. The detached signatures are over the .tar.gz
# database files (identical content to what clients download under the
# plain <db> name).
sign_and_publish_db_signatures() {
  local db
  for db in "${REPO_DB_NAME}.db.tar.gz" "${REPO_DB_NAME}.files.tar.gz"; do
    [[ -s "$db" ]] || { echo "::error::database archive missing: $db"; return 1; }
    sign_detached "$db" || return 1
    verify_detached "$db" "${db}.sig" || return 1
  done
  cp -f "${REPO_DB_NAME}.db.tar.gz.sig" "${REPO_DB_NAME}.db.sig"
  cp -f "${REPO_DB_NAME}.files.tar.gz.sig" "${REPO_DB_NAME}.files.sig"
  echo "[sign] database signatures verified and published (.db.sig / .files.sig)"
}

export_public_key() {
  local out="${REPO_DB_NAME}.pub.asc"
  gpg --export --armor "$SIGNING_KEYID" > "$out"
  [[ -s "$out" ]] || { echo "::error::failed to export public signing key"; return 1; }
  echo "[sign] exported public key: $out"
}
