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

Production screenshots use only these fixtures:
[Health](images/project-health.png), [Readiness](images/project-readiness.png),
[Evolution](images/project-evolution.png).

Read-only Azure DevOps inspection downloaded run 116's actual artifact. Offline
reevaluation of its existing exports preserved all 645 checkpoint identities and
257 Pass / 388 Fail totals. The final report is **926,552 bytes (0.93 MB)** against
the brief's **1.76 MB** baseline (about 47% smaller). All three views rendered with
no page errors or network requests, and Markdown remained byte-for-byte unchanged.
All **40 Pester tests**, both Node calculation suites and both browser suites pass. Actual
organization data stays in ignored local report directories.

Live pipeline publication of this version is **not yet verified**. Definition 17
is classic and embeds the older renderer; queueing another source branch alone
does not test this feature. No pipeline YAML/live configuration has been changed
for this feature, and no production pipeline has been triggered. Identify and
authorize a non-production publication context first. The installed BlakYaks
`PublishHtmlReport@1` accepts `reportDir`, `tabName`, `useFilenameTabs`; it has no
`htmlType: genericHTML` input. Verify the intended extension in that context.
