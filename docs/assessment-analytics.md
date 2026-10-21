# Assessment analytics

PowerShell generates `psrule-dashboard.html`, `psrule-summary.md` and
`assessment-snapshot.json`. The HTML embeds its CSS, JavaScript, current snapshot
and available history. Open it from the pipeline's Reports page or download it
from `psrule-results` and open it offline. It makes no runtime network requests.
SARIF and the existing Monitor publishers remain supported.

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

A verified lifecycle transition requires both snapshots to have complete collection,
matching organization, configuration hash and module version, reliable checkpoint
identities and explicit Pass/Fail outcomes at the same fingerprint:

- Pass → Fail: new; recurring when an earlier compatible assessment failed it.
- Fail → Pass: resolved.
- Fail → Fail: persistent.
- Missing checkpoints or changed applicability: scope changes, never resolution.
- Incompatible configurations, incomplete collection, ambiguous duplicate checkpoints
  or legacy evidence: no verified improvement is claimed.

The manual pipeline hashes module source files as part of its configuration, so
same-version rule edits also invalidate comparison. Comparable compliance uses the
intersection of explicit applicable checkpoints; raw totals remain separately visible.
Resource renames/identity changes conservatively appear as scope changes.

## Contracts

See [assessment-snapshot.schema.json](assessment-snapshot.schema.json). Version 1.0
contains organization, evaluated projects, run ID/time, module identity/version,
assessment configuration/hash, original collection report, evaluated rule/resource
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

`azure-pipelines/publish-workbooks.yml` maps `System.AccessToken` only to the
history step's process environment. The existing pipeline identity needs Build Read
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
its shared-key publisher. It preserves its prior evaluation configuration; because
its selected baseline/configuration is unspecified, lifecycle comparison is unavailable
until that configuration is explicitly supplied. Its SARIF, raw-data and existing
analysis artifacts remain available, and `psrule-results` is added for history.

`PublishHtmlReport@1` requires the HTML Reports extension. Evolution is integrated
into the same report; no separate app or hosting is required.

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

From the dashboard repository, with PowerShell 7, Pester 5.7.1 and Node 20+:

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

Supply collection/configuration/version and `-RuleHelpPath` when generating verified
snapshots. `-HistoryPath` embeds an existing history envelope in the HTML. Browser
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

Live read-only validation discovered organization `ai-experiments`, project
`PSRule.Rules.AzureDevOps`, pipeline 17, and downloaded/normalized run 113 through
the actual artifact API. That definition is **classic** and embeds its scripts;
queuing it on a feature branch does not test this source. It must not be silently
updated to deploy these changes.

To complete pipeline/extension validation in an approved test context:

1. Create a temporary YAML pipeline from this dashboard feature branch using
   `azure-pipelines/publish-workbooks.yml`, existing `AI-Pool`, GitHub endpoint and
   `psrule-azure` service connection; retain the existing classic definition untouched.
2. Queue it with `reportOnly: true`. Verify collection/evaluation status, readiness,
   `psrule-results` artifacts (HTML, Markdown, SARIF, snapshot, collection and history),
   and the HTML Reports tab. A partial collection should retain evidence and fail visibly.
3. Queue a second report-only assessment and compare both retained snapshots. Compare
   totals against the snapshot and underlying PSRule results. Confirm absent checkpoints
   remain scope changes and never become resolved findings.
4. Open the report in Azure DevOps and offline; exercise filters, navigation and
   selected-run Evolution. Confirm no external requests or tokens in the HTML.

Creating that temporary pipeline requires explicit approval because the task forbids
modifying live Azure DevOps resources. Pipeline creation and execution have not been
performed as part of the read-only integration checks above.
