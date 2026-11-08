#!/usr/bin/env bash
#
# extra-repo-lib.sh — shared EXTRA_REPO configuration for container
# bootstraps (build-in-docker.sh, local-build-candidates.sh).
#
# Adds an optional additional pacman repository so inter-package
# dependencies resolve during syncdeps. Format:  name|url
# Example: EXTRA_REPO="88kbleirad|https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository"
#
# Security: the extra repo is configured with `SigLevel = Required
# TrustedOnly` and the release's exported public key is imported ONLY
# after its fingerprint matches EXTRA_REPO_FINGERPRINT (default: the
# out-of-band verified 88kbleirad repository fingerprint). Unsigned,
# tampered, or wrong-key databases and packages fail hard.
#
# Must be sourced from a script running INSIDE the container (root),
# after pacman-key/gpg are available.

configure_extra_repo() {
  if [[ -z "${EXTRA_REPO:-}" ]]; then
    return 0
  fi

  local repo_name="${EXTRA_REPO%%|*}"
  local repo_url="${EXTRA_REPO#*|}"
  if [[ -z "$repo_name" || -z "$repo_url" || "$repo_name" == "$EXTRA_REPO" ]]; then
    echo "::error::EXTRA_REPO must be 'name|url'"
    exit 1
  fi

  local expected_fp="${EXTRA_REPO_FINGERPRINT:-3B9B8E3E5564A77A73B543D049DD327EE8135B62}"

  echo "Fetching ${repo_name} public key for fingerprint verification..."
  if ! curl -fSL --retry 3 -o /tmp/extra-repo-key.asc "${repo_url}/${repo_name}.pub.asc"; then
    echo "::error::could not download ${repo_name} public key from ${repo_url}"
    exit 1
  fi

  local actual_fp
  actual_fp=$(gpg --show-keys --with-colons /tmp/extra-repo-key.asc 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')
  if [[ -z "$actual_fp" ]]; then
    echo "::error::downloaded key is not a well-formed OpenPGP public key"
    exit 1
  fi
  if [[ "$actual_fp" != "$expected_fp" ]]; then
    echo "::error::public key fingerprint mismatch for ${repo_name}!"
    echo "::error::expected ${expected_fp}, got ${actual_fp} — refusing to trust this repository"
    exit 1
  fi

  pacman-key --add /tmp/extra-repo-key.asc || {
    echo "::error::failed to import ${repo_name} public key into pacman keyring"
    exit 1
  }
  pacman-key --lsign-key "${repo_name}@users.noreply.github.com" || {
    echo "::error::failed to locally sign ${repo_name} public key (keyring lacks a pacman secret key?)"
    exit 1
  }

  printf '\n[%s]\nSigLevel = Required TrustedOnly\nServer = %s\n' "$repo_name" "$repo_url" >> /etc/pacman.conf
  echo "EXTRA_REPO '${repo_name}' added with strict signature enforcement (fingerprint verified: ${actual_fp})"
}
