# Phase 8.3 Batch 5 — GTK themes (2 approved) + 3 deferred

Status: local implementation + validation PASS for two approved candidates.
Remote operations NOT executed — all below require owner approval.

## 1. Candidate audit summary

| Candidate | AUR | Upstream | Version | Architecture | License | Dependencies | Verdict |
|---|---|---|---|---|---|---|---|
| `arc-icon-theme` | arc-icon-theme (bertptrs) | github.com/horst3180/arc-icon-theme | 20161122-4 | any | GPL-3.0 | gtk-update-icon-cache, hicolor-icon-theme | **MANUAL_REVIEW** — PGP-gated source (`validpgpkeys`) that the CI build container cannot verify (key not in keyring; makepkg does not auto-fetch). Same blocker as neofetch in Batch 3. |
| `catppuccin-gtk-theme-frappe` | catppuccin-gtk-theme-frappe (Dvd-Znf) | github.com/catppuccin/gtk (archived) | 1.0.3-1 | any | GPL-3.0 | none | **APPROVED_WITH_CONDITIONS** — upstream archived but release assets + AUR maintained; LICENSE added per repo convention. |
| `catppuccin-gtk-theme-mocha` | catppuccin-gtk-theme-mocha (ameerarsala) | github.com/catppuccin/gtk (archived) | 1.0.3-1 | any | GPL-3.0 | none | **APPROVED_WITH_CONDITIONS** — same as frappe. |
| `maplemono-nf-cn-unhinted` | maplemono-nf-cn-unhinted | github.com/subframe7536/maple-font | 7.9-1 | any | OFL-1.1 | none | **DEFERRED — SPLIT_PACKAGE_UNSUPPORTED** (see §7). |
| `maplemono-nf-unhinted` | maplemono-nf-unhinted | github.com/subframe7536/maple-font | 7.9-1 | any | OFL-1.1 | none | **DEFERRED — SPLIT_PACKAGE_UNSUPPORTED** (see §7). |

## 2. AUR and upstream references

- arc-icon-theme: https://aur.archlinux.org/packages/arc-icon-theme · https://github.com/horst3180/arc-icon-theme
- catppuccin-gtk-theme-frappe: https://aur.archlinux.org/packages/catppuccin-gtk-theme-frappe · https://github.com/catppuccin/gtk
- catppuccin-gtk-theme-mocha: https://aur.archlinux.org/packages/catppuccin-gtk-theme-mocha · https://github.com/catppuccin/gtk
- maplemono pkgbase: https://aur.archlinux.org/packages/maplemono · https://github.com/subframe7536/maple-font

## 3. Source and version evidence

- arc: tarball sha512 `5d0f1417...fdfad1` verified vs upstream; signature by key
  `C57DFF0D28DAAE97` (matches `validpgpkeys=A46FD8E741A2A075898462CDC57DFF0D28DAAE97`).
- catppuccin frappe: all 14 release zips sha256 verified vs AUR (blue `8c79c1e5...34905` … yellow `71c45ed9...1d9e2`).
- catppuccin mocha: all 14 release zips sha256 verified vs AUR (blue `83811051...753bdc` … yellow `2be7cf6f...99df643`).
- maplemono: pkgbase source checksums present in AUR PKGBUILD; not built (deferred).

## 4. License and redistribution analysis

- catppuccin themes: upstream LICENSE is GPL-3.0 (verified byte-identical from
  v1.0.3 tag, sha256 `3972dc97...b36986`). The AUR package does not ship the
  license in the archive; this repository's convention (see
  catppuccin-obs-theme-git, coccoc-browser-stable) ships license files inside
  the package. Added `LICENSE` as a source + installed to
  `/usr/share/licenses/$pkgname`. Themes contain CSS/SVG/PNG assets only,
  redistributable under GPL-3.0.
- arc: GPL-3.0 COPYING present in source tree; redistribution OK (deferred for PGP, not license).
- maplemono: OFL-1.1; fonts redistributable; deferred for split-package unsupported, not license.

## 5. Dependencies and conflicts

- catppuccin themes: no runtime deps; no conflicts/provides; install to `/usr/share/themes`.
- arc: gtk-update-icon-cache + hicolor-icon-theme (both official); no conflicts.
- maplemono: no deps; no conflicts.

## 6. Architecture decisions

All five are architecture-independent (`arch=any`). The x86-64-v4 build
profile is orchestration-only for these; the produced packages declare
`arch = any` — never falsely labeled v4-optimized.

## 7. Security findings

- arc: **PGP keyring gap** — `makepkg` fails with `FAILED (unknown public key
  C57DFF0D28DAAE97)` in the pinned build container because `validpgpkeys` are
  not pre-imported (repo has no bootstrap keyring import; all existing
  `validpgpkeys` packages icu74/linux-nanoka/pacman/scx-manager are unpublished
  or critical). Onboarding arc requires a build-infra change (trusted-key
  import) — out of scope for a package PR; flagged for owner review.
- maplemono: **split-package integration gap** — pkgbase `maplemono` produces
  11 subpackages (+ debug). The pipeline builds all of them from one dir, but
  the meta file is keyed to the dir name (`v4-maplemono-nf-unhinted.meta.json`)
  while the pacman database records `%BASE%=maplemono`, so `validate-release.sh`
  would demand `v4-maplemono.meta.json` and fail. Onboarding the named
  subpackages individually without pipeline changes (dir=pkgbase, meta
  per-base, inventory by base) is not supported. Per owner decision: no
  publishing-architecture modification; both maplemono candidates deferred.

## 8. Package approval decisions

- APPROVED_WITH_CONDITIONS: catppuccin-gtk-theme-frappe, catppuccin-gtk-theme-mocha
  (condition: upstream archived; AUR maintained; LICENSE added per repo convention).
- MANUAL_REVIEW: arc-icon-theme (PGP keyring bootstrap).
- DEFERRED — SPLIT_PACKAGE_UNSUPPORTED: maplemono-nf-cn-unhinted, maplemono-nf-unhinted.

## 9. Implementation details

- Added `catppuccin-gtk-theme-frappe/`: PKGBUILD (AUR-verbatim + LICENSE install),
  `.SRCINFO` (regenerated via `makepkg --printsrcinfo`, byte-identical), `LICENSE`.
- Added `catppuccin-gtk-theme-mocha/`: same.
- `packages.txt`: `# Onboarding batch 5 (GTK themes; staging first)` +
  the two entries (no duplicates).

## 10. Local build results

- catppuccin-gtk-theme-frappe: pipeline build rc=0; archive
  `catppuccin-gtk-theme-frappe-1.0.3-1-any.pkg.tar.zst`; `arch=any`;
  packager metadata correct; LICENSE member present under
  `/usr/share/licenses/`.
- catppuccin-gtk-theme-mocha: same result.
- arc-icon-theme: build fails in container at PGP verification (rc=1, unknown key) — documented.
- maplemono: pipeline builds all 11 subarchives but meta mismatch proven (build rc=0; meta `v4-maplemono-nf-unhinted.meta.json` vs db base `maplemono`) — deferred.

## 11. Validation results

- `makepkg --printsrcinfo` vs `.SRCINFO`: identical for both approved packages.
- Source checksums: all 14+14 zips + LICENSE verified.
- `bash -n` PKGBUILDs: pass. `git diff --check`: pass.
- Full regression suite + container suite: see run records (PASS=59 FAIL=0 etc.).
- Matrix generation (staging + production subset): `["catppuccin-gtk-theme-frappe","catppuccin-gtk-theme-mocha"]` accepted.

## 12. Deferred candidates and blockers

- arc-icon-theme: blocks on PGP keyring bootstrap (build infra change).
- maplemono-*: blocks on first-class split-package support. Future work item:
  pkgbase→subpackage mappings, metadata ownership (per-base `v4-<base>.meta.json`),
  duplicate detection, cache handling, signature generation, database consistency,
  safe publication, and regression tests.

## 13. Expected staging changes

A future signed staging run (`repository-v4-test`) with
`packages=catppuccin-gtk-theme-frappe,catppuccin-gtk-theme-mocha`
adds exactly 2 packages + signatures + db updates. Production grows
27 → 29 after a separately authorized signed production run.

## 14. Known risks and rollback considerations

- Upstream catppuccin/gtk archived: pinned v1.0.3 assets remain downloadable; AUR
  packages maintained. If upstream assets disappear, package pins break — monitor.
- Rollback: remove the two packages.txt lines + dirs in a PR; next staging run
  prunes them. Production untouched until explicit authorization.

## 15. Next steps

1. Owner review this branch & approve PR.
2. After merge: signed staging run; verify assets/signatures/db/health.
3. Then a separate owner-approved production dry-run + signed production run.
4. Separate work item: PGP keyring bootstrap (arc) and split-package support (maplemono).

---

## 16. Replacement (2026-11-08) — catppuccin GTK themes superseded

The two Catppuccin GTK theme packages (`catppuccin-gtk-theme-frappe`,
`catppuccin-gtk-theme-mocha`) were not publishable: signed staging builds
failed because GitHub Release-asset downloads returned repeated HTTP 504
(release CDN outage). They are **superseded** and removed from `packages.txt`
and the repo tree; this audit remains as historical record.

### Replacement selection

| Candidate | Result | Reason |
|---|---|---|
| `bluetuith` | **SELECTED** | git+ tag source (v0.2.7), verified clone; MIT; Go, single archive; official deps (bluez, dbus); LICENSE packaged; matches published Go/git+ precedent (fzf-git). |
| `python-aiohttp-cors` | **SELECTED** | PyPI source (`files.pythonhosted.org`, verified sha256), not GitHub CDN; Apache-2.0; arch=any; single archive; Python 3.14 + aiohttp 3.14.3 verified compatible. |
| `mihomo` | deferred | Source verified + go.mod pinned + `clash-geoip` dep now in-repo; but ships a privileged systemd service (CAP_NET_ADMIN/RAW/BIND_SERVICE) and conflicts/provides `clash-meta` — manual-review profile retained. |
| `noisetorch` | not selected | Viable (git+ + local submodules) but heavier (Go+cmake+C+go generate); bluetuith is simpler and equally safe. |
| `nitrogen` | deferred | Uses `releases/download` (the failing path) + PGP (`validpgpkeys`). |
| `bridge-utils` | rejected | Deprecated; kernel.org mirrors + PGP; no compelling justification. |
| `betterlockscreen` | deferred | i3lock-color AUR-only PAM dependency unchanged. |
| `scc`, `typioca` | deferred | Archive sources returned HTTP 504 during verification. |

### Replacement implementation

- Removed `catppuccin-gtk-theme-frappe/`, `catppuccin-gtk-theme-mocha/`
  and their `packages.txt` entries.
- Added `bluetuith/` (PKGBUILD + .SRCINFO; MIT LICENSE installed from source)
  and `python-aiohttp-cors/` (PKGBUILD + .SRCINFO + LICENSE; Apache-2.0
  LICENSE installed per repo convention).
- `packages.txt`: `# Onboarding batch 5 replacement (reliable sources; staging first)`
  with the two entries.
- Both .SRCINFO byte-identical to `makepkg --printsrcinfo`.
- Real-pipeline pinned-container builds: rc=0 for both (see §10/11).

---

## 17. Final closure — signed production release (2026-11-08)

**Status: PHASE_8_3_BATCH5_REPLACEMENT_COMPLETE**

### Published packages

| Package | Version | Archive | Architecture |
|---|---|---|---|
| `bluetuith` | 1:0.2.7-1 | `bluetuith-1.0.2.7-1-x86_64.pkg.tar.zst` | x86_64 |
| `python-aiohttp-cors` | 0.8.1-1 | `python-aiohttp-cors-0.8.1-1-any.pkg.tar.zst` | any |

### Git / CI evidence

- PR #12 merged into `main`; merge commit `93b0363` (`feat(packages): replace Batch 5 with bluetuith and python-aiohttp-cors (#12)`).
- Three mandatory PR checks (CI Validation static-validation / regression-tests / ci-acceptance): PASS.
- Local regression: 59 PASS / 0 FAIL. Container UID-1001: 61 PASS / 0 FAIL.
- Release safety: 23 PASS / 0 FAIL. CI safety: 45 PASS / 0 FAIL.
- Both pinned-container builds: rc=0, single archive each.
- Cache determinism (fresh → hit → repeat) and corrupted-cache rejection: PASS for both.
- Python import smoke test (clean container, aiohttp 3.14.3, Python 3.14): PASS.

### Staging / Production evidence

- Signed staging (`repository-v4-test`) completed; package + database GPG verification passed.
- Production dry-run passed.
- Signed production (`repository`) completed.
- Final production inventory: **29 archives / 29 detached signatures / 29 v4-*.meta.json**.
- Production database verified: readable; GPG Good signature; signer fingerprint
  `3B9B8E3E5564A77A73B543D049DD327EE8135B62` (EDDSA); 29 unique package identities,
  no duplicates, no orphaned assets; every db entry has a matching published archive.
- `bluetuith` db record: version `1:0.2.7-1`, arch x86_64, filename
  `bluetuith-1.0.2.7-1-x86_64.pkg.tar.zst`, sha256 + PGPSIG present.
- `python-aiohttp-cors` db record: version `0.8.1-1`, arch any, filename
  `python-aiohttp-cors-0.8.1-1-any.pkg.tar.zst`, sha256 + PGPSIG present.
- Production health check (`repo-health.sh`, signed mode): **HEALTHY (rc=0)** —
  checksum/database/metadata/signing status all PASS.
- Limitation: the repository maintains no separate canonical published-inventory list
  independent of the release assets; cross-validation used three independently
  fetched release records (database `%FILENAME%`/`%NAME%`, archive assets, meta
  assets), all 29/29/29 consistent.

### Deferred / superseded

The original Batch 5 GTK candidates `catppuccin-gtk-theme-frappe` and
`catppuccin-gtk-theme-mocha` are superseded and NOT published: their upstream
release assets repeatedly returned HTTP 504 during staging. Historical audit
findings above are preserved for traceability. Do not reintroduce them.

### Next phase

Batch 6 is planning-ready, not implemented: `PHASE_8_4_BATCH6_PLANNING_READY`.
