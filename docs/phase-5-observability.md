# Phase 5 — Observability Dashboard

**Date:** 2026-11-06
**Status:** implemented + locally validated (static build; no live GitHub
operations performed)

## 1. Overview

A static, read-only monitoring dashboard for the 88kbleirad Arch repository.
Grafana-inspired layout but implemented as a self-contained static site:

- zero server, database, or third-party hosting requirement;
- built entirely from verified GitHub Actions artifacts/reports;
- dark Catppuccin Mocha theme, **square corners everywhere**
  (`border-radius: 0`), responsive desktop/mobile;
- no secrets embedded; no network calls at render time.

The dashboard is delivered as a GitHub Actions artifact (primary) with an
optional, owner-authorized GitHub Pages step (not enabled).

## 2. Metric schema

Every displayed value comes from a validated metrics snapshot
(`repo-metrics/v1`):

```json
{
  "schema": "repo-metrics/v1",
  "generated_at": "ISO-8601",
  "retention": 200,
  "build_profile": "x86-64-v4",
  "kpis": { ... },
  "health_history": [ {"timestamp","release","state"} ],
  "publish_history": [ {"timestamp","release","unchanged","uploaded","replaced","failed","api_requests","duration_seconds"} ],
  "build_durations": [ {"timestamp","package","duration_seconds","cache"} ],
  "cache_history": [ {"timestamp","run","hits","misses","hit_rate"} ],
  "packages": [ /* lifecycle report rows */ ]
}
```

Unavailable metrics are `null` → the dashboard renders `N/A`/`UNKNOWN`.
Never fabricated.

### Sources

| Snapshot section | Source |
|---|---|
| `packages` | `update-report.json` (lifecycle workflow) |
| `health_history` | `health-report*.json` + `health-history.jsonl` |
| `publish_history` | `publish-history.jsonl` (publication summaries) |
| `build_durations` / `cache_history` | `run-metrics-*` sidecars |

### Retention

- `build-metrics.sh` truncates each history series to the newest `--retention`
  points (default 50).
- `merge-metrics-history.sh` appends a new snapshot to a history file,
  deduplicates exact duplicates, sorts by `generated_at`, and trims to the
  newest N (default 200). Bounded growth; expiry handled by artifact
  retention-days.

## 3. Components

| File | Role |
|---|---|
| `.github/scripts/build-metrics.sh` | collects verified observations → snapshot |
| `.github/scripts/merge-metrics-history.sh` | bounded history merge |
| `.github/scripts/build-dashboard.sh` | renders static dashboard from snapshot |
| `dashboard/src/index.html` | dashboard shell (KPI cards, charts, inventory table) |
| `dashboard/src/style.css` | Catppuccin Mocha, square corners, responsive |
| `dashboard/src/app.js` | vanilla JS rendering (no framework) |
| `.github/workflows/observability.yml` | manual workflow: gather inputs → snapshot → history → build → artifact |
| `dashboard/tests/test-metrics.sh` | snapshot builder + history tests |
| `dashboard/tests/test-dashboard.sh` | build reproducibility/palette/no-secrets tests |

## 4. Dashboard features

- 12 KPI cards (Total Packages, Up-to-Date, Updates Available, Build
  Failures, Production Health, Staging Health, Build Success Rate, Cache Hit
  Rate, Avg Build Duration, Publication Duration, GitHub API Requests, Last
  Successful Publish).
- Four charts: health history, publication activity, build durations, cache
  efficiency. Missing source data renders an empty-state panel (`N/A`).
- Package inventory table: search, status filter chips, sortable columns,
  version-aware sorting, upstream links, epoch display.

## 5. Local preview / reproducible build

```fish
# 1. build a snapshot from local artifact copies
bash $REPO_ROOT/.github/scripts/build-metrics.sh \
  --health-dir /tmp/inputs --publish-dir /tmp/inputs \
  --runs-dir /tmp/inputs --lifecycle /tmp/inputs/update-report.json \
  --out /tmp/snapshot.json

# 2. render the dashboard
bash $REPO_ROOT/.github/scripts/build-dashboard.sh \
  --metrics /tmp/snapshot.json --out /tmp/dashboard

# 3. preview (python http.server)
cd /tmp/dashboard && python3 -m http.server 8000
# open http://127.0.0.1:8000/index.html
```

Reproducible: identical snapshot → identical dashboard output (tested).

## 6. Optional GitHub Pages deployment (NOT enabled)

The workflow has no Pages deployment step by default. To enable after owner
authorization, add an `actions/deploy-pages` step gated by a repository
variable (e.g. `ALLOW_PAGES_DEPLOY=yes`) and set the Pages source to
"GitHub Actions". The dashboard artifact remains the supported delivery.

## 7. Tests

- `test-metrics.sh` (13 assertions): schema, KPI derivation, retention,
  missing-source → null, read-only inputs, history merge/dedupe/trim.
- `test-dashboard.sh` (15 assertions): reproducible build, verbatim data
  embedding, Mocha palette + zero border-radius, responsive/accessible
  markers, search/filter/sort table, no secrets, empty snapshot render.
