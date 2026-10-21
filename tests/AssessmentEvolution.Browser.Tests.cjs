const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { mkdtempSync, readFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const path = require("node:path");
const { chromium } = require("playwright");
(async () => {
  const output = mkdtempSync(path.join(tmpdir(), "project-health-evidence-"));
  execFileSync("pwsh", [
    "-NoProfile",
    "-File",
    path.join(__dirname, "New-ProjectHealthFixture.ps1"),
    "-OutputDirectory",
    output,
    "-RunCount",
    "1",
  ]);
  const html = readFileSync(path.join(output, "psrule-dashboard.html"), "utf8");
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage(),
      errors = [],
      requests = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("request", (r) => {
      if (/^https?:/.test(r.url())) requests.push(r.url());
    });
    await page.setContent(html);
    await page.getByRole("tab", { name: /^Evolution/ }).click();
    assert.ok(
      (await page.locator("#ph-evolution").textContent()).includes(
        "Insufficient history",
      ),
    );
    assert.equal(await page.locator(".ph-lifecycle").count(), 0);
    const payload = JSON.parse(
      /<script id="report-data" type="application\/json">([\s\S]*?)<\/script>/.exec(
        html,
      )[1],
    );
    const render = async (data) => {
      await page.goto("about:blank");
      await page.setContent(
        html.replace(
          /(<script id="report-data" type="application\/json">)[\s\S]*?(<\/script>)/,
          (_, a, b) => a + JSON.stringify(data).replaceAll("<", "\\u003c") + b,
        ),
      );
    };
    const originalEffort = payload.effort;
    payload.effort = { categoryDefaults: {}, ruleOverrides: {} };
    await render(payload);
    await page.getByRole("tab", { name: /^Compliance Readiness/ }).click();
    let readiness = page.locator("#ph-readiness");
    assert.match(await readiness.textContent(), /Measured priority/);
    assert.equal(
      await readiness
        .getByRole("heading", { name: /Effort configuration/ })
        .count(),
      0,
    );
    assert.equal(await readiness.locator('[class*="ph-tier-"]').count(), 0);
    assert.doesNotMatch(
      await readiness.textContent(),
      /Needs estimate|Quick win|ESTIMATED|UNKNOWN/,
    );
    assert.match(
      await readiness.textContent(),
      /highest failing severity: High/,
    );
    assert.match(
      await readiness.textContent(),
      /colour\/label = compliance health band/,
    );
    await page
      .locator(".ph-rank")
      .getByRole("button", { name: "Atlas", exact: true })
      .click();
    await page
      .locator("#ph-detail")
      .getByRole("button", { name: "Repos", exact: true })
      .click();
    await page
      .locator("#ph-detail")
      .getByRole("button", { name: "Fixture.Repos.Protection", exact: true })
      .click();
    await page
      .locator("#ph-detail")
      .getByRole("button", { name: "Atlas / resource-1", exact: true })
      .click();
    assert.equal(
      await page
        .locator("#ph-detail")
        .getByRole("heading", { name: "Effort", exact: true })
        .count(),
      0,
    );
    payload.effort = {
      categoryDefaults: {},
      ruleOverrides: { "Fixture.Repos.Protection": "Unknown" },
    };
    await render(payload);
    await page.getByRole("tab", { name: /^Compliance Readiness/ }).click();
    assert.match(
      await page.locator("#ph-readiness").textContent(),
      /Measured priority/,
    );
    payload.effort = {
      categoryDefaults: {},
      ruleOverrides: { "Fixture.Repos.Protection": "Low" },
    };
    await render(payload);
    await page.getByRole("tab", { name: /^Compliance Readiness/ }).click();
    assert.match(
      await page.locator("#ph-readiness").textContent(),
      /Needs estimate/,
    );
    assert.equal(
      await page.getByRole("heading", { name: /Effort configuration/ }).count(),
      1,
    );
    await page.locator("#ph-category").selectOption("Pipelines");
    assert.match(
      await page.locator("#ph-readiness").textContent(),
      /Measured priority/,
    );
    assert.equal(
      await page.getByRole("heading", { name: /Effort configuration/ }).count(),
      0,
    );
    payload.effort = originalEffort;
    payload.legacy = true;
    payload.coverage = "Legacy failures-only";
    await render(payload);
    assert.ok(
      (await page.locator(".ph-kpis article").first().textContent()).includes(
        "Unavailable",
      ),
    );
    payload.legacy = false;
    payload.collection.Status = "Partial";
    payload.collection.Projects[0].Collectors = [];
    await render(payload);
    assert.ok(
      (await page.locator(".ph-kpis").textContent()).includes("Limited"),
    );
    assert.ok((await page.locator(".ph-uncollected").count()) > 0);
    payload.collection.Projects[0].Collectors = [
      {
        Command: "Export-AzDevOpsReposAndBranchPolicies",
        Status: "Empty",
        ReasonCodes: ["EmptyCollection"],
      },
    ];
    payload.results = payload.results.filter(
      (r) => !(r.project === "Atlas" && r.category === "Repos"),
    );
    await render(payload);
    assert.ok(
      (await page.locator(".ph-heatmap").textContent()).includes("n/a"),
    );
    payload.collection.Projects.push({
      Project: "NotCollectedProject",
      Status: "Failed",
      Collectors: [],
    });
    payload.results = Array.from({ length: 5000 }, (_, i) => ({
      ...payload.results[i % payload.results.length],
      fingerprint: `f-${i}`,
      resourceName: `resource-${i}`,
    }));
    await render(payload);
    assert.ok(
      (await page.locator(".ph-heatmap").textContent()).includes(
        "NotCollectedProject",
      ),
    );
    const findings = page.locator(".ph-panel").filter({
      has: page.getByRole("heading", {
        name: "Findings and all outcomes",
        exact: true,
      }),
    });
    assert.equal(await findings.locator("tbody tr").count(), 50);
    await findings.getByRole("button", { name: "Next", exact: true }).click();
    assert.ok((await findings.textContent()).includes("Page 2"));
    await findings.getByRole("searchbox").fill("resource-4999");
    assert.equal(await findings.locator("tbody tr").count(), 1);
    payload.results = [];
    payload.history.snapshots = [];
    await render(payload);
    assert.ok(
      (await page.locator(".ph-kpis").textContent()).includes("Unavailable"),
    );
    assert.deepEqual(errors, []);
    assert.deepEqual(requests, []);
    console.log(
      "Project Health evidence browser checks passed: insufficient/legacy history, partial/missing/empty collection, absent projects, empty data, and 5,000-checkpoint pagination.",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
