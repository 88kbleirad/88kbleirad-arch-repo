#!/usr/bin/env bash
#
# Regression tests for the PRODUCTION prepare-job logic in build-release.yml:
#   - approval gate (manual runs require confirm-production=YES)
#   - schedule authorization gate (separate, explicitly authorized path)
#   - matrix generation from packages.txt (single source of truth)
#   - system-critical package exclusion (default) / explicit approval
#   - subset validation (requested packages must exist in packages.txt)
#   - refusal of unknown/critical requests without approval
#
# The step bodies are extracted verbatim from build-release.yml and run
# exactly as shipped (token substitution per the mock harness contract), so
# this suite guards the real workflow logic, not a copy.
#
# Requires: python3, jq, bash. Run from anywhere with REPO_ROOT set.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKFLOW="$REPO_ROOT/.github/workflows/build-release.yml"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# Extract the body of a named step from build-release.yml as a bash
# fragment with ${{ ... }} tokens substituted from the environment.
# Secure (quoted) form: `${{ inputs.X }}` -> "${INPUT_X:-}" style.
# In the real workflow these are GitHub expression results, i.e. plain
# strings; we substitute the environment variable of the same name.
extract_step() {
  python3 - "$WORKFLOW" "$1" <<'PY'
import sys, yaml, os
path, step_name = sys.argv[1], sys.argv[2]
# "on:" at top level parses as boolean True under PyYAML 1.1; the step
# bodies we need live under jobs, so we only parse that subtree by
# working on the raw text via a small fixup.
with open(path) as fh:
    raw = fh.read()
lines = raw.splitlines()
for i, ln in enumerate(lines):
    if ln == "on:":
        lines[i] = "on_github:"
        break
data = yaml.safe_load("\n".join(lines))
jobs = data["jobs"]
body = None
for job in jobs.values():
    for step in job.get("steps", []):
        if step.get("name") == step_name and "run" in step:
            body = step["run"]
            break
    if body is not None:
        break
if body is None:
    sys.stderr.write("step not found: %s\n" % step_name)
    sys.exit(2)
print(body)
PY
}

run_scenario() {
  # usage: run_scenario <name> <script>
  local name="$1" script="$2" rc
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  bash -c "$script" > "$WORKDIR/$name.out" 2>&1
  rc=$?
  echo "EXIT=$rc" >> "$WORKDIR/$name.out"
  return 0
}

sed_escape() { printf '%s' "$1" | sed 's/[\/&]/\\&/g'; }

# pre-substitute the workflow expressions in the bodies
CONFIRM_STEP=$(extract_step "Require explicit production confirmation (manual mode)" \
  | sed -e "s/\${{ github.event.inputs.confirm-production }}/\${INPUT_CONFIRM_PRODUCTION:-}/g")
SCHED_STEP=$(extract_step "Schedule authorization gate (weekly path)" \
  | sed -e "s/\${{ vars.ALLOW_SCHEDULED_PRODUCTION }}/\${ALLOW_SCHEDULED_PRODUCTION:-}/g")
MATRIX_STEP=$(extract_step "Generate matrix from packages.txt (single source of truth)" \
  | sed -e "s/\${{ github.event_name }}/\${EVENT_NAME:-}/g" \
        -e "s/\${{ inputs.allow-critical }}/\${INPUT_ALLOW_CRITICAL:-}/g" \
        -e "s/\${{ inputs.packages }}/\${INPUT_PACKAGES:-}/g")

GITHUB_OUTPUT="$WORKDIR/gh-output"
GITHUB_STEP_SUMMARY="$WORKDIR/gh-summary"

run_prepare() {
  # usage: run_prepare <scenario> <event> <confirm> <packages> <allow-critical> [schedule-var]
  local scenario="$1" event="$2" confirm="$3" pkgs="$4" allow="${5:-}" schedvar="${6:-}"
  local sandbox="$WORKDIR/sandbox-$scenario"
  rm -rf "$sandbox"; mkdir -p "$sandbox"
  ( cd "$REPO_ROOT" && tar cf - packages.txt $(sed 's/#.*//;s/^local://' packages.txt | xargs) 2>/dev/null ) | ( cd "$sandbox" && tar xf - )
  local script
  script="set -euo pipefail
cd '$sandbox'
export GITHUB_OUTPUT='$GITHUB_OUTPUT'
export GITHUB_STEP_SUMMARY='$GITHUB_STEP_SUMMARY'
export EVENT_NAME='$event'
export INPUT_CONFIRM_PRODUCTION='$confirm'
export INPUT_PACKAGES='$pkgs'
export INPUT_ALLOW_CRITICAL='$allow'
"
  if [[ "$event" == "workflow_dispatch" ]]; then
    script+="$CONFIRM_STEP\n"
  else
    script+="export ALLOW_SCHEDULED_PRODUCTION='$schedvar'\n"
    script+="$SCHED_STEP\n"
  fi
  script+="$MATRIX_STEP\n"
  run_scenario "$scenario" "$(printf '%b' "$script")"
  # remember the scenario name for expect_exit (locals are gone)
  echo "$scenario" > "$WORKDIR/.last-scenario"
  # parse the emitted matrix JSON (empty when the step failed early)
  grep '^matrix=' "$GITHUB_OUTPUT" | cut -d= -f2- > "$WORKDIR/matrix.json" || true
}

matrix_count() { jq 'length' "$WORKDIR/matrix.json" 2>/dev/null || echo -1; }

expect_exit() {
  # usage: expect_exit <expected-rc> <needle> [scenario]
  local want="$1" needle="$2" scenario="${3:-}"
  [[ -z "$scenario" ]] && scenario=$(cat "$WORKDIR/.last-scenario")
  local rc=0
  grep -q '^EXIT=' "$WORKDIR/$scenario.out" && rc=$(sed -n 's/^EXIT=//p' "$WORKDIR/$scenario.out" | tail -1)
  if [[ "$rc" -eq "$want" ]]; then
    ok "exit ${want}"
  else
    bad "expected exit ${want}, got ${rc}"
  fi
  if [[ -n "$needle" ]] && grep -q "$needle" "$WORKDIR/$scenario.out"; then
    ok "output contains: $needle"
  elif [[ -n "$needle" ]]; then
    bad "output missing: $needle"
  fi
}

# ---------------------------------------------------------------------------
note "manual run without confirm-production=YES must fail"
rc=$(run_prepare no-confirm workflow_dispatch "" "" "")
expect_exit 1 "confirm-production" no-confirm

# ---------------------------------------------------------------------------
note "schedule run without ALLOW_SCHEDULED_PRODUCTION must fail"
rc=$(run_prepare sched-noauth schedule "" "" "" "")
expect_exit 1 "not authorized" sched-noauth

# ---------------------------------------------------------------------------
note "schedule run with ALLOW_SCHEDULED_PRODUCTION=yes passes gate"
rc=$(run_prepare sched-auth schedule "" "" "" yes)
expect_exit 0 "authorized" sched-auth

# ---------------------------------------------------------------------------
note "full manual matrix excludes system-critical packages by default"
rc=$(run_prepare full workflow_dispatch YES "" "")
expect_exit 0 "" full
MATRIX=$(jq -c . "$WORKDIR/matrix.json" 2>/dev/null || echo "[]")
echo "  matrix: $MATRIX"
if echo "$MATRIX" | jq -e 'any(. == "linux-nanoka" or . == "nvidia-utils" or . == "pacman" or . == "networkmanager-iwd")' >/dev/null 2>&1; then
  bad "critical package present in default matrix"
else
  ok "no critical packages in default matrix"
fi
if echo "$MATRIX" | jq -e 'any(. == "nmtui-go" or . == "osu-mime" or . == "magika")' >/dev/null 2>&1; then
  ok "noncritical packages present"
else
  bad "noncritical package missing from default matrix"
fi
if grep -q "linux-nanoka" "$WORKDIR/gh-output" && grep -q "excluded" "$WORKDIR/gh-output"; then
  ok "excluded bases flow to output"
else
  bad "excluded output missing"
fi
if [[ -f "$WORKDIR/sandbox-full/output-excluded-bases.txt" ]]; then
  ok "excluded-bases file written"
else
  bad "excluded-bases file missing"
fi

# ---------------------------------------------------------------------------
note "subset run: requested valid package is included"
rc=$(run_prepare subset workflow_dispatch YES "nmtui-go,osu-mime" "")
expect_exit 0 "" subset
MATRIX=$(jq -c . "$WORKDIR/matrix.json" 2>/dev/null || echo "[]")
if echo "$MATRIX" | jq -e '. == ["nmtui-go","osu-mime"]' >/dev/null 2>&1; then
  ok "subset matrix exact"
else
  bad "subset matrix wrong: $MATRIX"
fi

# ---------------------------------------------------------------------------
note "subset run: unknown package must be refused"
rc=$(run_prepare subset-unknown workflow_dispatch YES "nmtui-go,not-a-package" "")
expect_exit 1 "not listed in packages.txt" subset-unknown

# ---------------------------------------------------------------------------
note "subset run: requested critical package without approval must fail"
rc=$(run_prepare subset-critical workflow_dispatch YES "linux-nanoka" "")
expect_exit 1 "requires explicit approval" subset-critical

# ---------------------------------------------------------------------------
note "subset run: requested critical package with allow-critical passes"
rc=$(run_prepare subset-critical-ok workflow_dispatch YES "linux-nanoka,osu-mime" "linux-nanoka")
expect_exit 0 "" subset-critical-ok
MATRIX=$(jq -c . "$WORKDIR/matrix.json" 2>/dev/null || echo "[]")
if echo "$MATRIX" | jq -e 'any(. == "linux-nanoka")' >/dev/null 2>&1; then
  ok "approved critical package included"
else
  bad "approved critical package missing: $MATRIX"
fi

# ---------------------------------------------------------------------------
note "invalid allow-critical value must be refused"
rc=$(run_prepare allow-invalid workflow_dispatch YES "" "not-critical-at-all")
expect_exit 1 "not a known system-critical package" allow-invalid

# ---------------------------------------------------------------------------
note "scheduled run must never include critical packages and rejects inputs"
rc=$(run_prepare sched-matrix schedule "" "" "" yes)
expect_exit 0 "" sched-matrix
MATRIX=$(jq -c . "$WORKDIR/matrix.json" 2>/dev/null || echo "[]")
if echo "$MATRIX" | jq -e 'any(. == "linux-nanoka" or . == "nvidia-utils" or . == "pacman")' >/dev/null 2>&1; then
  bad "critical package present in scheduled matrix"
else
  ok "no critical packages in scheduled matrix"
fi
# scheduled runs have no inputs; simulate an attempt to smuggle one
rc=$(run_prepare sched-inputs schedule "" "linux-nanoka" "" yes)
expect_exit 0 "" sched-inputs
MATRIX=$(jq -c . "$WORKDIR/matrix.json" 2>/dev/null || echo "[]")
if echo "$MATRIX" | jq -e 'any(. == "linux-nanoka")' >/dev/null 2>&1; then
  bad "scheduled matrix accepted a critical package via inputs"
else
  ok "scheduled run ignores inputs"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
