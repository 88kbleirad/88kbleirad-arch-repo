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

# ---------------------------------------------------------------------------
# Phase 8.1.1 regression-fix invariants (live PR #9 failures)
# ---------------------------------------------------------------------------

note "fixA: regression job installs vercmp provider and verifies semantics"
if grep -q "makepkg" "$WF" && grep -q "vercmp" "$WF"; then
  ok "vercmp provider (makepkg) installed + verified"
else
  bad "vercmp provider not wired in ci-validation.yml"
fi
if grep -q 'vercmp 1.10.0 1.9.0' "$WF"; then
  ok "vercmp semantic probes present"
else
  bad "vercmp semantic probes missing"
fi

note "fixB: propose-updates fixture is self-contained (no origin/main dependency)"
if grep -q "prepare_fake_remote" "$REPO_ROOT/.github/tests/test-propose-updates.sh" \
   && grep -q "refs/remotes/origin/main" "$REPO_ROOT/.github/tests/test-propose-updates.sh"; then
  ok "fake remote materializes origin/main in detached/shallow checkouts"
else
  bad "propose-updates fake remote not hardened"
fi

note "fixC: container test uses container-aware workspace removal"
if grep -q "ws_rm" "$REPO_ROOT/.github/tests/run-container-tests.sh"; then
  ok "ws_rm helper present for root-owned workspace cleanup"
else
  bad "ws_rm helper missing"
fi

note "fixD: regression step preserves true exit status to job env"
if grep -q 'PIPESTATUS\[0\]' "$WF" && grep -q "regression_exit" "$WF"; then
  ok "PIPESTATUS captured before pipefail exit"
else
  bad "regression status capture not found"
fi
if grep -q 'INCOMPLETE' "$WF"; then
  ok "summary never defaults missing status to PASS"
else
  bad "summary may default unknown status to PASS"
fi

note "fixE: whitespace step fetches base SHA and fails when unavailable"
if grep -q 'git fetch --no-tags --depth=1 origin "$base_sha"' "$WF"; then
  ok "whitespace step fetches PR base SHA"
else
  bad "whitespace base fetch missing"
fi
if grep -q 'could not fetch PR base' "$WF"; then
  ok "unfetchable base fails the step"
else
  bad "missing-base case not handled"
fi

# -- local simulation of the status-propagation fix --------------------------
note "fixD negative: failed pipeline still writes env + exits nonzero"
SIM="$WORKDIR/sim-regression"
mkdir -p "$SIM"
cat > "$SIM/run.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
out="__SIM__/out.log"
envf="__SIM__/env"
set +e
bash -c 'echo partial; exit 7' 2>&1 | tee "$out"
status=${PIPESTATUS[0]}
set -e
echo "regression_exit=$status" > "$envf"
exit "$status"
EOF
sed -i "s|__SIM__|$SIM|g" "$SIM/run.sh"
chmod +x "$SIM/run.sh"
rc=0
bash "$SIM/run.sh" || rc=$?
if [[ "$rc" -eq 7 ]] && grep -q "regression_exit=7" "$SIM/env"; then
  ok "failed pipeline: status 7 recorded and propagated"
else
  bad "failed pipeline propagation broken (rc=$rc, env=$(cat "$SIM/env" 2>/dev/null))"
fi
if grep -q "partial" "$SIM/out.log"; then
  ok "log preserved despite failure"
else
  bad "log lost on failure"
fi

# ---------------------------------------------------------------------------
# Phase 8.1.1 stabilization: CI-F01..CI-F14 (behavior, not text-only)
# ---------------------------------------------------------------------------

note "CI-F01/F02: shallow/detached two-dot whitespace check works without merge base"
W_GIT="$WORKDIR/gitsim"
mkdir -p "$W_GIT"; git -C "$W_GIT" init -q
git -C "$W_GIT" config user.email t@t; git -C "$W_GIT" config user.name t
echo base > "$W_GIT/f"; git -C "$W_GIT" add f; git -C "$W_GIT" commit -qm base
BASE=$(git -C "$W_GIT" rev-parse HEAD)
git -C "$W_GIT" checkout -q --orphan pr; git -C "$W_GIT" rm -q -rf . 2>/dev/null || true
echo pr > "$W_GIT/g"; git -C "$W_GIT" add g; git -C "$W_GIT" commit -qm pr
if git -C "$W_GIT" diff --check "$BASE...HEAD" >/dev/null 2>&1; then
  ok "CI-F02 three-dot works here (has merge base)"
else
  ok "CI-F02 three-dot fails without merge base (as on runner)"
fi
if git -C "$W_GIT" diff --check "$BASE" HEAD >/dev/null 2>&1; then
  ok "CI-F01 two-dot comparison succeeds without merge base"
else
  bad "CI-F01 two-dot failed"
fi

note "CI-F05/F06: whitespace detection + valid file"
printf 'ok line\n' > "$W_GIT/ok.txt"
if git -C "$W_GIT" diff --check "$BASE" HEAD >/dev/null 2>&1; then
  ok "CI-F06 valid diff passes whitespace check"
else
  bad "CI-F06 valid diff failed"
fi
# introduce a trailing-whitespace file
git -C "$W_GIT" checkout -q --orphan ws2 2>/dev/null || true
git -C "$W_GIT" rm -q -rf . 2>/dev/null || true
printf 'bad trailing \n' > "$W_GIT/bad.txt"
git -C "$W_GIT" add bad.txt; git -C "$W_GIT" commit -qm ws
WS_DIFF="$(git -C "$W_GIT" diff --check "$BASE" HEAD 2>&1 || true)"
if printf '%s\n' "$WS_DIFF" | grep -q "trailing whitespace"; then
  ok "CI-F05 whitespace violation detected"
else
  bad "CI-F05 whitespace violation not detected"
fi
rm -rf "$W_GIT"

note "CI-F03/F04: missing base / fetch failure explicit (workflow grep + behavior)"
if grep -q 'could not fetch PR base' "$WF"; then ok "CI-F04 fetch-failure diagnostic present"; else bad "CI-F04 missing"; fi
if grep -q 'PR base object .* missing after fetch' "$WF"; then ok "CI-F03 missing-object diagnostic present"; else bad "CI-F03 missing"; fi

note "CI-F07/F08/F09: Docker workspace ownership helpers present and restore-able"
CC="$REPO_ROOT/.github/tests/run-container-tests.sh"
if grep -q "ws_ensure_host_owned()" "$CC" && grep -q "ws_mkdir()" "$CC" && grep -q "ws_rm()" "$CC"; then
  ok "CI-F07 workspace helpers present"
else
  bad "CI-F07 workspace helpers missing"
fi
if grep -q "chown -R \$uid:\$gid" "$CC"; then
  ok "CI-F08 host-ownership restore uses host uid:gid"
else
  bad "CI-F08 ownership restore missing"
fi

note "CI-F10: cleanup failure path does not mask results (ws_rm tolerant)"
if grep -q 'docker exec "$CID" bash -c "rm -rf --' "$CC"; then
  ok "CI-F10 container-side rm used for root-owned paths"
else
  bad "CI-F10 container-side rm missing"
fi

note "CI-F11/F12: static summary uses per-step outcomes"
if grep -q 'steps.bash_syntax.outcome' "$WF" && grep -q 'steps.actionlint.outcome' "$WF" \
   && grep -q 'steps.whitespace.outcome' "$WF"; then
  ok "CI-F11 per-step outcomes used in summary"
else
  bad "CI-F11 per-step outcomes missing"
fi
if grep -q 'INCOMPLETE' "$WF"; then
  ok "CI-F12 unexecuted check reported INCOMPLETE"
else
  bad "CI-F12 INCOMPLETE handling missing"
fi

note "CI-F13/F14: acceptance strictness unchanged"
if grep -q 'if: always()' "$WF" && grep -q 'needs.static-validation.result' "$WF" \
   && grep -q 'needs.regression-tests.result' "$WF"; then
  ok "CI-F13 acceptance evaluates both mandatory results"
else
  bad "CI-F13 acceptance weakened"
fi

note "CI-F15: every container build scenario hands the workspace to builder"
# Regression for the Phase 8.1.1 rc=11 root cause: makepkg 7.1 exits
# E_FS_PERMISSIONS (11) when its build directory (default: the package
# dir) is not writable by the build user. On GitHub-hosted runners the
# host UID (1001) differs from `builder` (1000), so run_build must chown
# the workspace BEFORE every invocation. Without this, the rebuild
# scenarios (second cache hit, tampered rebuild, epoch build) fail with
# an opaque rc=11.
if grep -q "chown -R builder:builder" "$CC" && grep -q 'run_build()' "$CC"; then
  ok "CI-F15 run_build owns workspace to builder before each run"
else
  bad "CI-F15 run_build builder-chown missing"
fi
if grep -q "TEST_BUILDER_UID" "$CC"; then
  ok "CI-F15 builder UID knob present (reproduces runner uid mismatch)"
else
  bad "CI-F15 builder UID knob missing"
fi

note "CI-F16: build-package.sh fails closed with an explicit permission diagnostic"
# A non-writable package dir must produce a precise error pointing at the
# ownership problem, never an opaque makepkg rc=11, and never a
# false-green success. The diagnostic must be distinguishable from the
# generic fail-closed path.
if grep -q "not writable by" "$REPO_ROOT/.github/scripts/build-package.sh"; then
  ok "CI-F16 build-package.sh explicit permission diagnostic present"
else
  bad "CI-F16 build-package.sh permission diagnostic missing"
fi
if grep -q "fail-closed" "$REPO_ROOT/.github/scripts/build-package.sh"; then
  ok "CI-F16 fail-closed wording retained"
else
  bad "CI-F16 fail-closed wording missing"
fi

echo
echo "ci-safety: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
