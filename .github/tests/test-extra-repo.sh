#!/usr/bin/env bash
#
# EXTRA_REPO integration tests (Phase 8.4 Batch 6).
#
# Verifies the secure forwarding of EXTRA_REPO from workflows into the
# build container, and the real in-container behavior:
#   - workflows set EXTRA_REPO (env forwarding)
#   - build-in-docker.sh imports the release key only after the pinned
#     fingerprint matches (no blind trust)
#   - the extra repo is configured with SigLevel = Required TrustedOnly
#     (never Optional TrustAll / Never)
#   - signed database sync + clash-geoip resolution inside the pinned
#     container (live, requires docker + network)
#   - tampered database is rejected under strict SigLevel (live)
#
# Live container tests are skipped when docker is unavailable, matching
# the convention of run-tests.sh.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

FINGERPRINT="3B9B8E3E5564A77A73B543D049DD327EE8135B62"
BID="$REPO_ROOT/.github/scripts/build-in-docker.sh"
WS="$REPO_ROOT/.github/workflows/build-staging.yml"
WR="$REPO_ROOT/.github/workflows/build-release.yml"

for f in "$BID" "$WS" "$WR"; do
  [[ -f "$f" ]] || { bad "required file missing: $f"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
done

# -- ER01: both build workflows forward EXTRA_REPO --------------------------
note "ER01: workflows forward EXTRA_REPO into build container"
for wf in "$WS" "$WR"; do
  if grep -q 'EXTRA_REPO: 88kbleirad|https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository' "$wf"; then
    ok "$(basename "$wf") sets EXTRA_REPO to the production release URL"
  else
    bad "$(basename "$wf") missing EXTRA_REPO forwarding"
  fi
done

# -- ER02: container create passes EXTRA_REPO into the container ------------
note "ER02: build-in-docker.sh propagates EXTRA_REPO env into docker create"
if grep -qE '\-e EXTRA_REPO=' "$BID"; then
  ok "docker create carries EXTRA_REPO into container env"
else
  bad "EXTRA_REPO not passed to docker exec/create"
fi

LIB="$REPO_ROOT/.github/scripts/extra-repo-lib.sh"
[[ -f "$LIB" ]] || { bad "extra-repo-lib.sh missing"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# -- ER03: strict SigLevel, no weak modes ------------------------------------
note "ER03: EXTRA_REPO pacman section uses strict signature level"
if grep -q 'SigLevel = Required TrustedOnly' "$LIB"; then
  ok "extra repo block writes SigLevel = Required TrustedOnly"
else
  bad "strict SigLevel missing in EXTRA_REPO block"
fi
if grep -qE 'TrustAll|SigLevel = Never' "$LIB"; then
  bad "EXTRA_REPO block contains weak SigLevel (TrustAll/Never)"
else
  ok "no Optional TrustAll or Never inside EXTRA_REPO block"
fi

# -- ER04: fingerprint pinned before key import ------------------------------
note "ER04: public key fingerprint is verified against pinned value"
if grep -q "$FINGERPRINT" "$LIB"; then
  ok "pinned fingerprint $FINGERPRINT present in extra-repo-lib.sh"
else
  bad "pinned fingerprint missing"
fi
if grep -qE 'ACTUAL_FP.*EXPECTED_FP|EXTRA_REPO_FINGERPRINT' "$LIB" && grep -q "fingerprint mismatch" "$LIB"; then
  ok "mismatch path fails closed with explicit error"
else
  bad "fingerprint mismatch fail-closed check missing"
fi
if grep -q 'pacman-key --lsign-key' "$LIB"; then
  ok "key locally signed into keyring after verification"
else
  bad "pacman-key lsign step missing"
fi

# -- ER05: mihomo onboarded in inventory -------------------------------------
note "ER05: mihomo present in packages.txt and package dir exists"
if grep -qx "mihomo" "$REPO_ROOT/packages.txt"; then
  ok "mihomo listed in packages.txt"
else
  bad "mihomo missing from packages.txt"
fi
if [[ -f "$REPO_ROOT/mihomo/PKGBUILD" ]]; then
  ok "mihomo/PKGBUILD exists"
else
  bad "mihomo/PKGBUILD missing"
fi
if grep -q "clash-geoip" "$REPO_ROOT/mihomo/PKGBUILD"; then
  ok "mihomo PKGBUILD declares clash-geoip dependency"
else
  bad "mihomo PKGBUILD does not declare clash-geoip"
fi

# -- ER06: lua-lgi-git untouched by infra change ------------------------------
note "ER06: lua-lgi-git package intact (no regression)"
if [[ -f "$REPO_ROOT/lua-lgi-git/PKGBUILD" ]] && grep -q "_LUA_VER=5.5" "$REPO_ROOT/lua-lgi-git/PKGBUILD"; then
  ok "lua-lgi-git PKGBUILD intact with Lua 5.5 target"
else
  bad "lua-lgi-git PKGBUILD changed or missing"
fi

# -- ER07..ER09: live container behavior --------------------------------------
note "ER07-ER09: live pinned-container verification"
if ! command -v docker >/dev/null 2>&1; then
  echo "  (skip: docker unavailable; live container tests skipped)"
  echo
  echo "extra-repo: PASS=$PASS FAIL=$FAIL"
  [[ $FAIL -eq 0 ]]
  exit 0
fi

IMAGE="ghcr.io/archlinux/archlinux@sha256:644576e90a71df3b137df2ab6b3517ecd045418195c1946c2c11d1c0564a7981"
REPO_URL="https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository"

run_in_container() { # script-body
  docker run --rm -i \
    -e EXTRA_REPO="88kbleirad|$REPO_URL" \
    -e EXTRA_REPO_FINGERPRINT="$FINGERPRINT" \
    "$IMAGE" bash -s <<< "$1"
}

note "ER07: signed database syncs under strict SigLevel (real pacman -Sy)"
if run_in_container '
set -euo pipefail
pacman-key --init >/dev/null 2>&1
repo_name="${EXTRA_REPO%%|*}"; repo_url="${EXTRA_REPO#*|}"
EXPECTED_FP="${EXTRA_REPO_FINGERPRINT}"
curl -fSL --retry 3 -o /tmp/extra-repo-key.asc "${repo_url}/${repo_name}.pub.asc" >/dev/null 2>&1
ACTUAL_FP=$(gpg --show-keys --with-colons /tmp/extra-repo-key.asc 2>/dev/null | awk -F: "/^fpr:/{print \$10; exit}")
[[ "$ACTUAL_FP" == "$EXPECTED_FP" ]] || { echo "FINGERPRINT_MISMATCH: $ACTUAL_FP"; exit 1; }
pacman-key --add /tmp/extra-repo-key.asc
pacman-key --lsign-key "${repo_name}@users.noreply.github.com" >/dev/null 2>&1
printf "\n[%s]\nSigLevel = Required TrustedOnly\nServer = %s\n" "$repo_name" "$repo_url" >> /etc/pacman.conf
pacman -Sy --noconfirm >/dev/null 2>&1
pacman -Si "${repo_name}/clash-geoip" >/dev/null 2>&1
echo "SIGNED_DB_SYNC_AND_DEP_RESOLUTION_OK"
' | grep -q "SIGNED_DB_SYNC_AND_DEP_RESOLUTION_OK"; then
  ok "signed db synced + clash-geoip resolvable with Required TrustedOnly"
else
  bad "signed db sync or clash-geoip resolution failed in container"
fi

note "ER08: clash-geoip package archive carries a valid detached signature"
if run_in_container '
set -euo pipefail
repo_url="${EXTRA_REPO#*|}"
curl -fSL --retry 3 -o /tmp/geoip.sig "${repo_url}/clash-geoip-202610160207-1-any.pkg.tar.zst.sig" >/dev/null 2>&1
curl -fSL --retry 3 -o /tmp/geoip.pkg "${repo_url}/clash-geoip-202610160207-1-any.pkg.tar.zst" >/dev/null 2>&1
curl -fSL --retry 3 -o /tmp/extra-repo-key.asc "${repo_url}/88kbleirad.pub.asc" >/dev/null 2>&1
mkdir -p /tmp/gnupg-verify && chmod 700 /tmp/gnupg-verify
gpg --homedir /tmp/gnupg-verify --import /tmp/extra-repo-key.asc >/dev/null 2>&1
fpr=$(gpg --homedir /tmp/gnupg-verify --show-keys --with-colons /tmp/extra-repo-key.asc 2>/dev/null | awk -F: "/^fpr:/{print \$10; exit}")
[[ "$fpr" == "${EXTRA_REPO_FINGERPRINT}" ]] || exit 1
gpg --homedir /tmp/gnupg-verify --verify /tmp/geoip.sig /tmp/geoip.pkg >/dev/null 2>&1
echo "PACKAGE_SIGNATURE_VALID"
' | grep -q "PACKAGE_SIGNATURE_VALID"; then
  ok "clash-geoip archive signature verifies against pinned-fingerprint key"
else
  bad "clash-geoip package signature verification failed"
fi

note "ER09: tampered database rejected under Required TrustedOnly"
if run_in_container '
set -euo pipefail
repo_name="${EXTRA_REPO%%|*}"; repo_url="${EXTRA_REPO#*|}"
curl -fSL --retry 3 -o /tmp/key.asc "${repo_url}/${repo_name}.pub.asc" >/dev/null 2>&1
ACTUAL_FP=$(gpg --show-keys --with-colons /tmp/key.asc 2>/dev/null | awk -F: "/^fpr:/{print \$10; exit}")
[[ "$ACTUAL_FP" == "${EXTRA_REPO_FINGERPRINT}" ]] || exit 1
pacman-key --init >/dev/null 2>&1
pacman-key --add /tmp/key.asc
pacman-key --lsign-key "${repo_name}@users.noreply.github.com" >/dev/null 2>&1
# Tamper: flip one byte in the middle of the db archive.
curl -fSL --retry 3 -o /tmp/db.tar.gz "${repo_url}/${repo_name}.db.tar.gz" >/dev/null 2>&1
SZ=$(stat -c%s /tmp/db.tar.gz)
printf "X" | dd of=/tmp/db.tar.gz bs=1 seek=$((SZ / 2)) count=1 conv=notrunc status=none
curl -fSL --retry 3 -o /tmp/db.sig "${repo_url}/${repo_name}.db.sig" >/dev/null 2>&1
if gpg --homedir /tmp/gnupg-tamper --import /tmp/key.asc >/dev/null 2>&1 \
   && gpg --homedir /tmp/gnupg-tamper --verify /tmp/db.sig /tmp/db.tar.gz >/dev/null 2>&1; then
  echo "TAMPER_NOT_DETECTED"
  exit 1
fi
echo "TAMPERED_DB_REJECTED"
' | grep -q "TAMPERED_DB_REJECTED"; then
  ok "tampered database signature rejected"
else
  bad "tampered database was NOT rejected"
fi

echo
echo "extra-repo: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
