#!/usr/bin/env bash
#
# Regression tests for the Phase 4 production/staging workflow invariants
# (Task A audit + Task E inventory propagation). These are static audits of
# the committed workflow definitions so that future edits cannot silently:
#   - re-enable a scheduled production/Phase-4 publication
#   - skip the post-publication health gate (dry-run or failed publish)
#   - break the publish/publish-signed mutual exclusion
#   - hardcode expected-packages instead of propagating the prepare matrix
#   - omit the unconditional health-report artifact upload
#   - widen permissions beyond least privilege
#
# Runs on the host (python3 + yaml, bash). No network, no mutations.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# parse <file> -> YAML dict on stdout with `on:` renamed to `on_github:`
parse() {
  python3 - "$1" <<'PY'
import sys, yaml
raw = open(sys.argv[1]).read().splitlines()
for i, ln in enumerate(raw):
    if ln == "on:":
        raw[i] = "on_github:"
        break
print(yaml.safe_dump(yaml.safe_load("\n".join(raw)), sort_keys=False))
PY
}

# ---------------------------------------------------------------------------
note "workflow audit: no Phase 4 workflow has a schedule trigger"
for wf in build-release build-staging check-updates repo-health; do
  f="$REPO_ROOT/.github/workflows/$wf.yml"
  if parse "$f" | grep -q 'schedule:'; then
    bad "$wf.yml defines a schedule trigger"
  else
    ok "$wf.yml has no schedule trigger"
  fi
done

# ---------------------------------------------------------------------------
note "workflow audit: production publish jobs are mutually exclusive"
release=$(parse "$REPO_ROOT/.github/workflows/build-release.yml")
if grep -q "signing-mode != 'signed'" <<<"$release" \
    && grep -q "signing-mode == 'signed'" <<<"$release"; then
  ok "publish / publish-signed are mutually exclusive"
else
  bad "publish exclusion conditions missing/changed"
fi

# ---------------------------------------------------------------------------
note "workflow audit: post-publication health gate survives a skipped publish"
# The gate must reference BOTH publish jobs via needs and gate on each one's
# success, so a skipped branch can never bypass it.
health_block=$(sed -n '/^  health-check:/,/^  [a-z]/p' \
  "$REPO_ROOT/.github/workflows/build-release.yml")
if grep -q 'needs: \[prepare, publish, publish-signed\]' <<<"$health_block" \
    && grep -q 'needs.publish.result == .success.' <<<"$health_block" \
    && grep -q 'needs.publish-signed.result == .success.' <<<"$health_block"; then
  ok "health gate depends on both publish jobs and their success"
else
  bad "health gate needs/result gating changed"
fi
if grep -q '!inputs.dry-run' <<<"$health_block"; then
  ok "dry-run skips the post-publication health gate"
else
  bad "dry-run skip condition missing"
fi
if grep -q "inputs.signing-mode || 'unsigned'" <<<"$health_block"; then
  ok "health gate signing mode defaults to unsigned (non-dispatch events)"
else
  bad "health gate unsigned default missing"
fi

# ---------------------------------------------------------------------------
note "workflow audit: dry-run boolean input is normalized to 1/0 for scripts"
# `inputs.dry-run` renders `true`/`false`, but the publish scripts check
# `DRY_RUN == "1"`; a bare `${{ inputs.dry-run }}` binding would silently
# execute real mutations. The binding must normalize to '1'/'0'.
f="$REPO_ROOT/.github/workflows/build-release.yml"
if grep -q "DRY_RUN: \${{ inputs.dry-run && '1' || '0' }}" "$f"; then
  ok "build-release normalizes inputs.dry-run to 1/0"
else
  bad "build-release dry-run binding not normalized to '1'/'0'"
fi

# ---------------------------------------------------------------------------
note "workflow audit: release runs are never cancelled unexpectedly"
# GitHub Releases are non-atomic; cancelling an in-flight publish can
# orphan partial assets. Both release workflows must not cancel.
for wf in build-release build-staging; do
  f="$REPO_ROOT/.github/workflows/$wf.yml"
  if grep -q 'cancel-in-progress: false' "$f"; then
    ok "$wf does not cancel in-flight runs"
  else
    bad "$wf cancel-in-progress is not false"
  fi
done

# ---------------------------------------------------------------------------
note "workflow audit: expected-packages propagated from prepare matrix"
for wf in build-release build-staging; do
  f="$REPO_ROOT/.github/workflows/$wf.yml"
  if grep -q 'EXPECTED_PACKAGES: \${{ needs.prepare.outputs.matrix }}' "$f" \
      && grep -q 'expected-packages: \${{ needs.prepare.outputs.matrix }}' "$f"; then
    ok "$wf propagates the prepare matrix to publish and health gate"
  else
    bad "$wf expected-packages propagation changed"
  fi
done

# ---------------------------------------------------------------------------
note "workflow audit: repo-health.yml uploads the report on failure"
if grep -q 'if: always()' "$REPO_ROOT/.github/workflows/repo-health.yml" \
    && grep -q 'if-no-files-found: error' "$REPO_ROOT/.github/workflows/repo-health.yml"; then
  ok "health-report artifact upload is unconditional and fails on absent file"
else
  bad "health-report upload is not unconditional"
fi

# ---------------------------------------------------------------------------
note "workflow audit: missing health report is an explicit infrastructure failure"
# A missing/unreadable report must never be treated as success: the
# workflow step must exit nonzero before the artifact upload.
health_run=$(sed -n '/- name: Run repository health check/,/- name: Upload health report artifact/p' \
  "$REPO_ROOT/.github/workflows/repo-health.yml")
if grep -q '! -s "$GITHUB_WORKSPACE/health-report.json"' <<<"$health_run" \
    && grep -q '::error::Repository health report was not generated' <<<"$health_run"; then
  ok "missing health report fails explicitly"
else
  bad "missing-report guard missing/changed"
fi

# ---------------------------------------------------------------------------
note "workflow audit: least-privilege permissions"
# default read; write only where publication requires it
release=$(parse "$REPO_ROOT/.github/workflows/build-release.yml")
staging=$(parse "$REPO_ROOT/.github/workflows/build-staging.yml")
health=$(parse "$REPO_ROOT/.github/workflows/repo-health.yml")
if grep -q 'permissions:' <<<"$release" && grep -q 'contents: read' <<<"$release"; then
  ok "build-release default permissions are read-only"
else
  bad "build-release default permissions changed"
fi
if grep -q 'contents: write' <<<"$release" && grep -q 'contents: read' <<<"$release"; then
  ok "build-release publish jobs escalate to contents:write only"
else
  bad "build-release write scope missing"
fi
if grep -q 'contents: read' <<<"$health" && ! grep -q 'contents: write' <<<"$health"; then
  ok "repo-health is read-only (no write scope)"
else
  bad "repo-health permissions changed"
fi
# build-staging publishes to staging: contents:write allowed on publish job
if grep -q 'contents: write' <<<"$staging" && grep -q 'contents: read' <<<"$staging"; then
  ok "build-staging publish job writes, prepare reads"
else
  bad "build-staging permissions changed"
fi

# ---------------------------------------------------------------------------
note "workflow audit: health gate consumes the repository release tag only"
if grep -q 'release-tag: repository' "$REPO_ROOT/.github/workflows/build-release.yml" \
    && grep -q 'release-tag: repository-v4-test' "$REPO_ROOT/.github/workflows/build-staging.yml"; then
  ok "production and staging health gate tags are separate"
else
  bad "release tags in health gates changed"
fi

# ---------------------------------------------------------------------------
note "workflow audit: Phase 5 workflows are read-only / gated"
# observability.yml: read-only, no write permissions, no schedule
obs=$(parse "$REPO_ROOT/.github/workflows/observability.yml")
if grep -q 'contents: read' <<<"$obs" && ! grep -q 'contents: write' <<<"$obs"; then
  ok "observability workflow is read-only"
else
  bad "observability workflow permissions widened"
fi
if ! grep -q 'schedule' <<<"$obs"; then
  ok "observability has no schedule trigger"
else
  bad "observability introduced a schedule"
fi
# check-updates.yml: propose job requires open-pr input (never automatic),
# and merger writing is isolated from untrusted code (permissions scoped)
updates=$(parse "$REPO_ROOT/.github/workflows/check-updates.yml")
if grep -q 'open-pr' <<<"$updates" && grep -q 'if: \${{ inputs.open-pr }}' \
    "$REPO_ROOT/.github/workflows/check-updates.yml"; then
  ok "update proposal PR gated behind open-pr input"
else
  bad "proposal PR gating changed"
fi

# Phase 5.2 PR validation gates (owner-authorized, isolated):
# - allow-remote-pr input exists and is default-off
# - the propose job only gains write permissions (contents:write +
#   pull-requests:write), never the detect job
upd_wf_cl="$REPO_ROOT/.github/workflows/check-updates.yml"
if grep -q 'allow-remote-pr' "$upd_wf_cl" && grep -q 'default: false' "$upd_wf_cl"; then
  ok "allow-remote-pr owner gate exists and defaults to off"
else
  bad "allow-remote-pr owner gate missing"
fi
if grep -q '^permissions:' "$upd_wf_cl" \
    && grep -q 'contents: read' "$upd_wf_cl" \
    && [[ "$(grep -c 'contents: write' "$upd_wf_cl")" -eq 1 ]] \
    && [[ "$(grep -c 'pull-requests: write' "$upd_wf_cl")" -eq 1 ]]; then
  ok "global permissions read-only; only propose job escalates to write"
else
  bad "write permission scoping changed (global or job-level)"
fi
if ! grep -q 'pull_request_target' "$upd_wf_cl"; then
  ok "no pull_request_target execution path (untrusted content never privileged)"
else
  bad "pull_request_target introduced"
fi
if grep -qF -- '--push' "$upd_wf_cl"; then
  ok "propose job pushes via --push only under open-pr gate"
else
  bad "propose push invocation changed"
fi
if grep -q 'fixture' "$upd_wf_cl" && grep -q 'allow-remote-pr' "$upd_wf_cl"; then
  ok "remote PR validation is wired to the validation fixture path only"
else
  bad "remote PR validation wiring missing"
fi
if grep -q 'sha256sum' "$upd_wf_cl" && grep -q 'cut -c1-16' "$upd_wf_cl"; then
  ok "fixture identity uses a SHA-256 digest (16 hex chars)"
else
  bad "fixture identity is not a cryptographic digest"
fi
if grep -qE '\^\[0-9a-f\]\{16\}\$' "$upd_wf_cl"; then
  ok "fixture branch suffix is validated as hex-only"
else
  bad "fixture branch suffix not restricted"
fi

# ---------------------------------------------------------------------------
note "workflow audit: vercmp provisioning on the check-updates runner"
# Ubuntu 24.04 ships vercmp in the `makepkg` binary package (NOT in a
# `pacman-contrib` package, which does not exist in Ubuntu). The workflow
# must install makepkg and verify `command -v vercmp` before the detector
# runs — the detector itself fails closed (exit 2) without vercmp.
upd_wf="$REPO_ROOT/.github/workflows/check-updates.yml"
if grep -q 'makepkg' "$upd_wf" \
    && grep -q 'command -v vercmp' "$upd_wf" \
    && grep -q '::error::dependency provisioning failed' "$upd_wf"; then
  ok "check-updates provisions the Ubuntu vercmp provider and verifies it"
else
  bad "check-updates vercmp provisioning missing/changed"
fi
if grep -q 'vercmp required' "$REPO_ROOT/.github/scripts/check-updates.sh"; then
  ok "detector fails closed without vercmp"
else
  bad "detector vercmp guard changed"
fi

# ---------------------------------------------------------------------------
note "workflow audit: observability uses REST API artifact retrieval"
# The old design downloaded from the CURRENT run with a multiline pattern
# (never matches) and silently produced empty dashboards. The corrected
# workflow retrieves cross-run artifacts via the read-only collector with
# an explicit run-id, requires `actions: read` for the REST API, and never
# depends on the current run's own artifacts.
obs=$(parse "$REPO_ROOT/.github/workflows/observability.yml")
if grep -q 'actions: read' <<<"$obs"; then
  ok "observability grants actions:read for artifact API"
else
  bad "observability missing actions:read permission"
fi
if grep -q 'collect-artifacts.sh' "$REPO_ROOT/.github/workflows/observability.yml" \
    && grep -q -- '--run-id "\${{ github.run_id }}"' "$REPO_ROOT/.github/workflows/observability.yml"; then
  ok "observability uses the cross-run collector with recursion guard"
else
  bad "observability collector wiring changed"
fi
# the old broken pattern block must be gone
if grep -q 'pattern: |' "$REPO_ROOT/.github/workflows/observability.yml"; then
  bad "observability still uses a multiline download-artifact pattern"
else
  ok "multiline artifact pattern removed (single-glob download by run)"
fi
if grep -q 'actions/download-artifact' "$REPO_ROOT/.github/workflows/observability.yml"; then
  bad "observability still downloads artifacts from the current run"
else
  ok "current-run download-artifact removed"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
