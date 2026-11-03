<#
.SYNOPSIS
  Provisions W-fit on Azure and deploys the API. Idempotent; safe to re-run.

.DESCRIPTION
  1. Creates the resource group and deploys infra/main.bicep (all resources in one RG, see docs/COSTS.md).
  2. Reuses the existing API key from Key Vault (or generates a new one on first deploy).
  3. Creates the Function App's managed-identity user in Azure SQL (passwordless).
  4. Publishes backend/src/WFit.Api to the Flex Consumption app (zip deploy).
  5. Smoke-tests /api/health and an authenticated endpoint (wakes SQL, runs migrations, seeds catalog).

.EXAMPLE
  ./infra/deploy.ps1 -AlertEmail you@example.com
  ./infra/deploy.ps1 -SkipInfra          # code-only redeploy
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = '<resource-group>',
    [string]$Location = 'westeurope',
    [string]$AlertEmail,
    [switch]$SkipInfra,
    [switch]$SkipCode,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Split-Path $PSScriptRoot -Parent

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

Step 'Checking Azure login'
$account = az account show -o json | ConvertFrom-Json
$me = az ad signed-in-user show --query '{id:id,upn:userPrincipalName}' -o json | ConvertFrom-Json
if (-not $AlertEmail) { $AlertEmail = $me.upn }
Write-Host "Subscription: $($account.name) | Tenant: $($account.tenantDefaultDomain) | User: $($me.upn)"

if (-not $SkipInfra) {
    Step "Ensuring resource group $ResourceGroup ($Location)"
    az group create -n $ResourceGroup -l $Location --tags app=w-fit costCenter=personal -o none

    # Keep the API key stable across redeployments.
    $apiKey = $null
    $existingVault = az keyvault list -g $ResourceGroup --query '[0].name' -o tsv
    if ($existingVault) {
        $apiKey = az keyvault secret show --vault-name $existingVault -n wfit-api-key --query value -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) { $apiKey = $null }
    }
    if (-not $apiKey) {
        $bytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $apiKey = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        Write-Host 'Generated a new API key.'
    }

    $clientIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).Trim()

    # Secure parameters go through a temp file (never on the command line, never in the repo).
    $paramFile = Join-Path ([IO.Path]::GetTempPath()) "wfit-params-$([guid]::NewGuid()).json"
    @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            sqlAdminObjectId = @{ value = $me.id }
            sqlAdminLogin    = @{ value = $me.upn }
            apiKey           = @{ value = $apiKey }
            clientIp         = @{ value = $clientIp }
            alertEmail       = @{ value = $AlertEmail }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $paramFile -Encoding utf8

    try {
        if ($WhatIf) {
            Step 'What-if'
            az deployment group what-if -g $ResourceGroup -f (Join-Path $PSScriptRoot 'main.bicep') -p "@$paramFile"
            return
        }
        Step 'Deploying infra/main.bicep (takes a few minutes)'
        $raw = az deployment group create -g $ResourceGroup -n wfit-main `
            -f (Join-Path $PSScriptRoot 'main.bicep') -p "@$paramFile" `
            --query properties.outputs -o json
        if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Bicep deployment failed – see the error above.' }
        $outputs = $raw | ConvertFrom-Json
    }
    finally {
        Remove-Item $paramFile -ErrorAction SilentlyContinue
    }
}
else {
    $outputs = az deployment group show -g $ResourceGroup -n wfit-main --query properties.outputs -o json | ConvertFrom-Json
}

$funcName = $outputs.functionAppName.value
if (-not $funcName) { throw 'Deployment outputs are missing – infrastructure deployment did not succeed.' }
$apiBase = $outputs.apiBaseUrl.value
$sqlFqdn = $outputs.sqlServerFqdn.value
$dbName = $outputs.sqlDatabaseName.value
$vaultName = $outputs.keyVaultName.value
Write-Host "Function app: $funcName`nAPI: $apiBase"

if (-not $SkipInfra) {
    Step 'Granting the Function App managed identity access to Azure SQL'
    $principalId = az functionapp identity show -g $ResourceGroup -n $funcName --query principalId -o tsv
    $appId = az ad sp show --id $principalId --query appId -o tsv
    $token = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
    $sql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$funcName')
BEGIN
    DECLARE @sid varbinary(16) = CAST(CAST('$appId' AS uniqueidentifier) AS varbinary(16));
    DECLARE @stmt nvarchar(max) = N'CREATE USER [$funcName] WITH SID = ' + CONVERT(nvarchar(max), @sid, 1) + N', TYPE = E;';
    EXEC (@stmt);
END;
IF IS_ROLEMEMBER('db_owner', N'$funcName') = 0 ALTER ROLE db_owner ADD MEMBER [$funcName];
"@
    # Serverless SQL may need up to a minute to resume.
    for ($i = 1; $i -le 5; $i++) {
        try {
            $conn = [System.Data.SqlClient.SqlConnection]::new("Server=tcp:$sqlFqdn,1433;Database=$dbName;Encrypt=True;Connect Timeout=120;")
            $conn.AccessToken = $token
            $conn.Open()
            $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120
            [void]$cmd.ExecuteNonQuery()
            $conn.Close()
            Write-Host 'SQL user ready.'
            break
        }
        catch {
            if ($i -eq 5) { throw }
            Write-Host "SQL not ready yet ($($_.Exception.Message.Split([Environment]::NewLine)[0])); retrying in 20s…"
            Start-Sleep -Seconds 20
        }
    }
}

if (-not $SkipCode) {
    Step 'Publishing backend'
    $publishDir = Join-Path ([IO.Path]::GetTempPath()) "wfit-publish-$([guid]::NewGuid())"
    $zip = "$publishDir.zip"
    dotnet publish (Join-Path $root 'backend/src/WFit.Api/WFit.Api.csproj') -c Release -o $publishDir --nologo -v quiet
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($publishDir, $zip)
    try {
        az functionapp deployment source config-zip -g $ResourceGroup -n $funcName --src $zip -o none
    }
    finally {
        Remove-Item $publishDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -ErrorAction SilentlyContinue
    }
}

Step 'Smoke test'
$health = $null
for ($i = 1; $i -le 12 -and -not $health; $i++) {
    try { $health = Invoke-RestMethod "$apiBase/health" -TimeoutSec 60 } catch { Start-Sleep -Seconds 10 }
}
if (-not $health) { throw 'Health check failed.' }
Write-Host "health: $($health | ConvertTo-Json -Compress)"

$key = az keyvault secret show --vault-name $vaultName -n wfit-api-key --query value -o tsv
$usage = Invoke-RestMethod "$apiBase/ai/usage" -Headers @{ 'X-Api-Key' = $key } -TimeoutSec 180
Write-Host "ai/usage (SQL + migrations OK): $($usage | ConvertTo-Json -Compress)"

Write-Host "`nDone. Configure the app (Settings → Backend connection):" -ForegroundColor Green
Write-Host "  API URL : $apiBase"
Write-Host "  API key : az keyvault secret show --vault-name $vaultName -n wfit-api-key --query value -o tsv"
