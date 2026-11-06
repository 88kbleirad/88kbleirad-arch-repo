# Phase 5 — Package Lifecycle & Update Review

**Date:** 2026-11-06
**Status:** implemented + locally validated (no live GitHub operations performed)

This document covers Phase 5.1 (automated package lifecycle detection and
reporting) and Phase 5.2 (update proposal generation and review workflow).

---

## 1. Scope

Extends the Phase 4.4 update detector (`check-updates.sh`) — it is **not**
a competing system. The old detector produced a 6-state update report; the
Phase 5 detector keeps all prior fields and classifications and adds
lifecycle fields, additional states, and a stable report schema.

Read-only by design: nothing in Phase 5.1/5.2 modifies package sources,
pushes to `main`, publishes, or deletes assets. All automatic actions are
gated behind explicit owner-dispatched inputs.

## 2. Architecture

```
packages.txt ──► package discovery (names + type hints)
                       │
                       ▼
PKGBUILD (committed) ──► parse pkgver / pkgrel / epoch / source URL
                       │
                       ▼
upstream probe (read-only, timeout):
   git ls-remote | GitHub API | GitLab API | npm registry
                       │
                       ▼
vercmp (pacman semantics) ──► lifecycle classification
                       │
                       ▼
update-report.json + Markdown summary (check-updates.sh)
                       │
                       ▼
propose-updates.sh (Phase 5.2):
   deterministic proposal documents (docs/update-proposals/)
   + optional gated PR (open-pr input only)
```

## 3. Lifecycle states

| State | Meaning |
|---|---|
| `UP_TO_DATE` | local version equals latest verified upstream (vercmp) |
| `UPDATE_AVAILABLE` | upstream has a newer verified version |
| `SOURCE_CHANGED` | VCS/git+ upstream HEAD moved (no version claimed) |
| `REBUILD_REQUIRED` | upstream pinned/checksum state requires a rebuild |
| `MANUAL_REVIEW` | unsupported/unparsable source shape (never guessed) |
| `CHECK_FAILED` | upstream probe failed (transient/network/rate limit) |
| `UPSTREAM_UNAVAILABLE` | upstream repository not found (404) |
| `UPSTREAM_ARCHIVED` | upstream repository marked archived (GitHub) |
| `UNKNOWN` | no probe could be attempted |

State semantics are independent from repository health verdicts
(`HEALTHY`/`DEGRADED`/`FAILED` in `repo-health.sh`).

Network/probe failures are **never** reported as updates (`CHECK_FAILED` /
`UPSTREAM_*`). `vercmp` (pacman-contrib) is the only version comparator.

Probe failures are classified (`note` + `probe_error`): `UPSTREAM_UNAVAILABLE`
for a resolved-but-missing upstream (git repo 404, npm package 404,
GitHub repo 404), `CHECK_FAILED` with a reason for transient failures
(rate limit 403/429, registry/server error, timeout, unreachable).
A GitHub repository **rename** (canonical repo name differs, e.g.
printcraft → pdfcraft) is `MANUAL_REVIEW` — identity cannot be assumed. A
pure owner transfer (same repo name) leaves the source URL valid and is
not flagged. (VCS revisions are compared by abbreviated-prefix against
upstream HEAD; a full-vs-abbreviated textual difference alone is never a
source change.)

## 4. Report schema (`check-updates.sh`)

Per-package object (stable, additive since Phase 4.4):

```json
{
  "package": "beautyline",
  "current_version": "3.0.5",
  "current_epoch": "2",
  "current_release": "2",
  "upstream_version": "3.0.5",
  "upstream_url": "https://gitlab.com/...",
  "update_type": "UP_TO_DATE",
  "package_type": "stable",
  "source_kind": "gitlab",
  "source_reference": "",
  "rebuild_required": false,
  "risk_level": "low",
  "recommended_action": "none",
  "probe_ok": true,
  "probe_error": "",
  "checked_at": "2026-11-06T00:00:00Z",
  "note": "current matches"
}
```

`probe_error` is `""` when the probe succeeded; otherwise it carries the
classified failure reason (`missing`, `auth`, `network_error`, `timed_out`
for git; npm/GitHub failures are described in `note`).

`package_type` is a best-effort classification (stable / vcs / binary /
local / xlibre) from the package name and `packages.txt` prefixes — it is
never authoritative. `checked_at` is a UTC timestamp.

### Discovery

Package discovery reads `packages.txt` (never hardcoded counts). Type hints:
`local:` / `xlibre:` prefixes; `xlibre-*` name prefix; `*-git/-hg/-svn`
for VCS; `*-bin` for binary packages.

## 5. Mock hooks for offline tests

Test-only environment variables (never set in production workflows):

| Variable | Effect |
|---|---|
| `MOCK_PROBE_GIT_REFS` | simulated `git ls-remote` output (empty = failed probe) |
| `MOCK_PROBE_GIT_ERROR` | reason for the empty GIT_REFS mock (`missing`/`auth`/…) |
| `MOCK_PROBE_GITHUB_JSON` / `MOCK_PROBE_GITHUB_STATUS` | GitHub releases/tags mock body/status |
| `MOCK_PROBE_GITHUB_REPO_JSON` / `MOCK_PROBE_GITHUB_REPO_STATUS` | GitHub repository metadata mock (include `full_name` for rename tests) |
| `MOCK_PROBE_GITLAB_JSON` | GitLab tags mock |
| `MOCK_PROBE_NPM_JSON` / `MOCK_PROBE_NPM_STATUS` | npm registry mock body/status (404/403/429/5xx) |
| `MOCK_PROBE_HTTP_STATUS` | generic HEAD mock |

## 6. Update proposals (Phase 5.2)

### `propose-updates.sh`

- Reads the verified `update-report.json`; derives a **decision set** of
  only `UPDATE_AVAILABLE` / `SOURCE_CHANGED` / `REBUILD_REQUIRED`.
- Writes deterministic proposal documents into `docs/update-proposals/`:
  - `README.md` — index of automatic proposals + manual-review candidates;
  - `<pkg>.md` — evidence-based proposal (versions, upstream reference,
    risk, validation evidence, required human review);
  - `proposal-plan.json` — machine-readable plan (branch, proposals, counts).
- **Never** edits PKGBUILDs and never invents checksums; the documents state
  that any checksum change must be verified by the maintainer.
- Deterministic branch name: `update-proposal/<sha1-of-decision-set>` so
  identical update sets reuse the same branch/PR (no duplicates).
- `--push` requires `GH_TOKEN`, `--repo`, and is only used by the gated
  workflow job. `--dry-run` prints the plan and touches nothing.
- **Permission model**: the real capability check is the operation itself
  (`git push`, `gh pr create`) — the job-scoped `contents: write` /
  `pull-requests: write` permissions are authoritative. The script no
  longer treats the repository metadata `permissions.push` value as a gate:
  for an installation token (GITHUB_TOKEN) it reports `false` even when the
  job has write permissions (there is no authenticated user role). A
  read-only API probe is retained for diagnostics only, and real push/PR
  failures are classified (403 → job permission or repository "Allow
  GitHub Actions to create and approve pull requests" setting; 404/409/
  422/429 → precise actionable messages). The script fails closed on real
  permission failures and never retries with another credential.
- **PR idempotency**: PR discovery uses `gh pr view --state all`; an open
  PR is updated in place (no duplicate), a closed PR is never silently
  reopened (a fresh PR is created on the same branch), and a merged PR is
  never recreated. API errors (403/404/409/422/429) are classified into
  actionable messages.

### Phase 5.2 PR validation (TEST ONLY)

Two modes, both isolated from genuine proposals:

- **Mode A — local/mocked (default).** `--fixture <id>` generates a
  documentation-only fixture under `docs/update-proposals/validation/
  phase5-pr-test-<id>/` with branch `validation/phase5-pr-test-<id>`.
  `--push` on a validation branch is REFUSED without
  `--allow-remote-pr`. `test-propose-updates.sh` exercises this with a
  mock `gh` + a local bare remote — zero remote writes.
- **Mode B — owner-authorized remote.** The workflow's `allow-remote-pr`
  input (default `false`) + `open-pr=true` together authorize one remote
  validation PR. The fixture identity is the first 16 hex chars of a
  SHA-256 digest over the canonical normalized fixture content (sorted
  package/update_type/upstream_version/source_reference tuples) — no
  timestamps/nondeterminism. Identical reruns target the same branch/PR;
  changed content produces a new identity. The branch suffix is validated
  as hex-only. The payload is documentation-only (manifest + identity
  plan), clearly labelled `TEST ONLY — PHASE 5.2 PR VALIDATION`, never
  merged, never used for publication.

### Workflow integration (`check-updates.yml`)

- `detect` job runs lifecycle detection (read-only) and uploads
  `update-report.json`.
- `propose` job runs only when `open-pr=true` is dispatched by the owner
  (manual). It has scoped `contents: write` + `pull-requests: write`
  permissions and never merges; merging is a human action.
- Top-level workflow permissions are read-only (`contents: read`); only the
  `propose` job escalates. No `pull_request_target` path exists (untrusted
  PR content never gets privileged tokens).
- The proposal PR is a review proposal only — it never triggers publication.
  Publication remains gated by the existing release workflows and owner
  authorization. PRs created with `GITHUB_TOKEN` do not trigger further
  workflow runs (GitHub does not fire events on token-created PRs), so CI
  is not re-run by proposal creation — by design.

## 7. Acceptance / tests

- `test-check-updates.sh` (host): 48 assertions — legacy safety semantics,
  epoch/pkgrel parsing, vercmp non-lexical, missing-vercmp fail-closed
  (rc 2), epoch/pkgver/pkgrel comparison smoke, 404/archived/empty upstream
  classification, VCS pinned-commit states, package type, schema, offline
  discovery from packages.txt, a real `git ls-remote` regression
  (20k-ref bare repo via a local `file://` remote — reproduces the SIGPIPE
  broken-pipe failure of the previous `printf | awk 'exit'` parser), and
  accuracy hardening: nested-variable + quoted `git+"URL"` source parsing,
  `?signed` VCS syntax, git probe failure classification (missing/transient),
  npm 404/403 classification, GitHub repository rename → MANUAL_REVIEW,
  abbreviated-pkgver-SHA vs full upstream HEAD comparison (false-positive
  elimination), unrecoverable pkgver revision → MANUAL_REVIEW.
- `test-propose-updates.sh` (host): 31 assertions — proposal generation for
  verified states only, index separation, deterministic branches, idempotent
  docs, no checksum/PKGBUILD edits, no secrets, no-update report, and Phase
  5.2 PR validation (mock gh + local bare remote): fixture isolation,
  allow-remote-pr gate, dry-run zero remote writes, duplicate-PR
  prevention, closed/merged PR handling, API error classification,
  repo-metadata-push=false NOT gating, real git-push-denial classification
  (exit 2 + zero remote writes), SHA-256 fixture identity (same/different
  content), and validation-only staging contents.
- `test-workflow-audit.sh` (host): 36 assertions — Phase 5 workflow
  read-only/gating checks + vercmp provisioning + observability REST
  retrieval wiring + Phase 5.2 owner-gate/least-privilege + fixture-digest
  assertions.
- `test-metrics.sh` / `test-dashboard.sh` cover report consumers and the
  completeness banner.
- `test-artifact-collection.sh` (host): 30 assertions — cross-workflow REST
  retrieval, source-run selection, expiration/missing/failed/corrupt
  sources, prod/staging separation, history persistence, completeness
  classification, no accidental API writes.

## 8. Manual verification (fish shell)

```fish
# lifecycle detection (read-only)
set -x REPO_ROOT (pwd)
set -x GH_TOKEN (gh auth token)
bash $REPO_ROOT/.github/scripts/check-updates.sh \
  --json /tmp/update-report.json --summary /tmp/update-summary.md

# proposal preview (no git/GitHub side effects)
bash $REPO_ROOT/.github/scripts/propose-updates.sh \
  --report /tmp/update-report.json --outdir /tmp/proposals

# Phase 5.2 PR validation — LOCAL/mocked (Mode A; zero remote writes)
bash $REPO_ROOT/.github/tests/test-propose-updates.sh

# Phase 5.2 PR validation — REMOTE (Mode B; OWNER-AUTHORIZED ONLY)
# first run: creates validation/phase5-pr-test-<sha256-16> + a labelled PR
gh workflow run check-updates.yml -f open-pr=true -f allow-remote-pr=true
gh run watch --exit-status (gh run list --workflow=check-updates.yml --limit 1 --json databaseId --jq '.[0].databaseId')

# second run (same dispatch): must REUSE the same branch + PR (no duplicate)
gh workflow run check-updates.yml -f open-pr=true -f allow-remote-pr=true

# audit the validation PR
gh pr list --head validation/phase5-pr-test-owner-<digest> --state all --json number,url,headRefName,state,mergeCommit

# cleanup (owner-only, targeted)
gh pr close <PR_N> --repo 88kbleirad/88kbleirad-arch-repo
git push origin --delete validation/phase5-pr-test-owner-<digest>
```

Expected behavior:

- **First run**: creates the validation branch (documentation-only payload:
  `README.md` + `fixture-plan.json`), pushes it, opens one PR titled
  `[TEST] PR validation fixture: <id>`. PR state `OPEN`.
- **Second run (identical fixture)**: the digest is identical → same
  branch → the existing OPEN PR is updated in place. No second PR.
- **Changed fixture content**: new digest → new branch → new PR (only when
  the fixture identity genuinely changed).
- **Closed PR**: not silently reopened; a fresh PR is created on the same
  branch. **Merged PR**: never recreated (idempotent skip).
- **Denied push / PR 403**: exit 2 with an actionable diagnostic (job
  permission or repo "Allow GitHub Actions to create and approve pull
  requests" setting); zero remote writes on a push denial.
