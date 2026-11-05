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
