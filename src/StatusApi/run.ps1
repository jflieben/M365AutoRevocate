using namespace System.Net

# Admin API: diagnostics for the web app's Diagnostics tab.
#   * The Graph change-notification subscription (status, id, expiry, target).
#   * Per-function heartbeats (last run, status, duration, last error).
# Protected by Easy Auth like the other admin endpoints.

param($Request, $TriggerMetadata)

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 8)
        })
}

try {
    $auth = Test-ARAdminRequest -Request $Request
    if (-not $auth.Ok) { Send-Json -Status $auth.Status -Object @{ error = $auth.Error }; return }

    Initialize-ARTables

    # --- Graph subscription ---------------------------------------------------
    $subInfo = @{ status = 'missing' }
    try {
        $sub = Get-ARExistingSubscription
        if ($sub) {
            $expires = [DateTimeOffset]::Parse($sub.expirationDateTime)
            $hoursLeft = [Math]::Round(($expires - [DateTimeOffset]::UtcNow).TotalHours, 1)
            $subInfo = @{
                status             = if ($hoursLeft -le 0) { 'expired' } elseif ($hoursLeft -lt 12) { 'expiring' } else { 'active' }
                id                 = $sub.id
                resource           = $sub.resource
                changeType         = $sub.changeType
                expirationDateTime = $sub.expirationDateTime
                hoursUntilExpiry   = $hoursLeft
                # Never expose the function key embedded in the callback URL.
                notificationUrl    = ($sub.notificationUrl -replace '(code=)[^&]+', '$1***')
            }
        }
    }
    catch { $subInfo = @{ status = 'unknown'; error = $_.Exception.Message } }

    # --- Azure portal deep links -------------------------------------------------
    # Built from the App Service environment: WEBSITE_OWNER_NAME is
    # '{subscriptionId}+{resourceGroup}-{region}webspace...', which gives us the
    # subscription id without any extra permission or configuration.
    $siteName = [Environment]::GetEnvironmentVariable('WEBSITE_SITE_NAME')
    $rgName   = [Environment]::GetEnvironmentVariable('WEBSITE_RESOURCE_GROUP')
    $owner    = [Environment]::GetEnvironmentVariable('WEBSITE_OWNER_NAME')
    $subId    = if ($owner -and $owner.Contains('+')) { $owner.Split('+')[0] } else { $null }

    function Get-PortalFunctionUrl {
        param([string]$FunctionName)
        if (-not ($subId -and $rgName -and $siteName)) { return $null }
        $resourceId = "/subscriptions/$subId/resourceGroups/$rgName/providers/Microsoft.Web/sites/$siteName/functions/$FunctionName"
        return 'https://portal.azure.com/#view/WebsitesExtension/FunctionTabMenuBlade/~/invocations/resourceId/' + [Uri]::EscapeDataString($resourceId)
    }

    # --- Function heartbeats ----------------------------------------------------
    # Every function that has ever run reports here; list the known set so the
    # UI also shows functions that have NEVER run (that itself is a finding).
    $known = @('SubscriptionManager', 'NotificationHandler', 'RevocationProcessor', 'HardDeleteReconciler', 'DirectorySnapshot', 'InactivityScanner', 'ActivityLogCleanup', 'ReconciliationSweep', 'Watchdog', 'VersionChecker')
    $beats = @{}
    foreach ($b in (Get-ARHeartbeats)) { $beats[$b.RowKey] = $b }
    $functions = foreach ($name in ($known + ($beats.Keys | Where-Object { $_ -notin $known }))) {
        $b = $beats[$name]
        [pscustomobject]@{
            name         = $name
            portalUrl    = Get-PortalFunctionUrl -FunctionName $name
            lastRun      = if ($b) { $b.LastRunUtc } else { $null }
            status       = if ($b) { $b.LastStatus } else { 'never ran' }
            durationMs   = if ($b) { $b.LastDurationMs } else { $null }
            lastSuccess  = if ($b -and $b.PSObject.Properties['LastSuccessUtc']) { $b.LastSuccessUtc } else { $null }
            lastError    = if ($b -and $b.PSObject.Properties['LastError']) { $b.LastError } else { $null }
            lastErrorUtc = if ($b -and $b.PSObject.Properties['LastErrorUtc']) { $b.LastErrorUtc } else { $null }
        }
    }

    # --- Safety / storm guard, dry-run banner, versions, snapshot age ---------
    $cfg = Get-ARConfig
    $features = Get-ARFeatureConfig
    $safety = $null
    try { $safety = Get-ARSafetyStatus -FeatureConfig $features } catch { $safety = @{ error = $_.Exception.Message } }

    $snapshotUtc = $null
    try {
        $meta = Get-ARTableEntity -Table (Get-ARTableNames).Safety -PartitionKey 'meta' -RowKey 'directorySize'
        if ($meta -and $meta.PSObject.Properties['Utc']) { $snapshotUtc = $meta.Utc }
    }
    catch { }

    # Poison queue depth: messages that failed processing repeatedly. Non-zero is
    # a finding (a bug or a persistently unreachable user).
    $poison = -1; $queueDepth = -1
    try { $poison = Get-ARQueueDepth -Name ($cfg.RevocationQueue + '-poison') } catch { }
    try { $queueDepth = Get-ARQueueDepth -Name $cfg.RevocationQueue } catch { }

    # Permission nudge: roles this config needs vs roles the identity holds.
    $permissions = @()
    try { $permissions = @(Get-ARPermissionStatus -FeatureConfig $features) } catch { }

    # Weekly version check result (installed vs latest published).
    $versionCheck = $null
    try { $versionCheck = Get-ARVersionCheckStatus } catch { $versionCheck = @{ error = $_.Exception.Message } }

    Send-Json -Status 200 -Object @{
        subscription = $subInfo
        functions    = @($functions)
        safety       = $safety
        dryRun       = [bool]$features.dryRun
        version      = $cfg.Version
        versionCheck = $versionCheck
        snapshotUtc  = $snapshotUtc
        queues       = @{ revocations = $queueDepth; poison = $poison }
        permissions  = $permissions
    }
}
catch {
    Write-Error "StatusApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
