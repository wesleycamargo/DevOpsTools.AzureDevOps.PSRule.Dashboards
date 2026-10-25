# PSRule assessment — Power BI

Open `PSRule.pbip` in Power BI Desktop.

## Configure Azure DevOps REST API with a PAT

The source uses Power Query `Web.Contents("https://dev.azure.com", ...)`. **The PAT is not embedded in the project.** Power BI's Web data source credential manager sends it over HTTPS using HTTP Basic.

1. Create a **short-lived PAT** in Azure DevOps with **Build (Read)** permission for the relevant organization. Do not paste it into this repository or any chat.
2. Open **Home > Transform data** and locate `Config` (Advanced Editor). Set `Organization`, `Project`, `PipelineDefinitionId`. Keep `ArtifactName = "psrule-results"` and `SarifFileName = "psrule-results.sarif"`. Start with `MaxBuilds = 1`.
3. Select **Data source settings > https://dev.azure.com > Edit Permissions > Edit Credentials**. If a previous Organizational Account sign-in failed, use **Clear Permissions**, then retry.
4. Select **Basic**, enter `azdo` as the username and your PAT as the password. Choose the root URL `https://dev.azure.com` for the credential scope, and **Save**.
5. Select the `Builds` query and **Refresh Preview**. Once it returns a build, select `AssessmentResults`. Then **Close & Apply**.

The token is local to the credentials store; the project can be committed without including it. Different users will need to authenticate separately.

## Troubleshooting

- **401 / 403:** confirm the PAT's organization, expiry and Build (Read) scope, plus permission to view the relevant pipeline.
- **No builds:** confirm the pipeline definition ID. Currently the query includes only successfully completed builds; PSRule runs that fail because of findings can still contain valid artifacts and are excluded.
- **404 reading SARIF:** the query currently assumes a File Container artifact at `psrule-results/psrule-results.sarif`; validate the item path using an actual build.
- **Schema / model error:** this is a preliminary PBIP project generated without a Power BI Desktop runtime to validate. The three pages are placeholders, not complete dashboards.

## Data limitations

SARIF can omit successful assessments, so do not calculate a compliance rate based solely on returned findings. Validate the results before using them for prioritization.

The Entra ID custom connector is a future replacement for PAT authentication.


## Raw Azure DevOps data (new, unvalidated)

The primary data source is now intended to be `RawFiles` instead of SARIF findings.

The manual assessment pipeline (`azure-pipelines/publish-workbooks.yml`) has a **branch-only** addition to publish the original export directory as a File Container Build Artifact named `psrule-raw-data` after export succeeds, even if later rule assertions fail. This does **not** change the existing `AzureDevOpsRawData` Pipeline Artifact in the daily pipeline. The change only takes effect on a pipeline run that uses this branch or after merging, and only if raw export completes.

The Power Query `fxRawJsonFiles` queries the build artifact metadata, enumerates recursive JSON file paths and requests each JSON file individually. The `RawFiles` table provides `BuildId`, `FilePath`, and `RawJson` (binary JSON) without assuming unverified JSON fields. Other semantic tables are unchanged.

**First-run validation:**
1. Execute the manual assessment against the updated branch (the currently published run 138 predates the new raw artifact).
2. Confirm `psrule-raw-data` is available under that run's published artifacts.
3. Refresh `RawFiles` in Power BI with `MaxBuilds=1`. A build without the new artifact will fail deliberately rather than silently returning an empty report.
4. Inspect a real JSON file's schema before adding normalized tables for projects, repositories, pipelines and settings.

The REST File Container item-list response structure, authentication and report compatibility have **not** been validated in Power BI Desktop; if the connector returns an error, inspect the API response instead of assuming the source file is empty. Existing placeholder pages are not final dashboards.

**Security:** raw data may include internal organization settings or other confidential metadata. Restrict permissions to the artifacts and report accordingly. No PAT is written to Git.
