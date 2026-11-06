#!/usr/bin/env bash
#
# Full validation harness for the 88kbleirad publish pipeline.
#
# Runs:
#   1. bash syntax check on every script in the repository
#   2. YAML validation of all GitHub workflow files
#   3. matrix gate tests (approval/schedule/critical-exclusion/subset)
#      — runs on the host (bash + python + jq only)
#   4. signing + publish E2E against the mock gh release — runs inside
#      the pinned generic Arch container (root, pacman available)
#   5. container build tests — real build in the pinned image with the
#      v4 compiler profile: packager metadata, packager gate, cache hit
#
# Usage: REPO_ROOT=<path> bash .github/tests/run-tests.sh
#
# Nothing here pushes, triggers workflows, or touches real releases.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
IMAGE="ghcr.io/archlinux/archlinux@sha256:644576e90a71df3b137df2ab6b3517ecd045418195c1946c2c11d1c0564a7981"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker pull "$IMAGE" >/dev/null
fi

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# -- 1. bash syntax --------------------------------------------------------
note "bash syntax: all scripts"
for f in "$REPO_ROOT"/.github/scripts/*.sh "$REPO_ROOT"/.github/tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then
    ok "syntax: $(basename "$f")"
  else
    bad "syntax: $(basename "$f")"
  fi
done

# -- 2. YAML validation ----------------------------------------------------
note "YAML validation: workflows"
python3 - "$REPO_ROOT" <<'PY'
import sys, yaml
root = sys.argv[1]
import glob
files = sorted(glob.glob(root + "/.github/workflows/*.yml"))
if not files:
    raise SystemExit("no workflow files found")
for f in files:
    raw = open(f).read().splitlines()
    for i, ln in enumerate(raw):
        if ln == "on:":
            raw[i] = "on_github:"
            break
    data = yaml.safe_load("\n".join(raw))
    assert isinstance(data, dict) and "jobs" in data, f
    print("OK:", f)
PY

# -- 2b. actionlint (when available) ----------------------------------------
if command -v actionlint >/dev/null 2>&1; then
  note "actionlint: workflows"
  if actionlint "$REPO_ROOT"/.github/workflows/*.yml; then
    ok "actionlint clean"
  else
    bad "actionlint reported issues"
  fi
else
  echo "  (actionlint not installed; skipped)"
fi

# -- 3. standalone host suite (lib + matrix) -------------------------------
note "standalone host suite (gh-release-lib + matrix gates)"
# The publish-prod scenarios in test-http500.sh require the pinned Arch
# container (repo-add must run as root and pacman-contrib must exist). They
# are executed by step 5 below inside the container; the host run MUST skip
# them explicitly (never inherit RUN_PROD_SCENARIOS from the caller's
# environment, which would attempt them as an unprivileged host user).
if RUN_PROD_SCENARIOS=0 bash "$REPO_ROOT/.github/tests/test-http500.sh"; then
  ok "host suite (lib retries + inventory logic)"
else
  bad "host suite"
fi

# -- 3b. content-aware + build-cache host suites ----------------------------
note "content-aware publishing suite"
if bash "$REPO_ROOT/.github/tests/test-content-aware.sh"; then
  ok "content-aware publishing suite"
else
  bad "content-aware publishing suite"
fi

note "build-cache verification suite"
if bash "$REPO_ROOT/.github/tests/test-build-cache.sh"; then
  ok "build-cache verification suite"
else
  bad "build-cache verification suite"
fi

note "rustc v4 build-script wrapper suite"
if bash "$REPO_ROOT/.github/tests/test-rustc-wrapper.sh"; then
  ok "rustc wrapper suite"
else
  bad "rustc wrapper suite"
fi

note "epoch-aware archive filename suite"
if bash "$REPO_ROOT/.github/tests/test-epoch-filenames.sh"; then
  ok "epoch-aware archive filename suite"
else
  bad "epoch-aware archive filename suite"
fi

note "update-detection safety suite"
if bash "$REPO_ROOT/.github/tests/test-check-updates.sh"; then
  ok "update-detection safety suite"
else
  bad "update-detection safety suite"
fi

note "workflow-audit suite (triggers / gate / permissions / inventory)"
if bash "$REPO_ROOT/.github/tests/test-workflow-audit.sh"; then
  ok "workflow-audit suite"
else
  bad "workflow-audit suite"
fi

note "update-proposal suite (Phase 5.2; offline, deterministic)"
if bash "$REPO_ROOT/.github/tests/test-propose-updates.sh"; then
  ok "update-proposal suite"
else
  bad "update-proposal suite"
fi

note "dashboard suite (Phase 5.3; static build + metrics)"
if bash "$REPO_ROOT/dashboard/tests/test-metrics.sh"; then
  ok "metrics-builder suite"
else
  bad "metrics-builder suite"
fi
if bash "$REPO_ROOT/dashboard/tests/test-dashboard.sh"; then
  ok "dashboard-build suite"
else
  bad "dashboard-build suite"
fi

# -- 4. matrix gate tests ---------------------------------------------------
note "matrix gate tests (approval / schedule / critical / subset)"
if bash "$REPO_ROOT/.github/tests/test-matrix.sh"; then
  ok "matrix gate suite"
else
  bad "matrix gate suite"
fi

# -- 5. signing + publish E2E in the pinned container -----------------------
note "signing + publish E2E (container, mock gh)"
if docker run --rm \
    --mount type=bind,source="$REPO_ROOT",target="$REPO_ROOT" \
    -e REPO_ROOT="$REPO_ROOT" \
    --workdir "$REPO_ROOT" \
    "$IMAGE" bash -c '
        set -euo pipefail
        pacman -Syu --noconfirm --needed \
          gnupg jq libarchive pacman-contrib base-devel git
        bash "$REPO_ROOT/.github/tests/test-signing.sh"
        EXPECTED_PACKAGES="[\"testa\",\"testb\"]" bash "$REPO_ROOT/.github/tests/test-signing-mode.sh"
        RUN_PROD_SCENARIOS=1 bash "$REPO_ROOT/.github/tests/test-http500.sh"
        bash "$REPO_ROOT/.github/tests/test-verify-remote.sh"
        bash "$REPO_ROOT/.github/tests/test-repo-health.sh"
      '; then
  ok "signing + host-prod suite"
else
  bad "signing + host-prod suite"
fi

# -- 6. container build/cache/packager tests --------------------------------
note "container build tests (packager metadata, gate, cache hit)"
if bash "$REPO_ROOT/.github/tests/run-container-tests.sh"; then
  ok "container build suite"
else
  bad "container build suite"
fi

# ---------------------------------------------------------------------------
echo
echo "overall: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
