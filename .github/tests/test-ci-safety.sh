#!/usr/bin/env bash
#
# CI validation safety tests (Phase 8.1.1) — CI01..CI16.
#
# Deterministic, offline. Asserts properties of the CI workflow and of
# the repository's release-safety invariants. Does NOT require GitHub
# events; live PR-check behavior must be confirmed on a real PR.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

WF="$REPO_ROOT/.github/workflows/ci-validation.yml"
[[ -f "$WF" ]] || { bad "ci-validation.yml missing"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# -- CI01: PR trigger targets main ------------------------------------------
note "CI01: PR trigger targets main"
if grep -qE "pull_request:" "$WF" && grep -qE "branches:" "$WF" && grep -q "main" "$WF"; then
  ok "pull_request trigger with main branch filter"
else
  bad "pull_request trigger missing or not targeting main"
fi

# -- CI09/CI10/CI12: security posture --------------------------------------
note "CI09/CI10/CI12: read-only permissions, no pull_request_target, no secrets"
if grep -qE "pull_request_target" "$WF"; then
  bad "workflow uses pull_request_target (forbidden)"
else
  ok "no pull_request_target"
fi
if grep -qE "permissions:" "$WF" && grep -q "contents: read" "$WF"; then
  ok "contents: read permission"
else
  bad "contents: read permission missing"
fi
if grep -qE "secrets:|GPG_PRIVATE_KEY|GPG_KEY_CONTENT|GPG_PASSPHRASE" "$WF"; then
  bad "workflow references signing secrets"
else
  ok "no signing secrets referenced"
fi
if grep -qE "GITHUB_TOKEN" "$WF"; then
  # GH_TOKEN usage is allowed for API read calls but the default token is
  # read-only by workflow permissions; flag any explicit usage for review.
  echo "  (note: GITHUB_TOKEN referenced; permissions remain read-only)"
fi

# -- CI11: no release mutation ----------------------------------------------
note "CI11: workflow must not mutate releases"
if grep -qE "gh release|publish-prod|publish-stage|build-release.yml|build-staging.yml|GH_TOKEN" "$WF"; then
  bad "workflow references release mutation paths"
else
  ok "no release mutation paths referenced"
fi

# -- CI13: acceptance fails on skipped deps ---------------------------------
note "CI13: ci-acceptance uses if: always() and checks needs results"
if grep -q "ci-acceptance" "$WF" && grep -q "if: always()" "$WF"; then
  ok "acceptance job present with if: always()"
else
  bad "acceptance job/always() missing"
fi
if grep -q 'needs.static-validation.result' "$WF" && grep -q 'needs.regression-tests.result' "$WF"; then
  ok "acceptance explicitly evaluates both mandatory job results"
else
  bad "acceptance does not evaluate needs results"
fi

# -- CI15/CI16: no auto-merge / auto-publish --------------------------------
note "CI15/CI16: no auto-merge, no auto-publication"
if grep -qiE "automerge|auto-merge|merge when|merge-when" "$WF"; then
  bad "auto-merge found"
else
  ok "no auto-merge"
fi
if grep -qE "workflow_run:|schedule:" "$WF"; then
  bad "workflow has schedule/workflow_run trigger"
else
  ok "no scheduled/workflow_run triggers"
fi

# -- CI14: existing release workflows unchanged ------------------------------
note "CI14: release workflows still present with gates"
for rel in build-release.yml build-staging.yml repo-health.yml; do
  if [[ -f "$REPO_ROOT/.github/workflows/$rel" ]]; then
    ok "$rel present"
  else
    bad "$rel missing"
  fi
done
if grep -q "confirm-production" "$REPO_ROOT/.github/workflows/build-release.yml"; then
  ok "confirm-production gate retained"
else
  bad "confirm-production gate missing"
fi
if grep -q "signing-mode" "$REPO_ROOT/.github/workflows/build-release.yml"; then
  ok "signing-mode input retained"
else
  bad "signing-mode input missing"
fi

# -- CI03/CI04/CI05/CI06: policy-level wiring --------------------------------
note "CI03/CI04/CI05/CI06: static job wired to fail on findings"
if grep -q "bash -n" "$WF"; then ok "bash syntax step present"; else bad "bash syntax step missing"; fi
if grep -q "shellcheck" "$WF"; then ok "shellcheck step present"; else bad "shellcheck step missing"; fi
if grep -q "actionlint" "$WF"; then ok "actionlint step present"; else bad "actionlint step missing"; fi
if grep -q "run-tests.sh" "$WF"; then ok "regression step present"; else bad "regression step missing"; fi

# -- CI08: REPO_ROOT configured in regression job ----------------------------
note "CI08: REPO_ROOT set in regression job"
if grep -q 'REPO_ROOT: \${{ github.workspace }}' "$WF"; then
  ok "REPO_ROOT bound to github.workspace"
else
  bad "REPO_ROOT not set in regression job"
fi

echo
echo "ci-safety: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
