# Phase 7 — Remaining onboarding roadmap (multi-batch)

Generated 2026-11-07 from `docs/inventory/omp-package-inventory.csv` (54 rows),
`packages.txt` (58 configured), production release inventory (23 published), and
live AUR/official metadata. Non-overlapping; every inventory entry assigned
exactly one status.

## Legend

- **Published** — in production release (23 full repo; 3 from inventory).
- **Configured-pending** — in packages.txt, not yet published.
- **Batch N candidate** — buildable now, planned batch.
- **Defer-noarch** — data/theme/font-only, no v4 value; lowest priority.
- **Defer-heavy** — large dependency/network-heavy builds.
- **Defer-review** — small native/script pkgs needing a final source review.
- **Blocked-dep** — AUR-only dependency must be onboarded first.
- **Exclude-*** — protected (critical), variant conflict, binary redistribution
  review, dependency/system hold, legacy/security, or special review.

## Status counts (54 unique)

| Status | Count |
|---|---|
| Published (inventory∩prod) | 3 |
| Configured-pending | 1 |
| Batch 2 candidate | 2 |
| Defer-noarch | 6 |
| Defer-heavy | 2 |
| Defer-review | 3 |
| Blocked-dep | 2 |
| Exclude-variant | 2 |
| Exclude-binary-redist | 11 |
| Exclude-dep-hold | 16 |
| Exclude-legacy/security | 3 |
| Exclude-special-review | 2 |
| Blocked-critical | 1 |
| **Total** | **54** |

## Batch plan

- Batch 2: fzf-git, swaync-git (currently being validated).
- Batch 3 (small native/script, low risk): hw-probe, neofetch,
  proton-authenticator (all official deps; noarch-ish; verify licenses).
- Batch 4 (blocked-dep resolution): betterlockscreen needs i3lock-color;
  mihomo needs clash-geoip (noarch data pkg). Onboard deps in a
  dependency-first batch, then the consumers.
- Batch 5 (noarch): arc-icon-theme, catppuccin-gtk-theme-{frappe,mocha},
  maplemono-nf-{cn-,}unhinted, clash-geoip (if not already in Batch 4).
- Deferred: open-webui, vikunja (heavy web/Go+frontend), equicord-openasar
  (configured-pending, needs its own validation run).
- Never: all Exclude-* buckets (documented above).

## Identified build blockers (evidence)

1. swaync-git PKGBUILD calls `arch-meson` — not in official, AUR, or
   CachyOS. Dependency gate passes (makedepends are official) but build()
   will fail with `arch-meson: command not found` unless patched.
2. fzf-git conflicts/provides `fzf` — official Arch has `extra/fzf`
   (0.74.5). On a machine with official fzf installed, `pacman -S
   fzf-git` would replace it (conflict resolution). This is a deliberate
   choice (VCS variant) and is fine for this repo's matrix, but the
   README should note the conflict.
3. fzf-git epoch=2: handled by the generalized epoch filename machinery.
4. swaync-git depends on gtk4-layer-shell>=1.0.4 (official 1.3.0), and
   provides notification-daemon — may conflict with other
   notification-daemon providers on the target machine; no repo-internal
   conflict.
