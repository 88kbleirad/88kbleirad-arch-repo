# Expans — 8 to 12–15 packages

This document records the review-ready expansion plan for the 88kbleirad
binary repository. Nothing in this document has been executed against the
live staging/production releases; deployment requires explicit approval.

## Inventory change (Phase 2 update)

`linux-nanoka` has been removed from `packages.txt` (it was a `local:`
entry). It remains in `critical-packages.sh` so it can never be introduced
accidentally. No other critical entries were changed, and no host system
package was uninstalled.

## Current inventory (8 published)

`all-contributors-cli`, `catppuccin-fcitx5-git`, `catppuccin-whiskers-bin`,
`ksuperkey`, `magika`, `nmtui-go`, `osu-mime`, `physlock`.

## Candidate selection criteria

- must be in `packages.txt` and not already published;
- not in the critical set (`critical-packages.sh`):
  `pacman`, `nvidia-utils`, `lib32-nvidia-utils`, `xlibre-xserver`,
  `xlibre-xserver-src`, `xlibre-input-libinput`, `linux-nanoka`,
  `networkmanager-iwd`;
- small/moderate build complexity, noninteractive, container-safe,
  reproducible, no privileged access, no kernel/EC/security-integration,
  no system-wide preference overrides, no fragile remote sources.

Re-evaluation after the `linux-nanoka` inventory removal: no selected
candidate depended on `linux-nanoka`, and it was already excluded from the
eligible pool by the critical policy. The candidate list below is therefore
unchanged and remains fully eligible.

## Selected (6)

| Package | Source | Version | arch | Dependencies | Build difficulty | Risk |
|---|---|---|---|---|---|---|
| `catppuccin-obs-theme-git` | repo PKGBUILD | `r35.054a297-1` | any | obs-studio | trivial (file copy) | low |
| `snapper-rollback` | repo PKGBUILD | `1.0-1` | any | coreutils, python, btrfs-progs | trivial (script) | low |
| `xclicker` | repo PKGBUILD | `1.5.1-1` | x86_64 | gtk3, libx11/xi/xtst | moderate (C) | low |
| `ripdrag` | repo PKGBUILD | `0.4.13-1` | x86_64 | glibc, gcc-libs, glib2, gdk-pixbuf2, gtk4, pango | moderate (Rust) | low-moderate |
| `xmousepasteblock` | repo PKGBUILD | `1.4-3` | x86_64 | libxi, libx11, libev, libxfixes | low (C) | low |
| `beautyline` | repo PKGBUILD | `2:3.0.5-1` | any | none | trivial | **excluded** — `epoch=2` produces `name-2:ver-rel` filenames that the pipeline’s `:`→`.` rename would corrupt, failing `validate_pkg_file`. Excluded unless the filename handling is generalized. |

Final expected count: 8 + 5 = **13 packages** (beautyline excluded).

## Rejected/other candidates and reasons

| Package | Reason |
|---|---|
| `anpan-git`, `pvpn-go`, `printcraft`, `rate-mirrors`, `paru` | Go/Rust build ok but larger or need patch/features; paru depends on `libalpm`/pacman (critical dependency). |
| `awesome-luajit-git`, `picom-nhktmdzhg-git`, `lightworks` | heavy/WM/compositor/NLE; high complexity, system integration. |
| `msi-ec-dkms-git`, `mcontrolcenter-git` | kernel DKMS / MSI EC hardware integration. |
| `lua-pam-git`, `opendoas-cpp-git` | PAM / doas-sudo security-sensitive system component. |
| `scx-manager`, `serein`, `equicord-openasar`, `zalo-for-linux-git` | kernel-scheduler manager / large native clients; high complexity. |
| `electron22-bin`, `osu-lazer-bin`, `coccoc-browser-stable`, `vscodium`, `rustdesk`, `onlyoffice`, `localsend` | large prebuilt/binary packages; heavy download/build; licensing/size considerations. |
| `ttf-ms-win11-base`, `ttf-vietnamese-tcvn3`, `ttf-vietnamese-vni` | EULA/fonts; ttf-ms-win11-base downloads from Microsoft (network-heavy); dropbox-hosted font tarballs are fragile. |
| `fcitx5-lotus-git`, `luajit-lgi`, `icu74` | multi-package/legacy/ABI-heavy; moderate-high complexity. |
| `omp-bun`, `yuzufox-git`, `rhythmbox-plugin-tray-icon` | bun dependency availability; global Firefox policy override; repackaged .deb reliability. |
| `ventoy` | upstream PKGBUILD explicitly DOES IN PROGRESS, bundled ancient sources, QEMU/libguestfs root usage. |

## Phase C local build results (pinned Arch container)

| Package | Build rc | Archive | .PKGINFO verified |
|---|---|---|---|
| beautyline | 0 | `beautyline-2:3.0.5-1-any.pkg.tar.zst` | yes (`packager = Unknown Packager` as expected pre-gate) |
| catppuccin-obs-theme-git | 0 | `...-r35.054a297-1-any.pkg.tar.zst` | yes |
| snapper-rollback | 0 | `snapper-rollback-1.0-1-any.pkg.tar.zst` | yes |
| xclicker | 0 | `xclicker-1.5.1-1-x86_64.pkg.tar.zst` | yes |
| ripdrag | 0 | `ripdrag-0.4.13-1-x86_64.pkg.tar.zst` | yes |
| xmousepasteblock | 0 | `xmousepasteblock-1.4-3-x86_64.pkg.tar.zst` | yes |

All built with `makepkg --syncdeps --nocheck --force`; runtime deps
installed from official repos. `packager = Unknown Packager` **for the raw
makepkg run** — the production `build-in-docker.sh` bootstrap sets
`PACKAGER` and the gate will enforce it (same as the current 8).

## Staging/production commands (require approval)

Staging (uses `repository-v4-test`; prepare matrix = existing staging + 5
new):

```bash
# GitHub UI or gh CLI:
gh workflow run build-staging.yml -f confirm-production=YES \
  -f packages="catppuccin-obs-theme-git,snapper-rollback,xclicker,ripdrag,xmousepasteblock"
```

Production (8 existing + 5 new; unsigned default):

```bash
gh workflow run build-release.yml -f confirm-production=YES \
  -f packages="all-contributors-cli,catppuccin-fcitx5-git,catppuccin-whiskers-bin,ksuperkey,magika,nmtui-go,osu-mime,physlock,catppuccin-obs-theme-git,snapper-rollback,xclicker,ripdrag,xmousepasteblock"
```

Proceed to production only after staging passes:
`STAGING BUILD PASS / NEW PACKAGES ALL VALID / EXPECTED INVENTORY COMPLETE /
DATABASE CONSISTENCY PASS / REMOTE VERIFICATION PASS / MISSING 0`.

## Expected final state

13 packages; cache: 8 HIT (existing) + 5 REBUILT/MISS on first run, HIT on
subsequent unchanged run; content-aware publish: 8 UNCHANGED packages +
UNCHANGED metadata + NEW archives/metas + CHANGED database (semantic), then
zero mutations on repeat; remote verification PASS.

## Verification on consumer

```bash
pacman -Sy
pacman -Si 88kbleirad/catppuccin-obs-theme-git  # etc.
pacman -S catppuccin-obs-theme-git snapper-rollback xclicker ripdrag xmousepasteblock
# package shown as 88kbleirad // ...
```
