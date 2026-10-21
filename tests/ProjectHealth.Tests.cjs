const assert = require("node:assert/strict");
const { ProjectHealth: H } = require("../src/templates/assessment.js");
const map = { CollectRepos: "Repos" };
const row = (
  fingerprint,
  outcome = "Fail",
  project = "Atlas",
  ruleName = "R",
) => ({
  fingerprint,
  outcome,
  project,
  ruleName,
  category: "Repos",
  identityComplete: true,
});
const run = (results, extra = {}) => ({
  organization: "fixture",
  runId: "fixture/1",
  module: { version: "1" },
  configurationHash: "same",
  configuration: { baseline: "Default", rulesetHash: "same" },
  evaluation: { Status: "Completed" },
  collection: {
    Status: "Complete",
    Projects: ["Atlas", "Beacon", "Cedar"].map((Project) => ({
      Project,
      Collectors: [
        { Command: "CollectRepos", Status: "Completed", ReasonCodes: [] },
      ],
    })),
  },
  evaluatedRules: [...new Set(results.map((r) => r.ruleName))],
  results,
  ...extra,
});
const effort = { categoryDefaults: { Repos: "Low" }, ruleOverrides: {} };
assert.equal(
  H.stats([row("a", "Pass"), row("b"), row("c", "Ignore"), row("d", "Error")])
    .compliance,
  50,
);
assert.equal(H.stats([row("a", "Ignore")]).compliance, null);
for (const [value, band] of [
  [null, "Unavailable"],
  [0, "Critical"],
  [49.9, "Critical"],
  [50, "At risk"],
  [69.9, "At risk"],
  [70, "Fair"],
  [89.9, "Fair"],
  [90, "Healthy"],
  [100, "Healthy"],
])
  assert.equal(H.band(value), band);
assert.deepEqual(H.effortFor("R", "Repos", {}), {
  value: "Unknown",
  source: "Not configured",
});
assert.equal(
  H.effortFor("R", "Repos", { ...effort, ruleOverrides: { R: "Unknown" } })
    .value,
  "Unknown",
);
assert.equal(H.projectSummary([row("a", "Pass")], effort).tier, "Compliant");
assert.equal(H.projectSummary([row("a")], {}).tier, "Needs estimate");
assert.equal(H.hasEffortEstimates([row("a")], {}), false);
assert.equal(H.hasEffortEstimates([row("a")], effort), true);
assert.equal(H.hasEffortEstimates([row("a", "Pass")], effort), false);
assert.equal(
  H.hasEffortEstimates([row("a")], {
    ...effort,
    ruleOverrides: { R: "Unknown" },
  }),
  false,
);
const measuredRows = [
  { ...row("critical", "Fail", "Critical"), severity: "Critical" },
  { ...row("shared", "Fail", "Shared"), severity: "High" },
  { ...row("private", "Fail", "Private", "Other"), severity: "High" },
  { ...row("low", "Fail", "Low"), severity: "Low" },
  row("pass", "Pass", "Clear"),
  row("unknown", "Fail", "Unknown", "Other"),
];
const measuredSummaries = [
  "Clear",
  "Unknown",
  "Low",
  "Private",
  "Shared",
  "Critical",
  "Missing",
].map((project) => ({
  project,
  ...H.projectSummary(
    measuredRows.filter((r) => r.project === project),
    {},
  ),
}));
const measuredOrder = H.measuredProjects(measuredSummaries, measuredRows);
assert.deepEqual(
  measuredOrder.map((p) => p.project),
  ["Critical", "Shared", "Private", "Low", "Unknown", "Clear", "Missing"],
);
assert.equal(measuredOrder[0].sharedControls, 1);
assert.equal(measuredOrder[1].highestSeverity, "High");
assert.equal(
  measuredOrder.find((p) => p.project === "Missing").compliance,
  null,
);
const mostlyPassing = [
  row("a"),
  ...Array.from({ length: 3 }, (_, i) => row(String(i), "Pass")),
];
assert.equal(H.projectSummary(mostlyPassing, effort).tier, "Quick win");
assert.equal(
  H.projectSummary(mostlyPassing, { ...effort, ruleOverrides: { R: "High" } })
    .tier,
  "Planned",
);
assert.equal(H.projectSummary(mostlyPassing, effort, 80).tier, "Planned");
assert.deepEqual(
  H.orderProjects([
    { project: "A", tier: "Compliant", outstanding: 0, compliance: 100 },
    { project: "B", tier: "Quick win", outstanding: 2, compliance: 90 },
    { project: "C", tier: "Quick win", outstanding: 1, compliance: 75 },
    { project: "D", tier: "Needs estimate", outstanding: 1, compliance: 90 },
    { project: "E", tier: "Planned", outstanding: 1, compliance: 90 },
  ]).map((p) => p.project),
  ["C", "B", "E", "D", "A"],
);
assert.equal(
  H.shared([
    row("a"),
    row("b"),
    row("c", "Fail", "Beacon"),
    row("d", "Fail", "Cedar"),
    row("e", "Fail", "(organization)"),
  ])[0].count,
  3,
);
assert.equal(H.shared([row("a"), row("b", "Fail", "Beacon")]).length, 0);
const a = run([
  row("resolved"),
  row("persistent"),
  row("recurring", "Pass"),
  row("new", "Pass"),
  row("missing"),
  row("existing", "Pass"),
]);
const b = run(
  [
    row("resolved", "Pass"),
    row("persistent"),
    row("recurring"),
    row("new"),
    row("new-resource"),
    row("new-rule", "Fail", "Atlas", "NewRule"),
  ],
  { runId: "fixture/2" },
);
const old = run([row("recurring")], { runId: "fixture/0" });
const compared = H.compareRuns(a, b, [old], map);
assert.equal(compared.lifecycle.resolved.length, 1);
assert.equal(compared.lifecycle.persistent.length, 1);
assert.equal(compared.lifecycle.recurring.length, 1);
assert.equal(compared.lifecycle.new.length, 2);
assert.equal(compared.lifecycle.notReassessed.length, 1);
assert.equal(compared.lifecycle.fromNewRules.length, 1);
const unverifiedPrior = H.compareRuns(
  a,
  b,
  [{ ...old, evaluation: { Status: "Failed" } }],
  map,
);
assert.equal(unverifiedPrior.lifecycle.recurring.length, 0);
assert.equal(
  unverifiedPrior.lifecycle.new.some((r) => r.fingerprint === "recurring"),
  false,
);
assert.equal(
  compared.lifecycle.resolved.some((r) => r.fingerprint === "missing"),
  false,
);
assert.equal(
  H.compareRuns({ ...a, legacy: true }, b, [], map).compatible,
  false,
);
assert.equal(
  H.compareRuns({ ...a, legacy: true }, b, [], map).lifecycle.resolved.length,
  0,
);
assert.equal(
  H.compareRuns(a, { ...b, configurationHash: "different" }, [], map).lifecycle
    .resolved.length,
  0,
);
assert.equal(
  H.compareRuns(a, { ...b, evaluation: { Status: "Failed" } }, [], map)
    .lifecycle.resolved.length,
  0,
);
assert.equal(
  H.compareRuns(a, { ...b, collection: { Status: "Partial" } }, [], map)
    .lifecycle.resolved.length,
  0,
);
const basis = H.likeForLike([a, b], map);
assert.equal(basis.available, true);
assert.deepEqual(
  basis.rows.get(a.runId).map((r) => r.fingerprint),
  ["resolved", "persistent", "recurring", "new"],
);
assert.equal(H.likeForLike([a], map).available, false);
assert.equal(H.likeForLike([a, b], {}).available, false);
assert.equal(H.likeForLike([a, { ...b, legacy: true }], map).available, false);
const collected = run([]);
assert.equal(H.collectionState(collected, "Atlas", "Repos", map), "collected");
collected.collection.Projects[0].Collectors[0] = {
  Command: "CollectRepos",
  Status: "Empty",
  ReasonCodes: ["EmptyCollection"],
};
assert.equal(
  H.collectionState(collected, "Atlas", "Repos", map),
  "not applicable",
);
collected.collection.Projects[0].Collectors[0].ReasonCodes = [];
assert.equal(
  H.collectionState(collected, "Atlas", "Repos", map),
  "not collected",
);
assert.equal(
  H.collectionState(collected, "Missing", "Repos", map),
  "not collected",
);
for (const [delta, trend] of [
  [null, "Unavailable"],
  [-3, "Stable"],
  [3, "Stable"],
  [3.1, "Improving"],
  [-3.1, "Deteriorating"],
])
  assert.equal(H.trend(delta), trend);
const compact = H.normalize({
  ...b,
  schemaVersion: "2.0",
  rules: {
    R: { displayName: "Readable", severity: "High", category: "Repos" },
  },
  history: {
    snapshots: [
      {
        ...a,
        results: [["fp", "Atlas", "Repository", "R", "Fail"]],
        identityIncomplete: ["fp"],
      },
    ],
  },
  categoryMap: { Repository: "Repos" },
});
assert.equal(compact.results[0].displayName, "Readable");
assert.equal(compact.history.snapshots[0].results[0].category, "Repos");
assert.equal(compact.history.snapshots[0].results[0].identityComplete, false);
assert.equal(
  H.normalize({ ...a, schemaVersion: "1.0" }).rules.R.category,
  "Repos",
);
console.log(
  "Project Health tests passed: compliance, bands, effort precedence, readiness order, shared scope, all lifecycle categories, conservative evidence and compact/legacy adapters.",
);
