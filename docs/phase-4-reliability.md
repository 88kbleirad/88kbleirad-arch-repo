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
| `repo-health.yml` *(new)* | manual / workflow_call (post-publication) | health | read-only release health audit |
| `check-updates.yml` *(new)* | manual | detect | read-only upstream update detection |

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

| Verdict | Meaning | Exit | Job |
|---|---|---|---|
| `HEALTHY` | integrity intact, inventory complete vs expected, signing expectation satisfied, no orphans | 0 | green |
| `DEGRADED` | integrity intact but missing/unexpected (orphaned) assets, or an `UNKNOWN` (unverifiable) sub-check | 1 | **red** |
| `FAILED` | release missing, DB missing/corrupt, DB↔asset mismatch, checksum mismatch, metadata mismatch, signing mismatch, duplicate identity, malformed expected inventory | 1 | **red** |

A verdict is never weakened: `DEGRADED`/`FAILED` always fail the job, and
`repo-health.yml` additionally refuses to report success unless the JSON
report exists and carries an `overall_status` (a missing report is an
infrastructure failure, not a repository verdict).

### Hardening pass (final Phase 4)

| Change | Reason |
|---|---|
| `repo-health.yml`: report upload `if: always()` + explicit missing-report infra failure | diagnostic retention on `DEGRADED`/`FAILED` without ever masking the failure |
| `repo-health.sh`: full-schema JSON written when the release is not found | previously only `{"error":...}` on stdout, so the workflow had no parseable report |
| `repo-health.sh`: `cleanup_proposal` (name/id/size/digest) + orphaned-signature detection | explicit, read-only stale-asset reporting (staging `beautyline-2.3.0.5-1` class of find) |
| `repo-health.sh`: malformed `--expected` inventory ⇒ `FAILED` | an unparsable matrix must fail closed, never pass as `HEALTHY` |
| `repo-health.sh`: `commit_sha` from `COMMIT_SHA`/`GITHUB_SHA` | deterministic, trusted provenance; stays empty (never invented) when unavailable |
| `publish-prod.sh` + `gh-release-lib.sh`: `DRY_RUN=1` blocks release creation, upload and delete **inside the lib** | dry-run previously still executed `POST /releases` when the release was absent |
| `build-release.yml`: `inputs.signing-mode || 'unsigned'` in the health gate | non-`workflow_dispatch` events (authorized schedule) have empty inputs and would silently skip the gate |
| `build-release.yml`: `DRY_RUN: ${{ inputs.dry-run && '1' || '0' }}` | `inputs.dry-run` renders `true`/`false`; the scripts check `== "1"` — an unnormalized binding would silently execute real mutations on a dry-run request |
| `build-release.yml` / `build-staging.yml`: `cancel-in-progress: false` | GitHub Releases are non-atomic; cancelling an in-flight publish can orphan partial assets — a second run queues and reconciles |
| `publish-stage.sh`: fail-closed `DRY_RUN` guard | staging uses legacy `gh release create/upload` (no dry-run); any dry-run request aborts before mutation |
| `check-updates.yml`: input bound via `env`, not shell interpolation | expression-injection hardening (same rule as `generate-matrix.sh`) |
| `.github/tests/test-workflow-audit.sh` | locks triggers, gate conditions, permissions, inventory propagation |

---

## 3. Changed files

**New**
- `.github/scripts/repo-health.sh` — read-only health monitor (JSON + summary).
- `.github/scripts/check-updates.sh` — read-only upstream update detection.
- `.github/workflows/repo-health.yml` — manual/workflow_call health gate (no schedule trigger).
- `.github/workflows/check-updates.yml` — manual update detection (no schedule trigger).
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
  recovery-mode downgrade, dry-run (incl. lib-level write guards), pre-mutation
  manifest tests.
- `.github/tests/test-repo-health.sh` — + malformed inventory, orphaned
  signatures, cleanup proposal, commit_sha, release-not-found report tests.
- `.github/tests/test-workflow-audit.sh` — trigger/gate/permissions/inventory
  regression suite (new).
- `.github/tests/run-tests.sh` — register the new suites.

---

## 3b. Orphan detection and safe cleanup (report-only)

`repo-health.sh` classifies assets that are **not referenced by the current
database**:

- stale package archives (`*.pkg.tar.zst` absent from the DB),
- orphaned detached signatures (a `.sig` whose owner archive no longer exists),
- unexpected metadata (`v4-*.meta.json` not in the DB/expected inventory).

Each such asset is reported with its exact API identity — name, asset id,
size, and digest — in two places:

- `cleanup_proposal` (JSON array) and the `unexpected_assets` field in the
  health report,
- an "Orphaned assets" table in the GitHub Actions summary.

Behavior is strictly **report-only and read-only**:

- detection never changes the verdict: a repository with orphans is
  `DEGRADED` (never `HEALTHY`);
- no cleanup is performed by monitoring or by normal staging publication;
- assets still referenced by the current DB are never proposed;
- a protected recovery state (a failed/restored build) is managed by the
  publish pipeline's `protect-*.txt`/`EXCLUDED_BASES_FILE` logic, not by
  the monitor.

Any destructive cleanup is a **separately authorized operation**: an
operator runs `gh release delete-asset` with exact asset names from the
proposal (e.g. `gh release delete-asset repository-v4-test \
  beautyline-2.3.0.5-1-any.pkg.tar.zst --repo 88kbleirad/88kbleirad-arch-repo -y`).
The health monitor never deletes anything.

---

## 4. Recovery design and limits (Phase 4.2)

Before mutating production, `publish-prod.sh` already: validates every
incoming package, validates versions, verifies remote identities/checksums,
identifies required changes (preflight), and records the current remote
manifest. Added: the manifest is written to a local JSON artifact
(`publish-manifest-<tag>.json`) before mutation, and `DRY_RUN=1` produces the
full plan with zero mutations.

### Dry-run contract (`DRY_RUN=1`)

- read-only GitHub API requests are allowed (status classification),
- the publication plan is calculated exactly (uploads/replacements/deletions
  are printed as `DRY-RUN: would ...` and counted in the SUMMARY),
- **no mutation is ever executed**: release creation, asset upload/replace,
  stale-archive deletion, signature purge, and manifest generation are all
  blocked; write helpers (`gh_upload_asset`, `gh_delete_asset`) short-circuit
  before any API call,
- a **missing release** is planned, not mutated: the release is reported as
  "would create", every local asset is classified NEW/MISSING, and the plan
  completes with exit 0 (never creating the release),
- the remote manifest inventory is left identical,
- post-publication remote verification is skipped (nothing was changed),
- a repeat dry-run produces the identical plan and zero mutations (tested),
- a failed API query during planning aborts the dry-run (never guessed).

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
the inventory (never hardcoding 20/44). The expected `JSON` array arrives
from `needs.prepare.outputs.matrix` (`EXPECTED_PACKAGES`) — it is a
propagated value, never a hardcoded count. `repo-health.sh` fails closed on a
malformed array.

---

## 8. Manual verification commands (fish shell)

```fish
# Health check (read-only), production unsigned
set -x GH_TOKEN (gh auth token)
set -x REPO_ROOT (pwd)
bash $REPO_ROOT/.github/scripts/repo-health.sh repository \
  88kbleirad/88kbleirad-arch-repo \
  --signing-mode unsigned --build-profile x86-64-v4 \
  --json health-report.json --summary health-summary.md

# Health check, staging signed
bash $REPO_ROOT/.github/scripts/repo-health.sh repository-v4-test \
  88kbleirad/88kbleirad-arch-repo \
  --signing-mode signed --build-profile x86-64-v4 \
  --json staging-health.json --summary staging-health.md

# Dry-run production publication (plans, never mutates)
DRY_RUN=1 EXPECTED_PACKAGES='[...]' \
  bash $REPO_ROOT/.github/scripts/publish-prod.sh

# Verify remote release after a real publish
bash $REPO_ROOT/.github/scripts/verify-remote-release.sh repository \
  88kbleirad/88kbleirad-arch-repo '["pkg1",...]' \
  --signing-mode unsigned

# Update detection (read-only)
bash $REPO_ROOT/.github/scripts/check-updates.sh --json update-report.json
```

> **Trust model.** The repository keeps the documented policy
> `SigLevel = Optional TrustAll` (client policy in `README.md`; the
> in-repo `pacman/pacman.conf` is the build container's, not the client's).
> Checksum/integrity verification is
> performed by `repo-health.sh` (sha256 vs the GitHub API digest) and by
> `validate-release.sh`; this is **not** cryptographic package
> authentication. Staging publishes signed artifacts (`GPG_PRIVATE_KEY` in
> the `package-signing` environment); production stays unsigned by design.

---

## 9. Rollback and recovery procedure

1. **Interrupted publish** — the local `publish-manifest-<tag>.json`
   records the pre-mutation asset manifest. Re-run the same publish:
   content-aware reconciliation uploads missing assets, gates same-version
   drift, and never downgrades.
2. **Corrupt/absent database** — `publish-prod.sh` reconstructs the DB from
   validated release archives (fail-closed: refuses if any expected package
   is missing).
3. **Failed/restored build** — the affected package is preserved via
   `protect-*.txt`/`EXCLUDED_BASES_FILE`; the next run rebuilds it.
4. **Release asset drift** — `repo-health.sh` flags orphans in
   `cleanup_proposal`; delete them only as a separately authorized
   operation (never via monitoring).

---

## 10. Operational troubleshooting

| Symptom | Cause / check |
|---|---|
| `health-check` failed, report exists | verdict is `DEGRADED`/`FAILED` — inspect `health-report-<tag>.json` (download from the run's artifacts) |
| `health-check` failed, no report | infrastructure failure (checkout/tools/script) — the workflow fails explicitly |
| `repo-health` reports `commit_sha` empty | no `COMMIT_SHA`/`GITHUB_SHA` context — never invented, repository still healthy |
| dry-run exits nonzero | preflight gate (same-version/downgrade) tripped, or a remote query failed — release untouched |
| publish SUMMARY `failed>0` | asset content/remote checkum error — abort before further mutations |
| staging orphans reported | `unexpected_assets` + `cleanup_proposal` — read-only, delete only with explicit authorization |
| report `database_status=FAIL` | DB missing/corrupt/mismatched — never repair via monitoring; re-run publish recovery |

---

## 11. Test coverage

Host-suite (`run-tests.sh` steps 1–4): bash `-n`, YAML validation,
actionlint (when installed), `test-http500.sh` (lib retries/inventory —
prod scenarios skipped), `test-content-aware.sh`, `test-build-cache.sh`,
`test-rustc-wrapper.sh`, `test-epoch-filenames.sh`,
`test-check-updates.sh`, `test-workflow-audit.sh`, `test-matrix.sh`.

Container suite (step 5, pinned Arch image): `test-signing.sh`,
`test-signing-mode.sh`, `RUN_PROD_SCENARIOS=1 test-http500.sh`,
`test-verify-remote.sh`, `test-repo-health.sh`; step 6:
`run-container-tests.sh` (build/packager gate/cache/fingerprint/epoch).

Expected zero-mutation production baseline (reference, not hardcoded):

```text
unchanged=44 uploaded=0 replaced=0 failed=0
```

Measured local validation (final hardening pass, pinned Arch container):

| Suite | Result |
|---|---|
| `test-matrix.sh` | 85 PASS |
| `test-content-aware.sh` | 30 PASS |
| `test-build-cache.sh` | 20 PASS |
| `test-rustc-wrapper.sh` | 10 PASS |
| `test-epoch-filenames.sh` | 8 PASS |
| `test-check-updates.sh` | 7 PASS |
| `test-http500.sh` (host) | 11 PASS, 1 SKIP (prod scenarios need container) |
| `test-workflow-audit.sh` | 20 PASS |
| `test-signing.sh` (container) | 37 PASS |
| `test-signing-mode.sh` (container) | 18 PASS |
| `test-http500.sh` `RUN_PROD_SCENARIOS=1` (container) | 108 PASS, 0 FAIL |
| `test-verify-remote.sh` (container) | 14 PASS |
| `test-repo-health.sh` (container) | 37 PASS |
| `run-container-tests.sh` (container) | 51 PASS |

Static checks: `bash -n` on all scripts OK; `git diff --check` clean;
actionlint clean on all workflows; shellcheck reports only pre-existing
info/warning-level findings (unused-variable/quote advisories), none
introduced by this pass.
