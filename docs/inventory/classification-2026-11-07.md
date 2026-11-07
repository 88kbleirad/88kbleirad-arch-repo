# 88kbleirad package inventory — corrected classification (54/54)

Source of truth: `docs/inventory/omp-package-inventory.csv` (54 rows) cross-checked
against `docs/inventory/arch_package_inventory_audit_2026-11-06.xlsx` triage sheet,
live production/staging release assets (gh API, read-only), `packages.txt`, and
per-package PKGBUILD dirs. All 54 rows classified; no row is unclassified.

| Class | Count | Packages |
|---|---|---|
| staging candidate | 7 | betterlockscreen, dynamips, fzf-git, mihomo, swaync-git, ubridge, vpcs |
| already configured | 2 | equicord-openasar, msi-ec-dkms-git |
| conflicting variant | 9 | awesome-git, electron37, electron38, fcitx5-lotus-bin, lua-lgi-git, mcontrolcenter-bin, rustdesk-bin, xlibre-xserver-src, zalo-for-linux-bin |
| binary redistribution review | 10 | balena-etcher, clash-party-bin, equibop-bin, ghostline-bin, maplemono-nf-cn-unhinted, maplemono-nf-unhinted, obsidian-bin, oh-my-posh-bin, powershell-bin, zoom |
| dependency/system hold | 14 | bridge-utils, gtkmm, lib32-audit, lib32-gettext, lib32-libcap, lib32-libnsl, lib32-libtirpc, lib32-pam, litehtml0.9, nitrogen, python-aiohttp-cors, qt5-remoteobjects, qt5-wayland-decorations, wlroots0.19 |
| legacy/security risk | 3 | lib32-openssl-1.0, openssl-1.0, packettracer |
| needs manual review | 2 | open-webui, vikunja |
| deferred addition review | 7 | arc-icon-theme, catppuccin-gtk-theme-frappe, catppuccin-gtk-theme-mocha, clash-geoip, hw-probe, neofetch, proton-authenticator |

Count check: 7+2+9+10+14+3+2+7 = 54 = rows in inventory.

---

## Production onboarding status (current, 2026-11-07)

The following three packages from the `staging candidate` class completed the
full onboarding pipeline and are **published in the production release
(`repository`)**: built (x86-64-v4), staged, health-checked, signed, and
installed/verified on a real Arch Linux x86-64-v4 host.

| Package | Published version | Production status |
|---|---|---|
| `dynamips` | 0.2.25-1 | **onboarded (production)** |
| `ubridge` | 1.3.0-1 | **onboarded (production)** |
| `vpcs` | 0.8.5-1 | **onboarded (production)** |

Verified production release inventory (2026-11-07): 23 package archives +
23 detached signatures + signed database; no duplicates.
See `docs/final-validation.md` → Phase 6 for the full evidence trail.

## Batch 3 audit status (2026-11-07)

| Package | Status | Evidence |
|---|---|---|
| `hw-probe` | READY_FOR_STAGING (arch=any) | AUR 1.6.6-3 maintained; all deps official; source sha256 verified; default probe offline; LGPL-2.1-or-later OR BSD-4-Clause |
| `neofetch` | LEGACY_HOLD | upstream archived; pinned 2020 commit + PGP key; active AUR maintainer; arch=any shell script; `extra/fastfetch` available but not substituted |
| `proton-authenticator` | NEEDS_MANUAL_REVIEW | AUR source tag `proton-authenticator@1.1.6` 404 on GitHub; unbuildable until upstream/AUR fixed |

The historical snapshot in `docs/inventory/omp-package-inventory.csv` and
the audit workbook are preserved unchanged (installed-version snapshots and
review categories are historical records); this page is the current-status
view.
