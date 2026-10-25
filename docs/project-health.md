# Project Health & Compliance

One self-contained HTML file presents **Project Health**, **Compliance Readiness**
and **Evolution**, following the approved brief/screenshots in the rules
repository's `docs/design/project-health/`. Neither prototype code nor its sample
data is included. PowerShell generates static essentials before JavaScript adds
tabs, shared filters, sorting, comparisons and the drawer.

## Current pipeline integration

`azure-pipelines/run-assessment.yml` generates this report using the pinned
`DevOpsTools.AzureDevOps.Assessment` Gallery package. It publishes the
**Project Health & Compliance** HTML tab, Markdown, snapshots and raw exports.
It does not invoke the legacy workbook publisher described in the historical
validation sections below. Organization collection gaps are visible in all tabs
and static HTML; partial exports and zero results retain the yellow diagnostic
behavior described in [architecture](architecture.md).

History uses the current pipeline definition/branch and mapped `System.AccessToken`.
Module source/help and PSRule options are hashed for conservative comparisons.
Acquisition failures remain visible limitations. This integration has offline
regressions; the older live runs below do not validate its merged commit.

## Views

- Project Health: project-only compliance, health distribution, weakest category,
  confidence, sortable project/category heatmap, failure shares, separate
  organization controls and findings with all outcomes.
- Compliance Readiness: measured compliance and outstanding controls, read-only
  estimated effort when available, recommended order, measured-axis matrix and
  shared controls. Empty effort content is hidden.
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
controls, then highest compliance. These tiers and this order apply only when at
least one failing control in the selected scope has a known estimate. Otherwise,
projects with failures come first, ordered by highest failing severity, most
shared controls, fewest outstanding controls, then lowest compliance (name breaks
ties). Projects without failures follow; unavailable compliance sorts last in a
tie. Shared controls use the configured project threshold and exclude organization
findings. The page prints the active order and evidence for each project.
Readiness is not maturity or a PSRule score.

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
When no failing control in scope has a known estimate, the config panel, estimate
legend, effort badges, finding effort section and effort-dependent tiers are
hidden. The matrix then uses measured compliance health bands. Filtering can
switch between measured priority and effort-based readiness. Partially estimated
scopes retain Unknown and Needs estimate for unclassified failing controls.
Proposed rule-level estimates and their review assumptions are recorded in
[`effort-review.md`](effort-review.md); they are not loaded as configuration.
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
The historical pre-integration PowerShell suite had **43 passing tests**, including archive round-trip,
task environment-input size and report-only bootstrap invocation. Both Node
calculation suites and both browser suites also pass.

Production screenshots use only these fixtures:
[Health](images/project-health.png), [Readiness](images/project-readiness.png),
[Readiness without estimates](images/project-readiness-measured.png),
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
Run 119's artifact HTML is **1,167,303 bytes (1.17 MB)** including its additional
history, about **34% smaller** than the brief's 1.76 MB baseline.

The approved publisher is the installed BlakYaks `PublishHtmlReport@1`, using
`reportDir`, `tabName` and `useFilenameTabs`; it has no `htmlType` input. Its
Cheerio pass normalizes HTML markup after artifact publication. Embedded JSON,
JavaScript and CSS were verified unchanged between artifact and report attachment.
An automated check of the signed-in Reports portal itself remains unavailable:
the ephemeral browser redirects to Microsoft sign-in. This limitation does not
affect the verified published attachment or its standalone/iframe functionality.

### Effort presentation follow-up

The approved empty-estimate presentation was published through the same definition
17 in report-only runs **120** and **121**, both successful on the container agent.
The final [run 121 report](https://dev.azure.com/ai-experiments/PSRule.Rules.AzureDevOps/_build/results?buildId=121&view=blakyaks.azure-pipelines-html-reports.build-html-reports-tab)
uses revision **15**, including the adjusted JavaScript-disabled explanation.
Its exact report attachment passed sandboxed browser checks for measured priority,
expected project ordering, hidden empty effort configuration/tier badges, all three
tabs, filters, theme and history comparison, with zero page errors or external
requests. Run 120 → 121 retains 645 comparable checkpoints and 388 persistent
failures, with no new/resolved/recurring/not-reassessed findings. Assessment totals
remain 257 Pass / 388 Fail. The HTML is **1,410,921 bytes**, including the accumulated
history. Configuration remains unset; proposed estimates are documented separately
for owner review and have no effect on readiness.

### Classic task packaging

`src/scripts/New-ProjectHealthPipelineBundle.ps1` returns a compressed bootstrap
for the existing classic assessment task. It ZIPs the ten source/config files,
preserves their repository layout and writes them into the job's temporary
directory before invoking the existing assessment entry point. This avoids placing
170 KB in one task environment input. The current bootstrap is **49,677 bytes**;
the script rejects inputs of 64 KB or larger. Exact source bytes, worker launch
and report-only arguments have regression coverage. Regenerate this bootstrap
when updating the classic definition; changing a source branch alone does not
replace embedded classic task code.

### Updating existing classic pipeline 17

1. Review and validate source changes in this repository. Generate the inline
   task bootstrap with `./src/scripts/New-ProjectHealthPipelineBundle.ps1` from
   the repository root. The output contains the ten source/config files listed
   in that script; the script enforces the safe task-input size limit.
2. In the existing classic definition **17**, replace only the assessment task's
   inline script with that generated bootstrap. Preserve the existing queue,
   authentication, report/artifact tasks and **Project Health & Compliance** tab
   name. Re-read the current definition revision before applying an update so
   concurrent edits are not overwritten. Selecting a branch alone updates the
   checked-out rule module, not this embedded dashboard source.
3. For an approved report-only validation, queue the existing definition with
   `PSRuleReportOnly=true`. Its task environment maps that value to
   `PSRULE_REPORT_ONLY`; the bootstrap passes `-ReportOnly` to the assessment.
   The normal default remains false. History acquisition uses the existing job
   token mapped as `SYSTEM_ACCESSTOKEN`, with same-organization Build Read access.
4. Start the registered build agent in the container after checking its process
   environment. The validated `devcontainer-agent` used `AI-Pool` and a temporary
   working directory with `run.sh --once`. It exits after the job. Automatic
   devcontainer startup is only a [plan](assessment-analytics.md#plan-build-agent-in-the-devcontainer).
5. Check assessment, artifact and HTML publication success; verify the log confirms
   report-only completion. Download the actual attachment, confirm its embedded
   source and data against the generated artifact, and test its tabs and filters.
   Report registration is separate from an authenticated portal-browser check.

The final validated rules checkout was `fix/assessment-trust` at
`164726afbb48861b9abad768834fd9ba17f524d8`. The dashboard feature is reviewed on
`feature/project-health-dashboard` against its `feat/assessment-analytics` base;
neither branch is assumed merged into `main`. Review and publish the intended
source bundle explicitly when promoting the change.
