#!/usr/bin/env bash
#
# Mock `gh api` for cross-workflow ARTIFACT retrieval tests
# (collect-artifacts.sh). Serves GET-only endpoints from a fixture
# directory and records every invocation verbatim in an events log so
# tests can prove the collector never performs writes.
#
# Fixture layout (MOCK_GH_API_DIR):
#   artifacts.json            reply for GET .../actions/artifacts[?page=..]
#                             (GitHub API shape: {"total_count":N,
#                             "artifacts":[{id,name,workflow_run:{id},
#                             expired,created_at,expires_at}]})
#   runs/<id>.json            reply for GET .../actions/runs/<id>
#                             ({id,status,conclusion,path,created_at});
#                             absent => "Not Found" (run unresolvable)
#   artifacts/<id>.zip        binary reply for GET .../artifacts/<id>/zip
#
# The mock NEVER handles --method/--field/--input: if the collector ever
# starts writing, the events log records it and `gh api` here exits 2.

set -uo pipefail

MOCK_GH_API_DIR="${MOCK_GH_API_DIR:?MOCK_GH_API_DIR is required}"
MOCK_GH_API_EVENTS="${MOCK_GH_API_EVENTS:-/dev/null}"

printf 'GET %s\n' "$*" >> "$MOCK_GH_API_EVENTS"

# normalize: drop -H <header> pairs; the last remaining arg is the path
args=()
prev=""
for a in "$@"; do
  if [[ "$prev" == "-H" ]]; then prev=""; continue; fi
  if [[ "$a" == "-H" ]]; then prev="-H"; continue; fi
  args+=("$a")
done
[[ ${#args[@]} -ge 1 ]] || { echo "mock: no path argument" >&2; exit 2; }
path="${args[${#args[@]}-1]}"

if [[ "$path" == *"/actions/artifacts/"*"/zip" ]]; then
  id="${path##*/actions/artifacts/}"
  id="${id%%/zip}"
  f="$MOCK_GH_API_DIR/artifacts/$id.zip"
  if [[ -f "$f" ]]; then
    cat "$f"
    exit 0
  fi
  echo '{"message":"artifact not found in mock"}' >&2
  exit 1
fi

if [[ "$path" == *"/actions/artifacts"* ]]; then
  f="$MOCK_GH_API_DIR/artifacts.json"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    printf '{"total_count":0,"artifacts":[]}\n'
  fi
  exit 0
fi

if [[ "$path" =~ /actions/runs/([0-9]+)$ ]]; then
  id="${BASH_REMATCH[1]}"
  f="$MOCK_GH_API_DIR/runs/$id.json"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo '{"message":"Not Found"}'
  fi
  exit 0
fi

echo "mock: unhandled path: $path" >&2
exit 2
