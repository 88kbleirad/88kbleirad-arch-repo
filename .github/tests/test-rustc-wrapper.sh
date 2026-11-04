#!/usr/bin/env bash
#
# Regression tests for the Rust x86-64-v4 build-script safety wrapper
# (.github/scripts/rustc-v4-safe.sh).
#
# The wrapper must strip `-C target-cpu=x86-64-v4` from every host-side /
# auxiliary crate (build scripts, proc-macros, build-dependency libraries)
# while keeping it for the final `bin` target. This is what prevents
# SIGILL on non-AVX-512 GitHub runners (observed: glib-sys linked into a
# build script, and openssl-sys).
#
# Uses an argv-echoing fake rustc; no cargo/AVX-512 needed.

set -euo pipefail

REPO_ROOT=${REPO_ROOT:?REPO_ROOT is required}
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
note() { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

WRAPPER="$REPO_ROOT/.github/scripts/rustc-v4-safe.sh"
FAKE="$WORKDIR/fake-rustc"
cat > "$FAKE" <<'X'
#!/usr/bin/env bash
printf '%s\n' "$@"
X
chmod +x "$FAKE"

run_wrapper() { # args...
  bash "$WRAPPER" "$FAKE" "$@"
}

check_stripped() { # label args...
  local label="$1"; shift
  local out
  out="$(run_wrapper "$@")"
  if printf '%s\n' "$out" | grep -q 'target-cpu=x86-64-v4'; then
    bad "$label: target-cpu NOT stripped"
  else
    ok "$label: target-cpu stripped"
  fi
}

check_kept() { # label args...
  local label="$1"; shift
  local out
  out="$(run_wrapper "$@")"
  if printf '%s\n' "$out" | grep -q 'target-cpu=x86-64-v4'; then
    ok "$label: target-cpu kept"
  else
    bad "$label: target-cpu unexpectedly stripped"
  fi
}

# ---------------------------------------------------------------------------
note "build scripts and proc-macros lose v4 codegen"
check_stripped "build_script (bin, -C separate)" \
  --crate-name build_script_build --crate-type bin -C target-cpu=x86-64-v4 -C opt-level=3
check_stripped "build_script (-Ctarget-cpu combined)" \
  --crate-name build_script_build -Ctarget-cpu=x86-64-v4
check_stripped "proc-macro crate" \
  --crate-name mypm --crate-type proc-macro -C target-cpu=x86-64-v4

# ---------------------------------------------------------------------------
note "build-dependency libraries lose v4 codegen (glib-sys case)"
check_stripped "build-dep lib (glib_sys)" \
  --crate-name glib_sys --crate-type lib -C target-cpu=x86-64-v4 -C opt-level=3
check_stripped "build-dep lib staticlib" \
  --crate-name foo --crate-type staticlib -C target-cpu=x86-64-v4
check_stripped "build-dep lib cdylib" \
  --crate-name bar --crate-type cdylib -C target-cpu=x86-64-v4

# ---------------------------------------------------------------------------
note "final target binary keeps v4 codegen"
check_kept "final bin target" \
  --crate-name myapp --crate-type bin -C target-cpu=x86-64-v4 -C opt-level=3

# ---------------------------------------------------------------------------
note "other flags are preserved"
out="$(run_wrapper --crate-name glib_sys --crate-type lib -C opt-level=3 -C target-cpu=x86-64-v4 -C debug-assertions=off)"
printf '%s\n' "$out" | grep -q -- '-C' && printf '%s\n' "$out" | grep -q 'opt-level=3' \
  && ok "other -C flags preserved" || bad "other flags dropped: $out"
printf '%s\n' "$out" | grep -q 'debug-assertions=off' \
  && ok "debug-assertions preserved" || bad "debug-assertions dropped"

# ---------------------------------------------------------------------------
note "no target-cpu flag at all is a no-op"
out="$(run_wrapper --crate-name x --crate-type lib -C opt-level=2)"
printf '%s\n' "$out" | grep -q 'opt-level=2' && ok "no-op passthrough" || bad "passthrough broken"

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
