#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot onboarding for M365AutoRevocate. Provisions everything and wires up
    the managed identity so the tool can run with NO secrets or certificates.

.DESCRIPTION
    Creates (idempotently):
      * Resource group
      * Storage account (state tables + Functions host storage)
      * Application Insights
      * Flex Consumption Function App (PowerShell 7.6) with a system-assigned
        managed identity
      * RBAC role assignments on the storage account for that identity
        (keyless host storage + our state tables/queue)
      * Application permissions for that identity: the Microsoft Graph app roles
        it needs, Sites.FullControl.All on SharePoint Online (OneDrive unshare),
        and Exchange.ManageAsApp on Office 365 Exchange Online (so the mailbox-
        type read for shared/room/equipment exclusion is accepted by Exchange)
      * Exchange Online RBAC-for-Applications: registers the identity's service
        principal in EXO, grants it a mailbox-scoped 'Application Mail.Send' role
        on the sender mailbox only (no tenant-wide Mail.Send), and 'View-Only
        Recipients' so it can read mailbox types
      * Application settings (behaviour + endpoints)
      * Admin web app: a static site in the storage account, an Entra app
        registration for delegated sign-in, App Service Easy Auth on the API
        restricted to the -AdminGroupName security group, and CORS.
    Then it zip-deploys the function code, registers the Graph subscription, and
    prints the admin web app URL.

    Finally it LOCKS DOWN inbound network access (unless -SkipNetworkLockdown):
    the Function App (admin API + Graph webhook) and the admin web site (its
    storage account) are restricted to your current public IP with everything
    else blocked, and the Function App additionally allows Microsoft Graph's
    change-notification ranges so deletions/disables keep arriving. We do not
    recommend leaving either surface publicly reachable. See README > Network
    access for how to add IPs later.

    Everything the tool does at runtime authenticates with the managed identity.
    The only thing this script needs a privileged human for is granting +
    consenting the Graph app roles, which requires Global Administrator or
    Privileged Role Administrator.

.PARAMETER Tags
    Optional tags to apply to the resource group, for tenants whose governance
    requires them. Pass a hashtable, e.g. -Tags @{ CostCentre = '1234'; Env = 'prod' }.
    Applied on the group (re-runs re-apply them); omit to leave any existing
    resource-group tags untouched.

.PARAMETER ServicedeskEmail
    Fallback recipient for the artifact hand-off email when a deleted user has
    no active manager.

.PARAMETER SenderUpn
    Mailbox the hand-off email is sent from (e.g. a shared/no-reply mailbox).
    The script verifies this mailbox exists and grants the managed identity a
    *mailbox-scoped* send permission on it via Exchange Online RBAC for
    Applications -- no tenant-wide Mail.Send is used (see docs/permissions.md).
    Its DOMAIN also determines the target Entra tenant: the script resolves the
    tenant id from the domain and forces az to sign in there, so you cannot
    accidentally deploy into the wrong tenant.

.PARAMETER AdminGroupName
    Display name of the Entra security group whose members may use the admin web
    app. The script resolves it to an object id. Required.

    You must be signed in as an Exchange Administrator: the script connects to
    Exchange Online interactively to set up mailbox-scoped mail.

.PARAMETER AllowedAdminIp
    Extra public IP address(es)/CIDR(s) allowed to reach the admin console + API,
    in addition to your auto-detected public IP (e.g. an office range). Everything
    else is blocked. Microsoft Graph's change-notification ranges are always
    allowed on the Function App so the tool keeps receiving events.

.PARAMETER SkipNetworkLockdown
    Leave both public surfaces (Function App + admin web site) openly reachable.
    NOT recommended; provided only for environments that front the app with their
    own network controls.

.EXAMPLE
    ./Deploy-M365AutoRevocate.ps1 -SubscriptionId <sub> -Location westeurope `
        -ServicedeskEmail servicedesk@contoso.com -SenderUpn noreply@contoso.com `
        -AdminGroupName "M365AutoRevocate Admins"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$ServicedeskEmail,
    [Parameter(Mandatory)][string]$SenderUpn,
    # Entra security group (DISPLAY NAME) whose members may use the admin web app.
    [Parameter(Mandatory)][string]$AdminGroupName,

    [string]$ResourceGroup = 'rg-m365autorevocate',
    # AppName / StorageAccount default to deterministic, per-tenant names (set
    # after login) so re-running the script is fully idempotent.
    [string]$AppName,
    [string]$StorageAccount,

    # Optional resource-group tags (e.g. -Tags @{ CostCentre = '1234' }) for
    # tenants whose policy requires them. Delete timing (soft/hard) is no longer
    # a deploy switch: it is chosen in the setup wizard and edited in the console.
    [hashtable]$Tags,

    # Network lockdown. By default the deploy restricts BOTH public surfaces (the
    # Function App and the admin web site) to your current public IP, denying all
    # other inbound traffic -- we do NOT recommend leaving them publicly reachable.
    # Give one or more extra public IPs/CIDRs to allow (e.g. an office range) in
    # addition to your detected IP, or use -SkipNetworkLockdown to leave both open.
    [string[]]$AllowedAdminIp,
    [switch]$SkipNetworkLockdown
)

# The tool targets Flex Consumption (keyless, identity-based host storage). The
# classic Consumption plan does not support identity-based host storage, so it
# is not offered.

$ErrorActionPreference = 'Stop'
# The API permissions (app roles on Graph / SharePoint / Exchange) and any Entra
# directory roles the managed identity needs are the single source of truth in
# deploy/permissions.json, reconciled by Update-ARPermission (deploy/AR.Common.ps1)
# below. Mail SENDING is NOT an app role: it is granted via Exchange Online RBAC
# (mailbox-scoped) further down. Add a new API requirement in permissions.json and
# both this deploy and Update-M365AutoRevocate.ps1 will grant it.

# Microsoft Graph change-notification egress ranges. Graph POSTs the subscription
# validation handshake and every change notification to NotificationHandler from
# these ranges, so they must stay allowed inbound once the Function App is locked
# down. Source: https://learn.microsoft.com/en-us/microsoft-365/enterprise/additional-office365-ip-addresses-and-urls
# (row #23). Verify these against that page periodically; update the allow rules
# in the portal if Microsoft changes them (see README > Network access).
$graphNotificationCidrs = @('20.20.32.0/19', '20.190.128.0/18', '20.231.128.0/19', '40.126.0.0/18')

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$AllowFail)
    # --only-show-errors keeps stdout clean (no warnings) so scalar queries parse
    # reliably; errors still surface on failure.
    if ($AzArgs -notcontains '--only-show-errors') { $AzArgs += '--only-show-errors' }
    $out = & az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (-not $AllowFail) { throw "az $($AzArgs -join ' ') failed:`n$out" }
        # Tolerated failure: return nothing so Get-AzScalar / truthiness checks
        # don't mistake the error text for a value.
        return $null
    }
    return $out
}
function Get-AzScalar {
    # Last non-empty, trimmed line of an az command's output.
    param($Value)
    return ((@($Value) | Where-Object { "$_".Trim() } | Select-Object -Last 1) | ForEach-Object { "$_".Trim() })
}
function Invoke-AzRestJson {
    # 'az rest' with a JSON body. The body is written to a temp file and passed as
    # @file: passing multi-line JSON inline mangles it (especially on Windows) and
    # Graph rejects it with "Unable to read JSON request payload".
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$Body,
        [switch]$AllowFail
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("azrest-$([Guid]::NewGuid().ToString('N')).json")
    [System.IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    try {
        return Invoke-Az -AzArgs @('rest', '--method', $Method, '--uri', $Uri,
            '--headers', 'Content-Type=application/json', '--body', "@$tmp") -AllowFail:$AllowFail
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
function Get-StableSuffix {
    # Deterministic 8-char suffix from a seed (used for idempotent resource names).
    param([Parameter(Mandatory)][string]$Seed)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Seed.ToLower()))
    return (([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 8)).ToLower()
}
function Get-TenantIdFromDomain {
    # Resolve an Entra tenant id from a verified domain via the public OpenID
    # Connect discovery endpoint (no auth needed).
    param([Parameter(Mandatory)][string]$Domain)
    $uri = "https://login.microsoftonline.com/$Domain/v2.0/.well-known/openid-configuration"
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $uri -ErrorAction Stop
        if ($resp.issuer -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            return $Matches[1]
        }
    }
    catch { return $null }
    return $null
}
function Get-MyPublicIp {
    # Best-effort discovery of the machine's public IPv4, used to seed the network
    # allow-list so the admin is not locked out. Tries a few well-known services.
    foreach ($svc in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $ip = "$(Invoke-RestMethod -Method Get -Uri $svc -TimeoutSec 10 -ErrorAction Stop)".Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        }
        catch { }
    }
    return $null
}
function Test-AzureCloudShell {
    # True when running inside Azure Cloud Shell. There, the machine's public IP is
    # the Cloud Shell container's Azure egress address, NOT the admin's, so it must
    # never be auto-whitelisted.
    return [bool](
        ($env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*') -or
        ($env:POWERSHELL_DISTRIBUTION_CHANNEL -eq 'CloudShell') -or
        $env:ACC_CLOUD
    )
}
function Show-ARSignInIpHint {
    # Best-effort: show the admin their recent sign-in source IPs (from the Entra
    # sign-in logs of the signed-in account) so they can recognise the public IP to
    # whitelist. Needs the account to be able to read its own sign-in logs (a Global
    # Administrator can). Never throws -- it is only a convenience hint.
    Write-Host 'Looking up your recent sign-in IP addresses to help you choose...'
    try {
        if (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue) {
            $me = (Invoke-AzRestMethod -Method GET -Uri 'https://graph.microsoft.com/v1.0/me').Content | ConvertFrom-Json
            $upn = "$($me.userPrincipalName)"
            if ($upn) {
                $filter = [Uri]::EscapeDataString("userPrincipalName eq '$upn'")
                $resp = (Invoke-AzRestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$top=5&`$filter=$filter").Content | ConvertFrom-Json
                $rows = @($resp.value | Select-Object createdDateTime, ipAddress, appDisplayName)
                if ($rows.Count) {
                    Write-Host 'Your most recent sign-ins (the ipAddress is very likely the IP to whitelist):' -ForegroundColor Cyan
                    ($rows | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host
                    return
                }
            }
        }
    }
    catch { }
    Write-Host '(Could not read your sign-in history automatically. Find your public IP from the workstation that will manage the tool, e.g. https://ifconfig.me.)'
}

# Single source of truth for the version: the VERSION file at the repo root,
# falling back to the module manifest. Stamped into the app (AR_VERSION) and
# shown in the web UI footer.
$moduleVersion = '1.0.0'
try {
    $versionFile = Join-Path $PSScriptRoot '..\VERSION'
    if (Test-Path $versionFile) { $moduleVersion = (Get-Content $versionFile -Raw).Trim() }
    else { $moduleVersion = (Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\src\Modules\AutoRevocate\AutoRevocate.psd1')).ModuleVersion }
}
catch { }

# --- Preflight ---------------------------------------------------------------
Write-Step 'Preflight'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install from https://aka.ms/azcli and run "az login".'
}
# Force the correct tenant. The sender's domain identifies the Entra tenant the
# tool belongs to; resolve it to a tenant id and make sure az is signed in there
# (guards against deploying into whatever tenant az happens to be pointing at).
$senderDomain = ($SenderUpn -split '@')[-1]
$expectedTenantId = Get-TenantIdFromDomain -Domain $senderDomain
if ($expectedTenantId) {
    Write-Host "Sender domain '$senderDomain' -> tenant $expectedTenantId."
}
else {
    Write-Warning "Could not resolve a tenant for '$senderDomain'; falling back to the current az login context. Verify you are in the right tenant."
}

$account = az account show 2>$null | ConvertFrom-Json
if ($expectedTenantId -and (-not $account -or $account.tenantId -ne $expectedTenantId)) {
    Write-Host "Current az context is not tenant $expectedTenantId; signing in to it now..." -ForegroundColor Yellow
    az login --tenant $expectedTenantId --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Sign-in to tenant $expectedTenantId failed. Ensure you have access to '$senderDomain'." }
    $account = az account show 2>$null | ConvertFrom-Json
}
if (-not $account) { throw 'Not logged in. Run "az login" first.' }

Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$account = az account show | ConvertFrom-Json           # refresh after selecting the subscription
$tenantId = $account.tenantId

if ($expectedTenantId -and $tenantId -ne $expectedTenantId) {
    throw "Subscription $SubscriptionId is in tenant $tenantId, but sender domain '$senderDomain' belongs to tenant $expectedTenantId. Use a subscription in the correct tenant."
}
Write-Host "Subscription: $SubscriptionId  Tenant: $tenantId"

# Resolve the admin security group (display name -> object id), creating it if
# it does not exist (with a confirmation prompt).
$AdminGroupObjectId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'group', 'show', '--group', $AdminGroupName, '--query', 'id', '-o', 'tsv') -AllowFail)
if (-not $AdminGroupObjectId) {
    Write-Warning "No Entra security group named '$AdminGroupName' was found."
    $answer = Read-Host "Create it now? Its members get admin access to the tool -- treat it as privileged access. [y/N]"
    if ($answer -notmatch '^\s*(y|yes)\s*$') {
        throw "No Entra security group named '$AdminGroupName' was found. Create it first, then re-run."
    }
    Write-Host "Creating security group '$AdminGroupName'..."
    $nickname = ($AdminGroupName -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($nickname)) { $nickname = 'm365autorevocateadmins' }
    # Membership of this group == control of a Tier-0-grade identity, so try to
    # create it ROLE-ASSIGNABLE (only Privileged Role Admins can then change its
    # membership). Fall back to a normal security group if that is not permitted.
    $AdminGroupObjectId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'group', 'create', '--display-name', $AdminGroupName, '--mail-nickname', $nickname, '--is-assignable-to-role', 'true', '--query', 'id', '-o', 'tsv') -AllowFail)
    if ($AdminGroupObjectId) { Write-Host "Created ROLE-ASSIGNABLE security group '$AdminGroupName' ($AdminGroupObjectId)." -ForegroundColor Green }
    else {
        Write-Warning 'Could not create a role-assignable group (needs Privileged Role Admin); creating a normal security group instead.'
        $AdminGroupObjectId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'group', 'create', '--display-name', $AdminGroupName, '--mail-nickname', $nickname, '--query', 'id', '-o', 'tsv'))
        if (-not $AdminGroupObjectId) { throw "Failed to create the security group '$AdminGroupName'." }
        Write-Host "Created security group '$AdminGroupName' ($AdminGroupObjectId)." -ForegroundColor Green
    }
    Write-Warning "The new group is EMPTY. Add the users who should access the admin web app. TREAT THIS GROUP AS PRIVILEGED ACCESS (PIM recommended)."
}
else {
    Write-Host "Admin group    : $AdminGroupName ($AdminGroupObjectId)"
}

# Deterministic per-tenant names so re-runs reuse the same resources.
$stableSuffix = Get-StableSuffix -Seed $tenantId
if (-not $AppName) { $AppName = "func-autorevocate-$stableSuffix" }
if (-not $StorageAccount) { $StorageAccount = "arevoc$stableSuffix" }   # 3-24 lowercase alnum
if ($StorageAccount.Length -gt 24) { $StorageAccount = $StorageAccount.Substring(0, 24) }

Write-Host "Resource group : $ResourceGroup"
Write-Host "Function app   : $AppName"
Write-Host "Storage account: $StorageAccount"
Write-Host "Plan           : Flex Consumption"
if ($Tags -and $Tags.Count) { Write-Host "RG tags        : $(($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')" }

if ($PSCmdlet.ShouldProcess($AppName, 'Deploy M365AutoRevocate (Flex Consumption)') -eq $false) { return }

# --- Exchange Online sign-in (up front) --------------------------------------
# Connect and verify the sender mailbox NOW -- while all the other interactive
# sign-ins are happening -- so the pop-up doesn't surprise the admin later (or
# get missed). The actual scoping happens after the managed identity exists.
# Assumes the signed-in user is an Exchange Administrator.
Write-Step 'Exchange Online sign-in'
$exoReady = $false
$exoScoped = $false
$mbxSmtp = $null
try {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        Write-Host 'Installing ExchangeOnlineManagement (CurrentUser)...'
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Write-Host 'Connecting to Exchange Online (a sign-in window will open)...'
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    $mbxSmtp = (Get-Mailbox -Identity $SenderUpn -ErrorAction Stop).PrimarySmtpAddress
    Write-Host "Sender mailbox verified: $mbxSmtp"
    $exoReady = $true
}
catch {
    Write-Warning "Exchange Online connect/verify failed: $($_.Exception.Message)"
    Write-Warning 'Mailbox-scoped mail will be skipped; set it up manually later (docs/permissions.md).'
}

# --- Resource group ----------------------------------------------------------
Write-Step 'Resource group'
$rgArgs = @('group', 'create', '--name', $ResourceGroup, '--location', $Location)
# Only pass --tags when the caller supplied some, so a re-run without -Tags never
# clears tags an enterprise (or an inheritance policy) put on the group.
if ($Tags -and $Tags.Count) { $rgArgs += @('--tags') + @($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) }
Invoke-Az -AzArgs $rgArgs | Out-Null

# --- Storage account ---------------------------------------------------------
Write-Step 'Storage account'
Invoke-Az -AzArgs @(
    'storage', 'account', 'create',
    '--name', $StorageAccount, '--resource-group', $ResourceGroup, '--location', $Location,
    '--sku', 'Standard_LRS', '--kind', 'StorageV2', '--min-tls-version', 'TLS1_2',
    '--allow-blob-public-access', 'false'
) | Out-Null
# Blob versioning gives the config blob a full, recoverable history (a bad save
# can be rolled back). Best-effort; the tool also keeps config.previous.json.
Invoke-Az -AzArgs @('storage', 'account', 'blob-service-properties', 'update', '--account-name', $StorageAccount, '--resource-group', $ResourceGroup, '--enable-versioning', 'true') -AllowFail | Out-Null
$storageId = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $StorageAccount, '--resource-group', $ResourceGroup, '--query', 'id', '-o', 'tsv'))
$tableEndpoint = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $StorageAccount, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.table', '-o', 'tsv'))).TrimEnd('/')
$blobEndpoint = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $StorageAccount, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.blob', '-o', 'tsv'))).TrimEnd('/')
$queueEndpoint = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $StorageAccount, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.queue', '-o', 'tsv'))).TrimEnd('/')

# --- Separate storage account for the admin web app --------------------------
# The static admin SPA lives in its OWN storage account, which the managed
# identity has NO role on. The Functions host requires account-level blob access
# on the state account for identity-based host storage, so keeping $web there
# would let a runtime compromise rewrite the SPA to harvest admin tokens.
# Isolating $web removes that path entirely (the deploy uploads it with the web
# account's own key, admin-time only).
$WebStorageAccount = "arweb$stableSuffix"
if ($WebStorageAccount.Length -gt 24) { $WebStorageAccount = $WebStorageAccount.Substring(0, 24) }
Write-Host "Web storage    : $WebStorageAccount"
Invoke-Az -AzArgs @(
    'storage', 'account', 'create',
    '--name', $WebStorageAccount, '--resource-group', $ResourceGroup, '--location', $Location,
    '--sku', 'Standard_LRS', '--kind', 'StorageV2', '--min-tls-version', 'TLS1_2',
    '--allow-blob-public-access', 'true'   # $web static hosting serves anonymously
) | Out-Null

# --- Log Analytics + Application Insights ------------------------------------
# Create our OWN Log Analytics workspace in THIS resource group and bind App
# Insights to it. Without a workspace, Azure auto-creates a separate
# 'ai_<app>_..._managed' resource group with its own workspace
Write-Step 'Log Analytics + Application Insights'
Invoke-Az -AzArgs @('extension', 'add', '--name', 'application-insights') -AllowFail | Out-Null
$workspaceId = Get-AzScalar (Invoke-Az -AzArgs @(
        'monitor', 'log-analytics', 'workspace', 'create',
        '--resource-group', $ResourceGroup, '--workspace-name', "log-$AppName", '--location', $Location,
        '--query', 'id', '-o', 'tsv'
    ) -AllowFail)
$aiArgs = @('monitor', 'app-insights', 'component', 'create', '--app', $AppName, '--location', $Location,
    '--resource-group', $ResourceGroup, '--query', 'connectionString', '-o', 'tsv')
if ($workspaceId) { $aiArgs += @('--workspace', $workspaceId) }
else { Write-Warning 'Could not create a Log Analytics workspace; App Insights may create its own managed resource group.' }
$aiConn = Get-AzScalar (Invoke-Az -AzArgs $aiArgs -AllowFail)
if (-not $aiConn) { Write-Warning 'Could not create Application Insights; continuing without it.' }

# --- Function app ------------------------------------------------------------
Write-Step 'Function app (Flex Consumption)'
# Idempotent: only create if it doesn't already exist
$appExists = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'name', '-o', 'tsv') -AllowFail)
if ($appExists) {
    Write-Host "Function app '$AppName' already exists; reusing it."
}
else {
    # Flex Consumption: keyless host storage via managed identity
    Invoke-Az -AzArgs @(
        'functionapp', 'create',
        '--name', $AppName, '--resource-group', $ResourceGroup,
        '--storage-account', $StorageAccount,
        '--flexconsumption-location', $Location,
        '--runtime', 'powershell', '--runtime-version', '7.6'
    ) | Out-Null
}

# Ensure the PowerShell runtime is current even on an app that already exists.
# Flex Consumption pins the runtime version at create time, so re-running deploy
# would otherwise leave an app created on an older (soon-retired) version behind.
# This ARM PATCH is idempotent and a no-op when the version already matches.
$runtimeUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName?api-version=2023-12-01"
Invoke-AzRestJson -Method PATCH -Uri $runtimeUri -Body @{
    properties = @{ functionAppConfig = @{ runtime = @{ name = 'powershell'; version = '7.6' } } }
} -AllowFail | Out-Null

# Enable the system-assigned identity
Invoke-Az -AzArgs @('functionapp', 'identity', 'assign', '--name', $AppName, '--resource-group', $ResourceGroup) | Out-Null
$principalId = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'identity', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'principalId', '-o', 'tsv'))
if (-not $principalId) { throw 'Failed to obtain the managed identity principalId.' }

# The identity's AppId (client id) is needed to register it in Exchange Online.
# The managed-identity service principal can take a minute to become queryable in
# Entra after it is created, so retry until it resolves.
$identityAppId = $null
for ($i = 0; $i -lt 12 -and -not $identityAppId; $i++) {
    $identityAppId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $principalId, '--query', 'appId', '-o', 'tsv') -AllowFail)
    if (-not $identityAppId) { Write-Host 'Waiting for the managed identity to appear in Entra...'; Start-Sleep -Seconds 10 }
}
if (-not $identityAppId) { throw 'The managed identity service principal did not propagate in time. Re-run the script (it is idempotent).' }
Write-Host "Managed identity principalId: $principalId  appId: $identityAppId"

# --- Storage RBAC for the identity (keyless data-plane access) ----------------
Write-Step 'Storage role assignments'
Write-Host 'Waiting 15s for the managed identity service principal to propagate...'
Start-Sleep -Seconds 15
$rbacFailed = $false
foreach ($role in @('Storage Blob Data Owner', 'Storage Queue Data Contributor', 'Storage Table Data Contributor')) {
    Write-Host "Granting '$role' on the storage account..."
    Invoke-Az -AzArgs @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $principalId, '--assignee-principal-type', 'ServicePrincipal',
        '--role', $role, '--scope', $storageId
    ) -AllowFail | Out-Null
    if ($LASTEXITCODE -ne 0) { $rbacFailed = $true; Write-Warning "Could not assign '$role'." }
}
if ($rbacFailed) {
    Write-Warning 'One or more storage role assignments FAILED. The tool cannot read/write its state without them and its APIs will return 500.'
    Write-Warning "You need 'Owner' or 'User Access Administrator' on the storage account. Grant the roles to principalId $principalId on the storage account, then re-run."
}

# --- API permissions (app roles) + directory roles ---------------------------
# Everything the managed identity needs on Microsoft Graph, SharePoint Online and
# Exchange Online (plus any Entra directory roles) is reconciled from
# deploy/permissions.json by the shared helper, which grants whatever is missing.
# This is the SAME code the update script runs, so a new requirement added to the
# JSON is applied on the next deploy or update.
Write-Step 'API permissions'
. (Join-Path $PSScriptRoot 'AR.Common.ps1')
$graphRolesFailed = @(Update-ARPermission -PrincipalId $principalId)
if ($graphRolesFailed.Count -eq 0) { Write-Host 'API permissions reconciled: all required roles are granted.' -ForegroundColor Green }

# --- Exchange Online: mailbox-scoped mail (RBAC for Applications) --------------
# Instead of a tenant-wide Graph Mail.Send app role, grant the identity a
# send permission scoped to ONLY the sender mailbox. The tool still calls Graph
# /sendMail at runtime; Exchange authorizes it via this scoped assignment.
Write-Step 'Exchange Online (mailbox-scoped mail)'
if (-not $exoReady) {
    Write-Warning 'Exchange Online was not connected/verified earlier; skipping mailbox scoping (docs/permissions.md).'
}
else {
  try {
    # Already connected and the sender mailbox verified up front ($mbxSmtp).

    # 2) Register the managed identity's service principal in Exchange.
    $exoSp = Get-ServicePrincipal -Identity $identityAppId -ErrorAction SilentlyContinue
    if (-not $exoSp) {
        Write-Host 'Registering the managed identity in Exchange Online...'
        $null = New-ServicePrincipal -AppId $identityAppId -ObjectId $principalId -DisplayName "M365AutoRevocate-$AppName" -ErrorAction Stop
    }
    else { Write-Host 'Exchange service principal already present.' }

    # 3) Management scope limited to exactly the sender mailbox. Exchange rejects
    #    a new scope whose filter matches an existing one, so we add a tautology
    #    that keeps the scope unique to this deployment (but still resolves to the
    #    same single mailbox). If a unique scope truly can't be made, fall back to
    #    an existing scope that already covers the mailbox.
    $scopeName = "M365AutoRevocate-Sender-$AppName"
    $scope = Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue
    if (-not $scope) {
        $smtp = $mbxSmtp
        $uniqueFilter = "PrimarySmtpAddress -eq '$smtp' -and Name -ne 'M365AR-$AppName-none'"
        try {
            Write-Host "Creating management scope '$scopeName'..."
            $scope = New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $uniqueFilter -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not create a unique scope ($($_.Exception.Message)). Falling back to an existing scope covering $smtp."
            $scope = Get-ManagementScope -ErrorAction SilentlyContinue | Where-Object { $_.RecipientFilter -and $_.RecipientFilter -match [regex]::Escape($smtp) } | Select-Object -First 1
            if (-not $scope) { throw "No management scope covers $smtp and a new one could not be created." }
            Write-Host "Reusing existing management scope '$($scope.Name)'."
        }
    }
    else { Write-Host "Management scope '$scopeName' already present." }
    $scopeName = $scope.Name

    # 4) Assign the scoped 'Application Mail.Send' role to the identity.
    $assignName = "M365AR-$AppName-MailSend"
    if (-not (Get-ManagementRoleAssignment -Identity $assignName -ErrorAction SilentlyContinue)) {
        Write-Host 'Assigning scoped "Application Mail.Send" role...'
        $null = New-ManagementRoleAssignment -Name $assignName -App $identityAppId -Role 'Application Mail.Send' -CustomResourceScope $scopeName -ErrorAction Stop
    }
    else { Write-Host 'Role assignment already present.' }

    # 5) Read-only recipient access (tenant-wide) so the tool can read mailbox
    #    types (RecipientTypeDetails) and exclude shared/room/equipment mailboxes
    #    from inactivity offboarding. 'View-Only Recipients' is read-only.
    $roAssignName = "M365AR-$AppName-ViewRecipients"
    if (-not (Get-ManagementRoleAssignment -Identity $roAssignName -ErrorAction SilentlyContinue)) {
        Write-Host 'Assigning "View-Only Recipients" role (mailbox-type reads)...'
        try { $null = New-ManagementRoleAssignment -Name $roAssignName -App $identityAppId -Role 'View-Only Recipients' -ErrorAction Stop }
        catch { Write-Warning "Could not assign 'View-Only Recipients' ($($_.Exception.Message)). Shared/room/equipment mailbox exclusion will be unavailable until this is granted (or turn the option off)." }
    }
    else { Write-Host 'View-Only Recipients role assignment already present.' }

    Write-Host 'Exchange Online scoping complete (allow up to ~30 min to take effect).' -ForegroundColor Green
    $exoScoped = $true
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
  catch {
    Write-Warning "Exchange Online setup did not complete: $($_.Exception.Message)"
    Write-Warning "Finish it manually (docs/permissions.md): New-ServicePrincipal -AppId $identityAppId -ObjectId $principalId; a mailbox-scoped New-ManagementScope for $SenderUpn; then New-ManagementRoleAssignment -App $identityAppId -Role 'Application Mail.Send' -CustomResourceScope <scope>."
  }
}

# --- Application settings -----------------------------------------------------
Write-Step 'Application settings'
# Reuse the existing clientState on re-runs. Generating a new one would orphan
# the live Graph subscription (it still carries the old value), making the
# NotificationHandler drop every notification as a clientState mismatch.
$clientState = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', "[?name=='AR_CLIENT_STATE'].value | [0]", '-o', 'tsv') -AllowFail)
if (-not $clientState) { $clientState = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N') }
$settings = [System.Collections.Generic.List[string]]::new()
# Delete timing (soft/hard) is no longer stamped here: it defaults to 'soft' and
# the operator sets it in the setup wizard / Configuration tab (stored in the
# behaviour-config blob). Get-ARDefaultConfig still honours a pre-existing
# AR_MODE if one was set by an older deploy.
$settings.Add("AR_SERVICEDESK_EMAIL=$ServicedeskEmail")
$settings.Add("AR_SENDER_UPN=$SenderUpn")
$settings.Add("AR_CLIENT_STATE=$clientState")
$settings.Add("AR_TABLE_ENDPOINT=$tableEndpoint")
# Tenant id + version for in-function admin-token validation and the UI footer.
# AR_ADMIN_CLIENT_ID is set later, once the admin app registration exists.
$settings.Add("AR_TENANT_ID=$tenantId")
$settings.Add("AR_VERSION=$moduleVersion")
$settings.Add("AR_BLOB_ENDPOINT=$blobEndpoint")
$settings.Add("AR_QUEUE_ENDPOINT=$queueEndpoint")
$settings.Add('AR_CONFIG_CONTAINER=autorevocate-config')
# Identity-based host storage (keyless). Removes the need for a connection string.
$settings.Add("AzureWebJobsStorage__accountName=$StorageAccount")
if ($aiConn) { $settings.Add("APPLICATIONINSIGHTS_CONNECTION_STRING=$aiConn") }

Invoke-Az -AzArgs (@('functionapp', 'config', 'appsettings', 'set', '--name', $AppName, '--resource-group', $ResourceGroup, '--settings') + $settings) | Out-Null

# For identity-based host storage, drop the connection-string form if present.
Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'delete', '--name', $AppName, '--resource-group', $ResourceGroup, '--setting-names', 'AzureWebJobsStorage') -AllowFail | Out-Null

# --- Deploy the function code ------------------------------------------------
Write-Step 'Deploy function code'
$srcPath = Join-Path $PSScriptRoot '..\src' | Resolve-Path
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "autorevocate-$([Guid]::NewGuid().ToString('N')).zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Write-Host "Packaging $srcPath ..."
# Stage a clean copy so a developer's real local.settings.json (which can hold
# secrets/connection strings) is NEVER shipped in the deployment package.
$pkgStage = Join-Path ([System.IO.Path]::GetTempPath()) "arpkg-$([Guid]::NewGuid().ToString('N'))"
Copy-Item -Path $srcPath -Destination $pkgStage -Recurse -Force
Get-ChildItem -Path $pkgStage -Filter 'local.settings.json*' -Recurse -Force | Remove-Item -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $pkgStage '*') -DestinationPath $zipPath -Force
Remove-Item $pkgStage -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'Waiting 30s for the app to be ready before deploying code...'
Start-Sleep -Seconds 30
# Try the modern one-deploy first, then classic config-zip. Whichever the app
# accepts wins. Errors are captured (not suppressed) so a total failure is
# actionable rather than a bare "failed after retries".
$deployMethods = @(
    @{ Name = 'one-deploy'; Cmd = @('functionapp', 'deploy', '--name', $AppName, '--resource-group', $ResourceGroup, '--src-path', $zipPath, '--type', 'zip') },
    @{ Name = 'config-zip'; Cmd = @('functionapp', 'deployment', 'source', 'config-zip', '--name', $AppName, '--resource-group', $ResourceGroup, '--src', $zipPath) }
)
$deployed = $false; $deployErr = ''
foreach ($m in $deployMethods) {
    for ($i = 1; $i -le 2 -and -not $deployed; $i++) {
        $cmd = $m.Cmd
        $out = & az @cmd --only-show-errors 2>&1
        if ($LASTEXITCODE -eq 0) { $deployed = $true; Write-Host "Function code deployed via $($m.Name)." }
        else {
            $deployErr = ($out | Out-String).Trim()
            Write-Host "Deploy via $($m.Name) attempt $i failed; retrying in 15s..."
            Start-Sleep -Seconds 15
        }
    }
    if ($deployed) { break }
}
if (-not $deployed) { throw "Function code deployment failed via all methods.`nLast error:`n$deployErr" }
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# --- Compute the notification URL (function key) and register the subscription
Write-Step 'Notification URL + subscription'
Write-Host 'Waiting 15s for the function to become queryable...'
Start-Sleep -Seconds 15
# Try the per-function key first (tightest scope). On Flex Consumption this often
# is NOT available for a while after a code deploy: the per-function key only
# exists once the host has indexed the function as an ARM sub-resource, which
# lags. So sync the triggers to nudge that, and fall back to the default HOST key
# (readable as soon as the app exists) which authorises the same call --
# NotificationHandler is the only function-key-protected HTTP function, so the
# blast radius is identical.
$funcKey = $null
for ($i = 0; $i -lt 6 -and -not $funcKey; $i++) {
    $funcKey = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'function', 'keys', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--function-name', 'NotificationHandler', '--query', 'default', '-o', 'tsv') -AllowFail)
    if (-not $funcKey) { Start-Sleep -Seconds 10 }
}
if (-not $funcKey) {
    Write-Host 'Per-function key not published yet (Flex host still indexing); syncing triggers and falling back to the default host key...'
    Invoke-Az -AzArgs @('rest', '--method', 'post',
        '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/syncfunctiontriggers?api-version=2023-12-01") -AllowFail | Out-Null
    for ($i = 0; $i -lt 6 -and -not $funcKey; $i++) {
        $funcKey = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'keys', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'functionKeys.default', '-o', 'tsv') -AllowFail)
        if (-not $funcKey) { Start-Sleep -Seconds 10 }
    }
}
if (-not $funcKey) { throw 'Could not read a usable function key for NotificationHandler after retries. The functions may still be starting; re-running the deploy (it is idempotent) will finish subscription setup.' }

$hostName = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'defaultHostName', '-o', 'tsv') -AllowFail)
# Fall back to the deterministic public-cloud host name if the query comes back
# empty (it can lag right after provisioning) so we never build a broken URL.
if (-not $hostName) { $hostName = "$AppName.azurewebsites.net" }
$notificationUrl = "https://$hostName/api/NotificationHandler?code=$funcKey"
Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'set', '--name', $AppName, '--resource-group', $ResourceGroup, '--settings', "AR_NOTIFICATION_URL=$notificationUrl") | Out-Null

# Restarting makes SubscriptionManager (runOnStartup) create the Graph
# subscription against the now-configured notification URL.
Invoke-Az -AzArgs @('functionapp', 'restart', '--name', $AppName, '--resource-group', $ResourceGroup) | Out-Null

# Sync the trigger metadata with the platform's scale controller. On Flex
# Consumption an instance only listens for the trigger group it was started
# for; without this sync the platform never starts instances for the timer and
# queue triggers, so those functions silently never run (HTTP keeps working,
# which makes it easy to miss). Loud on failure for exactly that reason.
Write-Host 'Syncing function triggers with the platform...'
Invoke-Az -AzArgs @('rest', '--method', 'post',
    '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/syncfunctiontriggers?api-version=2023-12-01") | Out-Null
Write-Host 'Triggers synced: timer and queue functions are schedulable.' -ForegroundColor Green

# --- Admin web app (static site + Entra sign-in + Easy Auth) ------------------
# The web app is a static site in the SEPARATE web storage account (the managed
# identity has no access to it). It signs users in with delegated Entra auth
# (MSAL) and calls the Function App admin API, which is protected by App Service
# Easy Auth and restricted to $AdminGroupObjectId.
$webUrl = $null
$authVerified = $false
Write-Step 'Admin web app'
try {
        # The state-account key: used ONLY to pre-create the work queue (admin-time).
        $stKey = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'keys', 'list', '--account-name', $StorageAccount, '--resource-group', $ResourceGroup, '--query', '[0].value', '-o', 'tsv'))
        # The web-account key: static website hosting + SPA upload (admin-time).
        $webKey = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'keys', 'list', '--account-name', $WebStorageAccount, '--resource-group', $ResourceGroup, '--query', '[0].value', '-o', 'tsv'))

        # Pre-create the work queue so the RevocationProcessor trigger has it
        # from the start (the runtime also creates it on demand).
        Invoke-Az -AzArgs @('storage', 'queue', 'create', '--name', 'revocations', '--account-name', $StorageAccount, '--account-key', $stKey) -AllowFail | Out-Null

        Invoke-Az -AzArgs @('storage', 'blob', 'service-properties', 'update', '--account-name', $WebStorageAccount, '--account-key', $webKey,
            '--static-website', '--index-document', 'index.html', '--404-document', 'index.html') | Out-Null
        $webUrl = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $WebStorageAccount, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.web', '-o', 'tsv'))).TrimEnd('/')

        # 1) Entra app registration for the SPA + API scope (reuse by display name
        #    so re-runs don't pile up duplicate app registrations).
        $webAppName = "M365AutoRevocate Admin - $AppName"
        $appId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'list', '--display-name', $webAppName, '--query', '[0].appId', '-o', 'tsv') -AllowFail)
        if (-not $appId) {
            $appId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'create', '--display-name', $webAppName, '--sign-in-audience', 'AzureADMyOrg', '--query', 'appId', '-o', 'tsv'))
        }
        else { Write-Host "Reusing existing app registration '$webAppName'." }
        $appObjId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv'))

        # Reuse the existing API scope id if one is already defined (so re-runs
        # don't invalidate tokens by changing the scope id).
        $existingScopeId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'show', '--id', $appId, '--query', "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]", '-o', 'tsv') -AllowFail)
        $scopeGuid = if ($existingScopeId) { $existingScopeId } else { [Guid]::NewGuid().ToString() }
        $appPatch = @{
            identifierUris = @("api://$appId")
            spa            = @{ redirectUris = @("$webUrl/", "$webUrl/index.html") }
            api            = @{ oauth2PermissionScopes = @(@{
                        id = $scopeGuid; value = 'access_as_user'; type = 'User'; isEnabled = $true
                        adminConsentDisplayName = 'Manage M365AutoRevocate'; adminConsentDescription = 'Allows managing offboarding automation config and viewing logs.'
                        userConsentDisplayName = 'Manage M365AutoRevocate'; userConsentDescription = 'Allows managing offboarding automation config and viewing logs.'
                    }) }
        }
        Invoke-AzRestJson -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$appObjId" -Body $appPatch | Out-Null

        # Tell the admin API which client id to expect, so each admin function
        # can validate the delegated bearer token itself (defense in depth under
        # Easy Auth). Without this the functions fall back to Easy Auth alone.
        Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'set', '--name', $AppName, '--resource-group', $ResourceGroup, '--settings', "AR_ADMIN_CLIENT_ID=$appId") | Out-Null

        # 2) Service principal, require assignment, assign the admin group.
        $spId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv') -AllowFail)
        if (-not $spId) { $spId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'sp', 'create', '--id', $appId, '--query', 'id', '-o', 'tsv')) }
        Invoke-AzRestJson -Method PATCH -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId" -Body @{ appRoleAssignmentRequired = $true } | Out-Null
        Invoke-AzRestJson -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" `
            -Body @{ principalId = $AdminGroupObjectId; resourceId = $spId; appRoleId = '00000000-0000-0000-0000-000000000000' } -AllowFail | Out-Null

        # 3) Easy Auth on the Function App (validate tokens for this app), leaving
        #    the Graph webhook path anonymous, and CORS for the static origin.
        # Written directly as authsettingsV2 via ARM: the 'az functionapp auth'
        # commands failed silently here and left the admin API unauthenticated,
        # so this is now one deterministic PUT followed by a read-back check.
        Invoke-Az -AzArgs @('functionapp', 'cors', 'add', '--name', $AppName, '--resource-group', $ResourceGroup, '--allowed-origins', $webUrl) -AllowFail | Out-Null
        # /admin/* stays outside Easy Auth: those endpoints demand the function
        # master key, and the deploy uses them to trigger the first snapshot.
        $authUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/config/authsettingsV2?api-version=2023-12-01"
        # unauthenticatedClientAction = AllowAnonymous (NOT Return401): a browser
        # CORS preflight (OPTIONS) never carries the Authorization header, so
        # Return401 makes Easy Auth reject the preflight BEFORE App Service can
        # attach the Access-Control-Allow-Origin header, and the SPA breaks with a
        # CORS error even though the origin is allow-listed. AllowAnonymous lets
        # the preflight (and the real request) through to the app; auth is still
        # enforced two ways: Easy Auth validates the bearer token when present,
        # and every admin function ALSO validates it itself (Test-ARAdminRequest,
        # RS256 against tenant JWKS, aud/iss/exp) and fails closed. So the API is
        # never actually open - the platform gate just no longer eats OPTIONS.
        Invoke-AzRestJson -Method PUT -Uri $authUri -Body @{
            properties = @{
                platform          = @{ enabled = $true; runtimeVersion = '~1' }
                globalValidation  = @{
                    requireAuthentication       = $true
                    unauthenticatedClientAction = 'AllowAnonymous'
                    excludedPaths               = @('/api/NotificationHandler', '/admin/*')
                }
                identityProviders = @{
                    azureActiveDirectory = @{
                        enabled      = $true
                        registration = @{ clientId = $appId; openIdIssuer = "https://login.microsoftonline.com/$tenantId/v2.0" }
                        validation   = @{ allowedAudiences = @("api://$appId") }
                    }
                }
                login             = @{ tokenStore = @{ enabled = $true } }
            }
        } | Out-Null
        $authEnabled = Get-AzScalar (Invoke-Az -AzArgs @('rest', '--method', 'get',
                '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/config/authsettingsV2/list?api-version=2023-12-01",
                '--query', 'properties.platform.enabled', '-o', 'tsv') -AllowFail)
        if ("$authEnabled" -ne 'true') {
            throw "Easy Auth verification failed (platform.enabled='$authEnabled'): the platform token gate is off. In-function bearer-token validation still protects the API, but do not rely on it alone - fix Easy Auth before using the web app."
        }
        Write-Host 'Easy Auth verified: platform token gate enabled (in-function validation is the fail-closed backstop).' -ForegroundColor Green
        $authVerified = $true

        # 4) Stage the web/ folder in a temp copy, write authConfig.js with real
        #    values there (so the repo's placeholder stays clean), then upload.
        $webSrc = Join-Path $PSScriptRoot '..\web' | Resolve-Path
        $webStage = Join-Path ([System.IO.Path]::GetTempPath()) "arweb-$([Guid]::NewGuid().ToString('N'))"
        Copy-Item -Path $webSrc -Destination $webStage -Recurse -Force
        $authJs = @"
window.AR_AUTH = {
  clientId: "$appId",
  tenantId: "$tenantId",
  apiBase: "https://$hostName/api",
  apiScope: "api://$appId/access_as_user"
};
"@
        Set-Content -Path (Join-Path $webStage 'authConfig.js') -Value $authJs -Encoding UTF8
        Invoke-Az -AzArgs @('storage', 'blob', 'upload-batch', '--account-name', $WebStorageAccount, '--account-key', $webKey, '--destination', '$web', '--source', $webStage, '--overwrite') | Out-Null
        Remove-Item $webStage -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Admin web app setup did not fully complete: $($_.Exception.Message)"
        Write-Warning 'Azure resources and the API are deployed; finish the web/auth wiring by hand (see docs/web-app.md).'
    }

# --- Seed the directory snapshot ----------------------------------------------
# Manager/ownership look-ups depend on the snapshot, so run the first pass now
# instead of asking the admin to do it. Timer functions are triggered through
# the host's admin API with the master key (that path is excluded from Easy
# Auth but still demands the key).
Write-Step 'Seeding the directory snapshot'
$snapshotStarted = $false
try {
    $masterKey = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'keys', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'masterKey', '-o', 'tsv') -AllowFail)
    if (-not $masterKey) { throw 'could not read the master key' }
    for ($i = 1; $i -le 5 -and -not $snapshotStarted; $i++) {
        try {
            Invoke-RestMethod -Method Post -Uri "https://$hostName/admin/functions/DirectorySnapshot" `
                -Headers @{ 'x-functions-key' = $masterKey; 'Content-Type' = 'application/json' } `
                -Body '{"input":""}' -ErrorAction Stop | Out-Null
            $snapshotStarted = $true
            Write-Host 'Directory snapshot started (runs in the background; large tenants take a while).' -ForegroundColor Green
        }
        catch { Write-Host "Snapshot trigger attempt $i failed; retrying in 15s..."; Start-Sleep -Seconds 15 }
    }
}
catch { }
if (-not $snapshotStarted) { Write-Warning 'Could not auto-start the DirectorySnapshot; it will run on its nightly schedule instead.' }

# --- Seed the Graph subscription ----------------------------------------------
# SubscriptionManager is set to run on startup, but a freshly deployed app may
# not have cold-started yet when the admin first opens the web app, so
# /api/status would show the subscription as missing/unhealthy and confuse them.
# Trigger it once now (same master-key admin path as the snapshot) so the
# subscription exists and reports healthy immediately after install.
Write-Step 'Seeding the Graph subscription'
$subscriptionStarted = $false
try {
    if (-not $masterKey) {
        $masterKey = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'keys', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'masterKey', '-o', 'tsv') -AllowFail)
    }
    if (-not $masterKey) { throw 'could not read the master key' }
    for ($i = 1; $i -le 5 -and -not $subscriptionStarted; $i++) {
        try {
            Invoke-RestMethod -Method Post -Uri "https://$hostName/admin/functions/SubscriptionManager" `
                -Headers @{ 'x-functions-key' = $masterKey; 'Content-Type' = 'application/json' } `
                -Body '{"input":""}' -ErrorAction Stop | Out-Null
            $subscriptionStarted = $true
            Write-Host 'Graph subscription creation started (runs in the background).' -ForegroundColor Green
        }
        catch { Write-Host "Subscription trigger attempt $i failed; retrying in 15s..."; Start-Sleep -Seconds 15 }
    }
}
catch { }
if (-not $subscriptionStarted) { Write-Warning 'Could not auto-start the SubscriptionManager; it will run on startup / its 6-hour schedule instead.' }

# --- Tighten Easy Auth: drop the /admin/* exclusion now seeding is done -------
# /admin/* was excluded only so the master-key call above could start the first
# snapshot. It is not needed at runtime (the app triggers its own timers), so
# remove the exclusion, leaving only the Graph webhook path open.
if ($authVerified) {
    Write-Step 'Tightening Easy Auth'
    try {
        $authUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/config/authsettingsV2?api-version=2023-12-01"
        Invoke-AzRestJson -Method PUT -Uri $authUri -Body @{
            properties = @{
                platform          = @{ enabled = $true; runtimeVersion = '~1' }
                globalValidation  = @{
                    requireAuthentication       = $true
                    unauthenticatedClientAction = 'AllowAnonymous'
                    excludedPaths               = @('/api/NotificationHandler')
                }
                identityProviders = @{
                    azureActiveDirectory = @{
                        enabled      = $true
                        registration = @{ clientId = $appId; openIdIssuer = "https://login.microsoftonline.com/$tenantId/v2.0" }
                        validation   = @{ allowedAudiences = @("api://$appId") }
                    }
                }
                login             = @{ tokenStore = @{ enabled = $true } }
            }
        } | Out-Null
        Write-Host 'Easy Auth tightened: /admin/* is no longer excluded.' -ForegroundColor Green
    }
    catch { Write-Warning "Could not tighten Easy Auth (the /admin/* path may remain excluded): $($_.Exception.Message)" }
}

# --- Network access restrictions ---------------------------------------------
# Lock BOTH public surfaces down to the admin's IP(s) so the tool is not openly
# reachable on the internet: (1) the Function App (admin API + Graph webhook) via
# App Service access restrictions, and (2) the admin web site via its storage
# account firewall. The Function App additionally allows Microsoft Graph's
# change-notification ranges so deletions/disables keep arriving. The STATE
# storage account is deliberately NOT locked -- the tool reaches its Table/Blob/
# Queue over the public endpoints (via AAD) and the Functions host needs it.
# Applied LAST so nothing earlier in the deploy (seeding, web upload) is affected.
$networkLocked = $false
$allowedIps = @()
if ($SkipNetworkLockdown) {
    Write-Warning 'Network lockdown SKIPPED (-SkipNetworkLockdown): the admin console and API stay publicly reachable. Not recommended -- lock them down in the portal or re-run without the switch.'
}
else {
    Write-Step 'Network access restrictions'
    # In Azure Cloud Shell, auto-detection returns the Cloud Shell container's
    # Azure egress IP, which is the wrong thing to whitelist (and would lock the
    # admin out). So there we do NOT auto-detect: use -AllowedAdminIp if given,
    # otherwise ask (with a hint from the sign-in logs). Elsewhere, auto-detect.
    $detectedIp = $null
    if (Test-AzureCloudShell) {
        Write-Host 'Azure Cloud Shell detected: the auto-detected IP would be an Azure address, not yours, so it will NOT be used.' -ForegroundColor Yellow
        if (-not $AllowedAdminIp) {
            Show-ARSignInIpHint
            Write-Host ''
            $entered = (Read-Host 'Public IP or CIDR to allow admin access from (blank = skip lockdown for now, set it later)').Trim()
            if ($entered) { $AllowedAdminIp = @($entered) }
        }
    }
    else {
        $detectedIp = Get-MyPublicIp
    }
    $allowedIps = @(@($AllowedAdminIp) + @($detectedIp) | Where-Object { $_ } | Select-Object -Unique)

    if ($allowedIps.Count -eq 0) {
        Write-Warning 'No admin IP to allow (none entered / detected, and -AllowedAdminIp not given). SKIPPING the lockdown so you are not locked out. Re-run with -AllowedAdminIp <your.public.ip/cidr>, or lock it down in the portal (see README > Network access).'
    }
    else {
        Write-Host "Allowing admin IP(s): $($allowedIps -join ', ')"
        # Function-app rules take CIDR; normalise bare IPs to /32. Storage firewall
        # rejects /32, so strip it back off for the storage rules.
        $adminCidrs = @($allowedIps | ForEach-Object { if ($_ -match '/') { $_ } else { "$_/32" } })
        $storageIps = @($allowedIps | ForEach-Object { $_ -replace '/32$', '' })

        # 1) Function App: allow admin IP(s) + Graph ranges, block the rest.
        try {
            # Idempotent re-runs: drop any AR-* rules we added on a prior run first.
            $existingRules = (Invoke-Az -AzArgs @('functionapp', 'config', 'access-restriction', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '-o', 'json') -AllowFail | Out-String | ConvertFrom-Json)
            foreach ($r in @($existingRules.ipSecurityRestrictions)) {
                if ($r.name -like 'AR-*') { Invoke-Az -AzArgs @('functionapp', 'config', 'access-restriction', 'remove', '--name', $AppName, '--resource-group', $ResourceGroup, '--rule-name', $r.name) -AllowFail | Out-Null }
            }
            $prio = 100
            foreach ($cidr in $adminCidrs) {
                Invoke-Az -AzArgs @('functionapp', 'config', 'access-restriction', 'add', '--name', $AppName, '--resource-group', $ResourceGroup, '--rule-name', "AR-Admin-$prio", '--action', 'Allow', '--ip-address', $cidr, '--priority', "$prio", '--description', 'M365AutoRevocate admin access') | Out-Null
                $prio += 10
            }
            $prio = 300
            foreach ($cidr in $graphNotificationCidrs) {
                Invoke-Az -AzArgs @('functionapp', 'config', 'access-restriction', 'add', '--name', $AppName, '--resource-group', $ResourceGroup, '--rule-name', "AR-Graph-$prio", '--action', 'Allow', '--ip-address', $cidr, '--priority', "$prio", '--description', 'Microsoft Graph change notifications') | Out-Null
                $prio += 10
            }
            # Unmatched rule action = block. Adding Allow rules already makes the
            # implicit default Deny; set it explicitly too (best-effort: older az
            # may not support --default-action, in which case the implicit deny
            # from the Allow rules above still applies).
            Invoke-Az -AzArgs @('functionapp', 'config', 'access-restriction', 'set', '--name', $AppName, '--resource-group', $ResourceGroup, '--default-action', 'Deny') -AllowFail | Out-Null
            Write-Host 'Function App locked: admin IP(s) + Microsoft Graph ranges allowed, everything else blocked.' -ForegroundColor Green
            $networkLocked = $true
        }
        catch { Write-Warning "Could not fully lock down the Function App network (finish it in the portal): $($_.Exception.Message)" }

        # 2) Admin web site (its storage account): allow admin IP(s), block the rest.
        try {
            Invoke-Az -AzArgs @('storage', 'account', 'update', '--name', $WebStorageAccount, '--resource-group', $ResourceGroup, '--default-action', 'Deny', '--bypass', 'AzureServices') | Out-Null
            foreach ($ip in $storageIps) {
                Invoke-Az -AzArgs @('storage', 'account', 'network-rule', 'add', '--account-name', $WebStorageAccount, '--resource-group', $ResourceGroup, '--ip-address', $ip) -AllowFail | Out-Null
            }
            Write-Host 'Admin web site (storage firewall) locked to admin IP(s).' -ForegroundColor Green
        }
        catch { Write-Warning "Could not lock down the web storage network (finish it in the portal): $($_.Exception.Message)" }
    }
}

# --- Done --------------------------------------------------------------------
Write-Step 'Done'
Write-Host "M365AutoRevocate is deployed." -ForegroundColor Green
Write-Host ""
Write-Host "Function app     : $AppName"
Write-Host "Notification URL : https://$hostName/api/NotificationHandler (key hidden)"
if ($webUrl) { Write-Host "Admin web app    : $webUrl/" -ForegroundColor Green }

# Network access status -- state it plainly: this determines who can reach the
# admin console + API at all.
Write-Host ""
if ($SkipNetworkLockdown) {
    Write-Host "Network access   : PUBLIC (lockdown skipped). The admin console and API are reachable from any IP." -ForegroundColor Red
    Write-Host "                   We do NOT recommend this. Restrict it: Function App > Networking > Access restrictions," -ForegroundColor Red
    Write-Host "                   and storage account '$WebStorageAccount' > Networking. See README > Network access." -ForegroundColor Red
}
elseif ($networkLocked) {
    Write-Host "Network access   : LOCKED to $($allowedIps -join ', ')" -ForegroundColor Green
    Write-Host "                   The Function App also allows Microsoft Graph's change-notification ranges so deletions/disables keep arriving."
    Write-Host "                   To add an IP later: re-run with -AllowedAdminIp <ip/cidr>, or in the portal (Function App > Networking >"
    Write-Host "                   Access restrictions, and storage account '$WebStorageAccount' > Networking). See README > Network access."
}
else {
    Write-Host "Network access   : NOT locked down (could not determine your IP, or it failed)." -ForegroundColor Yellow
    Write-Host "                   The admin console/API may be publicly reachable. Restrict it in the portal or re-run with -AllowedAdminIp. See README > Network access." -ForegroundColor Yellow
}
Write-Host ""

# Only surface follow-up work that is actually needed.
$steps = [System.Collections.Generic.List[string]]::new()
if ($graphRolesFailed.Count -gt 0) {
    $steps.Add("Grant + consent the missing API permissions ($($graphRolesFailed -join ', ')) for the '$AppName' managed identity (needs Global Admin / Privileged Role Admin). Re-running the deploy or the update reconciles them from deploy/permissions.json.")
}
if (-not $exoScoped) {
    $steps.Add("Finish the Exchange Online mailbox scoping for '$SenderUpn' (see docs/permissions.md) -- the hand-off email will not send until then.")
}
if (-not $snapshotStarted) {
    $steps.Add("The directory snapshot could not be auto-started; it runs tonight automatically, or trigger 'DirectorySnapshot' from the portal (Function app > DirectorySnapshot > Test/Run).")
}
if (-not $authVerified) {
    Write-Host ''
    Write-Host 'WARNING: Easy Auth on the admin API could NOT be verified. The admin web API may be reachable without authentication. Fix this before using the web app (re-run this script, or check Authentication on the Function App in the portal).' -ForegroundColor Red
    $steps.Add("Verify Authentication (Easy Auth) on '$AppName': it must be Enabled with action 'HTTP 401' and only /api/NotificationHandler and /admin/* excluded.")
}
if ($SkipNetworkLockdown -or (-not $networkLocked)) {
    $steps.Add("Restrict inbound network access (we do NOT recommend leaving it public): re-run with -AllowedAdminIp <ip/cidr>, or lock down '$AppName' (Networking > Access restrictions) and storage '$WebStorageAccount' (Networking) in the portal. Keep the Microsoft Graph ranges allowed on the Function App. See README > Network access.")
}
elseif ($allowedIps.Count) {
    $steps.Add("Access is locked to $($allowedIps -join ', '). If your IP changes or a teammate needs in, add their IP: re-run with -AllowedAdminIp <ip/cidr> or edit the rules in the portal (see README > Network access).")
}
$steps.Add('Open the admin web app -- the first sign-in starts a short setup wizard (delete timing, inactive-user monitoring).')

Write-Host "Next steps:" -ForegroundColor Yellow
for ($i = 0; $i -lt $steps.Count; $i++) { Write-Host "  $($i + 1). $($steps[$i])" }
if ($webUrl) {
    Write-Host ""; Write-Host "    $webUrl/" -ForegroundColor Cyan
    # Open the admin web app in the default browser so setup can continue at once.
    try { Start-Process "$webUrl/" } catch { Write-Host "(Open $webUrl/ in your browser to finish setup.)" }
}
