#!/usr/bin/env bash
#
# Security + behaviour regression tests for .github/scripts/generate-matrix.sh
# — the single matrix/validation implementation used by BOTH workflows.
#
# The workflows only bind untrusted `inputs.*` into environment variables and
# invoke this script, so exercising the script directly with hostile env
# values is exactly the regression test for the expression-injection fix.
#
# Covers: valid inputs, malformed names, shell injection, embedded newlines,
# whitespace, duplicates, empty lists, missing PKGBUILD dirs, unauthorized
# critical requests, bad allow-critical entries, scheduled-run bypass
# attempts, missing production confirmation, staging/production separation.
#
# Requires: bash, jq, sed. No network, no GitHub, no release mutation.

set -uo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# -- sandbox: packages.txt + a PKGBUILD for every listed package ------------
SANDBOX="$WORKDIR/repo"
mkdir -p "$SANDBOX"
cp "$REPO_ROOT/packages.txt" "$SANDBOX/packages.txt"
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  entry="$(printf '%s' "$raw_line" | sed 's/#.*//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "$entry" ]] || continue
  pkg="${entry#local:}"
  mkdir -p "$SANDBOX/$pkg"
  printf 'pkgname=%s\n' "$pkg" > "$SANDBOX/$pkg/PKGBUILD"
done < "$SANDBOX/packages.txt"
TOTAL_PKGS=$(find "$SANDBOX" -maxdepth 2 -name PKGBUILD | wc -l | tr -d ' ')

GH_OUT="$WORKDIR/gh-output"
GH_SUM="$WORKDIR/gh-summary"

# run_matrix <mode> <event> [VAR=VAL ...]
# Writes stdout+stderr to $WORKDIR/last.out; returns the script's exit code.
run_matrix() {
  local mode="$1" event="$2"; shift 2
  : > "$GH_OUT"; : > "$GH_SUM"
  (
    cd "$SANDBOX"
    env -i \
      PATH="$PATH" \
      HOME="$HOME" \
      GITHUB_WORKSPACE="$REPO_ROOT" \
      GITHUB_OUTPUT="$GH_OUT" \
      GITHUB_STEP_SUMMARY="$GH_SUM" \
      MODE="$mode" \
      EVENT_NAME="$event" \
      RELEASE_TAG="$([[ "$mode" == staging ]] && echo repository-v4-test || echo repository)" \
      "$@" \
      bash "$REPO_ROOT/.github/scripts/generate-matrix.sh"
  ) > "$WORKDIR/last.out" 2>&1
  echo $?
}

matrix() { grep '^matrix=' "$GH_OUT" | cut -d= -f2-; }

# expect <label> <rc> <want-rc> [needle]
expect_rc() {
  local label="$1" rc="$2" want="$3" needle="${4:-}"
  if [[ "$rc" -eq "$want" ]]; then
    ok "$label (exit $want)"
  else
    bad "$label: expected exit $want, got $rc"
  fi
  if [[ -n "$needle" ]]; then
    if grep -q -- "$needle" "$WORKDIR/last.out"; then
      ok "$label: output contains '$needle'"
    else
      bad "$label: output missing '$needle'"
    fi
  fi
}

# ---------------------------------------------------------------------------
note "staging: valid default input (empty -> canonical smoke set)"
rc=$(run_matrix staging workflow_dispatch INPUT_PACKAGES= INPUT_INCLUDE_KSUPERKEY=false)
expect_rc "staging default" "$rc" 0
[[ "$(matrix)" == '["nmtui-go","osu-mime"]' ]] && ok "default matrix nmtui-go,osu-mime" || bad "default matrix: $(matrix)"

# ---------------------------------------------------------------------------
note "staging: explicit valid list"
rc=$(run_matrix staging workflow_dispatch INPUT_PACKAGES="nmtui-go,osu-mime,ksuperkey")
expect_rc "staging explicit" "$rc" 0
[[ "$(matrix)" == '["nmtui-go","osu-mime","ksuperkey"]' ]] && ok "explicit matrix" || bad "explicit matrix: $(matrix)"

# include-ksuperkey=true appends ksuperkey
rc=$(run_matrix staging workflow_dispatch INPUT_PACKAGES="nmtui-go" INPUT_INCLUDE_KSUPERKEY=true)
expect_rc "staging include-ksuperkey" "$rc" 0
[[ "$(matrix)" == '["nmtui-go","ksuperkey"]' ]] && ok "include-ksuperkey appends" || bad "include-ksuperkey: $(matrix)"

# ---------------------------------------------------------------------------
note "staging: whitespace, duplicates, empty entries"
rc=$(run_matrix staging workflow_dispatch INPUT_PACKAGES="  nmtui-go , osu-mime ,,  ")
expect_rc "staging whitespace+empties" "$rc" 0
[[ "$(matrix)" == '["nmtui-go","osu-mime"]' ]] && ok "whitespace trimmed, empties dropped" || bad "got: $(matrix)"

rc=$(run_matrix staging workflow_dispatch INPUT_PACKAGES="nmtui-go,nmtui-go,osu-mime,nmtui-go")
expect_rc "staging duplicates deduped" "$rc" 0
[[ "$(matrix)" == '["nmtui-go","osu-mime"]' ]] && ok "duplicates deduped deterministically" || bad "got: $(matrix)"

# ---------------------------------------------------------------------------
note "staging: empty list rejected"
rc=$(run_matrix staging workflow_dispatch INPUT_PACKAGES=" , , ")
expect_rc "staging empty" "$rc" 1 "No valid packages"

# ---------------------------------------------------------------------------
note "staging: nonexistent PKGBUILD directory rejected"
rc=$(run_matrix staging workflow_dispatch INPUT_PACKAGES="definitely-not-a-package")
expect_rc "staging missing pkgbuild" "$rc" 1 "no PKGBUILD directory"

# ---------------------------------------------------------------------------
note "staging: malformed names rejected"
for badpkg in 'pkg;id' 'pkg$(id)' 'pkg`id`' 'pkg|id' 'pkg/../etc' 'pkg name' 'pkg*' 'pkg&id' 'pkg>out' 'pkg"quote'; do
  rc=$(run_matrix staging workflow_dispatch INPUT_PACKAGES="$badpkg")
  if [[ "$rc" -eq 1 ]] && grep -q "Invalid package name" "$WORKDIR/last.out"; then
    ok "rejected: $badpkg"
  else
    bad "NOT rejected: $badpkg (rc=$rc)"
  fi
done

# ---------------------------------------------------------------------------
note "staging: shell injection attempts cannot execute"
INJECT_MARK="$WORKDIR/INJECTED"
rm -f "$INJECT_MARK"
for payload in "nmtui-go;\$(touch $INJECT_MARK)" "nmtui-go\`touch $INJECT_MARK\`" "\$(touch $INJECT_MARK)" "nmtui-go\$(id)" "'; touch $INJECT_MARK; echo '"; do
  rc=$(run_matrix staging workflow_dispatch INPUT_PACKAGES="$payload")
  [[ "$rc" -eq 1 ]] || bad "injection payload accepted (rc=$rc): $payload"
done
if [[ ! -e "$INJECT_MARK" ]]; then
  ok "no injection payload executed (marker absent)"
else
  bad "SECURITY: injection payload executed — marker created"
fi

# ---------------------------------------------------------------------------
note "staging: embedded newlines"
# a newline inside the value must not smuggle a second command
rc=$(run_matrix staging workflow_dispatch "INPUT_PACKAGES=nmtui-go
\$(touch $INJECT_MARK)")
expect_rc "staging newline payload" "$rc" 1
[[ ! -e "$INJECT_MARK" ]] && ok "newline payload not executed" || bad "SECURITY: newline payload executed"
# a newline-separated valid list is a single malformed entry (rejected)
rc=$(run_matrix staging workflow_dispatch "INPUT_PACKAGES=nmtui-go
osu-mime")
expect_rc "staging newline list rejected" "$rc" 1 "embedded newline"

# ---------------------------------------------------------------------------
note "staging: system-critical packages forbidden (complete list)"
while IFS= read -r crit; do
  [[ -n "$crit" ]] || continue
  rc=$(run_matrix staging workflow_dispatch "INPUT_PACKAGES=$crit")
  if [[ "$rc" -eq 1 ]] && grep -qE "forbidden in staging|no PKGBUILD directory" "$WORKDIR/last.out"; then
    ok "staging rejects critical: $crit"
  else
    bad "staging ACCEPTED critical: $crit (rc=$rc)"
  fi
done < <(bash -c 'source "$0/.github/scripts/critical-packages.sh"; printf "%s\n" "${CRITICAL_PACKAGES[@]}"' "$REPO_ROOT")

# ---------------------------------------------------------------------------
note "production: confirmation gate"
rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION=no INPUT_PACKAGES=)
expect_rc "missing confirmation" "$rc" 1 "confirm-production"
rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION= INPUT_PACKAGES=)
expect_rc "empty confirmation" "$rc" 1 "confirm-production"

# ---------------------------------------------------------------------------
note "production: full matrix excludes critical by default"
rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION=YES INPUT_PACKAGES= INPUT_ALLOW_CRITICAL=)
expect_rc "production full" "$rc" 0
MATRIX="$(matrix)"
echo "  ($TOTAL_PKGS PKGBUILD dirs on disk; matrix size $(printf '%s' "$MATRIX" | jq 'length'))"
if printf '%s' "$MATRIX" | jq -e 'any(. == "linux-nanoka" or . == "pacman" or . == "nvidia-utils" or . == "lib32-nvidia-utils" or . == "xlibre-xserver" or . == "xlibre-xserver-src" or . == "xlibre-input-libinput" or . == "networkmanager-iwd")' >/dev/null 2>&1; then
  bad "critical package present in default production matrix"
else
  ok "no critical packages in default production matrix"
fi
printf '%s' "$MATRIX" | jq -e 'any(. == "nmtui-go")' >/dev/null 2>&1 && ok "noncritical packages present" || bad "noncritical missing"
grep -q 'excluded_bases_file' "$GH_OUT" && ok "excluded-bases file recorded" || bad "excluded-bases missing"
[[ -f "$SANDBOX/output-excluded-bases.txt" ]] && ok "output-excluded-bases.txt written" || bad "output-excluded-bases.txt missing"

# ---------------------------------------------------------------------------
note "production: subset validation"
rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION=YES INPUT_PACKAGES="nmtui-go,osu-mime" INPUT_ALLOW_CRITICAL=)
expect_rc "valid subset" "$rc" 0
[[ "$(matrix)" == '["nmtui-go","osu-mime"]' ]] && ok "subset exact" || bad "subset: $(matrix)"
rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION=YES INPUT_PACKAGES="nmtui-go,not-real" INPUT_ALLOW_CRITICAL=)
expect_rc "unknown subset name" "$rc" 1 "not listed in packages.txt"

# ---------------------------------------------------------------------------
note "production: critical requests and approvals"
# linux-nanoka was removed from packages.txt (still critical); use
# networkmanager-iwd, an inventory-resident critical package, for approval
# semantics tests.
rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION=YES INPUT_PACKAGES="networkmanager-iwd" INPUT_ALLOW_CRITICAL=)
expect_rc "requested critical w/o approval" "$rc" 1 "requires explicit approval"

rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION=YES INPUT_PACKAGES="networkmanager-iwd,osu-mime" INPUT_ALLOW_CRITICAL="networkmanager-iwd")
expect_rc "critical with approval" "$rc" 0
printf '%s' "$(matrix)" | jq -e 'any(. == "networkmanager-iwd")' >/dev/null 2>&1 && ok "approved critical included" || bad "approved critical missing: $(matrix)"

rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION=YES INPUT_PACKAGES= INPUT_ALLOW_CRITICAL="not-a-critical-pkg")
expect_rc "invalid allow-critical" "$rc" 1 "not a known system-critical package"

# wildcard / prefix tricks must not expand the approval set
for trick in '*' 'lib32-*' 'xlibre' 'linux-nanok' 'networkmanager'; do
  rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION=YES INPUT_PACKAGES= INPUT_ALLOW_CRITICAL="$trick")
  if [[ "$rc" -eq 1 ]]; then ok "allow-critical rejects '$trick'"; else bad "allow-critical ACCEPTED '$trick' (rc=$rc)"; fi
done

# malformed allow-critical is rejected by name validation (fail-closed)
rc=$(run_matrix production workflow_dispatch INPUT_CONFIRM_PRODUCTION=YES INPUT_PACKAGES= INPUT_ALLOW_CRITICAL='networkmanager-iwd;$(id)')
expect_rc "allow-critical injection" "$rc" 1 "Invalid package name"

# ---------------------------------------------------------------------------
note "production: scheduled path"
rc=$(run_matrix production schedule ALLOW_SCHEDULED_PRODUCTION=no)
expect_rc "schedule unauthorized" "$rc" 1 "not authorized"
rc=$(run_matrix production schedule ALLOW_SCHEDULED_PRODUCTION=yes)
expect_rc "schedule authorized" "$rc" 0
if printf '%s' "$(matrix)" | jq -e 'any(. == "linux-nanoka" or . == "pacman" or . == "networkmanager-iwd")' >/dev/null 2>&1; then
  bad "critical package in scheduled matrix"
else
  ok "no critical packages in scheduled matrix"
fi
# inputs smuggled into a scheduled run must be ignored entirely
rc=$(run_matrix production schedule ALLOW_SCHEDULED_PRODUCTION=yes INPUT_PACKAGES="linux-nanoka" INPUT_ALLOW_CRITICAL="linux-nanoka" INPUT_CONFIRM_PRODUCTION=YES)
expect_rc "schedule ignores inputs" "$rc" 0
if printf '%s' "$(matrix)" | jq -e 'any(. == "linux-nanoka")' >/dev/null 2>&1; then
  bad "SECURITY: scheduled run accepted a critical package via inputs"
else
  ok "scheduled run ignores inputs (no critical)"
fi

# ---------------------------------------------------------------------------
note "mode sanity: unknown mode fails closed"
rc=$(run_matrix bogus workflow_dispatch)
expect_rc "unknown mode" "$rc" 1 "Unknown MODE"

# ---------------------------------------------------------------------------
note "release separation: staging and production tags/groups are distinct"
grep -q 'RELEASE_TAG: repository-v4-test' "$REPO_ROOT/.github/workflows/build-staging.yml" \
  && ok "staging tag is repository-v4-test" || bad "staging tag mismatch"
grep -q 'RELEASE_TAG: repository$' "$REPO_ROOT/.github/workflows/build-release.yml" \
  && ok "production tag is repository" || bad "production tag mismatch"
grep -q 'group: release-repo-v4-test' "$REPO_ROOT/.github/workflows/build-staging.yml" \
  && ok "staging concurrency group distinct" || bad "staging concurrency group mismatch"
grep -q 'group: release-repo$' "$REPO_ROOT/.github/workflows/build-release.yml" \
  && ok "production concurrency group distinct" || bad "production concurrency group mismatch"

# ---------------------------------------------------------------------------
note "critical list is single-sourced (no duplicated literal list in workflows)"
if grep -q 'CRITICAL_PACKAGES' "$REPO_ROOT/.github/workflows/build-release.yml" "$REPO_ROOT/.github/workflows/build-staging.yml" 2>/dev/null; then
  bad "workflow still contains an inline critical list"
else
  ok "workflows reference the shared list only"
fi
[[ -f "$REPO_ROOT/.github/scripts/critical-packages.sh" ]] && ok "critical-packages.sh present" || bad "critical-packages.sh missing"
# the shared list must cover every critical package (incl. xlibre-xserver-src)
for must in pacman nvidia-utils lib32-nvidia-utils xlibre-xserver xlibre-xserver-src xlibre-input-libinput linux-nanoka networkmanager-iwd; do
  bash -c 'source "$0"; printf "%s\n" "${CRITICAL_PACKAGES[@]}"' "$REPO_ROOT/.github/scripts/critical-packages.sh" | grep -qx "$must" \
    && ok "critical list contains $must" || bad "critical list MISSING $must"
done

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
