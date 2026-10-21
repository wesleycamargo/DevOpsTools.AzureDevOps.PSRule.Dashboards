# Project Health & Compliance

One self-contained HTML file presents **Project Health**, **Compliance Readiness**
and **Evolution**, following the approved brief/screenshots in the rules
repository's `docs/design/project-health/`. Neither prototype code nor its sample
data is included. PowerShell generates static essentials before JavaScript adds
tabs, shared filters, sorting, comparisons and the drawer.

## Views

- Project Health: project-only compliance, health distribution, weakest category,
  confidence, sortable project/category heatmap, failure shares, separate
  organization controls and findings with all outcomes.
- Compliance Readiness: measured compliance and outstanding controls, read-only
  estimated effort, recommended order, measured-axis matrix and shared controls.
- Evolution: chronological runs A/B, optional like-for-like population, lifecycle,
  project trends, category/run values and coverage. Single-run, legacy and
  incompatible histories show explicit limitations rather than unsupported deltas.

Filters persist across tabs. The drawer follows organization → project → category
→ rule → finding; breadcrumbs return to earlier levels. It shows metadata,
retained reasons, effort provenance and outcome history. External links open with
`target="_blank" rel="noopener"`.

Without JavaScript, the summary, project/category table, organization controls and
expandable findings remain readable, with stacked sections. Static injection is
also supported. All CSS lives under `#psr-dashboard`, including theme variables.
There are no runtime requests, remote assets, storage dependencies or URL routing.
The theme follows system preference until toggled within this report.

## Definitions and configuration

Compliance is `Pass / (Pass + Fail)`, displayed as a percentage rounded to one
decimal; no denominator means unavailable. Other outcomes remain visible.
Health bands: Critical <50%, At risk 50–69%, Fair 70–89%, Healthy ≥90%.
Organization-wide controls never affect project scores.

Outstanding controls are distinct failing rules. Shared opportunities require a
failure in at least three distinct selected projects, independent of resource
counts. Readiness: zero outstanding → Compliant; otherwise any Unknown effort →
Needs estimate; otherwise ≥70% without High effort → Quick win; otherwise Planned.
Order: Quick win → Planned → Needs estimate → Compliant, then fewest outstanding
controls, then highest compliance. The page prints these rules and a justification
for each project. Readiness is not maturity or a PSRule score.

[`config/effort.json`](../config/effort.json) ships empty. Only an owner-provided
classification assigns effort. Example syntax, not recommended estimates:

```json
{
  "categoryDefaults": { "Repos": "Low" },
  "ruleOverrides": { "Your.Actual.Rule.Name": "High" }
}
```

Rule overrides win, including explicit Unknown; category defaults follow; missing
values stay Unknown. Values are Low, Medium, High or Unknown, without numeric
scores/time estimates. Invalid values fail generation clearly. The read-only page
shows the config source; finding details show where the value originated.
Exporter options: `-EffortConfigPath`, `-SharedOpportunityMinimum` (3), and
`-QuickWinThreshold` (70). Defaults require no pipeline YAML edits.

## Display and historical evidence

Persisted snapshots and history storage remain version **1.0**. Existing artifact
acquisition, validation and retention are unchanged. Embedded display JSON is
version **2.0**, and the client adapts full version 1 and compact version 2 records:

- `rules` stores descriptions, recommendations, links, category and severity once
  per rule; results retain rule names and checkpoint-specific evidence.
- `categoryMap` normalizes labels to Repos, Pipelines, Service Connections,
  Environments, Variable Groups, Projects, Retention Settings and Organization.
  Unknown labels remain visible. The current module's Distributed Task help
  describes variable-group rules and maps to Variable Groups.
- `collectorCategoryMap` maps exporter commands to categories. Missing/failed
  collection is **n/c**. Empty with EmptyCollection and no contradictory findings
  is **n/a**. Neither means passing. Missing projects remain visible in the heatmap.
- `effort` includes configuration/provenance; `settings` includes thresholds.
- Historical results are `[fingerprint, project, category, ruleName, outcome]`.
  Each run retains timestamp, module/ruleset/configuration identity, evaluated
  rules, collection/evaluation evidence, legacy/coverage flags and identity
  limitations. Repeated prose, resource arrays and nested history are omitted.

Verified comparisons retain the existing conservative requirements: completed
evaluation, complete collection, matching known module/configuration/baseline,
unambiguous fingerprints and reliable identities. Like-for-like further requires
rules evaluated in every compared run, scopes collected in each, and matched
explicit Pass/Fail checkpoints. Changed configurations/modules remain visible but
cannot establish improvement. Raw totals are separate from comparable values.

Fail→Fail is Persistent; Fail→Pass is Resolved; Fail→absent is Not re-assessed.
Pass→Fail with an earlier verified failure is Recurring. Other current failures
without an earlier failure are New; rules not evaluated in A are From new rules.
Legacy failures-only SARIF has no compliance or verified lifecycle. Missing or
incompatible evidence never establishes resolution. Retention limits history.
KPI deltas and project trends use like-for-like evidence; ±3 percentage points is
Stable. ◆ marks known module/ruleset changes; ▲ marks incomplete collection.

## Development and verification

```powershell
Invoke-Pester ./tests -Output Detailed
npm ci
npx playwright install chromium
npm test
npm run test:browser
./tests/New-ProjectHealthFixture.ps1 -OutputDirectory ./.report/project-health
```

Tests use independently constructed, sanitized fixtures. They cover calculations,
effort and precedence, order/shared scope, lifecycle, conservative comparisons,
deduplication, compaction, static essentials, tabs/filters, drawer/breadcrumbs,
themes, widths 1440/1024/768, zero requests/errors, sandboxed iframe, static
injection, JavaScript-disabled access, empty/partial/legacy/single-run evidence
and 5,000-checkpoint pagination. SARIF, Markdown and Monitor paths are preserved.
The full PowerShell suite has **43 passing tests**, including archive round-trip,
task environment-input size and report-only bootstrap invocation. Both Node
calculation suites and both browser suites also pass.

Production screenshots use only these fixtures:
[Health](images/project-health.png), [Readiness](images/project-readiness.png),
[Evolution](images/project-evolution.png).

Read-only inspection and offline reevaluation of run 116 preserved all 645
checkpoint identities and its 257 Pass / 388 Fail totals. That local preview was
926,552 bytes; Markdown was byte-for-byte unchanged. Actual organization data
stays in ignored local report directories.

## Live pipeline validation: 2026-10-21

After explicit user approval, existing classic definition **17** was updated to
revision **13** and executed in report-only test mode on **devcontainer-agent**
inside this container. No new definition, pipeline YAML, service connection,
permission, infrastructure, retention or history-storage changes were made.
The existing job token supplies same-organization historical Build Read.

| Run | Result | Evidence |
| --- | --- | --- |
| [117](https://dev.azure.com/ai-experiments/PSRule.Rules.AzureDevOps/_build/results?buildId=117) | Failed before assessment | The original 170,554-byte inline input prevented Node from starting: Argument list too long. |
| [118](https://dev.azure.com/ai-experiments/PSRule.Rules.AzureDevOps/_build/results?buildId=118) | Succeeded | Assessment, artifact and Project Health report publication tasks succeeded. |
| [119](https://dev.azure.com/ai-experiments/PSRule.Rules.AzureDevOps/_build/results?buildId=119&view=blakyaks.azure-pipelines-html-reports.build-html-reports-tab) | Succeeded | Published the three-tab report and retrieved run 118 through the actual artifact history API. |

Select **Project Health & Compliance** on run 119's Reports page. Both successful
runs contain 645 checkpoints, 257 Pass, 388 Fail and 39.8% global compliance.
Snapshots, Markdown, SARIF and evaluation logs agree. Both logs explicitly confirm
report-only completion without Azure Monitor publishing.

Verification downloaded the six published evidence files, checked tab registration,
and opened the exact report attachment in a sandboxed iframe. All three tabs,
filter persistence, dark theme and the real A/B comparison passed with zero page
errors or external requests. Run 118 → 119 has **645 comparable checkpoints**:
388 persistent failures, zero new/resolved/recurring/not-reassessed findings.
The latest artifact HTML is **1,167,303 bytes (1.17 MB)** including its additional
history, about **34% smaller** than the brief's 1.76 MB baseline.

The approved publisher is the installed BlakYaks `PublishHtmlReport@1`, using
`reportDir`, `tabName` and `useFilenameTabs`; it has no `htmlType` input. Its
Cheerio pass normalizes HTML markup after artifact publication. Embedded JSON,
JavaScript and CSS were verified unchanged between artifact and report attachment.
An automated check of the signed-in Reports portal itself remains unavailable:
the ephemeral browser redirects to Microsoft sign-in. This limitation does not
affect the verified published attachment or its standalone/iframe functionality.

### Classic task packaging

`src/scripts/New-ProjectHealthPipelineBundle.ps1` returns a compressed bootstrap
for the existing classic assessment task. It ZIPs the ten source/config files,
preserves their repository layout and writes them into the job's temporary
directory before invoking the existing assessment entry point. This avoids placing
170 KB in one task environment input. The deployed bootstrap is **48,861 bytes**;
the script rejects inputs of 64 KB or larger. Exact source bytes, worker launch
and report-only arguments have regression coverage. Regenerate this bootstrap
when updating the classic definition; changing a source branch alone does not
replace embedded classic task code.
