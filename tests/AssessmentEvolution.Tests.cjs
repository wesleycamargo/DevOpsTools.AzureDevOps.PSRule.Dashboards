const assert = require("node:assert/strict");
const { stats, compare } = require("../src/templates/assessment.js");
const row = (fingerprint, outcome = "Fail") => ({
  fingerprint,
  outcome,
  ruleName: "R",
  resourceKey: fingerprint,
  project: "p",
});
const run = (results, extra = {}) => ({
  organization: "org",
  configurationHash: "config",
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
