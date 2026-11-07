# Phase 7 Batch 2 — staging prep (fzf-git, swaync-git)

Status: local validation PASS (builds rc=0, v4 evidence, matrix 85/85, full
suite running). Remote operations NOT executed — all below require owner
approval.

## Commit / PR proposal

```
feat(packages): onboard Batch 2 VCS variants (fzf-git, swaync-git)

- fzf-git 2:v0.74.5.r13.g96028e2a-1 (AUR verbatim; MIT; ncurses; go)
- swaync-git r689.b8017a4-1 (AUR verbatim; GPL3; GTK4 stack)
- both are VCS variants that provide/conflict the official names
  (extra/fzf, extra/swaync); aligned with existing repo VCS-variant
  convention (e.g. awesome-luajit-git)
- packages.txt: +2 entries under "Onboarding batch 2 (VCS variants;
  staging first)"
- docs/inventory/onboarding-roadmap-2026-11-07.md: multi-batch plan for
  the remaining 54-entry inventory
```

Branch: `feat/onboard-batch2-fzf-swaync` (created, staged, not committed).

## Staging dispatch (owner-approved)

```bash
gh workflow run build-staging.yml \
  --repo 88kbleirad/88kbleirad-arch-repo \
  --ref main \
  --json '{"packages":"fzf-git,swaync-git"}'
```

Staging release: `repository-v4-test` (signed, merge keeps existing 23).

## Acceptance gates (enforced by pipeline)

- Build jobs pass (hosted ubuntu-24.04 + generic Arch container, v4 profile)
- EXPECTED_INVENTORY PASS; archives valid; signatures present
- Cache verification PASS; remote verification PASS; health HEALTHY

## Verification commands (after staging)

```bash
gh run list --workflow=build-staging.yml --limit 1 --repo 88kbleirad/88kbleirad-arch-repo
gh run view <RUN_ID> --repo 88kbleirad/88kbleirad-arch-repo
gh api repos/88kbleirad/88kbleirad-arch-repo/releases/tags/repository-v4-test \
  --jq '[.assets[].name] | map(select(.|test("fzf|swaync")))'
# then install test on v4 host:
pacman -Sy
pacman -S fzf-git swaync-git
pacman -Qi fzf-git swaync-git | grep -E 'Name|Version|Packager'
```

## Rollback

- Staging is non-destructive (merge). To pull the pair: remove the two
  lines from `packages.txt` and from `fzf-git/`/`swaync-git/` in a PR;
  next staging run prunes the DB references. Production untouched until an
  explicit `build-release.yml` run with `confirm-production=YES`.
- If a consumer hits the official-vs-VCS conflict: they choose one source
  (official `fzf`/`swaync` OR repo `-git` variants) — pacman conflict
  resolution refuses coexistence, which is the intended behavior.
