#!/usr/bin/env bash
#
# audit-package-isa.sh <output-dir> <pkg>
#
# Informational post-build audit: inspect every ELF file inside the produced
# package(s) for:
#   - ELF GNU property "x86 ISA needed" notes (hard ISA requirement)
#   - EVEX (0x62) instruction prefix frequency (AVX-512 usage indicator)
#
# Limitations (documented in the run report):
#   - Static EVEX counts include data that resembles opcodes; the count is
#     a heuristic, not proof that the instruction is reachable.
#   - A binary with no EVEX instructions may still be v4-incompatible via
#     indirect dispatch; the inverse (EVEX present) does not guarantee the
#     binary *requires* v4.
#   - This audit runs on the build host; it never executes package code.
#
# Output goes to stdout only (captured by the caller into the job log).

set -uo pipefail

DIR="${1:?usage: audit-package-isa.sh <dir> <pkg>}"
PKG="${2:?usage: audit-package-isa.sh <dir> <pkg>}"

echo "== package ISA audit: $PKG =="
shopt -s nullglob
for pkg in "$DIR"/*.pkg.tar.zst; do
  echo "--- $(basename "$pkg")"
  tmp=$(mktemp -d)
  tar --zstd -xf "$pkg" -C "$tmp" 2>/dev/null || bsdtar -xf "$pkg" -C "$tmp" 2>/dev/null
  while IFS= read -r f; do
    file "$f" | grep -q "ELF" || continue
    # 1) GNU property ISA-needed notes
    need=$(readelf -n "$f" 2>/dev/null | awk '/x86 ISA needed/{getline; print; exit}' | sed 's/^[[:space:]]*//')
    # 2) EVEX / AVX-512 instruction count (heuristic)
    evex=$(objdump -d "$f" 2>/dev/null | awk '/\t62 /{c++} END{print c+0}')
    echo "  $(basename "$f"): ${need:+ISA-needed=[$need] }EVEX-heuristic=$evex"
  done < <(find "$tmp" -type f)
  rm -rf "$tmp"
done
echo "== audit complete (informational; limits: static heuristic, not runtime proof) =="
exit 0
