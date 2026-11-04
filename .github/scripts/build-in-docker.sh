#!/usr/bin/env bash
#
# Build a package *targeting* x86-64-v4 inside a generic Arch Linux
# container (ghcr.io/archlinux/archlinux), which itself only requires the
# x86-64 baseline ISA and therefore runs on any GitHub-hosted ubuntu-24.04
# runner.
#
# Why not the CachyOS v4 image: its system libraries/binaries are compiled
# with -march=x86-64-v4 (AVX-512 required, see ELF GNU property notes in
# libc.so.6/bash). On hosted runners without AVX-512 every process dies
# with SIGILL (container exit 132). The generic Arch image has no such
# requirement, so host execution is always safe; we *target* v4 with the
# toolchain flags instead of *executing* v4 system code.
#
# Lifecycle is explicitly managed (create/start/probe/bootstrap/build),
# with phase diagnostics, corpse capture, bounded retries, and build exit
# code propagation — identical to previous versions, minus the CPU gate
# (host CPU is now audited, not required).
#
# Environment:
#   PKG                  - repository directory / base package name (matrix entry)
#   RELEASE_TAG          - GitHub release tag holding the repository assets
#   REPO_DB_NAME         - pacman repository database name
#   GH_TOKEN             - GitHub token for gh CLI (passed to exec only)
#   GITHUB_REPOSITORY    - owner/repo (REQUIRED for gh calls)
#   GITHUB_WORKSPACE     - workspace root (mounted at the same path)
#   BUILD_PROFILE        - architecture profile, default "x86-64-v4"
#   IMAGE                - container image (default ghcr.io/archlinux/archlinux:latest)
#   MAX_BOOT_ATTEMPTS    - boot retries (default 3)
#   PID1_MODE            - PID 1 command: "tail" (default) or "sleep"
#   MAKEPKG_PACKAGER_EMAIL - public contact email for PACKAGER metadata
#                       (default: 88kbleirad@users.noreply.github.com);
#                       the packager name is "88kbleirad"

set -uo pipefail

PKG="${PKG:?PKG is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
WS="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
IMAGE="${IMAGE:-ghcr.io/archlinux/archlinux@sha256:644576e90a71df3b137df2ab6b3517ecd045418195c1946c2c11d1c0564a7981}"
MAX_BOOT_ATTEMPTS="${MAX_BOOT_ATTEMPTS:-3}"
PID1_MODE="${PID1_MODE:-tail}"
BUILD_PROFILE="${BUILD_PROFILE:-x86-64-v4}"
MAKEPKG_PACKAGER_EMAIL="${MAKEPKG_PACKAGER_EMAIL:-88kbleirad@users.noreply.github.com}"

CID=""
SUMMARY_FILE="$WS/.step-summary-$PKG.md"
RUNNER_INFO="$WS/output/v4-runner-info-$PKG.json"
rm -f "$SUMMARY_FILE" "$WS/output/v4-runner-info-$PKG.json"

die() { echo "::error::[$PKG] $*" >&2; exit 1; }
phase() { echo "[$PKG] [phase=$1] $2"; }

cleanup() { [[ -n "$CID" ]] && docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# -- host audit (record, don't gate) ---------------------------------------
# We deliberately do NOT require AVX-512 on the host: generic Arch tools
# only need the baseline ISA. We record CPU/compiler facts for the run
# report, and verify the toolchain can *target* v4.

cpu_flags() {
  local src="${CPUINFO_FILE:-/proc/cpuinfo}"
  awk -F: '/^flags/{print $2; exit}' "$src" 2>/dev/null || true
}

host_cpu_model() {
  awk -F: '/^model name/{print $2; exit}' "${CPUINFO_FILE:-/proc/cpuinfo}" 2>/dev/null | sed 's/^ *//'
}

# -- diagnostics ------------------------------------------------------------

docker_ctx() {
  phase diag "docker client: $(docker version --format '{{.Client.Version}}' 2>/dev/null || echo unavailable)"
  phase diag "docker server: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)"
  phase diag "docker server api: $(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo unavailable)"
  phase diag "storage driver: $(docker info --format '{{.Driver}}' 2>/dev/null || echo unavailable)"
}

# Capture corpse diagnostics before removal. Never prints env/token values.
collect_diagnostics() {
  local why="$1"
  echo "::warning::[$PKG] ${why}; capturing container diagnostics before removal"
  {
    echo "--- host CPU ---"
    echo "model: $(host_cpu_model)"
    echo "flags: $(cpu_flags | tr ' ' '\n' | grep -E 'avx|bmi|fma|movbe' | tr '\n' ' ')"
  } | sed 's/^/  /'
  if [[ -n "$CID" ]]; then
    {
      echo "--- docker inspect state ---"
      docker inspect -f \
        'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} error={{.State.Error}}' \
        "$CID" 2>&1 || true
      echo "--- docker ps ---"
      docker ps -a --filter "id=$CID" --no-trunc --format '{{.ID}} {{.State}} {{.Status}}' 2>&1 || true
      echo "--- docker logs (last 40) ---"
      docker logs "$CID" 2>&1 | tail -40 || true
    } | sed 's/^/  /'
  fi
}

# -- lifecycle --------------------------------------------------------------

pid1_cmd() {
  case "$PID1_MODE" in
    sleep) printf '%s\n' "sh" "-c" "trap '' INT TERM; while :; do sleep 60; done" ;;
    *)     printf '%s\n' "tail" "-f" "/dev/null" ;;
  esac
}

create_container() {
  local rc
  local -a PID1_ARGS=()
  while IFS= read -r a; do PID1_ARGS+=("$a"); done < <(pid1_cmd)
  docker create \
    -e GITHUB_WORKSPACE="$WS" \
    -e EXTRA_REPO="${EXTRA_REPO:-}" \
    --mount type=bind,source="$WS",target="$WS" \
    --workdir "$WS" \
    --entrypoint "${PID1_ARGS[0]}" \
    "$IMAGE" "${PID1_ARGS[@]:1}" \
    > /tmp/container-id.$$ 2>/tmp/container-create.err.$$
  rc=$?
  if [[ $rc -ne 0 ]]; then
    phase create "docker create failed rc=$rc"; cat /tmp/container-create.err.$$ >&2
    return 1
  fi
  CID=$(cat /tmp/container-id.$$)
  rm -f /tmp/container-id.$$ /tmp/container-create.err.$$
  phase create "docker create ok id=${CID:0:12}"
}

start_stable() {
  local rc i
  phase start "docker start ${CID:0:12}"
  docker start "$CID" >/dev/null 2>/tmp/container-start.err.$$
  rc=$?
  if [[ $rc -ne 0 ]]; then
    phase start "docker start failed rc=$rc"; cat /tmp/container-start.err.$$ >&2
    return 1
  fi
  rm -f /tmp/container-start.err.$$
  for i in 1 2 3; do
    docker exec "$CID" sh -c 'test -x /usr/bin/pacman' >/dev/null 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
      phase probe "probe $i/3 failed rc=$rc (container died shortly after start?)"
      return 1
    fi
    phase probe "probe $i/3 ok"
    if [[ $i -lt 3 ]]; then
      sleep 1
    fi
  done
  return 0
}

bootstrap_container() {
  # Generic Arch container: install build tooling (baseline ISA only),
  # create the builder user, then apply the CachyOS v4 *compiler profile*
  # (text config; the compiler itself remains a generic-x86_64 binary).
  local rc
  docker exec -i -e MAKEPKG_PACKAGER_EMAIL="$MAKEPKG_PACKAGER_EMAIL" "$CID" bash -s <<'EOS'
set -euo pipefail

# pacman network sandbox isolation may be unsupported in some container
# environments; disable it when the [options] section exists.
if grep -q '^\[options\]$' /etc/pacman.conf; then
  tmp=$(mktemp)
  awk '
    BEGIN { inserted=0 }
    /^\[options\]$/ && !inserted { print; print "DisableSandboxNetwork"; inserted=1; next }
    { print }
    END { if (!inserted) exit 1 }
  ' /etc/pacman.conf > "$tmp"
  cat "$tmp" > /etc/pacman.conf
  rm -f "$tmp"
fi

# Optional additional pacman repository (e.g. the repository itself, so
# inter-package dependencies resolve during syncdeps). Format:
#   name|url
# Example: EXTRA_REPO="88kbleirad|https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository"
if [[ -n "${EXTRA_REPO:-}" ]]; then
  repo_name="${EXTRA_REPO%%|*}"
  repo_url="${EXTRA_REPO#*|}"
  if [[ -z "$repo_name" || -z "$repo_url" || "$repo_name" == "$EXTRA_REPO" ]]; then
    echo "::error::EXTRA_REPO must be 'name|url'"
    exit 1
  fi
  printf '\n[%s]\nSigLevel = Optional TrustAll\nServer = %s\n' "$repo_name" "$repo_url" >> /etc/pacman.conf
fi

pacman -Syu --noconfirm --needed \
  base-devel git subversion mercurial sudo rsync github-cli fakeroot \
  binutils pacman-contrib curl awk tar jq rustup

id builder >/dev/null 2>&1 || useradd -m builder
grep -q '^builder ALL=(ALL) NOPASSWD: ALL$' /etc/sudoers \
  || echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Target architecture = x86-64-v4 (host remains generic x86-64).
curl -fSL --retry 3 -o /etc/makepkg.conf \
  https://raw.githubusercontent.com/CachyOS/docker-makepkg/refs/heads/master/docker-makepkg-v4/makepkg.conf
mkdir -p /etc/makepkg.conf.d
curl -fSL --retry 3 -o /etc/makepkg.conf.d/rust.conf \
  https://raw.githubusercontent.com/CachyOS/docker-makepkg/refs/heads/master/docker-makepkg-v4/rust.conf

if ! grep -q -- '-march=x86-64-v4' /etc/makepkg.conf; then
  echo "::error::v4 makepkg.conf does not contain -march=x86-64-v4"
  exit 1
fi
if ! grep -q -- 'target-cpu=x86-64-v4' /etc/makepkg.conf.d/rust.conf; then
  echo "::error::v4 rust.conf does not contain target-cpu=x86-64-v4"
  exit 1
fi
echo "Confirmed x86-64-v4 target flags."

sed -i 's/^PKGDEST=/#PKGDEST=/g' /etc/makepkg.conf
sed -i 's/^LOGDEST=/#LOGDEST=/g' /etc/makepkg.conf
# Packager metadata: set a deterministic, public-only identity. The name
# and email land in every .PKGINFO as `packager = ...`. The email is a
# public noreply address — never a personal one — and is configurable via
# MAKEPKG_PACKAGER_EMAIL for forks.
sed -i "s|^#PACKAGER=\"\"|PACKAGER=\"88kbleirad <$MAKEPKG_PACKAGER_EMAIL>\"|" /etc/makepkg.conf
if ! grep -q "^PACKAGER=\"88kbleirad <" /etc/makepkg.conf; then
  printf 'PACKAGER="88kbleirad <%s>"\n' "$MAKEPKG_PACKAGER_EMAIL" >> /etc/makepkg.conf
fi
echo "PACKAGER is set to: $(grep '^PACKAGER=' /etc/makepkg.conf)"
# PACKAGECARCH is a CachyOS makepkg fork extension; upstream makepkg
# (7.1) ignores it and emits standard CARCH (x86_64/any) package metadata.
# Neutralize it so a custom arch is never relied upon: v4 targeting comes
# purely from -march/-C target-cpu, not from a custom arch label.
sed -i 's/^PACKAGECARCH=/#PACKAGECARCH=/g' /etc/makepkg.conf
# Belt-and-braces: refuse a custom PACKAGECARCH if the config still sets it.
if grep -q '^PACKAGECARCH=x86_64_v4' /etc/makepkg.conf; then
  echo "::error::PACKAGECARCH would mask standard arch metadata; aborting"
  exit 1
fi

rustup default stable
sudo -u builder rustup default stable

# RUSTC_WRAPPER: keep `-C target-cpu=x86-64-v4` (the v4 Rust profile) on
# the FINAL artifacts only. Cargo compiles and executes build scripts and
# proc-macros on the HOST; GitHub-hosted ubuntu-24.04 runners have no
# AVX-512, so a v4-compiled build script SIGILLs (observed: magika's
# openssl-sys build script -> signal 4). The wrapper strips target-cpu
# only for host-executed crates, so published binaries stay v4 while the
# build runs safely on any baseline x86-64 host.
#
# The wrapper must reach cargo even when the build runs under
# `sudo -u builder bash -lc ...` (sudo strips the docker-exec environment).
# Exporting from /etc/profile.d makes every login shell — including the
# builder's — pick it up; the docker-exec env below is a belt-and-braces
# for non-login invocations.
install -Dm755 "$GITHUB_WORKSPACE/.github/scripts/rustc-v4-safe.sh" /usr/local/bin/rustc-v4-safe
printf 'export RUSTC_WRAPPER=/usr/local/bin/rustc-v4-safe\n' > /etc/profile.d/rustc-wrapper.sh
echo "RUSTC_WRAPPER is set to: /usr/local/bin/rustc-v4-safe (profile.d + exec env)"

# Verify the toolchain can target v4 (this is a compile-target check, not
# a runtime requirement). Use files, never stdin: this script's stdin is
# the bootstrap heredoc.
echo 'int main(void){return 0;}' > /tmp/v4probe.c
echo "--- gcc target check:"
if gcc -march=x86-64-v4 /tmp/v4probe.c -o /tmp/v4probe 2>&1; then
  echo "gcc -march=x86-64-v4 compiles OK (binary carries target ISA only;"
  echo "it is not executed on this host)."
else
  echo "::error::gcc cannot target x86-64-v4 on this container"
  rm -f /tmp/v4probe.c
  exit 1
fi
rm -f /tmp/v4probe.c /tmp/v4probe

echo "--- rustc target check:"
printf 'fn main(){}\n' > /tmp/v4probe.rs
if rustc -C target-cpu=x86-64-v4 /tmp/v4probe.rs -o /tmp/v4probe-rs 2>&1; then
  echo "rustc -C target-cpu=x86-64-v4 compiles OK (target-only; not executed)."
else
  echo "::error::rustc cannot target x86-64-v4 on this container"
  rm -f /tmp/v4probe.rs
  exit 1
fi
rm -f /tmp/v4probe.rs /tmp/v4probe-rs
EOS
  rc=$?

  if [[ $rc -ne 0 ]]; then
    phase bootstrap "docker exec bootstrap failed rc=$rc"
    return 1
  fi

  docker exec "$CID" chown -R builder:builder "$WS" || {
    phase bootstrap "chown failed rc=$?"
    return 1
  }
}

# -- main -------------------------------------------------------------------

phase info "host CPU (recorded, not required): $(host_cpu_model)"
phase info "host CPU v4 flags present: $(cpu_flags | tr ' ' '\n' | grep -c '^avx512')"

docker_ctx
phase info "image=$IMAGE (generic Arch, baseline ISA host) pid1=$PID1_MODE attempts=$MAX_BOOT_ATTEMPTS"

boot_rc=1
for attempt in $(seq 1 "$MAX_BOOT_ATTEMPTS"); do
  [[ -n "$CID" ]] && { docker rm -f "$CID" >/dev/null 2>&1 || true; CID=""; }

  if create_container && start_stable && bootstrap_container; then
    phase info "container ready on attempt $attempt/$MAX_BOOT_ATTEMPTS (id=${CID:0:12})"
    boot_rc=0
    break
  fi

  collect_diagnostics "attempt $attempt/$MAX_BOOT_ATTEMPTS failed"
  if [[ "$attempt" -lt "$MAX_BOOT_ATTEMPTS" ]]; then
    backoff=$(( attempt * 3 ))
    phase info "retrying in ${backoff}s"
    sleep "$backoff"
  fi
done

if [[ $boot_rc -ne 0 ]]; then
  die "container could not be brought to a healthy state after $MAX_BOOT_ATTEMPTS attempts"
fi

# Run the build. Explicit env propagation into the exec'ed process.
set -o pipefail
# Pass GH_TOKEN via env inheritance (`-e NAME`), never as argv, so the
# token value does not appear in the host process list.
docker exec \
  -e GH_TOKEN \
  -e GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
  -e RELEASE_TAG="$RELEASE_TAG" \
  -e REPO_DB_NAME="$REPO_DB_NAME" \
  -e BUILD_PROFILE="$BUILD_PROFILE" \
  -e PKG="$PKG" \
  -e GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
  -e RUSTC_WRAPPER=/usr/local/bin/rustc-v4-safe \
  "$CID" bash "$WS/.github/scripts/build-package.sh"
build_rc=$?

if [[ $build_rc -ne 0 ]]; then
  collect_diagnostics "build script exited rc=$build_rc"
  [[ -s "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" > "$GITHUB_STEP_SUMMARY"
  exit "$build_rc"
fi

# Restore workspace ownership to the HOST user before any host-side write.
# The container builds as `builder` and bootstrap chowns the workspace to
# builder; without returning ownership to the host uid/gid, host-side
# writes (runner-info JSON, step summary, later git checkout cleanup) fail
# with Permission denied. The workspace is bind-mounted, so chown inside
# the container is the correct fix (no unrestricted-permission workaround).
if docker exec "$CID" chown -R "$(id -u):$(id -g)" "$WS" >/dev/null 2>&1; then
  phase info "restored workspace ownership to host uid $(id -u):$(id -g)"
else
  phase info "warning: could not restore workspace ownership; host-side writes may fail"
fi

# Record host/toolchain facts for the run (compiled outside the container).
mkdir -p "$WS/output"
{
  printf '{\n'
  printf '  "package": %s,\n' "$(printf '%s' "$PKG" | jq -R .)"
  printf '  "profile": %s,\n' "$(printf '%s' "$BUILD_PROFILE" | jq -R .)"
  printf '  "build_image": %s,\n' "$(printf '%s' "$IMAGE" | jq -R .)"
  printf '  "host": {\n'
  printf '    "cpu": %s,\n' "$(printf '%s' "$(host_cpu_model)" | jq -R .)"
  printf '    "avx512_flags": %s\n' "$(cpu_flags | tr ' ' '\n' | grep '^avx512' | tr '\n' ' ' | jq -R .)"
  printf '  },\n'
  printf '  "target": {\n'
  printf '    "cflags": "-march=x86-64-v4",\n'
  printf '    "rustflags": "-C target-cpu=x86-64-v4",\n'
  printf '    "note": "compile-target verified; runtime ISA of produced ELF binaries is NOT guaranteed by this metadata"\n'
  printf '  }\n'
  printf '}\n'
} > "$RUNNER_INFO" 2>/dev/null || true

# Post-build package ISA audit: scan every ELF member of the produced
# package for x86-64-v4 requirement (GNU property notes) and for EVEX
# (AVX-512) instructions. This flags upstream/prebuilt v4-only binaries
# embedded in a package (e.g. nmtui-go ships a prebuilt Go binary whose
# ISA the PKGBUILD does not control). It is an informational report, not
# a gate -- the package may intentionally contain v4 binaries (that is the
# repository's purpose), and static EVEX counts can over-report due to
# data/padding false positives. See .github/scripts/audit-package-isa.sh.
if command -v bash >/dev/null 2>&1 && [[ -f "$WS/.github/scripts/audit-package-isa.sh" ]]; then
  docker exec "$CID" bash "$WS/.github/scripts/audit-package-isa.sh" "$WS/output" "$PKG" || true
fi

[[ -s "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" > "$GITHUB_STEP_SUMMARY"
phase info "container final state: $(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}})' "$CID")"

docker rm -f "$CID" >/dev/null 2>&1
CID=""

# ---------------------------------------------------------------------------
# Artifact gate (fail closed): a successful build job MUST produce at
# least one actual, valid package archive matching the expected package
# name/version/architecture. Metadata-only outputs (status-failed +
# v4-*.meta.json, runner info, logs) are NOT valid artifacts. The build
# job already exits nonzero on un-recovered failures (build-package.sh),
# so reaching this point means the build/restore succeeded — but we still
# verify the archive exists, is readable, carries .PKGINFO, and is not a
# tiny metadata-only artifact before the artifact is uploaded.
# ---------------------------------------------------------------------------
VALID_ARCHIVE=""
# pick a usable archive reader: bsdtar (libarchive) or GNU tar with zstd.
# The host runner (Ubuntu) may lack bsdtar, so fall back to tar --zstd.
_arch_ok() { # file
  local f="$1"
  if command -v bsdtar >/dev/null 2>&1 && bsdtar --version >/dev/null 2>&1; then
    bsdtar -tf "$f" >/dev/null 2>&1
  elif tar --zstd --version >/dev/null 2>&1; then
    tar --zstd -tf "$f" >/dev/null 2>&1
  else
    return 1
  fi
}
_arch_pkginfo() { # file
  local f="$1"
  if command -v bsdtar >/dev/null 2>&1 && bsdtar --version >/dev/null 2>&1; then
    bsdtar -xOf "$f" .PKGINFO 2>/dev/null
  else
    tar --zstd -xOf "$f" .PKGINFO 2>/dev/null
  fi
}
shopt -s nullglob
for cand in "$WS/output"/*.pkg.tar.zst; do
  [[ -s "$cand" ]] || continue
  _arch_ok "$cand" || continue
  info="$(_arch_pkginfo "$cand")"
  cname=$(printf '%s\n' "$info" | awk -F' = ' '/^pkgname/{print $2; exit}')
  cbase=$(printf '%s\n' "$info" | awk -F' = ' '/^pkgbase/{print $2; exit}')
  [[ -n "$cname" ]] || continue
  # accept when the archive belongs to the requested package: by pkgbase,
  # by pkgname (single package), or by filename prefix (cache/restore).
  if [[ "$cbase" == "$PKG" || "$cname" == "$PKG" || "$(basename "$cand")" == "$PKG"-*.pkg.tar.zst ]]; then
    VALID_ARCHIVE="$cand"
    break
  fi
done
shopt -u nullglob

if [[ -z "$VALID_ARCHIVE" ]]; then
  echo "::error::[$PKG] no valid package archive produced (metadata-only or missing); refusing to upload artifact."
  exit 1
fi

pkginfo_name=$(_arch_pkginfo "$VALID_ARCHIVE" | awk -F' = ' '/^pkgname/{print $2; exit}')
pkginfo_ver=$(_arch_pkginfo "$VALID_ARCHIVE" | awk -F' = ' '/^pkgver/{print $2; exit}')
echo "[$PKG] valid artifact: $(basename "$VALID_ARCHIVE") (pkgname=$pkginfo_name ver=$pkginfo_ver)"
exit 0
