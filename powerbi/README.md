# PSRule Power BI

Initial Power BI Project for Azure DevOps PSRule assessment results.

Open `PSRule.pbip` with Power BI Desktop. The initial report contains three empty pages: Overview, Evolution, and Remediation Priorities. This is **not** a finished visual report and has **not** been verified in Power BI Desktop here.

The semantic model is defined in `PSRule.SemanticModel/model.bim`, where the queries use Azure DevOps REST API to retrieve `psrule-results` build artifacts and parse SARIF reports. Configure organization, project, and definition ID in the Config expression. Authenticate `https://dev.azure.com` using Basic with a short-lived PAT as password, stored only in the Power BI credential store; do not commit secrets.

Known limitations: the current SARIF result set may not include passing checks, so compliance percentages must not be derived from it. The initial query only loads successful builds and assumes a File Container artifact path. Validate against a real run, and include builds with rule assertion failures if those runs still publish artifacts. Custom Entra ID connector is planned for later.
