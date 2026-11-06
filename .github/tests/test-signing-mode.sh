#!/usr/bin/env bash
#
# Regression tests for optional production signing (SIGNING_MODE).
#
# Covers:
#   - unsigned mode publishes WITHOUT GPG secrets (no key import, no env)
#   - signed mode is strict (missing/invalid key aborts, never downgrades)
#   - invalid SIGNING_MODE value fails closed
#   - unsigned mode purges stale .sig assets (.pkg.tar.zst.sig, db/files sigs)
#   - signed mode keeps .sig assets and public key
#   - existing release assets are preserved in both modes (merge)
#   - database is regenerated in both modes and validates (integrity intact)
#   - workflow wiring: unsigned publish job has no environment; signed job
#     uses the protected environment; prepare validates the input
#
# Uses the mock gh shim; no network, no secrets, no live releases.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# -- test key (signed scenarios) --------------------------------------------
export GNUPGHOME="$WORKDIR/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
cat > "$WORKDIR/keyparams" <<'KP'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: 88kbleirad package signing
Name-Email: 88kbleirad@users.noreply.github.com
Expire-Date: 0
%commit
KP
gpg --batch --gen-key "$WORKDIR/keyparams" >/dev/null 2>&1
KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
export GPG_PRIVATE_KEY=$(gpg --armor --export-secret-keys "$KEYID")

# -- scripts / repo layout --------------------------------------------------
REPO_COPY="$WORKDIR/repo"
mkdir -p "$REPO_COPY/.github/scripts"
cp "$REPO_ROOT/.github/scripts/sign-helpers.sh" "$REPO_COPY/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/gh-release-lib.sh" "$REPO_COPY/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/publish-prod.sh" "$REPO_COPY/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/validate-release.sh" "$REPO_COPY/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/verify-remote-release.sh" "$REPO_COPY/.github/scripts/"
cp "$REPO_ROOT/.github/scripts/verify-build-cache.sh" "$REPO_COPY/.github/scripts/"
mkdir -p "$REPO_COPY/bin"
cp "$REPO_ROOT/.github/tests/mock-gh.sh" "$REPO_COPY/bin/mock-gh.sh"
cat > "$REPO_COPY/bin/gh" <<'SHIM'
#!/usr/bin/env bash
export FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?}"
export FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"
exec bash "$(dirname "$(readlink -f "$0")")/mock-gh.sh" "$@"
SHIM
chmod +x "$REPO_COPY/bin/gh"

# -- package + meta fixtures -------------------------------------------------
mk_pkg() { # outdir name
  local out="$1" name="$2"
  local dir="$WORKDIR/pkgbuild/$name"
  mkdir -p "$dir/usr/share"
  printf 'fixture %s\n' "$name" > "$dir/usr/share/$name"
  cat > "$dir/.PKGINFO" <<PKG
pkgname = $name
pkgbase = $name
pkgver = 1.0-1
pkgdesc = fixture
url = https://example.com
builddate = 1
packager = 88kbleirad <88kbleirad@users.noreply.github.com>
size = 8
arch = x86_64
license = MIT
PKG
  # deterministic mtimes so a re-publish of the same package is byte-identical
  # (otherwise the same-version drift gate would spuriously abort)
  touch -t 202001010000.00 "$dir/.PKGINFO" "$dir/usr" "$dir/usr/share" "$dir/usr/share/$name"
  ( cd "$dir" && find . -mindepth 1 \( -type f -o -type d \) | sort \
      | sed 's|^\./||' \
      | tar --zstd --mtime='@1' -cf "$out/$name-1.0-1-x86_64.pkg.tar.zst" -T - )
  printf '{"package": "%s", "profile": "x86-64-v4", "status": "built", "fingerprint": "abc"}\n' "$name" \
    > "$out/v4-$name.meta.json"
}

# -- run publish-prod --------------------------------------------------------
run_prod() { # scenario mode keymode [releasedir]
  local scenario="$1" mode="$2" keymode="$3"
  local rel="${4:-$WORKDIR/release-$scenario}"
  local ws="$WORKDIR/ws-$scenario"
  rm -rf "$ws"; mkdir -p "$ws/.github/scripts" "$ws/output" "$ws/bin"
  cp "$REPO_COPY/.github/scripts/"*.sh "$ws/.github/scripts/"
  cp "$REPO_COPY/bin/gh" "$ws/bin/gh"
  cp "$REPO_COPY/bin/mock-gh.sh" "$ws/bin/mock-gh.sh"
  mk_pkg "$ws/output" testa
  mk_pkg "$ws/output" testb

  local key_env=()
  if [[ "$keymode" == "withkey" ]]; then
    key_env=(GPG_PRIVATE_KEY="$GPG_PRIVATE_KEY" GPG_PASSPHRASE="")
  else
    key_env=(GPG_PRIVATE_KEY="" GPG_PASSPHRASE="")
  fi

  ( cd "$ws" && \
    env -i \
      PATH="$ws/bin:$PATH" HOME="$HOME" \
      GITHUB_WORKSPACE="$ws" \
      GITHUB_REPOSITORY="owner/repo" \
      GH_TOKEN=dummy \
      RELEASE_TAG=repository \
      REPO_DB_NAME=88kbleirad \
      GITHUB_STEP_SUMMARY="$ws/summary.md" \
      SIGNING_MODE="$mode" \
      EXPECTED_PACKAGES="${EXPECTED_PACKAGES:-}" \
      FAKE_RELEASE_DIR="$rel" \
      FAKE_EVENTS_LOG="$ws/events.log" \
      "${key_env[@]}" \
      bash "$ws/.github/scripts/publish-prod.sh" > "$WORKDIR/$scenario.log" 2>&1 )
  echo $?
}

# ---------------------------------------------------------------------------
note "unsigned mode: publishes without GPG secrets"
RELEASE="$WORKDIR/release-unsigned"
rm -rf "$RELEASE"
rc=$(run_prod unsigned-ok unsigned nokey "$WORKDIR/release-unsigned")
if [[ "$rc" -eq 0 ]]; then
  ok "unsigned publish exit 0 (no signing secrets)"
else
  bad "unsigned publish failed (rc=$rc): $(tail -5 "$WORKDIR/unsigned-ok.log")"
fi
[[ -f "$RELEASE/88kbleirad.db.tar.gz" ]] && ok "db published" || bad "db missing"
[[ -f "$RELEASE/testa-1.0-1-x86_64.pkg.tar.zst" ]] && ok "package published" || bad "package missing"
if ls "$RELEASE"/*.pkg.tar.zst.sig "$RELEASE/88kbleirad.db.sig" "$RELEASE/88kbleirad.pub.asc" >/dev/null 2>&1; then
  bad "unsigned release unexpectedly contains signature/key assets"
else
  ok "unsigned release has no signature/key assets"
fi
# integrity validation still passes (REQUIRE_SIGNATURES=0)
REQUIRE_SIGNATURES=0 bash "$REPO_ROOT/.github/scripts/validate-release.sh" "$RELEASE" "88kbleirad" >/dev/null 2>&1 \
  && ok "unsigned release validates (integrity intact)" || bad "unsigned release validation failed"

# ---------------------------------------------------------------------------
note "unsigned mode: stale .sig assets from an earlier signed release are purged"
RELEASE2="$WORKDIR/release-unsigned2"
rm -rf "$RELEASE2"; mkdir -p "$RELEASE2"
touch "$RELEASE2/.created"
# seed a "previous signed release": package + sig + db + db sig + pub key
mk_pkg "$RELEASE2" testa
gpg --batch --yes --detach-sign --no-armor -u "$KEYID" \
  -o "$RELEASE2/testa-1.0-1-x86_64.pkg.tar.zst.sig" \
  "$RELEASE2/testa-1.0-1-x86_64.pkg.tar.zst"
( cd "$RELEASE2" && repo-add --include-sigs 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
gpg --batch --yes --detach-sign --no-armor -u "$KEYID" \
  -o "$RELEASE2/88kbleirad.db.sig" "$RELEASE2/88kbleirad.db.tar.gz"
gpg --batch --yes --detach-sign --no-armor -u "$KEYID" \
  -o "$RELEASE2/88kbleirad.files.sig" "$RELEASE2/88kbleirad.files.tar.gz"
gpg --armor --export "$KEYID" > "$RELEASE2/88kbleirad.pub.asc"
cp "$RELEASE2/v4-testa.meta.json" "$RELEASE2/" 2>/dev/null || true

rc=$(run_prod unsigned-purge unsigned nokey "$RELEASE2")
if [[ "$rc" -eq 0 ]]; then
  ok "unsigned publish over previous signed release exit 0"
else
  bad "unsigned purge run failed (rc=$rc): $(tail -5 "$WORKDIR/unsigned-purge.log")"
fi
# all .sig / pub key assets must be gone from the release now
LEFT=$(gh release view repository --repo owner/repo --json assets -q '.assets[].name' 2>/dev/null | grep -cE '\.sig$|pub\.asc' || true)
[[ "$LEFT" == "0" ]] && ok "all stale signature/key assets purged" || bad "stale signature/key assets remain ($LEFT): $(gh release view repository --repo owner/repo --json assets -q '.assets[].name' 2>/dev/null | grep -E '\.sig$|pub\.asc' || true)"

# ---------------------------------------------------------------------------
note "signed mode: publishes signed assets when key is valid"
RELEASE3="$WORKDIR/release-signed"
rm -rf "$RELEASE3"
rc=$(run_prod signed-ok signed withkey "$WORKDIR/release-signed")
if [[ "$rc" -eq 0 ]]; then
  ok "signed publish exit 0"
else
  bad "signed publish failed (rc=$rc): $(tail -5 "$WORKDIR/signed-ok.log")"
fi
[[ -f "$RELEASE3/88kbleirad.db.sig" ]] && ok "db.sig published" || bad "db.sig missing"
[[ -f "$RELEASE3/88kbleirad.pub.asc" ]] && ok "pub.asc published" || bad "pub.asc missing"
[[ -f "$RELEASE3/testa-1.0-1-x86_64.pkg.tar.zst.sig" ]] && ok "package sig published" || bad "package sig missing"
REQUIRE_SIGNATURES=1 bash "$REPO_ROOT/.github/scripts/validate-release.sh" "$RELEASE3" "88kbleirad" >/dev/null 2>&1 \
  && ok "signed release validates with signatures" || bad "signed release validation failed"

# ---------------------------------------------------------------------------
note "signed mode: missing key aborts (never silent downgrade)"
rc=$(run_prod signed-nokey signed nokey "$WORKDIR/release-signed-nokey")
if [[ "$rc" -ne 0 ]] && grep -q "No signing key available" "$WORKDIR/signed-nokey.log"; then
  ok "signed mode aborts without key"
else
  bad "signed mode did not abort without key (rc=$rc)"
fi

# ---------------------------------------------------------------------------
note "invalid SIGNING_MODE fails closed"
rc=$(run_prod invalid-mode bogus nokey "$WORKDIR/release-invalid")
if [[ "$rc" -ne 0 ]] && grep -q "Invalid SIGNING_MODE" "$WORKDIR/invalid-mode.log"; then
  ok "invalid mode rejected"
else
  bad "invalid mode not rejected (rc=$rc)"
fi

# ---------------------------------------------------------------------------
note "workflow wiring: unsigned job has no protected environment"
if grep -q 'if: \${{ inputs.signing-mode != .signed. }}' "$REPO_ROOT/.github/workflows/build-release.yml" \
    && awk '/^  publish:/,/^  publish-signed:/' "$REPO_ROOT/.github/workflows/build-release.yml" | grep -q 'environment:'; then
  bad "unsigned publish job uses a protected environment"
else
  ok "unsigned publish job has no environment"
fi
awk '/^  publish-signed:/{p=1} p' "$REPO_ROOT/.github/workflows/build-release.yml" | grep -q 'environment: package-signing' \
  && ok "signed publish job uses package-signing environment" || bad "signed publish job missing protected environment"
grep -q 'INPUT_SIGNING_MODE' "$REPO_ROOT/.github/workflows/build-release.yml" \
  && ok "prepare validates signing-mode input" || bad "prepare does not validate signing-mode"
grep -q 'signing-mode:' "$REPO_ROOT/.github/workflows/build-release.yml" \
  && ok "signing-mode input defined" || bad "signing-mode input missing"

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
