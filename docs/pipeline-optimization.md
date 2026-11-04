# Content-aware publishing, remote verification and build-cache verification

This document describes the three optimization objectives implemented for the
88kbleirad production release pipeline, the observed behavior, and how to use
the new verification steps.

## 1. Content-aware publishing

`publish-prod.sh` now compares local content against the remote Release before
touching any asset.

For every asset (package archive, `v4-*.meta.json`, database/index files):

1. compute local SHA-256;
2. query the remote asset;
3. obtain a trustworthy remote checksum from the GitHub API `digest` field
   (`sha256:...`) when present and valid — a malformed digest is rejected;
4. otherwise fall back to a safe download-and-hash of the remote asset;
5. `UNCHANGED` → skip upload and skip delete;
6. `NEW`/`MISSING` → upload;
7. `CHANGED` → replace (DELETE+POST, never PATCH);
8. `UNKNOWN` (checksum cannot be retrieved, fallback failed) → **fail
   closed**: a valid asset is never deleted merely because its checksum was
   unavailable.

Asset byte equality is never inferred from filename/version/size/ETag.

### Database optimization

`repo-add` is nondeterministic: byte-identical package sets produce different
archives because of embedded timestamps (verified). The pipeline therefore
performs **semantic** database comparison — the sorted `(NAME, VERSION,
FILENAME)` set referenced by the regenerated database versus the previously
published one. When the sets are equal, the database is reported
`UNCHANGED database set (semantic)` and **no** database asset is re-uploaded.
The canonical `.db.tar.gz` / `.files.tar.gz` and their plain aliases (which
`repo-add` creates as symlinks) stay consistent because they are uploaded as
separate assets with identical bytes.

### Mutation safety and ordering

Uploads happen in dependency order: package archives first, then metadata,
then the public key, then database assets. A failure aborts all later
dependent mutations. The database is never published before the archives it
references exist.

### Logging

Structured per-asset lines:

```text
[publish] UNCHANGED package: nmtui-go
[publish] UNCHANGED metadata: v4-nmtui-go.meta.json
[publish] NEW package: example-package
[publish] CHANGED database: 88kbleirad.db.tar.gz
[publish] SUMMARY unchanged=12 uploaded=1 replaced=2 failed=0
```

## 2. Remote post-publish verification

`.github/scripts/verify-remote-release.sh` runs **after** every production
publish and is mandatory (the publish job exits nonzero if it fails). It is
read-only and never mutates the release.

Checks:

- release exists; assets enumerated;
- every expected package archive exists and downloads + validates;
- every required `v4-<pkg>.meta.json` exists;
- all four database/index assets exist: `.db`, `.db.tar.gz`, `.files`,
  `.files.tar.gz`;
- the database downloads, extracts, and is structurally valid;
- database package names/versions match the expected inventory;
- the database references only assets that exist in the release;
- plain aliases match their canonical compressed counterparts (digest);
- remote digests reconcile against the local manifest dir (`output/`):
  byte-wise for packages/metadata, **semantic** for database assets (because
  an intentionally-skipped unchanged database differs byte-wise);
- unsigned mode: stale detached signatures are rejected; signed mode: all
  required detached signatures must be present.

Output:

```text
REMOTE RELEASE VERIFICATION
Release: repository
Packages expected: 8
Packages available: 8
Packages validated: 8
Metadata validated: 8
Database assets: 4/4
Database consistency: PASS
Checksums: PASS
Signing mode: unsigned
Result: PASS
```

## 3. Deterministic build-cache verification

`.github/scripts/verify-build-cache.sh` matches every expected package to its
build result and classifies it:

| Status | Meaning |
|---|---|
| `HIT` | cache hit (`status-skipped`) with a valid archive |
| `MISS` | legitimate rebuild (`status-built`) — allowed in normal mode |
| `MISS_FINGERPRINT` | metadata exists but no result (fingerprint changed) |
| `MISS_ARCHIVE` | matching metadata but no archive |
| `INVALID` | cached archive failed validation, with a precise reason |
| `WRONG_PROFILE` | cached metadata carries a different build profile |
| `DUPLICATE` | more than one result/archive for the package |
| `FAILED` | build status-failed |
| `EXCLUDED` | intentionally excluded |
| `MISSING` | no result recorded |
| `TOOL_UNAVAILABLE` | archive validation tools missing (infrastructure error) |

A metadata-only artifact never qualifies as a hit. `--strict`/`--all` modes
turn any unexpected miss into a failure; normal mode reports but allows
rebuilds.

### Deterministic cache metadata

On a cache hit, `build-package.sh` now reuses the previously published
`built_at` timestamp instead of stamping a fresh one when the prior meta has
the same `status=skipped` and `fingerprint` (identical content). This makes
a repeated identical run produce byte-identical `v4-<pkg>.meta.json`
assets — so a second publish performs **zero** metadata mutations. The
`built_at` field is informational (no functional consumers); fingerprints,
profile, status, and package identity are untouched as `built_at` is the
only varying field across runs.

Validation prefers `bsdtar` (libarchive), which is exactly the tool used
inside the build/publish container. The default GitHub-hosted Ubuntu runner
does **not** ship it, so:

- the `cache-verify` workflow job installs `libarchive-tools zstd` before
  verifying (identical validation semantics to the container);
- the verifier also probes for GNU `tar` with zstd support and falls back to
  it when `bsdtar` is unavailable;
- if **no** usable archive reader exists, artifacts are classified
  `TOOL_UNAVAILABLE` (infrastructure error, fail-closed) — never
  `CORRUPT`. A missing tool can never produce a false CORRUPT verdict.

Invalid archives are reported with precise reasons:

```text
INVALID: archive decompression failed or missing .PKGINFO
INVALID: missing .PKGINFO (no pkgname)
INVALID: checksum mismatch
INVALID: missing archive
INVALID: incorrect build profile
```

Optional byte-exact verification is available via `--hashes '{"pkg":"sha256hex"}'`
(returns `INVALID: checksum mismatch` on mismatch).

## 4. Workflow integration

- `build-release.yml` gained a `strict-cache` input (default `false`) and a
  `cache-verify` job that runs after `build` and before `publish`.
  `publish`/`publish-signed` now require `cache-verify` to pass. The job
  installs `libarchive-tools`+`zstd` on the Ubuntu runner so archive
  validation uses the same `bsdtar` semantics as the build container.
- The publish job runs `verify-remote-release.sh` (inside the container) after
  uploads; failure fails the job.
- `EXPECTED_PACKAGES` (the prepare matrix) is the single source of the
  expected inventory for both verification steps. Nothing is hardcoded to
  the current 8 packages.

## 5. Testing

New regression suites:

- `test-content-aware.sh` — identical/changed/missing/unknown checksums,
  malformed digest fallback, transient 500, 429 Retry-After, failed-upload
  abort ordering, repeated-publish idempotency (host-level);
- `test-verify-remote.sh` — valid release + 10 negative cases
  (container-level, uses real `repo-add`);
- `test-build-cache.sh` — 20 cache scenarios including: 8/8 valid hits,
  legitimate miss, strict vs normal, fingerprint mismatch, metadata-only
  artifact, missing archive, corrupted archive with precise reason, missing
  `.PKGINFO`, checksum mismatch (`--hashes`), missing validation tools →
  `TOOL_UNAVAILABLE` (never false CORRUPT), and the flat GitHub Actions
  artifact-merge layout (host-level);
- `test-http500.sh` prod scenarios now cover content-aware second-run
  idempotency end-to-end.

Run everything with:

```bash
REPO_ROOT="$PWD" bash .github/tests/run-tests.sh
```
