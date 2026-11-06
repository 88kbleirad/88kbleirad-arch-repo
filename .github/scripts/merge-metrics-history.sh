#!/usr/bin/env bash
#
# Bounded metrics history merge (Phase 5.3.5). Pure, offline, read-only:
# merges a new snapshot into a history file (append + trim to retention)
# and writes the result. Used by the observability workflow between
# artifact downloads/uploads; also directly testable.
#
# History format: one JSON object per line (JSONL). Each line is one
# snapshot; series are extracted at dashboard build time.
#
# Usage:
#   merge-metrics-history.sh --history <inc> --snapshot <snap.json>
#       [--out <out>] [--retention <N>] [--dedupe-keys ...]
#
# If --out is omitted the merged history is printed to stdout.
# If --history is missing/empty, the history starts with the snapshot.

set -euo pipefail

HISTORY=""
SNAPSHOT=""
OUT=""
RETENTION="${METRICS_RETENTION:-200}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --history) HISTORY="${2:-}"; shift 2 ;;
    --snapshot) SNAPSHOT="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --retention) RETENTION="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SNAPSHOT" && -f "$SNAPSHOT" ]] || { echo "::error::--snapshot required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

# validate snapshot shape
jq -e '.generated_at and .kpis' "$SNAPSHOT" >/dev/null 2>&1 \
  || { echo "::error::snapshot is not a valid metrics snapshot" >&2; exit 2; }

SN=$(jq -c '.' "$SNAPSHOT")

if [[ -n "$HISTORY" && -f "$HISTORY" && -s "$HISTORY" ]]; then
  # keep only lines that parse; append new snapshot; sort by generated_at;
  # dedupe exact duplicates; trim to newest retention. A corrupt history
  # line must never abort the merge — it is dropped.
  CLEAN=$(jq -R -c 'fromjson? // empty' "$HISTORY" 2>/dev/null || true)
  MERGED=$(jq -s -c --argjson sn "$SN" --argjson n "$RETENTION" '
    (map(select(.generated_at != null)) + [$sn])
    | unique
    | sort_by(.generated_at)
    | if length > $n then .[length-$n:] else . end
    | .[]' <<<"$CLEAN" 2>/dev/null || printf '%s\n' "$SN")
else
  MERGED=$(printf '%s\n' "$SN")
fi

if [[ -n "$OUT" ]]; then
  printf '%s\n' "$MERGED" > "$OUT"
  echo "[history] wrote $OUT ($(printf '%s\n' "$MERGED" | wc -l) entries)" >&2
else
  printf '%s\n' "$MERGED"
fi
