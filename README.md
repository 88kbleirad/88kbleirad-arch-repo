# 📦 Personal Arch Linux Repository Builder

[🇻🇳 Xem bản tiếng Việt](#-hướng-dẫn-tiếng-việt)

A fully automated, zero-cost Arch Linux binary repository powered entirely by GitHub Actions and GitHub Releases.

This template allows you to maintain a personal `pacman` repository without paying for a VPS or managing a build server. It automatically tracks updates from the Arch User Repository (AUR), builds the packages (including split packages), caches them smartly to save runner memory, and publishes the `.pkg.tar.zst` binaries to a fixed GitHub Release.

---

## 🚀 How to use this repository (For End-Users)

If you just want to install packages that have already been built in this repository, you simply need to add it to your pacman configuration.

### 1. Check CPU compatibility

This repository builds packages inside a generic Arch Linux container with the
CachyOS `x86-64-v4` compiler profile (`-march=x86-64-v4` /
`-C target-cpu=x86-64-v4`).

That means the published binaries are intended for systems that support the `x86-64-v4` instruction set (AVX-512).

Before using this repository, make sure your machine supports `x86-64-v4` or higher. If your CPU only supports `x86-64-v3` or lower, the packages from this repository may not run correctly on your system.

### 2. Edit your `pacman.conf`

Append the following configuration to the bottom of your `/etc/pacman.conf`:

```ini
[88kbleirad]
SigLevel = Required TrustedOnly
Server = https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository
```

The production and staging repositories publish **GPG-signed** packages and
a signed pacman database. `Required` + `TrustedOnly` is the recommended
(enforced) policy: every package and the database must carry a valid
signature from a key you have imported and locally trusted. Before enabling
it, follow the verified-client procedure (export/verify the key, `pacman-key`
import, local trust, signature testing) in
[`docs/pacman-signing.md`](docs/pacman-signing.md). Never trust a key
without verifying its fingerprint out-of-band.

### 3. Sync and Install

Refresh your package databases and install your desired packages just like official Arch packages:

```bash
sudo pacman -Sy
sudo pacman -S <package-name>
```

### 4. Confirm package version and origin

Verify the package comes from this repository (not a copied AUR binary) and check its version:

```bash
pacman -Si 88kbleirad/<package-name>   # shows Repository, Version, Packager
pacman -Q <package-name>                # installed version
pacman -Qi <package-name> | grep -E 'Name|Version|Packager'
# Packager: 88kbleirad <88kbleirad@users.noreply.github.com>
```

### 5. Available GNS3 package trio

The repository ships the GNS3 network-emulator trio (x86-64-v4, signed):

| Package | Version | Description |
|---|---|---|
| `dynamips` | 0.2.25-1 | Cisco router emulator (GPL2) |
| `ubridge` | 1.3.0-1 | UDP/Ethernet/TAP/VMnet bridge (GPL3) |
| `vpcs` | 0.8.5-1 | Virtual PC simulator (BSD) |

```bash
sudo pacman -S dynamips ubridge vpcs
```

## 🛠️ Create Your Own Automated Repo

Want to build your own automated AUR farm? Follow these steps to fork and configure this system.

### Step 1: Fork and Clean

- Fork this repository to your own GitHub account.

### Step 2: Choose the correct Docker container

This repository runs builds on GitHub-hosted runners inside a **generic Arch
Linux container** (`ghcr.io/archlinux/archlinux`), which only needs the
baseline x86-64 ISA; the toolchain inside it targets `x86-64-v4` via the
CachyOS compiler profile (`-march=x86-64-v4` / `-C target-cpu=x86-64-v4`).
The workflow verifies the compiler flags actually target `x86-64-v4`.

If you fork this repository, choose the container that matches your target machines:

- `ghcr.io/archlinux/archlinux` (generic, as used here) for v4 targeting via compiler flags.
- `cachyos/cachyos` for generic builds.
- `cachyos/cachyos-v3` for `x86-64-v3` builds.
- `cachyos/cachyos-v4` for `x86-64-v4` builds (note: the v4 image itself requires AVX-512 and will not start on hosts without it).

If you need a different target level, edit the workflow file `build-release.yml` and replace the container image accordingly.

### Step 3: Choose the correct makepkg profile

Besides the container choice, the workflows also download a CachyOS `makepkg.conf` profile.

CachyOS makepkg profiles include:

- `docker-makepkg` for generic builds.
- `docker-makepkg-v3` for `x86-64-v3` builds.
- `docker-makepkg-v4` for `x86-64-v4` builds.
- `docker-makepkg-znver4` for AMD Zen 4 optimized builds.

In practice, if you want to customize your own fork, review both the container image and the downloaded makepkg profile so they match your intended CPU target. The build workflow refuses to continue if the downloaded profiles do not contain `-march=x86-64-v4` / `target-cpu=x86-64-v4`.

### Step 4: Local packages are supported

This repository also supports local packages that are not synced from the AUR.

In `packages.txt`, use the prefix `local:` for packages that you maintain yourself inside this repository. These entries are skipped by the AUR sync workflow, so you can manually keep and update their `PKGBUILD` files in your repo.

Example:

```txt
paru-bin
local:my-custom-package
```

In this example:

- `paru-bin` will be synced from the AUR.
- `my-custom-package` will be treated as a local package and must be maintained manually by the repository owner.

### Step 5: Configure Repository Permissions

To allow GitHub Actions to build and release packages, you must enable specific workflow permissions:

- Go to your repository Settings > Actions > General.
- Under Workflow permissions, select Read and write permissions.
- Check the box that says Allow GitHub Actions to create and approve pull requests.
- Click Save.

### Step 6: Manage Your Packages

The entire repository is controlled by a single file: `packages.txt`.

- Open `packages.txt`.
- Add the exact names of the AUR packages you want to build (one per line).
- For packages that you maintain manually in this repository, use the `local:` prefix.

  > Note on Split Packages: If a package has multiple sub-packages, just write the base package name. The workflow will automatically discover and build all sub-packages.

- Commit the changes to the `main` branch.

### Step 7: Relax and Let it Run

- The Sync Workflow runs on a schedule and when `packages.txt` changes. It reads `packages.txt`, pulls the latest PKGBUILDs from the AUR, skips `local:` entries, deletes removed packages, and creates a clean Pull Request.
- The Publish Workflow is manual-only until separately approved (`confirm-production=YES`), later optionally via a weekly schedule path gated by a dedicated repository variable. It checks existing assets, reuses cached packages when possible, falls back to previous release files if needed, generates a fresh pacman database, validates archive/database consistency, and uploads everything to the repository Release tag.
- **Signing is enforced in production.** The publish workflow has a
  `signing-mode` input:
  - `signed` (**current production/staging mode**) — strict GPG signing +
    verification of every package and the database; requires the protected
    `package-signing` environment. A signed run never silently downgrades
    to unsigned if signing fails.
  - `unsigned` — no GPG key and no protected environment are required. The
    repository is published unsigned; any leftover detached signatures from
    an earlier signed run are purged so nothing mismatched stays online.
    Unsigned forks should keep clients on `SigLevel = Optional TrustAll`
    (no authentication) until they enable signing.
- Matrix builds are limited to **2 concurrent jobs** (`max-parallel: 2`).
- Caching is architecture-aware: each package carries a `v4-<pkg>.meta.json` metadata file (profile + fingerprint of the `PKGBUILD` and compiler config). A cached package is reused only when the profile matches the current build target and the fingerprint matches; `x86-64-v3`-era binaries are never reused for `x86-64-v4` builds.

**Disclaimer:** The production repository runs in **signed mode** — every
package and the database are GPG-signed and the recommended client policy is
`SigLevel = Required TrustedOnly` (see `docs/pacman-signing.md`). Only use
this repository if you trust the operator; verify the key fingerprint
out-of-band before trusting it:

```
3B9B8E3E5564A77A73B543D049DD327EE8135B62
```

### Step 8: Publish packages manually

The exact dispatch command (replace the package list as needed):

```bash
gh workflow run build-release.yml \
  --repo 88kbleirad/88kbleirad-arch-repo \
  -f confirm-production=YES \
  -f packages="nmtui-go,osu-mime,ksuperkey" \
  -f signing-mode=signed
```

Leave `packages` empty to build the **full** `packages.txt` matrix (minus system-critical packages). Add `-f allow-critical=<name>` to include an individual system-critical package by exact name.

### Step 9: Verify the published database

```bash
curl -fLO https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository/88kbleirad.db.tar.gz
tar -tzf 88kbleirad.db.tar.gz | sed 's|^|  |'
# each directory is a package present in the repository database
```

Or, with the repository configured in `pacman.conf`:

```bash
sudo pacman -Sy
pacman -Sl 88kbleirad   # list every package the database provides
```

### Step 10: Signed publishing (active)

The production release is published **signed** (`signing-mode=signed`):

- Every package archive (`*.pkg.tar.zst`) has a detached `*.sig`.
- Both database files (`88kbleirad.db.tar.gz`, `88kbleirad.files.tar.gz`)
  are signed; pacman fetches the plain `88kbleirad.db.sig` /
  `.files.sig` aliases.
- The public key `88kbleirad.pub.asc` is published on every signed release.
- Fork setup: create a dedicated ed25519 sign-only key and add it to the
  protected `package-signing` environment as `GPG_PRIVATE_KEY` (+ optional
  `GPG_PASSPHRASE`) — see `docs/operator-signing.md`; then publish with
  `-f signing-mode=signed` and point clients at
  `SigLevel = Required TrustedOnly`. (This repository already uses the
  same key for staging and production; see `docs/pacman-signing.md`.)

### Step 11: Prepare weekly scheduled builds (disabled)

The cron entry in `build-release.yml` stays commented out. To enable it,
in a separately approved PR: uncomment the `schedule:` block **and** set
the repository variable `ALLOW_SCHEDULED_PRODUCTION=yes`. Scheduled runs
have no inputs, always publish unsigned, never include system-critical
packages, and keep publication non-destructive.

---

## 🇻🇳 Hướng dẫn tiếng Việt

Kho gói nhị phân Arch Linux cá nhân này được tự động hóa hoàn toàn, không tốn chi phí máy chủ riêng, và hoạt động bằng GitHub Actions kết hợp GitHub Releases.

Template này cho phép bạn duy trì một kho `pacman` cá nhân mà không cần thuê VPS hoặc tự quản lý build server. Hệ thống sẽ tự theo dõi cập nhật từ AUR, build gói (bao gồm cả split packages), dùng cache hợp lý để tiết kiệm tài nguyên runner, rồi phát hành file `.pkg.tar.zst` lên một GitHub Release cố định.

### 🚀 Cách dùng repository này (dành cho người dùng cuối)

Nếu bạn chỉ muốn cài các gói đã được build sẵn từ repository này, bạn chỉ cần thêm repo vào cấu hình `pacman`.

#### 1. Kiểm tra khả năng tương thích CPU

Repository này build package bên trong container Arch Linux generic với compiler profile `x86-64-v4` của CachyOS (`-march=x86-64-v4` / `-C target-cpu=x86-64-v4`).

Điều đó có nghĩa là các gói nhị phân được phát hành được nhắm tới các máy hỗ trợ tập lệnh `x86-64-v4` (AVX-512).

Trước khi dùng repository này, hãy chắc chắn rằng máy của bạn hỗ trợ `x86-64-v4` hoặc cao hơn. Nếu CPU của bạn chỉ hỗ trợ mức `x86-64-v3` hoặc thấp hơn, các gói từ repository này có thể không chạy đúng trên hệ thống của bạn.

#### 2. Chỉnh sửa `pacman.conf`

Thêm đoạn cấu hình sau vào cuối file `/etc/pacman.conf`:

```ini
[88kbleirad]
SigLevel = Required TrustedOnly
Server = https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository
```

Repository production và staging phát hành gói **có chữ ký GPG** và cơ sở
dữ liệu pacman có chữ ký. `Required` + `TrustedOnly` là chính sách khuyến
nghị: mọi gói và database phải có chữ ký hợp lệ từ key mà bạn đã nhập và
tin tưởng cục bộ. Trước khi bật, hãy thực hiện đầy đủ quy trình xác minh
key (tải key, kiểm tra fingerprint, `pacman-key --add` + `--lsign-key`,
kiểm tra chữ ký) trong `docs/pacman-signing.md`. Không bao giờ tin tưởng
key mà chưa xác minh fingerprint qua kênh bên ngoài:

```
3B9B8E3E5564A77A73B543D049DD327EE8135B62
```

#### 3. Đồng bộ và cài đặt

Làm mới cơ sở dữ liệu gói rồi cài gói bạn muốn giống như gói chính thức của Arch:

```bash
sudo pacman -Sy
sudo pacman -S <package-name>
```

### 🛠️ Tạo repository tự động của riêng bạn

Nếu bạn muốn tự dựng một hệ thống build AUR tự động cho tài khoản của mình, hãy làm theo các bước sau.

#### Bước 1: Fork và dọn dẹp

- Fork repository này về tài khoản GitHub của bạn.

#### Bước 2: Chọn Docker container phù hợp

Repository này chạy build trên GitHub-hosted runner bên trong **container Arch Linux generic** (`ghcr.io/archlinux/archlinux`) chỉ cần baseline x86-64 ISA; toolchain bên trong nhắm `x86-64-v4` qua compiler profile CachyOS, và workflow xác minh cờ compiler thực sự nhắm `x86-64-v4`.

Nếu bạn fork repository này, hãy chọn container phù hợp với máy đích của bạn:

- `ghcr.io/archlinux/archlinux` (generic, như repo này) để nhắm v4 qua cờ compiler.
- `cachyos/cachyos` cho build generic.
- `cachyos/cachyos-v3` cho build `x86-64-v3`.
- `cachyos/cachyos-v4` cho build `x86-64-v4` (lưu ý: image v4 tự nó yêu cầu AVX-512 và sẽ không khởi động được trên máy thiếu nó).

Nếu bạn muốn đổi target, hãy sửa file workflow `build-release.yml`, rồi thay container image tương ứng.

#### Bước 3: Chọn makepkg profile phù hợp

Ngoài việc chọn container, workflow còn tải một profile `makepkg.conf` của CachyOS.

Các profile makepkg của CachyOS gồm có:

- `docker-makepkg` cho build generic.
- `docker-makepkg-v3` cho build `x86-64-v3`.
- `docker-makepkg-v4` cho build `x86-64-v4`.
- `docker-makepkg-znver4` cho build tối ưu cho AMD Zen 4.

Trên thực tế, nếu bạn muốn tùy biến fork của mình, hãy kiểm tra cả container image lẫn makepkg profile được tải về để chúng khớp với CPU target bạn muốn.

#### Bước 4: Hỗ trợ gói local không sync từ AUR

Repository này cũng hỗ trợ các gói local không cần đồng bộ từ AUR.

Trong `packages.txt`, hãy dùng tiền tố `local:` cho các gói mà bạn tự maintain trong repository này. Các dòng đó sẽ bị bỏ qua trong workflow sync AUR, nên bạn có thể tự quản lý và tự cập nhật `PKGBUILD` của chúng trong repo.

Ví dụ:

```txt
paru-bin
local:my-custom-package
```

Trong ví dụ trên:

- `paru-bin` sẽ được sync từ AUR.
- `my-custom-package` sẽ được xem là gói local và chủ repository phải tự maintain thủ công.

#### Bước 5: Cấu hình quyền cho repository

Để GitHub Actions có thể build và phát hành gói, bạn cần bật đúng quyền cho workflow:

- Vào `Settings > Actions > General` của repository.
- Trong phần **Workflow permissions**, chọn **Read and write permissions**.
- Tích vào ô **Allow GitHub Actions to create and approve pull requests**.
- Nhấn **Save**.

#### Bước 6: Quản lý danh sách gói

Toàn bộ repository này được điều khiển bởi một file duy nhất là `packages.txt`.

- Mở file `packages.txt`.
- Thêm đúng tên các gói AUR mà bạn muốn build, mỗi dòng một gói.
- Với các gói bạn tự maintain trong repo, hãy dùng tiền tố `local:`.

  > Lưu ý về Split Packages: Nếu một gói có nhiều gói con, bạn chỉ cần ghi tên gói gốc. Workflow sẽ tự phát hiện và build toàn bộ các gói con liên quan.

- Commit thay đổi vào branch `main`.

#### Bước 7: Để hệ thống tự chạy

- **Sync Workflow** chạy theo lịch và khi `packages.txt` thay đổi. Workflow này đọc `packages.txt`, kéo PKGBUILD mới nhất từ AUR, bỏ qua các dòng `local:`, xóa các gói đã bị loại bỏ, rồi tạo một Pull Request sạch.
- **Publish Workflow** chỉ chạy tay cho tới khi được phê duyệt riêng (`confirm-production=YES`), sau đó có thể qua đường lịch tuần được kiểm soát bởi biến repository riêng. Workflow này kiểm tra asset hiện có, tận dụng cache nếu có thể, fallback về file từ release trước nếu cần, tạo lại pacman database mới, xác thực tính toàn vẹn của archive/database, rồi upload toàn bộ lên Release tag của repository. **Ký GPG là bắt buộc tại production hiện tại**: chế độ `signing-mode=signed` ký và xác thực mọi chữ ký; chế độ `signing-mode=unsigned` (dành cho fork chưa bật ký) không cần key và sẽ dọn các chữ ký cũ, không bao giờ tự hạ cấp xuống unsigned nếu việc ký thất bại.

**Lưu ý:** Repository production hiện đang chạy **chế độ ký** (`signing-mode=signed`) — mọi gói và database đều có chữ ký GPG, và chính sách khuyến nghị cho client là `SigLevel = Required TrustedOnly` (xem `docs/pacman-signing.md`). Chỉ dùng repository này khi bạn tin tưởng người vận hành và đã xác minh fingerprint key qua kênh bên ngoài (`3B9B8E3E5564A77A73B543D049DD327EE8135B62`).
