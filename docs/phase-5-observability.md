# Phase 5 — Observability Dashboard

**Date:** 2026-11-06
**Status:** implemented + locally validated; live source retrieval requires
an authorized observability workflow run (Phase 5.4)

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

## 2. Source retrieval (cross-workflow, read-only)

The dashboard's inputs are produced by OTHER workflows. `actions/download-artifact`
without an explicit run-id only sees the CURRENT run's artifacts (the original
"Found 0 artifact(s) / packages=0 health=0 publish=0" failure) and its
`pattern` input is a single glob — a multiline pattern matches nothing.

`.github/scripts/collect-artifacts.sh` retrieves inputs via the GitHub Actions
REST API:

1. enumerate the repository's artifacts (paginated `actions/artifacts`),
2. resolve the owning workflow run of every candidate and require a
   **completed + successful** run (never in-flight/failed),
3. honour artifact expiration/retention (`expired` flag + `expires_at`),
4. **never ingest the current run's own artifacts** (recursion guard),
5. download each selected artifact into its own directory (artifact names
   collide: every health report ships `health-report.json`),
6. validate every downloaded report against its schema and **reject
   malformed data** instead of rendering it as healthy,
7. retrieve the most recent `metrics-snapshot` from a previous successful
   observability run so history persists across runs (bounded by retention
   + dedupe).

Only HTTP GETs are issued; the collector cannot write to GitHub.

### Sources

| Slot (inventory) | Artifact pattern | Produced by | Required |
|---|---|---|---|
| `health_production` | `health-report-repository` | repo-health/build-release health gate | core |
| `health_staging` | `health-report-repository-v4-test` | repo-health/build-staging health gate | core |
| `lifecycle` | `update-report` | check-updates (Package Lifecycle) | core |
| `publish` | `publish-summary-*` | build-release/build-staging publish jobs | optional |
| `ci` | `run-metrics-*` | build-release cache-verify sidecar | optional |
| `history` | `metrics-snapshot` (previous run) | observability itself | optional |

Configuration inventory (`packages.txt`) and published inventory (production
health report `package_count`) are kept separate in the snapshot: configured
may exceed published.

## 3. Completeness verdict

`collect-artifacts.sh` emits a `repo-artifact-inventory/v1` document with a
deterministic verdict:

- core sources = production health, staging health, lifecycle report
- `COMPLETE` = every core source retrieved and schema-valid
- `PARTIAL` = at least one core source ok, but not all
- `NO_DATA` = no core source ok

The snapshot embeds `completeness` + `source_summary` (per-slot status,
rejections, warnings). The dashboard renders an explicit incomplete banner;
the workflow fails the run on `NO_DATA` (after uploading the labelled
incomplete dashboard) — a no-source dashboard is **never** presented as a
populated observability view. Health KPIs are only ever taken from validated
reports (`HEALTHY`/`DEGRADED`/`FAILED` from `repo-health.sh`).

## 4. Metric schema

Every displayed value comes from a validated metrics snapshot
(`repo-metrics/v1`):

```json
{
  "schema": "repo-metrics/v1",
  "generated_at": "ISO-8601",
  "retention": 200,
  "completeness": "COMPLETE|PARTIAL|NO_DATA",
  "source_summary": { "completeness": "...", "sources": {...}, "missing": [...], "unavailable": [...], "rejected": [...], "warnings": [...] },
  "kpis": { ... },
  "health_history": [ {"timestamp","release","state"} ],
  "publish_history": [ {"timestamp","release","unchanged","uploaded","replaced","failed","api_requests","duration_seconds"} ],
  "build_durations": [ {"timestamp","package","duration_seconds","cache"} ],
  "cache_history": [ {"timestamp","run","hits","misses","hit_rate"} ],
  "packages": [ /* lifecycle report rows */ ]
}
```

Unavailable metrics are `null` → the dashboard renders `N/A`/`UNKNOWN`.
Never fabricated. `kpis.packages_configured` (packages.txt) and
`kpis.packages_published` (production release inventory) are distinct.

### Retention

- `build-metrics.sh` truncates each history series to the newest `--retention`
  points (default 50).
- `merge-metrics-history.sh` appends a new snapshot to a history file,
  deduplicates exact duplicates, sorts by `generated_at`, and trims to the
  newest N (default 200). Bounded growth; expiry handled by artifact
  retention-days.

## 5. Components

| File | Role |
|---|---|
| `.github/scripts/collect-artifacts.sh` | cross-run artifact retrieval + schema validation + inventory |
| `.github/scripts/build-metrics.sh` | collects verified observations → snapshot (+ completeness) |
| `.github/scripts/merge-metrics-history.sh` | bounded history merge |
| `.github/scripts/build-dashboard.sh` | renders static dashboard from snapshot |
| `dashboard/src/index.html` | dashboard shell (KPI cards, charts, inventory table, incomplete banner) |
| `dashboard/src/style.css` | Catppuccin Mocha, square corners, responsive |
| `dashboard/src/app.js` | vanilla JS rendering (no framework) |
| `.github/workflows/observability.yml` | manual workflow: collect → snapshot → history → build → artifact |
| `dashboard/tests/test-metrics.sh` | snapshot builder + history tests |
| `dashboard/tests/test-dashboard.sh` | build reproducibility/palette/no-secrets/incomplete-state tests |
| `.github/tests/test-artifact-collection.sh` | REST retrieval regression suite (mock GitHub API) |

## 6. Local preview / reproducible build

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

## 7. Optional GitHub Pages deployment (NOT enabled)

The workflow has no Pages deployment step by default. To enable after owner
authorization, add an `actions/deploy-pages` step gated by a repository
variable (e.g. `ALLOW_PAGES_DEPLOY=yes`) and set the Pages source to
"GitHub Actions". The dashboard artifact remains the supported delivery.

## 8. Tests

- `test-artifact-collection.sh` (30 assertions): discovery across runs, source
  run selection, expired/missing/failed/corrupt sources, prod/staging
  separation, history persistence (two runs), completeness classification,
  no API writes (mock `gh`).
- `test-metrics.sh` (13 assertions): schema, KPI derivation, retention,
  missing-source → null, read-only inputs, history merge/dedupe/trim.
- `test-dashboard.sh` (18 assertions): reproducible build, verbatim data
  embedding, Mocha palette + zero border-radius, responsive/accessible
  markers, search/filter/sort table, no secrets, empty-snapshot render,
  incompleteness banner.
- `test-workflow-audit.sh` (29 assertions, incl. Phase 5.4): vercmp
  provisioning, actions:read, collector wiring, no multiline pattern.
