"use strict";
// Shared lifecycle semantics, also imported by the offline Node tests.
const Assessment = (() => {
  const severity = { Critical: 4, High: 3, Medium: 2, Low: 1, Unknown: 0 };
  const stats = (rows) => {
    const passed = rows.filter((r) => r.outcome === "Pass").length,
      failed = rows.filter((r) => r.outcome === "Fail").length;
    return {
      total: rows.length,
      passed,
      failed,
      errors: rows.filter((r) => r.outcome === "Error").length,
      ignored: rows.filter((r) => r.outcome === "Ignore").length,
      applicable: passed + failed,
      compliance:
        passed + failed
          ? +((100 * passed) / (passed + failed)).toFixed(1)
          : null,
      rules: new Set(rows.map((r) => r.ruleName)).size,
      resources: new Set(rows.map((r) => r.resourceKey)).size,
    };
  };
  const comparisonEvidence = (before, after) => {
    const limitations = [];
    if (before.organization !== after.organization)
      limitations.push("Organization differs.");
    if (
      !before.configurationHash ||
      before.configurationHash !== after.configurationHash
    )
      limitations.push("Assessment configuration or baseline differs.");
    if (
      !before.module ||
      !after.module ||
      !before.module.version ||
      before.module.version === "Unknown" ||
      before.module.version !== after.module.version
    )
      limitations.push("Rule module version differs or is unknown.");
    if (
      before.evaluation?.Status !== "Completed" ||
      after.evaluation?.Status !== "Completed" ||
      before.results.some((r) => r.outcome === "Error") ||
      after.results.some((r) => r.outcome === "Error")
    )
      limitations.push(
        "Rule evaluation is incomplete, failed or unknown; lifecycle comparison is unverified.",
      );
    if (before.legacy || after.legacy)
      limitations.push("Legacy evidence has no verified checkpoint identity.");
    if (
      !before.collection ||
      !after.collection ||
      before.collection.Status !== "Complete" ||
      after.collection.Status !== "Complete"
    )
      limitations.push("Collection coverage is incomplete or unknown.");
    for (const snapshot of [before, after]) {
      if (
        !snapshot.configuration?.baseline ||
        !snapshot.configuration?.rulesetHash ||
        snapshot.configuration.baseline === "Unknown" ||
        snapshot.configuration.rulesetHash === "Unknown"
      )
        limitations.push("Baseline or ruleset identity is unknown.");
    }
    const a = new Map(),
      b = new Map();
    for (const [snapshot, map] of [
      [before, a],
      [after, b],
    ])
      for (const row of snapshot.results) {
        if (map.has(row.fingerprint))
          limitations.push(
            "Duplicate checkpoint identity; comparison is ambiguous.",
          );
        map.set(row.fingerprint, row);
      }
    return { limitations, a, b };
  };
  const compare = (before, after, earlier = []) => {
    const { limitations, a, b } = comparisonEvidence(before, after);
    const lifecycle = {
      new: [],
      resolved: [],
      persistent: [],
      recurring: [],
      unverified: [],
      scope: [],
    };
    const comparable = [];
    const compatible = !limitations.length;
    const priorFailures = new Set();
    if (compatible) {
      for (const snapshot of earlier) {
        const evidence = comparisonEvidence(snapshot, before);
        if (evidence.limitations.length) continue;
        for (const row of evidence.a.values()) {
          if (row.identityComplete === true && row.outcome === "Fail")
            priorFailures.add(row.fingerprint);
        }
      }
    }
    for (const key of new Set([...a.keys(), ...b.keys()])) {
      const old = a.get(key),
        current = b.get(key);
      if (!old || !current) {
        lifecycle.scope.push(current || old);
        continue;
      }
      if (!compatible) {
        if (old.outcome === "Fail" || current.outcome === "Fail")
          lifecycle.unverified.push(current);
        continue;
      }
      if (old.identityComplete !== true || current.identityComplete !== true) {
        lifecycle.unverified.push(current);
        continue;
      }
      if (
        !["Pass", "Fail"].includes(old.outcome) ||
        !["Pass", "Fail"].includes(current.outcome)
      ) {
        lifecycle.scope.push(current);
        continue;
      }
      comparable.push([old, current]);
      if (old.outcome === "Fail" && current.outcome === "Pass")
        lifecycle.resolved.push(current);
      if (old.outcome === "Fail" && current.outcome === "Fail")
        lifecycle.persistent.push(current);
      if (old.outcome === "Pass" && current.outcome === "Fail") {
        const recurring = priorFailures.has(key);
        lifecycle[recurring ? "recurring" : "new"].push(current);
      }
    }
    if (compatible && lifecycle.unverified.length)
      limitations.push(
        `${lifecycle.unverified.length} checkpoints have incomplete identities; their lifecycle is unverified.`,
      );
    if (lifecycle.scope.length)
      limitations.push(
        `${lifecycle.scope.length} checkpoints changed scope or applicability; absent evidence is never classified as resolved or new.`,
      );
    return {
      compatible,
      limitations,
      lifecycle,
      comparable,
      before: stats(comparable.map((p) => p[0])),
      after: stats(comparable.map((p) => p[1])),
    };
  };
  return { severity, stats, compare };
})();
if (typeof module !== "undefined") module.exports = Assessment;
if (typeof document !== "undefined")
  (() => {
    const report = JSON.parse(
        document.getElementById("report-data").textContent,
      ),
      results = report.results;
    const $ = (id) => document.getElementById(id);
    const snapshotStats = (snapshot) => ({
      ...Assessment.stats(snapshot.results),
      ...(snapshot.legacy ? { compliance: null } : {}),
    });
    function el(tag, text, cls) {
      const node = document.createElement(tag);
      if (text !== undefined) node.textContent = text;
      if (cls) node.className = cls;
      return node;
    }
    function button(text, action) {
      const node = el("button", text);
      node.type = "button";
      node.onclick = action;
      return node;
    }
    function panel(title, parent = $("view")) {
      const node = el("section", undefined, "panel");
      node.append(el("h2", title));
      parent.append(node);
      return node;
    }
    function table(parent, headings, rows) {
      const wrap = el("div", undefined, "table-scroll"),
        t = el("table"),
        head = el("tr");
      headings.forEach((h) => head.append(el("th", h)));
      const thead = el("thead");
      thead.append(head);
      t.append(thead);
      const body = el("tbody");
      let tablePage = 0;
      const pages = Math.max(1, Math.ceil(rows.length / 50));
      const pager = el("div", undefined, "pagination");
      const previous = button("Previous rows", () => {
        tablePage--;
        drawRows();
      });
      const next = button("Next rows", () => {
        tablePage++;
        drawRows();
      });
      const info = el("span");
      pager.append(previous, info, next);
      function drawRows() {
        body.replaceChildren();
        for (const cells of rows.slice(tablePage * 50, tablePage * 50 + 50)) {
          const tr = el("tr");
          cells.forEach((value) => {
            const td = el("td");
            if (value instanceof Node) td.append(value);
            else td.textContent = String(value ?? "Unavailable");
            tr.append(td);
          });
          body.append(tr);
        }
        previous.disabled = tablePage === 0;
        next.disabled = tablePage === pages - 1;
        info.textContent = `Rows ${tablePage * 50 + 1}–${Math.min(rows.length, tablePage * 50 + 50)} of ${rows.length}`;
      }
      drawRows();
      t.append(body);
      wrap.append(t);
      parent.append(wrap);
      if (pages > 1) parent.append(pager);
      return body;
    }
    function cards(parent, rows, ids = false) {
      parent.replaceChildren();
      const s = Assessment.stats(rows);
      for (const [key, label] of Object.entries({
        total: "Total checkpoints",
        passed: "Passed checkpoints",
        failed: "Failed checkpoints",
        ignored: "Ignored",
        errors: "Error checkpoints",
        applicable: "Applicable",
        compliance: "Compliance",
        rules: "Rules",
        resources: "Resources",
      })) {
        const card = el("div", undefined, "card"),
          value = el(
            "strong",
            key === "compliance"
              ? s[key] === null
                ? "Unavailable"
                : `${s[key]}%`
              : s[key],
          );
        if (ids) value.id = key;
        card.append(el("span", label), value);
        parent.append(card);
      }
    }
    $("run-info").textContent =
      `${report.organization} · Run ${report.runId} · ${report.timestamp} · Rules ${report.module.version}`;
    cards($("global-metrics"), results);
    $("collection").textContent =
      `Collection: ${report.collection.Status}. Evaluation: ${report.evaluation?.Status || "Unknown"}. Check failures are separate from collection and evaluation errors.`;
    $("collection-detail").textContent = JSON.stringify(
      report.collection,
      null,
      2,
    );
    $("theme").onchange = () => {
      if ($("theme").value === "auto")
        document.documentElement.removeAttribute("data-theme");
      else document.documentElement.dataset.theme = $("theme").value;
    };
    const fields = ["project", "targetType", "category", "outcome", "severity"];
    for (const field of fields)
      for (const value of [...new Set(results.map((r) => r[field]))].sort()) {
        const option = el("option", value);
        option.value = value;
        $(field).append(option);
      }
    let projectSort = "risk";
    let view = "Overview",
      page = 0,
      group = "",
      sort = "risk",
      ruleFilter = null,
      resourceFilter = null,
      lifecycleFilter = null,
      detail = null;
    const previous = [];
    const views = [
      "Overview",
      "Risk & Compliance",
      "Projects & Resources",
      "Findings Explorer",
      "Evolution",
      "Maturity",
    ];
    function save() {
      previous.push({
        view,
        page,
        group,
        sort,
        projectSort,
        filters: fields.map((f) => $(f).value),
        search: $("search").value,
        ruleFilter,
        resourceFilter,
        lifecycleFilter,
        detail,
      });
    }
    function navigate(name) {
      save();
      view = name;
      page = 0;
      detail = null;
      if (name === "Findings Explorer" && !$("outcome").value)
        $("outcome").value = "Fail";
      render();
    }
    for (const name of views)
      $("navigation").append(button(name, () => navigate(name)));
    function drill(field, value) {
      save();
      if (fields.includes(field)) $(field).value = value;
      else if (field === "ruleName") ruleFilter = value;
      else resourceFilter = value;
      view = "Findings Explorer";
      detail = null;
      page = 0;
      render();
    }
    function selection() {
      const query = $("search").value.toLocaleLowerCase();
      return results.filter(
        (r) =>
          fields.every((f) => !$(f).value || r[f] === $(f).value) &&
          (!ruleFilter || r.ruleName === ruleFilter) &&
          (!resourceFilter || r.resourceKey === resourceFilter) &&
          (!lifecycleFilter || lifecycleFilter.has(r.fingerprint)) &&
          (!query ||
            Object.values(r)
              .filter((v) => typeof v === "string")
              .join(" ")
              .toLocaleLowerCase()
              .includes(query)),
      );
    }
    function reset() {
      fields.forEach((f) => ($(f).value = ""));
      $("search").value = "";
      ruleFilter = resourceFilter = lifecycleFilter = detail = null;
      page = 0;
      render();
    }
    $("reset").onclick = () => {
      save();
      reset();
    };
    $("back").onclick = () => {
      const old = previous.pop();
      if (!old) return;
      ({
        view,
        page,
        group,
        sort,
        projectSort,
        ruleFilter,
        resourceFilter,
        lifecycleFilter,
        detail,
      } = old);
      fields.forEach((f, i) => ($(f).value = old.filters[i]));
      $("search").value = old.search;
      render();
    };
    [...fields, "search"].forEach((f) =>
      $(f).addEventListener(f === "search" ? "input" : "change", () => {
        page = 0;
        detail = null;
        render();
      }),
    );
    function groups(rows, field) {
      const map = new Map();
      for (const r of rows) {
        const key = r[field];
        if (!map.has(key)) map.set(key, []);
        map.get(key).push(r);
      }
      return [...map].sort(
        (a, b) =>
          b[1].reduce(
            (v, r) =>
              Math.max(
                v,
                r.outcome === "Fail" ? Assessment.severity[r.severity] || 0 : 0,
              ),
            0,
          ) -
            a[1].reduce(
              (v, r) =>
                Math.max(
                  v,
                  r.outcome === "Fail"
                    ? Assessment.severity[r.severity] || 0
                    : 0,
                ),
              0,
            ) ||
          new Set(b[1].map((r) => r.resourceKey)).size -
            new Set(a[1].map((r) => r.resourceKey)).size ||
          a[0].localeCompare(b[0]),
      );
    }
    function bars(title, rows, field, id, frequency = false) {
      const node = panel(title),
        container = el("div");
      if (id) container.id = id;
      node.append(container);
      const ranked = groups(
          rows.filter((r) => r.outcome === "Fail"),
          field,
        )
          .sort((a, b) => (frequency ? b[1].length - a[1].length : 0))
          .slice(0, 12),
        max = Math.max(1, ...ranked.map((g) => g[1].length));
      if (!ranked.length)
        container.append(el("p", "No failures in this selection."));
      for (const [key, items] of ranked) {
        const line = el("div", undefined, "bar-row"),
          track = el("div", undefined, "bar-track"),
          bar = el("div", undefined, "bar"),
          label = button(
            field === "resourceKey"
              ? `${items[0].project} / ${items[0].resourceName}`
              : key,
            () => drill(field, key),
          );
        label.className = "bar-label";
        bar.style.width = `${(100 * items.length) / max}%`;
        track.append(bar);
        line.append(label, track, el("span", items.length));
        container.append(line);
      }
    }
    function explorer(rows) {
      if (detail) {
        const n = panel(
          detail.displayName === "Unknown"
            ? detail.ruleName
            : detail.displayName,
        );
        n.append(
          button("Back to findings", () => {
            detail = null;
            render();
          }),
          el(
            "p",
            `${detail.outcome} · ${detail.severity} · ${detail.project} / ${detail.resourceName}`,
          ),
        );
        for (const [title, value] of [
          ["Description", detail.description],
          ["Failure reason", detail.reason],
          ["Recommendation", detail.recommendation],
        ]) {
          n.append(
            el("h3", title),
            el("p", value || "Not supplied by the rule metadata.", "detail"),
          );
        }
        for (const link of [
          { title: "Rule documentation", url: detail.documentation },
          ...(detail.references || []),
        ]) {
          try {
            const url = new URL(link.url);
            if (url.protocol !== "https:" && url.protocol !== "http:") continue;
            const a = el("a", link.title);
            a.href = url.href;
            a.target = "_blank";
            a.rel = "noopener noreferrer";
            n.append(a, el("br"));
          } catch {}
        }
        return;
      }
      const n = panel("Findings Explorer"),
        tools = el("div", undefined, "toolbar"),
        groupSelect = el("select"),
        sortSelect = el("select");
      groupSelect.setAttribute("aria-label", "Group findings");
      sortSelect.setAttribute("aria-label", "Sort findings");
      for (const [key, text] of [
        ["", "Individual findings"],
        ["ruleName", "Rule"],
        ["project", "Project"],
        ["resourceKey", "Resource"],
        ["category", "Category"],
      ]) {
        const o = el("option", text);
        o.value = key;
        groupSelect.append(o);
      }
      groupSelect.value = group;
      groupSelect.onchange = () => {
        group = groupSelect.value;
        sort = "risk";
        page = 0;
        render();
      };
      for (const [key, text] of group
        ? [
            ["risk", "Severity and affected scope"],
            ["name", "Group name"],
            ["compliance", "Compliance ascending"],
          ]
        : [
            ["risk", "Severity and affected scope"],
            ["ruleName", "Rule name"],
            ["project", "Project"],
            ["outcome", "Outcome"],
          ]) {
        const o = el("option", text);
        o.value = key;
        sortSelect.append(o);
      }
      sortSelect.value = sort;
      sortSelect.onchange = () => {
        sort = sortSelect.value;
        page = 0;
        render();
      };
      tools.append(groupSelect, sortSelect);
      n.append(tools);
      const entries = group
        ? groups(rows, group).sort((a, b) =>
            sort === "compliance"
              ? (Assessment.stats(a[1]).compliance ?? 101) -
                (Assessment.stats(b[1]).compliance ?? 101)
              : sort === "name"
                ? a[0].localeCompare(b[0])
                : 0,
          )
        : [...rows].sort((a, b) =>
            sort === "risk"
              ? (Assessment.severity[b.severity] || 0) -
                  (Assessment.severity[a.severity] || 0) ||
                a.ruleName.localeCompare(b.ruleName)
              : a[sort].localeCompare(b[sort]),
          );
      const pages = Math.max(1, Math.ceil(entries.length / 50));
      page = Math.min(page, pages - 1);
      n.append(
        el(
          "p",
          `${rows.length} checkpoints · ${entries.length} ${group ? "groups" : "findings"}`,
        ),
      );
      const visible = entries.slice(page * 50, page * 50 + 50);
      const body = group
        ? table(
            n,
            ["Group", "Checkpoints", "Failed", "Compliance"],
            visible.map(([key, items]) => {
              const s = Assessment.stats(items);
              return [
                button(
                  group === "resourceKey" ? items[0].resourceName : key,
                  () => drill(group, key),
                ),
                s.total,
                s.failed,
                s.compliance === null ? "Unavailable" : `${s.compliance}%`,
              ];
            }),
          )
        : table(
            n,
            ["Outcome", "Severity", "Category", "Project", "Rule", "Resource"],
            visible.map((r) => [
              r.outcome,
              r.severity,
              r.category,
              button(r.project, () => drill("project", r.project)),
              button(
                r.displayName === "Unknown" ? r.ruleName : r.displayName,
                () => {
                  detail = r;
                  render();
                },
              ),
              button(r.resourceName, () => drill("resourceKey", r.resourceKey)),
            ]),
          );
      body.id = "findings";
      if (!entries.length) {
        const tr = el("tr"),
          td = el("td", "No results match these filters.");
        td.colSpan = 6;
        tr.append(td);
        body.append(tr);
      }
      const pagination = el("div", undefined, "pagination"),
        prev = button("Previous", () => {
          page--;
          render();
        }),
        next = button("Next", () => {
          page++;
          render();
        }),
        info = el("span", `Page ${page + 1} of ${pages}`);
      prev.id = "previous";
      next.id = "next";
      info.id = "page-info";
      prev.disabled = page === 0;
      next.disabled = page >= pages - 1;
      pagination.append(prev, info, next);
      n.append(pagination);
    }
    function projects(rows) {
      const n = panel("Project comparison · normalized compliance");
      const order = el("select");
      order.setAttribute("aria-label", "Sort projects");
      for (const [key, label] of [
        ["risk", "Highest failing severity"],
        ["compliance", "Compliance ascending"],
        ["project", "Project name"],
      ]) {
        const option = el("option", label);
        option.value = key;
        order.append(option);
      }
      order.value = projectSort;
      order.onchange = () => {
        projectSort = order.value;
        render();
      };
      n.append(order);
      const rankedProjects = groups(rows, "project");
      if (projectSort === "compliance")
        rankedProjects.sort(
          (a, b) =>
            (Assessment.stats(a[1]).compliance ?? 101) -
            (Assessment.stats(b[1]).compliance ?? 101),
        );
      if (projectSort === "project")
        rankedProjects.sort((a, b) => a[0].localeCompare(b[0]));
      table(
        n,
        [
          "Project",
          "Applicable",
          "Compliance",
          "Failed",
          "Highest failing severity",
          "Resources",
        ],
        rankedProjects.map(([project, items]) => {
          const s = Assessment.stats(items),
            fails = items
              .filter((r) => r.outcome === "Fail")
              .sort(
                (a, b) =>
                  (Assessment.severity[b.severity] || 0) -
                  (Assessment.severity[a.severity] || 0),
              );
          return [
            button(project, () => drill("project", project)),
            s.applicable,
            s.compliance === null ? "Unavailable" : `${s.compliance}%`,
            s.failed,
            fails[0]?.severity || "None",
            s.resources,
          ];
        }),
      );
      const types = panel("Compliance by resource type");
      table(
        types,
        ["Type", "Applicable", "Compliance", "Failed"],
        groups(rows, "targetType").map(([type, items]) => {
          const s = Assessment.stats(items);
          return [
            button(type, () => drill("targetType", type)),
            s.applicable,
            s.compliance === null ? "Unavailable" : `${s.compliance}%`,
            s.failed,
          ];
        }),
      );
      bars(
        "Resource-level risk: severity, then affected scope",
        rows,
        "resourceKey",
        "resource-chart",
      );
    }
    function heatmap(rows) {
      const n = panel("Project × category · failed / applicable"),
        categories = [...new Set(rows.map((r) => r.category))].sort();
      table(
        n,
        ["Project", ...categories],
        groups(rows, "project").map(([project, items]) => [
          button(project, () => drill("project", project)),
          ...categories.map((category) => {
            const s = Assessment.stats(
              items.filter((r) => r.category === category),
            );
            const b = button(
              s.applicable
                ? `${s.failed} / ${s.applicable} (${s.compliance}%)`
                : "Unavailable",
              () => {
                save();
                $("project").value = project;
                $("category").value = category;
                view = "Findings Explorer";
                render();
              },
            );
            if (s.failed) b.className = "heat";
            return b;
          }),
        ]),
      );
    }
    function evolution() {
      const history = report.history || { snapshots: [], limitations: [] },
        runs = [
          ...history.snapshots.filter((s) => s.runId !== report.runId),
          report,
        ].sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp)),
        n = panel("Assessment evolution");
      for (const text of history.limitations) n.append(el("p", text, "notice"));
      n.append(
        el(
          "p",
          "Historical views use all checkpoints. Current selection filters apply to the other views. Raw trends can reflect changes in scope; use matched population metrics below.",
        ),
      );
      if (runs.length < 2) {
        n.append(
          el(
            "p",
            "No prior assessment is available. Publish and retain psrule-results artifacts to enable comparisons.",
          ),
        );
        return;
      }
      const tools = el("div", undefined, "toolbar"),
        before = el("select"),
        after = el("select");
      before.id = "compare-before";
      after.id = "compare-after";
      before.setAttribute("aria-label", "Earlier run");
      after.setAttribute("aria-label", "Later run");
      for (const [i, s] of runs.entries())
        for (const select of [before, after]) {
          const o = el("option", `${s.runId} · ${s.timestamp}`);
          o.value = i;
          select.append(o);
        }
      before.value = runs.length - 2;
      after.value = runs.length - 1;
      tools.append(before, after);
      n.append(tools);
      const comparison = el("div");
      n.append(comparison);
      const trend = panel("Compliance trend · raw totals"),
        svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("viewBox", "0 0 900 220");
      svg.setAttribute("role", "img");
      svg.setAttribute(
        "aria-label",
        "Historical compliance trend. Values are also listed in the table.",
      );
      const points = [];
      runs.forEach((s, i) => {
        const stat = snapshotStats(s);
        if (stat.compliance === null) return;
        const x = 40 + (i * 820) / Math.max(1, runs.length - 1),
          y = 190 - stat.compliance * 1.5;
        points.push(`${x},${y}`);
        const circle = document.createElementNS(svg.namespaceURI, "circle");
        circle.setAttribute("cx", x);
        circle.setAttribute("cy", y);
        circle.setAttribute("r", "6");
        circle.setAttribute("tabindex", "0");
        circle.setAttribute("aria-label", `${s.runId}: ${stat.compliance}%`);
        const select = () => {
          after.value = i;
          draw();
        };
        circle.onclick = select;
        circle.onkeydown = (e) => {
          if (e.key === "Enter") select();
        };
        const title = document.createElementNS(svg.namespaceURI, "title");
        title.textContent = `${s.runId}: ${stat.compliance}%`;
        circle.append(title);
        svg.append(circle);
      });
      const line = document.createElementNS(svg.namespaceURI, "polyline");
      line.setAttribute("points", points.join(" "));
      svg.prepend(line);
      trend.append(svg);
      table(
        trend,
        [
          "Run",
          "Compliance",
          "Passed",
          "Failed",
          "Collection",
          "Evaluation",
          "Critical / High / Medium / Low",
        ],
        runs.map((s) => {
          const stat = snapshotStats(s);
          return [
            button(s.runId, () => {
              after.value = runs.indexOf(s);
              draw();
            }),
            stat.compliance === null ? "Unavailable" : `${stat.compliance}%`,
            stat.passed,
            stat.failed,
            s.collection?.Status || "Unknown",
            s.evaluation?.Status || "Unknown",
            ["Critical", "High", "Medium", "Low"]
              .map(
                (v) =>
                  s.results.filter(
                    (r) => r.outcome === "Fail" && r.severity === v,
                  ).length,
              )
              .join(" / "),
          ];
        }),
      );
      function draw() {
        comparison.replaceChildren();
        const a = runs[+before.value],
          b = runs[+after.value];
        if (new Date(a.timestamp) >= new Date(b.timestamp)) {
          comparison.append(
            el("p", "Select two distinct runs in chronological order."),
          );
          return;
        }
        const c = Assessment.compare(
          a,
          b,
          runs.filter((s) => new Date(s.timestamp) < new Date(a.timestamp)),
        );
        comparison.append(
          el(
            "h3",
            c.compatible
              ? "Matched checkpoint comparison"
              : "Comparison unavailable",
          ),
          el(
            "p",
            `Matched applicable checkpoints: ${c.comparable.length}. Comparable compliance: ${c.before.compliance ?? "Unavailable"} → ${c.after.compliance ?? "Unavailable"}.`,
          ),
        );
        c.limitations.forEach((t) => comparison.append(el("p", t, "notice")));
        for (const [state, items] of Object.entries(c.lifecycle)) {
          comparison.append(el("h3", `${state}: ${items.length}`));
          if (items.length) {
            const open = button("Explore underlying findings", () => {
              const p = panel(`${state} · ${b.runId}`);
              table(
                p,
                ["Rule", "Project", "Resource", "Outcome"],
                items.map((r) => [
                  r.ruleName,
                  r.project,
                  r.resourceName,
                  r.outcome,
                ]),
              );
            });
            comparison.append(open);
          }
        }
        for (const field of ["project", "ruleName", "resourceKey"]) {
          const oldGroups = new Map(groups(a.results, field)),
            newGroups = new Map(groups(b.results, field));
          const keys = [...new Set([...oldGroups.keys(), ...newGroups.keys()])];
          comparison.append(
            el("h3", `${field} evolution · raw assessment totals`),
          );
          table(
            comparison,
            [
              field,
              "Earlier compliance",
              "Later compliance",
              "Earlier failures",
              "Later failures",
            ],
            keys.map((key) => {
              const x = snapshotStats({
                  ...a,
                  results: oldGroups.get(key) || [],
                }),
                y = snapshotStats({
                  ...b,
                  results: newGroups.get(key) || [],
                });
              return [
                key,
                x.compliance === null ? "Unavailable" : `${x.compliance}%`,
                y.compliance === null ? "Unavailable" : `${y.compliance}%`,
                x.failed,
                y.failed,
              ];
            }),
          );
        }
      }
      before.onchange = after.onchange = draw;
      draw();
    }
    function render() {
      for (const b of $("navigation").children)
        b.setAttribute(
          "aria-current",
          b.textContent === view ? "page" : "false",
        );
      $("back").disabled = !previous.length;
      const rows = selection();
      cards($("selection-metrics"), rows, true);
      $("view").replaceChildren();
      if (view === "Findings Explorer") explorer(rows);
      else if (view === "Projects & Resources") projects(rows);
      else if (view === "Evolution") evolution();
      else if (view === "Maturity") {
        const n = panel("DevOps maturity · evidence unavailable");
        n.append(
          el(
            "p",
            "The 0–4 maturity model requires People, Process and Technology evidence from technical assessments, knowledge-transfer sessions and documentation analysis. PSRule compliance is not a maturity score.",
          ),
          el("pre", JSON.stringify(report.maturity, null, 2)),
        );
      } else {
        bars("Failing severity distribution", rows, "severity");
        bars("Findings by category", rows, "category");
        bars(
          "Prioritized controls · severity, then affected resources",
          rows,
          "ruleName",
          "rule-chart",
        );
        bars(
          "Resource risk distribution",
          rows,
          "resourceKey",
          "resource-chart",
        );
        if (view === "Risk & Compliance") {
          bars(
            "Most frequently violated controls",
            rows,
            "ruleName",
            null,
            true,
          );
          heatmap(rows);
        } else {
          const n = panel("Prioritized areas");
          n.append(
            el(
              "p",
              "Controls are ordered by highest severity, then affected resource count. No composite risk score is calculated.",
            ),
          );
          n.append(
            button("Investigate failed controls", () =>
              navigate("Findings Explorer"),
            ),
            button("Compare projects", () => navigate("Projects & Resources")),
            button("Review historical evolution", () => navigate("Evolution")),
          );
        }
      }
    }
    render();
  })();
