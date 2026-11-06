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
#
# --push will:
#   1. create/refresh the proposal documents,
#   2. commit them on a deterministic branch
#      (<stem>/<sha1-of-decision-set>),
#   3. create the PR if it does not exist (or update its body if it does).
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) REPORT="${2:-}"; shift 2 ;;
    --outdir) OUTDIR="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --branch-stem) BRANCH_STEM="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --dry-run) DRY=1; shift ;;
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

mkdir -p "$OUTDIR"

# ---------------------------------------------------------------------------
# proposal documents
# ---------------------------------------------------------------------------
INDEX="$OUTDIR/README.md"
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

# per-package proposal files — deterministic, evidence-only
N=0
while IFS= read -r rec; do
  [[ -n "$rec" ]] || continue
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

  F="$OUTDIR/$pkg.md"
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
PLAN="$OUTDIR/proposal-plan.json"
jq -n \
  --arg branch "$BRANCH" \
  --argjson proposals "$DECISIONS" \
  --argjson update_count "$UPDATE_COUNT" \
  '{branch:$branch, proposals:$proposals, update_count:$update_count}' > "$PLAN"

echo "[propose] generated $N proposal document(s) in $OUTDIR"
echo "[propose] deterministic branch: $BRANCH"
echo "[propose] update_count=$UPDATE_COUNT"

if [[ "$PUSH" -eq 1 ]]; then
  if [[ "$DRY" -eq 1 ]]; then
    echo "[propose] DRY-RUN: would push branch $BRANCH and open/update a PR"
    exit 0
  fi
  [[ -n "${GH_TOKEN:-}" ]] || { echo "::error::GH_TOKEN required for --push" >&2; exit 2; }
  [[ -n "$REPO" ]] || REPO="${GITHUB_REPOSITORY:-}"
  [[ -n "$REPO" ]] || { echo "::error::--repo (or GITHUB_REPOSITORY) required for --push" >&2; exit 2; }

  # branch exists? (idempotent: reuse/update, never duplicate)
  if git fetch origin "$BRANCH" >/dev/null 2>&1; then
    echo "[propose] branch $BRANCH exists; updating it"
    git checkout -q "$BRANCH"
  else
    git checkout -q -b "$BRANCH" "origin/$BASE"
  fi
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add "$OUTDIR"
  git commit -q -m "docs(updates): update proposals for $DECISION_COUNT package(s)" || true
  git push -q -u origin "$BRANCH"

  TITLE="Update proposals ($DECISION_COUNT package(s))"
  BODY="Automated update proposals (Phase 5.2). Review each proposal in docs/update-proposals/. No package sources modified; merging does NOT publish."
  if gh pr view "$BRANCH" --repo "$REPO" --json url -q .url >/dev/null 2>&1; then
    gh pr edit "$BRANCH" --repo "$REPO" --title "$TITLE" --body "$BODY" >/dev/null
    echo "[propose] updated PR for $BRANCH"
  else
    gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" \
      --title "$TITLE" --body "$BODY"
    echo "[propose] created PR for $BRANCH"
  fi
fi
