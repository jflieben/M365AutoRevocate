<#
.SYNOPSIS
    One-line bootstrap installer for M365AutoRevocate.

.DESCRIPTION
    Downloads the LATEST published release straight from GitHub and runs the full
    deployment into your Azure subscription. Designed to be run in Azure Cloud
    Shell (PowerShell), where the Azure CLI is present and you are already signed
    in, with a single line:

        iex (irm https://raw.githubusercontent.com/jflieben/M365AutoRevocate/main/install.ps1)

    Any required setting you do not pass is prompted for, so the one-liner is
    fully interactive. To run unattended (or pin a version), download it and pass
    parameters instead:

        irm https://raw.githubusercontent.com/jflieben/M365AutoRevocate/main/install.ps1 -OutFile install.ps1
        ./install.ps1 -SubscriptionId <sub> -Location westeurope `
            -SenderUpn noreply@contoso.com -ServicedeskEmail servicedesk@contoso.com `
            -AdminGroupName "M365AutoRevocate Admins"

.PARAMETER Version
    Release to install (e.g. '1.2.0' or 'v1.2.0'). Default: the latest release.

.PARAMETER Repo
    GitHub owner/repo to install from. Default: jflieben/M365AutoRevocate. Set
    this to install from your own fork or mirror.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$Location,
    [string]$ServicedeskEmail,
    [string]$SenderUpn,
    [string]$AdminGroupName,
    [hashtable]$Tags,
    [string]$ResourceGroup,
    [string[]]$AllowedAdminIp,
    [switch]$SkipNetworkLockdown,
    [string]$Version,
    [string]$Repo = 'jflieben/M365AutoRevocate'
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7+ is required. Use Azure Cloud Shell (PowerShell) or install PowerShell 7.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) was not found. Run this in Azure Cloud Shell (PowerShell), or install the Azure CLI and run "az login" first.'
}

function Read-Required {
    param([string]$Current, [string]$Prompt)
    $v = $Current
    while ([string]::IsNullOrWhiteSpace($v)) { $v = (Read-Host $Prompt).Trim() }
    return $v
}

Write-Host ''
Write-Host 'M365AutoRevocate installer' -ForegroundColor Cyan
Write-Host '--------------------------'

$headers = @{ 'User-Agent' = 'M365AutoRevocate-Installer'; 'Accept' = 'application/vnd.github+json' }

# --- 1) Resolve the release to install --------------------------------------
$tag = $null
if ($Version) {
    $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    Write-Host "Installing pinned release $tag from $Repo."
}
else {
    try {
        $rel = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases/latest" -TimeoutSec 30
        $tag = "$($rel.tag_name)".Trim()
        Write-Host "Latest release: $tag"
    }
    catch {
        Write-Warning "No published release found for $Repo; falling back to the 'main' branch."
    }
}

# --- 2) Download + extract the source archive for that ref ------------------
$archiveUrl = if ($tag) {
    "https://github.com/$Repo/archive/refs/tags/$tag.zip"
} else {
    "https://github.com/$Repo/archive/refs/heads/main.zip"
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ar-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$zip = Join-Path $work 'source.zip'
Write-Host "Downloading $archiveUrl ..."
Invoke-WebRequest -Headers $headers -Uri $archiveUrl -OutFile $zip -TimeoutSec 120
Expand-Archive -Path $zip -DestinationPath $work -Force

$root = Get-ChildItem -Path $work -Directory | Select-Object -First 1
if (-not $root) { throw "The downloaded archive did not contain the expected repository folder." }
$deployScript = Join-Path $root.FullName 'deploy/Deploy-M365AutoRevocate.ps1'
if (-not (Test-Path $deployScript)) { throw "Deploy script not found in the download ($deployScript)." }

$installedVersion = 'unknown'
$verFile = Join-Path $root.FullName 'VERSION'
if (Test-Path $verFile) { $installedVersion = (Get-Content $verFile -Raw).Trim() }
Write-Host "Prepared M365AutoRevocate $installedVersion." -ForegroundColor Green

# --- 3) Gather the required deployment settings ------------------------------
Write-Host ''
Write-Host 'A few settings are needed. Press Enter after each.' -ForegroundColor Cyan
$SubscriptionId   = Read-Required $SubscriptionId   'Azure subscription id'
$Location         = Read-Required $Location         'Azure region (e.g. westeurope)'
$SenderUpn        = Read-Required $SenderUpn         'Sender mailbox UPN (the hand-off email is sent from this mailbox)'
$ServicedeskEmail = Read-Required $ServicedeskEmail  'Service desk email (fallback when a user has no active manager)'
$AdminGroupName   = Read-Required $AdminGroupName    'Admin Entra security group (display name)'

# --- 4) Run the deployment ---------------------------------------------------
$deployParams = @{
    SubscriptionId   = $SubscriptionId
    Location         = $Location
    ServicedeskEmail = $ServicedeskEmail
    SenderUpn        = $SenderUpn
    AdminGroupName   = $AdminGroupName
}
if ($Tags) { $deployParams.Tags = $Tags }
if ($ResourceGroup) { $deployParams.ResourceGroup = $ResourceGroup }
if ($AllowedAdminIp) { $deployParams.AllowedAdminIp = $AllowedAdminIp }
if ($SkipNetworkLockdown) { $deployParams.SkipNetworkLockdown = $true }

Write-Host ''
Write-Host "Starting deployment ($installedVersion)..." -ForegroundColor Cyan
try {
    & $deployScript @deployParams
    Write-Host ''
    Write-Host "M365AutoRevocate $installedVersion install/update complete." -ForegroundColor Green
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Host ''
    Write-Warning "Deployment did not complete: $($_.Exception.Message)"
    Write-Host "The downloaded files are kept at: $($root.FullName)"
    throw
}
