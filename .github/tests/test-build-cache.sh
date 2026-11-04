#!/usr/bin/env bash
#
# Regression tests for deterministic build-cache verification (Objective C).
#
# Drives .github/scripts/verify-build-cache.sh against synthetic results
# directories covering: 8 valid hits, one legitimate miss, fingerprint
# mismatch, metadata-only artifact, missing archive, corrupted cached
# archive, duplicate results, wrong build profile, strict-mode failure and
# normal-rebuild success.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

verify() { # resultsdir expected [extra args...]
  local dir="$1" expected="$2"; shift 2
  bash "$REPO_ROOT/.github/scripts/verify-build-cache.sh" \
    --expected "$expected" --results-dir "$dir" "$@"
}

mk_archive() { # dir name
  local dir="$1" name="$2"
  local d="$WORKDIR/pkgbuild/$name"
  mkdir -p "$d/usr/share"
  printf 'pkg %s\n' "$name" > "$d/usr/share/$name"
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
  ( cd "$d" && tar --zstd -cf "$dir/$name-1.0-1-x86_64.pkg.tar.zst" .PKGINFO usr )
}

mk_meta() { # dir name status [extra_json]
  local dir="$1" name="$2" status="$3" extra="${4:-}"
  {
    printf '{\n'
    printf '  "package": %s,\n' "$(printf '%s' "$name" | jq -R .)"
    printf '  "profile": "x86-64-v4",\n'
    printf '  "status": %s,\n' "$(printf '%s' "$status" | jq -R .)"
    printf '  "fingerprint": "fp3",\n'
    printf '  "built_at": "2026-11-04T00:00:00Z"\n'
    [[ -n "$extra" ]] && printf ',%s\n' "$extra"
    printf '}\n'
  } > "$dir/v4-$name.meta.json"
}

EXPECTED8='["nmtui-go","osu-mime","ksuperkey","magika","catppuccin-fcitx5-git","catppuccin-whiskers-bin","physlock","all-contributors-cli"]'

# ---------------------------------------------------------------------------
note "cache: eight valid hits pass"
D="$WORKDIR/hits8"
mkdir -p "$D"
for name in nmtui-go osu-mime ksuperkey magika catppuccin-fcitx5-git catppuccin-whiskers-bin physlock all-contributors-cli; do
  echo "$name" > "$D/status-skipped-$name.txt"
  mk_archive "$D" "$name"
  mk_meta "$D" "$name" skipped
done
if verify "$D" "$EXPECTED8" > "$WORKDIR/hits8.out" 2>&1; then
  ok "8/8 cache hits verified"
else
  bad "8/8 hit verification failed: $(tail -5 "$WORKDIR/hits8.out")"
fi
grep -q '"hits": 8' "$WORKDIR/hits8.out" && ok "summary shows 8 hits" || bad "summary hits != 8"

# ---------------------------------------------------------------------------
note "cache: one legitimate miss allowed in normal mode"
D="$WORKDIR/miss1"
mkdir -p "$D"
for name in nmtui-go osu-mime ksuperkey magika catppuccin-fcitx5-git catppuccin-whiskers-bin physlock; do
  echo "$name" > "$D/status-skipped-$name.txt"
  mk_archive "$D" "$name"
  mk_meta "$D" "$name" skipped
done
echo "all-contributors-cli" > "$D/status-built-all-contributors-cli.txt"
mk_archive "$D" all-contributors-cli
mk_meta "$D" all-contributors-cli built
if verify "$D" "$EXPECTED8" > "$WORKDIR/miss1.out" 2>&1; then
  ok "normal mode tolerates a legitimate rebuild"
else
  bad "normal mode failed on legitimate rebuild: $(tail -5 "$WORKDIR/miss1.out")"
fi
grep -q '"hits": 7' "$WORKDIR/miss1.out" && grep -q '"misses": 1' "$WORKDIR/miss1.out" \
  && ok "summary 7 hits 1 miss" || bad "miss summary wrong"

# ---------------------------------------------------------------------------
note "cache: strict mode fails on unexpected miss"
if verify "$D" "$EXPECTED8" --strict > "$WORKDIR/strict.out" 2>&1; then
  bad "strict mode accepted a rebuild"
else
  grep -q "unexpected rebuild for all-contributors-cli" "$WORKDIR/strict.out" \
    && ok "strict mode fails on rebuild" || bad "strict mode did not fail"
fi

# ---------------------------------------------------------------------------
note "cache: fingerprint mismatch detected"
D="$WORKDIR/fpmismatch"
mkdir -p "$D"
for name in nmtui-go osu-mime; do
  echo "$name" > "$D/status-skipped-$name.txt"
  mk_archive "$D" "$name"
  mk_meta "$D" "$name" skipped
done
# ksuperkey: cached metadata+archive exist but NO status file, which means
# the build job decided the fingerprint changed (or the result was lost):
# the verification must not treat it as a silent hit.
mk_archive "$D" ksuperkey
mk_meta "$D" ksuperkey skipped
if verify "$D" '["nmtui-go","osu-mime","ksuperkey"]' > "$WORKDIR/fp.out" 2>&1; then
  bad "fingerprint mismatch not detected"
else
  grep -q "MISS_FINGERPRINT for ksuperkey" "$WORKDIR/fp.out" \
    && ok "fingerprint mismatch detected" || bad "fp mismatch handling wrong: $(grep -E 'ksuperkey' "$WORKDIR/fp.out" | head -3)"
fi

# ---------------------------------------------------------------------------
note "cache: metadata-only artifact is not a hit"
D="$WORKDIR/metaonly"
mkdir -p "$D"
echo "magika" > "$D/status-failed-magika.txt"
mk_meta "$D" magika failed
if verify "$D" '["magika"]' > "$WORKDIR/metaonly.out" 2>&1; then
  bad "metadata-only artifact accepted as hit"
else
  grep -q "FAILED for magika" "$WORKDIR/metaonly.out" \
    && ok "metadata-only artifact marked FAILED" || bad "metadata-only not failed"
fi

# ---------------------------------------------------------------------------
note "cache: missing archive despite matching metadata fails"
D="$WORKDIR/missingarch"
mkdir -p "$D"
echo "nmtui-go" > "$D/status-skipped-nmtui-go.txt"
mk_meta "$D" nmtui-go skipped
if verify "$D" '["nmtui-go"]' > "$WORKDIR/missingarch.out" 2>&1; then
  bad "missing archive accepted as hit"
else
  grep -q "MISS_ARCHIVE for nmtui-go" "$WORKDIR/missingarch.out" \
    && ok "missing archive detected" || bad "missing archive not detected"
fi

# ---------------------------------------------------------------------------
note "cache: corrupted cached archive fails"
D="$WORKDIR/corrupt"
mkdir -p "$D"
echo "osu-mime" > "$D/status-skipped-osu-mime.txt"
mk_archive "$D" osu-mime
printf 'not-a-tar' > "$D/osu-mime-1.0-1-x86_64.pkg.tar.zst"
mk_meta "$D" osu-mime skipped
if verify "$D" '["osu-mime"]' > "$WORKDIR/corrupt.out" 2>&1; then
  bad "corrupted cached archive accepted"
else
  grep -q "INVALID for osu-mime" "$WORKDIR/corrupt.out" \
    && ok "corrupted archive detected" || bad "corrupt archive not detected"
fi

# ---------------------------------------------------------------------------
note "cache: duplicate results fail"
D="$WORKDIR/dup"
mkdir -p "$D"
echo "ksuperkey" > "$D/status-skipped-ksuperkey.txt"
echo "ksuperkey" > "$D/status-built-ksuperkey.txt"
mk_archive "$D" ksuperkey
mk_meta "$D" ksuperkey skipped
if verify "$D" '["ksuperkey"]' > "$WORKDIR/dup.out" 2>&1; then
  bad "duplicate results accepted"
else
  grep -q "DUPLICATE for ksuperkey" "$WORKDIR/dup.out" \
    && ok "duplicate results detected" || bad "duplicates not detected"
fi

# ---------------------------------------------------------------------------
note "cache: wrong build profile fails"
D="$WORKDIR/wrongprof"
mkdir -p "$D"
echo "physlock" > "$D/status-skipped-physlock.txt"
mk_archive "$D" physlock
printf '{"package":"physlock","profile":"x86-64-v3","status":"skipped","fingerprint":"fp3"}\n' > "$D/v4-physlock.meta.json"
if verify "$D" '["physlock"]' > "$WORKDIR/wrongprof.out" 2>&1; then
  bad "wrong build profile accepted"
else
  grep -q "WRONG_PROFILE for physlock" "$WORKDIR/wrongprof.out" \
    && ok "wrong profile detected" || bad "wrong profile not detected"
fi

# ---------------------------------------------------------------------------
note "cache: intentionally excluded package is allowed"
D="$WORKDIR/excluded"
mkdir -p "$D"
echo "nmtui-go" > "$D/status-skipped-nmtui-go.txt"
mk_archive "$D" nmtui-go
mk_meta "$D" nmtui-go skipped
# osu-mime is excluded from the build matrix by the critical/exclusion
# policy: it is not part of the EXPECTED inventory, so verification must
# not require it
EXCLUDED='["osu-mime"]'
if verify "$D" '["nmtui-go"]' --excluded "$EXCLUDED" > "$WORKDIR/excl.out" 2>&1; then
  ok "excluded package accepted"
else
  bad "excluded package rejected: $(tail -5 "$WORKDIR/excl.out")"
fi

# ---------------------------------------------------------------------------
note "cache: precisely invalid archive reports reason"
D="$WORKDIR/precise"
mkdir -p "$D"
echo "a" > "$D/status-skipped-a.txt"
printf 'garbage-not-a-tar' > "$D/a-1.0-1-x86_64.pkg.tar.zst"
mk_meta "$D" a skipped
if verify "$D" '["a"]' > "$WORKDIR/precise.out" 2>&1; then
  bad "invalid archive accepted"
else
  grep -qE "INVALID for a \(archive decompression failed or missing .PKGINFO\)|archive decompression failed" "$WORKDIR/precise.out" \
    && ok "invalid archive reports precise reason" || bad "precise reason missing: $(tail -3 "$WORKDIR/precise.out")"
fi

# ---------------------------------------------------------------------------
note "cache: missing .PKGINFO detected"
D="$WORKDIR/nopkginfo"
mkdir -p "$D"
echo "b" > "$D/status-skipped-b.txt"
d="$WORKDIR/pkgbuild2/b"; mkdir -p "$d/usr/share"; echo x > "$d/usr/share/b"
( cd "$d" && tar --zstd -cf "$D/b-1.0-1-x86_64.pkg.tar.zst" usr )  # no .PKGINFO
mk_meta "$D" b skipped
if verify "$D" '["b"]' > "$WORKDIR/nopkginfo.out" 2>&1; then
  bad "archive without .PKGINFO accepted"
else
  grep -q "missing .PKGINFO" "$WORKDIR/nopkginfo.out" \
    && ok "missing .PKGINFO detected" || bad "missing PKGINFO not detected: $(tail -3 "$WORKDIR/nopkginfo.out")"
fi

# ---------------------------------------------------------------------------
note "cache: checksum mismatch detection (--hashes)"
D="$WORKDIR/hash"
mkdir -p "$D"
echo "c" > "$D/status-skipped-c.txt"
mk_archive "$D" c
mk_meta "$D" c skipped
good=$(sha256sum "$D/c-1.0-1-x86_64.pkg.tar.zst" | awk '{print $1}')
if verify "$D" '["c"]' --hashes "{\"c\":\"$good\"}" > "$WORKDIR/hash-ok.out" 2>&1; then
  ok "matching expected checksum passes"
else
  bad "matching checksum failed: $(tail -3 "$WORKDIR/hash-ok.out")"
fi
badhex=$(printf '0%.0s' $(seq 1 64))
if verify "$D" '["c"]' --hashes "{\"c\":\"${badhex}\"}" > "$WORKDIR/hash-bad.out" 2>&1; then
  bad "checksum mismatch accepted"
else
  grep -q "checksum mismatch" "$WORKDIR/hash-bad.out" \
    && ok "checksum mismatch detected" || bad "checksum mismatch not detected: $(tail -3 "$WORKDIR/hash-bad.out")"
fi

# ---------------------------------------------------------------------------
note "cache: missing validation tools -> TOOL_UNAVAILABLE (not CORRUPT)"
D="$WORKDIR/tool"
mkdir -p "$D"
for name in d e f g h; do
  echo "$name" > "$D/status-skipped-$name.txt"
  mk_archive "$D" "$name"
  mk_meta "$D" "$name" skipped
done
NOBIN="$WORKDIR/nobin"
mkdir -p "$NOBIN"
# shims that exist on PATH but are not usable -> tool detection must fail
for tool in bsdtar tar; do
  printf '#!/usr/bin/env bash\necho "%s: command not found" >&2\nexit 127\n' "$tool" > "$NOBIN/$tool"
  chmod +x "$NOBIN/$tool"
done
if env PATH="$NOBIN:/usr/bin:/bin" bash "$REPO_ROOT/.github/scripts/verify-build-cache.sh" \
    --expected '["d","e","f","g","h"]' --results-dir "$D" > "$WORKDIR/tool.out" 2>&1; then
  bad "missing tools did not fail closed"
else
  grep -q '"tool_unavailable": 5' "$WORKDIR/tool.out" \
    && ok "tool-unavailable counted for all" || bad "tool_unavailable count wrong: $(grep tool_unavailable "$WORKDIR/tool.out")"
  ! grep -q "CORRUPT" "$WORKDIR/tool.out" \
    && ok "no false CORRUPT when tools missing" || bad "false CORRUPT reported"
  grep -q "required archive validation tool unavailable" "$WORKDIR/tool.out" \
    && ok "tool error classified as infrastructure error" || bad "tool error message missing"
fi

# ---------------------------------------------------------------------------
note "cache: GitHub Actions artifact merge layout (flat dir) validates"
D="$WORKDIR/layout"
mkdir -p "$D"
for name in i j k; do
  echo "$name" > "$D/status-skipped-$name.txt"
  mk_archive "$D" "$name"
  mk_meta "$D" "$name" skipped
done
if verify "$D" '["i","j","k"]' > "$WORKDIR/layout.out" 2>&1; then
  ok "flat merged artifact layout validates"
else
  bad "flat layout failed: $(tail -3 "$WORKDIR/layout.out")"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
