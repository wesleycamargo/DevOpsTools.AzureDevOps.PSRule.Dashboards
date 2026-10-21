# Dashboard architecture

This document describes the repository sources.
It does not establish the current state of deployed Azure resources or remote branches.

## Components

| Component | Responsibility |
| --- | --- |
| `Invoke-PSRuleWorkbookAssessment.ps1` | Import the supplied rule module, collect inputs, evaluate rules, create reports, publish results, and check ingestion. |
| `Export-PSRulePipelineReport.ps1`, `AssessmentModel.ps1` and `src/templates/assessment.{js,css}` | Convert detailed results into a standalone HTML snapshot and Markdown summary. |
| `Get-AssessmentHistory.ps1` | Discover, validate and aggregate retained assessment artifacts; embed history in the main dashboard. |
| `Publish-PSRuleWorkbookResults.ps1` | Convert detailed results to the ingestion schema and send authenticated batches. |
| `Deploy-PSRuleWorkbooks.ps1` and `src/bicep/workbooks.bicep` | Deploy and inspect the workspace, result table, ingestion rule, and five workbooks. |
| `src/bicep/main.bicep` and older analysis scripts | Preserve the original deployment and shared-key Monitor path. This path is distinct from the manual workbook pipeline. |

## Manual assessment pipeline

`azure-pipelines/publish-workbooks.yml` disables push and PR triggers and uses the self-hosted `AI-Pool`.
It checks out dashboards under `s/dashboards` and rules under `s/rules`.
The rule repository resource selects `main` through the configured GitHub endpoint.
The Azure CLI task uses the `psrule-azure` service connection.

```mermaid
flowchart TD
    Checkout["Check out dashboards and rule source"] --> Auth["Azure service connection and Azure CLI tokens"]
    Auth --> Export["Export organization JSON"]
    Export --> Evaluate["PSRule 2.9.0 and Baseline.Default"]
    Evaluate --> Reports["Write SARIF, HTML, and Markdown"]
    Reports --> Summary["Attach Markdown and set PSRuleReportReady"]
    Summary --> Ingest["Publish Custom-PSRule batches"]
    Ingest --> Query["Check total and failed counts in PSRule_CL"]
    Query --> Artifact["Publish available psrule-results artifact"]
    Artifact --> HTML["Attach HTML report when ready"]
    Ingest --> Workbooks["Azure Monitor Workbooks query PSRule_CL"]
```

Artifact publication uses `succeededOrFailed()`, so it can execute after the assessment task fails.
HTML publication additionally requires `PSRuleReportReady` to equal `true`.
The assessment script sets this variable after report generation and before ingestion.
Expected rule failures remain visible in reports. Zero results stop report generation. Rule execution errors retain reports and block workbook ingestion.
Collection now writes a completeness report. Partial or unknown collection retains current-run reports and blocks workbook ingestion. See [assessment analytics](assessment-analytics.md) for the current reporting contract and history integration.

The `psrule-results` artifact contains `psrule-results.sarif`, `psrule-dashboard.html`, and `psrule-summary.md` when generation succeeds.
The script also attaches Markdown to the run summary.
`PublishHtmlReport@1` requires the HTML Reports extension and uses the HTML file as `reportDir`.
Open the run's **Reports** page to view `PSRule Dashboard`.
The **Code Coverage** page is a separate report surface. This pipeline contains no coverage publication task.

## Azure result contract

`workbooks.bicep` creates a Log Analytics workspace, the `PSRule_CL` table, and a direct data collection rule.
The input stream is `Custom-PSRule`. Its data flow writes to `Custom-PSRule_CL`.

| Column | Meaning |
| --- | --- |
| `TimeGenerated` | UTC publication timestamp. |
| `RunId_s` | Organization name and pipeline build ID. |
| `RuleName_s`, `DisplayName_s` | Rule identifier and display name. |
| `TargetName_s`, `TargetType_s` | PSRule target identity and type. |
| `Outcome_s` | Rule outcome. |
| `Annotations_s` | JSON annotations from the rule information. |
| `Field_s` | JSON target fields, including structured identity metadata when available. |

The publisher requests an Azure Monitor bearer token and submits batches of at most 100 records.
It rejects a batch body larger than 900,000 bytes. It retries HTTP 429 and HTTP 5xx responses up to four times.
All records in one publisher invocation share a timestamp and run ID.

Assessment obtains a separate query token and checks total and failed counts for the run.
It makes up to 45 query attempts, with 20-second waits after unsuccessful attempts.
Excess records trigger a duplicate-record error. A timeout fails the assessment task.
This check does not roll back partial ingestion or prevent a repeated submission.

Five workbook modules supply the main view, resource state, rule summary, resources by rule, and rule hits by resource.
The template configures 30-day retention and public ingestion and query endpoints.
It does not define identity role assignments. Required ingestion and query access must exist outside this template.

## Other pipeline entry points

| Definition | Structure and dependency |
| --- | --- |
| `azure-pipelines/deploy-workbooks.yml` | Manual deployment on `AI-Pool` through `psrule-azure`. Validates and previews Bicep, creates deployment `psrule-workbooks`, and checks workbook content and table queries. |
| `azure-pipelines/azure-pipelines.yml` | Daily 06:00 UTC schedule on `main`, hosted Ubuntu agent, one `Run` stage. Uses `devops-assessment-vg001`, an Azure Artifacts module, and the older Monitor analysis script. Publishes raw and analysis artifacts from the export directory. |

The manual assessment reads outputs from deployment `psrule-workbooks`.
These outputs supply the workspace ID, ingestion endpoint, and immutable rule ID.
The YAML files do not chain deployment and assessment automatically.

## Operation and validation

Protect artifacts and workspace results because they contain organization and target identities.
Restrict service-connection and variable-group access. Raw exports in the older pipeline require additional care.
Pipeline retention controls snapshots. Log Analytics retention controls historical records.

Run offline dashboard tests with `Invoke-Pester ./tests -Output Detailed` from this repository.
Browser checks use `tests/PipelineReport.Browser.Tests.cjs` and Playwright Chromium.
They exercise iframe rendering. They do not establish extension installation or live workspace permissions.

The [module architecture](../../PSRule.Rules.AzureDevOps/docs/architecture.md) contains the complete pipeline inventory, module boundaries, risks, and decision records.
That link assumes the two repositories retain their current workspace directory names.

### Source entry points

- [Manual assessment pipeline](../azure-pipelines/publish-workbooks.yml) and [assessment script](../src/scripts/Invoke-PSRuleWorkbookAssessment.ps1).
- [Report generator](../src/scripts/Export-PSRulePipelineReport.ps1) and [ingestion publisher](../src/scripts/Publish-PSRuleWorkbookResults.ps1).
- [Deployment pipeline](../azure-pipelines/deploy-workbooks.yml), [deployment script](../src/scripts/Deploy-PSRuleWorkbooks.ps1), and [workbook infrastructure](../src/bicep/workbooks.bicep).
- [Legacy daily pipeline](../azure-pipelines/azure-pipelines.yml) and [legacy infrastructure](../src/bicep/main.bicep).
