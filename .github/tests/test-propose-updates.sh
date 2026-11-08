#!/usr/bin/env bash
#
# Regression tests for Phase 5.2 update proposal generation
# (propose-updates.sh). Runs offline (no --push, no network). Verifies:
#   - proposals are only generated for verified update states
#   - deterministic branch derivation (same report => same branch)
#   - no PKGBUILD edits / no invented checksums
#   - index lists manual-review candidates separately
#   - no secrets/tokens in generated documents
set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# -- fixture lifecycle report ------------------------------------------------
cat > "$WORKDIR/report.json" <<'JSON'
[
  {"package":"pkg-a","current_version":"1.0.0","current_epoch":"","current_release":"1","upstream_version":"1.2.0","upstream_url":"https://github.com/example/pkg-a","update_type":"UPDATE_AVAILABLE","package_type":"stable","source_kind":"github","source_reference":"v1.2.0","rebuild_required":true,"risk_level":"medium","recommended_action":"review PR proposal","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"newer version 1.2.0"},
  {"package":"pkg-b","current_version":"1.0","current_epoch":"","current_release":"1","upstream_version":"","upstream_url":"https://github.com/example/pkg-b","update_type":"SOURCE_CHANGED","package_type":"vcs","source_kind":"git","source_reference":"abcdef0123","rebuild_required":true,"risk_level":"low","recommended_action":"none","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"branch HEAD moved"},
  {"package":"pkg-c","current_version":"2.0","current_epoch":"","current_release":"1","upstream_version":"","upstream_url":"https://github.com/example/pkg-c","update_type":"CHECK_FAILED","package_type":"stable","source_kind":"github","source_reference":"","rebuild_required":false,"risk_level":"low","recommended_action":"none","probe_ok":false,"checked_at":"2026-11-06T00:00:00Z","note":"github probe returned no versions"},
  {"package":"pkg-d","current_version":"1.0","current_epoch":"","current_release":"1","upstream_version":"","upstream_url":"","update_type":"MANUAL_REVIEW","package_type":"stable","source_kind":"unsupported","source_reference":"","rebuild_required":false,"risk_level":"low","recommended_action":"none","probe_ok":false,"checked_at":"2026-11-06T00:00:00Z","note":"unparsable source"}
]
JSON

# ---------------------------------------------------------------------------
note "propose: proposal docs generated only for verified update states"
OUT1="$WORKDIR/out1"
rc=0
bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
  --report "$WORKDIR/report.json" --outdir "$OUT1" --base main \
  > "$WORKDIR/propose1.log" 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "propose-updates exits 0 offline"
else
  bad "propose-updates failed (rc=$rc): $(tail -3 "$WORKDIR/propose1.log")"
fi
if [[ -f "$OUT1/pkg-a.md" ]]; then
  ok "UPDATE_AVAILABLE package gets a proposal"
else
  bad "pkg-a.md missing"
fi
if [[ -f "$OUT1/pkg-b.md" ]]; then
  ok "SOURCE_CHANGED package gets a proposal"
else
  bad "pkg-b.md missing"
fi
if [[ ! -f "$OUT1/pkg-c.md" && ! -f "$OUT1/pkg-d.md" ]]; then
  ok "CHECK_FAILED/MANUAL_REVIEW packages get NO proposal"
else
  bad "unverified package proposed: $(ls "$OUT1" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
note "propose: index separates automatic proposals from manual review"
if grep -q 'Automatic proposals (2)' "$OUT1/README.md" \
    && grep -q 'pkg-a' "$OUT1/README.md" \
    && grep -q 'pkg-b' "$OUT1/README.md" \
    && grep -q 'pkg-c' "$OUT1/README.md" \
    && grep -q 'pkg-d' "$OUT1/README.md"; then
  ok "index lists proposals and manual-review candidates"
else
  bad "index structure wrong: $(head -20 "$OUT1/README.md")"
fi

# ---------------------------------------------------------------------------
note "propose: deterministic branch + plan"
PLAN="$OUT1/proposal-plan.json"
if jq -e '.update_count == 1 and (.proposals | length) == 2 and (.branch | length > 0)' \
    "$PLAN" >/dev/null 2>&1; then
  ok "plan JSON has branch + update count + proposals"
else
  bad "plan JSON wrong: $(cat "$PLAN")"
fi
OUT2="$WORKDIR/out2"
bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
  --report "$WORKDIR/report.json" --outdir "$OUT2" --base main \
  > /dev/null 2>&1
B1=$(jq -r '.branch' "$PLAN")
B2=$(jq -r '.branch' "$OUT2/proposal-plan.json")
if [[ "$B1" == "$B2" && -n "$B1" ]]; then
  ok "branch is deterministic across runs"
else
  bad "branch not deterministic: $B1 vs $B2"
fi
# generated timestamps legitimately differ across runs; everything else
# must be byte-identical (deterministic proposal content)
if diff -r -x 'README.md' "$OUT1" "$OUT2" >/dev/null 2>&1 \
    && diff <(grep -v '^Generated:' "$OUT1/README.md") <(grep -v '^Generated:' "$OUT2/README.md") >/dev/null 2>&1; then
  ok "proposal documents deterministic across runs (modulo timestamp)"
else
  bad "proposal documents differ across runs"
fi

# ---------------------------------------------------------------------------
note "propose: never edits PKGBUILDs, never invents checksums"
if grep -qrE 'sha256sums=\(|apply this patch|edit PKGBUILD|modify PKGBUILD' "$OUT1"; then
  bad "proposal contains concrete edit instructions"
else
  ok "no checksum/PKGBUILD edits proposed"
fi
if grep -q 'No checksums are proposed automatically' "$OUT1/pkg-a.md"; then
  ok "proposal documents checksum policy (never guessed)"
else
  bad "checksum policy note missing"
fi

# ---------------------------------------------------------------------------
note "propose: documents never contain secrets/tokens"
if grep -rqiE 'GH_TOKEN|GITHUB_TOKEN|ghp_|github_pat_|BEGIN (RSA |OPENSSH |PGP )?PRIVATE KEY' \
    "$OUT1"; then
  bad "sensitive content found in proposals"
else
  ok "proposal documents free of secrets"
fi

# ---------------------------------------------------------------------------
note "propose: no-update report yields zero proposals, exit 0"
cat > "$WORKDIR/no-update.json" <<'JSON'
[
  {"package":"pkg-a","current_version":"1.0.0","update_type":"UP_TO_DATE","package_type":"stable","source_kind":"github","source_reference":"v1.0.0","rebuild_required":false,"risk_level":"low","recommended_action":"none","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"current matches"}
]
JSON
OUT3="$WORKDIR/out3"
rc=0
bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
  --report "$WORKDIR/no-update.json" --outdir "$OUT3" \
  > /dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'Automatic proposals (0)' "$OUT3/README.md"; then
  ok "no-update report -> 0 proposals, exit 0"
else
  bad "no-update handling wrong (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# PHASE 5.2 PR VALIDATION — Mode A (local/mocked, zero remote writes)
# ---------------------------------------------------------------------------
# A mock `gh` CLI records every invocation and returns canned PR states.
# The tests run propose-updates.sh --push with the mock on PATH; a real
# git remote is simulated via a local bare repository so push/fetch can be
# exercised without any network access.

# controlled, documentation-only fixture report (NEVER the real lifecycle report)
cat > "$WORKDIR/fixture-report.json" <<'JSON'
[
  {"package":"fixture-a","current_version":"1.0.0","current_epoch":"","current_release":"1","upstream_version":"1.2.0","upstream_url":"https://github.com/example/fixture-a","update_type":"UPDATE_AVAILABLE","package_type":"stable","source_kind":"github","source_reference":"v1.2.0","rebuild_required":true,"risk_level":"medium","recommended_action":"review PR proposal","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"fixture"},
  {"package":"fixture-b","current_version":"1.0","current_epoch":"","current_release":"1","upstream_version":"","upstream_url":"https://github.com/example/fixture-b","update_type":"SOURCE_CHANGED","package_type":"vcs","source_kind":"git","source_reference":"abcdef0123","rebuild_required":true,"risk_level":"low","recommended_action":"none","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"fixture"}
]
JSON

MOCK_GH="$WORKDIR/gh"
cat > "$MOCK_GH" <<'MOCK'
#!/usr/bin/env bash
# mock gh: records calls, returns canned responses driven by files
set -u
FAKE_STATE="${PR_STATE_FILE:-/dev/null}"
echo "gh $*" >> "$FAKE_STATE"
echo "gh $*" >&2
case "$1" in
  api)
    shift
    local jq_filter="" url=""
    while (( $# > 0 )); do
      case "$1" in
        --jq) shift; jq_filter="$1";;
        *) url="$1";;
      esac
      shift
    done
    case "$url" in
      repos/*)
        local body
        if [[ -f "${MOCK_PERM_FILE:-}" ]]; then
          body="$(cat "$MOCK_PERM_FILE")"
        else
          body='{"full_name":"mock/repo","permissions":{"push":true}}'
        fi
        if [[ -n "$jq_filter" ]]; then
          printf '%s' "$body" | jq -r "$jq_filter"
        else
          printf '%s' "$body"
        fi
        ;;
      *) echo '{"full_name":"mock/repo","permissions":{"push":true}}' ;;
    esac
    ;;
  pr)
    shift
    case "$1" in
      view)
        # --state all --json state,url,merged
        # canned response comes from $MOCK_PR_STATE_FILE
        if [[ -f "${MOCK_PR_STATE_FILE:-}" ]]; then
          cat "$MOCK_PR_STATE_FILE"
        else
          echo '{"state":"CLOSED","url":"","merged":false}'
        fi
        ;;
      edit) exit 0 ;;
      create)
        if [[ -f "${MOCK_CREATE_FAIL_FILE:-}" ]]; then
          cat "$MOCK_CREATE_FAIL_FILE" >&2
          exit 1
        fi
        echo "https://github.com/mock/repo/pull/123"
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$MOCK_GH"

# fully isolated clone (never a worktree of the real repo): the test
# exercises git push/fetch against a local fake bare remote; the real
# repository is never touched.
FAKE_REMOTE="$WORKDIR/fake-remote.git"

# prepare_fake_remote: create a self-contained bare remote and worktree
# clone. The source checkout may be detached/shallow (GitHub Actions PR
# merge ref), so we explicitly materialize a `main` branch in the fake
# remote (pointing at the current HEAD) and install the matching
# `origin/main` remote-tracking ref in the worktree. This never touches
# the real remote.
prepare_fake_remote() {
  rm -rf "$FAKE_REMOTE" "$WORKDIR/wt"
  # Preempt "dubious ownership" when the source checkout belongs to a
  # different UID (e.g. Ubuntu CI container against a bind-mounted host
  # checkout). Sandboxed to this process's global git config.
  git config --global --add safe.directory "$REPO_ROOT" 2>/dev/null || true
  git config --global --add safe.directory "$REPO_ROOT/.git" 2>/dev/null || true
  git clone -q --bare "$REPO_ROOT" "$FAKE_REMOTE"
  # ensure a stable `main` ref exists in the fake remote even when the
  # source checkout is detached/shallow
  if ! git --git-dir="$FAKE_REMOTE" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
    git --git-dir="$FAKE_REMOTE" branch -f main HEAD
  fi
  git clone -q "$FAKE_REMOTE" "$WORKDIR/wt"
  git -C "$WORKDIR/wt" config --global --add safe.directory "$WORKDIR/wt" 2>/dev/null || true
  git -C "$WORKDIR/wt" fetch -q origin main:refs/remotes/origin/main 2>/dev/null || true
  git -C "$WORKDIR/wt" config user.name "test"
  git -C "$WORKDIR/wt" config user.email "test@example.com"
}

prepare_fake_remote

run_push_mock() { # [env=val...] -- [args...] -> rc
  local -a extra_env
  local -a args
  local in_args=0
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then in_args=1; continue; fi
    if (( in_args )); then args+=("$a"); else extra_env+=("$a"); fi
  done
  local rc
  # start from a clean, per-test-isolated state:
  #  - wipe the fake remote (so stale branches from earlier tests cannot
  #    be "found" by the idempotent fetch),
  #  - recreate the worktree clone from it,
  #  - remove local untracked fixtures.
  prepare_fake_remote
  set +e
  ( cd "$WORKDIR/wt" \
    && PATH="$WORKDIR:$PATH" \
    GH_TOKEN=fake-token \
    GITHUB_REPOSITORY=mock/repo \
    GITHUB_WORKSPACE="$WORKDIR/wt" \
    env "${extra_env[@]}" \
    bash "$REPO_ROOT/.github/scripts/propose-updates.sh" "${args[@]}" \
      > "$WORKDIR/push.log" 2>&1 )
  rc=$?
  set -e
  return "$rc"
}

note "PR validation: fixture mode blocks remote writes without --allow-remote-pr"
rc=0
run_push_mock -- --report "$WORKDIR/fixture-report.json" --fixture t01 --repo mock/repo --base main --push || rc=$?
if [[ "$rc" -eq 2 ]] && grep -q "allow-remote-pr" "$WORKDIR/push.log"; then
  ok "validation branch push refused without --allow-remote-pr (rc=2)"
else
  bad "validation push not blocked: rc=$rc ($(tail -2 "$WORKDIR/push.log"))"
fi

note "PR validation: --dry-run never performs remote writes"
rm -f "$WORKDIR/events"
rc=0
run_push_mock PR_STATE_FILE="$WORKDIR/events" -- --report "$WORKDIR/fixture-report.json" --fixture t02 --repo mock/repo --base main --push --allow-remote-pr --dry-run || rc=$?
if [[ "$rc" -eq 0 && ! -s "$WORKDIR/events" ]]; then
  ok "dry-run produced zero remote calls"
else
  bad "dry-run touched remote (rc=$rc): $(cat "$WORKDIR/events" 2>/dev/null)"
fi

note "PR validation: duplicate PR prevented (existing open PR reused)"
rm -f "$WORKDIR/events1" "$WORKDIR/pr-open"
printf '%s' '{"state":"OPEN","url":"https://github.com/mock/repo/pull/42","merged":false}' > "$WORKDIR/pr-open"
rc=0
run_push_mock PR_STATE_FILE="$WORKDIR/events1" MOCK_PR_STATE_FILE="$WORKDIR/pr-open" \
    -- --report "$WORKDIR/fixture-report.json" --fixture t03 --repo mock/repo --base main --push --allow-remote-pr || rc=$?
if grep -q 'pr create' "$WORKDIR/events1" 2>/dev/null; then
  bad "created duplicate PR"
else
  ok "existing open PR reused (no duplicate create)"
fi
if grep -q 'pr edit' "$WORKDIR/events1"; then
  ok "open PR updated in place"
else
  bad "open PR not updated"
fi

note "PR validation: closed PR is not silently reopened; fresh PR created"
rm -f "$WORKDIR/events2" "$WORKDIR/pr-closed"
printf '%s' '{"state":"CLOSED","url":"https://github.com/mock/repo/pull/7","merged":false}' > "$WORKDIR/pr-closed"
rc=0
run_push_mock PR_STATE_FILE="$WORKDIR/events2" MOCK_PR_STATE_FILE="$WORKDIR/pr-closed" \
    -- --report "$WORKDIR/fixture-report.json" --fixture t04 --repo mock/repo --base main --push --allow-remote-pr || rc=$?
if grep -q 'pr create' "$WORKDIR/events2"; then
  ok "closed PR leads to fresh PR create (not silent reopen)"
else
  bad "closed PR handling wrong: $(cat "$WORKDIR/events2")"
fi

note "PR validation: merged PR is never recreated"
rm -f "$WORKDIR/events3" "$WORKDIR/pr-merged"
printf '%s' '{"state":"MERGED","url":"https://github.com/mock/repo/pull/9","merged":true}' > "$WORKDIR/pr-merged"
rc=0
run_push_mock PR_STATE_FILE="$WORKDIR/events3" MOCK_PR_STATE_FILE="$WORKDIR/pr-merged" \
    -- --report "$WORKDIR/fixture-report.json" --fixture t05 --repo mock/repo --base main --push --allow-remote-pr || rc=$?
if grep -q 'pr create' "$WORKDIR/events3" 2>/dev/null; then
  bad "merged PR recreated"
else
  ok "merged PR skipped (no create)"
fi

note "PR validation: PR creation API errors are classified"
rm -f "$WORKDIR/events4" "$WORKDIR/pr-create-fail"
printf '%s\n' 'HTTP 403: Bad credentials' > "$WORKDIR/pr-create-fail"
rc=0
run_push_mock PR_STATE_FILE="$WORKDIR/events4" MOCK_CREATE_FAIL_FILE="$WORKDIR/pr-create-fail" \
    -- --report "$WORKDIR/fixture-report.json" --fixture t06 --repo mock/repo --base main --push --allow-remote-pr || rc=$?
if [[ "$rc" -eq 2 ]] && grep -q "::error::" "$WORKDIR/push.log"; then
  ok "PR create failure produces clear error and nonzero exit"
else
  bad "PR create failure not classified (rc=$rc): $(tail -2 "$WORKDIR/push.log")"
fi

note "PR validation: repo metadata push=false is NOT treated as a gate failure"
# GitHub Actions job-scoped contents:write does NOT show up as
# repo .permissions.push=true (installation token has no user role). A
# false push value must not abort the run — the real capability check is
# the push/PR operation itself.
rm -f "$WORKDIR/events5" "$WORKDIR/perm-deny"
printf '%s' '{"full_name":"mock/repo","permissions":{"push":false}}' > "$WORKDIR/perm-deny"
rc=0
run_push_mock PR_STATE_FILE="$WORKDIR/events5" MOCK_PERM_FILE="$WORKDIR/perm-deny" \
    -- --report "$WORKDIR/fixture-report.json" --fixture t07 --repo mock/repo --base main --push --allow-remote-pr || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'pr view' "$WORKDIR/events5"; then
  ok "push=false repo metadata does not abort the run (job scoped permissions govern)"
else
  bad "run aborted by misleading repo metadata (rc=$rc): $(tail -3 "$WORKDIR/push.log")"
fi
# mock API was consulted for diagnostics (not as a gate)
if grep -q 'gh api repos/mock/repo' "$WORKDIR/push.log" "$WORKDIR/events5" 2>/dev/null; then
  ok "mock GitHub API diagnostic probe invoked"
else
  bad "diagnostic probe missing: $(cat "$WORKDIR/push.log" 2>/dev/null | tr '\n' '|')"
fi

note "PR validation: actual git push denial is classified and fails closed"
# simulate a real push denial: replace git push with a failing stub
cat > "$WORKDIR/git" <<'GIT'
#!/usr/bin/env bash
if [[ "$1" == "push" ]]; then
  echo "remote: Permission to mock/repo.git denied to github-actions[bot]." >&2
  echo "fatal: unable to access 'https://github.com/mock/repo.git/': The requested URL returned error: 403" >&2
  exit 1
fi
exec /usr/bin/git "$@"
GIT
chmod +x "$WORKDIR/git"
rm -f "$WORKDIR/events6"
rc=0
( cd "$WORKDIR/wt" \
  && PATH="$WORKDIR:$PATH" \
  GH_TOKEN=fake-token GITHUB_REPOSITORY=mock/repo GITHUB_WORKSPACE="$WORKDIR/wt" \
  PR_STATE_FILE="$WORKDIR/events6" MOCK_PERM_FILE="$WORKDIR/perm-deny" \
  bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
    --report "$WORKDIR/fixture-report.json" --fixture t08 --repo mock/repo --base main --push --allow-remote-pr \
    > "$WORKDIR/push-deny.log" 2>&1 ) || rc=$?
if [[ "$rc" -eq 2 ]] && grep -q '::error::git push DENIED' "$WORKDIR/push-deny.log"; then
  ok "git push 403 classified as permission denial (rc=2)"
else
  bad "push denial not classified: rc=$rc ($(tail -3 "$WORKDIR/push-deny.log"))"
fi
# zero remote writes: no validation branch may exist in the fake remote
PUSHED_REF="$(git -C "$FAKE_REMOTE" for-each-ref --format='%(refname)' refs/heads 2>/dev/null | grep -c 'validation/phase5-pr-test-t08' || true)"
if [[ "$PUSHED_REF" -eq 0 ]]; then
  ok "real push denial left zero remote branches"
else
  bad "branch existed despite push denial (refs=$PUSHED_REF)"
fi

note "PR validation: idempotency — same fixture content yields identical branch identity"
# calculate the SHA-256 fixture digest exactly as the workflow does
fixture_digest() { # <report> -> 16-hex digest
  jq -r \
    'map({p:.package, t:.update_type, u:(.upstream_version // ""), r:(.source_reference // "")}) | sort | tostring | @base64' "$1" \
    | tr -d '\n' | sha256sum | cut -c1-16
}
DIG_A="$(fixture_digest "$WORKDIR/fixture-report.json")"
OUT_A="$WORKDIR/outA"
OUT_B="$WORKDIR/outB"
bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
  --report "$WORKDIR/fixture-report.json" --fixture "$DIG_A" --outdir "$OUT_A" --base main >/dev/null 2>&1
bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
  --report "$WORKDIR/fixture-report.json" --fixture "$DIG_A" --outdir "$OUT_B" --base main >/dev/null 2>&1
BR_A=$(jq -r '.branch' "$OUT_A/validation/phase5-pr-test-$DIG_A/fixture-plan.json")
BR_B=$(jq -r '.branch' "$OUT_B/validation/phase5-pr-test-$DIG_A/fixture-plan.json")
if [[ "$BR_A" == "$BR_B" && "$BR_A" == "validation/phase5-pr-test-$DIG_A" ]] \
    && [[ "$DIG_A" =~ ^[0-9a-f]{16}$ ]]; then
  ok "identical fixture content -> identical SHA-256 branch identity"
else
  bad "identity not deterministic: $BR_A vs $BR_B (digest=$DIG_A)"
fi
if diff -r "$OUT_A/validation/phase5-pr-test-$DIG_A" "$OUT_B/validation/phase5-pr-test-$DIG_A" >/dev/null 2>&1; then
  ok "fixture documents byte-identical across runs (modulo timestamp)"
else
  bad "fixture documents differ across runs"
fi

note "PR validation: different fixture content produces a different identity"
cat > "$WORKDIR/fixture-report2.json" <<'JSON'
[
  {"package":"fixture-a","current_version":"1.0.0","current_epoch":"","current_release":"1","upstream_version":"1.3.0","upstream_url":"https://github.com/example/fixture-a","update_type":"UPDATE_AVAILABLE","package_type":"stable","source_kind":"github","source_reference":"v1.3.0","rebuild_required":true,"risk_level":"medium","recommended_action":"review PR proposal","probe_ok":true,"checked_at":"2026-11-06T00:00:00Z","note":"fixture"}
]
JSON
DIG_B="$(fixture_digest "$WORKDIR/fixture-report2.json")"
if [[ "$DIG_B" != "$DIG_A" && "$DIG_B" =~ ^[0-9a-f]{16}$ ]]; then
  ok "changed fixture content -> new SHA-256 identity"
else
  bad "collision or invalid digest: $DIG_A vs $DIG_B"
fi
OUT_C="$WORKDIR/outC"
bash "$REPO_ROOT/.github/scripts/propose-updates.sh" \
  --report "$WORKDIR/fixture-report2.json" --fixture "$DIG_B" --outdir "$OUT_C" --base main >/dev/null 2>&1
BR_C=$(jq -r '.branch' "$OUT_C/validation/phase5-pr-test-$DIG_B/fixture-plan.json")
if [[ "$BR_C" == "validation/phase5-pr-test-$DIG_B" ]]; then
  ok "changed content targets a distinct branch"
else
  bad "branch for changed content wrong: $BR_C"
fi

note "PR validation: fixture staging contains ONLY validation files"
# allowed: README.md (manifest) + fixture-plan.json (identity). Anything
# else (per-package proposal .md files, real index) is a violation.
FIX_DIR="$OUT_A/validation/phase5-pr-test-$DIG_A"
FIX_FILES="$(find "$FIX_DIR" -type f | sed "s#^$FIX_DIR/##" | LC_ALL=C sort)"
EXPECTED_FIX="$(printf 'README.md\nfixture-plan.json\n')"
if [[ "$FIX_FILES" == "$EXPECTED_FIX" ]] \
    && ! grep -q '## Automatic proposals' "$FIX_DIR/README.md"; then
  ok "fixture payload is exactly manifest + identity plan (no real proposals)"
else
  bad "fixture payload polluted: $(echo "$FIX_FILES" | tr '\n' ' ')"
fi
if [[ "$(find "$OUT_A" -path '*/fixture-a.md' -o -path '*/fixture-b.md' | wc -l)" -eq 0 ]]; then
  ok "no per-package proposal files staged in fixture"
else
  bad "fixture contains proposal files"
fi
if jq -e '.kind == "validation-fixture" and (.proposals == null)' "$FIX_DIR/fixture-plan.json" >/dev/null 2>&1; then
  ok "fixture plan carries identity only, never proposal rows"
else
  bad "fixture plan embeds proposals: $(cat "$FIX_DIR/fixture-plan.json")"
fi
# staged paths are restricted to docs/update-proposals/validation/ (checked
# inside the push path; here we confirm the fixture output does not contain
# a top-level README or proposal files outside the validation namespace)
if [[ ! -f "$OUT_C/docs/update-proposals/README.md" ]] \
    && [[ ! -f "$OUT_C/docs/update-proposals/validation/phase5-pr-test-$DIG_B/fixture-a.md" ]] \
    && [[ ! -f "$OUT_C/docs/update-proposals/validation/phase5-pr-test-$DIG_B/fixture-b.md" ]]; then
  ok "no non-validation files created outside the validation namespace"
else
  bad "non-validation files leaked into docs/"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
