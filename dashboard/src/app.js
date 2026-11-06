/* Repository Observability dashboard — client logic.
 * Rendering only: all data comes from the generated metrics.js snapshot
 * (verified CI artifacts). No credentials, no network calls.
 */
(function () {
  "use strict";

  var DATA = window.REPO_METRICS || {};

  function txt(id, s) { var el = document.getElementById(id); if (el) el.textContent = s; }
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function fmt(v) { return v == null || v === "" ? "N/A" : String(v); }

  /* ---------- KPI cards ---------- */
  function kpi(label, value, cls, meta) {
    return '<div class="kpi"><span class="label">' + esc(label) + "</span>" +
      '<span class="value ' + (cls || "") + '">' + esc(fmt(value)) + "</span>" +
      (meta ? '<span class="meta">' + esc(meta) + "</span>" : "") + "</div>";
  }

  function renderKpis() {
    var d = DATA.kpis || {};
    var h = "";
    h += kpi("Configured Packages", d.packages_configured, "");
    h += kpi("Published Packages", d.packages_published, "");
    h += kpi("Total Packages (checked)", d.total_packages, "");
    h += kpi("Up-to-Date", d.up_to_date, "ok");
    h += kpi("Updates Available", d.updates_available, "warn");
    h += kpi("Source Changes", d.source_changes, d.source_changes > 0 ? "warn" : "ok");
    h += kpi("Manual Review", d.manual_review, d.manual_review > 0 ? "warn" : "ok");
    h += kpi("Check Failed", d.check_failed, d.check_failed > 0 ? "bad" : "ok");
    h += kpi("Build Failures", d.build_failures, d.build_failures == null ? "na" : (d.build_failures > 0 ? "bad" : "ok"));
    h += kpi("Production Health", d.production_health, healthCls(d.production_health), d.production_health_at || "");
    h += kpi("Staging Health", d.staging_health, healthCls(d.staging_health), d.staging_health_at || "");
    h += kpi("Build Success Rate", d.build_success_rate != null ? d.build_success_rate + "%" : null, rateCls(d.build_success_rate));
    h += kpi("Cache Hit Rate", d.cache_hit_rate != null ? d.cache_hit_rate + "%" : null, rateCls(d.cache_hit_rate));
    h += kpi("Avg Build Duration", d.avg_build_duration, "", "s");
    h += kpi("Publication Duration", d.publication_duration, "", "s");
    h += kpi("GitHub API Requests", d.api_requests, "");
    h += kpi("Last Successful Publish", d.last_successful_publish, "");
    document.getElementById("kpis").innerHTML = h;
    txt("snapshot-at", d.snapshot_at || "N/A");
    completenessBanner(DATA.completeness, (DATA.source_summary || {}).missing || []);
  }
  function completenessBanner(c, missing) {
    var el = document.getElementById("completeness");
    if (!el) return;
    if (c === "COMPLETE") {
      el.className = "status-banner complete";
      el.textContent = "Source data COMPLETE — all verified core reports retrieved.";
      return;
    }
    if (c === "PARTIAL") {
      el.className = "status-banner partial";
      el.textContent = "Incomplete source data (PARTIAL): missing source(s) — " +
        (missing.length ? missing.join(", ") : "unknown") + ".";
      return;
    }
    el.className = "status-banner nodata";
    el.textContent = "NO source data available — this dashboard is incomplete, it is NOT a populated observability view.";
  }
  function healthCls(v) {
    if (v === "HEALTHY") return "ok";
    if (v === "DEGRADED") return "warn";
    if (v === "FAILED") return "bad";
    return "na";
  }
  function rateCls(v) { return v == null ? "na" : (v >= 90 ? "ok" : (v >= 70 ? "warn" : "bad")); }

  /* ---------- charts ---------- */
  function svgChart(id, series, opts) {
    opts = opts || {};
    var W = 760, H = 220, padL = 34, padB = 22, padT = 8, padR = 8;
    var iw = W - padL - padR, ih = H - padT - padB;

    // gather points
    var allX = [], allY = [];
    series.forEach(function (s) { s.points.forEach(function (p) { allX.push(p.x); allY.push(p.y); }); });
    if (!allX.length) { document.getElementById(id).innerHTML = '<div class="empty-chart">No data</div>'; return; }

    var minX = Math.min.apply(null, allX), maxX = Math.max.apply(null, allX);
    var minY = Math.min.apply(null, allY), maxY = Math.max.apply(null, allY);
    if (minX === maxX) maxX = minX + 1;
    if (minY === maxY) maxY = minY + 1;
    var spanX = maxX - minX, spanY = maxY - minY;
    function X(x) { return padL + ((x - minX) / spanX) * iw; }
    function Y(y) { return padT + ih - ((y - minY) / spanY) * ih; }

    var svg = '<svg class="chart" viewBox="0 0 ' + W + " " + H + '" role="img" aria-label="' + esc(opts.aria || "chart") + '">';
    // y gridlines
    for (var g = 0; g <= 4; g++) {
      var gy = padT + (g / 4) * ih;
      var val = maxY - (g / 4) * spanY;
      svg += '<line class="grid" x1="' + padL + '" y1="' + gy + '" x2="' + (W - padR) + '" y2="' + gy + '"/>';
      svg += '<text x="' + (padL - 6) + '" y="' + (gy + 3) + '" text-anchor="end">' + esc(trimNum(val)) + "</text>";
    }
    svg += '<line class="axis" x1="' + padL + '" y1="' + (H - padB) + '" x2="' + (W - padR) + '" y2="' + (H - padB) + '"/>';
    svg += '<line class="axis" x1="' + padL + '" y1="' + padT + '" x2="' + padL + '" y2="' + (H - padB) + '"/>';
    // x labels (up to 5)
    var labels = opts.xLabels || [];
    for (var li = 0; li <= 4; li++) {
      var xi = padL + (li / 4) * iw;
      if (labels.length) {
        var idx = Math.floor((li / 4) * (labels.length - 1));
        svg += '<text x="' + xi + '" y="' + (H - 6) + '" text-anchor="middle">' + esc(labels[idx]) + "</text>";
      }
    }
    series.forEach(function (s) {
      var path = "", area = "";
      s.points.forEach(function (p, i) {
        var px = X(p.x), py = Y(p.y);
        path += (i ? "L" : "M") + px + " " + py + " ";
        area += (i ? "L" : "M") + px + " " + py + " ";
      });
      if (s.points.length > 1) {
        area += "L" + X(s.points[s.points.length - 1].x) + " " + (H - padB) + "Z";
        svg += '<path class="area" d="' + area + '" fill="' + esc(s.color || "#45475a") + '" opacity="0.15"/>';
        svg += '<path class="line" d="' + path + '" stroke="' + esc(s.color || "#89b4fa") + '"/>';
      } else if (s.points.length === 1) {
        var p0 = s.points[0];
        svg += '<circle class="dot" cx="' + X(p0.x) + '" cy="' + Y(p0.y) + '" r="3.5" fill="' + esc(s.color || "#89b4fa") + '"/>';
      }
      s.points.forEach(function (p) {
        svg += '<circle class="dot" cx="' + X(p.x) + '" cy="' + Y(p.y) + '" r="2" fill="' + esc(s.color || "#89b4fa") + '"/>';
      });
    });
    svg += "</svg>";
    document.getElementById(id).innerHTML = svg;

    var legEl = document.getElementById("legend-" + (opts.legendId || id.replace("chart-", "")));
    if (legEl) {
      legEl.innerHTML = series.map(function (s) {
        return '<span><span class="sw" style="background:' + esc(s.color || "#89b4fa") + '"></span>' + esc(s.name) + "</span>";
      }).join("");
    }
  }
  function trimNum(n) {
    if (Math.abs(n) >= 1000) return Math.round(n).toString();
    return (Math.round(n * 100) / 100).toString();
  }

  /* ---------- health history ---------- */
  function renderHealth() {
    var hist = DATA.health_history || [];
    var series = [
      { name: "HEALTHY", color: "var(--green)", points: [] },
      { name: "DEGRADED", color: "var(--yellow)", points: [] },
      { name: "FAILED", color: "var(--red)", points: [] },
      { name: "UNKNOWN", color: "var(--surface2)", points: [] }
    ];
    var labels = [];
    hist.forEach(function (h) {
      var t = new Date(h.timestamp).getTime();
      var s = series.filter(function (x) { return x.name === h.state; })[0] || series[3];
      s.points.push({ x: t, y: 1 });
      labels.push(h.release + " " + h.timestamp.slice(0, 10));
    });
    // stack states as distinct y levels
    var byTime = {};
    hist.forEach(function (h) {
      var t = new Date(h.timestamp).getTime();
      if (!byTime[t]) byTime[t] = [];
      byTime[t].push(h.state);
    });
    var pts = Object.keys(byTime).sort().map(function (t) { return { x: +t, y: 1 }; });
    svgChart("chart-health", series, { aria: "Repository health over time", xLabels: labels, legendId: "health" });
    if (pts.length) {
      // fallback single-series dots if all same state
    }
  }

  /* ---------- publish activity ---------- */
  function renderPublish() {
    var hist = DATA.publish_history || [];
    var series = [
      { name: "unchanged", color: "var(--blue)", points: [] },
      { name: "uploaded", color: "var(--green)", points: [] },
      { name: "replaced", color: "var(--yellow)", points: [] },
      { name: "failed", color: "var(--red)", points: [] }
    ];
    var labels = [];
    hist.forEach(function (p) {
      var t = new Date(p.timestamp).getTime();
      series[0].points.push({ x: t, y: p.unchanged || 0 });
      series[1].points.push({ x: t, y: p.uploaded || 0 });
      series[2].points.push({ x: t, y: p.replaced || 0 });
      series[3].points.push({ x: t, y: p.failed || 0 });
      labels.push(p.release + " " + p.timestamp.slice(0, 10));
    });
    svgChart("chart-publish", series, { aria: "Publication activity over time", xLabels: labels, legendId: "publish" });
  }

  /* ---------- build duration ---------- */
  function renderBuild() {
    var hist = DATA.build_durations || [];
    var series = [{ name: "duration (s)", color: "var(--mauve)", points: [] }];
    var labels = [];
    hist.forEach(function (b) {
      series[0].points.push({ x: new Date(b.timestamp).getTime(), y: b.duration_seconds || 0 });
      labels.push(b.package);
    });
    svgChart("chart-build", series, { aria: "Build duration by package", xLabels: labels, legendId: "build" });
  }

  /* ---------- cache ---------- */
  function renderCache() {
    var hist = DATA.cache_history || [];
    var series = [
      { name: "hits", color: "var(--green)", points: [] },
      { name: "misses", color: "var(--yellow)", points: [] }
    ];
    var labels = [];
    hist.forEach(function (c) {
      var t = new Date(c.timestamp).getTime();
      series[0].points.push({ x: t, y: c.hits || 0 });
      series[1].points.push({ x: t, y: c.misses || 0 });
      labels.push(c.run || c.timestamp.slice(0, 10));
    });
    svgChart("chart-cache", series, { aria: "Cache hits and misses", xLabels: labels, legendId: "cache" });
  }

  /* ---------- inventory table ---------- */
  var currentFilter = "all", currentQuery = "", sortKey = "package", sortAsc = true;

  function renderTable() {
    var rows = DATA.packages || [];
    var tbl = document.getElementById("inventory-body");
    var body = rows.filter(function (r) {
      if (currentFilter !== "all" && r.update_type !== currentFilter) return false;
      if (currentQuery && String(r.package).toLowerCase().indexOf(currentQuery) < 0) return false;
      return true;
    });
    body.sort(function (a, b) {
      var av = a[sortKey], bv = b[sortKey];
      if (av == null) av = "";
      if (bv == null) bv = "";
      var c = sortKey === "current_version" || sortKey === "upstream_version"
        ? vercmpStr(av, bv) : String(av).localeCompare(String(bv));
      return sortAsc ? c : -c;
    });
    if (!body.length) {
      tbl.innerHTML = '<tr><td colspan="7" class="na-cell">No matching packages</td></tr>';
    } else {
      tbl.innerHTML = body.map(function (r) {
        var up = r.upstream_version || "";
        var statusCls = { UPDATE_AVAILABLE: "warn", SOURCE_CHANGED: "warn", REBUILD_REQUIRED: "warn", UP_TO_DATE: "good", CHECK_FAILED: "bad", UPSTREAM_UNAVAILABLE: "bad", UPSTREAM_ARCHIVED: "bad", MANUAL_REVIEW: "info", UNKNOWN: "mute" }[r.update_type] || "mute";
        return "<tr>" +
          '<td><a href="' + esc(r.upstream_url || "#") + '" target="_blank" rel="noopener">' + esc(r.package) + "</a></td>" +
          '<td class="mono">' + esc(fmt(r.current_version)) + (r.current_epoch ? ' <span class="na-cell">e' + esc(r.current_epoch) + "</span>" : "") + "</td>" +
          '<td class="mono">' + esc(fmt(up)) + "</td>" +
          '<td><span class="status-chip ' + statusCls + '">' + esc(fmt(r.update_type)) + "</span></td>" +
          '<td>' + esc(fmt(r.package_type)) + "</td>" +
          '<td class="mono">' + esc((r.checked_at || "").replace("T", " ").slice(0, 16)) + "</td>" +
          '<td>' + esc(fmt(r.note)) + "</td>" +
          "</tr>";
      }).join("");
    }
    txt("table-count", rows.length + " packages · " + body.length + " shown");
  }

  /* minimal non-lexical-ish version comparator fallback (vercmp done in
   * upstream data; here we compare numerically where possible) */
  function vercmpStr(a, b) {
    var pa = a.split(/[-:.]/).map(Number), pb = b.split(/[-:.]/).map(Number);
    for (var i = 0; i < Math.max(pa.length, pb.length); i++) {
      var x = pa[i] || 0, y = pb[i] || 0;
      if (x !== y) return x - y;
    }
    return 0;
  }

  function renderFilters() {
    var states = [];
    (DATA.packages || []).forEach(function (r) { if (states.indexOf(r.update_type) < 0) states.push(r.update_type); });
    states.sort();
    var el = document.getElementById("filters");
    el.innerHTML = '<button class="filter-btn active" data-state="all">All</button>' +
      states.map(function (s) { return '<button class="filter-btn" data-state="' + esc(s) + '">' + esc(s) + "</button>"; }).join("");
    el.querySelectorAll(".filter-btn").forEach(function (b) {
      b.addEventListener("click", function () {
        el.querySelectorAll(".filter-btn").forEach(function (x) { x.classList.remove("active"); });
        b.classList.add("active");
        currentFilter = b.getAttribute("data-state");
        renderTable();
      });
    });
  }

  function init() {
    renderKpis();
    renderHealth();
    renderPublish();
    renderBuild();
    renderCache();
    renderFilters();
    renderTable();
    document.getElementById("search").addEventListener("input", function (e) {
      currentQuery = e.target.value.trim().toLowerCase();
      renderTable();
    });
    document.querySelectorAll("#inventory thead th").forEach(function (th) {
      th.addEventListener("click", function () {
        var k = th.getAttribute("data-key");
        if (sortKey === k) { sortAsc = !sortAsc; } else { sortKey = k; sortAsc = true; }
        document.querySelectorAll("#inventory thead th").forEach(function (x) { x.classList.remove("sorted", "asc"); });
        th.classList.add("sorted");
        if (sortAsc) th.classList.add("asc");
        renderTable();
      });
    });
  }

  document.addEventListener("DOMContentLoaded", init);
})();
