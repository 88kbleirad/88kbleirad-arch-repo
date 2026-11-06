#!/usr/bin/env bash
#
# Package lifecycle detection (Phase 4.4 + Phase 5.1). READ-ONLY: never
# modifies PKGBUILDs, never pushes, never opens PRs, never publishes. It
# inspects each package's committed PKGBUILD, probes the upstream source
# (read-only network calls with timeouts), and emits:
#   - a machine-readable JSON report (one object per package), and
#   - a human-readable Markdown summary.
#
# Lifecycle states (Phase 5.1.3), separate from repository health verdicts:
#   UP_TO_DATE             current version == latest upstream (vercmp)
#   UPDATE_AVAILABLE       upstream has a newer version for this source shape
#   SOURCE_CHANGED         upstream default-branch HEAD moved (VCS/git+)
#   REBUILD_REQUIRED       upstream pinned/checksum state requires a rebuild
#   MANUAL_REVIEW          unsupported/unparsable source shape (never guessed)
#   CHECK_FAILED           upstream probe failed (transient/network); never
#                          treated as success
#   UPSTREAM_UNAVAILABLE  upstream repo is gone/not found (404/archived)
#   UPSTREAM_ARCHIVED     upstream repo is marked archived (GitHub)
#   UNKNOWN                no probe could be attempted (e.g. no source URL)
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
# Test hooks (deterministic offline tests; never used in production):
#   MOCK_PROBE_<KIND>_<VAR>=... overrides probe results. Supported:
#   MOCK_PROBE_GIT_REFS=<refs>   simulated git ls-remote output lines
#                                 (empty string simulates a failed probe)
#     MOCK_PROBE_GIT_ERROR=<kind> simulated probe-failure reason for the
#                                 empty GIT_REFS mock (missing|auth|timeout|…)
#     MOCK_PROBE_GITHUB_JSON=<json> simulated GitHub API response body
#     MOCK_PROBE_GITHUB_STATUS=<n> simulated GitHub HTTP status (404 => archived)
#     MOCK_PROBE_GITHUB_REPO_REDIRECT=<url> simulated GitHub repo redirect target
#     MOCK_PROBE_GITLAB_JSON=<json> simulated GitLab API response body
#     MOCK_PROBE_NPM_JSON=<json>    simulated npm registry response body
#     MOCK_PROBE_NPM_STATUS=<n>     simulated npm registry HTTP status
#     MOCK_PROBE_HTTP_STATUS=<n>    generic HTTP status for HEAD probes
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

command -v vercmp >/dev/null 2>&1 \
  || { echo "vercmp required (pacman-contrib on Arch Linux; makepkg on Ubuntu/Debian)" >&2; exit 2; }

# ---------------------------------------------------------------------------
# helpers
#
# Contract: every probe helper ALWAYS exits 0 and prints whatever data it
# obtained (possibly nothing). A probe failure is "no data", never a shell
# failure — the caller classifies it as CHECK_FAILED/UPSTREAM_*. This keeps
# `set -e` from aborting a lifecycle run on a flaky upstream.
#
# Test hooks (mock): MOCK_PROBE_GIT_REFS, MOCK_PROBE_HTTP_STATUS,
# MOCK_PROBE_GITHUB_JSON/STATUS (releases+tags),
# MOCK_PROBE_GITHUB_REPO_JSON/STATUS (repository metadata),
# MOCK_PROBE_GITLAB_JSON, MOCK_PROBE_NPM_JSON.
# ---------------------------------------------------------------------------
curl_json() { # url -> body (with timeout, silent; always rc 0)
  # Captures HTTP status in $CURL_HTTP_CODE (or "network_error"). Effective-
  # URL (redirect) tracking is done by github_repo_meta(), which runs its
  # own inline request; callers of curl_json run it inside command
  # substitution, so only the body reaches them.
  local url="$1" body="" status="200" curltmp
  CURL_HTTP_CODE="200"
  if [[ "$url" == *api.github.com/repos/*/releases/latest* || "$url" == *api.github.com/repos/*/tags* ]] \
      && [[ -n "${MOCK_PROBE_GITHUB_JSON:-}${MOCK_PROBE_GITHUB_STATUS:-}" ]]; then
    status="${MOCK_PROBE_GITHUB_STATUS:-200}"
    CURL_HTTP_CODE="$status"
    [[ "$status" == "200" ]] && body="${MOCK_PROBE_GITHUB_JSON:-}"
  elif [[ "$url" == *registry.npmjs.org/* ]]; then
    # npm probes bypass curl_json (npm_latest runs its own inline request
    # so the HTTP status survives command substitution)
    :
  else
    curltmp="$(mktemp)"
    status=$(curl -fsSL --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
      -H "Accept: application/vnd.github+json" \
      ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
      -o "$curltmp" -w '%{http_code}' \
      "$url" 2>/dev/null) || status="network_error"
    if [[ "$status" == "network_error" ]]; then
      CURL_HTTP_CODE="network_error"
    else
      CURL_HTTP_CODE="$status"
      body="$(cat "$curltmp" 2>/dev/null)"
    fi
    rm -f "$curltmp"
  fi
  [[ -n "$body" ]] && printf '%s' "$body"
  return 0
}

# github_repo_meta <owner/repo> -> writes $REPO_META (repository JSON or
# empty) and $CURL_HTTP_CODE (HTTP status or "network_error"). No command
# substitution (a subshell would lose the status). Rename detection is
# done by github_repo_status() from the canonical `full_name`.
github_repo_meta() {
  local repo="$1" status curltmp
  REPO_META=""
  if [[ -n "${MOCK_PROBE_GITHUB_REPO_JSON:-}${MOCK_PROBE_GITHUB_REPO_STATUS:-}" ]]; then
    CURL_HTTP_CODE="${MOCK_PROBE_GITHUB_REPO_STATUS:-200}"
    [[ "$CURL_HTTP_CODE" == "200" ]] && REPO_META="${MOCK_PROBE_GITHUB_REPO_JSON:-}"
    return 0
  fi
  curltmp="$(mktemp)"
  status=$(curl -fsSL --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    -H "Accept: application/vnd.github+json" \
    ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
    -o "$curltmp" -w '%{http_code}' \
    "https://api.github.com/repos/${repo}" 2>/dev/null) || status="network_error"
  if [[ "$status" == "network_error" ]]; then
    CURL_HTTP_CODE="network_error"
  else
    CURL_HTTP_CODE="$status"
    REPO_META="$(cat "$curltmp" 2>/dev/null)"
  fi
  rm -f "$curltmp"
}

curl_head() { # url -> headers (or nothing); always rc 0
  local url="$1"
  if [[ -n "${MOCK_PROBE_HTTP_STATUS:-}" ]]; then
    [[ "${MOCK_PROBE_HTTP_STATUS}" == "200" ]] && printf 'HTTP/2 200\n'
    return 0
  fi
  curl -fsSI --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" "$url" 2>/dev/null || true
}

git_ls_remote() { # url -> refs (or nothing); always rc 0
  local url="$1"
  if [[ -n "${MOCK_PROBE_GIT_REFS+x}" ]]; then
    # explicit mock (also when empty: simulates a failed probe without
    # touching the network)
    printf '%s\n' "${MOCK_PROBE_GIT_REFS}"
    return 0
  fi
  GIT_TERMINAL_PROMPT=0 timeout "$TIMEOUT" git ls-remote "$url" 2>/dev/null || true
}

# git_remote_diagnose <url> -> "missing"|"auth"|"timeout"|"network_error"|"invalid"|"ok"
# Runs git ls-remote a second time to classify a failed probe. The probe
# itself stays contract-compliant (always exit 0, prints refs or nothing);
# this helper only refines the failure note.
git_remote_diagnose() {
  local url="$1" err rc
  err="$(mktemp)"
  set +e
  GIT_TERMINAL_PROMPT=0 timeout "$TIMEOUT" git ls-remote "$url" >/dev/null 2>"$err"
  rc=$?
  set -e
  local body
  body="$(cat "$err" 2>/dev/null || true)"
  rm -f "$err"
  if [[ -z "$body" && $rc -ne 0 ]]; then
    printf 'network_error'; return 0
  fi
  case "$body" in
    *"not found"*|*"Could not read from remote repository"*|*"does not appear to be a git repository"*)
      printf 'missing' ;;
    *"Authentication failed"*|*"Permission denied"*|*"access denied"*|*"could not read Username"*|*"Invalid credentials"*)
      printf 'auth' ;;
    *) printf 'network_error' ;;
  esac
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
  [[ -z "$tags" ]] && { printf ''; return 0; }
  local best="" t
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    t=$(strip_v <<<"$t")
    [[ "$t" =~ ^[0-9] ]] || continue
    if [[ -z "$best" ]] || vercmp_greater "$t" "$best"; then best="$t"; fi
  done <<< "$tags"
  printf '%s' "$best"
  return 0
}

# github_latest_release <repo> -> newest non-prerelease tag (or empty)
github_latest_release() {
  local repo="$1" tag
  tag=$(curl_json "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null || true)
  [[ -n "$tag" ]] && strip_v <<<"$tag" || true
  return 0
}

# github_repo_status <owner/repo> -> "archived"|"missing"|"redirected"|"rate_limited"|
#                                    "network_error"|"ok"|"unknown"
# github_repo_status <repo> <outvar> — writes the state into $outvar and
# records any rename target in $CURL_REDIRECTED (no command substitution,
# so globals survive).
# Redirect semantics: only a repository *rename* (canonical repo name
# differs from the requested name, e.g. printcraft→pdfcraft) is treated as
# an identity change requiring review. A pure owner transfer (same repo
# name, e.g. pavouk/lgi→lgi-devs/lgi) leaves the source URL valid and is
# not flagged.
github_repo_status() {
  local repo="$1" out="$2" full_name requested_name canonical_name
  if [[ -n "${MOCK_PROBE_GITHUB_REPO_STATUS:-}" && "${MOCK_PROBE_GITHUB_REPO_STATUS}" != "200" ]]; then
    printf -v "$out" 'missing'; return 0
  fi
  github_repo_meta "$repo"
  if [[ "$CURL_HTTP_CODE" == "403" ]]; then
    printf -v "$out" 'rate_limited'; return 0
  fi
  if [[ "$CURL_HTTP_CODE" == "network_error" ]]; then
    printf -v "$out" 'network_error'; return 0
  fi
  if [[ -z "$REPO_META" ]]; then
    printf -v "$out" 'unknown'; return 0
  fi
  full_name="$(printf '%s' "$REPO_META" | jq -r '.full_name // empty' 2>/dev/null || true)"
  if [[ -n "$full_name" ]]; then
    requested_name="${repo##*/}"
    canonical_name="${full_name##*/}"
    if [[ "$canonical_name" != "$requested_name" ]]; then
      CURL_REDIRECTED="$full_name"
      printf -v "$out" 'redirected'; return 0
    fi
  fi
  if [[ "$(printf '%s' "$REPO_META" | jq -r '.archived // false' 2>/dev/null || true)" == "true" ]]; then
    printf -v "$out" 'archived'; return 0
  fi
  printf -v "$out" 'ok'
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
# npm_latest <package> <outvar> — writes the latest version into $outvar
# and the registry HTTP status into $NPM_STATUS. The HTTP request runs
# inline (no command-substitution subshell) so the status survives.
npm_latest() {
  local pkg="$1" out="$2" v="" status curltmp
  if [[ -n "${MOCK_PROBE_NPM_JSON:-}${MOCK_PROBE_NPM_STATUS:-}" ]]; then
    NPM_STATUS="${MOCK_PROBE_NPM_STATUS:-200}"
    [[ "$NPM_STATUS" == "200" ]] && v="$(printf '%s' "${MOCK_PROBE_NPM_JSON:-}" | jq -r '.version // empty' 2>/dev/null || true)"
  else
    curltmp="$(mktemp)"
    status=$(curl -fsSL --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
      -o "$curltmp" -w '%{http_code}' \
      "https://registry.npmjs.org/${pkg}/latest" 2>/dev/null) || status="network_error"
    NPM_STATUS="$status"
    v="$(jq -r '.version // empty' "$curltmp" 2>/dev/null || true)"
    rm -f "$curltmp"
  fi
  printf -v "$out" '%s' "$v"
}

# ---------------------------------------------------------------------------
# source parsing
# ---------------------------------------------------------------------------
parse_source_url() { # PKGBUILD -> first source URL (expanded), or empty
  # Safely extracts the first network source entry without sourcing the
  # PKGBUILD (never executes untrusted code). Supported formats:
  #   git+https://host/repo.git[?param][#fragment]   (VCS; ?signed allowed)
  #   https://host/...                               (tarball/archive)
  #   http://host/...
  # Variable references (${var}, $var, $var) are expanded from simple
  # `name=value` assignments only — command substitution, function calls,
  # and arrays are never evaluated.
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
    local s="$1" k v
    # repeatedly expand until stable; values may reference other variables
    for ((round=0; round<8; round++)); do
      local changed=0
      for k in "${!VARS[@]}"; do
        v="${VARS[$k]}"
        [[ "$s" == *"\${$k}"* || "$s" == *"\$$k"* ]] || continue
        local s_before="$s"
        s="${s//\$\{$k\}/$v}"
        s="${s//\$$k/$v}"
        [[ "$s" == "$s_before" ]] || changed=1
      done
      (( changed )) || break
    done
    printf '%s' "$s"
  }

  while IFS= read -r line; do
    if [[ "$line" == source=\(* ]]; then in_src=1; line="${line#source=(}"; fi
    if (( in_src )); then
      # strip trailing ), whitespace
      raw="$line"
      raw="${raw%"${raw##*[![:space:]]}"}"   # rtrim
      if [[ "$raw" == *\)* ]]; then
        raw="${raw%\)}"                      # single trailing )
        in_src=0
      fi
      # strip surrounding quotes (single or double), then expand variables
      raw="${raw%\"}"; raw="${raw#\"}"
      raw="${raw%\'}"; raw="${raw#\'}"
      raw="$(expand "$raw")"
      # handle `git+"URL"` / `git+'URL'` forms: drop a quote directly
      # after the git+ prefix (the trailing one was stripped above)
      case "$raw" in
        'git+"'*|"git+'"*) raw="git+${raw:5}" ;;
      esac
      # keep only the URL token: strip `filename::` prefixes and any
      # trailing non-URL tokens (e.g. `::foo`)
      raw="${raw##*::}"
      raw="${raw%%[[:space:]]*}"
      if [[ "$raw" =~ ^(git\+(https?://|git@|file://|ssh://)|https?://) ]]; then
        # the git+ prefix is preserved so callers can classify the source
        # kind (git / github / gitlab / npm); fragments (e.g. #commit=,
        # #branch=) and query params (?signed) are kept for that analysis
        printf '%s' "$raw"
        return 0
      fi
      if [[ "$raw" =~ ^(https?://|git\+) ]]; then
        # VCS/protocol form without a fetchable URL -> treat as unsupported
        return 2
      fi
    fi
  done < "$f"
  return 1
}

# classify_pkg <pkg> <pkgbuild> -> lifecycle JSON line
# Collects lifecycle fields (installed version epoch/pkgrel, package type,
# upstream URL, checked timestamp) and classifies the upstream state.
# States are documented in the header. Unknown/invalid states are NEVER
# invented; probe failures are CHECK_FAILED/UPSTREAM_UNAVAILABLE.
classify_pkg() {
  local pkg="$1" pkgbuild="$2" type_hint="${3:-}"
  local cur_ver cur_epoch cur_rel src_url package_type
  local upstream_url="" upstream_ver="" upstream_ref=""
  local result="UNKNOWN" risk="low" note=""
  local checked_at
  checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local source_kind="none" probe_ok="false" probe_error=""

  if [[ ! -f "$pkgbuild" ]]; then
    jq -nc --arg package "$pkg" \
      '{package:$package, update_type:"CHECK_FAILED", note:"no PKGBUILD"}'
    return 0
  fi

  # ---- installed/published version (never invented) ---------------------
  cur_ver=$(awk -F= '/^pkgver=/{gsub(/[ "\t]/,"",$2); print $2; exit}' "$pkgbuild")
  cur_rel=$(awk -F= '/^pkgrel=/{gsub(/[ "\t]/,"",$2); print $2; exit}' "$pkgbuild")
  cur_epoch=$(awk -F= '/^epoch=/{gsub(/[ "\t]/,"",$2); print $2; exit}' "$pkgbuild")

  # ---- package type (best-effort classification, never authoritative) ---
  case "$type_hint" in
    local) package_type="local" ;;
    xlibre) package_type="xlibre" ;;
    *)
      case "$pkg" in
        *-git|*-hg|*-svn) package_type="vcs" ;;
        *-bin) package_type="binary" ;;
        *) package_type="stable" ;;
      esac
      ;;
  esac

  # ---- upstream source URL (for reporting + probing) --------------------
  src_url=$(parse_source_url "$pkgbuild" || true)
  case "$src_url" in
    git+*) upstream_url="${src_url#git+}"; source_kind="git" ;;
    https://github.com/*|http://github.com/*) upstream_url="$src_url"; source_kind="github" ;;
    https://gitlab.com/*|http://gitlab.com/*) upstream_url="$src_url"; source_kind="gitlab" ;;
    https://registry.npmjs.org/*|http://registry.npmjs.org/*) upstream_url="$src_url"; source_kind="npm" ;;
    *) source_kind="unsupported" ;;
  esac

  # ---- probe upstream (read-only, timeout, never fail via curl) ---------
  if [[ "$source_kind" == "git" ]]; then
    local giturl heads head_sha
    # strip any VCS query/fragment metadata that is not part of the fetch
    # URL (e.g. `?signed` is a makepkg signature marker, `#branch=`,
    # `#tag=`, `#commit=` are VCS fragments and are handled separately)
    giturl="${src_url#git+}"
    if [[ "$giturl" == *"?signed"* ]]; then
      giturl="${giturl%%\?signed*}"
    fi
    giturl="${giturl%%#*}"
    heads=$(git_ls_remote "$giturl")
    if [[ -z "$heads" ]]; then
      probe_ok="false"
      if [[ -n "${MOCK_PROBE_GIT_REFS+x}" && -z "${MOCK_PROBE_GIT_REFS}" ]]; then
        # mocked empty ref list: deterministic failure classification
        probe_error="${MOCK_PROBE_GIT_ERROR:-network_error}"
        if [[ "$probe_error" == "missing" ]]; then
          result="UPSTREAM_UNAVAILABLE"; note="upstream git repository not found for ${giturl}"
          upstream_url="$giturl"
        else
          result="CHECK_FAILED"; note="git ls-remote failed (${probe_error})"
        fi
      else
        probe_error="$(git_remote_diagnose "$giturl")"
        case "$probe_error" in
          missing)
            # reachable remote but no such repository: an upstream fact,
            # not a transient probe failure
            result="UPSTREAM_UNAVAILABLE"; note="upstream git repository not found for ${giturl}"
            upstream_url="$giturl"
            ;;
          *)
            result="CHECK_FAILED"; note="git ls-remote failed (${probe_error})"
            ;;
        esac
      fi
    else
      probe_ok="true"
      # Parse the ref list in pure Bash (here-string). The previous
      # `printf | awk '...exit'` pipeline hit SIGPIPE on large ref lists:
      # awk exits after the first HEAD line while the printf builtin is
      # still writing, the pipe closes, and under `set -o pipefail` the
      # failing builtin aborts the whole script (line 315). A here-string
      # has no producer writing into a pipe that a consumer can close.
      head_sha=""
      while IFS=$' \t' read -r _sha _ref || [[ -n "$_sha" ]]; do
        [[ "$_ref" == "HEAD" ]] && { head_sha="$_sha"; break; }
      done <<< "$heads"
      if [[ -z "$head_sha" ]]; then
        while IFS=$' \t' read -r _sha _ref || [[ -n "$_sha" ]]; do
          [[ "$_ref" == "refs/heads/master" || "$_ref" == "refs/heads/main" ]] \
            && { head_sha="$_sha"; break; }
        done <<< "$heads"
      fi
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
        # Unpinned VCS: compare the revision recorded in pkgver against
        # upstream HEAD. pkgver formats (from git describe / makepkg):
        #   <tag>.r<count>.g<shortsha>   (standard Arch git pkgver)
        #   r<count>.g<shortsha>          (some fns omit the g)
        #   r<count>g<shortsha>           (concatenated form)
        #   <ver>.<count>.g<shortsha>
        #   <ver>.r<count>.<shortsha>
        # The abbreviated recorded SHA is compared as a prefix of the full
        # upstream HEAD SHA (a full-vs-abbreviated textual difference alone
        # must NOT be classified as a source change).
        pkgver_sha=""
        if [[ "$cur_ver" =~ (^|[^0-9a-f])r[0-9]+\.?(g)?([0-9a-f]{7,40})([^0-9a-f]|$) ]]; then
          pkgver_sha="${BASH_REMATCH[3]}"
        elif [[ "$cur_ver" =~ (^|[^0-9a-f])[0-9]+\.g([0-9a-f]{7,40})([^0-9a-f]|$) ]]; then
          pkgver_sha="${BASH_REMATCH[2]}"
        fi
        if [[ -n "$pkgver_sha" ]]; then
          if [[ "${head_sha:0:${#pkgver_sha}}" == "$pkgver_sha" ]]; then
            result="UP_TO_DATE"; upstream_ref="$head_sha"; note="recorded revision matches upstream HEAD"
          else
            result="SOURCE_CHANGED"; upstream_ref="$head_sha"; note="recorded revision behind upstream HEAD"
          fi
        else
          # No revision identifier is recoverable from pkgver; the package
          # cannot be verified against upstream HEAD. Do not assert a
          # rebuild. (e.g. date/epoch-based, `r<count>` only, or custom.)
          result="MANUAL_REVIEW"; upstream_ref="$head_sha"; note="cannot determine recorded VCS revision from pkgver"
        fi
      fi
    fi
  elif [[ "$source_kind" == "github" ]]; then
    local gh_repo latest repo_state
    gh_repo=$(printf '%s' "$src_url" | sed -E 's#https?://github\.com/([^/]+/[^/]+).*#\1#')
    CURL_REDIRECTED=""
    github_repo_status "$gh_repo" repo_state
    if [[ "$repo_state" == "archived" ]]; then
      result="UPSTREAM_ARCHIVED"; note="upstream repository is archived"
    elif [[ "$repo_state" == "missing" ]]; then
      result="UPSTREAM_UNAVAILABLE"; note="upstream repository not found (404)"
    elif [[ "$repo_state" == "redirected" ]]; then
      # repository moved (e.g. project rename); identity cannot be assumed
      result="MANUAL_REVIEW"; note="upstream repository redirected to ${CURL_REDIRECTED:-}"
    elif [[ "$repo_state" == "rate_limited" ]]; then
      result="CHECK_FAILED"; note="github API rate limited (403)"
    elif [[ "$repo_state" == "network_error" ]]; then
      result="CHECK_FAILED"; note="github API unreachable"
    else
      latest=$(github_latest_release "$gh_repo")
      [[ -z "$latest" ]] && latest=$(github_latest_tag "$gh_repo")
      if [[ -z "$latest" ]]; then
        result="CHECK_FAILED"; note="github probe returned no versions"
      else
        probe_ok="true"; upstream_ver="$latest"
        if [[ -z "$cur_ver" ]] || vercmp_greater "$latest" "$cur_ver"; then
          result="UPDATE_AVAILABLE"; risk="medium"; note="newer version $latest"
        else
          result="UP_TO_DATE"; note="current matches/latest upstream"
        fi
      fi
    fi
  elif [[ "$source_kind" == "gitlab" ]]; then
    local gl_project committed_pin latest
    gl_project=$(printf '%s' "$src_url" | sed -E 's#https?://gitlab\.com/([^/]+/[^/]+).*#\1#')
    committed_pin=""
    if [[ "$src_url" == *"/-/archive/"* || "$src_url" == *"#commit="* ]]; then
      committed_pin="1"
    fi
    latest=$(gitlab_latest_tag "$gl_project")
    if [[ -n "$committed_pin" ]]; then
      if [[ -z "$latest" ]]; then
        result="MANUAL_REVIEW"; note="pinned GitLab commit; tag probe unavailable"
      else
        probe_ok="true"; upstream_ver="$latest"
        if [[ -n "$cur_ver" ]] && vercmp_greater "$latest" "$cur_ver"; then
          result="UPDATE_AVAILABLE"; risk="medium"; note="pinned commit; newer tag $latest"
        else
          result="MANUAL_REVIEW"; note="pinned GitLab commit; tag $latest unchanged"
        fi
      fi
    elif [[ -z "$latest" ]]; then
      result="CHECK_FAILED"; note="gitlab probe returned no tags"
    else
      probe_ok="true"; upstream_ver="$latest"
      if [[ -z "$cur_ver" ]] || vercmp_greater "$latest" "$cur_ver"; then
        result="UPDATE_AVAILABLE"; risk="medium"; note="newer version $latest"
      else
        result="UP_TO_DATE"; note="current matches gitlab latest"
      fi
    fi
  elif [[ "$source_kind" == "npm" ]]; then
    local pkgname latest
    pkgname=$(awk -F= '/^pkgname=/{gsub(/[ "\t]/,"",$2); print $2; exit}' "$pkgbuild")
    npm_latest "$pkgname" latest
    if [[ -z "$latest" ]]; then
      # classify the failure: an unpublished/renamed npm package is an
      # upstream fact, while rate limiting/timeouts are transient
      case "${NPM_STATUS:-network_error}" in
        404)
          result="UPSTREAM_UNAVAILABLE"; note="npm package ${pkgname} not found (404)"
          ;;
        403)
          result="CHECK_FAILED"; note="npm registry denied the request (403; rate limit or auth)"
          ;;
        429)
          result="CHECK_FAILED"; note="npm registry rate limited (429)"
          ;;
        5??)
          result="CHECK_FAILED"; note="npm registry error (${NPM_STATUS})"
          ;;
        *)
          result="CHECK_FAILED"; note="npm registry unreachable"
          ;;
      esac
    else
      probe_ok="true"; upstream_ver="$latest"
      if [[ -z "$cur_ver" ]] || vercmp_greater "$latest" "$cur_ver"; then
        result="UPDATE_AVAILABLE"; risk="medium"; note="newer npm version $latest"
      else
        result="UP_TO_DATE"; note="current matches npm latest"
      fi
    fi
  else
    result="MANUAL_REVIEW"; note="unparsable/unsupported source: ${src_url:0:60}"
  fi

  # JSON line (schema stable; lifecycle fields added in Phase 5.1).
  # jq -nc --arg properly escapes every string (URLs may contain
  # backslash-escaped variable forms, e.g. `\${pkgver}`); printf-based
  # JSON would emit invalid escapes and abort the report.
  jq -nc \
    --arg package "$pkg" \
    --arg current_version "$cur_ver" \
    --arg current_epoch "${cur_epoch:-}" \
    --arg current_release "${cur_rel:-}" \
    --arg upstream_version "$upstream_ver" \
    --arg upstream_url "$upstream_url" \
    --arg update_type "$result" \
    --arg package_type "$package_type" \
    --arg source_kind "$source_kind" \
    --arg source_reference "${upstream_ref:-${upstream_ver:-}}" \
    --argjson rebuild_required "$([[ "$result" == "UPDATE_AVAILABLE" || "$result" == "SOURCE_CHANGED" || "$result" == "REBUILD_REQUIRED" ]] && echo true || echo false)" \
    --arg risk_level "$risk" \
    --arg recommended_action "$([[ "$result" == "UPDATE_AVAILABLE" ]] && echo "review PR proposal" || echo "none")" \
    --argjson probe_ok "$probe_ok" \
    --arg probe_error "$probe_error" \
    --arg checked_at "$checked_at" \
    --arg note "$note" \
    '{package:$package, current_version:$current_version, current_epoch:$current_epoch, current_release:$current_release, upstream_version:$upstream_version, upstream_url:$upstream_url, update_type:$update_type, package_type:$package_type, source_kind:$source_kind, source_reference:$source_reference, rebuild_required:$rebuild_required, risk_level:$risk_level, recommended_action:$recommended_action, probe_ok:$probe_ok, probe_error:$probe_error, checked_at:$checked_at, note:$note}'
}

# compatibility alias for older callers/tests
check_pkg() { classify_pkg "$@"; }

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
PKGS=("${SELECTED[@]}")
declare -A PKG_HINT=()
if (( ${#PKGS[@]} == 0 )); then
  # package-type hints come from the packages.txt prefix (local:/xlibre:)
  # or the package-name prefix (xlibre-*)
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    trimmed="$(echo "$raw" | sed 's/#.*//' | xargs)"
    [[ -z "$trimmed" ]] && continue
    if [[ "$trimmed" == "local:"* ]]; then
      PKGS+=("${trimmed#local:}")
      PKG_HINT["${trimmed#local:}"]="local"
    elif [[ "$trimmed" == "xlibre:"* ]]; then
      PKGS+=("${trimmed#xlibre:}")
      PKG_HINT["${trimmed#xlibre:}"]="xlibre"
    else
      PKGS+=("$trimmed")
      [[ "$trimmed" == xlibre-* ]] && PKG_HINT["$trimmed"]="xlibre"
    fi
  done < "$REPO_ROOT/packages.txt"
fi

{
  echo '['
  first=1
  for pkg in "${PKGS[@]}"; do
    [[ -d "$REPO_ROOT/$pkg" ]] || continue
    [[ $first -eq 0 ]] && echo ','
    first=0
    classify_pkg "$pkg" "$REPO_ROOT/$pkg/PKGBUILD" "${PKG_HINT[$pkg]:-}"
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
    echo "## Package Lifecycle (read-only)"
    echo
    echo "### Classification counts"
    echo
    jq -s -r 'flatten | group_by(.update_type) | sort_by(.[0].update_type)[] | "- \(.[0].update_type): \(length)"' \
      /tmp/check-updates-raw.json
    echo
    echo "| package | current | upstream | type | pkg-type | risk | recommendation |"
    echo "|---|---|---|---|---|---|---|"
    jq -s -r 'flatten[] | "| \(.package) | \(.current_version // "-") | \(.upstream_version // "-") | \(.update_type) | \(.package_type // "-") | \(.risk_level) | \(.recommended_action) |"' \
      /tmp/check-updates-raw.json
  } > "$SUMMARY_OUT"
fi

rm -f /tmp/check-updates-raw.json
