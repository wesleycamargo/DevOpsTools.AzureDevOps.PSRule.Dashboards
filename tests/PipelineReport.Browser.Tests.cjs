const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, readFileSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { chromium } = require('playwright');

(async () => {
    const output = mkdtempSync(path.join(tmpdir(), 'psrule-report-browser-'));
    const attack = '</script><script>window.reportInjected=true</script><img src=x onerror=alert(1)> prøject';
    const result = (Outcome, RuleName, TargetName, project, resourceName, severity = 'Critical') => ({
        Outcome, RuleName, TargetName, TargetType: 'Azure.DevOps.Project',
        Info: { DisplayName: RuleName, Annotations: { severity } },
        TargetObject: { id: { project, resourceName } }
    });
    const results = [
        result('Fail', 'Rule.A', 'shared-resource', 'alpha', 'shared'),
        result('Pass', 'Rule.A', 'shared-resource', 'alpha', 'shared'),
        result('Fail', 'Rule.B', 'shared-resource', 'beta', 'shared'),
        { Outcome: 'Ignore', RuleName: 'Rule.C', TargetName: 'missing-resource' },
        result('Pass', attack, 'injected-resource', 'alpha', attack, 'Warning'),
        ...Array.from({ length: 51 }, (_, i) => result('Pass', 'Rule.C', `resource-${i}`, 'alpha', `resource-${i}`, 'Warning'))
    ];
    const fixture = path.join(output, 'results.json');
    writeFileSync(fixture, JSON.stringify(results));
    execFileSync('pwsh', ['-NoProfile', '-Command', "& $env:PSRULE_REPORT_SCRIPT -Results @(Get-Content $env:PSRULE_REPORT_FIXTURE -Raw | ConvertFrom-Json) -Organization test-org -RunId test-org/42 -Timestamp ([datetime]'2026-10-09T12:00:00Z') -OutputDirectory $env:PSRULE_REPORT_OUTPUT"], {
        env: { ...process.env, PSRULE_REPORT_SCRIPT: path.resolve(__dirname, '../src/scripts/Export-PSRulePipelineReport.ps1'), PSRULE_REPORT_FIXTURE: fixture, PSRULE_REPORT_OUTPUT: output }
    });
    const browser = await chromium.launch({ headless: true });
    try {
        const page = await browser.newPage({ viewport: { width: 1280, height: 960 } });
        const errors = [];
        const network = [];
        page.on('pageerror', error => errors.push(error.message));
        page.on('request', request => { if (/^https?:/.test(request.url())) network.push(request.url()); });
        await page.setContent('<iframe id="report-frame" style="width:100%;height:920px;border:0"></iframe>');
        await page.evaluate(html => { document.getElementById('report-frame').srcdoc = html; }, readFileSync(path.join(output, 'psrule-dashboard.html'), 'utf8'));
        const frame = page.frameLocator('#report-frame');
        await frame.locator('#total').waitFor({ state: 'visible' });
        assert.equal(await frame.locator('#total').textContent(), '56');
        assert.equal(await frame.locator('#passed').textContent(), '53');
        assert.equal(await frame.locator('#failed').textContent(), '2');
        assert.equal(await frame.locator('#rules').textContent(), '4');
        assert.equal(await frame.locator('#resources').textContent(), '55');
        assert.equal(await frame.locator('#findings tr').count(), 50);
        await frame.locator('#next').click();
        assert.equal(await frame.locator('#findings tr').count(), 6);
        await frame.locator('#project').selectOption('beta');
        assert.equal(await frame.locator('#total').textContent(), '1');
        assert.equal(await frame.locator('#failed').textContent(), '1');
        assert.equal(await frame.locator('#page-info').textContent(), 'Page 1 of 1');
        await frame.locator('#reset').click();
        await frame.locator('#severity').selectOption('Critical');
        assert.equal(await frame.locator('#total').textContent(), '3');
        await frame.locator('#outcome').selectOption('Pass');
        assert.equal(await frame.locator('#total').textContent(), '1');
        await frame.locator('#reset').click();
        await frame.locator('#outcome').selectOption('Ignore');
        assert.equal(await frame.locator('#total').textContent(), '1');
        assert.equal(await frame.locator('#rule-chart').textContent(), 'No failures in this selection.');
        await frame.locator('#reset').click();
        await frame.locator('#rule-chart .bar-label').filter({ hasText: 'Rule.A' }).click();
        assert.equal(await frame.locator('#total').textContent(), '2');
        assert.equal(await frame.locator('#failed').textContent(), '1');
        await frame.locator('#reset').click();
        await frame.locator('#resource-chart .bar-label').filter({ hasText: 'beta / shared' }).click();
        assert.equal(await frame.locator('#total').textContent(), '1');
        await frame.locator('#reset').click();
        await frame.locator('#search').fill('prøject');
        assert.equal(await frame.locator('#total').textContent(), '1');
        assert.ok((await frame.locator('#findings').textContent()).includes(attack));
        assert.equal(await frame.locator('img').count(), 0);
        assert.equal(await frame.locator('body').evaluate(() => window.reportInjected), undefined);
        await frame.locator('#search').fill('no-such-resource');
        assert.equal(await frame.locator('#total').textContent(), '0');
        assert.equal(await frame.locator('#findings').textContent(), 'No results match these filters.');
        await frame.locator('#reset').click();
        await page.screenshot({ path: path.join(output, 'dashboard-preview.png'), fullPage: true });
        await page.setViewportSize({ width: 480, height: 900 });
        const width = await frame.locator('body').evaluate(() => ({ content: document.documentElement.scrollWidth, viewport: window.innerWidth }));
        assert.ok(width.content <= width.viewport, 'Dashboard should fit a narrow viewport');
        // Render a diagnostic-only report in the same iframe and verify safe diagnostics.
        writeFileSync(fixture, '[]');
        const statusFile = path.join(output, 'status.json');
        writeFileSync(statusFile, JSON.stringify({ Status: 'Unavailable', Projects: [{ Project: attack, Status: 'Unavailable', Collectors: [{ Command: 'billing', Status: 'Failed', ReasonCodes: ['CollectorFailed'] }] }] }));
        execFileSync('pwsh', ['-NoProfile', '-Command', '& $env:PSRULE_REPORT_SCRIPT -Results @() -CollectionStatus (Get-Content $env:PSRULE_REPORT_STATUS -Raw | ConvertFrom-Json) -Organization test-org -RunId test-org/43 -OutputDirectory $env:PSRULE_REPORT_OUTPUT'], {
            env: { ...process.env, PSRULE_REPORT_SCRIPT: path.resolve(__dirname, '../src/scripts/Export-PSRulePipelineReport.ps1'), PSRULE_REPORT_STATUS: statusFile, PSRULE_REPORT_OUTPUT: output }
        });
        await page.evaluate(html => { document.getElementById('report-frame').srcdoc = html; }, readFileSync(path.join(output, 'psrule-dashboard.html'), 'utf8'));
        await frame.locator('#no-results').waitFor({ state: 'visible' });
        assert.equal(await frame.locator('#total').textContent(), '0');
        assert.equal(await frame.locator('#coverage').isVisible(), true);
        assert.ok((await frame.locator('#collection-issues').textContent()).includes(attack));
        assert.ok((await frame.locator('#collection-issues').textContent()).includes('CollectorFailed'));
        assert.equal(await frame.locator('#rule-chart').textContent(), 'No assessment results available.');
        assert.equal(await frame.locator('img').count(), 0);
        assert.equal(await frame.locator('body').evaluate(() => window.reportInjected), undefined);
        assert.deepEqual(errors, []);
        assert.deepEqual(network, []);
        console.log(`Browser checks passed: filters, drill-downs, pagination, escaping, empty selection, responsive layout, and no network requests. Preview: ${output}`);
    } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
