#!/usr/bin/env bash
#
# rustc wrapper that strips `-C target-cpu=x86-64-v4` (and any other
# codegen CPU flags) from Cargo **build scripts**, **proc-macros**, and
# **build-dependency libraries**.
#
# Why: Cargo compiles build scripts and their dependencies for the HOST
# and executes them during the build. GitHub-hosted ubuntu-24.04 runners
# do NOT provide AVX-512 (x86-64-v4). With a global `RUSTFLAGS="-C
# target-cpu=x86-64-v4"` (the CachyOS v4 Rust profile), the resulting
# host-executed binaries execute v4-only instructions and die with SIGILL
# on the runner (observed: magika's `openssl-sys` build script, and
# ripdrag's `glib-sys` build-dependency library -> signal 4).
#
# Cargo compiles:
#   - the build script itself with `--crate-name build_script_*` and
#     `--crate-type bin`;
#   - each build-dependency with `--crate-type lib` and the dependency's
#     crate name (e.g. `glib_sys`), which is then LINKED into the build
#     script executable;
#   - proc-macros with `--crate-type proc-macro`;
#   - the final target (binary) with `--crate-type bin` and the package's
#     own crate name.
#
# The wrapper therefore strips v4 codegen flags for EVERY crate type except
# `bin`. Build scripts (bin) are also stripped by crate-name prefix. This
# guarantees host-executed code is runner-compatible. The final target
# binary keeps the v4 profile. NOTE: any package that publishes a compiled
# library artifact (lib/staticlib/cdylib) would lose the v4 codegen on
# that library; no package in this repository ships such an artifact.
#
# Install as RUSTC_WRAPPER in the build container. The first argument is
# the path to the real `rustc` (Cargo's wrapper protocol) — it is shifted
# off before forwarding.

set -euo pipefail

real_rustc="${1:?missing real rustc path}"
shift

host_tool=0
prev=""
args=()
pending_c_flag=0

for a in "$@"; do
  # detect crate kind: value follows --crate-name / --crate-type
  if [[ "$a" == "--crate-name" || "$a" == "--crate-type" ]]; then
    prev="$a"
    args+=("$a")
    continue
  fi
  if [[ "$prev" == "--crate-name" ]]; then
    prev=""
    [[ "$a" == build_script_* ]] && host_tool=1
    args+=("$a")
    continue
  fi
  if [[ "$prev" == "--crate-type" ]]; then
    prev=""
    # strip v4 for every host-side/auxiliary crate type; only final
    # `bin` targets keep the v4 profile
    if [[ "$a" != "bin" ]]; then
      host_tool=1
    fi
    args+=("$a")
    continue
  fi

  # a bare `-C` flag: remember it until we see its value
  if [[ "$a" == "-C" ]]; then
    pending_c_flag=1
    args+=("$a")
    continue
  fi

  if (( host_tool && pending_c_flag )) && [[ "$a" == target-cpu=* ]]; then
    # drop the target-cpu value AND the preceding -C
    args=( "${args[@]:0:${#args[@]}-1}" )
    pending_c_flag=0
    continue
  fi

  if (( host_tool )) && [[ "$a" == -Ctarget-cpu=* ]]; then
    continue
  fi

  pending_c_flag=0
  args+=("$a")
done

exec "$real_rustc" "${args[@]}"
