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


## Existing raw Pipeline Artifact

The assessment run 138 already exposes **AzureDevOpsRawData** (a Pipeline Artifact) with project folders and `.ado.json` files. **No pipeline modification is required**. The original `psrule-results` SARIF report remains available as a secondary data source.

The `fxRawJsonFiles` query now calls the Azure DevOps Build Artifacts API to retrieve the Pipeline Artifact's dedup manifest (`resource.data`), then downloads each JSON blob via the Build Artifacts Get File endpoint using `fileId` and `fileName`. `RawFiles` has `BuildId`, `FilePath` and `RawJson`.

To test, open the PBIP, set `Config` for the organization `ai-experiments`, project `PSRule.Rules.AzureDevOps`, and the **pipeline definition ID** (not the build ID 138). Use `MaxBuilds=1` and refresh `RawFiles` with your existing Basic/PAT credential.

**Not yet verified in Power BI Desktop.** The pipeline manifest can contain `manifestReferences` for nested directories; the current query processes JSON entries directly listed under `items`, so additional manifest traversal may be needed to include all project subfolders. Verify file count and paths against the artifact browser before using the data. Do not interpret missing rows as missing resources until this check passes.
