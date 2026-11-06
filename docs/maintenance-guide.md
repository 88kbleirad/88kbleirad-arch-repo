# 88kbleirad Arch Repo — Maintenance Guide

**Applies to:** v1.0 (maintenance mode) after Phase 5.

## 1. Roles & responsibilities

| Role | Duties |
|---|---|
| Maintainer (owner) | approves proposal PRs, runs production publication, manages signing environments, reviews reports |
| CI/CD automation | lifecycle detection, proposals, health gates, observability — all read-only unless manually authorized |

## 2. Regular maintenance cadence

- **Weekly (or on demand):** run `Package Lifecycle` workflow
  (`workflow_dispatch`) with `open-pr=false` to refresh `update-report.json`
  and download it for review.
- **Review updates:** inspect `docs/update-proposals/` proposal files; for
  each verified update, decide whether to apply the PKGBUILD change manually
  (the proposal never edits source).
- **Publish:** after merging PKGBUILD changes, run the staging workflow, then
  (after staging passes) the production workflow with explicit
  `confirm-production=YES`.
- **Observe:** run the `Observability Dashboard` workflow after publications
  or on demand; download the dashboard artifact.

## 3. Operational commands (fish shell)

```fish
# lifecycle detection (read-only)
set -x REPO_ROOT (pwd)
set -x GH_TOKEN (gh auth token)
bash $REPO_ROOT/.github/scripts/check-updates.sh \
  --json /tmp/update-report.json --summary /tmp/update-summary.md

# proposal preview
bash $REPO_ROOT/.github/scripts/propose-updates.sh \
  --report /tmp/update-report.json --outdir /tmp/proposals

# Phase 5.2 PR validation — LOCAL/mocked (Mode A, no remote writes)
bash $REPO_ROOT/.github/tests/test-propose-updates.sh

# Phase 5.2 PR validation — REMOTE (Mode B, OWNER-AUTHORIZED ONLY):
# creates a documentation-only fixture PR under validation/phase5-pr-test-<id>
gh workflow run check-updates.yml -f open-pr=true -f allow-remote-pr=true

# repository health (read-only)
bash $REPO_ROOT/.github/scripts/repo-health.sh repository \
  88kbleirad/88kbleirad-arch-repo \
  --signing-mode unsigned --build-profile x86-64-v4 \
  --json /tmp/health-report.json --summary /tmp/health.md

# production dry-run (no mutations)
gh workflow run build-release.yml \
  -f confirm-production=YES -f dry-run=true

# dashboard preview
bash $REPO_ROOT/.github/scripts/build-dashboard.sh \
  --metrics /tmp/snapshot.json --out /tmp/dashboard
```

## 3b. Phase 5.2 PR validation & cleanup

- **Fixture identity**: validation branches are always
  `validation/phase5-pr-test-<id>` (deterministic id derived from the report
  digest). Reruns reuse the same branch/PR — never a duplicate.
- **Behavior**: an open PR is updated in place; a closed PR is not silently
  reopened (a fresh PR is created on the same branch); a merged PR is never
  recreated. Merging a validation PR is forbidden and does not publish.
- **Record for audit**: PR number, branch, commit SHA, result. Example:

  ```fish
  gh pr list --head validation/phase5-pr-test-owner-<id> --state all --json number,url,headRefName,mergeCommit
  ```

- **Cleanup (owner-only, targeted)**: close the validation PR and delete
  only its branch. Never use wildcard cleanup.

  ```fish
  # capture the PR number from the list above
  set -x PR_N 12345
  gh pr close $PR_N --repo 88kbleirad/88kbleirad-arch-repo
  git push origin --delete validation/phase5-pr-test-owner-<id>
  ```

## 4. Publication procedures

### Staging (signed)

1. Run `build-staging.yml` (manual dispatch; packages input default).
2. Staging publishes to `repository-v4-test` with GPG signatures.
3. The post-publication health gate must be `HEALTHY`.

### Production (unsigned)

1. Only after staging validation.
2. Run `build-release.yml` with `confirm-production=YES` and the desired
   `packages`/`allow-critical` inputs.
3. `signing-mode` defaults to `unsigned` (never signed by default).
4. Verify the publish SUMMARY:
   `unchanged=44 uploaded=0 replaced=0 failed=0` for a no-change run.
5. Verify the post-publication health gate reports `HEALTHY`.

## 5. Signing & trust policy (never changed without owner authorization)

- Production: **unsigned**.
- Staging: **signed** (GPG key in the `package-signing` environment).
- Client pacman policy: `SigLevel = Optional TrustAll` (kept).
- Checksum/integrity verification (`repo-health.sh`, `validate-release.sh`)
  is distinct from cryptographic package authentication.

## 6. Recovery procedures

- **Interrupted publish:** local `publish-manifest-<tag>.json` records the
  pre-mutation state; re-run the same publish for idempotent reconciliation.
- **Corrupt/absent DB:** `publish-prod.sh` reconstructs from verified
  release archives (fail-closed).
- **Failed/restored build:** protected via `protect-*.txt` /
  `EXCLUDED_BASES_FILE`; next run rebuilds.
- **Orphaned release assets:** `repo-health.sh` reports them in
  `cleanup_proposal` (with id/size/digest). Deletion is a separately
  authorized manual operation (`gh release delete-asset` with exact names).

## 7. Troubleshooting

| Symptom | Check |
|---|---|
| Lifecycle report shows `CHECK_FAILED` | upstream probe failure/rate limit — retry later; never an update |
| `UPSTREAM_ARCHIVED` / `UPSTREAM_UNAVAILABLE` | upstream repo archived/missing — manual review required |
| Proposal PR not created | `open-pr=false` (default); no verified updates; or branch already exists |
| Dashboard shows `N/A` | corresponding source artifact/report absent — no fabrication |
| Health gate failed | download `health-report-<tag>.json` artifact; verdict is authoritative |
| Publish SUMMARY `failed>0` | asset content/availability error — abort before further mutations |
| Dry-run `DRY_RUN=1` still shows mutations | verify workflow input binding (`inputs.dry-run && '1' || '0'`) and script normalization |

## 8. Known limitations

- GitHub Releases are non-atomic; a mid-publish crash can leave partial
  assets (reconciled by the next idempotent publish).
- Automatic extension of proposals to full PKGBUILD patches is out of scope
  by design: proposals are evidence documents; PKGBUILD edits are human
  actions.
- The dashboard renders the latest verified snapshot(s); it does not
  stream live data.
