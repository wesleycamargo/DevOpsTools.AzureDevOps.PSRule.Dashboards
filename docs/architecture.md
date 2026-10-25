# Dashboard architecture

## Assessment pipeline

`azure-pipelines/run-assessment.yml` is the dashboard repository's only pipeline
entry point. It runs manually or daily at 06:00 UTC on `main`, with push and PR
triggers disabled. `AI-Pool` executes the job; `psrule-azure` supplies the Azure
DevOps token. Rules are checked out from `main` through `github.com_wesleycamargo`.

```text
Schedule / manual -> Check out dashboards + rules -> Export organization
                                                       |          |
                                                       |          +-> Raw artifact
                                                       v
                                                Collection diagnostics
                                                       |
                                                       v
                                                Evaluate rules
                                                       |
                                                       v
                                             HTML + Markdown + SARIF
                                                       |
                                                       v
                                           Pipeline dashboard + reports
```

`Invoke-PSRuleAssessment.ps1` collects organization data, evaluates PSRule 2.9.0
with `Baseline.Default`, and invokes `Export-PSRulePipelineReport.ps1`. No Azure
resource deployment, Monitor ingestion, or Log Analytics query is part of the run.

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
| `psrule-results` | `collection-status.json`, and SARIF, HTML and Markdown when generated. |

Both artifact tasks use `succeededOrFailed()`. HTML publication also requires
`PSRuleReportReady=true`, set only after report generation. The installed BlakYaks
`PublishHtmlReport@1` task displays `PSRule Dashboard` on the run's Reports page.
The Markdown summary is attached with `task.uploadsummary`. HTML is self-contained
and can be downloaded and opened offline. Raw data and reports use pipeline
permissions and retention; retain runs when their evidence must be preserved.

## Consolidation and legacy resources

The module repository retains its Azure Artifacts publishing pipeline. Its weekly
assessment is replaced by this daily assessment. Disable old daily assessment,
weekly assessment and workbook deployment definitions after validating the replacement.
Update definition mappings and remove UI schedule overrides during cutover.

Standalone Bicep and publishing scripts remain for existing installations. They
are outside the assessment execution path; existing Azure resources are not deleted.
The live classic definition may contain a newer Project Health source bundle than
`main`; preserve that reporter when updating it rather than replacing it with an
older template. A source-backed YAML migration must first include that reviewed
reporter. Historical run IDs and their report artifacts remain unchanged.

## Validation

Run `Invoke-Pester ./tests -Output Detailed`. Assessment tests cover complete and
incomplete collection, raw file retention, repeat attempts, zero results, execution
errors, and rejection of Azure deployment/Monitor requests. Browser checks use
`node tests/PipelineReport.Browser.Tests.cjs` with Playwright Chromium and exercise
the report in an iframe. Verify live artifact and HTML task publication separately.
