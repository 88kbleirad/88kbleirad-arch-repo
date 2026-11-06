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
  "checked_at": "2026-11-06T00:00:00Z",
  "note": "current matches"
}
```

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
| `MOCK_PROBE_GIT_REFS` | simulated `git ls-remote` output |
| `MOCK_PROBE_GITHUB_JSON` / `MOCK_PROBE_GITHUB_STATUS` | GitHub releases/tags mock body/status |
| `MOCK_PROBE_GITHUB_REPO_JSON` / `MOCK_PROBE_GITHUB_REPO_STATUS` | GitHub repository metadata mock |
| `MOCK_PROBE_GITLAB_JSON` | GitLab tags mock |
| `MOCK_PROBE_NPM_JSON` | npm registry mock |
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

### Workflow integration (`check-updates.yml`)

- `detect` job runs lifecycle detection (read-only) and uploads
  `update-report.json`.
- `propose` job runs only when `open-pr=true` is dispatched by the owner
  (manual). It has scoped `contents: write` + `pull-requests: write`
  permissions and never merges; merging is a human action.
- The proposal PR is a review proposal only — it never triggers publication.
  Publication remains gated by the existing release workflows and owner
  authorization.

## 7. Acceptance / tests

- `test-check-updates.sh` (host): 34 assertions — legacy safety semantics,
  epoch/pkgrel parsing, vercmp non-lexical, missing-vercmp fail-closed
  (rc 2), epoch/pkgver/pkgrel comparison smoke, 404/archived/empty upstream
  classification, VCS pinned-commit states, package type, schema, offline
  discovery from packages.txt, and a real `git ls-remote` regression
  (20k-ref bare repo via a local `file://` remote — reproduces the SIGPIPE
  broken-pipe failure of the previous `printf | awk 'exit'` parser).
- `test-propose-updates.sh` (host): 12 assertions — proposal generation for
  verified states only, index separation, deterministic branches, idempotent
  docs, no checksum/PKGBUILD edits, no secrets, no-update report.
- `test-workflow-audit.sh` (host): 29 assertions — Phase 5 workflow
  read-only/gating checks + vercmp provisioning + observability REST
  retrieval wiring.
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
```
