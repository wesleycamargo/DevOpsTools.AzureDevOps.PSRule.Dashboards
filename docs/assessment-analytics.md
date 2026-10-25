# Assessment analytics

The current three-tab presentation is documented in [Project Health & Compliance](project-health.md).
The six-view description below records the earlier presentation; its version 1
snapshot and artifact-history contracts remain the underlying evidence format.

PowerShell generates `psrule-dashboard.html`, `psrule-summary.md` and
`assessment-snapshot.json`. The HTML embeds its CSS, JavaScript, current snapshot
and available history. Open it from the pipeline's Reports page or download it
from `psrule-results` and open it offline. It makes no runtime network requests.
SARIF and the existing Monitor publishers remain supported.

## Current source-backed pipeline

The maintained entry point is `azure-pipelines/run-assessment.yml`, using the
pinned Gallery module `DevOpsTools.AzureDevOps.Assessment`. It presents the
[three-tab Project Health report](project-health.md), with organization collection
diagnostics retained in HTML and Markdown. `System.AccessToken` is mapped for
read-only history from the same pipeline/branch. Current reports and snapshots
are written to the `reports` staging directory and retained in `psrule-results`.
Incomplete collection or zero results finishes yellow after diagnostic reporting;
execution failures stay red. No Monitor publisher is called by this entry point.

The older pipeline filenames and live validation sections below describe the
legacy analytics implementation, not additional active YAML entry points.

## Views

| View | Audience and behavior |
| --- | --- |
| Overview | Executive totals, collection evidence, severity/category distributions and prioritized controls. |
| Risk & Compliance | Control/resource risk distributions and a project × category heatmap. |
| Projects & Resources | Normalized project and resource-type compliance; sort projects by risk, compliance or name and navigate to findings. |
| Findings Explorer | Investigate individual/grouped findings using combined filters, text search, sorting, 50-row pages and rule details. Entering this view defaults to failures; all outcomes remain available. |
| Evolution | Select any two retained runs, review raw compliance/severity/coverage trends, compare matched checkpoints, and inspect lifecycle findings and project/rule/resource changes. |
| Maturity | Unavailable until supporting People, Process and Technology evidence exists. The 0–4 model never derives a score from compliance. |

Global metrics always describe the complete current assessment. Selection metrics
reflect filters and drill-downs. Evolution intentionally uses whole runs and labels
this behavior. Back restores the preceding selection. Themes support system, light
and dark preferences. Chart values are also available in tables.

## Semantics

Compliance is `100 × Pass / (Pass + Fail)`, rounded to one decimal place. An empty
denominator is unavailable. Ignore, None, Suppressed, Error and any other PSRule
outcomes are retained and excluded from this denominator. Collection status and
rule-check failures are independent. Completed and Empty collectors represent
successful collection; Partial, Unavailable and Failed represent limitations.
The collection detail exposes the module's original report, including legitimately
empty collections and discovery failures.

Severity aliases normalize as follows: Critical → Critical; Severe, Important,
Error, High → High; Moderate, Warning, Warn, Medium → Medium; Information,
Informational, Info, Low → Low. Missing/unrecognized severity stays Unknown.
Controls are ranked by highest failing severity, then affected resource count.
There is no invented composite risk score. Rule help/PSRule metadata supplies
categories, descriptions, recommendations and links; missing content stays unavailable.

A verified lifecycle transition requires both snapshots to have completed evaluation and complete collection,
matching organization, configuration hash and module version, reliable checkpoint
identities and explicit Pass/Fail outcomes at the same fingerprint:

- Pass → Fail: new; recurring when an earlier compatible assessment failed it.
- Fail → Pass: resolved.
- Fail → Fail: persistent.
- Missing checkpoints or changed applicability: scope changes, never resolution.
- Incompatible configurations, incomplete collection, ambiguous duplicate checkpoints
  or legacy evidence: no verified improvement is claimed.

Both pipeline entry points hash module sources/help and effective PSRule options as part
of their configuration. Dictionary ordering does not change the hash. Same-version rule
edits and configuration changes invalidate comparison. Comparable compliance uses the
intersection of explicit applicable checkpoints; raw totals remain separately visible.
Resource renames/identity changes conservatively appear as scope changes.

## Contracts

See [assessment-snapshot.schema.json](assessment-snapshot.schema.json). Version 1.0
contains organization, evaluated projects, run ID/time, module identity/version,
assessment configuration/hash, evaluation status, original collection report, evaluated rule/resource
identities, checkpoint metadata/outcomes, statistics and maturity evidence contract.
Fingerprints are SHA-256 hashes of JSON arrays containing organization, project,
resource type, resource ID/name, target identity and rule identity. Resource keys
use the same components without the rule. Missing identity is marked explicitly.
Target objects, credentials and exported resource configuration are not embedded.

The history envelope is `{schemaVersion:"1.0",snapshots:[],limitations:[]}`. It
contains snapshots without nested history. Unsupported future snapshot versions,
corrupt files and missing comparison metadata are excluded with limitations.
The maturity contract includes version, scale `[0,1,2,3,4]`, dimensions, evidence
and a nullable score; supporting evidence is presently empty.

## Pipeline operation

`azure-pipelines/publish-workbooks.yml` maps `System.AccessToken` to the
assessment task environment for historical acquisition. The existing pipeline identity needs Build Read
and access to its own artifacts; additional infrastructure and PATs are unnecessary.
History acquisition filters exactly one pipeline and branch, paginates build history,
deduplicates runs, downloads `psrule-results` and reads only the named snapshot or
legacy SARIF ZIP entry. Failed builds can contain valid assessment evidence;
successful builds without evidence do not count as assessments. Credentials are
sent only to download URLs in the configured Azure DevOps organization.

Reports are written and readiness is announced before Monitor ingestion. Partial or
unknown collection and evaluation errors retain reports and fail the assessment
before workbook publication. Historical API failures produce visible limitations;
they do not fail current evidence generation. `reportOnly: true` performs collection,
evaluation and reporting without publishing to Azure Monitor. No Azure infrastructure
or retention policies are changed by the reporting scripts.

The older `azure-pipelines.yml` entry point also writes reports and snapshots before
its shared-key publisher. It preserves its prior rule selection using an explicit effective-options object, records
`ModuleDefault` when no baseline override was selected, and hashes module sources and
options for historical comparison. Its SARIF, raw-data and existing
analysis artifacts remain available, and `psrule-results` is added for history.

`PublishHtmlReport@1` requires the HTML Reports extension. The repository YAML
names the report **DevOps Assessment Analytics**. The updated classic definition
17 uses **Project Health & Compliance**; [run 121](https://dev.azure.com/ai-experiments/PSRule.Rules.AzureDevOps/_build/results?buildId=121&view=blakyaks.azure-pipelines-html-reports.build-html-reports-tab)
contains the current three-tab dashboard. Evolution is integrated into the same
report; no separate app or hosting is required.

## History and retention

The default discovery limit is 50 candidate builds (`-MaxRuns`, maximum 1000).
Retention may delete artifacts and builds; gaps are not evidence of improvement.
Legacy PSRule SARIF can contain only failures. It supplies historical findings and
counts but never a reliable overall compliance denominator or verified lifecycle.
For example, actual pipeline 17 run 113 retained 388 SARIF failures while its old
HTML included 257 additional passes. The collector reports that limitation explicitly.

An optional future JSON store needs only to supply compatible snapshot paths through
`-SnapshotPaths`; no database or live Log Analytics dependency is required. Existing
Monitor reports remain independent and share the same assessed results. No second
historical scoring implementation is introduced in workbooks.

## Local development

From the dashboard repository, with PowerShell 7.4+, Pester 5.7.1 and Node 20+:

```powershell
Invoke-Pester ./tests -Output Detailed
npm ci
npx playwright install chromium
npm test
npm run test:browser

$results = @(Get-Content ./results.json -Raw | ConvertFrom-Json)
./src/scripts/Export-PSRulePipelineReport.ps1 -Results $results -Organization example -RunId example/1 -OutputDirectory ./.report

./src/scripts/Get-AssessmentHistory.ps1 -Organization example -Project project -DefinitionId 17 -SnapshotPaths ./old/assessment-snapshot.json -Token '' -OutputPath ./.report/assessment-history.json
```

Supply collection/configuration/version, `-Evaluation @{Status='Completed'}`, and
`-RuleHelpPath` when generating verified snapshots. Unknown evaluation status or missing
checkpoint identity fields prevent verified lifecycle transitions. `-HistoryPath` embeds an existing history envelope in the HTML. Browser
tests generate synthetic evidence; production credentials and live Azure resources
are not required. Presentation source is in `src/templates/assessment.{js,css}`;
the shell template is `psrule-dashboard.html`. `npm run format` formats those files.

## Troubleshooting and Azure DevOps validation

- No history: verify Build Read access, token mapping, exact branch/pipeline selection,
  retained `psrule-results` artifacts and the report's acquisition limitations.
- No verified comparison: check module/configuration identity, collection status,
  duplicate fingerprints, applicability and legacy coverage limitations.
- Missing metadata: pass the module's `en` help directory; do not infer remediation.
- Reports exist but the pipeline fails: inspect collection/evaluation errors or Monitor
  ingestion errors; download the artifact independently of the ingestion result.
- No Reports tab: inspect extension installation/task status and artifact HTML first.

### Live validation: 2026-10-21

The existing classic definition 17 in `ai-experiments/PSRule.Rules.AzureDevOps`
was executed as [run 116](https://dev.azure.com/ai-experiments/PSRule.Rules.AzureDevOps/_build/results?buildId=116).
It succeeded on `AI-Pool` using `devcontainer-agent` running in this container.
The assessment collected complete evidence and evaluated 645 checkpoints:
257 passed, 388 failed, and compliance was 39.8%.

Definition 17 embeds older scripts. Its shared configuration was left unchanged;
the new generator was run afterward against run 116's actual raw exports, using
the same checked-out rules and PSRule 2.9.0. Detailed outcome counts matched the
original report. The resulting HTML, normalized snapshot, history and Markdown
were attached to that run's existing `psrule-results` artifact. The old report was
preserved. A separate **DevOps Assessment Analytics** report was registered alongside
**PSRule Dashboard** on the existing
[Reports page](https://dev.azure.com/ai-experiments/PSRule.Rules.AzureDevOps/_build/results?buildId=116&view=blakyaks.azure-pipelines-html-reports.build-html-reports-tab).

Verification downloaded the published artifact, compared its HTML to the generated
file, checked snapshot totals and token exclusion, and confirmed the new report's
attachment registration. Playwright opened the downloaded HTML and navigated all
six views without page errors or external requests. This checks the published
file; it does not constitute an authenticated browser check of the Azure DevOps
Reports page itself. Local browser suites separately cover sandboxed iframes.

The real history collector subsequently retrieved run 116's normalized snapshot
and run 113's legacy SARIF through the artifact API. Run 113's compliance remains
unavailable; the pair cannot establish verified lifecycle improvement.

### Subsequent authorized deployment validation

The user subsequently authorized updating existing definition 17 for Project
Health. Revision 13 generated and published the current three-tab report in
report-only runs **118 and 119** on the container agent. The actual pipeline tasks
published snapshots, SARIF, Markdown, collection/history evidence and the new
**Project Health & Compliance** report. Run 119 retrieved run 118's snapshot and
their comparison verified 645 matching checkpoints without claiming improvement.
See [Project Health validation](project-health.md#live-pipeline-validation-2026-10-21)
for run links, file size, the compressed classic-task bundle and the remaining
signed-in portal-browser limitation. Subsequent revision **15**, validated by
**run 121**, hides empty effort content and uses measured remediation priority.
Its report-only job succeeded on `devcontainer-agent`; the exact published
attachment and comparison with run 120 passed browser checks. See the
[effort follow-up](project-health.md#effort-presentation-follow-up) for final
evidence. No Azure Monitor ingestion was requested.

### Plan: build agent in the devcontainer

The successful run used a temporary agent directory and `run.sh --once`; that
listener exited after its job. Automatic startup is planned, not implemented.

1. Reuse the agent package already installed at `/opt/azure-pipelines-agent` by
   the workspace's `.devcontainer/Dockerfile`. Add a startup wrapper that removes
   invalid process environment names before registration/capability discovery.
   The observed registration failure was a leading newline in the name
   `\nCONDA_PROMPT_MODIFIER`. In PowerShell, remove it using explicit
   `[System.Management.Automation.Language.NullString]::Value`; assigning `$null`
   through the .NET API retained an empty-valued invalid key in this environment.
2. Persist registration, credentials and work data in a dedicated named volume
   owned by `vscode`. Keep credentials out of source and image layers. Configure
   only when unregistered, with a bounded timeout and the approved authentication
   mechanism; do not unconditionally replace an existing agent registration.
3. Start one continuous listener with the Compose lifecycle, preserving skills
   synchronization. Use a single-listener lock and graceful signal handling.
4. Validate startup, stop/start and rebuild: the same registration returns online,
   a queued job runs in this container, malformed environment names cannot stall
   registration, and logs/reports contain no credentials.
