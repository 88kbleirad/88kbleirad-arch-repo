# Phase 8.1 — Multi-Package Publication Safety

Status: implemented + local validation (see evidence below). No remote
writes were performed for this hardening task.

## 1. Publication architecture (as built)

- **Recoverable publication**: every publish run captures a versioned
  pre-mutation recovery manifest (`publish-recovery-manifest/v1`) BEFORE
  the first remote mutation. The manifest records repository, tag,
  workflow run id, source commit, signing mode, timestamp, and the full
  remote asset inventory (name, id, digest, kind). It is persisted by the
  workflow as a restricted artifact (`publish-recovery-manifest-<tag>`,
  retention 30 days) with `if: always()` so it survives a failed job. It
  contains no secrets/keys. If it cannot be captured+validated, the run
  fails before any mutation.
- **Content-aware publication**: assets whose remote SHA-256 digest equals
  the local file are skipped (UNCHANGED); changed/new assets go through
  `gh_publish_asset` → `gh_upload_asset`.
- **Digest-verified reconciliation**: an ambiguous upload outcome (5xx /
  transport error) is only treated as success when the remote asset's
  trustworthy SHA-256 digest matches the local file. Filename presence is
  never sufficient. If the digest cannot be obtained/verified, the upload
  is retried or failed — never claimed successful.
- **Recovery-gated replacement**: `gh_delete_asset` refuses to remove an
  existing asset unless the caller has armed
  `GH_REQUIRE_RECOVERY_SNAPSHOT=1` AND `RECOVERY_SNAPSHOT_OK=1`
  (set only after the snapshot validates). Publish entrypoints arm it;
  legacy lib callers (tests) are unchanged.
- **Ordering**: packages → metadata → public key → database. The database
  is published only after the archives it references exist and are
  verified; canonical `.db`/`.files` archives, aliases, and signatures
  are preserved.
- **DB content-consistency**: the semantic DB comparison now also compares
  `%SHA256SUM%` (plus FILENAME/NAME/BASE/VERSION). A rebuilt package with
  identical identity but different archive content forces a DB re-upload.
- **Staging**: same helpers as production (content-aware, digest-verified,
  recovery-gated, ordered); signatures and `repository-v4-test` preserved;
  `gh release upload --clobber` removed; post-publish remote verification
  and health gate unchanged.

### Terminology
- Atomic publication: **not achieved** — GitHub Release assets are mutable
  and cannot be replaced atomically by name. Documented limitation.
- Recoverable publication: yes — snapshot + artifact + gated deletion.
- Idempotent publication: yes — identical content causes zero mutations.
- Content-aware publication: yes.

## 2. Failure handling matrix

| Phase | Behavior |
|---|---|
| Before any mutation | snapshot capture + validation; fail-closed if impossible |
| Package upload | content-aware + digest reconciliation; abort downstream on failure |
| Metadata upload | same; abort downstream |
| Signature upload | same; missing signature in signed mode aborts |
| Database upload | after packages/meta verified; per-asset abort |
| Stale cleanup | only with verified snapshot; protected assets never deleted |
| Remote verification | post-publish, mandatory; failure → no success reported |
| Ambiguous API | digest reconcile → retry (retryable) or fail (non-retryable) |
| Runner interruption | manifest artifact remains; manual recovery via restore procedure |
| Dry-run | zero remote writes (lib-level short-circuit) |

## 3. Manual recovery procedure

1. Download the recovery artifact (`publish-recovery-manifest-<tag>`) from
   the failed run.
2. Validate schema `publish-recovery-manifest/v1` and confirm the release
   tag matches.
3. Compare current release assets to the manifest. Any asset in the
   manifest but now missing is the damage set.
4. Restore each missing asset from the release's previous content: if the
   artifact is a package/database, re-upload the archived bytes (or
   rebuild the package and re-publish with the same identity).
5. Never delete or mutate assets not listed in the manifest.
6. Re-run remote verification before considering the release healthy.

## 4. Fault-injection coverage

| ID | Scenario | Where |
|---|---|---|
| F01 | 5 packages build+validate | `test-release-safety.sh` (host) |
| F02 | third package build fails → blocked | `test-http500.sh` container |
| F03 | third package upload fails → abort+recovery | `test-release-safety.sh` |
| F04 | existing asset delete+replacement fails → preservation | `test-http500.sh` container |
| F05 | HTTP 500 after successful upload → digest reconcile | `test-release-safety.sh` |
| F06 | filename exists with wrong checksum → rejected | `test-release-safety.sh` |
| F07 | same version, different archive checksum → DB enforced | `test-http500.sh` container |
| F08 | database archive upload fails | covered by F04-style abort path + publish ordering (abort on first failure) |
| F09 | one DB alias fails → no false success | abort-on-first-failure in `publish_assets_loop`; remote verification gate |
| F10 | package signature missing → signed rejected | `test-http500.sh` container |
| F11 | signing failure → no silent unsigned fallback | existing `test-signing-mode.sh` (18/18) |
| F12 | HTTP 429 (transient + persistent) | `test-release-safety.sh` |
| F13 | permanent HTTP 4xx → fail no retries | `test-release-safety.sh` |
| F14 | interruption → recovery usable | manifest artifact design (workflow `always()` upload) |
| F15 | identical republish → idempotent | `test-release-safety.sh` |
| F16 | downgrade/ same-version byte drift blocked | `test-release-safety.sh` (real archive identity) |
| F17 | dry-run zero mutations | `test-release-safety.sh` |
| F18 | snapshot cannot be verified → fail before mutation | `test-release-safety.sh` |
| F19 | remote inventory incomplete → never treated complete | `test-http500.sh` container |
| F20 | signed staging 5-package path | staging workflow unchanged + same helper path; exercised via existing staging E2E in `run-tests.sh` |

## 5. Evidence summary

- Fault-injection host suite `test-release-safety.sh`: **PASS=23 FAIL=0**.
- Extended `test-http500.sh` container scenarios (RUN_PROD_SCENARIOS=1):
  results in the run log (F02/F04/F07/F10/F19).
- Existing suites: `test-content-aware.sh` 30/30; `test-verify-remote.sh`
  14/14; `test-signing-mode.sh` 18/18 (container);
  `test-http500.sh` host 11/11 + container suite; full `run-tests.sh`
  PASS=55 FAIL=0.
- Bash syntax: all scripts. YAML: all workflows.

## 6. Batch 4 readiness

See final report verdict. Staging (5 packages) is the next authorized step;
production requires separate owner approval after staging health.

## 7. Known limitations

- GitHub Release same-name asset replacement is delete-then-upload; not
  atomic. Mitigated via recovery-gated deletion + digest verification.
- Asset digest trust relies on GitHub's `digest` field when valid,
  with download-and-hash fallback; a fully offline/unverifiable remote
  fails closed (never treated as success).
- Automatic rollback is not performed; only verified manual recovery is
  provided (destructive rollback from an untrusted manifest is forbidden).
