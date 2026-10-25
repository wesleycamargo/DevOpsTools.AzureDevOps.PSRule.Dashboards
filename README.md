# DevOpsTools.AzureDevOps.PSRule.Dashboards

## Overview

`run-assessment` collects Azure DevOps data and presents PSRule findings directly
in the pipeline. It runs daily at 06:00 UTC on `main`, or manually, using `AI-Pool`.
It does not deploy Azure workbooks or publish to Log Analytics.

## Getting started

Create or update the assessment definition to use `azure-pipelines/run-assessment.yml`.
Authorize the existing `psrule-azure` service connection for Azure DevOps collection
and `github.com_wesleycamargo` for checking out this dashboard repository.
The service principal needs read access to the assessed organization and projects.
No workspace, ingestion rule, shared workspace key, or Azure deployment is required.

The pipeline installs `DevOpsTools.AzureDevOps.PSRule` **0.2.0** from
PowerShell Gallery and imports that exact version alongside PSRule **2.9.0**.
Only dashboard source is checked out; the private module repository is outside
the assessment execution path. To adopt a later package release, update
`-ModuleVersion` in `azure-pipelines/run-assessment.yml` after publishing it.
Installation or import failures stop the assessment and fail the run.

### Pipeline run dashboard

The assessment pipeline generates `psrule-dashboard.html` and
`psrule-summary.md` directly from the detailed assessment results. The dashboard
contains totals, failure charts by rule and resource, and a findings table with
project, outcome, and severity filters, text search, and chart drill-downs.
It is a snapshot of one assessment run.

An organization administrator must install
[BlakYaks HTML Reports](https://marketplace.visualstudio.com/items?itemName=blakyaks.azure-pipelines-html-reports)
in the Azure DevOps organization before running the updated pipeline. Its
`PublishHtmlReport@1` task displays the dashboard on the pipeline run's Reports
page. The Markdown summary appears on the run's Extensions tab through
[`task.uploadsummary`](https://learn.microsoft.com/en-us/azure/devops/pipelines/scripts/logging-commands?view=azure-devops#uploadsummary-add-some-markdown-content-to-the-build-summary).
The pipeline uses the `PSRuleReportReady` variable to publish the HTML tab only
after a valid report has been generated.

The `psrule-results` artifact retains HTML, Markdown, SARIF, and collection status
when available. The separate `AzureDevOpsRawData` artifact retains the original JSON
export with project subfolders, including partial exports after collection failure.
Available exports are evaluated even when collection is incomplete. HTML and Markdown
show affected projects, collectors, statuses, and reason codes; totals cover only
the available evaluated data. Collection gaps finish as `SucceededWithIssues` (yellow). Download the artifact
and open `psrule-dashboard.html` in a browser to use the dashboard offline;
all styles, scripts, and report data are embedded in the file. Readers need
permission to view the pipeline run and its artifacts, rather than additional
Log Analytics access. Downloaded reports contain assessment findings, so share
them with the same audience as the run. Reports follow the pipeline's run and
artifact retention policy; retain the run or download its artifact to keep a
snapshot longer. Authentication, rule execution, report generation, and artifact publication failures
fail the run; rule violations are findings. With no usable inputs or results, a
diagnostic dashboard reports zero evaluated checkpoints and the run finishes yellow.
SARIF is retained only when evaluation produces results.

From this repository, run the offline PowerShell tests with
`Invoke-Pester ./tests -Output Detailed`. For browser checks, install Playwright
in a temporary directory, install its Chromium browser, set `NODE_PATH` to that
directory's `node_modules`, and run `node tests/PipelineReport.Browser.Tests.cjs`.
Chromium also requires the host libraries listed by `playwright install-deps chromium`.
The browser checks exercise the report in an iframe, matching the viewer's
rendering method. A live run must also confirm the Reports page and Markdown
summary in Azure DevOps.

See [dashboard architecture](docs/architecture.md) for assessment flow, pipeline
structure and report publication.

### Legacy Azure resources

The Bicep templates and standalone ingestion scripts remain available for existing
installations. They are not used by `run-assessment`; consolidation does not delete
previously deployed resources. The old daily and separate deployment definitions
must be disabled during cutover to prevent continued Azure publication.

## References and acknowledgements

- [PSRule](https://microsoft.github.io/PSRule) by [@BernieWhite](https://github.com/BernieWhite)
- [PSRule.Monitor](https://github.com/microsoft/PSRule.Monitor) by [@BernieWhite](https://github.com/BernieWhite)
- [PSRule.Rules.AzureDevOps](https://github.com/cloudyspells/PSRule.Rules.AzureDevOps) by [Roderick Bant](https://github.com/webtonize)
