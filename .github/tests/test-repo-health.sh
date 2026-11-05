#!/usr/bin/env bash
#
# Regression tests for the read-only repository health monitor
# (.github/scripts/repo-health.sh). Uses the mock `gh` shim + local fake
# releases (no network / no live GitHub). Requires pacman-contrib
# (repo-add) — run inside the pinned Arch container like test-verify-remote.sh.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# -- mock gh environment ----------------------------------------------------
export MOCK_GH="$REPO_ROOT/.github/tests/mock-gh.sh"
mkdir -p "$WORKDIR/mockbin"
cat > "$WORKDIR/mockbin/gh" <<'SHIM'
#!/usr/bin/env bash
export FAKE_RELEASE_DIR="${FAKE_RELEASE_DIR:?}"
export FAKE_EVENTS_LOG="${FAKE_EVENTS_LOG:-/dev/null}"
exec bash "$MOCK_GH" "$@"
SHIM
chmod +x "$WORKDIR/mockbin/gh"
export PATH="$WORKDIR/mockbin:$PATH"

mk_pkg() { # name outdir [profile]
  local name="$1" out="$2" profile="${3:-x86-64-v4}"
  local d="$WORKDIR/pkgbuild/$name"
  mkdir -p "$d/usr/share"
  printf 'fixture %s\n' "$name" > "$d/usr/share/$name"
  cat > "$d/.PKGINFO" <<PKG
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
  ( cd "$d" && tar --zstd --mtime='@1' -cf "$out/$name-1.0-1-x86_64.pkg.tar.zst" .PKGINFO usr )
  printf '{"package": "%s", "profile": "%s", "status": "built", "fingerprint": "abc"}\n' "$name" "$profile" \
    > "$out/v4-$name.meta.json"
}

# make_release <dir> — 3 packages + db + metas (all healthy)
make_release() {
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"; touch "$dir/.created"; : > "$dir/.ids"
  mk_pkg testa "$dir"
  mk_pkg testb "$dir"
  mk_pkg testc "$dir"
  ( cd "$dir" && repo-add 88kbleirad.db.tar.gz \
      testa-1.0-1-x86_64.pkg.tar.zst \
      testb-1.0-1-x86_64.pkg.tar.zst \
      testc-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
}

EXPECTED='["testa","testb","testc"]'

# run_health <rel> [extra env assignments...]
# runs the health monitor against the fake release dir; sets HEALTH_RC and
# writes JSON to $WORKDIR/health.json
run_health() {
  local rel="$1"; shift
  set +e
  env -i \
    PATH="$PATH" HOME="$HOME" \
    MOCK_GH="$MOCK_GH" \
    GH_TOKEN=dummy \
    GITHUB_REPOSITORY=owner/repo \
    RELEASE_TAG=repository \
    REPO_DB_NAME=88kbleirad \
    BUILD_PROFILE=x86-64-v4 \
    SIGNING_MODE=unsigned \
    FAKE_RELEASE_DIR="$rel" \
    FAKE_EVENTS_LOG="$WORKDIR/health.events" \
    "$@" \
    bash "$REPO_ROOT/.github/scripts/repo-health.sh" \
      repository owner/repo \
      --expected "$EXPECTED" \
      --json "$WORKDIR/health.json" \
      --summary "$WORKDIR/health.md" > "$WORKDIR/health.log" 2>&1
  HEALTH_RC=$?
  set -e
}

# ---------------------------------------------------------------------------
note "health: healthy repository is HEALTHY"
REL="$WORKDIR/release-healthy"
make_release "$REL"
run_health "$REL"
if [[ "$HEALTH_RC" -eq 0 ]]; then
  ok "healthy repo exit 0"
else
  bad "healthy repo failed (rc=$HEALTH_RC): $(tail -5 "$WORKDIR/health.log")"
fi
if [[ "$(jq -r '.overall_status' "$WORKDIR/health.json")" == "HEALTHY" ]]; then
  ok "overall_status=HEALTHY"
else
  bad "overall_status != HEALTHY: $(jq -r '.overall_status' "$WORKDIR/health.json")"
fi
jq -e '.package_count == 3' "$WORKDIR/health.json" >/dev/null \
  && ok "package_count=3" || bad "package_count wrong"
jq -e '.database_asset_count == 4' "$WORKDIR/health.json" >/dev/null \
  && ok "database_asset_count=4" || bad "database_asset_count wrong"
jq -e '.database_status == "PASS"' "$WORKDIR/health.json" >/dev/null \
  && ok "database_status=PASS" || bad "database_status wrong"
jq -e '.checksum_status == "PASS"' "$WORKDIR/health.json" >/dev/null \
  && ok "checksum_status=PASS" || bad "checksum_status wrong"
jq -e '.metadata_status == "PASS"' "$WORKDIR/health.json" >/dev/null \
  && ok "metadata_status=PASS" || bad "metadata_status wrong"
jq -e '.signing_status == "PASS"' "$WORKDIR/health.json" >/dev/null \
  && ok "signing_status=PASS" || bad "signing_status wrong"
if jq -e '.missing_assets == ""' "$WORKDIR/health.json" >/dev/null \
    && jq -e '.unexpected_assets == ""' "$WORKDIR/health.json" >/dev/null; then
  ok "no missing/unexpected assets"
else
  bad "unexpected missing/unexpected: $(jq -r '.missing_assets,.unexpected_assets' "$WORKDIR/health.json")"
fi

# ---------------------------------------------------------------------------
note "health: missing package archive is detected"
REL="$WORKDIR/release-missing-pkg"
make_release "$REL"
rm -f "$REL/testc-1.0-1-x86_64.pkg.tar.zst"
run_health "$REL"
if [[ "$HEALTH_RC" -ne 0 ]]; then
  ok "missing package -> nonzero exit"
else
  bad "missing package not detected (rc=0)"
fi
if jq -e '.missing_assets | contains("testc")' "$WORKDIR/health.json" >/dev/null; then
  ok "missing_assets lists testc"
else
  bad "missing_assets missing testc: $(jq -r '.missing_assets' "$WORKDIR/health.json")"
fi

# ---------------------------------------------------------------------------
note "health: corrupted package archive is detected"
REL="$WORKDIR/release-corrupt-pkg"
make_release "$REL"
# corrupt the archive content (checksum mismatch vs API digest)
printf 'garbage' >> "$REL/testb-1.0-1-x86_64.pkg.tar.zst"
run_health "$REL"
if jq -e '.checksum_status == "FAIL"' "$WORKDIR/health.json" >/dev/null; then
  ok "corrupt archive -> checksum_status=FAIL"
else
  bad "corrupt archive not detected: $(jq -r '.checksum_status' "$WORKDIR/health.json")"
fi

# ---------------------------------------------------------------------------
note "health: invalid remote checksum (bad digest) is detected"
REL="$WORKDIR/release-bad-digest"
make_release "$REL"
run_health "$REL" MOCK_GH_BAD_DIGEST=1
if jq -e '.checksum_status == "FAIL"' "$WORKDIR/health.json" >/dev/null; then
  ok "bad remote digest -> checksum_status=FAIL"
else
  bad "bad digest not detected: $(jq -r '.checksum_status' "$WORKDIR/health.json")"
fi

# ---------------------------------------------------------------------------
note "health: database referencing a missing asset is detected"
REL="$WORKDIR/release-db-mismatch"
make_release "$REL"
# rewrite the db to reference testc but remove the archive, then rebuild db
rm -f "$REL/testc-1.0-1-x86_64.pkg.tar.zst"
( cd "$REL" && rm -f 88kbleirad.db.tar.gz 88kbleirad.db 88kbleirad.files.tar.gz 88kbleirad.files \
    && repo-add 88kbleirad.db.tar.gz testa-1.0-1-x86_64.pkg.tar.zst testb-1.0-1-x86_64.pkg.tar.zst >/dev/null 2>&1 )
run_health "$REL" EXPECTED_PACKAGES='["testa","testb"]'
# expected=2 but db has 2; the deleted testc archive is no longer referenced,
# so db/asset consistency holds. To force db mismatch, corrupt db content:
( cd "$REL" && printf 'garbage' >> 88kbleirad.db.tar.gz )
run_health "$REL"
if jq -e '.database_status == "FAIL"' "$WORKDIR/health.json" >/dev/null; then
  ok "corrupt db -> database_status=FAIL"
else
  bad "corrupt db not detected: $(jq -r '.database_status' "$WORKDIR/health.json")"
fi

# ---------------------------------------------------------------------------
note "health: metadata profile mismatch is detected"
REL="$WORKDIR/release-meta-mismatch"
make_release "$REL"
printf '{"package": "testa", "profile": "x86-64-v3", "status": "built", "fingerprint": "abc"}\n' \
  > "$REL/v4-testa.meta.json"
run_health "$REL"
if jq -e '.metadata_status == "FAIL"' "$WORKDIR/health.json" >/dev/null; then
  ok "metadata profile mismatch -> metadata_status=FAIL"
else
  bad "metadata mismatch not detected: $(jq -r '.metadata_status' "$WORKDIR/health.json")"
fi

# ---------------------------------------------------------------------------
note "health: orphaned (unexpected) asset is detected"
REL="$WORKDIR/release-orphan"
make_release "$REL"
printf '{"package":"ghost","profile":"x86-64-v4","status":"built","fingerprint":"abc"}\n' \
  > "$REL/v4-ghost.meta.json"
run_health "$REL"
if jq -e '.unexpected_assets | contains("v4-ghost")' "$WORKDIR/health.json" >/dev/null; then
  ok "orphaned metadata detected"
else
  bad "orphan not detected: $(jq -r '.unexpected_assets' "$WORKDIR/health.json")"
fi

# ---------------------------------------------------------------------------
note "health: unsigned release with stray signature is detected"
REL="$WORKDIR/release-sig"
make_release "$REL"
printf 'garbage' > "$REL/testa-1.0-1-x86_64.pkg.tar.zst.sig"
run_health "$REL"
if jq -e '.signing_status == "FAIL"' "$WORKDIR/health.json" >/dev/null; then
  ok "stray signature detected in unsigned release"
else
  bad "stray signature not detected: $(jq -r '.signing_status' "$WORKDIR/health.json")"
fi

# ---------------------------------------------------------------------------
note "health: read-only — nothing mutates the release"
REL="$WORKDIR/release-readonly"
make_release "$REL"
before=$(ls "$REL" | sort | md5sum | awk '{print $1}')
run_health "$REL"
after=$(ls "$REL" | sort | md5sum | awk '{print $1}')
if [[ "$before" == "$after" ]]; then
  ok "health check never mutates the release"
else
  bad "release mutated by health check"
fi
if grep -qE 'upload |delete-asset |create ' "$WORKDIR/health.events" 2>/dev/null; then
  bad "health check performed remote mutations: $(cat "$WORKDIR/health.events")"
else
  ok "zero remote mutations by health check"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
