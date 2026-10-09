[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [object[]]$Results,
    [Parameter(Mandatory)]
    [string]$IngestionEndpoint,
    [Parameter(Mandatory)]
    [string]$RuleImmutableId,
    [Parameter(Mandatory)]
    [string]$RunId
)
$ErrorActionPreference = 'Stop'
$token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not acquire Azure Monitor ingestion authentication.' }
$uri = "$($IngestionEndpoint.TrimEnd('/'))/dataCollectionRules/$RuleImmutableId/streams/Custom-PSRule?api-version=2023-01-01"
$timestamp = [DateTime]::UtcNow.ToString('o')
for ($offset = 0; $offset -lt $Results.Count; $offset += 100) {
    $last = [Math]::Min($offset + 99, $Results.Count - 1)
    $records = @($Results[$offset..$last] | ForEach-Object {
        $field = [ordered]@{id = $_.Field.id; name = $_.Field.name}
        # PSRule stringifies structured IDs; retain their JSON metadata for workbook filters.
        if ($_.TargetObject.id -is [pscustomobject] -or $_.TargetObject.id -is [Collections.IDictionary]) {
            $field.id = $_.TargetObject.id | ConvertTo-Json -Depth 8 -Compress
        }
        [ordered]@{
            TimeGenerated = $timestamp
            RunId_s = $RunId
            RuleName_s = $_.RuleName
            DisplayName_s = $_.Info.DisplayName
            TargetName_s = $_.TargetName
            TargetType_s = $_.TargetType
            Outcome_s = [string]$_.Outcome
            Annotations_s = ($_.Info.Annotations | ConvertTo-Json -Depth 8 -Compress)
            Field_s = ($field | ConvertTo-Json -Depth 8 -Compress)
        }
    })
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $records -Depth 10 -Compress))
    if ($body.Length -gt 900000) { throw 'A results batch exceeds the ingestion request size limit.' }
    for ($attempt = 0; ; $attempt++) {
        try {
            $null = Invoke-WebRequest -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $body
            break
        } catch {
            $status = [int]$_.Exception.Response.StatusCode
            if ($attempt -ge 4 -or ($status -ne 429 -and ($status -lt 500 -or $status -gt 599))) { throw }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt + 1))
        }
    }
}
Write-Host "Published $($Results.Count) PSRule results with run ID $RunId."
