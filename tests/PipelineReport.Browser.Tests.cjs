const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { mkdtempSync, readFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const path = require("node:path");
const { chromium } = require("playwright");
(async () => {
  const output = mkdtempSync(path.join(tmpdir(), "project-health-browser-"));
  execFileSync("pwsh", [
    "-NoProfile",
    "-File",
    path.join(__dirname, "New-ProjectHealthFixture.ps1"),
    "-OutputDirectory",
    output,
  ]);
  const html = readFileSync(path.join(output, "psrule-dashboard.html"), "utf8");
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({
        viewport: { width: 1440, height: 1000 },
      }),
      errors = [],
      requests = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", (m) => {
      if (m.type() === "error") errors.push(m.text());
    });
    page.on("request", (r) => {
      if (/^https?:/.test(r.url())) requests.push(r.url());
    });
    await page.setContent(
      '<iframe id="frame" sandbox="allow-scripts" style="width:100%;height:1000px;border:0"></iframe>',
    );
    await page
      .locator("#frame")
      .evaluate((frame, html) => (frame.srcdoc = html), html);
    const f = page.frameLocator("#frame");
    await f.getByRole("tab", { name: /^Project Health/ }).waitFor();
    assert.equal(await f.locator(".ph-kpis article").count(), 4);
    await f
      .getByRole("img", { name: /share of failures/ })
      .first()
      .waitFor();
    await f
      .locator(".ph-heatmap thead")
      .getByRole("button", { name: "Pipelines", exact: true })
      .click();
    await f.locator("#ph-category").selectOption("Repos");
    assert.equal(
      await f
        .locator(".ph-heatmap thead")
        .getByRole("button", { name: "Overall ▼", exact: true })
        .count(),
      1,
    );
    const ranking = await f
      .locator(".ph-heatmap tbody tr td:nth-child(2)")
      .allTextContents();
    assert.ok(ranking.indexOf("Delta") < ranking.indexOf("Atlas"));
    await f.locator("#ph-category").selectOption("");
    await f.locator("#ph-project").selectOption("Atlas");
    await f.getByRole("tab", { name: /^Compliance Readiness/ }).click();
    assert.equal(await f.locator("#ph-project").inputValue(), "Atlas");
    assert.ok(
      (await f.locator("#ph-readiness").textContent()).includes("Quick win"),
    );
    await f.locator("#ph-category").selectOption("Repos");
    await f.getByRole("tab", { name: /^Project Health/ }).click();
    assert.equal(await f.locator("#ph-category").inputValue(), "Repos");
    await f
      .locator(".ph-heatmap")
      .getByRole("button", { name: /Atlas \/ Repos:/ })
      .click();
    await f
      .locator("#ph-detail")
      .getByRole("button", { name: "Fixture.Repos.Protection", exact: true })
      .click();
    await f
      .locator("#ph-detail")
      .getByRole("button", { name: "Atlas / resource-1", exact: true })
      .click();
    assert.ok(
      (await f.locator("#ph-detail").textContent()).includes(
        "Fixture: protection outcome Fail",
      ),
    );
    assert.ok(
      (await f.locator("#ph-detail").textContent()).includes(
        "Category default: Repos",
      ),
    );
    assert.equal(
      await f.locator('#ph-detail a[target="_blank"][rel="noopener"]').count(),
      1,
    );
    await f
      .locator("#ph-breadcrumb")
      .getByRole("button", { name: "Atlas", exact: true })
      .click();
    await f
      .locator("#ph-detail")
      .getByRole("button", { name: "Repos", exact: true })
      .waitFor();
    await f.getByRole("button", { name: "Close details", exact: true }).click();
    await f.locator("#ph-theme").click();
    assert.equal(
      await f.locator("#psr-dashboard").getAttribute("data-theme"),
      "dark",
    );
    await f.locator("#ph-project").selectOption("");
    await f.locator("#ph-category").selectOption("");
    await f.getByRole("tab", { name: /^Evolution/ }).click();
    await f.locator("#ph-before").selectOption("0");
    await f.locator("#ph-after").selectOption("2");
    await f.locator("#ph-like").check();
    assert.equal(await f.locator(".ph-lifecycle button").count(), 6);
    assert.ok(
      (await f.locator("#ph-evolution").textContent()).includes(
        "Not re-assessed",
      ),
    );
    assert.ok(
      (await f.locator("#ph-evolution").textContent()).includes(
        "like-for-like",
      ),
    );
    const categoryGrid = f.locator(".ph-panel").filter({
      has: f.getByRole("heading", {
        name: "Category evolution",
        exact: true,
      }),
    });
    assert.ok((await categoryGrid.locator(".ph-cell").count()) > 0);
    await f
      .locator(".ph-lifecycle button")
      .filter({ hasText: "Resolved" })
      .click();
    assert.ok((await f.locator("#ph-detail").textContent()).includes("Delta"));
    await f.getByRole("button", { name: "Close details", exact: true }).click();
    for (const width of [1440, 1024, 768]) {
      await page.setViewportSize({ width, height: 1000 });
      await f.getByRole("tab", { name: /^Project Health/ }).click();
      assert.equal(
        await f
          .locator("#psr-dashboard")
          .evaluate((n) => n.scrollWidth <= n.clientWidth + 1),
        true,
      );
    }
    assert.equal(await f.locator("img").count(), 0);
    assert.deepEqual(errors, []);
    assert.deepEqual(requests, []);
    // An extension may inject markup without executing scripts. The static document must stand alone.
    await page.setContent(
      '<style>body{background:rgb(1,2,3)}#host-heading{font-size:31px}</style><h1 id="host-heading">Host</h1><div id="injected"></div>',
    );
    await page
      .locator("#injected")
      .evaluate((el, html) => (el.innerHTML = html), html);
    assert.equal(await page.locator("#injected #ph-tabs").isVisible(), false);
    await page
      .locator("#injected")
      .getByRole("heading", {
        name: "Team Project ranking × category",
        exact: true,
      })
      .waitFor();
    assert.ok(
      (
        await page.locator("#injected #ph-static-findings").textContent()
      ).includes("Fixture.Repos.Protection"),
    );
    assert.equal(
      await page
        .locator("#host-heading")
        .evaluate((n) => getComputedStyle(n).fontSize),
      "31px",
    );
    assert.equal(
      await page
        .locator("body")
        .evaluate((n) => getComputedStyle(n).backgroundColor),
      "rgb(1, 2, 3)",
    );
    assert.equal(await page.locator("#injected img").count(), 0);
    const noJs = await browser.newContext({ javaScriptEnabled: false });
    const staticPage = await noJs.newPage();
    await staticPage.goto(`file://${output}/psrule-dashboard.html`);
    await staticPage
      .getByRole("heading", { name: "Organization-wide controls", exact: true })
      .waitFor();
    await staticPage
      .locator("#ph-static-findings > details")
      .first()
      .locator("summary")
      .first()
      .click();
    assert.equal(
      await staticPage
        .locator("#ph-static-findings > details")
        .first()
        .getAttribute("open"),
      "",
    );
    await noJs.close();
    // Integration: organization gaps stay visible independently of the active tab.
    for (const empty of [false, true]) {
      const diagnosticOutput = mkdtempSync(
        path.join(tmpdir(), "project-health-gaps-"),
      );
      execFileSync("pwsh", [
        "-NoProfile",
        "-File",
        path.join(__dirname, "New-ProjectHealthFixture.ps1"),
        "-OutputDirectory",
        diagnosticOutput,
        "-RunCount",
        "1",
        "-OrganizationGap",
        ...(empty ? ["-NoResults"] : []),
      ]);
      const diagnosticHtml = readFileSync(
        path.join(diagnosticOutput, "psrule-dashboard.html"),
        "utf8",
      );
      await page.locator("#injected").evaluate((el) => el.remove());
      await page.setContent(
        '<iframe id="diagnostics" sandbox="allow-scripts" style="width:100%;height:1000px"></iframe>',
      );
      await page
        .locator("#diagnostics")
        .evaluate((frame, html) => (frame.srcdoc = html), diagnosticHtml);
      const gap = page.frameLocator("#diagnostics");
      await gap.getByRole("tab", { name: /^Project Health/ }).waitFor();
      assert.equal(
        await gap.locator("#ph-collection-diagnostics tbody tr").count(),
        2,
      );
      const diagnostics = await gap
        .locator("#ph-collection-diagnostics")
        .textContent();
      assert.ok(diagnostics.includes("(organization)"));
      assert.ok(
        diagnostics.includes("Export-AdoOrganizationGeneralBillingSettings"),
      );
      assert.ok(diagnostics.includes("<script>|PermissionDenied"));
      assert.equal(
        await gap.locator("#ph-collection-diagnostics script").count(),
        0,
      );
      for (const tab of [
        /^Compliance Readiness/,
        /^Evolution/,
        /^Project Health/,
      ]) {
        await gap.getByRole("tab", { name: tab }).click();
        assert.equal(
          await gap.locator("#ph-collection-diagnostics").isVisible(),
          true,
        );
      }
      assert.equal(await gap.locator("#ph-no-results").count(), empty ? 1 : 0);
      if (empty)
        assert.ok(
          (await gap.locator("#ph-no-results").textContent()).includes(
            "No compliance conclusion",
          ),
        );
      // The same evidence must remain readable when JavaScript is disabled.
      const context = await browser.newContext({ javaScriptEnabled: false });
      const staticGap = await context.newPage();
      await staticGap.goto(`file://${diagnosticOutput}/psrule-dashboard.html`);
      assert.equal(
        await staticGap.locator("#ph-collection-diagnostics tbody tr").count(),
        2,
      );
      assert.equal(
        await staticGap.locator("#ph-collection-diagnostics").isVisible(),
        true,
      );
      await context.close();
      // Recreate the injection host for the next fixture.
      await page.setContent('<div id="injected"></div>');
    }
    assert.deepEqual(errors, []);
    assert.deepEqual(requests, []);
    console.log(
      "Project Health browser checks passed: filters, drawer/breadcrumb, comparisons, themes, responsive widths, offline sandboxed iframe, injection and no-JavaScript fallback.",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
