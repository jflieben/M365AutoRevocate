# Power Platform offboarding actions: disable, delete or re-own the cloud flows
# and canvas apps a departing user owns.
#
# There is NO Microsoft Graph surface for this. The tool uses the Power Platform
# ADMIN REST APIs directly with the managed identity, across three audiences:
#   * https://api.bap.microsoft.com          -> list environments (also our
#                                               access-detection probe)
#   * https://service.powerapps.com/         -> token audience for both the flow
#                                               and the powerapps admin APIs
# Access is NOT granted by an app role/consent. An admin authorises the managed
# identity as a Power Platform management application, out of band:
#     Install-Module Microsoft.PowerApps.Administration.PowerShell
#     Add-PowerAppsAccount
#     New-PowerAppManagementApp -ApplicationId "<managed-identity-app-id>"
# Until that is done every admin call returns 401/403; the web app greys the
# actions out and shows those commands (see Get-ARPowerPlatformStatus).
#
# Ownership is matched by the departing user's object id, which we have at every
# trigger (including delete: Power Platform keeps the owner/creator reference on
# the object for a while after the Entra account is gone). Enumeration is one
# call per environment for flows and one for apps, so it scales with the number
# of environments, not users.

function Get-ARPowerPlatformApiToken {
    [CmdletBinding()] param()
    return Get-ARManagedIdentityToken -Resource (Get-ARConfig).PowerPlatformApiResource
}

function Get-ARPowerPlatformBapToken {
    [CmdletBinding()] param()
    return Get-ARManagedIdentityToken -Resource (Get-ARConfig).PowerPlatformBapResource
}

function Invoke-ARPowerPlatform {
    <#
    .SYNOPSIS
        REST call to a Power Platform admin API with a managed-identity token for
        the given resource. Honours throttling (429/5xx). With -All follows the
        API's nextLink and returns the concatenated 'value' collection. With -Raw
        returns @{ StatusCode; Body } (used to tell 401/403/404 apart).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Resource,
        [ValidateSet('Get', 'Post', 'Delete')][string]$Method = 'Get',
        $Body,
        [switch]$All,
        [switch]$Raw,
        [int]$MaxRetries = 4
    )

    $results = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        $params = @{
            Method                  = $Method
            Uri                     = $Uri
            Headers                 = @{ Authorization = "Bearer $(Get-ARManagedIdentityToken -Resource $Resource)"; Accept = 'application/json' }
            ErrorAction             = 'Stop'
            StatusCodeVariable      = 'statusCode'
            SkipHttpErrorCheck      = $true
            ResponseHeadersVariable = 'respHeaders'
        }
        if ($null -ne $Body) {
            $params.ContentType = 'application/json'
            $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        }

        $attempt = 0
        while ($true) {
            $attempt++
            $response = Invoke-RestMethod @params
            if ($statusCode -in @(429, 503, 504, 500) -and $attempt -le $MaxRetries) {
                $retryAfter = 0
                if ($respHeaders -and $respHeaders['Retry-After']) { [void][int]::TryParse(($respHeaders['Retry-After'] | Select-Object -First 1), [ref]$retryAfter) }
                if ($retryAfter -le 0) { $retryAfter = [Math]::Min(60, [Math]::Pow(2, $attempt)) }
                Write-Warning "Power Platform returned $statusCode for $Method $Uri; retrying in ${retryAfter}s (attempt $attempt/$MaxRetries)."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            break
        }

        if ($Raw) { return [pscustomobject]@{ StatusCode = $statusCode; Body = $response } }
        if ($statusCode -ge 400) {
            $detail = if ($response) { ($response | ConvertTo-Json -Depth 6 -Compress) } else { '(no body)' }
            throw "Power Platform $Method $Uri failed with HTTP $statusCode`: $detail"
        }

        if ($All -and $response -and ($response.PSObject.Properties.Name -contains 'value')) {
            foreach ($item in $response.value) { $results.Add($item) }
            $next = if ($response.PSObject.Properties['nextLink']) { $response.nextLink } else { $response.'@odata.nextLink' }
            if ($next) { $Uri = $next; continue }
            return $results
        }
        return $response
    }
}

$script:ARPPStatusCache = $null
$script:ARPPStatusCacheAt = [DateTimeOffset]::MinValue

function Get-ARPowerPlatformStatus {
    <#
    .SYNOPSIS
        Whether the managed identity is authorised as a Power Platform admin, plus
        the app id the operator needs for New-PowerAppManagementApp. Drives the web
        app's greyed-out Power Platform section. Cached per worker (~10 min).
        Returns @{ accessible; appId; environmentCount; error }.
    #>
    [CmdletBinding()] param([switch]$Fresh)
    if (-not $Fresh -and $null -ne $script:ARPPStatusCache -and
        ([DateTimeOffset]::UtcNow - $script:ARPPStatusCacheAt).TotalMinutes -lt 10) {
        return $script:ARPPStatusCache
    }
    $cfg = Get-ARConfig
    $appId = $null
    try { $appId = Get-ARManagedIdentityAppId } catch { }
    $result = [ordered]@{ accessible = $false; appId = $appId; environmentCount = 0; error = $null }
    try {
        $uri = '{0}/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01&$expand=properties' -f $cfg.PowerPlatformBapResource
        $r = Invoke-ARPowerPlatform -Uri $uri -Resource $cfg.PowerPlatformBapResource -Raw
        if ($r.StatusCode -lt 400) {
            $result.accessible = $true
            $result.environmentCount = @($r.Body.value).Count
        }
        elseif ($r.StatusCode -in 401, 403) {
            $result.error = "not authorised (HTTP $($r.StatusCode)); run New-PowerAppManagementApp for this managed identity"
        }
        else { $result.error = "environments probe returned HTTP $($r.StatusCode)" }
    }
    catch { $result.error = $_.Exception.Message }
    $script:ARPPStatusCache = $result
    $script:ARPPStatusCacheAt = [DateTimeOffset]::UtcNow
    return $result
}

function Get-ARPowerPlatformEnvironmentIds {
    <#
    .SYNOPSIS
        Environment ids the managed identity can administer. Throws on a read
        failure so callers can decide (the orchestrator treats it as "no objects
        resolved" and records the error).
    #>
    [CmdletBinding()] param()
    $cfg = Get-ARConfig
    $uri = '{0}/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01&$expand=properties' -f $cfg.PowerPlatformBapResource
    $envs = Invoke-ARPowerPlatform -Uri $uri -Resource $cfg.PowerPlatformBapResource -All
    return @($envs | ForEach-Object { $_.name } | Where-Object { $_ })
}

function Get-ARUserPowerPlatformObjects {
    <#
    .SYNOPSIS
        The cloud flows and canvas apps owned by the user, across every
        environment. Ownership is matched by object id: a flow's creator, an app's
        owner. Works at the delete trigger too (the reference outlives the account
        for a while). One flow list + one app list per environment; a per-object
        permission walk is deliberately avoided so this scales. Returns items:
        { Kind='flow'|'app'; EnvironmentId; Id; Name; State }.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    $cfg = Get-ARConfig
    $list = [System.Collections.Generic.List[object]]::new()
    $envIds = Get-ARPowerPlatformEnvironmentIds
    foreach ($envId in $envIds) {
        try {
            $flowsUri = '{0}/providers/Microsoft.ProcessSimple/scopes/admin/environments/{1}/v2/flows?api-version=2016-11-01' -f $cfg.PowerPlatformFlowHost, $envId
            $flows = Invoke-ARPowerPlatform -Uri $flowsUri -Resource $cfg.PowerPlatformApiResource -All
            foreach ($f in $flows) {
                # The admin flow list carries the creator (the flow's owner) as a
                # UserIdentity; different API revisions surface the id as objectId
                # or userId, so match either. Co-owners added via sharing are not
                # in this list and are not matched (documented limitation).
                $creator = $f.properties.creator
                $creatorId = if ($creator) { @($creator.objectId, $creator.userId) | Where-Object { $_ } | Select-Object -First 1 } else { $null }
                if ("$creatorId" -eq $UserId) {
                    $list.Add([pscustomobject]@{ Kind = 'flow'; EnvironmentId = $envId; Id = $f.name; Name = "$($f.properties.displayName)"; State = "$($f.properties.state)" })
                }
            }
        }
        catch { Write-Warning "Power Platform: listing flows in environment $envId failed: $($_.Exception.Message)" }

        try {
            $appsUri = '{0}/providers/Microsoft.PowerApps/scopes/admin/environments/{1}/apps?api-version=2016-11-01' -f $cfg.PowerPlatformAppsHost, $envId
            $apps = Invoke-ARPowerPlatform -Uri $appsUri -Resource $cfg.PowerPlatformApiResource -All
            foreach ($a in $apps) {
                $ownerId = $a.properties.owner.id
                if ("$ownerId" -eq $UserId) {
                    # An app's "disabled" state is its admin quarantine flag, which
                    # lives under executionRestrictions.appQuarantineState (NOT the
                    # top-level appQuarantineState, which is always null on the admin
                    # GET). Capture it so Disable can skip an already-quarantined app.
                    $qStatus = "$($a.properties.executionRestrictions.appQuarantineState.quarantineStatus)"
                    $list.Add([pscustomobject]@{ Kind = 'app'; EnvironmentId = $envId; Id = $a.name; Name = "$($a.properties.displayName)"; State = $qStatus })
                }
            }
        }
        catch { Write-Warning "Power Platform: listing apps in environment $envId failed: $($_.Exception.Message)" }
    }
    return $list
}

function New-ARPowerPlatformSummary {
    param([string]$Action)
    return [pscustomobject]@{ Action = $Action; Total = 0; Succeeded = 0; Skipped = 0; Errors = 0; DryRun = [bool](Get-ARConfig).DryRun; Items = @() }
}

function Add-ARPowerPlatformItem {
    param($Summary, $Object, [string]$Result)
    $Summary.Items += [pscustomobject]@{ Kind = $Object.Kind; Name = $Object.Name; Result = $Result }
}

function Disable-ARPowerPlatformObjects {
    <#
    .SYNOPSIS
        Turns off owned flows (stop) and quarantines owned canvas apps.
    .DESCRIPTION
        Flows are stopped via /stop (state becomes 'Stopped'). Canvas apps have no
        enabled/disabled flag, so "disable" = admin QUARANTINE via
        /setAppQuarantineState { quarantineStatus = 'Quarantined' }. A quarantined
        app cannot be opened or played by anyone (owner included) - users get an
        "app is quarantined by your admin" message - which is the closest
        equivalent to disabling it. Fully reversible ('Unquarantined'). The state
        is reported by the admin API under
        properties.executionRestrictions.appQuarantineState.quarantineStatus
        (the top-level appQuarantineState field is always null), which the
        enumeration captures so an already-quarantined app is skipped here.
    #>
    [CmdletBinding()] param([object[]]$Objects)
    $cfg = Get-ARConfig
    $summary = New-ARPowerPlatformSummary -Action 'disable'
    if (-not $Objects -or $Objects.Count -eq 0) { Write-Host 'disablePowerPlatform: user owns no flows/apps; skipping.'; return $summary }
    foreach ($o in $Objects) {
        $summary.Total++
        if ($o.Kind -eq 'flow' -and $o.State -in @('Stopped', 'Suspended')) { $summary.Skipped++; Add-ARPowerPlatformItem $summary $o 'already off'; continue }
        if ($o.Kind -eq 'app' -and $o.State -eq 'Quarantined') { $summary.Skipped++; Add-ARPowerPlatformItem $summary $o 'already quarantined'; continue }
        if ($cfg.DryRun) { $summary.Succeeded++; Add-ARPowerPlatformItem $summary $o 'would disable'; continue }
        try {
            if ($o.Kind -eq 'flow') {
                $uri = '{0}/providers/Microsoft.ProcessSimple/scopes/admin/environments/{1}/flows/{2}/stop?api-version=2016-11-01' -f $cfg.PowerPlatformFlowHost, $o.EnvironmentId, $o.Id
                $null = Invoke-ARPowerPlatform -Method Post -Uri $uri -Resource $cfg.PowerPlatformApiResource
            }
            else {
                $uri = '{0}/providers/Microsoft.PowerApps/scopes/admin/environments/{1}/apps/{2}/setAppQuarantineState?api-version=2016-11-01' -f $cfg.PowerPlatformAppsHost, $o.EnvironmentId, $o.Id
                $null = Invoke-ARPowerPlatform -Method Post -Uri $uri -Resource $cfg.PowerPlatformApiResource -Body @{ quarantineStatus = 'Quarantined' }
            }
            $summary.Succeeded++; Add-ARPowerPlatformItem $summary $o 'disabled'
        }
        catch { Write-Warning "Disabling $($o.Kind) '$($o.Name)' failed: $($_.Exception.Message)"; $summary.Errors++; Add-ARPowerPlatformItem $summary $o "error: $($_.Exception.Message)" }
    }
    Write-Host "Power Platform disable: total=$($summary.Total) done=$($summary.Succeeded) skipped=$($summary.Skipped) errors=$($summary.Errors)."
    return $summary
}

function Remove-ARPowerPlatformObjects {
    <#
    .SYNOPSIS
        Permanently deletes owned flows and canvas apps.
    #>
    [CmdletBinding()] param([object[]]$Objects)
    $cfg = Get-ARConfig
    $summary = New-ARPowerPlatformSummary -Action 'delete'
    if (-not $Objects -or $Objects.Count -eq 0) { Write-Host 'deletePowerPlatform: user owns no flows/apps; skipping.'; return $summary }
    foreach ($o in $Objects) {
        $summary.Total++
        if ($cfg.DryRun) { $summary.Succeeded++; Add-ARPowerPlatformItem $summary $o 'would delete'; continue }
        try {
            if ($o.Kind -eq 'flow') {
                $uri = '{0}/providers/Microsoft.ProcessSimple/scopes/admin/environments/{1}/flows/{2}?api-version=2016-11-01' -f $cfg.PowerPlatformFlowHost, $o.EnvironmentId, $o.Id
            }
            else {
                $uri = '{0}/providers/Microsoft.PowerApps/scopes/admin/environments/{1}/apps/{2}?api-version=2016-11-01' -f $cfg.PowerPlatformAppsHost, $o.EnvironmentId, $o.Id
            }
            $null = Invoke-ARPowerPlatform -Method Delete -Uri $uri -Resource $cfg.PowerPlatformApiResource
            $summary.Succeeded++; Add-ARPowerPlatformItem $summary $o 'deleted'
        }
        catch { Write-Warning "Deleting $($o.Kind) '$($o.Name)' failed: $($_.Exception.Message)"; $summary.Errors++; Add-ARPowerPlatformItem $summary $o "error: $($_.Exception.Message)" }
    }
    Write-Host "Power Platform delete: total=$($summary.Total) deleted=$($summary.Succeeded) errors=$($summary.Errors)."
    return $summary
}

function Set-ARPowerPlatformObjectsOwner {
    <#
    .SYNOPSIS
        Re-owns owned flows and canvas apps to a new principal (the manager, with
        the service desk as fallback). Apps use modifyAppOwner (a real ownership
        transfer, demoting the old owner to CanView); flows add the new principal
        as a co-owner (a flow's original Owner role cannot be reassigned).
    #>
    [CmdletBinding()] param([object[]]$Objects, [Parameter(Mandatory)][string]$NewOwnerId)
    $cfg = Get-ARConfig
    $summary = New-ARPowerPlatformSummary -Action 'reown'
    if (-not $Objects -or $Objects.Count -eq 0) { Write-Host 'reownPowerPlatform: user owns no flows/apps; skipping.'; return $summary }
    if ([string]::IsNullOrWhiteSpace($NewOwnerId)) {
        Write-Warning 'reownPowerPlatform: no new owner id resolved (no manager and no service desk object id); skipping.'
        $summary | Add-Member -NotePropertyName Reason -NotePropertyValue 'no new owner resolved' -Force
        return $summary
    }
    foreach ($o in $Objects) {
        $summary.Total++
        if ($cfg.DryRun) { $summary.Succeeded++; Add-ARPowerPlatformItem $summary $o 'would re-own'; continue }
        try {
            if ($o.Kind -eq 'flow') {
                $uri = '{0}/providers/Microsoft.ProcessSimple/scopes/admin/environments/{1}/flows/{2}/modifyPermissions?api-version=2016-11-01' -f $cfg.PowerPlatformFlowHost, $o.EnvironmentId, $o.Id
                $body = @{ put = @(@{ properties = @{ principal = @{ id = $NewOwnerId; type = 'User' }; roleName = 'CanEdit' } }) }
                $null = Invoke-ARPowerPlatform -Method Post -Uri $uri -Resource $cfg.PowerPlatformApiResource -Body $body
            }
            else {
                $uri = '{0}/providers/Microsoft.PowerApps/scopes/admin/environments/{1}/apps/{2}/modifyAppOwner?api-version=2016-11-01' -f $cfg.PowerPlatformAppsHost, $o.EnvironmentId, $o.Id
                $body = @{ roleForOldAppOwner = 'CanView'; newAppOwner = $NewOwnerId }
                $null = Invoke-ARPowerPlatform -Method Post -Uri $uri -Resource $cfg.PowerPlatformApiResource -Body $body
            }
            $summary.Succeeded++; Add-ARPowerPlatformItem $summary $o 're-owned'
        }
        catch { Write-Warning "Re-owning $($o.Kind) '$($o.Name)' failed: $($_.Exception.Message)"; $summary.Errors++; Add-ARPowerPlatformItem $summary $o "error: $($_.Exception.Message)" }
    }
    Write-Host "Power Platform re-own: total=$($summary.Total) reowned=$($summary.Succeeded) errors=$($summary.Errors)."
    return $summary
}
