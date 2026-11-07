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
