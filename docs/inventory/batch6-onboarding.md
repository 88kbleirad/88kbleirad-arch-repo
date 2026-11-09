# Phase 8.4 Batch 6 — On-Demand Package Onboarding (`mihomo`, `lua-lgi-git`)

Status: **COMPLETE — SIGNED PRODUCTION VERIFIED** (2026-11-09). Both packages published to Production `repository`; inventory expanded 29 → 31.

Lifecycle evidence (all verified in this phase):

- **Signed Staging**: workflow run `42511015358` — all jobs success on main `1521861`; both packages built, signed, published to `repository-v4-test`; signed DB integrity verified; staging health HEALTHY.
- **Production Dry-Run**: workflow run `42556285662` — planned 29 → 31; exactly 6 new assets (2 archives + 2 sigs + 2 meta); exactly 8 DB replacements; no deletions/unauthorized mutations; production baseline HEALTHY.
- **Signed Production**: workflow run `42558423232` on main `1521861` — `unchanged=88 uploaded=6 replaced=8 failed=0`, no stale deletions, remote verification passed, post-publication health HEALTHY (rc=0). Final production: 31 archives / 31 sigs / 31 metadata, signed DB, zero missing/unexpected assets. GPG fingerprint `3B9B8E3E5564A77A73B543D049DD327EE8135B62` verified; DB identity consistency and SHA256 checks verified.

## 1. Candidate selection and repository policy

Per the repository's **On-Demand Package Onboarding** policy, only the two user-selected packages for Batch 6 were evaluated:

1. `mihomo`
2. `lua-lgi-git`

No additional packages from `packages.txt` or the host installed inventory were auto-selected, and neither candidate was silently substituted.

| Candidate | AUR | Upstream | Version | Architecture | License | Dependencies | Verdict |
|---|---|---|---|---|---|---|---|
| `mihomo` | `mihomo` (Kizumi) | `github.com/MetaCubeX/mihomo` | `1.19.33-1` | `x86_64` | `GPL3` | `glibc`, `clash-geoip` (runtime); `go` (make) | **BLOCKED** — inter-package dependency resolution gap (`clash-geoip` is published in `88kbleirad` release `repository`, not in official Arch repos; `check_dependencies_resolvable()` passes because `clash-geoip/PKGBUILD` exists in the repo workspace, but `makepkg --syncdeps` inside the isolated Arch container only queries `core`/`extra` unless `EXTRA_REPO` is configured in the workflow, failing with `rc=8: error: target not found: clash-geoip`). Additionally ships privileged systemd units (`CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE`) and `conflicts/provides=('clash-meta')`. |
| `lua-lgi-git` | `lua-lgi-git` (actionless) | `github.com/lgi-devs/lgi` | `0.9.2.r134.g7a2276f-1` | `x86_64` | `custom:MIT` | `glibc`, `glib2`, `libffi`, `lua`, `gobject-introspection-runtime` (runtime); `git`, `gobject-introspection` (make) | **APPROVED_FOR_IMPLEMENTATION** — builds cleanly against Arch `extra/lua` 5.5.1-1 (`_LUA_VER=5.5`), installs to `/usr/lib/lua/5.5/` and `/usr/share/lua/5.5/`, coexists cleanly with published `luajit-lgi` (which targets Lua 5.1/LuaJIT paths and `/usr/bin/dump-typelib-luajit`), passes Lua 5.5 GObject Introspection runtime smoke tests and full cache validation. |

## 2. Baseline and duplicate audit (Phase A)

- **Repository**: `88kbleirad/88kbleirad-arch-repo` (`main` at `d2136af`).
- **Existing Production inventory (`repository`)**: 29 package archives (`*.pkg.tar.zst`), 29 detached signatures (`*.pkg.tar.zst.sig`), 29 metadata files (`v4-*.meta.json`), signed database (`88kbleirad.db[.tar.gz][.sig]`, `88kbleirad.files[.tar.gz][.sig]`), public key (`88kbleirad.pub.asc`). Production health: `HEALTHY`.
- **Duplicate check**:
  - Neither `mihomo` nor `lua-lgi-git` is published in `repository` (29 packages) or listed in `packages.txt` at baseline `d2136af`.
  - Both existed in the local working tree as untracked directories prepared for Batch 6 review (`mihomo/` and `lua-lgi-git/`) and were tracked in `docs/inventory/omp-package-inventory.csv` / `docs/inventory/classification-2026-11-07.md`.
  - Related published packages:
    - `clash-geoip` (`202610160207-1`, `arch=any`) was onboarded in Batch 4 and is published in `repository`.
    - `luajit-lgi` (`0.9.2-6`, `arch=x86_64`) is published in `repository`; it targets `luajit` (`/usr/lib/lua/5.1/lgi/corelgilua51.so`, `/usr/share/lua/5.1/`, `/usr/bin/dump-typelib-luajit`) and does not conflict with `lua-lgi-git`.

## 3. Upstream and AUR audit (Phase B)

### Package A: `mihomo`

- **AUR identity**: `mihomo` (`pkgbase=mihomo`, version `1.19.33-1`, maintainer `Kizumi`). Not in official Arch repositories (`core`/`extra`).
- **Upstream**: `https://github.com/MetaCubeX/mihomo` (tag `v1.19.33` → commit `3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`).
- **Source & checksum verification**:
  - `mihomo-1.19.33.tar.gz` (`https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.33.tar.gz`): sha256 `e7c596b37ff27ec487d19b1920f73e0c97a78067ea35766530ee9659ade72711` (verified against live download).
  - Local auxiliary files verified against `.SRCINFO`:
    - `mihomo.service`: `7b60925a78c9a4b726833e194b395cabddf89b364a5c721522cb78aaece33e79`
    - `mihomo@.service`: `81a93a53a59dee006bfaa3f8b6490e654ea8a929cd2acb136136b5f7d569aad4`
    - `mihomo.sysusers`: `60b5e5308d9aec711e797c402b82899ea0f20951de9baca1594884fbe21f8acc`
    - `mihomo.tmpfiles`: `60b60d84c52443d976265f0be68b13ae1700daffd8de35edf63990380f4c93d9`
    - `config.yaml`: `90f7fdacecd5928e37865b4f841517f925c8bedc769f16f7a7a1e89b923f1fb9`
- **License**: `GPL-3.0` (`GPL3` in PKGBUILD; `LICENSE` file present in upstream tarball).
- **Dependencies & namespace**:
  - `depends=('glibc' 'clash-geoip')`, `makedepends=('go')`.
  - `provides=('clash-meta')`, `conflicts=('clash-meta')`, `backup=('etc/mihomo/config.yaml')`.
  - Symlinks `/etc/mihomo/Country.mmdb -> /etc/clash/Country.mmdb` (provided by `clash-geoip`) and `/usr/bin/clash-meta -> /usr/bin/mihomo`.
- **Pipeline blocker (Gate 7 & Gate 13)**:
  - In `.github/scripts/build-package.sh`, `check_dependencies_resolvable()` treats any dependency with a matching `$WORKSPACE/$dep/PKGBUILD` directory as resolvable (`clash-geoip/PKGBUILD` exists in the repo).
  - However, `build-package.sh` then invokes `makepkg --noconfirm --nocheck --syncdeps --needed` inside the fresh Arch container created by `build-in-docker.sh`.
  - Because `EXTRA_REPO` is not set in `.github/workflows/build-staging.yml` or `.github/workflows/build-release.yml`, the container's `/etc/pacman.conf` only has official Arch repositories (`core`, `extra`).
  - `pacman` inside the container cannot find `clash-geoip` (`error: target not found: clash-geoip`), causing `makepkg` to abort with exit code `8` (`E_INSTALL_DEPS_FAILED`) and the pipeline build job to fail closed (`rc=1`).
  - Resolving this cleanly requires either passing `EXTRA_REPO="88kbleirad|https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository"` in the build workflow or pre-installing in-repo dependencies in `build-package.sh` — both are common build infrastructure / workflow changes outside the scope of a package-only onboarding PR (Gate 14).
  - Consequently, `mihomo` was classified **`BLOCKED`** until the inter-package dependency resolution path was **owner-authorized and implemented** in this PR (see Section 7 EXTRA_REPO integration). With `EXTRA_REPO` wired, the real pipeline build passes (`rc=0`).

### Package B: `lua-lgi-git`

- **AUR identity**: `lua-lgi-git` (`pkgbase=lua-lgi-git`, version `0.9.2.r134.g7a2276f-1`, maintainer `actionless`).
- **Upstream**: `https://github.com/lgi-devs/lgi` (`master` HEAD commit `7a2276f9657a50ee548a636f2e646f96ec748bbd`, which includes PR #359 `664ce58` "Support for Lua 5.5" and GLib >= 2.86 enum fixes).
- **Relationship to official `extra/lua-lgi` and repo `luajit-lgi`**:
  - Official `extra/lua-lgi` (`0.9.2-14`) is built from the older `pavouk/lgi` 0.9.2 tarball; `lua-lgi-git` is the VCS variant from `lgi-devs/lgi` with upstream Lua 5.5 and modern GLib 2.86+ fixes, declaring `provides=('lua-lgi')`, `conflicts=('lgi' 'lua-lgi')`, `replaces=('lgi' 'lua-lgi')`. This follows the established repository VCS-variant convention (`fzf-git`, `swaync-git`, `anpan-git`).
  - Published `luajit-lgi` (`0.9.2-6`) installs to `/usr/lib/lua/5.1/lgi/corelgilua51.so`, `/usr/share/lua/5.1/`, and `/usr/bin/dump-typelib-luajit`, whereas `lua-lgi-git` installs to `/usr/lib/lua/5.5/lgi/corelgilua51.so`, `/usr/share/lua/5.5/`, and `/usr/bin/dump-typelib`. Zero file or package-name conflicts exist between `lua-lgi-git` and `luajit-lgi`.
- **Lua ABI & version compatibility**:
  - Arch Linux `extra/lua` is currently `5.5.1-1` (`Provides: lua55`, headers in `/usr/include/lua5.5/` or `/usr/include/`, module directories `/usr/lib/lua/5.5` and `/usr/share/lua/5.5`).
  - `lua-lgi-git/PKGBUILD` sets `_LUA_VER=5.5` and installs `corelgilua51.so` (upstream's internal C-module name required by `lgi/core.lua`: `local core = require 'lgi.corelgilua51'`) into `LUA_LIBDIR=/usr/lib/lua/5.5` and Lua files into `LUA_SHAREDIR=/usr/share/lua/5.5`.
- **License**: MIT (`license=('custom:MIT')`), installed to `/usr/share/licenses/lua-lgi-git/LICENSE`.
- **Single-package output**: `pkgname=lua-lgi-git` produces exactly one archive (`lua-lgi-git-0.9.2.r134.g7a2276f-1-x86_64.pkg.tar.zst`).

## 4. Security and feasibility gates (Phase C)

| Gate | `mihomo` | `lua-lgi-git` |
|---|---|---|
| 1. Trusted upstream source | PASS (`MetaCubeX/mihomo`) | PASS (`lgi-devs/lgi`) |
| 2. Clear license | PASS (`GPL-3.0`) | PASS (`MIT`, installed to `/usr/share/licenses/lua-lgi-git/LICENSE`) |
| 3. Verifiable source integrity | PASS (sha256 verified for tag archive + 5 local files) | PASS (VCS git clone; `pkgver()` deterministic from `git describe --long`) |
| 4. No unexplained install/build network execution | PASS (standard Go module download during build) | PASS (standard git source clone by makepkg; offline `make` build) |
| 5. No unexpected privileged operations | REVIEW (ships systemd units with `CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE`, not auto-enabled) | PASS (no install script, no systemd units, no capabilities) |
| 6. No secret requirements | PASS | PASS |
| 7. Compatible runtime dependencies | **PASS** — `clash-geoip` resolves via configured `EXTRA_REPO` (signed release; `SigLevel = Required TrustedOnly`) | PASS (`glibc`, `glib2`, `libffi`, `lua`, `gobject-introspection-runtime` all in official Arch repos) |
| 8. Compatible build dependencies | PASS (`go` in official Arch `extra`) | PASS (`git`, `gobject-introspection` in official Arch `extra`) |
| 9. Single-package output | PASS (one archive, real build) | PASS (`lua-lgi-git-0.9.2.r134.g7a2276f-1-x86_64.pkg.tar.zst`) |
| 10. Supported x86-64-v4 build configuration | PASS | PASS (compiled with `-march=x86-64-v4`, `EVEX-heuristic=19`) |
| 11. Compatible package metadata | PASS | PASS (`packager = 88kbleirad <88kbleirad@users.noreply.github.com>`) |
| 12. Reproducible/deterministic cache behavior | PASS (fresh build MISS → HIT → repeat HIT byte-identical meta → corrupt archive rejected & rebuilt) | PASS (fresh `MISS` → `HIT` → repeat `HIT` byte-identical meta → corrupt archive rejected & rebuilt) |
| 13. Compatibility with existing CI/CD pipeline | PASS (real pipeline build `rc=0` with `EXTRA_REPO`; `build-package.sh` resolves deps via `sudo -E pacman` fallback) | PASS (`build-package.sh` exits `rc=0`) |
| 14. No unapproved modification to signing/publishing/build infra | Enforced — infra change explicitly owner-authorized for this PR; no private keys touched | PASS (no infra files modified) |
| **Final Gate Verdict** | **`APPROVED_FOR_IMPLEMENTATION`** | **`APPROVED_FOR_IMPLEMENTATION`** |

## 5. Real Docker build, runtime smoke test & cache validation (Phase E)

### 5.1 Real pipeline Docker build (`local-build-candidates.sh`)

Executed inside pinned `ghcr.io/archlinux/archlinux@sha256:644576e90a71df3b137df2ab6b3517ecd045418195c1946c2c11d1c0564a7981` with the CachyOS `x86-64-v4` `makepkg.conf` and `rust.conf` profiles:

- **`lua-lgi-git`**:
  - Pipeline build exit code: **`rc=0`** (`status-built-lua-lgi-git.txt` written).
  - Produced archive: `lua-lgi-git-0.9.2.r134.g7a2276f-1-x86_64.pkg.tar.zst` (241,478 bytes compressed; 691,737 bytes installed).
  - `.PKGINFO` verified: `pkgname = lua-lgi-git`, `pkgbase = lua-lgi-git`, `pkgver = 0.9.2.r134.g7a2276f-1`, `arch = x86_64`, `license = custom:MIT`, `packager = 88kbleirad <88kbleirad@users.noreply.github.com>`.
  - ISA audit (`audit-package-isa.sh`): `corelgilua51.so: EVEX-heuristic=19` (compiled with `-march=x86-64-v4 -O3 -flto=auto`).
- **`mihomo`**:
  - Real pipeline build exit code: **`rc=0`** (`status-built-mihomo.txt` written) with `EXTRA_REPO` wired; `makepkg` succeeded, producing exactly one archive `mihomo-1.19.33-1-x86_64.pkg.tar.zst` (17,547,961 bytes compressed; 61,434,891 bytes installed).
  - `.PKGINFO` verified: `pkgname = mihomo`, `pkgbase = mihomo`, `pkgver = 1.19.33-1`, `arch = x86_64`, `license = GPL3`, `packager = 88kbleirad <88kbleirad@users.noreply.github.com>`, `depend = glibc`, `depend = clash-geoip`, `provides = clash-meta`, `conflict = clash-meta`.
  - ISA audit (`audit-package-isa.sh`): `mihomo: EVEX-heuristic=20420` (Go `-buildmode=pie` + `-tags with_gvisor`, v4-targeted toolchain).
  - Clean-container install plus smoke test (with signed `clash-geoip` installed first): `/usr/bin/mihomo -v` → `Mihomo Meta 1.19.33 linux amd64 with go1.27.3-X:nodwarf5 2026-11-08 17:30:03+00:00 / Use tags: with_gvisor`; `ldd /usr/bin/mihomo` linked cleanly (`libc.so.6`).

### 5.2 Clean-container runtime smoke test (`lua-lgi-git`)

Installed `lua-lgi-git-0.9.2.r134.g7a2276f-1-x86_64.pkg.tar.zst` into a fresh `ghcr.io/archlinux/archlinux` container via `pacman -U`:

- `ldd /usr/lib/lua/5.5/lgi/corelgilua51.so`: all shared libraries resolved (`libgirepository-1.0.so.1`, `libgobject-2.0.so.0`, `libgmodule-2.0.so.0`, `libglib-2.0.so.0`, `libffi.so.8`, `libc.so.6`, `libm.so.6`, `libpcre2-8.so.0`).
- Lua 5.5 (`Lua 5.5.1`) module import and GObject Introspection call:
  ```
  lgi version:    0.9.2
  GLib version:   2.90.1
  LUA_LGI_GIT_SMOKE_TEST_PASS
  ```

### 5.3 Cache validation (`lua-lgi-git`)

Executed 4-stage cache lifecycle test in the pinned container using `build-package.sh` + `verify-build-cache.sh`:

1. **Fresh build**: `rc=0`, `verify-build-cache.sh` reported `MISS` / `VALID` (`hits=0, misses=1, invalid=0, failed=0`).
2. **First cache reuse (`--strict`)**: `rc=0`, `status-skipped-lua-lgi-git.txt`, `verify-build-cache.sh --strict` reported `HIT` / `VALID` (`hits=1, misses=0`), `v4-lua-lgi-git.meta.json` preserved byte-identical (`META_BYTE_IDENTICAL_1=PASS`).
3. **Second repeat cache reuse (`--strict`)**: `rc=0`, `verify-build-cache.sh --strict` reported `HIT` / `VALID`, `v4-lua-lgi-git.meta.json` preserved byte-identical (`META_BYTE_IDENTICAL_2=PASS`).
4. **Corrupted cache rejection**: truncated cached `.pkg.tar.zst` to 100 bytes; `build-package.sh` logged `cached binary failed validation: lua-lgi-git-0.9.2.r134.g7a2276f-1-x86_64.pkg.tar.zst; forcing rebuild`, rebuilt cleanly (`rc=0`), and `verify-build-cache.sh` confirmed `MISS` / `VALID`.

## 6. Regression and CI validation evidence (Phase F)

- `makepkg --printsrcinfo` vs `lua-lgi-git/.SRCINFO`: byte-identical (`diff -u` exit 0).
- `bash -n lua-lgi-git/PKGBUILD`: exit 0.
- `git diff --check`: exit 0.
- Host-side regression suites:
  - `test-matrix.sh`: `PASS=85 FAIL=0` (65 PKGBUILD dirs on disk; default production matrix size 59).
  - `test-ci-safety.sh`: `PASS=45 FAIL=0`.
  - `test-release-safety.sh`: `PASS=23 FAIL=0`.
  - `test-workflow-audit.sh`: `PASS=26 FAIL=0`.
  - `test-build-cache.sh`: `PASS=20 FAIL=0`.
  - `test-content-aware.sh`: `PASS=18 FAIL=0`.
  - `test-epoch-filenames.sh`: `PASS=8 FAIL=0`.
  - `test-rustc-wrapper.sh`: `PASS=10 FAIL=0`.
  - `test-check-updates.sh`: `PASS=43 FAIL=0`.
  - `test-artifact-collection.sh`: `PASS=21 FAIL=0`.
  - `test-propose-updates.sh`: `PASS=31 FAIL=0`.
  - `dashboard/tests/test-metrics.sh`: `PASS=24 FAIL=0`.
  - `dashboard/tests/test-dashboard.sh`: `PASS=19 FAIL=0`.
- Full end-to-end regression suite (`run-tests.sh` including container signing/publish/health/cache and UID-1001 container tests): `PASS=59 FAIL=0` (`run-container-tests.sh` `PASS=61 FAIL=0`).

## 7. Release lifecycle record (staging → production)

All steps below executed with explicit owner authorization; no workflow/package files changed after the PR merge. Main commit for all runs: `1521861`.

### 7.1 Signed Staging — run `42511015358`

- Workflow: `build-staging.yml` on main `1521861`; packages `mihomo,lua-lgi-git`.
- Job conclusions: prepare / build (mihomo) / build (lua-lgi-git) / publish / health-check — all success.
- Both archives published to `repository-v4-test` with detached GPG signatures and `v4-*.meta.json`; package signatures verified; signed DB (`88kbleirad.db.tar.gz` + `.sig`) integrity verified; staging health HEALTHY.
- Staging verdict: `PHASE_8_4_BATCH6_SIGNED_STAGING_PASS`.

### 7.2 Production Dry-Run — run `42556285662`

- Workflow: `build-release.yml` on main `1521861`; `confirm-production=YES`, `signing-mode=signed`, `dry-run=true`.
- Publish-signed plan: `preflight: all 31 package assets conflict-free`; `Inventory OK: all 2 requested packages are present and validated`; `DRY-RUN: would upload` 6 assets (2 archives + 2 sigs + 2 meta); `DRY-RUN: would replace database` 8 assets; `SUMMARY unchanged=88 uploaded=6 replaced=8 failed=0`; no `would delete` lines; exit 0.
- Verified read-only: every mutation path gated on `DRY_RUN=1`; production untouched (asset diff empty, 29/29/29, DB sig Good, health HEALTHY).
- Verdict: `PHASE_8_4_BATCH6_PRODUCTION_DRY_RUN_PASS`.

### 7.3 Signed Production — run `42558423232`

- Workflow: `build-release.yml` on main `1521861`; `confirm-production=YES`, `signing-mode=signed`, `dry-run=false`.
- Job conclusions: prepare / build (both) / cache-verify / publish-signed / health-check — all success; `publish` (unsigned) correctly skipped.
- Publish evidence: `preflight: all 31 package assets conflict-free`; `Inventory OK: all 2 requested packages are present and validated`; 29 existing archives + 29 sigs + 29 meta `UNCHANGED`; `NEW` for `mihomo-1.19.33-1-x86_64` (+ `.sig`), `lua-lgi-git-0.9.2.r134.g7a2276f-1-x86_64` (+ `.sig`), `v4-mihomo.meta.json`, `v4-lua-lgi-git.meta.json`; `CHANGED database` ×8; `SUMMARY unchanged=88 uploaded=6 replaced=8 failed=0`; `No stale assets to delete.`; `== Remote verification passed ==`; exit 0.
- Post-publication verification: 31/31/31 archives/sigs/meta; zero removals; no orphaned sigs; DB sig Good with fingerprint `3B9B8E3E5564A77A73B543D049DD327EE8135B62`; mihomo + lua-lgi-git package sigs Good; DB 31 entries, no duplicates; `mihomo 1.19.33-1 x86_64` and `lua-lgi-git 0.9.2.r134.g7a2276f-1 x86_64`; local sha256 == API digest == DB `%SHA256SUM%`; mihomo declares `depends=('glibc' 'clash-geoip')`; health HEALTHY (rc=0).
- Verdict: `PHASE_8_4_BATCH6_SIGNED_PRODUCTION_PASS`.

### 7.4 Release asset inventory (final)

- **Package assets**: 31 archives + 31 detached signatures + 31 `v4-*.meta.json` (29 pre-existing preserved byte-identical; 6 new).
- **Database assets**: `88kbleirad.db`, `88kbleirad.db.tar.gz`, `88kbleirad.files`, `88kbleirad.files.tar.gz` (+ `.sig` for each) — all 8 replaced with freshly signed regenerated DB.
- **Public-key asset**: `88kbleirad.pub.asc` (signing key export; unchanged).
- Total release assets: 102.

### 7.5 Known limitation (preserved)

No independent canonical published-inventory list exists in the repository; the expected inventory is derived at publish time from `packages.txt` + the prepare matrix + the live release/DB (verified via `verify-remote-release.sh` and `repo-health.sh`).

### EXTRA_REPO integration (secure dependency resolution)

- **Root cause**: `build-in-docker.sh` accepted an `EXTRA_REPO` env var and appended it to the container's `/etc/pacman.conf`, but neither workflow set the variable, so `makepkg --syncdeps` only saw official Arch repos and failed with `rc=8: error: target not found: clash-geoip`. Additionally, `check_dependencies_resolvable()` in `build-package.sh` did not consult the extra repo.
- **Fix**: both workflows now set `EXTRA_REPO="88kbleirad|https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository"`. The container bootstrap sources the new shared `.github/scripts/extra-repo-lib.sh`, which downloads the release's exported public key (`88kbleirad.pub.asc`), verifies its fingerprint against the pinned `3B9B8E3E5564A77A73B543D049DD327EE8135B62` (fail-closed on mismatch or malformed key), imports and locally signs it via `pacman-key`, and appends the repo with `SigLevel = Required TrustedOnly`. `check_dependencies_resolvable()` in `build-package.sh` also falls back to `pacman -Sy` + re-resolution when `EXTRA_REPO` is set, so the dependency gate no longer lies.
- **Regression coverage**: new suite `.github/tests/test-extra-repo.sh` (15 tests), registered in `run-tests.sh`; it verifies env forwarding in both workflows, strict `SigLevel`, pinned fingerprint fail-closed behavior, live signed-DB sync and `clash-geoip` resolution in the pinned container, valid detached signature on the `clash-geoip` archive, and rejection of a tampered database.
