## Phase 5.2 — Final Validation

Status: LIVE PASS
Date: 2026-11-06

- Local regression suite: PASS
- GITHUB_TOKEN scoped permissions: PASS
- Live validation PR creation: PASS (#3)
- Deterministic fixture identity: PASS
- Idempotent rerun: PASS
- Duplicate PR prevention: PASS
- Validation PR closed: PASS
- Remote validation branch deleted: PASS

Final Result: ALL ACCEPTANCE CRITERIA SATISFIED

# Phase 5.4 — Final Validation

**Date:** 2026-11-06

## 1. What was validated

All Phase 1–4 and Phase 5 components were exercised locally in the pinned
Arch container / host harness (see `phase-4-reliability.md` §11 for the
Phase 4 baseline; this document reports the Phase 5 run).

No live GitHub operations were performed (no push, no PR creation, no
publication, no Pages enablement) — those require owner authorization.

## 2. Phase 5 test results (local)

| Suite | Source | Result |
|---|---|---|
| lifecycle detection + safety (incl. vercmp provisioning, SIGPIPE regression, source-parsing + probe-classification accuracy) | `test-check-updates.sh` | 48 PASS |
| update proposals (offline) + Phase 5.2 PR validation | `test-propose-updates.sh` | 31 PASS |
| workflow audit (+ Phase 5.4 gates + PR-validation gates) | `test-workflow-audit.sh` | 36 PASS |
| artifact collection (REST retrieval, mock API) | `test-artifact-collection.sh` | 30 PASS |
| metrics builder + history (incl. strict KPI mapping) | `dashboard/tests/test-metrics.sh` | 24 PASS |
| dashboard build (incl. incomplete banner) | `dashboard/tests/test-dashboard.sh` | 19 PASS |
| full harness (Phase 1–4 regressions) | `run-tests.sh` | overall 0 FAIL (see §4) |
| browser render (headless Chromium) | dashboard with fixture snapshot | KPIs, 4 charts, table/filter/search, completeness banner OK |

## 3. Static analysis

- `bash -n` on all `*.sh` in `.github/scripts`, `.github/tests`, `dashboard/tests`: pass.
- `git diff --check`: clean.
- `actionlint` on all workflows in `.github/workflows`: clean.
- `shellcheck -S warning`: only pre-existing advisory findings; none
  introduced by Phase 5.

## 4. Full harness regression

`REPO_ROOT=$PWD RUN_PROD_SCENARIOS=1 bash .github/tests/run-tests.sh`
runs every existing suite plus the newly registered Phase 5 suites.
Measured (pinned container): overall `PASS=56 FAIL=0`, `EXIT=0` — 18 suite
runs, including lifecycle (48), proposals (31), workflow-audit (36),
artifact-collection (30), metrics (24), dashboard (19), and all Phase 1–4
suites (host + container). 657 assertions total, 0 failures.

## 5. Phase 5.4 safety re-verification

- Production remains unsigned; staging remains signed; `Optional TrustAll`
  unchanged.
- `DRY_RUN=1` blocks all remote mutations (lib-level short-circuit,
  missing-release planning, no-create, zero-mutation SUMMARY) — tested.
- Production publication requires `confirm-production=YES` (manual).
- No scheduled production release is enabled (audit covers all Phase 4/5
  workflows).
- Health gates unchanged and functional (post-publication, never after
  failure).
- Workflow concurrency does not cancel in-flight publishes.
- Recovery remains idempotent (repeat recovery = zero mutations).
- Proposal PRs are gated behind `open-pr` and cannot publish (no merge
  automation; publication path is separate + owner-authorized).
- Dashboard + lifecycle detection use read-only permissions; observability
  workflow is `contents: read` + `actions: read` (artifact API only, GETs
  only) and never ingests its own run's artifacts.
- The observability workflow fails on `NO_DATA` (explicitly labelled
  incomplete dashboard) and never claims a populated dashboard without
  verified sources.
- Public/configured inventory (`packages.txt`) is kept separate from the
  published package count (production health report) — nothing is hardcoded.

## 6. Live validation required (PENDING, owner-authorized)

| Item | Gate |
|---|---|
| Lifecycle workflow run (real upstream probes; vercmp now provisioned) | owner dispatch |
| Proposal PR creation (real remote) | owner dispatch with `open-pr=true` |
| Phase 5.2 PR validation — remote (Mode B) | owner dispatch with `open-pr=true` + `allow-remote-pr=true` |
| Observability workflow run + cross-run artifact download | owner dispatch |
| First publish-sidecar uploads (`publish-summary-*`, `run-metrics-*`) | existing production/staging authorization |
| Optional Pages enablement | owner repo-settings change |
| Production/staging publication | existing manual authorization |

No acceptance criterion that requires a live GitHub run is claimed as
verified here; those remain `PENDING` until executed by the owner.

### Required repository settings (owner check before remote PR runs)

The workflow needs the standard `GITHUB_TOKEN` job permissions
(`contents: write`, `pull-requests: write` on the `propose` job only).
Before a remote validation run, verify:

1. **Settings → Actions → General → Workflow permissions**: the repository
   allows GitHub Actions to create/approve pull requests (toggle **Allow
   GitHub Actions to create and approve pull requests** must be ON). If it
   is OFF, `gh pr create` returns 403 and the script emits the specific
   diagnostic (job permission OR this setting).
2. The `propose` job's `permissions:` block retains exactly
   `contents: write` + `pull-requests: write`; the top-level workflow
   permissions stay read-only (`contents: read`).
3. Validation branches (`validation/phase5-pr-test-*`) are not protected by
   branch rules that would reject pushes from the workflow token (if they
   are, the push returns 403 and is reported as a permission denial).
4. No PAT is required for the standard flow; a PAT is only justified if a
   documented repository restriction blocks the workflow token (e.g.
   repository-level "require approval for workflow runs" or branch
   protection requiring a user token) — the script never substitutes or
   recommends a credential automatically.

## 7. Verdict

The project is **deployment-ready (PARTIALLY READY)** for v1.0: all local
implementation and regression work is complete, static analysis is clean,
and no known critical defect remains in the local tree.

Status by criterion:

| Criterion | Status |
|---|---|
| Lifecycle detection (probes, parser, classification) | PASS (local + mock) — live workflow PENDING |
| Proposal generation (deterministic, evidence-only) | PASS (local) |
| PR creation + idempotency (Mode A mock verified) | PASS (mock) — remote PENDING |
| Permission preflight / least-privilege | MOCK VERIFIED |
| No auto-merge / no auto-publication | PASS (workflow audit) |
| Dashboard KPI accuracy (strict mapping + null semantics) | PASS (local + mock + browser render) |
| Observability completeness/history | PASS (local) — live workflow PENDING |
| Production/staging safety invariants | PASS (harness) |
| v1.0 milestone | PARTIALLY READY — remote PR validation + live workflow runs PENDING owner authorization |

Final `VERIFIED` status for the remote items in §6 awaits the owner's
authorized live runs.
