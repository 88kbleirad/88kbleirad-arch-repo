# Phase 8.2 Batch 4 — clash-geoip (single candidate)

Status: local validation PASS (real-pipeline build rc=0, arch=any data
package, cache round-trip byte-identical, matrix/CI gates passing).
Remote operations NOT executed — all below require owner approval.

## Candidate decision summary

| Candidate | Verdict | Reason |
|---|---|---|
| clash-geoip | **APPROVED_FOR_BATCH4** | AUR 202610160207-1 maintained (pngdeity); arch=any data pkg (Country.mmdb); no dependencies; source sha256 verified against upstream release digest; CC-BY-SA-4.0 + GPL-3.0-or-later; installs to `/etc/clash/Country.mmdb` only. Da v4 build value (pure data) — correctly NOT labeled v4-optimized. |
| mihomo | **NEEDS_MANUAL_REVIEW** | Go x86_64 build feasible, but ships a systemd service with CAP_NET_ADMIN/RAW/BIND_SERVICE and conflicts/provides `clash-meta` (privileged network daemon replacing a legacy variant). Requires owner review of the service/integration profile before batch onboarding. |
| betterlockscreen | **DEFER_TO_LATER_BATCH** | arch=any, but depends on `i3lock-color>=2.13.c.3` (AUR-only, PAM-integrated security-sensitive component not in this repository). Violates the no-AUR-only-dependency-chain convention until i3lock-color is separately reviewed. |

## Why only one package

The batch was planned dependency-first (mihomo → clash-geoip;
betterlockscreen → i3lock-color). Only clash-geoip passes the full audit
today; the other two are held for review. The batch is intentionally NOT
forced to five packages.

## Commit / PR proposal

```
feat(packages): onboard Batch 4 clash-geoip (arch=any data)

- clash-geoip 202610160207-1 (AUR verbatim incl. .SRCINFO +
  clash-geoip.changelog stub; CC-BY-SA-4.0/GPL-3.0-or-later; installs
  /etc/clash/Country.mmdb)
- packages.txt: +1 entry under "Onboarding batch 4 (clash-geoip;
  staging first)"
- docs/inventory/batch4-staging-prep.md: this plan
- docs/inventory/onboarding-roadmap-2026-11-07.md: Batch 4 status
  (clash-geoip approved; mihomo/betterlockscreen review/defer)
```

Branch: `feat/phase8.2-batch4-onboarding` (created, staged, not committed).

## Staging dispatch (owner-approved)

```bash
gh workflow run build-staging.yml \
  --repo 88kbleirad/88kbleirad-arch-repo \
  --ref main \
  --json '{"packages":"clash-geoip"}'
```

Staging release: `repository-v4-test` (signed, merge keeps existing 26).

## Acceptance gates (pipeline-enforced)

- Build job passes; EXPECTED_INVENTORY PASS; archive valid; signature present
- Cache verification PASS; remote verification PASS; health HEALTHY

## Verification commands (after staging)

```bash
gh run list --workflow=build-staging.yml --limit 1 --repo 88kbleirad/88kbleirad-arch-repo
gh run view <RUN_ID> --repo 88kbleirad/88kbleirad-arch-repo
gh api repos/88kbleirad/88kbleirad-arch-repo/releases/tags/repository-v4-test \
  --jq '[.assets[].name] | map(select(.|test("clash-geoip")))'
# install test on a v4 host:
pacman -Sy && pacman -S clash-geoip
pacman -Qi clash-geoip | grep -E 'Name|Version|Packager'
sha256sum /etc/clash/Country.mmdb
# expected: 64809d264be87ecfb7ac3ad19b7678893b6275038a7d4bf9eec72464a6c4f9fe
```

## Rollback

- Staging is non-destructive (merge). To pull: remove the `clash-geoip`
  line from `packages.txt` and the `clash-geoip/` dir in a PR; next
  staging run prunes the DB reference. Production untouched until an
  explicit `build-release.yml` run with `confirm-production=YES`.
- The package installs a single read-only data file; no daemons, no
  services, no privileged hooks, no network access at install/runtime.
