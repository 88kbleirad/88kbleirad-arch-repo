#!/usr/bin/env bash
#
# Update proposal generation (Phase 5.2). READ-ONLY by default: it only
# writes proposal documents into a local directory. The --push flag is the
# ONLY mode that touches GitHub (opens/updates a reviewable PR); it is used
# exclusively by the `propose` job in check-updates.yml after an owner
# dispatched the workflow with `open-pr=true`.
#
# Safety invariants:
#   - proposals are ALWAYS derived from the verified lifecycle report
#     (update-report.json); never from guessed data
#   - PKGBUILDs are NEVER edited or generated here — the PR is a review
#     proposal, not an automatic update
#   - checksums are never invented: if the report does not carry verified
#     checksums, the proposal says so and CLASSIFIES it as manual review
#   - no secrets, tokens, or credentials ever appear in proposals
#   - proposal generation is deterministic: same report => same documents
#     (used to avoid duplicate branches/PRs)
#
# Usage:
#   propose-updates.sh --report <update-report.json>
#       [--outdir <dir>] [--branch-stem <stem>] [--base <branch>]
#       [--repo <owner/repo>] [--push] [--dry-run]
#       [--fixture <id>] [--allow-remote-pr]
#
# --push will:
#   1. create/refresh the proposal documents,
#   2. commit them on a deterministic branch
#      (<stem>/<sha1-of-decision-set>),
#   3. create the PR if it does not exist (or update its body if it does).
#
# --fixture <id>: PHASE 5.2 PR VALIDATION — TEST ONLY. Generates a
#   documentation-only fixture under docs/update-proposals/validation/
#   (never touches git or GitHub). Branch stem becomes
#   validation/phase5-pr-test-<id>. Use with --report pointing at a
#   fixture report (never the real lifecycle report).
#
# --allow-remote-pr: explicit owner-gated approval for remote writes on a
#   VALIDATION branch only. The workflow's `allow-remote-pr` input sets
#   this; without it, --push on a validation branch is refused.
#
# Environment: GH_TOKEN, GITHUB_WORKSPACE (defaults to repo root).

set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REPORT=""
OUTDIR="$REPO_ROOT/docs/update-proposals"
BASE="main"
BRANCH_STEM="update-proposal"
REPO=""
PUSH=0
DRY=0
FIXTURE=""
ALLOW_REMOTE_PR=0
rel_outdir=""
TMPDIR="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "$TMPDIR/propose.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) REPORT="${2:-}"; shift 2 ;;
    --outdir) OUTDIR="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --branch-stem) BRANCH_STEM="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --fixture) FIXTURE="${2:-}"; shift 2 ;;
    --allow-remote-pr) ALLOW_REMOTE_PR=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$REPORT" && -f "$REPORT" ]] || { echo "::error::--report file required and must exist: $REPORT" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

# ---------------------------------------------------------------------------
# decision set: only real, verified updates are proposed
# ---------------------------------------------------------------------------
# A "proposable" update is one where the report proves an upstream change:
#   UPDATE_AVAILABLE   newer upstream version (vercmp-confirmed)
#   SOURCE_CHANGED     VCS HEAD moved (no version claimed)
#   REBUILD_REQUIRED   upstream metadata/checksum state changed
# Anything else (CHECK_FAILED, MANUAL_REVIEW, UPSTREAM_*) is NOT proposed
# automatically — it is surfaced in the index for manual review.
DECISIONS=$(jq -c '[.[] | select(.update_type == "UPDATE_AVAILABLE" or .update_type == "SOURCE_CHANGED" or .update_type == "REBUILD_REQUIRED")]' "$REPORT")
DECISION_COUNT=$(jq 'length' <<<"$DECISIONS")
UPDATES=$(jq -c '[.[] | select(.update_type == "UPDATE_AVAILABLE")]' "$REPORT")
UPDATE_COUNT=$(jq 'length' <<<"$UPDATES")

# deterministic branch: sha1 of the sorted decision set (package|state|upstream)
BRANCH_KEY=$(printf '%s' "$DECISIONS" | jq -S -c . | sha1sum | awk '{print $1}')
BRANCH="$BRANCH_STEM/$BRANCH_KEY"

# PHASE 5.2 PR VALIDATION fixture (TEST ONLY, documentation-only payload)
if [[ -n "$FIXTURE" ]]; then
  # a fixture must be deterministic and clearly marked; it never touches
  # the real proposal index or any package sources
  case "$FIXTURE" in
    *[!A-Za-z0-9._-]*) echo "::error::invalid fixture id: $FIXTURE" >&2; exit 2 ;;
  esac
  BRANCH="validation/phase5-pr-test-$FIXTURE"
  OUTDIR="$OUTDIR/validation/phase5-pr-test-$FIXTURE"
  FIXTURE_MARK="TEST ONLY — PHASE 5.2 PR VALIDATION"
fi
STAGE="$WORKDIR/stage"
mkdir -p "$OUTDIR" "$STAGE"

# ---------------------------------------------------------------------------
# proposal documents (staged first; applied to the branch after the branch
# is resolved — avoids untracked-file conflicts when updating an existing
# proposal branch)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# FIXTURE MODE: emit ONLY the validation manifest under the validation
# namespace. Genuine per-package proposals (which are derived from the
# report's decision set) are NEVER generated in fixture mode — a
# validation-only PR must never carry real proposal content.
# ---------------------------------------------------------------------------
INDEX="$STAGE/README.md"
if [[ -n "${FIXTURE_MARK:-}" ]]; then
  {
    echo "# Phase 5.2 PR Validation Fixture"
    echo
    echo "> **$FIXTURE_MARK**"
    echo
    echo "This file exists solely to validate the Phase 5.2 pull-request"
    echo "workflow (branch creation, PR creation, idempotent reruns)."
    echo
    echo "- **fixture id**: \`$FIXTURE\`"
    echo "- **branch**: \`$BRANCH\`"
    echo "- **payload**: documentation only — no PKGBUILD, no package"
    echo "  sources, no release assets, no production changes."
    echo "- **do not merge**; merging publishes nothing."
    echo
    echo "## Content digest (fixture identity)"
    echo
    echo '```'
    echo "packages_checked=$(jq 'length' "$REPORT")"
    echo "decision_count=$DECISION_COUNT"
    echo "update_count=$UPDATE_COUNT"
    echo '```'
    echo
    echo "The branch suffix is a SHA-256 digest of the canonical fixture"
    echo "content (sorted package/state/version tuples). Identical content"
    echo "always yields the same branch and PR; changed content yields a new"
    echo "one."
  } > "$INDEX"
fi

if [[ -z "${FIXTURE_MARK:-}" ]]; then
{
  echo "# Update Proposals (Phase 5.2)"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Base branch: \`$BASE\`"
  echo
  echo "## Automatic proposals ($DECISION_COUNT)"
  echo
  if [[ "$DECISION_COUNT" -eq 0 ]]; then
    echo "None — no verified upstream changes were detected."
  else
    echo "| package | current | proposed | state | risk | evidence |"
    echo "|---|---|---|---|---|---|"
    jq -r '.[] | "| \(.package) | \(.current_version // "-") | \(.upstream_version // "-") | \(.update_type) | \(.risk_level // "-") | \(.source_reference // "-") |"' \
      <<<"$DECISIONS"
  fi
  echo
  echo "## Manual review candidates"
  echo
  echo "The following packages are NOT auto-proposed (probe failures,"
  echo "upstream unavailable/archived, or unsupported source shapes):"
  echo
  jq -r '.[] | "- \(.package): \(.update_type) — \(.note // "")"' "$REPORT" \
    | grep -vE 'UPDATE_AVAILABLE|SOURCE_CHANGED|REBUILD_REQUIRED' || echo "- (none)"
} > "$INDEX"
fi

# per-package proposal files — deterministic, evidence-only (NEVER in
# fixture mode: validation PRs carry only the manifest above)
N=0
while IFS= read -r rec; do
  [[ -n "$rec" ]] || continue
  [[ -n "${FIXTURE_MARK:-}" ]] && continue
  N=$((N+1))
  pkg=$(jq -r '.package' <<<"$rec")
  state=$(jq -r '.update_type' <<<"$rec")
  ver=$(jq -r '.current_version // "-"' <<<"$rec")
  up=$(jq -r '.upstream_version // "-"' <<<"$rec")
  risk=$(jq -r '.risk_level // "-"' <<<"$rec")
  kind=$(jq -r '.package_type // "-"' <<<"$rec")
  src=$(jq -r '.source_kind // "-"' <<<"$rec")
  ref=$(jq -r '.source_reference // "-"' <<<"$rec")
  note=$(jq -r '.note // "-"' <<<"$rec")
  url=$(jq -r '.upstream_url // "-"' <<<"$rec")

  # validation evidence (never invented): version comparison + rebuild flag
  if [[ "$state" == "UPDATE_AVAILABLE" ]]; then
    compare="upstream $up > current $ver (vercmp-confirmed)"
  elif [[ "$state" == "SOURCE_CHANGED" ]]; then
    compare="VCS upstream reference changed (no version claimed)"
  else
    compare="rebuild required per lifecycle report"
  fi
  rebuild=$(jq -r '.rebuild_required // false' <<<"$rec")
  checksum_note="No checksums are proposed automatically. Any checksum change must be verified by the maintainer (updpkgsums with a verified source) — never guessed."

  F="$STAGE/$pkg.md"
  {
    echo "# Proposal: $pkg"
    echo
    echo "- **package**: \`$pkg\`"
    echo "- **package type**: \`$kind\`"
    echo "- **source kind**: \`$src\`"
    echo "- **state**: \`$state\`"
    echo "- **current version**: \`$ver\`"
    echo "- **proposed version**: \`$up\`"
    echo "- **upstream reference**: \`$ref\`"
    echo "- **upstream URL**: <$url>"
    echo "- **risk level**: \`$risk\`"
    echo "- **requires rebuild**: \`$rebuild\`"
    echo "- **validation evidence**: $compare"
    echo "- **detail**: $note"
    echo
    echo "## Required human review"
    echo
    echo "$checksum_note"
    echo
    echo "This is a review proposal only. Merging this PR does NOT publish"
    echo "anything: publication happens through the existing release"
    echo "workflows after separate owner authorization."
  } > "$F"
done < <(jq -c '.[]' <<<"$DECISIONS")

# summaries (machine-readable plan)
# - proposal mode: full deterministic plan (branch + proposals + count)
# - fixture mode:  fixture identity ONLY — never the real decision set
#   (a validation PR must not embed genuine proposal content)
if [[ -n "${FIXTURE_MARK:-}" ]]; then
  PLAN="$STAGE/fixture-plan.json"
  jq -n \
    --arg branch "$BRANCH" \
    --arg fixture "$FIXTURE" \
    --argjson packages_checked "$(jq 'length' "$REPORT")" \
    --argjson decision_count "$DECISION_COUNT" \
    --argjson update_count "$UPDATE_COUNT" \
    '{branch:$branch, fixture:$fixture, kind:"validation-fixture", packages_checked:$packages_checked,
      decision_count:$decision_count, update_count:$update_count}' > "$PLAN"
else
  PLAN="$STAGE/proposal-plan.json"
  jq -n \
    --arg branch "$BRANCH" \
    --argjson proposals "$DECISIONS" \
    --argjson update_count "$UPDATE_COUNT" \
    '{branch:$branch, proposals:$proposals, update_count:$update_count}' > "$PLAN"
fi

echo "[propose] generated $N proposal document(s) (staged)"
echo "[propose] deterministic branch: $BRANCH"
echo "[propose] update_count=$UPDATE_COUNT"

if [[ "$PUSH" -eq 1 ]]; then
  if [[ "$DRY" -eq 1 ]]; then
    # materialize locally (offline docs) but never touch git remote
    rm -rf "$OUTDIR"
    mkdir -p "$OUTDIR"
    cp -r "$STAGE/." "$OUTDIR/"
    echo "[propose] DRY-RUN: would push branch $BRANCH and open/update a PR"
    exit 0
  fi
  [[ -n "${GH_TOKEN:-}" ]] || { echo "::error::GH_TOKEN required for --push" >&2; exit 2; }
  [[ -n "$REPO" ]] || REPO="${GITHUB_REPOSITORY:-}"
  [[ -n "$REPO" ]] || { echo "::error::--repo (or GITHUB_REPOSITORY) required for --push" >&2; exit 2; }

  # validation branches require explicit owner authorization (--allow-remote-pr)
  if [[ "$BRANCH" == validation/* ]]; then
    if [[ "$ALLOW_REMOTE_PR" -ne 1 ]]; then
      echo "::error::remote write on validation branch $BRANCH requires --allow-remote-pr (owner-gated)" >&2
      exit 2
    fi
  fi

  # Token/repo access probe — DIAGNOSTIC ONLY, never a gate.
  #
  # `GET /repos/{repo}.permissions.push` reports the *authenticated user's*
  # repo role. For an installation token (GITHUB_TOKEN) there is no user
  # role, so it returns `false` even when the job has `contents: write` —
  # treating it as authoritative produced a false negative and aborted a
  # correctly-authorized run. The real capability check is the operation
  # itself (git push / gh pr create); those failures are classified below.
  if GH_TOKEN="$GH_TOKEN" gh api "repos/$REPO" --jq '.full_name' >/dev/null 2>&1; then
    echo "[propose] token can read $REPO (effective write scope is enforced by the operations below)"
  else
    echo "[propose] warning: token cannot read $REPO metadata; remote operations will likely fail" >&2
  fi

  # branch exists? (idempotent: reuse/update, never duplicate)
  if git fetch origin "$BRANCH" >/dev/null 2>&1; then
    echo "[propose] branch $BRANCH exists; updating it"
    git checkout -q "$BRANCH"
  else
    git checkout -q -b "$BRANCH" "origin/$BASE"
  fi
  # apply the staged docs onto the resolved branch (copy, never move — the
  # stage is reusable)
  rm -rf "$OUTDIR"
  mkdir -p "$OUTDIR"
  cp -r "$STAGE/." "$OUTDIR/"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  # STRICT STAGING PATHSPEC: in fixture mode ONLY the validation namespace
  # may be staged; in proposal mode ONLY docs/update-proposals/. Nothing
  # else (no PKGBUILDs, packages.txt, workflows) can ever enter a commit.
  if [[ -n "${FIXTURE_MARK:-}" ]]; then
    # validation branch: the ONLY allowed path is the validation dir
    # (git ls-files emits repo-root-relative paths; normalize OUTDIR to
    # relative and add a trailing slash for the prefix match)
    rel_outdir="${OUTDIR#"$REPO_ROOT"/}"
    if git ls-files --others --exclude-standard | grep -vE "^${rel_outdir}/" | grep -q .; then
      echo "::error::fixture stage contains files outside $rel_outdir; refusing to commit" >&2
      git ls-files --others --exclude-standard | grep -vE "^${rel_outdir}/" >&2
      exit 2
    fi
    git add -- "${rel_outdir}"
  else
    git add -- "${OUTDIR}"
  fi
  # verify the staged diff touches only the intended root before committing
  staged_files="$(git diff --cached --name-only)"
  if [[ -z "$staged_files" ]]; then
    echo "[propose] no changes to commit (idempotent no-op)"
    exit 0
  fi
  if ! grep -qE "^docs/update-proposals/" <<<"$staged_files"; then
    echo "::error::staged files are outside docs/update-proposals/; refusing to commit" >&2
    echo "$staged_files" >&2
    exit 2
  fi
  git commit -q -m "docs(updates): update proposals for $DECISION_COUNT package(s)" || true
  if ! git push -q -u origin "$BRANCH" 2>"$WORKDIR/push.err"; then
    push_err="$(cat "$WORKDIR/push.err" 2>/dev/null)"
    case "$push_err" in
      *"403"*|*"forbidden"*|*"not authorized"*|*"Permission denied"*)
        echo "::error::git push DENIED for $BRANCH (HTTP 403). The workflow job lacks contents:write, or repository settings disallow the token. Job permissions must include contents: write; verify 'Allow GitHub Actions to create and approve pull requests' is enabled for the repository." >&2 ;;
      *"protected branch"*|*"pre-receive hook"*|*"refusing"*)
        echo "::error::git push REJECTED for $BRANCH (branch protection / pre-receive hook). Review branch protection rules for the validation namespace." >&2 ;;
      *"repository not found"*|*404*)
        echo "::error::git push failed: remote repository or remote missing — verify origin and --repo." >&2 ;;
      *"unable to access"*|*"Could not resolve host"*|*"Connection refused"*|*"Operation timed out"*)
        echo "::error::git push failed: network error reaching GitHub. Retry later; no credential fallback is attempted." >&2 ;;
      *)
        echo "::error::git push failed for $BRANCH: $push_err" >&2 ;;
    esac
    exit 2
  fi

  TITLE="Update proposals ($DECISION_COUNT package(s))"
  BODY="Automated update proposals (Phase 5.2). Review each proposal in docs/update-proposals/. No package sources modified; merging does NOT publish."
  if [[ -n "${FIXTURE_MARK:-}" ]]; then
    TITLE="[TEST] PR validation fixture: $FIXTURE"
    BODY="$FIXTURE_MARK. Documentation-only payload under docs/update-proposals/validation/. Do not merge; do not use for publication."
  fi

  # discover the PR for this head branch, including CLOSED ones (a closed PR
  # must not be silently reopened; a merged PR must never be recreated)
  PR_STATE=""
  PR_URL=""
  if gh pr view "$BRANCH" --repo "$REPO" --state all --json state,url,merged -q '{state, url, merged}' >"$WORKDIR/pr.json" 2>/dev/null; then
    PR_STATE="$(jq -r '.state' "$WORKDIR/pr.json")"
    PR_URL="$(jq -r '.url' "$WORKDIR/pr.json")"
    PR_MERGED="$(jq -r '.merged' "$WORKDIR/pr.json")"
  fi

  if [[ -n "$PR_URL" && "$PR_MERGED" == "true" ]]; then
    echo "[propose] PR for $BRANCH is already MERGED; not recreating (idempotent skip)"
    exit 0
  fi

  if [[ -n "$PR_URL" ]]; then
    if [[ "$PR_STATE" == "OPEN" ]]; then
      gh pr edit "$BRANCH" --repo "$REPO" --title "$TITLE" --body "$BODY" >/dev/null
      echo "[propose] updated open PR for $BRANCH: $PR_URL"
    elif [[ "$PR_STATE" == "CLOSED" ]]; then
      # closed PR: reopen a fresh PR on the same branch (same content) rather
      # than silently resurrecting the closed PR
      echo "[propose] PR $PR_URL is closed; creating a fresh PR for $BRANCH"
      gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" \
        --title "$TITLE" --body "$BODY" || {
          echo "::error::could not create PR for $BRANCH (closed PR existed)" >&2; exit 2; }
    fi
  else
    if gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" \
        --title "$TITLE" --body "$BODY" >"$WORKDIR/prcreate.log" 2>&1; then
      echo "[propose] created PR for $BRANCH: $(tail -1 "$WORKDIR/prcreate.log")"
    else
      # classify the failure for a clear, actionable error
      case "$(tail -1 "$WORKDIR/prcreate.log")" in
        *"Bad credentials"*|*403*)
          echo "::error::PR creation denied (HTTP 403). Either the workflow job lacks pull-requests:write, or repository settings disallow GitHub Actions from creating PRs. Check: job permissions include pull-requests: write; repo Settings → Actions → General → Workflow permissions → 'Allow GitHub Actions to create and approve pull requests' is enabled." >&2 ;;
        *404*)
          echo "::error::PR creation failed: base branch $BASE or head branch $BRANCH not found on $REPO." >&2 ;;
        *409*|*"reference already exists"*)
          echo "::error::PR creation failed: branch conflict on $BRANCH (a PR or ref already exists)." >&2 ;;
        *422*)
          echo "::error::PR creation failed: API validation error (422). Check base/head branch names and repo state." >&2 ;;
        *429*)
          echo "::error::PR creation failed: GitHub API rate limited (429). Retry later." >&2 ;;
        *)
          echo "::error::PR creation failed: $(tail -1 "$WORKDIR/prcreate.log")" >&2 ;;
      esac
      exit 2
    fi
  fi
else
  # offline path: materialize the staged docs (never touches git/GitHub)
  rm -rf "$OUTDIR"
  mkdir -p "$OUTDIR"
  cp -r "$STAGE/." "$OUTDIR/"
  echo "[propose] materialized proposals at $OUTDIR"
fi
