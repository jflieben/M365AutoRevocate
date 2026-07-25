# Storm guard / circuit breaker.
#
# A destructive tool driven by tenant-wide events must not turn one mistake
# (an Entra Connect OU-filter slip that soft-deletes 10,000 users; a first-time
# inactivity enablement in an old tenant; a scripted bulk-disable) into 10,000
# irreversible cleanups. This module caps how many users the tool will act on
# per trigger per day and, on breach, PAUSES all processing until an admin
# reviews the activity log and explicitly resumes.
#
# State lives in the SafetyState table:
#   flag  / paused          -> the circuit-breaker latch (Paused/Reason/Utc)
#   count / <trigger>|<date> -> actions taken today, per trigger
#   meta  / directorySize    -> last known user count (for the percent ceiling)
#
# The counter increment is read-modify-write, so under heavy queue concurrency
# it can undercount by a few; the numeric cap has headroom and the percent
# ceiling is a second backstop, so a small race never defeats the guard.

function Get-ARPausedEntity {
    [CmdletBinding()] param()
    $tables = Get-ARTableNames
    return Get-ARTableEntity -Table $tables.Safety -PartitionKey 'flag' -RowKey 'paused'
}

function Test-ARPaused {
    [CmdletBinding()] param()
    $e = Get-ARPausedEntity
    return [bool]($e -and "$($e.Paused)".ToLowerInvariant() -eq 'true')
}

function Set-ARPaused {
    <#
    .SYNOPSIS
        Latches the circuit breaker. Idempotent: does not overwrite an existing
        pause reason (the first trip is the interesting one).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Reason, [string]$Trigger)
    $tables = Get-ARTableNames
    if (Test-ARPaused) { return }
    Set-ARTableEntity -Table $tables.Safety -PartitionKey 'flag' -RowKey 'paused' -Properties @{
        Paused  = 'true'
        Reason  = $Reason
        Trigger = $Trigger
        Utc     = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-ARSystemActivity -EventName 'PAUSED by storm guard' -Detail $Reason
    Write-Warning "STORM GUARD TRIPPED: $Reason. All processing is paused until an admin resumes from the web app."
}

function Clear-ARPaused {
    <#
    .SYNOPSIS
        Resumes processing: clears the latch AND resets today's counters so the
        run that tripped it can proceed. Records who resumed.
    #>
    [CmdletBinding()] param([string]$Actor)
    $tables = Get-ARTableNames
    try { Remove-ARTableEntity -Table $tables.Safety -PartitionKey 'flag' -RowKey 'paused' } catch { }
    $today = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd')
    foreach ($t in @('inactive', 'disable', 'delete')) {
        try { Remove-ARTableEntity -Table $tables.Safety -PartitionKey 'count' -RowKey ("$t|$today") } catch { }
    }
    Write-ARSystemActivity -EventName 'Resumed (storm guard cleared)' -Actor $Actor -Detail 'Daily action counters reset; processing resumes.'
}

function Get-ARSafetyCount {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Trigger, [string]$Date)
    if (-not $Date) { $Date = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd') }
    $tables = Get-ARTableNames
    $e = Get-ARTableEntity -Table $tables.Safety -PartitionKey 'count' -RowKey ("$Trigger|$Date")
    $n = 0
    if ($e -and $e.PSObject.Properties['Count']) { [void][int]::TryParse("$($e.Count)", [ref]$n) }
    return $n
}

function Add-ARSafetyCount {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Trigger)
    $tables = Get-ARTableNames
    $today = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd')
    $current = Get-ARSafetyCount -Trigger $Trigger -Date $today
    Merge-ARTableEntity -Table $tables.Safety -PartitionKey 'count' -RowKey ("$Trigger|$today") -Properties @{
        Count     = [string]($current + 1)
        Trigger   = $Trigger
        Date      = $today
        UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    return ($current + 1)
}

function Set-ARDirectorySize {
    [CmdletBinding()] param([Parameter(Mandatory)][int]$Size)
    $tables = Get-ARTableNames
    Set-ARTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'directorySize' -Properties @{
        Size = [string]$Size
        Utc  = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Get-ARDirectorySize {
    [CmdletBinding()] param()
    $tables = Get-ARTableNames
    $e = Get-ARTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'directorySize'
    $n = 0
    if ($e -and $e.PSObject.Properties['Size']) { [void][int]::TryParse("$($e.Size)", [ref]$n) }
    return $n
}

function Test-ARStormGuard {
    <#
    .SYNOPSIS
        The gate every destructive action passes through. Returns whether this
        action is allowed and, as a side effect, counts allowed actions and
        trips the breaker (pauses) when a cap or the percent ceiling is reached.
    .OUTPUTS
        [pscustomobject] @{ Allowed = [bool]; Reason = [string]; Paused = [bool] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('inactive', 'disable', 'delete')][string]$Trigger,
        $FeatureConfig
    )
    if (-not $FeatureConfig) { $FeatureConfig = Get-ARFeatureConfig }
    $safety = $FeatureConfig.safety
    if (-not $safety -or -not $safety.enabled) {
        return [pscustomobject]@{ Allowed = $true; Reason = 'storm guard disabled'; Paused = $false }
    }

    if (Test-ARPaused) {
        return [pscustomobject]@{ Allowed = $false; Reason = 'processing is paused (storm guard); resume from the web app'; Paused = $true }
    }

    $cap = switch ($Trigger) {
        'inactive' { [int]$safety.dailyCapInactive }
        'disable'  { [int]$safety.dailyCapDisable }
        default    { [int]$safety.dailyCapDelete }
    }
    $ceiling = [int]$safety.percentCeiling
    $count   = Get-ARSafetyCount -Trigger $Trigger
    $wouldBe = $count + 1

    $trip = $null
    if ($cap -gt 0 -and $wouldBe -gt $cap) {
        $trip = "daily cap for '$Trigger' reached ($cap). $count action(s) already taken today; refusing further to avoid a mass action."
    }
    else {
        # Percent ceiling: only a backstop for large tenants. Ignored for tiny
        # action counts so it never nuisance-trips a small directory.
        $dir = Get-ARDirectorySize
        if ($ceiling -gt 0 -and $dir -gt 0 -and $wouldBe -ge 10) {
            $pct = ($wouldBe / [double]$dir) * 100.0
            if ($pct -gt $ceiling) {
                $trip = "percent ceiling for '$Trigger' reached (>$ceiling% of $dir users). $count action(s) today; refusing further to avoid a mass action."
            }
        }
    }

    if ($trip) {
        Set-ARPaused -Reason $trip -Trigger $Trigger
        return [pscustomobject]@{ Allowed = $false; Reason = $trip; Paused = $true }
    }

    [void](Add-ARSafetyCount -Trigger $Trigger)
    return [pscustomobject]@{ Allowed = $true; Reason = ''; Paused = $false }
}

function Get-ARSafetyStatus {
    <#
    .SYNOPSIS
        Snapshot for the Diagnostics/StatusApi: paused state + today's counters.
    #>
    [CmdletBinding()] param($FeatureConfig)
    if (-not $FeatureConfig) { $FeatureConfig = Get-ARFeatureConfig }
    $paused = Get-ARPausedEntity
    $today = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd')
    return [pscustomobject]@{
        paused       = [bool]($paused -and "$($paused.Paused)".ToLowerInvariant() -eq 'true')
        pausedReason = if ($paused) { $paused.Reason } else { $null }
        pausedSince  = if ($paused) { $paused.Utc } else { $null }
        counts       = [ordered]@{
            inactive = Get-ARSafetyCount -Trigger 'inactive' -Date $today
            disable  = Get-ARSafetyCount -Trigger 'disable'  -Date $today
            delete   = Get-ARSafetyCount -Trigger 'delete'   -Date $today
        }
        caps         = [ordered]@{
            inactive = [int]$FeatureConfig.safety.dailyCapInactive
            disable  = [int]$FeatureConfig.safety.dailyCapDisable
            delete   = [int]$FeatureConfig.safety.dailyCapDelete
        }
        directorySize = Get-ARDirectorySize
    }
}
