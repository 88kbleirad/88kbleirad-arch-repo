#!/usr/bin/env bash
#
# Automated package update detection (Phase 4.4). READ-ONLY: never
# modifies PKGBUILDs, never pushes, never opens PRs. It inspects each
# package's committed PKGBUILD, probes the upstream source (read-only
# network calls with timeouts), and emits:
#   - a machine-readable JSON report (one object per package), and
#   - a human-readable Markdown summary.
#
# Classifications:
#   UP_TO_DATE         current version == latest upstream (vercmp)
#   UPDATE_AVAILABLE   upstream has a newer version for this source shape
#   SOURCE_CHANGED     upstream default-branch HEAD moved (VCS/git+)
#   REBUILD_REQUIRED   upstream pinned/checksum state requires a rebuild
#   MANUAL_REVIEW      unsupported/unparsable source shape (never guessed)
#   CHECK_FAILED       upstream probe failed (transient/network); never
#                      treated as success
#
# Version comparison uses pacman `vercmp` (never lexical ordering).
#
# Usage:
#   check-updates.sh [pkg ...] [--json out.json] [--summary out.md]
#                    [--timeout 10] [--include-archived 0]
#
# Environment:
#   GH_TOKEN (optional; used for GitHub API when available)
#   GITHUB_WORKSPACE (repo root)
#
# No credentials are logged. Unverified/temporary upstream failures are
# reported as CHECK_FAILED, never as an update.

set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JSON_OUT=""
SUMMARY_OUT=""
TIMEOUT="${CHECK_UPDATES_TIMEOUT:-10}"
INCLUDE_ARCHIVED="${INCLUDE_ARCHIVED:-0}"
SELECTED=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUT="${2:-}"; shift 2 ;;
    --summary) SUMMARY_OUT="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --include-archived) INCLUDE_ARCHIVED="${2:-}"; shift 2 ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *) SELECTED+=("$1"); shift ;;
  esac
done

command -v vercmp >/dev/null 2>&1 || { echo "vercmp required (pacman-contrib)" >&2; exit 2; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
curl_json() { # url -> body (with timeout, silent)
  curl -fsSL --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    -H "Accept: application/vnd.github+json" \
    ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
    "$1" 2>/dev/null || true
}
curl_head() {
  curl -fsSI --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" "$1" 2>/dev/null || true
}
git_ls_remote() { # url -> refs
  GIT_TERMINAL_PROMPT=0 timeout "$TIMEOUT" git ls-remote "$1" 2>/dev/null || true
}

# compare version candidates with vercmp (strict greater)
vercmp_greater() { # a b -> 0 if a>b (strict), 1 otherwise
  local a="$1" b="$2" s
  s=$(vercmp "$a" "$b")
  [[ "$s" == "1" ]]
}

strip_v() { sed 's/^v//'; }

# ---------------------------------------------------------------------------
# classification helpers per source shape
# ---------------------------------------------------------------------------
# github_latest_tag <repo> -> newest tag (v-prefix tolerated), or empty
github_latest_tag() {
  local repo="$1"
  local tags
  tags=$(curl_json "https://api.github.com/repos/${repo}/tags?per_page=100" | jq -r '.[].name // empty' 2>/dev/null || true)
  [[ -z "$tags" ]] && return 1
  local best="" t
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    t=$(strip_v <<<"$t")
    [[ "$t" =~ ^[0-9] ]] || continue
    if [[ -z "$best" ]] || vercmp_greater "$t" "$best"; then best="$t"; fi
  done <<< "$tags"
  printf '%s' "$best"
}

# github_latest_release <repo> -> newest non-prerelease tag
github_latest_release() {
  local repo="$1" tag
  tag=$(curl_json "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null || true)
  [[ -n "$tag" ]] && strip_v <<<"$tag" || true
}

# gitlab_latest_tag <project> -> newest tag
gitlab_latest_tag() {
  local project="$1" enc tags t best=""
  enc=$(printf '%s' "$project" | jq -sRr @uri)
  tags=$(curl_json "https://gitlab.com/api/v4/projects/${enc}/repository/tags?per_page=100" | jq -r '.[].name // empty' 2>/dev/null || true)
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    t=$(strip_v <<<"$t")
    [[ "$t" =~ ^[0-9] ]] || continue
    if [[ -z "$best" ]] || vercmp_greater "$t" "$best"; then best="$t"; fi
  done <<< "$tags"
  printf '%s' "$best"
}

# npm_latest <package> -> latest version
npm_latest() {
  local pkg="$1"
  curl_json "https://registry.npmjs.org/${pkg}/latest" | jq -r '.version // empty' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# source parsing
# ---------------------------------------------------------------------------
parse_source_url() { # PKGBUILD -> first source URL (expanded), or empty
  local f="$1" line raw="" in_src=0
  # collect simple `name=value` assignments (no command substitution; never
  # sourced) for variable expansion
  declare -A VARS=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
      v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
      VARS["$k"]="$v"
    fi
  done < "$f"

  expand() { # string -> with ${var}/$var/${_var} substituted
    local s="$1" k
    for k in "${!VARS[@]}"; do
      s="${s//\$\{$k\}/${VARS[$k]}}"
      s="${s//\$$k/${VARS[$k]}}"
    done
    printf '%s' "$s"
  }

  while IFS= read -r line; do
    if [[ "$line" == source=\(* ]]; then in_src=1; line="${line#source=(}"; fi
    if (( in_src )); then
      # strip trailing ), whitespace and surrounding quotes
      raw="$line"
      raw="${raw%"${raw##*[![:space:]]}"}"   # rtrim
      raw="${raw%\)}"                        # trailing )
      raw="${raw%\"}"; raw="${raw#\"}"
      raw="${raw%\'}"; raw="${raw#\'}"
      raw="$(expand "$raw")"
      # strip ::filename= prefix
      raw="${raw##*::}"
      # first whitespace-delimited token (multi-source lines)
      raw="${raw%%[[:space:]]*}"
      if [[ "$raw" =~ ^(https?://|git\+) ]]; then
        printf '%s' "$raw"
        return 0
      fi
    fi
    if (( in_src )) && [[ "$line" == *\)* ]]; then in_src=0; fi
  done < "$f"
  return 1
}

check_pkg() {
  local pkg="$1"
  local pkgbuild="$REPO_ROOT/$pkg/PKGBUILD"
  local cur_ver src_url upstream_ver="" upstream_ref="" result="MANUAL_REVIEW" risk="low" note=""
  if [[ ! -f "$pkgbuild" ]]; then
    printf '{"package":"%s","status":"CHECK_FAILED","reason":"no PKGBUILD"}\n' "$pkg"
    return 0
  fi
  cur_ver=$(awk -F= '/^pkgver=/{gsub(/[ "\t]/,"",$2); print $2; exit}' "$pkgbuild")
  src_url=$(parse_source_url "$pkgbuild" || true)
  # determine kind + probe upstream
  if [[ "$src_url" == git+* ]]; then
    local giturl="${src_url#git+}"
    giturl="${giturl%%#*}"
    src_kind="git"
    local heads
    heads=$(git_ls_remote "$giturl")
    if [[ -z "$heads" ]]; then
      result="CHECK_FAILED"; note="git ls-remote failed"
    else
      local head_sha
      head_sha=$(printf '%s\n' "$heads" | awk '$2=="HEAD"{print $1; exit}')
      if [[ -z "$head_sha" ]]; then
        head_sha=$(printf '%s\n' "$heads" | awk '$2 ~ /refs\/heads\/master$|refs\/heads\/main$/ {print $1; exit}')
      fi
      # pinned commit?
      if [[ "$src_url" == *"#commit="* ]]; then
        local pinned="${src_url##*#commit=}"
        if [[ "${head_sha:0:${#pinned}}" == "$pinned" ]]; then
          result="UP_TO_DATE"; upstream_ref="$head_sha"; note="pinned commit matches upstream HEAD"
        else
          result="SOURCE_CHANGED"; upstream_ref="$head_sha"; note="pinned commit behind upstream HEAD"
        fi
      elif [[ "$src_url" == *"#tag="* ]]; then
        local tag="${src_url##*#tag=}"
        result="MANUAL_REVIEW"; upstream_ref="$tag"; note="pinned tag; verify tag still exists"
      else
        result="SOURCE_CHANGED"; upstream_ref="$head_sha"; note="branch HEAD moved"
      fi
    fi
  elif [[ "$src_url" == *github.com/* ]]; then
    # extract owner/repo (path after github.com/, before /archive /releases)
    local gh_repo
    gh_repo=$(printf '%s' "$src_url" | sed -E 's#https?://github\.com/([^/]+/[^/]+).*#\1#')
    local latest
    latest=$(github_latest_release "$gh_repo")
    [[ -z "$latest" ]] && latest=$(github_latest_tag "$gh_repo")
    if [[ -z "$latest" ]]; then
      result="CHECK_FAILED"; note="github probe returned no versions"
    else
      upstream_ver="$latest"
      if [[ -z "$cur_ver" ]] || vercmp_greater "$latest" "$cur_ver"; then
        result="UPDATE_AVAILABLE"; risk="medium"; note="newer version $latest"
      else
        result="UP_TO_DATE"; note="current matches/latest upstream"
      fi
    fi
  elif [[ "$src_url" == *gitlab.com/* ]]; then
    # beautyline-style pinned archive: /-/archive/${_commit}/... — the
    # committed recipe pins a commit, not a tag: verify by probing the
    # project's default branch HEAD instead of guessing a tag.
    local gl_project committed_pin
    gl_project=$(printf '%s' "$src_url" | sed -E 's#https?://gitlab\.com/([^/]+/[^/]+).*#\1#')
    committed_pin=""
    if [[ "$src_url" == *"/-/archive/"* || "$src_url" == *"#commit="* ]]; then
      committed_pin="1"
    fi
    local latest
    latest=$(gitlab_latest_tag "$gl_project")
    if [[ -n "$committed_pin" ]]; then
      if [[ -z "$latest" ]]; then
        result="MANUAL_REVIEW"; note="pinned GitLab commit; tag probe unavailable"
      else
        upstream_ver="$latest"
        if [[ -n "$cur_ver" ]] && vercmp_greater "$latest" "$cur_ver"; then
          result="UPDATE_AVAILABLE"; risk="medium"; note="pinned commit; newer tag $latest"
        else
          result="MANUAL_REVIEW"; note="pinned GitLab commit; tag $latest unchanged"
        fi
      fi
    elif [[ -z "$latest" ]]; then
      result="CHECK_FAILED"; note="gitlab probe returned no tags"
    else
      upstream_ver="$latest"
      if [[ -z "$cur_ver" ]] || vercmp_greater "$latest" "$cur_ver"; then
        result="UPDATE_AVAILABLE"; risk="medium"; note="newer version $latest"
      else
        result="UP_TO_DATE"; note="current matches gitlab latest"
      fi
    fi
  elif [[ "$src_url" == *registry.npmjs.org/* ]]; then
    local pkgname
    pkgname=$(awk -F= '/^pkgname=/{gsub(/[ "\t]/,"",$2); print $2; exit}' "$pkgbuild")
    local latest
    latest=$(npm_latest "$pkgname")
    if [[ -z "$latest" ]]; then
      result="CHECK_FAILED"; note="npm probe failed"
    else
      upstream_ver="$latest"
      if [[ -z "$cur_ver" ]] || vercmp_greater "$latest" "$cur_ver"; then
        result="UPDATE_AVAILABLE"; risk="medium"; note="newer npm version $latest"
      else
        result="UP_TO_DATE"; note="current matches npm latest"
      fi
    fi
  else
    result="MANUAL_REVIEW"; note="unparsable/unsupported source: ${src_url:0:60}"
  fi

  # JSON line
  printf '{"package":"%s","current_version":"%s","upstream_version":"%s","update_type":"%s","source_reference":"%s","rebuild_required":%s,"risk_level":"%s","recommended_action":"%s","note":"%s"}\n' \
    "$pkg" "$cur_ver" "$upstream_ver" "$result" "${upstream_ref:-${upstream_ver:-}}" \
    "$([[ "$result" == "UPDATE_AVAILABLE" || "$result" == "SOURCE_CHANGED" || "$result" == "REBUILD_REQUIRED" ]] && echo true || echo false)" \
    "$risk" \
    "$([[ "$result" == "UPDATE_AVAILABLE" ]] && echo "review PR proposal" || echo "none")" \
    "$note"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
PKGS=("${SELECTED[@]}")
if (( ${#PKGS[@]} == 0 )); then
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    e="$(echo "$raw" | sed 's/#.*//' | xargs)"
    [[ -z "$e" ]] && continue
    PKGS+=("${e#local:}")
  done < "$REPO_ROOT/packages.txt"
fi

{
  echo '['
  first=1
  for pkg in "${PKGS[@]}"; do
    [[ -d "$REPO_ROOT/$pkg" ]] || continue
    [[ $first -eq 0 ]] && echo ','
    first=0
    check_pkg "$pkg"
  done
  echo
  echo ']'
} > /tmp/check-updates-raw.json

if [[ -n "$JSON_OUT" ]]; then
  jq -s 'flatten' /tmp/check-updates-raw.json > "$JSON_OUT"
else
  jq -s 'flatten' /tmp/check-updates-raw.json
fi

if [[ -n "$SUMMARY_OUT" ]]; then
  {
    echo "## Package Update Detection (read-only)"
    echo
    echo "| package | current | upstream | type | risk | recommendation |"
    echo "|---|---|---|---|---|---|"
    jq -s -r 'flatten[] | "| \(.package) | \(.current_version // "-") | \(.upstream_version // "-") | \(.update_type) | \(.risk_level) | \(.recommended_action) |"' \
      /tmp/check-updates-raw.json
  } > "$SUMMARY_OUT"
fi

rm -f /tmp/check-updates-raw.json
