#!/usr/bin/env bash
#
# Reproducible dashboard build (Phase 5.3.6).
#
#   build-dashboard.sh --metrics <snapshot.json> [--out <dir>]
#
# Produces a self-contained static dashboard:
#   <out>/index.html
#   <out>/style.css
#   <out>/app.js
#   <out>/metrics.js        (window.REPO_METRICS = <snapshot>)
#   <out>/metrics.json      (raw snapshot, for verification/tests)
#
# The source assets live in dashboard/src/. No external dependencies, no
# network, no build tooling beyond bash + jq.
#
# If --metrics is omitted, an EMPTY snapshot is used (all N/A) so the
# build is always reproducible.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../dashboard/src" && pwd)"
OUT=""
METRICS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --metrics) METRICS="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$OUT" ]] || OUT="${DASHBOARD_OUT:-$(pwd)/dashboard-dist}"
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

if [[ -n "$METRICS" && -f "$METRICS" ]]; then
  jq -e . "$METRICS" >/dev/null 2>&1 || { echo "::error::metrics snapshot is not valid JSON" >&2; exit 1; }
else
  METRICS="/dev/null"
fi

mkdir -p "$OUT"

# raw snapshot copy (valid JSON, for verification/tests)
if [[ "$METRICS" == "/dev/null" ]]; then
  printf '{}\n' > "$OUT/metrics.json"
else
  cp "$METRICS" "$OUT/metrics.json"
fi

# metrics.js: window.REPO_METRICS = {...}; (single line, valid JS)
{
  printf 'window.REPO_METRICS = '
  cat "$OUT/metrics.json"
  printf ';\n'
} > "$OUT/metrics.js"

cp "$SRC/index.html" "$OUT/"
cp "$SRC/style.css" "$OUT/"
cp "$SRC/app.js" "$OUT/"

echo "[dashboard] built $OUT"
echo "[dashboard] metrics: ${METRICS:-<empty snapshot>}"
