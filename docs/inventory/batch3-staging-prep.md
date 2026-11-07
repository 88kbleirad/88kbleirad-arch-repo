# Phase 8 Batch 3 — hw-probe (single candidate)

Status: local validation PASS (real-pipeline build rc=0, arch=any Perl
script, matrix 85/85, full suite running). Remote operations NOT executed —
all below require owner approval.

## Candidate decision summary

| Candidate | Verdict | Reason |
|---|---|---|
| hw-probe | **GO FOR STAGING** | AUR 1.6.6-3 maintained; all deps official (no AUR chain); arch=any; source sha256 verified; default probe offline (upload only with explicit `-upload`); LGPL-2.1-or-later OR BSD-4-Clause |
| neofetch | **LEGACY_HOLD / NO-GO (this batch)** | Upstream archived since 2024; pinned 2020 commit; CI PGP verify fails (validpgpkeys not present in build container keyring and not auto-fetched by makepkg); shell script arch=any; official `extra/fastfetch` is the maintained alternative (not silently substituted) |
| proton-authenticator | **NEEDS_MANUAL_REVIEW** | AUR source tag `proton-authenticator@1.1.6` 404 on GitHub (WebClients has no such tag today); unbuildable until upstream/AUR fixed |

## Commit / PR proposal

```
feat(packages): onboard Batch 3 hw-probe (arch=any Perl probe)

- hw-probe 1.6.6-3 (AUR verbatim; LGPL-2.1-or-later OR BSD-4-Clause;
  perl + official hardware tools deps)
- packages.txt: +1 entry under "Onboarding batch 3 (hw-probe; staging
  first)"
- docs/inventory/classification-2026-11-07.md: Batch 3 audit status table
- docs/inventory/onboarding-roadmap-2026-11-07.md: corrected build-blocker
  notes + Batch 3 status
```

Branch: `feat/onboard-batch3-hwprobe` (created, staged, not committed).

## Staging dispatch (owner-approved)

```bash
gh workflow run build-staging.yml \
  --repo 88kbleirad/88kbleirad-arch-repo \
  --ref main \
  --json '{"packages":"hw-probe"}'
```

Staging release: `repository-v4-test` (signed, merge keeps existing 25).

## Acceptance gates (pipeline-enforced)

- Build job passes; EXPECTED_INVENTORY PASS; archive valid; signature present
- Cache verification PASS; remote verification PASS; health HEALTHY

## Verification commands (after staging)

```bash
gh run list --workflow=build-staging.yml --limit 1 --repo 88kbleirad/88kbleirad-arch-repo
gh run view <RUN_ID> --repo 88kbleirad/88kbleirad-arch-repo
gh api repos/88kbleirad/88kbleirad-arch-repo/releases/tags/repository-v4-test \
  --jq '[.assets[].name] | map(select(.|test("hw-probe")))'
# install test on v4 host:
pacman -Sy && pacman -S hw-probe
pacman -Qi hw-probe | grep -E 'Name|Version|Packager'
# offline smoke (no -upload, no root):
hw-probe --help
```

## Rollback

- Staging is non-destructive (merge). To pull: remove the `hw-probe` line
  from `packages.txt` and the `hw-probe/` dir in a PR; next staging run
  prunes the DB reference. Production untouched until an explicit
  `build-release.yml` run with `confirm-production=YES`.
- hw-probe never uploads hardware info unless the user explicitly passes
  `-upload` (or `-generate-inventory-id` / `-remind-inventory`) and
  confirms; the packaged default is offline.
