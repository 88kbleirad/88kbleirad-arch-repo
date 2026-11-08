# Phase 8.1.1 — Pull Request CI Validation

Status: implemented + locally validated. Live GitHub PR checks require a
real PR (owner action); no PR was created by this task.

## 1. Architecture

New workflow: `.github/workflows/ci-validation.yml` (display name **CI Validation**).

```
Pull Request to main ──► CI Validation
                            ├── static-validation  (bash -n, ShellCheck,
                            │                       actionlint, YAML, diff --check)
                            ├── regression-tests   (full run-tests.sh incl. Docker)
                            └── ci-acceptance     (aggregate; fails if any dep
                                                    failed/cancelled/skipped)
```

Triggers:
- `pull_request` on `branches: [main]` — runs on opened/synchronize/
  reopened (no path filter, so packaging/release-safety changes are never
  silently skipped).
- `workflow_dispatch` — owner-initiated CI-only testing.

Permissions: `contents: read`, `pull-requests: read` (least privilege).

## 2. Jobs

### static-validation (ubuntu-24.04)
1. Checkout (fetch-depth 1).
2. Install tools: `shellcheck` via apt (Ubuntu 24.04 → 0.10.0);
   `actionlint` v1.7.12 pinned release binary + SHA-256 verification
   (`8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8`).
3. **Bash syntax**: dynamic `find` over `.github/scripts`, `.github/tests`,
   `dashboard/tests` → `bash -n`; fails on first syntax error, reports file.
4. **ShellCheck**: `-S warning`; **error-level findings fail CI**;
   warnings are counted and reported in the summary (legacy findings
   documented below). No global disables.
5. **actionlint**: validates all `.github/workflows/*.yml` (workflow
   expressions, needs, permissions, inputs, artifact steps, branching).
6. **YAML validation**: `validate-workflows-yaml.py` (yaml.safe_load +
   `jobs` presence, with `on:` rename shim).
7. **Whitespace**: `git diff --check origin/<base>...HEAD`.

### regression-tests (ubuntu-24.04, timeout 60m)
1. Checkout.
2. Install host deps: `python3-yaml`, `jq`, `zstd`, `libarchive-tools`
   (Docker is preinstalled on GitHub-hosted runners).
3. `REPO_ROOT=${{ github.workspace }}` + run `run-tests.sh` (full suite:
   matrix gates, critical-package restrictions, downgrade protection, cache
   verification, publish helpers, signing E2E in the pinned Arch container,
   database/remote verification, health, Phase 8.1 fault-injection, update
   detection, proposals, workflow audit, observability/dashboard, CI-safety).
4. Log uploaded as artifact `ci-regression-log` (retention 7 days) on
   success and failure (`if: always()`).

### ci-acceptance (aggregate)
- `needs: [static-validation, regression-tests]`, `if: always()`.
- Explicitly inspects `needs.<job>.result`; fails (exit 1) when any
  mandatory dependency is not `success` (failed/cancelled/skipped).
- This intentionally avoids `if: success()` so a skipped dependency cannot
  silently pass the acceptance gate.

## 3. Security boundaries
- No `pull_request_target`; no signing secrets; no production environment.
- Read-only token; no release mutation paths (`gh release`, publish-prod/
  stage, build-release/staging wiring).
- No auto-merge, no schedule/workflow_run triggers.
- Tests that exercise publish scripts run only in the isolated container
  with mock `gh` and `GH_TOKEN=dummy`; no live API writes.
- PR-controlled strings are never interpolated into shell here (only
  `github.ref`/`github.event.pull_request.number` in expressions/labels).

## 4. ShellCheck policy + legacy findings
- Errors fail CI; warnings reported. 0 error-level findings repo-wide.
- 13 legacy files carry 21 warnings (SC2034 unused vars via sourcing/
  reflection, SC2155, SC2164, SC1007, SC2115). They are documented legacy
  exceptions — not mass-rewritten. New/changed files are expected to be
  warning-clean (e.g. `test-release-safety.sh` had its SC2115 sites fixed).
- Verified ShellCheck v0.10.0 (apt on ubuntu-24.04; local binary for this
  validation). actionlint v1.7.12 (checksum-verified).

## 5. Local validation performed
| Check | Result |
|---|---|
| `python3 .github/scripts/validate-workflows-yaml.py .` | PASS (7 workflows) |
| `actionlint .github/workflows/*.yml` | PASS (0 findings) |
| `bash -n` all 44 scripts | PASS |
| ShellCheck -S error repo-wide | PASS (0 findings) |
| `test-ci-safety.sh` | PASS 19/19 |
| `test-release-safety.sh` | PASS (earlier 23/23) |
| Negative tests (invalid bash / shellcheck violation / actionlint violation) | rejected correctly |
| `run-tests.sh` full | PASS=57 FAIL=0 (baseline; will re-run with ci-safety suite) |

## 6. Branch protection setup (owner action, not executed)
1. Settings → Rules → Rulesets → New ruleset → target `main`.
2. Branch ruleset → “Require status checks to pass” → add:
   - `CI Validation / static-validation`
   - `CI Validation / regression-tests`
   - `CI Validation / ci-acceptance`
3. Enable “Require branches to be up to date” (optional).
4. Keep “Do not require for Admins” OFF if you want admins bound too.
5. Pending/missing checks block merge until they run; failed checks block
   until they pass.
6. Interaction with manual approval: rulesets and required checks are
   independent — approval only grants merge permission; status checks must
   still pass.
7. Verify by opening a test PR and observing the three checks.

Note: PR #8 predates this workflow; it will apply to future PRs only.

## 7. Local pre-PR check recipe (for developers)
```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
bash -n .github/scripts/*.sh .github/tests/*.sh dashboard/tests/*.sh
shellcheck -S error .github/scripts/*.sh .github/tests/*.sh dashboard/tests/*.sh
actionlint .github/workflows/*.yml
python3 .github/scripts/validate-workflows-yaml.py .
REPO_ROOT=$PWD bash .github/tests/run-tests.sh
```

## 8. Container-suite ownership model (Phase 8.1.1 final)
- makepkg 7.1 exits `E_FS_PERMISSIONS` (rc=11) when an effective build/
  output directory is not writable by the build user. On GitHub-hosted
  runners the host UID is 1001, distinct from the container `builder`
  (1000), so the harness must hand the workspace to `builder` before
  every build invocation.
- `run_build()` now chowns `$WS` to `builder` before each scenario, and
  host-side mkdir/ep of the workspace go through `ws_mkdir()` (host
  ownership first). Both are scoped strictly to the dedicated `$WS`.
- `TEST_BUILDER_UID` (default 1000) makes the container `builder` user
  use the runner-like UID so the mismatch can be reproduced on any host:
  `TEST_BUILDER_UID=1001 REPO_ROOT=$PWD bash .github/tests/run-container-tests.sh`.
- `build-package.sh` runs `ensure_build_dirs_writable()` before invoking
  makepkg: it resolves the effective BUILDDIR/PKGDEST/SRCDEST (falling
  back to the package dir exactly as makepkg does) and fails closed with
  an explicit per-directory diagnostic, never a bare rc=11. It does not
  require a read-only source tree to be writable when the build/output
  dirs are explicitly configured writable.
- `test-ci-safety.sh` asserts these invariants (CI-F15/CI-F16) and the
  container suite covers the permission preflight with a positive control
  (CB13).

## 9. Known limitations
- Live GitHub PR checks cannot be simulated locally; `test-ci-safety.sh`
  asserts workflow *properties*, and a real PR is required for
  `PR_CI_VERIFIED`.
- Docker integration runs on the GitHub-hosted runner using the pinned
  generic Arch container; it does not require AVX-512 on the host
  (toolchain targets v4 only for build artifacts).
