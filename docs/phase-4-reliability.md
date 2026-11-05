# Phase 4 — Reliability, Monitoring, Recovery & CI/CD Automation

**Date:** 2026-11-06
**Baseline:** Phase 3.5 stable (20 packages, x86-64-v4, unsigned production,
signed staging, zero-mutation repeat publishing).
**Scope:** local implementation + validation; no live deployment performed.

---

## 1. Existing functionality audit (Stage A)

### Workflows

| Workflow | Trigger | Jobs | Purpose |
|---|---|---|---|
| `build-release.yml` | manual (`confirm-production=YES`), weekly schedule (disabled) | prepare → build(≤2 parallel) → cache-verify → publish / publish-signed → **health-check** | production release `repository` (unsigned default) |
| `build-staging.yml` | manual | prepare → build → publish(signed) → **health-check** | signed staging `repository-v4-test` |
| `sync-aur.yml` | hourly + push to packages.txt | sync | mirrors AUR/CachyOS PKGBUILDs → PR |
| `repo-health.yml` *(new)* | manual / schedule / workflow_call | health | read-only release health audit |
| `check-updates.yml` *(new)* | manual / schedule | detect | read-only upstream update detection |

### Scripts (reused, not duplicated)

`generate-matrix.sh` (inventory/approval), `build-in-docker.sh` (container
lifecycle + bootstrap), `build-package.sh` (fingerprint/cache/build/meta),
`publish-prod.sh` (preflight → sign → repo-add → validate → inventory →
publish → verify), `publish-in-docker.sh` (container wrapper),
`validate-release.sh` (local DB↔asset consistency), `verify-remote-release.sh`
(post-publish remote verification), `verify-build-cache.sh` (cache HIT/MISS),
`gh-release-lib.sh` (API retry/backoff/content-aware asset ops),
`sign-helpers.sh`, `pkg-filename-lib.sh`, `critical-packages.sh`,
`rustc-v4-safe.sh`.

### Safety invariants carried into Phase 4

Same-version byte-drift gate, downgrade (vercmp) gate, fail-closed preflight,
fingerprint cache invalidation, stable metadata reuse, DB validation, remote
verification, zero-mutation repeat, `ALLOW_SAME_VERSION_REPLACE` unset,
production unsigned + `TrustAll`.

### Gaps identified

1. No read-only repository **health monitoring** → added `repo-health.sh` + workflow.
2. No **dry-run / pre-mutation manifest / idempotent-recovery** coverage → added.
3. No **automated update detection** → added `check-updates.sh` + workflow.
4. No **post-publication health gate** wired into the release workflows → added.
5. No **API-request observability** → added `api_requests` to the publish SUMMARY.
6. Validation/verification logic existed but was not surfaced as a single
   post-release gate → the health gate now composes it.

---

## 2. Architecture (Stages B–F)

```
                      ┌─────────────────────────────┐
                      │  generate-matrix.sh         │  (inventory, approvals)
                      └──────────────┬──────────────┘
                                     ▼
   build-package.sh ──► fingerprint / cache / build / stable meta
                                     ▼
   cache-verify (verify-build-cache.sh)
                                     ▼
   publish-prod.sh:
     preflight (same-version + downgrade, vercmp)   ← fail closed
     [optional signing]
     repo-add + validate-release.sh + inventory
     pre-mutation manifest (local JSON)
     content-aware publish (gh-release-lib.sh)      ← packages→meta→key→db
     remote verification (verify-remote-release.sh)
                                     ▼
   repo-health.yml (repo-health.sh)  ← read-only post-publication gate
                                     ▼
   check-updates.yml (check-updates.sh) ← independent, read-only
```

### Result states

- **HEALTHY** — integrity intact, inventory complete vs expected, signing
  expectation satisfied, no orphans.
- **DEGRADED** — integrity intact but missing/unexpected assets, or an
  UNKNOWN (unverifiable) sub-check.
- **FAILED** — release missing, DB missing/corrupt, DB↔asset mismatch,
  checksum mismatch, metadata mismatch, signing mismatch, duplicate identity.

---

## 3. Changed files

**New**
- `.github/scripts/repo-health.sh` — read-only health monitor (JSON + summary).
- `.github/scripts/check-updates.sh` — read-only upstream update detection.
- `.github/workflows/repo-health.yml` — manual/schedule/workflow_call health gate.
- `.github/workflows/check-updates.yml` — manual/schedule update detection.
- `.github/tests/test-repo-health.sh` — health monitor regression suite.
- `.github/tests/test-check-updates.sh` — update detector safety suite.
- `docs/phase-4-reliability.md` — this document.

**Modified**
- `.github/scripts/gh-release-lib.sh` — `DRY_RUN` plan-only mode; `api_requests` counter.
- `.github/scripts/publish-prod.sh` — pre-mutation manifest; dry-run gates;
  dry-run skips remote verification; `api_requests` in SUMMARY.
- `.github/scripts/publish-in-docker.sh` — pass `DRY_RUN` into the container.
- `.github/workflows/build-release.yml` — `dry-run` input; `DRY_RUN` env;
  post-publication `health-check` job.
- `.github/workflows/build-staging.yml` — post-publication `health-check` job.
- `.github/tests/test-http500.sh` — recovery idempotency, recovery API-failure,
  recovery-mode downgrade, dry-run, pre-mutation manifest tests.
- `.github/tests/run-tests.sh` — register the two new suites.

---

## 4. Recovery design and limits (Phase 4.2)

Before mutating production, `publish-prod.sh` already: validates every
incoming package, validates versions, verifies remote identities/checksums,
identifies required changes (preflight), and records the current remote
manifest. Added: the manifest is written to a local JSON artifact
(`publish-manifest-<tag>.json`) before mutation, and `DRY_RUN=1` produces the
full plan with zero mutations.

**Explicit limitations:**
- GitHub Releases have **no atomic multi-asset transaction**. A crash
  mid-publish can leave a partially updated release.
- Recovery is therefore **idempotent, content-aware re-run**: the next
  publish reconciles by digest (UNCHANGED skipped, NEW uploaded, CHANGED
  gated). Re-running recovery never adds damage (verified).
- Automatic recovery is safe **only** when the remote state is verifiable.
  If it cannot be verified (DB corrupt, transient API failure), the run
  **aborts** rather than guessing.
- Concurrent publication is prevented by the workflow `concurrency` group
  (`release-repo` / `release-repo-v4-test`); the manifest is the local
  record for post-hoc reconciliation.

---

## 5. CI/CD performance (Phase 4.3)

Baseline (measured locally on the pinned container):

| Metric | Before |
|---|---|
| Container bootstrap (warm) | ≈15 s per build job |
| Full harness wall time | ≈6–8 min |
| Publish `api_requests` (2-pkg proxy, zero-mutation) | 4 |
| Extrapolated 20-pkg zero-mutation summary | `unchanged=44 uploaded=0 replaced=0 failed=0` |

Observability added: `api_requests` in the publish SUMMARY. No
correctness-affecting optimization was applied — the Phase 3.5 cache/publish
logic is preserved verbatim; only read-only observability and the dry-run/
manifest planning path were added.

---

## 6. Update detection (Phase 4.4)

`check-updates.sh` classifies each package from its committed PKGBUILD
without sourcing it: expands PKGBUILD variables, then probes GitHub
tags/releases, GitLab tags, npm registry, or `git ls-remote`, comparing with
`vercmp` (never lexical). Results: `UP_TO_DATE`, `UPDATE_AVAILABLE`,
`SOURCE_CHANGED`, `REBUILD_REQUIRED`, `MANUAL_REVIEW`, `CHECK_FAILED`.
Probe failures are **never** reported as updates. The workflow may open a
report-only PR; it never modifies sources or publishes.

---

## 7. Validation integration (Phase 4.5)

Pre-publication: the existing fail-closed preflight (same-version +
downgrade + inventory) is unchanged. Post-publication: the new `health-check`
job (read-only) validates inventory, checksums, metadata, database, signing
expectation, and idempotency for the expected matrix, deriving counts from
the inventory (never hardcoding 20/44).
