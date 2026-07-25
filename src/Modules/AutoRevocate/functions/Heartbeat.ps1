# Function heartbeats.
#
# Every worker function records its last run, status, duration and (on failure)
# the error into the FunctionHeartbeats table. The admin web app's Diagnostics
# tab reads this, so an operator can see at a glance whether the timers and
# processors are healthy without opening Application Insights.

function Write-ARHeartbeat {
    <#
    .SYNOPSIS
        Records a run result for a function. Never throws -- diagnostics must
        not break the function being diagnosed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('ok', 'error')][string]$Status,
        [long]$DurationMs = 0,
        [string]$ErrorMessage
    )
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    $props = @{
        LastRunUtc     = $now
        LastStatus     = $Status
        LastDurationMs = [string]$DurationMs
    }
    if ($Status -eq 'ok') { $props.LastSuccessUtc = $now }
    else { $props.LastError = "$ErrorMessage"; $props.LastErrorUtc = $now }

    try {
        $tables = Get-ARTableNames
        # MERGE preserves LastSuccessUtc when writing an error and vice versa.
        Merge-ARTableEntity -Table $tables.Heartbeats -PartitionKey 'fn' -RowKey $Name -Properties $props
    }
    catch { Write-Warning "Could not write heartbeat for ${Name}: $($_.Exception.Message)" }
}

$script:ARHeartbeatLast = @{}

function Write-ARHeartbeatSampled {
    <#
    .SYNOPSIS
        Like Write-ARHeartbeat but rate-limited per worker: a healthy heartbeat
        writes at most once per interval. For high-volume HTTP functions (the
        NotificationHandler firehose) this avoids a table write on every POST.
        Errors are never sampled -- they always write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('ok', 'error')][string]$Status = 'ok',
        [int]$MinIntervalSeconds = 30,
        [string]$ErrorMessage
    )
    if ($Status -eq 'ok') {
        $last = $script:ARHeartbeatLast[$Name]
        if ($last -and ([DateTimeOffset]::UtcNow - $last).TotalSeconds -lt $MinIntervalSeconds) { return }
        $script:ARHeartbeatLast[$Name] = [DateTimeOffset]::UtcNow
    }
    Write-ARHeartbeat -Name $Name -Status $Status -ErrorMessage $ErrorMessage
}

function Invoke-ARFunctionRun {
    <#
    .SYNOPSIS
        Runs a function body and records a heartbeat with the outcome. Failures
        are rethrown so the Functions runtime still registers them (retries,
        poison queue, App Insights).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "${Name}: run starting."
    try {
        & $Script
        Write-ARHeartbeat -Name $Name -Status ok -DurationMs $sw.ElapsedMilliseconds
        Write-Host "${Name}: run finished ok in $($sw.ElapsedMilliseconds)ms."
    }
    catch {
        Write-ARHeartbeat -Name $Name -Status error -DurationMs $sw.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
        Write-Host "${Name}: run FAILED after $($sw.ElapsedMilliseconds)ms: $($_.Exception.Message)"
        throw
    }
}

function Get-ARHeartbeats {
    [CmdletBinding()] param()
    $tables = Get-ARTableNames
    return @(Get-ARTableEntities -Table $tables.Heartbeats -Filter "PartitionKey eq 'fn'")
}
