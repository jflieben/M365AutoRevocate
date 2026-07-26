#Requires -Version 7.0
<#
.SYNOPSIS
    Fast, non-interactive UPDATE for an existing M365AutoRevocate deployment.

.DESCRIPTION
    Redeploys the function code and the admin web app onto an app that is already
    provisioned, and stamps the new version. It also reconciles the managed
    identity's API permissions against deploy/permissions.json (granting anything a
    newer version added), so an update never leaves a new feature missing its
    permission. There are still no interactive prompts -- suitable for scheduled
    patching / CI. It does NOT touch the Exchange Online mailbox scoping or the
    Entra app registration (those belong to the full deploy). Granting new API
    permissions needs the caller to be Global Administrator / Privileged Role
    Administrator; when they lack that (e.g. an unattended CI identity) the missing
    grants are reported, not fatal.

    Resolves the same deterministic per-tenant resource names as the deploy
    script (from the sender domain's tenant), or you can pass -AppName /
    -ResourceGroup / -StorageAccount explicitly.

.EXAMPLE
    ./deploy/Update-M365AutoRevocate.ps1 -SubscriptionId <sub> -SenderUpn noreply@contoso.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$SenderUpn,
    [string]$ResourceGroup = 'rg-m365autorevocate',
    [string]$AppName,
    [string]$StorageAccount
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$AllowFail)
    if ($AzArgs -notcontains '--only-show-errors') { $AzArgs += '--only-show-errors' }
    $out = & az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0) { if (-not $AllowFail) { throw "az $($AzArgs -join ' ') failed:`n$out" }; return $null }
    return $out
}
function Get-AzScalar { param($Value) return ((@($Value) | Where-Object { "$_".Trim() } | Select-Object -Last 1) | ForEach-Object { "$_".Trim() }) }
function Get-StableSuffix {
    param([Parameter(Mandatory)][string]$Seed)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Seed.ToLower()))
    return (([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 8)).ToLower()
}
function Get-TenantIdFromDomain {
    param([Parameter(Mandatory)][string]$Domain)
    try {
        $resp = Invoke-RestMethod -Method Get -Uri "https://login.microsoftonline.com/$Domain/v2.0/.well-known/openid-configuration" -ErrorAction Stop
        if ($resp.issuer -match '([0-9a-fA-F-]{36})') { return $Matches[1] }
    }
    catch { return $null }
    return $null
}

# Shared permission reconciler (Update-ARPermission), reading deploy/permissions.json.
. (Join-Path $PSScriptRoot 'AR.Common.ps1')

# --- Version -----------------------------------------------------------------
$moduleVersion = '1.0.0'
try {
    $vf = Join-Path $PSScriptRoot '..\VERSION'
    if (Test-Path $vf) { $moduleVersion = (Get-Content $vf -Raw).Trim() }
    else { $moduleVersion = (Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\src\Modules\AutoRevocate\AutoRevocate.psd1')).ModuleVersion }
}
catch { }

# --- Preflight + tenant lock -------------------------------------------------
Write-Step 'Preflight'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required (https://aka.ms/azcli).' }
$senderDomain = ($SenderUpn -split '@')[-1]
$expectedTenantId = Get-TenantIdFromDomain -Domain $senderDomain
$account = az account show 2>$null | ConvertFrom-Json
if ($expectedTenantId -and (-not $account -or $account.tenantId -ne $expectedTenantId)) {
    az login --tenant $expectedTenantId --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Sign-in to tenant $expectedTenantId failed." }
}
Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$account = az account show | ConvertFrom-Json
$tenantId = $account.tenantId
if ($expectedTenantId -and $tenantId -ne $expectedTenantId) { throw "Subscription $SubscriptionId is not in tenant $expectedTenantId." }

$stableSuffix = Get-StableSuffix -Seed $tenantId
if (-not $AppName) { $AppName = "func-autorevocate-$stableSuffix" }
if (-not $StorageAccount) { $StorageAccount = "arevoc$stableSuffix"; if ($StorageAccount.Length -gt 24) { $StorageAccount = $StorageAccount.Substring(0, 24) } }

$existing = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'name', '-o', 'tsv') -AllowFail)
if (-not $existing) { throw "Function app '$AppName' not found in '$ResourceGroup'. Run the full deploy script first." }
$oldVersion = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', "[?name=='AR_VERSION'].value | [0]", '-o', 'tsv') -AllowFail)
Write-Host "App: $AppName   Current version: $(if ($oldVersion){$oldVersion}else{'unknown'})   ->   $moduleVersion"
if ($PSCmdlet.ShouldProcess($AppName, "Update M365AutoRevocate to $moduleVersion") -eq $false) { return }

# --- Package + deploy code (excludes local.settings.json) --------------------
Write-Step 'Deploy function code'
$srcPath = Join-Path $PSScriptRoot '..\src' | Resolve-Path
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "autorevocate-$([Guid]::NewGuid().ToString('N')).zip"
$pkgStage = Join-Path ([System.IO.Path]::GetTempPath()) "arpkg-$([Guid]::NewGuid().ToString('N'))"
Copy-Item -Path $srcPath -Destination $pkgStage -Recurse -Force
Get-ChildItem -Path $pkgStage -Filter 'local.settings.json*' -Recurse -Force | Remove-Item -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $pkgStage '*') -DestinationPath $zipPath -Force
Remove-Item $pkgStage -Recurse -Force -ErrorAction SilentlyContinue

$deployed = $false; $deployErr = ''
foreach ($m in @(
        @{ Name = 'one-deploy'; Cmd = @('functionapp', 'deploy', '--name', $AppName, '--resource-group', $ResourceGroup, '--src-path', $zipPath, '--type', 'zip') },
        @{ Name = 'config-zip'; Cmd = @('functionapp', 'deployment', 'source', 'config-zip', '--name', $AppName, '--resource-group', $ResourceGroup, '--src', $zipPath) }
    )) {
    for ($i = 1; $i -le 2 -and -not $deployed; $i++) {
        $out = & az @($m.Cmd) --only-show-errors 2>&1
        if ($LASTEXITCODE -eq 0) { $deployed = $true; Write-Host "Deployed via $($m.Name)." }
        else { $deployErr = ($out | Out-String).Trim(); Start-Sleep -Seconds 10 }
    }
    if ($deployed) { break }
}
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
if (-not $deployed) { throw "Code deployment failed.`n$deployErr" }

# --- Re-upload the web app (preserving auth values) --------------------------
Write-Step 'Update web app'
try {
    $appId = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', "[?name=='AR_ADMIN_CLIENT_ID'].value | [0]", '-o', 'tsv') -AllowFail)
    $hostName = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'defaultHostName', '-o', 'tsv') -AllowFail)
    if (-not $hostName) { $hostName = "$AppName.azurewebsites.net" }
    $webStorage = "arweb$($StorageAccount -replace '^arevoc','')"
    if ($webStorage.Length -gt 24) { $webStorage = $webStorage.Substring(0, 24) }
    $webKey = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'keys', 'list', '--account-name', $webStorage, '--resource-group', $ResourceGroup, '--query', '[0].value', '-o', 'tsv') -AllowFail)
    if (-not $webKey) { throw "Web storage account '$webStorage' not found; run the full deploy first." }
    $webStage = Join-Path ([System.IO.Path]::GetTempPath()) "arweb-$([Guid]::NewGuid().ToString('N'))"
    Copy-Item -Path (Join-Path $PSScriptRoot '..\web' | Resolve-Path) -Destination $webStage -Recurse -Force
    if ($appId) {
        $authJs = @"
window.AR_AUTH = {
  clientId: "$appId",
  tenantId: "$tenantId",
  apiBase: "https://$hostName/api",
  apiScope: "api://$appId/access_as_user"
};
"@
        Set-Content -Path (Join-Path $webStage 'authConfig.js') -Value $authJs -Encoding UTF8
    }
    else { Write-Warning 'AR_ADMIN_CLIENT_ID not found; leaving the existing authConfig.js in place (not overwriting with placeholders).'; Remove-Item (Join-Path $webStage 'authConfig.js') -Force -ErrorAction SilentlyContinue }
    Invoke-Az -AzArgs @('storage', 'blob', 'upload-batch', '--account-name', $webStorage, '--account-key', $webKey, '--destination', '$web', '--source', $webStage, '--overwrite') | Out-Null
    Remove-Item $webStage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Web app updated.'
}
catch { Write-Warning "Web app update did not complete: $($_.Exception.Message) (if this is a 403/AuthorizationFailure, the web storage firewall may not allow your current IP -- add it under storage account '$webStorage' > Networking, or run from an allowed network)." }

# --- Reconcile API permissions -----------------------------------------------
# A newer version may need a permission an older deploy never granted. Grant
# anything missing from deploy/permissions.json (idempotent; the full deploy runs
# the same reconciler). Non-fatal if the caller lacks the rights to grant.
Write-Step 'API permissions'
$principalId = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'identity', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'principalId', '-o', 'tsv') -AllowFail)
if ($principalId) {
    $permFailed = @(Update-ARPermission -PrincipalId $principalId)
    if ($permFailed.Count -gt 0) {
        Write-Warning "Some API permissions are still missing: $($permFailed -join ', ')."
        Write-Warning 'Re-run as Global Administrator / Privileged Role Administrator to grant them (and consent), or grant them in the portal.'
    }
    else { Write-Host 'API permissions are up to date.' -ForegroundColor Green }
}
else { Write-Warning 'Could not resolve the managed identity principal id; skipping API-permission reconciliation. Run the full deploy to be sure permissions are current.' }

# --- Stamp version, sync triggers, restart -----------------------------------
Write-Step 'Finalise'
Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'set', '--name', $AppName, '--resource-group', $ResourceGroup, '--settings', "AR_VERSION=$moduleVersion") | Out-Null
Invoke-Az -AzArgs @('rest', '--method', 'post', '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/syncfunctiontriggers?api-version=2023-12-01") -AllowFail | Out-Null
Invoke-Az -AzArgs @('functionapp', 'restart', '--name', $AppName, '--resource-group', $ResourceGroup) | Out-Null
Write-Host "`nUpdated $AppName to version $moduleVersion." -ForegroundColor Green
