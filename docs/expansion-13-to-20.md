# Expansion — 13 to 20 packages

This document records the review-ready expansion plan for the 88kbleirad
binary repository (13 published → 20). Nothing here has been
executed against live releases; deployment requires explicit approval
(staging first, then production).

## Baseline (13 published, verified 2026-11-05)

`all-contributors-cli`, `catppuccin-fcitx5-git`,
`catppuccin-obs-theme-git`, `catppuccin-whiskers-bin`, `ksuperkey`,
`magika`, `nmtui-go`, `osu-mime`, `physlock`, `ripdrag`,
`snapper-rollback`, `xclicker`, `xmousepasteblock`.

Target: 13 + 7 = **20 packages**.

Production release `repository` (unsigned), staging `repository-v4-test`
(GPG-signed). Critical-package policy unchanged (`critical-packages.sh`);
`linux-nanoka` stays excluded from `packages.txt` and protected.

## Candidate selection

Pool = `packages.txt` entries with a PKGBUILD dir, minus the 13 published
and the 8 critical. Re-evaluated with the criteria from the 8→13
expansion. The exact 7 selected candidates:

| Package | Version (built) | Source | Architecture | Build complexity | Dependencies | x86-64-v4 | Conflict | License risk | Decision | Reason |
|---|---|---|---|---|---|---|---|---|---|---|
| `anpan-git` | `1.0.3.r0.g82991d7-1` | git (GitHub) | x86_64 | low (Go) | go (build), none runtime | compiled w/ v4 CFLAGS | provides/conflicts anpan, anpan-bin (none in repo) | MIT | **accepted** | small Go downloader; single binary; no root/system integration |
| `pwvucontrol` | `0.5.3-2` | tag tarball | x86_64 | moderate (Rust+meson) | glib2, gtk4, libadwaita, wireplumber | compiled v4 | none | GPL-3.0 | **accepted** | GNOME PipeWire volume control; official-repo deps only; modest build |
| `pvpn-go` | `0.2.10-1` | tag tarball | x86_64 | moderate (Go) | glibc | compiled v4 | none (provides pvpn) | GPL-3.0 | **accepted** | small TUIs; systemd unit shipped but no service enabling |
| `obs-pipewire-audio-capture` | `1.2.2-1` | tag tarball | x86_64 | low (cmake) | obs-studio>=28, wireplumber | compiled v4 | none | GPL-2.0 | **accepted** | tiny plugin; official-repo deps; non-critical |
| `rate-mirrors` | `0.34.1-1` | git (GitHub) + CachyOS patches | x86_64 | moderate (Rust/clang/lld) | glibc, gcc-libs, librustls | compiled v4 | none | CC-BY-NC-SA-3.0 | **accepted** | mirror ranking tool; builds clean with v4 toolchain |
| `beautyline` | `2:3.0.5-1` | gitlab tag tarball | any | trivial (icon copy) | none | n/a (data) | none | GPL | **accepted** | previously excluded for epoch filenames; the generalized epoch handling (Phase C) now builds+validates it through the real pipeline |
| `luajit-lgi` | `0.9.2-6` | tag tarball + PR patch | x86_64 | low (make) | glibc, glib2, libffi, luajit, gobject-introspection-runtime | compiled v4 | none | MIT | **accepted** | LuaJIT GI bindings; official-repo deps; small |

Rejected / deferred candidates (not re-litigated unless changed):
`printcraft` (upstream source broken: `v0.2.1` tarball now extracts to
`pdfcraft-0.2.1/` and its pinned sha256 no longer matches — pipeline
`updpkgsums` cannot fix a renamed archive dir), `awesome-luajit-git`,
`picom-nhktmdzhg-git`, `lightworks`, `msi-ec-dkms-git`,
`mcontrolcenter-git`, `lua-pam-git`, `opendoas-cpp-git`,
`scx-manager`, `serein`, `equicord-openasar`, `zalo-for-linux-git`,
`electron22-bin`, `osu-lazer-bin`, `coccoc-browser-stable`,
`vscodium`, `rustdesk`, `onlyoffice`, `localsend`,
`ttf-ms-win11-base`, `ttf-vietnamese-tcvn3`, `ttf-vietnamese-vni`,
`fcitx5-lotus-git` (epoch=4 split package — covered by the generalized
epoch handling but left out of this run to keep the matrix small),
`icu74`, `omp-bun`, `yuzufox-git`, `rhythmbox-plugin-tray-icon`,
`ventoy`.

## Phase C — epoch-aware version handling (implemented)

Previous behavior: `build-package.sh` renamed any produced `:` in output
filenames to `.` (GitHub Release assets cannot store `:`; `gh`
sanitizes them to `.`) but computed expected names and validated
filenames without accounting for `epoch`. `validate_pkg_file` built the
expected name from `pkgver`/`pkgrel`/`arch` only, so an epoch package
(beautyline `2:3.0.5-1`) failed validation after the rename and was
excluded.

Fix (general, no per-package special case):

- New shared lib `.github/scripts/pkg-filename-lib.sh`:
  `archive_basename` derives the canonical stored (GitHub-safe) archive
  basename from `.PKGINFO` (handles pacman-7 embedded EVR and legacy
  separate `epoch`/`pkgver`/`pkgrel`; `epoch=0` adds no prefix), and
  `_archive_mangle_name` renders `:` as `.` (gh sanitizeFileName parity).
- `build-package.sh`:
  - `validate_pkg_file` validates against `archive_basename` (epoch-aware).
  - Built archives are canonicalized (renamed to the canonical name)
    before validation/publish.
  - Cache expected names (`makepkg --packagelist`) are mangled through
    the same helper; the post-build `:`→`.` mv loop was removed.
  - The epoch `.PKGINFO` version (e.g. `2:3.0.5-1`) stays intact; the
    DB (`repo-add`) records the stored filename, so db→asset consistency
    holds by construction.
- Regression tests: `.github/tests/test-epoch-filenames.sh` (host,
  8 checks) + in-container epoch build/cache round-trip added to
  `.github/tests/run-container-tests.sh`.

Verified: host suite passes; container build of `hello-epoch`
(epoch=2) produces `hello-epoch-2.1.0-1-any.pkg.tar.zst`, validates, and
cache-hits on the next run. `beautyline` itself built through the real
pipeline and validated.

## Phase D — local build results (pinned Arch container, v4 profile)

Production profile applied: generic Arch image (digest-pinned), CachyOS
v4 makepkg/rust.conf, `PACKAGER="88kbleirad <88kbleirad@users.noreply.github.com>"`,
rustc wrapper (build-script host-safety). Outputs from the real
`build-package.sh` path (mock gh, fresh release):

| Package | Build rc (pipeline) | Archive | .PKGINFO | packager | Payload files | v4 ELF check |
|---|---|---|---|---|---|---|
| anpan-git | 0 | `anpan-git-1.0.3.r0.g82991d7-1-x86_64.pkg.tar.zst` | ok | repo | anpan binary + docs | EVEX present (Go, compiled v4) |
| pwvucontrol | 0 | `pwvucontrol-0.5.3-2-x86_64.pkg.tar.zst` | ok | repo | binary + gschema/icons | EVEX present |
| pvpn-go | 0 | `pvpn-go-0.2.10-1-x86_64.pkg.tar.zst` | ok | repo | pvpn/pvpnctl/pvpnd + unit | EVEX present |
| obs-pipewire-audio-capture | 0 | `obs-pipewire-audio-capture-1.2.2-1-x86_64.pkg.tar.zst` | ok | repo | plugin .so | EVEX present |
| rate-mirrors | 0 | `rate-mirrors-0.34.1-1-x86_64.pkg.tar.zst` | ok | repo | binary | EVEX present |
| beautyline | 0 | `beautyline-2.3.0.5-1-any.pkg.tar.zst` | ok (epoch embedded) | repo | icons tree | n/a (data only) |
| luajit-lgi | 0 | `luajit-lgi-0.9.2-6-x86_64.pkg.tar.zst` | ok | repo | lua libs + tools | EVEX present |

## Existing-package preservation

No existing asset or definition was touched. Cache keys/fingerprints are
unchanged for non-epoch packages (the expected-name mangling is identity
for names without `:`). Publish remains non-destructive: identical
assets are skipped (content-aware), the database is regenerated from the
merged inventory, and stale unpublished assets are only deleted when not
protected.

## Phase E — inventory enforcement for split packages (implemented)

The expected-inventory gates (publish-prod.sh, publish-stage.sh,
verify-remote-release.sh) matched requested packages by database `%NAME%`
only. For a split package whose base name differs from every subpackage
name, that would false-fail. All three sites now accept a match by
`%BASE%` as well, and remote verification derives the required archives
from the database's own `%FILENAME%` entries (base-agnostic) instead of a
filename-prefix guess against the expected inventory. Regression: a
`splitbase` → `sublib` synthetic package passes production publish +
remote verification, and a missing split base still fails before any
Release mutation.

## Cache, publish and regression test results

Run with `REPO_ROOT=$PWD RUN_PROD_SCENARIOS=1 bash .github/tests/run-tests.sh`
(bash syntax, YAML, actionlint, host suites, container signing/publish
E2E, container build/cache, epoch round-trip).

| Area | Result |
|---|---|
| bash syntax (all scripts/tests) | PASS |
| workflow YAML + actionlint | PASS |
| matrix gates (critical/subset/schedule/injection) | PASS |
| content-aware publishing (UNCHANGED/NEW/CHANGED/UNKNOWN/429/500/idempotent) | PASS |
| build-cache verification (HIT/MISS/strict/fingerprint/corrupt/duplicate/profile/tool-unavailable) | PASS |
| gh-release-lib retry + inventory enforcement + expansion + split-base + idempotency (container) | PASS |
| signing modes (unsigned purge / signed strict / no downgrade) | PASS |
| epoch filenames (host) + epoch build/cache round-trip (container) | PASS |
| container build, PACKAGER gate, cache hit, tamper, fail-closed | PASS |

Cache matrix coverage (Phase F): existing-package cache HIT
(`status-skipped`, deterministic `built_at`), new-package cache MISS
(first run `status-built`), legitimate rebuild allowed in normal mode and
rejected in `--strict`, fingerprint change forcing a rebuild, PKGBUILD
modification invalidating the entry, missing cache entry, corrupt archive
rejected + rebuilt, metadata-only artifact never a hit, failed fallback
exit, unchanged rerun producing zero mutations (content-aware summary
`uploaded=0 replaced=0 failed=0`).

## Verification log (2026-11-05, local)

All checks executed locally in this session (no live release touched):

| Check | Result |
|---|---|
| Full suite `run-tests.sh` (RUN_PROD_SCENARIOS=1) | **PASS=36 FAIL=0** |
| Matrix gates (test-matrix.sh) | PASS=85 FAIL=0 |
| Epoch filenames (test-epoch-filenames.sh) | PASS=8 FAIL=0 |
| Rustc wrapper (test-rustc-wrapper.sh) | PASS=10 FAIL=0 |
| Build-cache (test-build-cache.sh) | PASS=20 FAIL=0 |
| Content-aware (test-content-aware.sh) | PASS=18 FAIL=0 |
| gh-release-lib host (test-http500.sh, RUN_PROD_SCENARIOS=0) | PASS=6 FAIL=0 SKIP=1 |
| Container build/cache/epoch (run-container-tests.sh) | PASS=29 FAIL=0 |
| bash syntax (all .sh) | exit 0 |
| YAML safe_load (all workflows) | exit 0 |
| actionlint (all workflows) | exit 0 |
| `git diff --check` | exit 0 |

### Real-pipeline candidate builds (pinned Arch image, v4 profile, mock gh)

All via `.github/scripts/local-build-candidates.sh` (build-package.sh path:
cache/fingerprint/packager-gate/fail-closed).

| Package | Build rc | Archive | .PKGINFO | Payload | v4 ELF |
|---|---|---|---|---|---|
| anpan-git | 0 | `anpan-git-1.0.3.r0.g82991d7-1-x86_64.pkg.tar.zst` | name/base/ver/arch/packager OK | `usr/bin/anpan` + license | zmm=496, kmask=65 |
| pwvucontrol | 0 | `pwvucontrol-0.5.3-2-x86_64.pkg.tar.zst` | OK | binary + desktop/gschema/icons | zmm=22, kmask=194 |
| pvpn-go | 0 | `pvpn-go-0.2.10-1-x86_64.pkg.tar.zst` | OK | pvpn/pvpnctl/pvpnd + systemd unit | zmm=489-500, kmask=65 |
| obs-pipewire-audio-capture | 0 | `obs-pipewire-audio-capture-1.2.2-1-x86_64.pkg.tar.zst` | OK | plugin .so + locales | zmm=74 |
| rate-mirrors | 0 | `rate-mirrors-0.34.1-1-x86_64.pkg.tar.zst` | OK | `usr/bin/rate-mirrors` | zmm=677, kmask=96 |
| beautyline | 0 | `beautyline-2.3.0.5-1-any.pkg.tar.zst` | OK, `pkgver = 2:3.0.5-1` | 14,814 icon files | n/a (data) |
| luajit-lgi | 0 | `luajit-lgi-0.9.2-6-x86_64.pkg.tar.zst` | OK | lua lib + tools | zmm=4, kmask=8 |

Notes:
- All `status-built-*.txt` written; all `v4-*.meta.json` carry
  `"profile":"x86-64-v4"`, `"status":"built"`, fingerprint, `built_at`.
- `.BUILDINFO` `buildtool = makepkg 7.1.0`; every build log shows
  `-march=x86-64-v4` (CachyOS v4 profile). AVX-512 codegen proven via
  zmm/k-mask instruction counts (Go binaries: static, v4 target).
- Epoch packages store `:`→`.` (beautyline `2.3.0.5`, .PKGINFO keeps
  `2:3.0.5-1`); the stored name round-trips through the DB by
  construction (repo-add records the stored filename), verified by the
  hello-epoch container fixture and `test-epoch-filenames.sh`.

### Staging/production workflow schema validation (against live repo)

- `build-staging.yml`: `workflow_dispatch` inputs = `packages` (string,
  default `nmtui-go,osu-mime`) + `include-ksuperkey` (boolean).
  **No `confirm-production` input exists** — it must not appear in the
  staging dispatch.
- `build-release.yml`: `workflow_dispatch` inputs = `confirm-production`
  (string, required), `packages` (string), `allow-critical` (string),
  `signing-mode` (choice unsigned|signed), `strict-cache` (boolean).
  Production gate `generate-matrix.sh` requires `confirm-production=YES`.

## Remaining limitations

- Staging/production runs have not been executed (approval required); the
  HTTP 500 recovery, remote GitHub verification and GPG signing paths are
  proven against the mock-gh harness + container, not against the live
  GitHub API in this session.
- The container-based publish E2E runs in the pinned Arch image; the
  GitHub-hosted ubuntu-24.04 runner additionally installs
  `libarchive-tools`/`zstd`/`jq` (already wired) for verification jobs.
- `beautyline` epoch handling is exercised by the synthetic `hello-epoch`
  fixture and by a real container build; the live publish of an epoch
  package has not been run.
- `rate-mirrors` carries a CC-BY-NC-SA-3.0 license (non-commercial) —
  acceptable for this personal repository, flagged for completeness.

## Staging deployment plan (approved command, not executed)

Workflow `build-staging.yml`, release `repository-v4-test`, GPG-signed
(unchanged), `confirm-production` is NOT an input of this workflow (the
dispatch must not include it). Matrix = new packages only; staging merge
keeps the existing 13.

```bash
gh workflow run build-staging.yml \
  --repo 88kbleirad/88kbleirad-arch-repo \
  --ref main \
  --json '{"packages":"anpan-git,pwvucontrol,pvpn-go,obs-pipewire-audio-capture,rate-mirrors,beautyline,luajit-lgi"}'
```

Acceptance (already enforced by the pipeline): BUILD JOBS PASS, EXPECTED
INVENTORY PASS, PACKAGE ARCHIVES VALID, CACHE VERIFICATION PASS,
SIGNATURE VERIFICATION PASS, DATABASE CONSISTENCY PASS, REMOTE
VERIFICATION PASS. Any missing/failed package fails the workflow.

## Production deployment plan (after staging passes; approved command, not executed)

Workflow `build-release.yml`, release `repository`, unsigned (default),
`confirm-production=YES`. Matrix = complete target inventory (13 + 7).

```bash
gh workflow run build-release.yml \
  --repo 88kbleirad/88kbleirad-arch-repo \
  --ref main \
  --json '{"confirm-production":"YES","packages":"all-contributors-cli,catppuccin-fcitx5-git,catppuccin-obs-theme-git,catppuccin-whiskers-bin,ksuperkey,magika,nmtui-go,osu-mime,physlock,ripdrag,snapper-rollback,xclicker,xmousepasteblock,anpan-git,pwvucontrol,pvpn-go,obs-pipewire-audio-capture,rate-mirrors,beautyline,luajit-lgi"}'
```

No new mirrors/hosts/CDNs; pacman config untouched.

## Verification on consumer

```bash
pacman -Sy
pacman -Si 88kbleirad/anpan-git 88kbleirad/pwvucontrol 88kbleirad/pvpn-go \
  88kbleirad/obs-pipewire-audio-capture 88kbleirad/rate-mirrors \
  88kbleirad/beautyline 88kbleirad/luajit-lgi
pacman -S anpan-git pwvucontrol pvpn-go obs-pipewire-audio-capture rate-mirrors beautyline luajit-lgi
```

## Rollback / recovery

- Staging: run the previous signing workflow with the same matrix; the
  release is merged non-destructively, so failures leave the previous
  assets intact.
- Production: an interrupted/app failed run never mutates the Release
  (inventory gate + fail-closed build jobs) unless the old database is
  merged back; on partial upstream state, the `publish-prod.sh`
  recovery path reconstructs the DB from validated archives.
- Cache: `strict-cache=true` fails on any rebuild; a fingerprint change
  (PKGBUILD/compiler config) intentionally invalidates entries.
