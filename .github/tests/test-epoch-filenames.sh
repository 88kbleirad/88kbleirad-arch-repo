#!/usr/bin/env bash
#
# Regression tests for epoch-aware package-archive filenames
# (.github/scripts/pkg-filename-lib.sh).
#
# Covers the generic version-parsing rules the pipeline must honor:
#   - .PKGINFO `pkgver` may already embed the epoch and release
#     (pacman 7: "2:3.0.5-1")
#   - legacy .PKGINFO carries separate `epoch` / `pkgver` / `pkgrel`
#   - epoch=0 must not add a prefix
#   - the GitHub-asset-safe name (epoch `:` -> `.`) is the canonical
#     stored basename; every derived filename uses it
#   - no per-package special casing (the beautyline exclusion at the
#     time of the 8->13 expansion is generalized away)
#
# Host-only: bash + awk + sed. No container, no network, no release.

set -uo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# shellcheck source=/dev/null
. "$REPO_ROOT/.github/scripts/pkg-filename-lib.sh"

pkginfo_file() { # heredoc content -> file
  local f="$WORKDIR/PKGINFO.test"
  cat > "$f"
  printf '%s\n' "$f"
}

# ---------------------------------------------------------------------------
note "epoch filename: pacman 7 embedded EVR (pkgver carries epoch+release)"
f=$(pkginfo_file <<'EOF'
pkgname = beautyline
pkgbase = beautyline
pkgver = 2:3.0.5-1
arch = any
EOF
)
got=$(archive_basename "$f") || { bad "archive_basename returned nonzero"; got=""; }
if [[ "$got" == "beautyline-2.3.0.5-1-any.pkg.tar.zst" ]]; then
  ok "canonical stored name (epoch ':' -> '.')"
else
  bad "got: $got"
fi

# ---------------------------------------------------------------------------
note "epoch filename: legacy .PKGINFO (separate epoch/pkgrel)"
f=$(pkginfo_file <<'EOF'
pkgname = beautyline
pkgver = 3.0.5
pkgrel = 1
epoch = 2
arch = any
EOF
)
got=$(archive_basename "$f") || bad "archive_basename returned nonzero"
if [[ "$got" == "beautyline-2.3.0.5-1-any.pkg.tar.zst" ]]; then
  ok "legacy epoch+krel → same canonical name"
else
  bad "got: $got"
fi

# ---------------------------------------------------------------------------
note "epoch filename: no epoch and no pkgrel"
f=$(pkginfo_file <<'EOF'
pkgname = plain
pkgver = 1.2.3
arch = x86_64
EOF
)
got=$(archive_basename "$f") || bad "archive_basename returned nonzero"
if [[ "$got" == "plain-1.2.3-x86_64.pkg.tar.zst" ]]; then
  ok "plain modern name"
else
  bad "got: $got"
fi

# ---------------------------------------------------------------------------
note "epoch filename: epoch=0 must not add a prefix"
f=$(pkginfo_file <<'EOF'
pkgname = plain
pkgver = 1.2.3
pkgrel = 2
epoch = 0
arch = x86_64
EOF
)
got=$(archive_basename "$f") || bad "archive_basename returned nonzero"
if [[ "$got" == "plain-1.2.3-2-x86_64.pkg.tar.zst" ]]; then
  ok "epoch=0 ignored"
else
  bad "got: $got"
fi

# ---------------------------------------------------------------------------
note "mangle: colon runs collapse, dot runs collapse"
v=$(_archive_mangle_name "beautyline-2:3.0.5-1-any.pkg.tar.zst")
[[ "$v" == "beautyline-2.3.0.5-1-any.pkg.tar.zst" ]] \
  && ok "colon→dot" || bad "got: $v"
v=$(_archive_mangle_name "a-1::2-1-any.pkg.tar.zst")
[[ "$v" == "a-1.2-1-any.pkg.tar.zst" ]] \
  && ok "colon run → single dot" || bad "got: $v"
v=$(_archive_mangle_name "a-1.2.3-1-any.pkg.tar.zst")
[[ "$v" == "a-1.2.3-1-any.pkg.tar.zst" ]] \
  && ok "plain name unchanged" || bad "got: $v"

# ---------------------------------------------------------------------------
note "incomplete metadata fails closed"
f=$(pkginfo_file <<'EOF'
pkgname = broken
pkgver = 1.0
EOF
)
if archive_basename "$f" >/dev/null 2>&1; then
  bad "incomplete .PKGINFO accepted"
else
  ok "missing arch rejected"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
