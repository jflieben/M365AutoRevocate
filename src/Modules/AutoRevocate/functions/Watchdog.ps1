# Watchdog.
#
# Operators do not watch dashboards. This daily check emails the service desk
# (from the already-scoped sender mailbox) when something is wrong: a worker
# function is failing, the Graph subscription is missing/expired, the directory
# snapshot has gone stale, the poison queue is non-empty, or the storm guard has
# paused processing. Healthy runs are silent.

function Invoke-ARWatchdog {
    [CmdletBinding()] param()
    $cfg = Get-ARConfig
    $features = Get-ARFeatureConfig
    $issues = [System.Collections.Generic.List[string]]::new()

    foreach ($b in (Get-ARHeartbeats)) {
        if ("$($b.LastStatus)" -eq 'error') {
            $issues.Add("Function '$($b.RowKey)' last run FAILED: $($b.LastError)")
        }
    }

    try {
        $sub = Get-ARExistingSubscription
        if (-not $sub) { $issues.Add('Graph subscription is MISSING; deletions/disables are not being received.') }
        elseif ([DateTimeOffset]::Parse($sub.expirationDateTime) -lt [DateTimeOffset]::UtcNow) { $issues.Add('Graph subscription has EXPIRED.') }
    }
    catch { $issues.Add("Could not check the Graph subscription: $($_.Exception.Message)") }

    try {
        $meta = Get-ARTableEntity -Table (Get-ARTableNames).Safety -PartitionKey 'meta' -RowKey 'directorySize'
        if ($meta -and $meta.PSObject.Properties['Utc'] -and $meta.Utc) {
            $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($meta.Utc)).TotalHours
            if ($age -gt 48) { $issues.Add("Directory snapshot is stale ($([int]$age)h old); delete-time manager/ownership may be wrong.") }
        }
        else { $issues.Add('Directory snapshot has never completed.') }
    }
    catch { }

    try { $p = Get-ARQueueDepth -Name ($cfg.RevocationQueue + '-poison'); if ($p -gt 0) { $issues.Add("$p message(s) in the poison queue (cleanups that failed repeatedly).") } } catch { }

    if (Test-ARPaused) { $pe = Get-ARPausedEntity; $issues.Add("Processing is PAUSED by the storm guard: $(if ($pe) { $pe.Reason })") }

    if ($issues.Count -eq 0) { Write-Host 'Watchdog: all healthy.'; return }
    Write-Host "Watchdog: $($issues.Count) issue(s) found."

    $to = "$($features.servicedeskEmail)".Trim()
    if ($to -and -not $cfg.DryRun) {
        try { Send-ARAlertMail -To $to -Subject "M365AutoRevocate health alert: $($issues.Count) issue(s)" -Issues @($issues) }
        catch { Write-Warning "Watchdog could not send the alert email: $($_.Exception.Message)" }
    }
    elseif (-not $to) { Write-Warning 'Watchdog: no service desk email configured; cannot email the alert (it is still in the activity log).' }
    else { Write-Host "[DryRun] Would email $to about $($issues.Count) issue(s)." }

    Write-ARSystemActivity -EventName "Watchdog: $($issues.Count) health issue(s)" -SummaryObject @{ issues = @($issues) }
}
