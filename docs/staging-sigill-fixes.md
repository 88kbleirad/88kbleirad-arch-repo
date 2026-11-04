# Staging false-success and Rust SIGILL fixes

This document records the investigation and fixes for GitHub Actions staging
run `41872295944`:

- `ripdrag` build failed with `signal: 4, SIGILL` in the `glib-sys`
  build-script dependency;
- the build job nonetheless exited 0 ("Gracefully exiting to ignore
  package") and uploaded a 456-byte metadata-only artifact;
- the staging release lacked `ripdrag`, yet the workflow concluded success;
- secondary permission errors writing `v4-runner-info-ripdrag.json` and
  locking `.git/config`.

## Root causes

### 1. Rust build-script CPU incompatibility (SIGILL)

`glib-sys` is a **build-dependency** of ripdrag. Cargo compiles it as a
`--crate-type lib` under the global `RUSTFLAGS="-C
target-cpu=x86-64-v4"`, then links that `.rlib` into the `build_script_*`
executable. The previous `rustc-v4-safe.sh` wrapper stripped v4 codegen
only for crate names `build_script_*` and crate type `proc-macro` — it did
**not** strip for build-dependency libraries (`glib_sys` etc.). On the
non-AVX-512 GitHub runner, the build script executed v4-only instructions →
`SIGILL`.

Fix (`rustc-v4-safe.sh`): strip v4 codegen flags for **every crate type
except `bin`** (lib/staticlib/cdylib/proc-macro and `build_script_*`
bins). Final target binaries keep the v4 profile. No package in this
repository publishes a compiled library artifact, so this is safe for the
whole inventory. Verified by `test-rustc-wrapper.sh` (10/10) and the cargo
repro: `glib_sys`/`build_script_build` are stripped, the final `bin`
keeps v4.

### 2. Fail-closed builds (`build-package.sh`)

`makepkg rc=4` used to fall through to "Gracefully exiting to ignore
package" with `exit 0` after writing `status-failed` metadata. Now:

- on build failure, the fallback attempts download of previously published
  archives and **validates each restored archive** (`validate_pkg_file`)
  before counting it as recovery;
- if no valid archive is restored, the script writes `status-failed` +
  metadata **and exits 1** — the job fails (no false green);
- successful restore still writes `status-restored` and exits 0.

### 3. Artifact gate (`build-in-docker.sh`)

Before `exit 0`, the build job now requires at least one **actual, valid
package archive** matching the requested package (by pkgbase/pkgname/
filename prefix) with a readable `.PKGINFO`. Metadata-only outputs
(`status-failed` + `v4-*.meta.json`, runner info, logs) fail the job with
`::error::no valid package archive produced`. Tool-robust: uses
`bsdtar` or GNU tar+zstd fallback (Ubuntu host has no bsdtar by default).

### 4. Staging inventory completeness + remote verification

`publish-stage.sh` now:

- enforces `EXPECTED_PACKAGES` (matrix output) against the regenerated DB
  **before any release mutation**, mirroring production;
- runs `verify-remote-release.sh` after publishing (mandatory, signed mode)
  and fails the publish job on any missing/inconsistent asset.

`build-staging.yml` passes `EXPECTED_PACKAGES` from `prepare` into the
publish container.

### 5. Permission errors

The container bootstrap `chown`s the workspace to `builder`; host-side
writes (runner-info JSON, step summary, and later git checkout cleanup)
then fail with Permission denied. `build-in-docker.sh` now restores
workspace ownership to the host uid/gid (`docker exec chown -R
$(id -u):$(id -g)`) right after the build, before any host-side write.
This fixes both the runner-info and `.git/config` lock errors without
unrestricted permissions.

## Files changed

- `.github/scripts/rustc-v4-safe.sh` — strip v4 for all non-`bin` crate
  types (build-dep libs).
- `.github/scripts/build-package.sh` — fail closed on unrecoverable build
  failure; validate restored archives.
- `.github/scripts/build-in-docker.sh` — artifact gate (valid archive
  required), tool-robust reader, host-ownership restore.
- `.github/scripts/publish-stage.sh` — inventory enforcement + mandatory
  remote verification.
- `.github/workflows/build-staging.yml` — pass `EXPECTED_PACKAGES`.
- `.github/tests/run-container-tests.sh` — fail-closed (broken build and
  metadata-only) tests; PACKAGER gate now asserts nonzero exit.
- `.github/tests/test-rustc-wrapper.sh` (new) — wrapper unit tests.
- `.github/tests/test-signing.sh` — staging sandbox ships new scripts and
  derives `EXPECTED_PACKAGES`.
- `.github/tests/run-tests.sh` — runs the wrapper suite.

## Test results

| Suite | PASS | FAIL |
|---|---|---|
| host lib | 6 | 0 |
| content-aware | 18 | 0 |
| build-cache | 20 | 0 |
| rustc wrapper | 10 | 0 |
| matrix | 85 | 0 |
| signing | 37 | 0 |
| signing-mode | 18 | 0 |
| prod scenarios | 43 | 0 |
| remote-verify | 13 | 0 |
| container build | 20 | 0 |
| **full suite** | **33** | **0** |

`bash -n` (all scripts/tests), actionlint, YAML validation, and `git diff
--check`: all pass.

## Safe staging rerun command (requires approval)

```bash
gh workflow run build-staging.yml -f confirm-production=YES \
  -f packages="catppuccin-obs-theme-git,snapper-rollback,xclicker,ripdrag,xmousepasteblock"
```

Expected outcome with fixes: ripdrag builds (build-dep v4 stripping) or, if
the build still fails, the job exits nonzero and the workflow fails
loudly — no partial staging release.
