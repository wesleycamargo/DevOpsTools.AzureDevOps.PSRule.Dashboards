# Dashboard architecture

## Assessment pipeline

`azure-pipelines/run-assessment.yml` is the dashboard repository's only pipeline
entry point. It runs manually or daily at 06:00 UTC on `main`, with push and PR
triggers disabled. The Microsoft-hosted `Azure Pipelines` pool (`ubuntu-latest`) executes the job; `psrule-azure` supplies the Azure
DevOps token. Only dashboard source is checked out. The assessment task installs
`DevOpsTools.AzureDevOps.PSRule` 0.2.1 from PowerShell Gallery and imports that
exact version, with PSRule 2.9.0. The module repository is not accessed.

```mermaid
flowchart TB
    trigger["Manual run / daily 06:00 UTC"]
    gallery[("PowerShell Gallery<br/>Pinned module + PSRule 2.9.0")]
    ado[("Azure DevOps<br/>Organization and projects")]
    prior[("Retained psrule-results<br/>Same pipeline and branch")]

    subgraph job["Azure Pipelines · fresh ubuntu-latest VM"]
        checkout["Check out dashboard source"]
        install["Install pinned packages"]
        collect["Collect configuration<br/>psrule-azure service connection"]
        evaluate["Evaluate available JSON<br/>PSRule · Baseline.Default"]
        history["Read compatible history<br/>System.AccessToken"]
        report["Generate report and snapshot<br/>Coverage + current results + history"]
        checkout --> install --> collect
        collect -->|"Available targets"| evaluate
        evaluate -->|"Detailed results"| report
        collect -->|"Coverage / no usable targets"| report
        history -->|"Snapshots or visible limitations"| report
    end
    trigger --> checkout
    gallery --> install
    ado --> collect
    prior --> history

    raw[("AzureDevOpsRawData<br/>Original project JSON · partial exports")]
    evidence[("psrule-results<br/>HTML · Markdown · SARIF when evaluated<br/>Completeness · snapshot · history")]
    viewer["Pipeline Reports<br/>Project Health · Readiness · Evolution"]
    collect --> raw
    report --> evidence
    report -->|"Report ready"| viewer

    classDef input fill:#eef2ff,stroke:#6366f1,color:#1e1b4b
    classDef step fill:#eff6ff,stroke:#2563eb,color:#172554
    classDef output fill:#ecfdf5,stroke:#059669,color:#064e3b
    class trigger,gallery,ado,prior input
    class checkout,install,collect,evaluate,history,report step
    class raw,evidence,viewer output
```

`Invoke-PSRuleAssessment.ps1` collects organization data, evaluates PSRule 2.9.0
with `Baseline.Default`, records configuration/module identity and completed
evaluation evidence, and invokes `Export-PSRulePipelineReport.ps1`. No Azure
resource deployment, Monitor ingestion, or Log Analytics query is part of the run.
The package version is pinned by `-ModuleVersion` in the YAML. Update the pin after
publishing a new module version. Installation and import failures remain red.

Each job receives a fresh Microsoft-hosted VM; no devcontainer listener is
required. Hosted capacity and pipeline authorization are managed in Azure DevOps.
The script resets its dedicated `raw-export` and `reports` staging directories
before each attempt, so reused agents cannot contribute stale results. Collection
status is outside the resource input directory. Available exports are evaluated
without the module's optional `-Strict` policy. Recorded collection errors become
escaped pipeline warnings; HTML and Markdown list affected projects, collectors,
statuses, and reason codes. Missing exports never create passing results. Totals
cover only available evaluated data.

Incomplete collection and absent assessment results finish as `SucceededWithIssues`
(yellow) after report generation. No inputs or zero results produce a diagnostic
dashboard with zero evaluated checkpoints and no compliance conclusion. SARIF is
retained only when evaluation produces results. Authentication, terminating export
errors, rule execution, report writing, and artifact publication failures remain
red. Rule violations remain findings, rather than infrastructure failures.

## Report interfaces

| Artifact | Contents |
| --- | --- |
| `AzureDevOpsRawData` | Original JSON exports, preserving project subfolders; partial data survives collection failure. |
| `psrule-results` | `collection-status.json`, persisted `assessment-snapshot.json` (schema 1.0), available `assessment-history.json`, and SARIF, HTML and Markdown when generated. |

Both artifact tasks use `succeededOrFailed()`. HTML publication also requires
`PSRuleReportReady=true`, set only after report generation. The installed BlakYaks
`PublishHtmlReport@1` task displays `Project Health & Compliance` on the run's Reports page.
The Markdown summary is attached with `task.uploadsummary`. HTML is self-contained
and can be downloaded and opened offline. Raw data and reports use pipeline
permissions and retention; retain runs when their evidence must be preserved.

## Project Health and historical evidence

The [three-tab report](project-health.md) uses `AssessmentModel.ps1` for persisted
schema 1.0 evidence and `ProjectHealthReport.ps1` for compact display schema 2.0.
Static HTML and embedded scripts/styles work offline. Organization discovery and
collector gaps remain visible in every tab and without JavaScript; zero results
show an explicit diagnostic instead of a compliance conclusion.

`Get-AssessmentHistory.ps1` reads retained `psrule-results` artifacts from the same
pipeline and branch, using the mapped `System.AccessToken`. History permission or
retention gaps are displayed as limitations. The runner hashes installed module
source/help and PSRule options; incompatible configuration/module identities or
incomplete evidence cannot establish improvement. Current assessment collection,
error and artifact behavior remains as documented above.

## Consolidation and legacy resources

The module repository publishes `DevOpsTools.AzureDevOps.PSRule` through
GitHub Actions to PowerShell Gallery. Assessment installs the published package
and does not depend on private source access. The weekly module assessment is
replaced by this daily assessment. Disable old daily assessment,
weekly assessment and workbook deployment definitions after validating the replacement.
Update definition mappings and remove UI schedule overrides during cutover.

Standalone Bicep and publishing scripts remain for existing installations. They
are outside the assessment execution path; existing Azure resources are not deleted.
The live classic definition may contain a newer Project Health source bundle than
`main`; preserve that reporter when updating it rather than replacing it with an
older template. The reviewed reporter is now included in the source-backed YAML flow.
`Invoke-PSRuleWorkbookAssessment.ps1` and its compressed task bundler remain
standalone legacy compatibility utilities; `run-assessment` never calls them.
Historical run IDs and their report artifacts remain unchanged.

## Validation

Run `Invoke-Pester ./tests -Output Detailed`, `npm test` and `npm run test:browser`.
Assessment tests cover complete and
incomplete collection, raw file retention, repeat attempts, zero results, execution
errors, and rejection of Azure deployment/Monitor requests. Browser checks use
`node tests/PipelineReport.Browser.Tests.cjs` with Playwright Chromium and exercise
the report in an iframe. Verify live artifact and HTML task publication separately.
