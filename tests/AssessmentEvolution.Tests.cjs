const assert = require("node:assert/strict");
const { stats, compare } = require("../src/templates/assessment.js");
const row = (fingerprint, outcome = "Fail") => ({
  fingerprint,
  identityComplete: true,
  outcome,
  ruleName: "R",
  resourceKey: fingerprint,
  project: "p",
});
const run = (results, extra = {}) => ({
  organization: "org",
  configurationHash: "config",
  configuration: { baseline: "Default", rulesetHash: "known" },
  evaluation: { Status: "Completed" },
  module: { version: "1" },
  collection: { Status: "Complete" },
  results,
  ...extra,
});
let c = compare(
  run([row("resolved"), row("persistent"), row("new", "Pass"), row("absent")]),
  run([row("resolved", "Pass"), row("persistent"), row("new"), row("added")]),
);
assert.equal(c.lifecycle.resolved.length, 1);
assert.equal(c.lifecycle.persistent.length, 1);
assert.equal(c.lifecycle.new.length, 1);
assert.equal(c.lifecycle.scope.length, 2);
assert.equal(c.comparable.length, 3);
for (const change of [
  { collection: { Status: "Partial" } },
  { configurationHash: "changed" },
  { module: { version: "2" } },
  { legacy: true },
  { organization: "other" },
]) {
  c = compare(run([row("a")]), run([row("a", "Pass")], change));
  assert.equal(c.compatible, false);
  assert.equal(c.lifecycle.resolved.length, 0);
}
c = compare(run([row("a")]), run([]));
assert.equal(c.lifecycle.resolved.length, 0);
assert.equal(c.lifecycle.scope.length, 1);
c = compare(run([row("a")]), run([row("a", "Ignore")]));
assert.equal(c.lifecycle.resolved.length, 0);
c = compare(run([row("a", "Pass")]), run([row("a")]), [run([row("a")])]);
assert.equal(c.lifecycle.recurring.length, 1);
assert.equal(c.lifecycle.new.length, 0);
c = compare(run([row("a"), row("a")]), run([row("a", "Pass")]));
assert.equal(c.compatible, false);
assert.equal(stats([row("1", "Ignore")]).compliance, null);
console.log(
  "Lifecycle tests passed: matched populations, missing scope, incomplete coverage, configuration, module, duplicates, recurrence and denominator.",
);
const executionError = compare(
  run([row("a")]),
  run([row("a", "Pass")], { evaluation: { Status: "Failed" } }),
);
assert.equal(executionError.compatible, false);
assert.equal(executionError.lifecycle.resolved.length, 0);
const missingIdentity = compare(
  run([{ ...row("a"), identityComplete: false }]),
  run([{ ...row("a", "Pass"), identityComplete: false }]),
);
assert.equal(missingIdentity.lifecycle.resolved.length, 0);
assert.equal(missingIdentity.lifecycle.unverified.length, 1);

for (const change of [
  { configuration: undefined },
  { configuration: {} },
  { configuration: { baseline: "Default" } },
  { module: {} },
  { evaluation: undefined },
  { evaluation: { Status: "Unknown" } },
]) {
  const result = compare(run([row("a")]), run([row("a", "Pass")], change));
  assert.equal(result.compatible, false);
  assert.equal(result.lifecycle.resolved.length, 0);
}
const missingFlag = compare(
  run([{ ...row("a"), identityComplete: undefined }]),
  run([{ ...row("a", "Pass"), identityComplete: undefined }]),
);
assert.equal(missingFlag.lifecycle.resolved.length, 0);
assert.equal(missingFlag.lifecycle.unverified.length, 1);
const invalidEarlier = run([row("a")], { evaluation: { Status: "Failed" } });
const recurrence = compare(run([row("a", "Pass")]), run([row("a")]), [
  invalidEarlier,
]);
assert.equal(recurrence.lifecycle.recurring.length, 0);
assert.equal(recurrence.lifecycle.new.length, 1);

for (const invalidPrior of [
  run([row("a"), row("a")]),
  run([row("a")], { configuration: {} }),
  run([{ ...row("a"), identityComplete: undefined }]),
]) {
  const result = compare(run([row("a", "Pass")]), run([row("a")]), [
    invalidPrior,
  ]);
  assert.equal(result.lifecycle.recurring.length, 0);
}
