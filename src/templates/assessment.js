(() => {
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
        limitations.push(
          "Legacy evidence has no verified checkpoint identity.",
        );
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
        if (
          old.identityComplete !== true ||
          current.identityComplete !== true
        ) {
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
  // Project Health presentation and calculations. Version 1 evidence remains readable.
  const ProjectHealth = (() => {
    const categories = [
      "Repos",
      "Pipelines",
      "Service Connections",
      "Environments",
      "Variable Groups",
      "Projects",
      "Retention Settings",
      "Organization",
    ];
    const stats = (rows) => Assessment.stats(rows);
    const band = (value) =>
      value === null
        ? "Unavailable"
        : value < 50
          ? "Critical"
          : value < 70
            ? "At risk"
            : value < 90
              ? "Fair"
              : "Healthy";
    const bandClass = (value) =>
      value === 100
        ? "ph-perfect"
        : {
            Critical: "ph-critical",
            "At risk": "ph-at-risk",
            Fair: "ph-fair",
            Healthy: "ph-healthy",
          }[band(value)] || "";
    function normalize(input) {
      const rules = { ...input.rules };
      for (const r of input.results || [])
        if (!Array.isArray(r) && !rules[r.ruleName])
          rules[r.ruleName] = Object.fromEntries(
            [
              "displayName",
              "category",
              "severity",
              "description",
              "recommendation",
              "documentation",
              "references",
            ].map((k) => [k, r[k]]),
          );
      const category = (value) =>
        input.categoryMap?.[value] || value || "Unknown";
      function snapshot(source) {
        const incomplete = new Set(source.identityIncomplete || []);
        const results = (source.results || []).map((r) =>
          Array.isArray(r)
            ? {
                ...rules[r[3]],
                fingerprint: r[0],
                project: r[1],
                category: category(r[2]),
                ruleName: r[3],
                outcome: r[4],
                identityComplete: !source.legacy && !incomplete.has(r[0]),
              }
            : {
                ...r,
                category: category(r.category),
                ...Object.fromEntries(
                  Object.entries(rules[r.ruleName] || {}).filter(
                    ([key]) => !Object.hasOwn(r, key) && key !== "category",
                  ),
                ),
              },
        );
        return {
          ...source,
          configuration: source.configuration || {
            baseline: "Unknown",
            rulesetHash: source.rulesetHash,
          },
          results,
        };
      }
      const current = snapshot(input);
      const history = (input.history?.snapshots || [])
        .filter((s) => s.runId !== input.runId)
        .map(snapshot);
      return {
        ...current,
        rules,
        categoryMap: input.categoryMap || {},
        collectorCategoryMap: input.collectorCategoryMap || {},
        effort: input.effort || {
          categoryDefaults: {},
          ruleOverrides: {},
          source: "No effort configuration",
        },
        settings: {
          sharedOpportunityMinimum: 3,
          quickWinThreshold: 70,
          ...input.settings,
        },
        history: {
          snapshots: history,
          limitations: input.history?.limitations || [],
        },
      };
    }
    function collectionState(snapshot, project, category, map) {
      if (project === "(organization)") {
        const evidence = snapshot.collection?.OrganizationCollection;
        return evidence?.Status === "Completed" ||
          evidence?.Status === "Complete"
          ? "collected"
          : "not collected";
      }
      const commands = Object.keys(map).filter(
        (command) => map[command] === category,
      );
      if (!commands.length) return "not collected";
      const projectEvidence = snapshot.collection?.Projects?.find(
        (p) => p.Project === project,
      );
      const collectors = commands.map((command) =>
        projectEvidence?.Collectors?.find((c) => c.Command === command),
      );
      if (
        collectors.some(
          (c) =>
            !c ||
            !(
              c.Status === "Completed" ||
              (c.Status === "Empty" &&
                c.ReasonCodes?.includes("EmptyCollection"))
            ),
        )
      )
        return "not collected";
      if (collectors.every((c) => c.Status === "Empty")) {
        return snapshot.results.some(
          (r) => r.project === project && r.category === category,
        )
          ? "not collected"
          : "not applicable";
      }
      return "collected";
    }
    function effortFor(rule, category, config) {
      if (Object.hasOwn(config.ruleOverrides || {}, rule))
        return {
          value: config.ruleOverrides[rule],
          source: `Rule override: ${rule}`,
        };
      if (Object.hasOwn(config.categoryDefaults || {}, category))
        return {
          value: config.categoryDefaults[category],
          source: `Category default: ${category}`,
        };
      return { value: "Unknown", source: "Not configured" };
    }
    function projectSummary(rows, config, threshold = 70) {
      const measured = stats(rows),
        failing = rows.filter((r) => r.outcome === "Fail");
      const controls = [...new Set(failing.map((r) => r.ruleName))];
      const efforts = controls.map((rule) =>
        effortFor(
          rule,
          failing.find((r) => r.ruleName === rule).category,
          config,
        ),
      );
      const outstanding = controls.length;
      let tier, justification;
      if (!outstanding) {
        tier = "Compliant";
        justification =
          "No outstanding controls in the selected assessment scope.";
      } else if (efforts.some((e) => e.value === "Unknown")) {
        tier = "Needs estimate";
        justification = "At least one outstanding control has Unknown effort.";
      } else if (
        measured.compliance >= threshold &&
        !efforts.some((e) => e.value === "High")
      ) {
        tier = "Quick win";
        justification = `Compliance is at least ${threshold}% and no outstanding control has High or Unknown effort.`;
      } else {
        tier = "Planned";
        justification = efforts.some((e) => e.value === "High")
          ? "Includes High-effort controls."
          : `Compliance is below ${threshold}%.`;
      }
      return {
        ...measured,
        outstanding,
        controls,
        efforts,
        tier,
        justification,
      };
    }
    const hasEffortEstimates = (rows, config) =>
      rows.some(
        (r) =>
          r.outcome === "Fail" &&
          effortFor(r.ruleName, r.category, config).value !== "Unknown",
      );
    function measuredProjects(projects, rows, minimum = 3) {
      const sharedRules = new Set(shared(rows, minimum).map((r) => r.rule));
      return projects
        .map((p) => {
          const failing = rows.filter(
            (r) => r.project === p.project && r.outcome === "Fail",
          );
          const severityRank = Math.max(
            0,
            ...failing.map((r) => Assessment.severity[r.severity] || 0),
          );
          return {
            ...p,
            severityRank,
            highestSeverity: failing.length
              ? Object.keys(Assessment.severity).find(
                  (key) => Assessment.severity[key] === severityRank,
                )
              : "None",
            sharedControls: p.controls.filter((rule) => sharedRules.has(rule))
              .length,
          };
        })
        .sort(
          (a, b) =>
            Number(b.outstanding > 0) - Number(a.outstanding > 0) ||
            b.severityRank - a.severityRank ||
            b.sharedControls - a.sharedControls ||
            a.outstanding - b.outstanding ||
            (a.compliance ?? 101) - (b.compliance ?? 101) ||
            a.project.localeCompare(b.project),
        );
    }
    const tiers = {
      "Quick win": 0,
      Planned: 1,
      "Needs estimate": 2,
      Compliant: 3,
    };
    const orderProjects = (rows) =>
      [...rows].sort(
        (a, b) =>
          tiers[a.tier] - tiers[b.tier] ||
          a.outstanding - b.outstanding ||
          (b.compliance ?? -1) - (a.compliance ?? -1) ||
          a.project.localeCompare(b.project),
      );
    function shared(rows, minimum = 3) {
      const groups = new Map();
      for (const r of rows)
        if (r.outcome === "Fail" && r.project !== "(organization)") {
          if (!groups.has(r.ruleName)) groups.set(r.ruleName, new Set());
          groups.get(r.ruleName).add(r.project);
        }
      return [...groups]
        .map(([rule, projects]) => ({
          rule,
          projects: [...projects],
          count: projects.size,
        }))
        .filter((r) => r.count >= minimum)
        .sort((a, b) => b.count - a.count || a.rule.localeCompare(b.rule));
    }
    function likeForLike(runs, collectorMap) {
      const rows = new Map(runs.map((r) => [r.runId, []]));
      if (runs.length < 2)
        return {
          rows,
          available: false,
          limitations: [
            "Insufficient history: at least two comparable runs are required.",
          ],
        };
      const limitations = [
        ...new Set(
          runs
            .slice(1)
            .flatMap((run) =>
              Assessment.compare(runs[0], run).limitations.filter(
                (s) =>
                  !s.includes("changed scope") &&
                  !s.includes("incomplete identities"),
              ),
            ),
        ),
      ];
      if (limitations.length) return { rows, available: false, limitations };
      const maps = runs.map(
        (r) => new Map(r.results.map((row) => [row.fingerprint, row])),
      );
      const commonRules = (runs[0].evaluatedRules || []).filter((rule) =>
        runs.every((r) => r.evaluatedRules?.includes(rule)),
      );
      for (const first of runs[0].results) {
        if (!commonRules.includes(first.ruleName)) continue;
        const population = maps.map((m) => m.get(first.fingerprint));
        if (
          population.some(
            (row, i) =>
              !row ||
              row.identityComplete !== true ||
              !["Pass", "Fail"].includes(row.outcome) ||
              collectionState(
                runs[i],
                row.project,
                row.category,
                collectorMap,
              ) !== "collected",
          )
        )
          continue;
        population.forEach((row, i) => rows.get(runs[i].runId).push(row));
      }
      const available = [...rows.values()].every((r) => r.length > 0);
      return {
        rows,
        available,
        limitations: available
          ? []
          : [
              "No verified like-for-like checkpoints: rules, identities and collected scopes must overlap.",
            ],
      };
    }
    function compareRuns(a, b, earlier = [], collectorMap = {}) {
      const original = Assessment.compare(a, b, earlier);
      const lifecycle = {
        new: [],
        recurring: [],
        persistent: [],
        resolved: [],
        notReassessed: [],
        fromNewRules: [],
        unverified: [],
      };
      if (a.legacy || b.legacy)
        return {
          compatible: false,
          lifecycle,
          limitations: [
            "Legacy failures-only evidence is not comparable: compliance and lifecycle are unavailable.",
          ],
        };
      const old = new Map(a.results.map((r) => [r.fingerprint, r]));
      const current = new Map(b.results.map((r) => [r.fingerprint, r]));
      for (const row of a.results)
        if (row.outcome === "Fail" && !current.has(row.fingerprint))
          lifecycle.notReassessed.push(row);
      for (const row of b.results) {
        const prior = old.get(row.fingerprint);
        if (row.outcome !== "Fail" && prior?.outcome !== "Fail") continue;
        if (
          !original.compatible ||
          row.identityComplete !== true ||
          (prior && prior.identityComplete !== true) ||
          collectionState(a, row.project, row.category, collectorMap) !==
            "collected" ||
          collectionState(b, row.project, row.category, collectorMap) !==
            "collected"
        ) {
          lifecycle.unverified.push(row);
          continue;
        }
        if (prior?.outcome === "Fail" && row.outcome === "Pass")
          lifecycle.resolved.push(row);
        else if (prior?.outcome === "Fail" && row.outcome === "Fail")
          lifecycle.persistent.push(row);
        else if (prior?.outcome === "Fail") lifecycle.unverified.push(row);
        else if (row.outcome === "Fail") {
          if (!a.evaluatedRules?.includes(row.ruleName)) {
            lifecycle.fromNewRules.push(row);
            continue;
          }
          const failedEarlier = earlier.some(
            (s) =>
              !s.legacy &&
              Assessment.compare(s, a).compatible &&
              s.results.some(
                (r) =>
                  r.fingerprint === row.fingerprint &&
                  r.identityComplete === true &&
                  r.outcome === "Fail" &&
                  collectionState(s, r.project, r.category, collectorMap) ===
                    "collected",
              ),
          );
          const observedEarlier = earlier.some((s) =>
            s.results.some(
              (r) => r.fingerprint === row.fingerprint && r.outcome === "Fail",
            ),
          );
          if (prior?.outcome === "Pass" && failedEarlier)
            lifecycle.recurring.push(row);
          else if (
            !observedEarlier &&
            (!prior ||
              ["Pass", "Ignore", "None", "Suppressed"].includes(prior.outcome))
          )
            lifecycle.new.push(row);
          else lifecycle.unverified.push(row);
        }
      }
      return {
        compatible: original.compatible,
        lifecycle,
        limitations: original.limitations,
      };
    }
    const trend = (delta) =>
      delta === null
        ? "Unavailable"
        : Math.abs(delta) <= 3
          ? "Stable"
          : delta > 3
            ? "Improving"
            : "Deteriorating";
    return {
      normalize,
      categories,
      stats,
      band,
      bandClass,
      collectionState,
      effortFor,
      hasEffortEstimates,
      measuredProjects,
      projectSummary,
      orderProjects,
      shared,
      likeForLike,
      compareRuns,
      trend,
    };
  })();
  if (typeof module !== "undefined")
    module.exports = { ...Assessment, ProjectHealth };
  if (typeof document !== "undefined")
    (() => {
      const root =
        document.currentScript?.closest("#psr-dashboard") ||
        document.getElementById("psr-dashboard");
      if (!root) return;
      const $ = (id) => root.querySelector(id.startsWith("#") ? id : `#${id}`);
      const H = ProjectHealth;
      const report = H.normalize(JSON.parse($("#report-data").textContent));
      const runs = [...report.history.snapshots, report].sort(
        (a, b) => new Date(a.timestamp) - new Date(b.timestamp),
      );
      const state = {
        tab: "health",
        project: "",
        category: "",
        run: runs.length - 1,
        before: Math.max(0, runs.length - 2),
        after: runs.length - 1,
        like: false,
        rank: "",
        drawer: null,
      };
      const percent = (value) =>
        value === null ? "Unavailable" : `${value.toFixed(1)}%`;
      const deltaText = (value) =>
        value === null
          ? "Unavailable"
          : `${value >= 0 ? "+" : ""}${value.toFixed(1)} pp`;
      const unique = (values) =>
        [...new Set(values)].sort((a, b) => a.localeCompare(b));
      const node = (tag, text, cls) => {
        const n = document.createElement(tag);
        if (text !== undefined) n.textContent = text;
        if (cls) n.className = cls;
        return n;
      };
      const button = (text, fn, cls = "ph-link") => {
        const n = node("button", text, cls);
        n.type = "button";
        n.onclick = fn;
        return n;
      };
      const badge = (text, cls = "") => node("span", text, `ph-badge ${cls}`);
      function panel(parent, title, note) {
        const n = node("section", undefined, "ph-panel");
        n.append(node("h3", title));
        if (note) n.append(node("p", note, "ph-note"));
        parent.append(n);
        return n;
      }
      function table(parent, headings, rows, cls = "") {
        const wrap = node("div", undefined, "ph-scroll"),
          t = node("table", undefined, cls),
          head = node("thead"),
          tr = node("tr"),
          body = node("tbody");
        headings.forEach((h) => {
          const th = node("th");
          th.scope = "col";
          th.append(h instanceof Node ? h : document.createTextNode(h));
          tr.append(th);
        });
        head.append(tr);
        rows.forEach((cells) => {
          const tr = node("tr");
          cells.forEach((value) => {
            const td = node("td");
            td.append(
              value instanceof Node
                ? value
                : document.createTextNode(String(value ?? "—")),
            );
            tr.append(td);
          });
          body.append(tr);
        });
        t.append(head, body);
        wrap.append(t);
        parent.append(wrap);
        return t;
      }
      const selected = (snapshot, includeOrg = false) =>
        snapshot.results.filter(
          (r) =>
            (includeOrg || r.project !== "(organization)") &&
            (!state.project ||
              r.project === state.project ||
              (includeOrg && r.project === "(organization)")) &&
            (!state.category || r.category === state.category),
        );
      const fromPopulation = (population, run) =>
        selected({ ...run, results: population.get(run.runId) || [] });
      const runStats = (snapshot, rows) => ({
        ...H.stats(rows),
        ...(snapshot.legacy ? { compliance: null } : {}),
      });
      function option(select, value, label) {
        const o = node("option", label);
        o.value = String(value);
        select.append(o);
      }
      option($("#ph-organization"), report.organization, report.organization);
      for (const select of [$("#ph-run"), $("#ph-before"), $("#ph-after")])
        runs.forEach((r, i) =>
          option(
            select,
            i,
            `${r.runId} · ${new Date(r.timestamp).toISOString().slice(0, 10)} · ${r.module?.version || "Unknown"}`,
          ),
        );
      option($("#ph-project"), "", "All Team Projects");
      unique(
        runs
          .flatMap((r) => [
            ...r.results.map((x) => x.project),
            ...(r.collection?.Projects || []).map((p) => p.Project),
          ])
          .filter((p) => p && p !== "(organization)"),
      ).forEach((p) => option($("#ph-project"), p, p));
      option($("#ph-category"), "", "All categories");
      unique(runs.flatMap((r) => r.results.map((x) => x.category))).forEach(
        (c) => option($("#ph-category"), c, c),
      );
      $("#ph-project").onchange = (e) => {
        state.project = e.target.value;
        render();
      };
      $("#ph-category").onchange = (e) => {
        state.category = e.target.value;
        if (state.category && state.rank !== state.category) state.rank = "";
        render();
      };
      $("#ph-run").onchange = (e) => {
        state.run = +e.target.value;
        render();
      };
      $("#ph-before").onchange = (e) => {
        state.before = +e.target.value;
        render();
      };
      $("#ph-after").onchange = (e) => {
        state.after = +e.target.value;
        state.run = state.after;
        render();
      };
      $("#ph-like").onchange = (e) => {
        state.like = e.target.checked;
        render();
      };
      $("#ph-tabs").hidden = false;
      $("#ph-filters").hidden = false;
      $("#ph-theme").hidden = false;
      $("#ph-theme").textContent = matchMedia("(prefers-color-scheme: dark)")
        .matches
        ? "Light theme"
        : "Dark theme";
      $("#ph-tabs").setAttribute("role", "tablist");
      for (const tab of $("#ph-tabs").children) {
        tab.setAttribute("role", "tab");
        tab.setAttribute("aria-controls", `ph-${tab.dataset.tab}`);
        tab.onclick = () => {
          state.tab = tab.dataset.tab;
          render();
        };
      }
      $("#ph-theme").onclick = () => {
        const dark =
          root.dataset.theme === "dark" ||
          (!root.dataset.theme &&
            matchMedia("(prefers-color-scheme: dark)").matches);
        root.dataset.theme = dark ? "light" : "dark";
        $("#ph-theme").textContent = dark ? "Dark theme" : "Light theme";
      };
      function meter(value) {
        const n = node("span", undefined, "ph-meter"),
          fill = node("span", undefined, H.bandClass(value));
        fill.style.width = `${value ?? 0}%`;
        n.append(fill);
        return n;
      }
      function currentProjects(snapshot, includeDiscovered = false) {
        return unique([
          ...selected(snapshot).map((r) => r.project),
          ...(includeDiscovered
            ? (snapshot.collection?.Projects || [])
                .map((p) => p.Project)
                .filter((p) => p && (!state.project || p === state.project))
            : []),
        ]);
      }
      function health(parent, snapshot) {
        const rows = selected(snapshot),
          s = runStats(snapshot, rows),
          projects = currentProjects(snapshot, true);
        const cats = state.category
          ? [state.category]
          : [
              ...H.categories.filter((c) => c !== "Organization"),
              ...unique(
                rows
                  .map((r) => r.category)
                  .filter((c) => !H.categories.includes(c)),
              ),
            ];
        const predecessor = runs[state.run - 1];
        const basis = predecessor
          ? H.likeForLike([predecessor, snapshot], report.collectorCategoryMap)
          : null;
        const before = basis?.available
          ? H.stats(fromPopulation(basis.rows, predecessor))
          : null;
        const after = basis?.available
          ? H.stats(fromPopulation(basis.rows, snapshot))
          : null;
        const delta =
          before?.compliance !== null &&
          after?.compliance !== null &&
          before &&
          after
            ? +(after.compliance - before.compliance).toFixed(1)
            : null;
        const cards = node("div", undefined, "ph-kpis");
        parent.append(cards);
        function card(title, value, note) {
          const n = node("article");
          n.append(node("h3", title), node("strong", value), node("p", note));
          cards.append(n);
          return n;
        }
        card(
          "Project compliance",
          percent(s.compliance),
          `${s.passed} pass · ${s.failed} fail · ${s.ignored} ignored · ${s.errors} errors`,
        ).append(
          node(
            "p",
            delta === null
              ? "Insufficient comparable history; no delta."
              : `${deltaText(delta)} vs ${predecessor.runId} · like-for-like`,
          ),
        );
        const distribution = {
          Critical: 0,
          "At risk": 0,
          Fair: 0,
          Healthy: 0,
          Unavailable: 0,
        };
        projects.forEach(
          (project) =>
            distribution[
              H.band(
                runStats(
                  snapshot,
                  rows.filter((r) => r.project === project),
                ).compliance,
              )
            ]++,
        );
        const projectCard = card(
          "Team Projects assessed · health",
          unique(rows.map((row) => row.project)).length,
          Object.entries(distribution)
            .filter(([, v]) => v)
            .map(([k, v]) => `${k} ${v}`)
            .join(" · "),
        );
        const dist = node("div", undefined, "ph-distribution");
        for (const [name, count] of Object.entries(distribution)) {
          const seg = node(
            "span",
            undefined,
            H.bandClass(
              { Critical: 0, "At risk": 50, Fair: 70, Healthy: 90 }[name] ??
                null,
            ),
          );
          seg.style.width = `${(100 * count) / (projects.length || 1)}%`;
          dist.append(seg);
        }
        projectCard.append(dist);
        const categoryScores = cats
          .map((category) => ({
            category,
            ...runStats(
              snapshot,
              rows.filter((r) => r.category === category),
            ),
          }))
          .filter((c) => c.compliance !== null)
          .sort((a, b) => a.compliance - b.compliance);
        const weakest = categoryScores[0];
        card(
          "Weakest category",
          weakest?.category || "Unavailable",
          weakest
            ? `${percent(weakest.compliance)} compliant · ${weakest.failed} failed results`
            : "No applicable checkpoints.",
        );
        const scopes = projects.flatMap((project) =>
          cats.map((category) => ({
            project,
            category,
            status: H.collectionState(
              snapshot,
              project,
              category,
              report.collectorCategoryMap,
            ),
          })),
        );
        const collected = scopes.filter(
          (s) => s.status !== "not collected",
        ).length;
        const complete =
          collected === scopes.length &&
          scopes.length > 0 &&
          snapshot.collection?.Status === "Complete" &&
          snapshot.evaluation?.Status === "Completed" &&
          !snapshot.results.some((row) => row.outcome === "Error");
        card(
          "Assessment confidence",
          complete ? "Complete" : "Limited",
          `${collected} of ${scopes.length} selected project/category scopes collected · ${snapshot.evaluatedRules?.length || 0} rules evaluated`,
        ).append(
          node(
            "p",
            scopes
              .filter((s) => s.status === "not collected")
              .map((s) => `${s.project} / ${s.category}: not collected`)
              .join("; ") ||
              `Collection: ${snapshot.collection?.Status || "Unknown"}. Evaluation: ${snapshot.evaluation?.Status || "Unknown"}.`,
          ),
        );
        const heat = panel(
          parent,
          "Team Project ranking × category",
          "Lowest compliance first · click a column to rank by it · click a cell to drill in. Critical <50; At risk 50–69; Fair 70–89; Healthy ≥90.",
        );
        const ranked = projects
          .map((project) => ({
            project,
            score: runStats(
              snapshot,
              rows.filter(
                (r) =>
                  r.project === project &&
                  (!state.rank || r.category === state.rank),
              ),
            ).compliance,
          }))
          .sort(
            (a, b) =>
              (a.score ?? -1) - (b.score ?? -1) ||
              a.project.localeCompare(b.project),
          );
        table(
          heat,
          [
            "#",
            "Team Project",
            button(`Overall${!state.rank ? " ▼" : ""}`, () => {
              state.rank = "";
              render();
            }),
            ...cats.map((c) =>
              button(`${c}${state.rank === c ? " ▼" : ""}`, () => {
                state.rank = c;
                render();
              }),
            ),
          ],
          ranked.map(({ project }, i) => {
            const total = runStats(
                snapshot,
                rows.filter((r) => r.project === project),
              ).compliance,
              overall = node("span");
            overall.append(
              meter(total),
              document.createTextNode(percent(total)),
            );
            return [
              i + 1,
              button(project, () => openDrawer({ project })),
              overall,
              ...cats.map((category) => {
                const scope = H.collectionState(
                    snapshot,
                    project,
                    category,
                    report.collectorCategoryMap,
                  ),
                  score = runStats(
                    snapshot,
                    rows.filter(
                      (r) => r.project === project && r.category === category,
                    ),
                  ).compliance;
                const text =
                  scope === "not collected"
                    ? "n/c"
                    : scope === "not applicable"
                      ? "n/a"
                      : score === null
                        ? "—"
                        : percent(score);
                const cell = button(
                  text,
                  () => openDrawer({ project, category }),
                  `ph-cell ${scope === "not collected" ? "ph-uncollected" : H.bandClass(score)}`,
                );
                cell.setAttribute(
                  "aria-label",
                  `${project} / ${category}: ${scope === "collected" ? text : scope}`,
                );
                return cell;
              }),
            ];
          }),
          "ph-heatmap",
        );
        heat.append(
          node(
            "p",
            "n/c = not collected or status missing · n/a = Empty with EmptyCollection, no resources · — = no applicable checkpoints. None means passing.",
            "ph-note",
          ),
        );
        const columns = node("div", undefined, "ph-columns");
        parent.append(columns);
        const gaps = panel(
          columns,
          "Largest compliance gaps",
          "Share of all failed project-scoped results.",
        );
        for (const c of [...categoryScores].sort(
          (a, b) => b.failed - a.failed,
        )) {
          if (!c.failed) continue;
          const share = (100 * c.failed) / (s.failed || 1);
          const line = node("p");
          line.append(
            button(c.category, () => openDrawer({ category: c.category })),
            document.createTextNode(
              ` · ${c.failed} fail · ${percent(c.compliance)} · ${share.toFixed(1)}% of failures`,
            ),
          );
          gaps.append(line);
          const bar = node("div", undefined, "ph-gap-bar");
          bar.setAttribute("role", "img");
          bar.setAttribute(
            "aria-label",
            `${c.category}: ${share.toFixed(1)}% share of failures`,
          );
          const fill = node("span");
          fill.style.width = `${share}%`;
          bar.append(fill);
          gaps.append(bar);
        }
        const organization = panel(
          columns,
          "Organization-wide controls",
          "Not attributed to any Team Project; excluded from project scores.",
        );
        const orgRows = snapshot.results.filter(
          (r) =>
            r.project === "(organization)" &&
            (!state.category || r.category === state.category),
        );
        organization.append(
          node("p", percent(runStats(snapshot, orgRows).compliance)),
        );
        table(
          organization,
          ["Control", "Outcome"],
          orgRows.map((r) => [
            button(report.rules[r.ruleName]?.displayName || r.ruleName, () =>
              openDrawer({
                project: "(organization)",
                category: r.category,
                rule: r.ruleName,
              }),
            ),
            r.outcome,
          ]),
        );
        findings(parent, snapshot, selected(snapshot, true));
      }
      function findings(parent, snapshot, rows) {
        const p = panel(
          parent,
          "Findings and all outcomes",
          "Failures first. Search and filters are combined; all PSRule outcomes remain available.",
        );
        const controls = node("div", undefined, "ph-filters"),
          search = node("input"),
          outcome = node("select"),
          severity = node("select");
        search.type = "search";
        search.placeholder = "Search findings";
        search.setAttribute("aria-label", "Search findings");
        outcome.setAttribute("aria-label", "Finding outcome");
        severity.setAttribute("aria-label", "Finding severity");
        option(outcome, "", "All outcomes");
        unique(rows.map((r) => r.outcome)).forEach((o) =>
          option(outcome, o, o),
        );
        option(severity, "", "All severities");
        unique(rows.map((r) => r.severity || "Unknown")).forEach((o) =>
          option(severity, o, o),
        );
        controls.append(search, outcome, severity);
        p.append(controls);
        const list = node("div"),
          pager = node("div");
        p.append(list, pager);
        let page = 0;
        function draw() {
          list.replaceChildren();
          pager.replaceChildren();
          const term = search.value.toLowerCase();
          const filtered = rows
            .filter(
              (r) =>
                (!outcome.value || r.outcome === outcome.value) &&
                (!severity.value ||
                  (r.severity || "Unknown") === severity.value) &&
                [
                  r.ruleName,
                  r.resourceName,
                  r.project,
                  r.reason,
                  report.rules[r.ruleName]?.description,
                ]
                  .join(" ")
                  .toLowerCase()
                  .includes(term),
            )
            .sort(
              (a, b) =>
                (a.outcome === "Fail" ? 0 : 1) -
                  (b.outcome === "Fail" ? 0 : 1) ||
                a.ruleName.localeCompare(b.ruleName),
            );
          const last = Math.max(0, Math.ceil(filtered.length / 50) - 1);
          page = Math.min(page, last);
          table(
            list,
            ["Project", "Rule", "Resource", "Outcome"],
            filtered.slice(page * 50, page * 50 + 50).map((r) => [
              r.project,
              button(r.ruleName, () =>
                openDrawer({
                  project: r.project,
                  category: r.category,
                  rule: r.ruleName,
                  fingerprint: r.fingerprint,
                }),
              ),
              r.resourceName || r.fingerprint,
              r.outcome,
            ]),
          );
          if (!filtered.length) list.append(node("p", "No findings match."));
          const prev = button("Previous", () => {
              page--;
              draw();
            }),
            next = button("Next", () => {
              page++;
              draw();
            });
          prev.disabled = !page;
          next.disabled = page === last;
          pager.append(
            prev,
            node(
              "span",
              ` Page ${page + 1} of ${last + 1} · ${filtered.length} checkpoints `,
            ),
            next,
          );
        }
        search.oninput =
          outcome.onchange =
          severity.onchange =
            () => {
              page = 0;
              draw();
            };
        draw();
      }
      function readiness(parent, snapshot) {
        if (snapshot.legacy) {
          panel(
            parent,
            "Readiness unavailable",
            "Legacy failures-only evidence has no compliance denominator. Select a normalized assessment; effort-based readiness is unavailable for this run.",
          );
          return;
        }
        const rows = selected(snapshot).map((r) => ({
          ...r,
          severity: r.severity || report.rules[r.ruleName]?.severity,
        }));
        const estimates = H.hasEffortEstimates(rows, report.effort);
        const legend = panel(parent, "How to read this view");
        legend.append(
          badge("MEASURED"),
          document.createTextNode(" from assessment results."),
        );
        if (estimates) {
          legend.append(
            badge("ESTIMATED", "ph-estimated"),
            document.createTextNode(" effort configuration, not PSRule "),
            badge("UNKNOWN", "ph-unknown"),
            document.createTextNode(" no estimate configured."),
          );
          const config = panel(
            parent,
            "Effort configuration · read only",
            `${report.effort.source}. Rule overrides take precedence over category defaults. Anything unconfigured is Unknown.`,
          );
          const configured = [
            ...Object.entries(report.effort.categoryDefaults || {}).map(
              ([key, value]) => ["Category default", key, value],
            ),
            ...Object.entries(report.effort.ruleOverrides || {}).map(
              ([key, value]) => ["Rule override", key, value],
            ),
          ];
          table(config, ["Source", "Category / rule", "Effort"], configured);
        }
        const summaries = currentProjects(snapshot).map((project) => ({
          project,
          ...H.projectSummary(
            rows.filter((r) => r.project === project),
            report.effort,
            report.settings.quickWinThreshold,
          ),
        }));
        const projects = estimates
          ? H.orderProjects(summaries)
          : H.measuredProjects(
              summaries,
              rows,
              report.settings.sharedOpportunityMinimum,
            );
        const cols = node("div", undefined, "ph-columns");
        parent.append(cols);
        const ordered = panel(
          cols,
          "Recommended remediation order",
          estimates
            ? `Order: Quick win → Planned → Needs estimate → Compliant; then fewest outstanding controls, then highest compliance. Quick win requires ≥${report.settings.quickWinThreshold}% and no High/Unknown effort. Compliant = zero outstanding; any Unknown effort = Needs estimate; otherwise Planned.`
            : "Measured priority: projects with failures first; highest failing severity, then most shared controls, fewest outstanding controls, then lowest compliance. Projects without failures follow. No effort estimates are available in this scope.",
        );
        const list = node("ol", undefined, "ph-rank");
        ordered.append(list);
        for (const p of projects) {
          const li = node("li");
          li.append(
            button(p.project, () => openDrawer({ project: p.project })),
            document.createTextNode(" "),
            ...(estimates
              ? [
                  badge(
                    p.tier,
                    `ph-tier-${p.tier.toLowerCase().replaceAll(" ", "-")}`,
                  ),
                ]
              : []),
            node(
              "strong",
              ` ${percent(p.compliance)} · ${p.outstanding} outstanding controls`,
            ),
            node(
              "p",
              estimates
                ? `${p.failed} failed results. ${p.justification}`
                : `${p.failed} failed results · highest failing severity: ${p.highestSeverity} · ${p.sharedControls} shared controls.`,
            ),
          );
          for (const e of estimates ? p.efforts : [])
            li.append(
              badge(
                e.value,
                e.value === "Unknown" ? "ph-unknown" : "ph-estimated",
              ),
            );
          list.append(li);
        }
        const matrix = panel(
          cols,
          "Compliance vs outstanding controls",
          estimates
            ? "Both axes are MEASURED · colour/label = readiness tier, which uses ESTIMATED effort."
            : "Both axes are MEASURED · colour/label = compliance health band. No effort-based tiers are assigned.",
        );
        const svg = document.createElementNS(
          "http://www.w3.org/2000/svg",
          "svg",
        );
        svg.setAttribute("viewBox", "0 0 520 340");
        svg.classList.add("ph-chart");
        svg.setAttribute("role", "group");
        svg.setAttribute(
          "aria-label",
          "Compliance percentage versus distinct outstanding controls",
        );
        matrix.append(svg);
        function svgNode(tag, attrs, text) {
          const n = document.createElementNS(svg.namespaceURI, tag);
          for (const [k, v] of Object.entries(attrs))
            n.setAttribute(k, String(v));
          if (text) n.textContent = text;
          svg.append(n);
          return n;
        }
        svgNode("line", { x1: 45, y1: 15, x2: 45, y2: 295, class: "ph-axis" });
        svgNode("line", {
          x1: 45,
          y1: 295,
          x2: 500,
          y2: 295,
          class: "ph-axis",
        });
        for (const value of [0, 50, 100])
          svgNode("text", { x: 3, y: 300 - value * 2.7 }, `${value}%`);
        svgNode("text", { x: 160, y: 332 }, "Outstanding distinct controls →");
        const max = Math.max(1, ...projects.map((p) => p.outstanding));
        const points = new Map();
        for (const p of projects) {
          const key = `${p.compliance}/${p.outstanding}/${estimates ? p.tier : H.band(p.compliance)}`;
          if (!points.has(key)) points.set(key, []);
          points.get(key).push(p);
        }
        for (const group of points.values()) {
          const p = group[0];
          if (p.compliance === null) continue;
          const names = group.map((item) => item.project).join(", ");
          const x = 55 + (425 * p.outstanding) / max,
            y = 295 - p.compliance * 2.7;
          const dot = svgNode("circle", {
            cx: x,
            cy: y,
            r: 8,
            tabindex: 0,
            role: "button",
            "aria-label": `${names}: ${percent(p.compliance)}, ${p.outstanding} controls, ${estimates ? p.tier : H.band(p.compliance)}`,
          });
          dot.style.fill = {
            "Quick win": "#107c10",
            Planned: "var(--ph-link)",
            "Needs estimate": "#888",
            Compliant: "#107c10",
            Critical: "#a4262c",
            "At risk": "#ca5010",
            Fair: "#8a6d00",
            Healthy: "#107c10",
          }[estimates ? p.tier : H.band(p.compliance)];
          dot.onclick = () =>
            group.length === 1
              ? openDrawer({ project: p.project })
              : openDrawer({
                  rows: rows.filter((row) =>
                    group.some((item) => item.project === row.project),
                  ),
                  label: names,
                });
          dot.onkeydown = (e) => {
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              dot.onclick();
            }
          };
          svgNode(
            "text",
            {
              x: x > 300 ? x - 10 : x + 10,
              y: Math.max(15, y - 10),
              "text-anchor": x > 300 ? "end" : "start",
            },
            names,
          );
        }
        table(
          matrix,
          [
            "Project",
            "Compliance",
            "Outstanding",
            estimates ? "Tier" : "Health",
          ],
          projects.map((p) => [
            p.project,
            percent(p.compliance),
            p.outstanding,
            estimates ? p.tier : H.band(p.compliance),
          ]),
        );
        const opportunities = panel(
          parent,
          "Shared opportunities",
          `Distinct rules failing in at least ${report.settings.sharedOpportunityMinimum} selected Team Projects. Organization-wide findings are excluded.`,
        );
        const shared = H.shared(rows, report.settings.sharedOpportunityMinimum);
        table(
          opportunities,
          ["Control", "Projects affected", "Projects"],
          shared.map((s) => [
            button(s.rule, () => openDrawer({ rule: s.rule })),
            s.count,
            s.projects.join(", "),
          ]),
        );
        if (!shared.length)
          opportunities.append(
            node(
              "p",
              "No controls meet the configured shared-opportunity threshold.",
            ),
          );
      }
      function evolution(parent) {
        const a = runs[state.before],
          b = runs[state.after];
        const top = node("div", undefined, "ph-columns");
        parent.append(top);
        const chart = panel(
          top,
          "Compliance per run",
          "Raw assessment totals can reflect scope changes. ◆ rule-set change · ▲ incomplete collection. Outlined bars are selected runs.",
        );
        const basis = H.likeForLike(
          runs.filter((r) => !r.legacy),
          report.collectorCategoryMap,
        );
        const bars = node("div", undefined, "ph-trend");
        chart.append(bars);
        runs.forEach((run, i) => {
          const rows = state.like
              ? fromPopulation(basis.rows, run)
              : selected(run),
            score = runStats(run, rows).compliance;
          const btn = button(
            "",
            () => {
              state.after = i;
              state.run = i;
              render();
            },
            "ph-run-bar",
          );
          btn.setAttribute("aria-label", `Compare to ${run.runId}`);
          btn.setAttribute(
            "aria-pressed",
            String(i === state.before || i === state.after),
          );
          btn.append(node("span", percent(score)));
          const fill = node(
            "span",
            undefined,
            `ph-run-fill ${H.bandClass(score)}`,
          );
          fill.style.height = `${score === null ? 0 : score * 1.65}px`;
          btn.append(
            fill,
            node("span", run.runId, "ph-run-label"),
            node(
              "span",
              new Date(run.timestamp).toISOString().slice(0, 10),
              "ph-run-label",
            ),
          );
          const prev = runs[i - 1];
          const known = (value) => value && value !== "Unknown";
          const changed =
            prev &&
            ((known(prev.module?.version) &&
              known(run.module?.version) &&
              prev.module.version !== run.module.version) ||
              (known(prev.configuration?.rulesetHash) &&
                known(run.configuration?.rulesetHash) &&
                prev.configuration.rulesetHash !==
                  run.configuration.rulesetHash));
          btn.append(
            node(
              "span",
              `${changed ? "◆ " : ""}${run.collection?.Status !== "Complete" ? "▲ " : ""}${run.legacy ? "Legacy · not comparable" : ""}`,
              "ph-run-label",
            ),
          );
          bars.append(btn);
        });
        if (state.like && !basis.available)
          chart.append(node("p", basis.limitations.join(" ")));
        const coverage = () => {
          const grid = panel(
            parent,
            "Category evolution",
            "Category × run · values are compliance percentages; unavailable evidence is never passing.",
          );
          const cats = state.category
            ? [state.category]
            : unique(runs.flatMap((r) => selected(r).map((x) => x.category)));
          table(
            grid,
            ["Category", ...runs.map((r) => r.runId)],
            cats.map((c) => [
              c,
              ...runs.map((r) => {
                const value = runStats(
                  r,
                  (state.like
                    ? fromPopulation(basis.rows, r)
                    : selected(r)
                  ).filter((x) => x.category === c),
                ).compliance;
                return node(
                  "span",
                  percent(value),
                  `ph-cell ${H.bandClass(value)}`,
                );
              }),
            ]),
          );
          const p = panel(
            parent,
            "Historical coverage & comparability",
            "Configuration, module, evaluation and collection evidence must be verified. History is limited by artifact retention.",
          );
          table(
            p,
            [
              "Run",
              "Date",
              "Module / ruleset",
              "Rules",
              "Resources",
              "Collection",
              "Evidence",
            ],
            runs.map((r) => [
              r.runId,
              new Date(r.timestamp).toISOString().slice(0, 10),
              `${r.module?.version || "Unknown"} / ${r.configuration?.rulesetHash || "Unknown"}`,
              r.evaluatedRules?.length || 0,
              r.evaluatedResourceCount ??
                r.evaluatedResources?.length ??
                "Unknown",
              r.collection?.Status || "Unknown",
              r.legacy
                ? "Legacy · not comparable"
                : r.evaluation?.Status === "Completed"
                  ? "Evaluation completed"
                  : "Evaluation unverified",
            ]),
          );
          for (const limitation of report.history.limitations)
            p.append(node("p", limitation, "ph-note"));
        };
        if (state.before >= state.after) {
          parent.append(
            node(
              "p",
              "Insufficient history or invalid selection: choose two distinct runs in chronological order. No trends or deltas are calculated.",
            ),
          );
          coverage();
          return;
        }
        const comparison = H.compareRuns(
          a,
          b,
          runs.slice(0, state.before),
          report.collectorCategoryMap,
        );
        const pair = H.likeForLike([a, b], report.collectorCategoryMap);
        const lifecyclePanel = panel(
          top,
          "Finding lifecycle",
          `${a.runId} → ${b.runId}. Resolved requires an explicit verified Pass; absence is never resolution.`,
        );
        if (!comparison.compatible)
          lifecyclePanel.append(
            node(
              "p",
              `Insufficient comparable history. ${comparison.limitations.join(" ")}`,
            ),
          );
        else {
          for (const limitation of comparison.limitations)
            lifecyclePanel.append(node("p", limitation, "ph-note"));
          const tiles = node("div", undefined, "ph-lifecycle");
          lifecyclePanel.append(tiles);
          for (const [key, label] of [
            ["new", "New"],
            ["recurring", "Recurring"],
            ["persistent", "Persistent"],
            ["resolved", "Resolved"],
            ["notReassessed", "Not re-assessed"],
            ["fromNewRules", "From new rules"],
          ]) {
            const rows = selected({ ...b, results: comparison.lifecycle[key] });
            const btn = button("", () => openDrawer({ rows, label }), "");
            btn.append(node("strong", rows.length), node("span", label));
            tiles.append(btn);
          }
          if (comparison.lifecycle.unverified.length)
            lifecyclePanel.append(
              node(
                "p",
                `${comparison.lifecycle.unverified.length} lifecycle checkpoints are unverified.`,
              ),
            );
        }
        const p = panel(
          parent,
          "Team Project evolution",
          "Δ and trend use verified like-for-like checkpoints. ±3 percentage points = Stable. A/B values and outstanding counts use the selected raw or like-for-like basis.",
        );
        if (!pair.available)
          p.append(
            node(
              "p",
              `Insufficient comparable history; no trend arrows or deltas. ${pair.limitations.join(" ")}`,
            ),
          );
        const projectNames = unique(
          [...selected(a), ...selected(b)].map((r) => r.project),
        );
        const evolutions = projectNames
          .map((project) => {
            const left = (
                state.like ? fromPopulation(pair.rows, a) : selected(a)
              ).filter((r) => r.project === project),
              right = (
                state.like ? fromPopulation(pair.rows, b) : selected(b)
              ).filter((r) => r.project === project);
            const ma = H.stats(
                fromPopulation(pair.rows, a).filter(
                  (r) => r.project === project,
                ),
              ).compliance,
              mb = H.stats(
                fromPopulation(pair.rows, b).filter(
                  (r) => r.project === project,
                ),
              ).compliance;
            const delta =
              pair.available && ma !== null && mb !== null
                ? +(mb - ma).toFixed(1)
                : null;
            return { project, left, right, delta };
          })
          .sort((a, b) => (b.delta ?? -Infinity) - (a.delta ?? -Infinity));
        table(
          p,
          [
            "Team Project",
            "All runs",
            a.runId,
            b.runId,
            "Δ like-for-like",
            "Trend",
            "Outstanding A → B",
          ],
          evolutions.map(({ project, left, right, delta }) => {
            const spark = node("span", undefined, "ph-spark");
            for (const r of runs) {
              const score = runStats(
                r,
                selected(r).filter((row) => row.project === project),
              ).compliance;
              const part = node("span", undefined, H.bandClass(score));
              part.style.height = `${score ?? 0}%`;
              part.title = `${r.runId}: ${percent(score)}`;
              spark.append(part);
            }
            spark.setAttribute(
              "aria-label",
              runs
                .map(
                  (r) =>
                    `${r.runId}: ${percent(
                      runStats(
                        r,
                        selected(r).filter((row) => row.project === project),
                      ).compliance,
                    )}`,
                )
                .join("; "),
            );
            return [
              button(project, () => openDrawer({ project })),
              spark,
              percent(runStats(a, left).compliance),
              percent(runStats(b, right).compliance),
              deltaText(delta),
              H.trend(delta),
              `${H.projectSummary(left, report.effort).outstanding} → ${H.projectSummary(right, report.effort).outstanding}`,
            ];
          }),
        );
        coverage();
      }
      let returnFocus = null;
      function openDrawer(context) {
        returnFocus = document.activeElement;
        state.drawer = context;
        drawDrawer();
        $("#ph-drawer").hidden = false;
        $("#ph-close").focus();
      }
      function closeDrawer() {
        $("#ph-drawer").hidden = true;
        state.drawer = null;
        if (returnFocus?.isConnected) returnFocus.focus();
      }
      $("#ph-close").onclick = closeDrawer;
      root.addEventListener("keydown", (e) => {
        if (!state.drawer) return;
        if (e.key === "Escape") {
          closeDrawer();
          return;
        }
        if (e.key === "Tab") {
          const items = [
            ...$("#ph-drawer").querySelectorAll('button,a,[tabindex="0"]'),
          ].filter((n) => !n.disabled);
          const first = items[0],
            last = items.at(-1);
          if (e.shiftKey && document.activeElement === first) {
            e.preventDefault();
            last.focus();
          } else if (!e.shiftKey && document.activeElement === last) {
            e.preventDefault();
            first.focus();
          }
        }
      });
      function drawDrawer() {
        const context = state.drawer,
          crumbs = $("#ph-breadcrumb"),
          detail = $("#ph-detail");
        crumbs.replaceChildren();
        detail.replaceChildren();
        const snapshot =
          runs[state.tab === "evolution" ? state.after : state.run];
        let rows = context.rows || selected(snapshot, true);
        for (const [field, key] of [
          ["project", "project"],
          ["category", "category"],
          ["rule", "ruleName"],
          ["fingerprint", "fingerprint"],
        ])
          if (context[field])
            rows = rows.filter((r) => r[key] === context[field]);
        crumbs.append(
          button(report.organization, () => {
            state.drawer = {};
            drawDrawer();
          }),
        );
        for (const field of ["project", "category", "rule", "fingerprint"])
          if (context[field]) {
            crumbs.append(
              document.createTextNode(" › "),
              button(
                field === "fingerprint" ? "Finding" : context[field],
                () => {
                  const next = { ...context };
                  const sequence = [
                    "project",
                    "category",
                    "rule",
                    "fingerprint",
                  ];
                  for (const lower of sequence.slice(
                    sequence.indexOf(field) + 1,
                  ))
                    delete next[lower];
                  state.drawer = next;
                  drawDrawer();
                },
              ),
            );
          }
        detail.append(
          node(
            "h2",
            context.label ||
              context.rule ||
              context.category ||
              context.project ||
              "Organization",
          ),
        );
        if (context.fingerprint) {
          const row = rows[0];
          if (!row) {
            detail.append(node("p", "Finding is unavailable in this run."));
            return;
          }
          const rule = report.rules[row.ruleName] || {};
          detail.append(
            node("h3", rule.displayName || row.ruleName),
            node(
              "p",
              `${row.outcome} · ${row.severity || rule.severity || "Unknown"} · ${row.resourceName || row.fingerprint}`,
            ),
          );
          for (const [label, text] of [
            ["Description", rule.description],
            ["Reason", row.reason],
            ["Recommendation", rule.recommendation],
          ])
            detail.append(
              node("h3", label),
              node(
                "p",
                text || "Not retained or supplied by the assessment evidence.",
              ),
            );
          const effort = H.effortFor(row.ruleName, row.category, report.effort);
          if (H.hasEffortEstimates(selected(snapshot), report.effort))
            detail.append(
              node("h3", "Effort"),
              node(
                "p",
                `${effort.value} · ${effort.source} · ${report.effort.source}`,
              ),
            );
          for (const link of [
            { url: rule.documentation, title: "Rule documentation" },
            ...(rule.references || []),
          ])
            if (/^https?:\/\//i.test(link.url || "")) {
              const a = node("a", link.title || "Reference");
              a.href = link.url;
              a.target = "_blank";
              a.rel = "noopener";
              detail.append(a, document.createTextNode(" "));
            }
          const history = panel(detail, "Outcome history");
          table(
            history,
            ["Run", "Outcome / evidence"],
            runs.map((r) => [
              r.runId,
              r.legacy
                ? "Legacy · unverified"
                : r.results.find((x) => x.fingerprint === row.fingerprint)
                    ?.outcome || "Not re-assessed",
            ]),
          );
          return;
        }
        if (!rows.length) {
          detail.append(
            node(
              "p",
              "No findings in this scope. Collection may be empty, unavailable or excluded.",
            ),
          );
          return;
        }
        if (!context.project && !context.rows) {
          const names = unique(rows.map((r) => r.project));
          for (const project of names)
            detail.append(
              button(project, () => {
                state.drawer = { ...context, project };
                drawDrawer();
              }),
              node("br"),
            );
          return;
        }
        if (!context.category && !context.rule && !context.rows) {
          for (const category of unique(rows.map((r) => r.category)))
            detail.append(
              button(category, () => {
                state.drawer = { ...context, category };
                drawDrawer();
              }),
              node("br"),
            );
          return;
        }
        if (!context.rule && !context.rows) {
          for (const rule of unique(rows.map((r) => r.ruleName)))
            detail.append(
              button(rule, () => {
                state.drawer = { ...context, rule };
                drawDrawer();
              }),
              node("br"),
            );
          return;
        }
        table(
          detail,
          ["Project / resource", "Rule", "Outcome"],
          rows.map((row) => [
            button(
              `${row.project} / ${row.resourceName || row.fingerprint}`,
              () => {
                state.drawer = {
                  ...context,
                  project: row.project,
                  category: row.category,
                  rule: row.ruleName,
                  fingerprint: row.fingerprint,
                };
                drawDrawer();
              },
            ),
            row.ruleName,
            row.outcome,
          ]),
        );
      }
      function render() {
        const snapshot = runs[state.run];
        root.querySelector(".ph-header p").textContent =
          `${report.organization} · ${snapshot.runId} · ${new Date(snapshot.timestamp).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric", timeZone: "UTC" })} UTC · ${snapshot.module?.name || "PSRule.Rules.AzureDevOps"} ${snapshot.module?.version || "Unknown"} · ${snapshot.configuration?.baseline || "Unknown"}`;
        for (const tab of $("#ph-tabs").children) {
          const active = tab.dataset.tab === state.tab;
          tab.setAttribute("aria-selected", String(active));
          tab.tabIndex = active ? 0 : -1;
        }
        for (const section of root.querySelectorAll("[data-view]"))
          section.hidden = section.dataset.view !== state.tab;
        $("#ph-run").value = String(state.run);
        $("#ph-before").value = String(state.before);
        $("#ph-after").value = String(state.after);
        $("#ph-run-label").hidden = state.tab === "evolution";
        for (const label of root.querySelectorAll(".ph-compare"))
          label.hidden = state.tab !== "evolution";
        $("#ph-status").textContent =
          `Selected scope: ${state.project || "all Team Projects"} · ${state.category || "all categories"} · ${snapshot.runId}. Organization-wide controls are separate.`;
        const parent = $(`ph-${state.tab}`);
        parent.replaceChildren();
        if (state.tab === "health") health(parent, snapshot);
        else if (state.tab === "readiness") readiness(parent, snapshot);
        else evolution(parent);
      }
      $("#ph-tabs").addEventListener("keydown", (e) => {
        if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) return;
        e.preventDefault();
        const tabs = [...$("#ph-tabs").children],
          index = tabs.indexOf(document.activeElement);
        let next =
          e.key === "Home"
            ? 0
            : e.key === "End"
              ? tabs.length - 1
              : (index + (e.key === "ArrowRight" ? 1 : -1) + tabs.length) %
                tabs.length;
        tabs[next].click();
        tabs[next].focus();
      });
      render();
    })();
})();
