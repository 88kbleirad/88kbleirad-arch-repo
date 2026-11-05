# Phase 3.5 — Build Stability, Reproducibility, Cache Consistency & Zero-Mutation Publishing

**Date:** 2026-11-05
**Scope:** local analysis + implementation; no live deployment executed.
**Baseline:** production `repository` = 20 packages, 20 `v4-*.meta.json`,
4 database/index assets (total 44 assets). Staging `repository-v4-test`
signed, production unsigned. Profile `x86-64-v4`, GitHub-hosted Ubuntu
24.04 runners, digest-pinned generic Arch container.

---

## 1. Observed problem

The 13→20 production expansion (run 41963114258) reported:

```
Inventory OK: all 20 requested packages are present and validated.
[publish] SUMMARY unchanged=22 uploaded=14 replaced=8 failed=0
REMOTE RELEASE VERIFICATION: PASS
```

Breakdown of the 8 replaced:
- `xclicker-1.5.1-1-x86_64.pkg.tar.zst` + `v4-xclicker.meta.json`
- `xmousepasteblock-1.4-3-x86_64.pkg.tar.zst` + `v4-xmousepasteblock.meta.json`
- 4 database assets (`88kbleirad.{db,files}` + `.tar.gz`) — repo-add
  nondeterminism (already handled semantically; the run *did* change the
  package set, so the DB legitimately changed).

Uploaded=14 = 7 new package archives + 7 new meta files (the new packages).
Unchanged=22 = 11 kept archives + 11 kept metas.

Both replaced packages were rebuilt with the **same version** and the log
showed `PKGBUILD/compiler fingerprint changed; forcing rebuild`.

## 2. Root cause (evidence-backed)

**Class: B — incorrect fingerprint invalidation** (not nondeterministic
output, not publishing comparison error).

Evidence:

1. `compute_fingerprint()` in `.github/scripts/build-package.sh` hashed the
   **committed** PKGBUILD bytes (plus `makepkg.conf` + `makepkg.conf.d/*`).
2. The build branch ran `updpkgsums` **before** makepkg, which rewrites
   the PKGBUILD in place: a committed `sha512sums=('SKIP')` on a
   non-VCS source becomes the real hash. It then re-computed the
   fingerprint (line 343) and **stored that post-rewrite hash** in the
   meta file.
3. On every later run, the fingerprint is again computed from the
   committed (SKIP) file → differs from the stored hash →
   `PKGBUILD/compiler fingerprint changed; forcing rebuild` forever.
4. Container probe (reproduction): with the exact CI config,
   `updpkgsums` rewrites:
   - `xclicker`: `sha512sums=('SKIP')` → real sha512 (tarball source)
   - `xmousepasteblock`: `sha256sums=('SKIP')` → real sha256 (pinned git)
   - `beautyline`: `sha256sums=('SKIP')` → real sha256 (tarball source)
   All other 17 packages: **NOOP** (already-real checksums, or VCS `git+`
   sources that keep `SKIP`).
5. This exactly explains why only these three packages could churn.
   `beautyline` was *new* in the 13→20 run (no cache to miss), so it did
   not appear in the replaced count — but it would churn on the next
   unchanged run. `snapper-rollback` (git+SKIP, untouched by
   updpkgsums) cache-hit, confirming the mechanism.

The numbers of the observed run are fully explained: the two churning
packages + DB assets were the only replaced assets; everything else was
unchanged.

## 3. Fingerprint design (Phase B)

New `compute_fingerprint()`:

- Hashes the **effective** PKGBUILD state. When the committed file has a
  `SKIP` checksum on a non-VCS source, it runs `updpkgsums` in a
  **scratch copy** (never mutating the checkout) and hashes the
  normalized file.
- Otherwise hashes the committed file (unchanged behavior — no
  re-download for the 17 already-pinned packages; verified NOOP).
- Still includes `/etc/makepkg.conf` and all `/etc/makepkg.conf.d/*.conf`
  (compiler/toolchain config).
- Outputs two lines: effective fingerprint, then raw committed fingerprint.
  Callers parse both; the effective fingerprint is what is stored and
  compared.
- Added diagnostics: when a mismatch occurs, the log explains whether it
  is checksum normalization or a real source/config change.

Validation: with the exact CI bootstrap, the new effective fingerprint
**matches the currently published** meta fingerprint for all three
previously-looping packages:

| Package | committed (raw) | effective (new) | stored (release) | result |
|---|---|---|---|---|
| xclicker | 9c2e4775… | dcf8d40c… | dcf8d40c… | **HIT** |
| xmousepasteblock | 006872aa… | 51b0ba4b… | 51b0ba4b… | **HIT** |
| beautyline | a7cb3373… | d1051ebc… | d1051ebc… | **HIT** |
| snapper-rollback | 6764d838… | 6764d838… | 6764d838… | **HIT** (control) |

The control (snapper-rollback) proves the config reproduction is
byte-exact, so the matches are meaningful.

## 4. Reproducibility (Phase C)

Two controlled builds each of `xclicker` and `xmousepasteblock` with
identical frozen inputs (same committed PKGBUILD, same CachyOS v4 config,
same pinned image):

| Package | build 1 sha256 | build 2 sha256 | diff |
|---|---|---|---|
| xclicker | 7f9179d5… | e8fc25dc… | `.PKGINFO builddate` only |
| xmousepasteblock | 9ba53c07… | 5a64b200… | `.PKGINFO builddate` only |

**Classification:** the archives are NOT byte-identical; the only
difference is the `.PKGINFO builddate` (unix timestamp stamped by
makepkg). Member lists, .BUILDINFO, binaries, and payloads are
otherwise identical. This is `NONDETERMINISTIC` only in the embedded
`builddate`; the binary content and structure are reproducible. Sources
are pinned (xclicker: tag `v1.5.1`; xmousepasteblock: commit
`c4ee870d…`), so legitimate upstream changes are versioned, not silent
rebuilds.

**Consequence for caching:** because a fresh build always produces a new
`builddate`, a legitimate rebuild of the same version yields different
bytes — this is exactly the case the same-version drift policy must
capture.

## 5. Same-version archive integrity policy (Phase D)

Implemented in `.github/scripts/gh-release-lib.sh` (`gh_publish_asset`,
`kind=package`):

- **UNCHANGED**: byte-identical → no upload (unchanged).
- **MISSING/NEW**: first-time upload allowed.
- **CHANGED** with the same package identity (name|version|arch parsed
  from `.PKGINFO` of both local and downloaded remote archive):
  **fail closed** — publish aborts before any mutation, unless
  `ALLOW_SAME_VERSION_REPLACE=1` is explicitly set.
- **CHANGED** where the remote archive is unreadable/corrupt (no valid
  `.PKGINFO`): replacement allowed (legitimate recovery of a corrupt
  asset).
- **CHANGED** with a different identity (version bump): normal replace.
- Non-package kinds (database, metadata, public key): unaffected.

This makes it impossible to silently publish different bytes under the
same package name/version/pkgrel/arch unless explicitly authorized.

## 6. Deterministic cache metadata (Phase E)

No schema changes. Verified the existing behavior:

- On a cache HIT, `write_meta skipped … "$prev_built_at"` reuses the
  previously published `built_at` (byte-identical meta output).
- A *build* writes a fresh `built_at` (new provenance).
- Metadata is minimal and stable (package/profile/status/fingerprint/
  built_at) — deliberately NOT extended with new fields, because that
  would rewrite all 20 meta assets on the next run (violating
  zero-mutation).

## 7. Content-aware publishing (Phase G)

Reviewed; no changes needed beyond the new same-version gate:

- Comparison is sha256-based (API `digest` with validated format,
  fallback download-and-hash; UNKNOWN → fail closed).
- Database comparison is semantic (sorted FILENAME/NAME/BASE/VERSION
  set), so an identical package set is not re-uploaded.
- Ordering: packages → metadata → public key → database.
- HTTP 500/429 retries, release reconciliation, mandatory remote
  verification, stale-signature purge in unsigned mode: all preserved.

## 8. Rust / x86-64-v4 compatibility (Phase F)

Untouched: `rustc-v4-safe.sh` and `build-in-docker.sh` have zero diff.
Final binaries remain v4 (`-C target-cpu=x86-64-v4` /
`-march=x86-64-v4`); build scripts/proc-macros are host-safe via the
wrapper. `any` packages unaffected.

## 9. Test results

### New regression tests

- `.github/tests/run-container-tests.sh`: `hello-skip` package (local
  tarball source + committed `SKIP` checksum): first run builds, second
  run **cache-hits** (regression for the fingerprint loop).
- `.github/tests/test-content-aware.sh`: same-version gate — drift
  blocked (no mutation), explicit override publishes, version bump
  publishes, non-package kinds unaffected.
- `.github/tests/test-http500.sh`: fixture archives made deterministic
  (`mk_tar` with fixed mtime + sorted members) so the realistic
  unchanged-merge path is byte-stable and does not trip the new gate.

### Full suite (RUN_PROD_SCENARIOS=1)

| Suite | result |
|---|---|
| test-content-aware.sh | PASS=30 FAIL=0 |
| test-build-cache.sh | PASS=20 FAIL=0 |
| test-rustc-wrapper.sh | PASS=10 FAIL=0 |
| test-epoch-filenames.sh | PASS=8 FAIL=0 |
| test-matrix.sh | PASS=85 FAIL=0 |
| run-container-tests.sh | PASS=34 FAIL=0 |
| test-http500.sh (container prod scenarios) | PASS=37 FAIL=0 |
| test-signing.sh | PASS=18 FAIL=0 |
| test-signing-mode.sh | PASS=45 FAIL=0 |
| test-verify-remote.sh | PASS=14 FAIL=0 |
| host lib suite (test-http500 host part) | PASS=6 FAIL=0 SKIP=1 |
| overall | **PASS=36 FAIL=0** (rc=0) |

Static gates: `bash -n` all scripts (exit 0), YAML safe_load (exit 0),
actionlint (exit 0), `git diff --check` (exit 0).

## 10. Expected behavior on a repeated unchanged run

With the fingerprint fix, an unchanged re-run should produce:

```
EXPECTED PACKAGE INVENTORY: 20
UNCHANGED ASSETS: 44
UPLOADED ASSETS: 0
REPLACED ASSETS: 0
FAILED OPERATIONS: 0
REMOTE RELEASE VERIFICATION: PASS
```

This is derived from the actual inventory (20 archives + 20 meta + 4
DB assets = 44), not hardcoded in pipeline logic. The DB assets are
compared semantically, so a byte-different but semantically identical DB
is not re-uploaded.

## 11. Files changed

- `.github/scripts/build-package.sh` — fingerprint normalization
  (effective vs raw), diagnostics, dropped redundant build-path
  `updpkgsums` re-run.
- `.github/scripts/gh-release-lib.sh` — `pkg_identity` helper +
  same-version fail-closed gate (with corrupt-remote recovery override).
- `.github/tests/test-content-aware.sh` — same-version gate tests.
- `.github/tests/run-container-tests.sh` — fingerprint-loop regression
  (hello-skip).
- `.github/tests/test-http500.sh` — deterministic fixture archives
  (`mk_tar`), used by merge/expand/recovery scenarios.
- `docs/phase-3.5-stability.md` — this report.

## 12. Remaining limitations / risks

- The published production meta fingerprints for the three churning
  packages already equal the new effective fingerprints, so the next
  production run should cache-hit them. If any other package's stored
  fingerprint was produced under a different normalization, it would
  rebuild once and then stabilize (one-time realignment).
- Full byte reproducibility is not achieved (`builddate` embedded by
  makepkg). Pinning `SOURCE_DATE_EPOCH` at build time would enable it but
  would change archive bytes for every package (one-time full rebuild)
  and is not required for the zero-mutation goal; deferred.
- The same-version gate blocks any future same-version byte drift unless
  `ALLOW_SAME_VERSION_REPLACE=1`. Toolchain-driven rebuilds of unchanged
  versions will need either a pkgrel bump or that override.
- Rolling sources (git/VCS) still legitimately change versions/revisions;
  the fingerprint reflects the committed PKGBUILD, and the resolved
  revision is encoded in pkgver via the pkgver() prepass.

## 13. Staging validation procedure

```bash
gh workflow run build-staging.yml --repo 88kbleirad/88kbleirad-arch-repo \
  --ref main --json '{"packages":"xclicker,xmousepasteblock,beautyline"}'
```

But note: with the fix, a staging run with these packages should
**cache-hit** (they are already built and published). To exercise the
fix's *rebuild-then-stabilize* path, run a full matrix on staging first,
then an unchanged repeat; the second run must be zero-mutation.

## 14. Production verification procedure

```bash
gh workflow run build-release.yml --repo 88kbleirad/88kbleirad-arch-repo \
  --ref main --json '{"confirm-production":"YES","signing-mode":"unsigned","packages":"<20-package inventory>"}'
```

Then re-run with identical inputs; expect `uploaded=0 replaced=0
failed=0` and remote verification PASS. Do not force `strict-cache=true`
unless the full fingerprint/fingerprint-expected state is verified, since
a one-time realignment may first rebuild a package.

## 15. Rollback / recovery

- Same-version gate never runs automatically; if an operator needs to
  force a same-version replacement (e.g. after a critical fix that does
  not bump pkgrel), set `ALLOW_SAME_VERSION_REPLACE=1` on the publish
  job env for that one run.
- If cache correctness is ever in doubt, `strict-cache=true` fails on any
  unexpected rebuild, making the divergence visible before publish.
- New package added (`local:/`…): standard expansion flow unchanged.

## 16. Caveats

- All results above are **local** (container + mock-gh harness). No live
  GitHub Actions run, publish, or release modification was performed.
- The `built_at` values in the production meta files were not modified.

---

# Hotfix Addendum (2026-11-05): BeautyLine 2:3.0.5-2

## H1. Reproduced root cause (publish block)

The 20-package production run after Phase 3.5 failed because the newly
built `beautyline` archive had different bytes from the published
`2:3.0.5-1` archive (fail-closed gate correctly refused the overwrite).

- Committed `beautyline/PKGBUILD` SHA256: `c05c6c712c5e4784fcd39d5daec00e255ba00c19a99cac006d0cf7a22f660e0e`
  (contains `sha256sums=('SKIP')`).
- `updpkgsums` rewrites it to the real source hash → PKGBUILD SHA256
  `670f588725035ea80cf0028f5728de50d604a9e835a38493c9c46e946940e9a1`
  (matches the old production archive's `.BUILDINFO pkgbuild_sha256sum`).
- Production archive sha256 `ce88d47734d22947a2db009e2762b21c2ff8c04c3a37004f1d1625d52f17136b`
  vs new CI archive `74acd8a24417e05b48009a4e7a39ada50235d29c8d25a39e65542eec6d8fdd7c`
  — identical identity (`2:3.0.5-1`, any), `.PKGINFO builddate` differs,
  payloads identical (symlink-safe `diff` exit 0 except .PKGINFO/.BUILDINFO/.MTREE).

## H2. BeautyLine PKGBUILD changes

- `pkgrel` 1 → 2 (epoch=2, pkgver=3.0.5 preserved).
- `sha256sums=('SKIP')` → verified pin
  `cab222dbed3008f214ce10494fb03a9f983f991477a7534885aedf119bb5cf79`
  (verified against the GitLab tarball for pinned commit
  `07e3736f8be38f9f48cf015d992f56f06e455002`).
- `package()` now repairs absolute symlinks (below).

## H3. Absolute symlink repair

The source ships 24 absolute symlinks pointing into the author's dev
environment (`/home/troupal/…`, `/home/oosh/…`, `/git/beautyline/…`,
`/home/tango/…`, `/usr/share/icons/breeze-dark/…`). The new `package()`
loop:

1. For each absolute link, derives the target basename.
2. Finds the matching entry (file or symlink) inside the packaged
   BeautyLine tree (excluding the link itself).
3. Verifies the resolved target stays inside the package.
4. Replaces the absolute link with a relative link computed via
   `realpath --relative-to`.
5. Fails the build if no target exists or resolution fails (fail closed).

One special case: `mimetypes/scalable/text-vnd.kde.kcrash-report.svg`
points at a KDE Breeze mimetype icon not present in the source; it is
mapped to `text-plain.svg` (which itself resolves to the package's
`text-x-generic.svg` — the canonical generic text-document icon per the
Freedesktop mimetype fallback chain). Documented semantic substitution
(approved; updated from the earlier text-xml approximation).

Validation of the built `2:3.0.5-2` archive:
- Absolute symlinks: 0
- Broken/unresolved symlinks: 0
- `dialog-transform.svg → transform-scale.svg` resolves, and wireless-100
  chains and kcrash all resolve.
- Icon payload count: 3165 files (3164 source icons + COPYING license) —
  no icons removed.

## H4. Fingerprint predicate correction

The Phase 3.5 normalization guard only normalized `SKIP` on non-VCS
sources. Verification of the 20-package audit found `xmousepasteblock`
(`git+…#commit=` source) is ALSO rewritten by `updpkgsums`, so its
fingerprint still mismatched. The predicate now normalizes `SKIP` for any
source whose checksum updpkgsums can compute — plain tarballs AND VCS
pinned to `#commit=`/`#tag=`; branch/HEAD `git+` sources keep `SKIP`.

## H5. 20-package preflight audit

Effective fingerprints vs stored release fingerprints (exact CI config):

| Package | classification |
|---|---|
| all-contributors-cli, catppuccin-fcitx5-git, catppuccin-whiskers-bin, ksuperkey, luajit-lgi, magika, nmtui-go, obs-pipewire-audio-capture, osu-mime, physlock, pvpn-go, pwvucontrol, rate-mirrors, ripdrag, snapper-rollback | UNCHANGED (match) |
| xclicker | UNCHANGED (match after normalize) |
| xmousepasteblock | UNCHANGED (match after predicate fix) |
| anpan-git | LEGITIMATE_VERSION_UPGRADE (source moved: 1.0.3.r1.g55609cd → 0.4.0.r6.g88dd31e) |
| catppuccin-obs-theme-git | LEGITIMATE_VERSION_UPGRADE (source moved: r35.054a297 → r21.d90002a) |
| beautyline | LEGITIMATE_VERSION_UPGRADE (2:3.0.5-1 → 2:3.0.5-2) |

No `SAME_VERSION_CONFLICT` remains: the only same-version drift that was
blocked was beautyline, now resolved by a genuine version bump.

## H6. Publishing preflight (new)

`publish-prod.sh` now runs `preflight_package_assets()` before any remote
mutation: every local package asset is classified against the remote
release; a same-version byte-drift aborts the run before a single
upload/delete, so a conflict in one package cannot leave a partially
modified Release. The per-asset gate in `gh_publish_asset` remains as a
second line of defense.

## H7. Release plan (not executed)

Deployment requires approval. Sequence:
1. Commit + push reviewed changes.
2. Run signed staging (`repository-v4-test`) — full matrix.
3. Verify repaired symlinks inside staged archive + signatures + 20 DB
   entries.
4. Run unsigned production (`repository`) — full matrix.
5. Verify DB consistency + download-only smoke install of beautyline in an
   isolated environment.
6. Repeat production with unchanged inputs → zero-mutation goal
   (`unchanged=44 uploaded=0 replaced=0 failed=0`).

## H8. Hotfix regression results

- Container suite: PASS=34 FAIL=0 (hello-skip regression still green after
  predicate fix).
- test-http500.sh (container): PASS=49 FAIL=0 (incl. same-version preflight
  and downgrade-regression preflight tests).
- test-signing-mode.sh: PASS=18 FAIL=0 (after deterministic fixture + .sig
  preflight skip).
- test-signing.sh: PASS=37 FAIL=0.
- Full suite `run-tests.sh` (RUN_PROD_SCENARIOS=1): **overall PASS=36
  FAIL=0** (rc=0); host lib 6/0/1skip, content-aware 30, build-cache 20,
  rustc 10, epoch 8, matrix 85, http500-prod 49, signing 37, signing-mode
  18, verify-remote 14, container 34.
- Static gates: `bash -n` all scripts, YAML safe_load, actionlint,
  `git diff --check` — all exit 0.

Remaining limitations unchanged: builddate embedded by makepkg (full byte
reproducibility not claimed); same-version gate requires pkgrel bump or
explicit override for any future same-version byte drift.

## H9. VCS version regression review (pre-deployment)

The 20-package preflight flagged two VCS packages whose *committed*
`pkgver=` placeholders appeared lower than the published versions. Full
investigation (vercmp + upstream ancestry + pkgver() resolution):

| Package | committed pkgver | pkgver() resolved | published | verdict |
|---|---|---|---|---|
| anpan-git | 0.4.0.r6.g88dd31e | **1.0.3.r1.g55609cd** | 1.0.3.r1.g55609cd-1 | no regression — resolved == published |
| catppuccin-obs-theme-git | r21.d90002a | **r35.054a297** | r35.054a297-1 | no regression — resolved == published |

- `vercmp 1.0.3.r1.g55609cd-1 0.4.0.r6.g88dd31e-1` → 1 (only the stale
  placeholder is lower; the resolved VCS version is unchanged).
- Upstream ancestry verified: anpan HEAD = `55609cd`, obs HEAD =
  `054a297` (35 commits) — both identical to the published builds.
- The committed `pkgver=` lines are AUR-sync placeholders; `pkgver()`
  rewrites them during makepkg's prepass. The pipeline fingerprints the
  **post-prepass** PKGBUILD, matching the stored production fingerprints
  exactly (`16d9ba3c…`, `ab2c1611…`) → cache HIT, no rebuild.
- The earlier "mismatch" was an audit-probe artifact (it hashed the
  pre-prepass file), not a pipeline defect. No PKGBUILD correction is
  required or made.

### Downgrade-prevention preflight (new)

`publish-prod.sh` preflight additionally detects genuine version
regressions: for each local package it compares the resolved version
against the published database version via pacman `vercmp`; if local <
published, the run aborts before any mutation (e.g. an upstream history
rewrite or tag deletion lowering a VCS package's version). Tested: a
local `testa-1.0` against published `testa-2.0` aborts with the release
untouched.

## H10. BeautyLine symlink semantic review

All 24 repaired links reviewed. 23 are semantically faithful (each maps
to the same icon subject: projects-folder, wireless-network, zoom,
transform/scale, dosbox app). The single flagged case
`text-vnd.kde.kcrash-report.svg` (original target: a KDE Breeze mimetype
icon absent from the source) is mapped to `text-plain.svg`, which
resolves to the package's `text-x-generic.svg` — the canonical generic
text-document icon in the Freedesktop mimetype fallback chain. This is a
documented semantic substitution (the closest available generic text
icon), not an arbitrary same-basename match.
