#Requires -Version 7.0
<#
.SYNOPSIS
    Uninstalls M365AutoRevocate and removes the privileged artifacts it created.

.DESCRIPTION
    Tears down, for the tenant that owns -SenderUpn's domain:
      * the Exchange Online mailbox-scoped mail grant (role assignment, scope,
        and the managed identity's Exchange service principal)   [unless -SkipExchange]
      * the admin web app's Entra app registration + service principal
      * the resource group (Function App + managed identity + storage +
        App Insights + Log Analytics)   [unless -KeepData]

    The managed identity's Graph and SharePoint app-role assignments are removed
    automatically when the Function App (and its identity) is deleted with the
    resource group. The Graph change-notification subscription is owned by that
    identity and expires on its own (within ~24h) once nothing renews it.

    Nothing here can run at "runtime" -- it uses your admin credentials.

.PARAMETER KeepData
    Keep the storage account (state tables + activity log) for audit. Deletes the
    Function App, App Insights and Log Analytics but leaves the resource group
    and storage in place.

.EXAMPLE
    ./deploy/Remove-M365AutoRevocate.ps1 -SubscriptionId <sub> -SenderUpn noreply@contoso.com
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$SenderUpn,
    [string]$ResourceGroup = 'rg-m365autorevocate',
    [string]$AppName,
    [string]$StorageAccount,
    [switch]$KeepData,
    [switch]$SkipExchange,
    [switch]$Force
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

Write-Step 'Preflight'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required.' }
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
$stableSuffix = Get-StableSuffix -Seed $tenantId
if (-not $AppName) { $AppName = "func-autorevocate-$stableSuffix" }
if (-not $StorageAccount) { $StorageAccount = "arevoc$stableSuffix"; if ($StorageAccount.Length -gt 24) { $StorageAccount = $StorageAccount.Substring(0, 24) } }

Write-Host "Tenant          : $tenantId"
Write-Host "Resource group  : $ResourceGroup"
Write-Host "Function app     : $AppName"
Write-Host "Keep storage    : $KeepData"

if (-not $Force -and -not $PSCmdlet.ShouldProcess($AppName, 'Uninstall M365AutoRevocate (deletes resources)')) { return }
if (-not $Force) {
    $answer = Read-Host "Type the app name '$AppName' to confirm deletion"
    if ($answer -ne $AppName) { Write-Host 'Confirmation did not match; aborting.'; return }
}

# Capture the identity appId (for Exchange cleanup) BEFORE anything is deleted.
$principalId = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'identity', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'principalId', '-o', 'tsv') -AllowFail)
$identityAppId = $null
if ($principalId) { $identityAppId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $principalId, '--query', 'appId', '-o', 'tsv') -AllowFail) }
$webAppId = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', "[?name=='AR_ADMIN_CLIENT_ID'].value | [0]", '-o', 'tsv') -AllowFail)

# --- Exchange Online cleanup -------------------------------------------------
if (-not $SkipExchange -and $identityAppId) {
    Write-Step 'Exchange Online cleanup'
    try {
        if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) { Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber }
        Import-Module ExchangeOnlineManagement -ErrorAction Stop
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        Get-ManagementRoleAssignment -Identity "M365AR-$AppName-MailSend" -ErrorAction SilentlyContinue | Remove-ManagementRoleAssignment -Confirm:$false -ErrorAction SilentlyContinue
        Get-ManagementRoleAssignment -Identity "M365AR-$AppName-ViewRecipients" -ErrorAction SilentlyContinue | Remove-ManagementRoleAssignment -Confirm:$false -ErrorAction SilentlyContinue
        Get-ManagementScope -Identity "M365AutoRevocate-Sender-$AppName" -ErrorAction SilentlyContinue | Remove-ManagementScope -Confirm:$false -ErrorAction SilentlyContinue
        Get-ServicePrincipal -Identity $identityAppId -ErrorAction SilentlyContinue | Remove-ServicePrincipal -Confirm:$false -ErrorAction SilentlyContinue
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host 'Exchange Online artifacts removed.'
    }
    catch { Write-Warning "Exchange Online cleanup did not complete: $($_.Exception.Message). Remove them by hand if needed." }
}
elseif ($SkipExchange) { Write-Host 'Skipping Exchange Online cleanup (-SkipExchange).' }

# --- Entra app registration for the admin web app ----------------------------
if ($webAppId) {
    Write-Step 'Admin web app registration'
    Invoke-Az -AzArgs @('ad', 'app', 'delete', '--id', $webAppId) -AllowFail | Out-Null
    Write-Host "Deleted app registration $webAppId (and its service principal)."
}

# --- Azure resources ---------------------------------------------------------
if ($KeepData) {
    Write-Step 'Deleting compute (keeping storage / audit data)'
    Invoke-Az -AzArgs @('functionapp', 'delete', '--name', $AppName, '--resource-group', $ResourceGroup) -AllowFail | Out-Null
    Invoke-Az -AzArgs @('monitor', 'app-insights', 'component', 'delete', '--app', $AppName, '--resource-group', $ResourceGroup) -AllowFail | Out-Null
    Invoke-Az -AzArgs @('monitor', 'log-analytics', 'workspace', 'delete', '--resource-group', $ResourceGroup, '--workspace-name', "log-$AppName", '--yes', '--force', 'true') -AllowFail | Out-Null
    Write-Host "Function app removed. Storage account '$StorageAccount' (state + activity log) was KEPT." -ForegroundColor Yellow
    Write-Host "Delete it later with: az group delete --name $ResourceGroup --yes"
}
else {
    Write-Step 'Deleting resource group'
    Invoke-Az -AzArgs @('group', 'delete', '--name', $ResourceGroup, '--yes') | Out-Null
    Write-Host "Resource group '$ResourceGroup' deleted."
}

Write-Step 'Done'
Write-Host 'M365AutoRevocate uninstalled.' -ForegroundColor Green
Write-Host 'Note: the Graph change-notification subscription (owned by the now-deleted identity) expires on its own within ~24h.'
