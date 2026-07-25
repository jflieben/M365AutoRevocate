# Queue writes over REST with the managed identity.
#
# The NotificationHandler used a host-managed queue OUTPUT binding, but a
# binding failure happens at host level: the function body never runs, nothing
# is logged, and the failure is invisible from the app's own diagnostics. So we
# write queue messages ourselves, exactly like the table/blob layers, and keep
# only the queue TRIGGER host-managed (the host demonstrably talks to storage
# already: timers and leases use the same identity connection).
#
# NB: the Functions queue trigger expects Base64-encoded message bodies by
# default, so MessageText must carry base64(content).

function New-ARQueue {
    <#
    .SYNOPSIS
        Ensures a queue exists. Safe to call repeatedly (409 = already there).
    #>
    [CmdletBinding()] param([string]$Name)
    $cfg = Get-ARConfig
    if (-not $Name) { $Name = $cfg.RevocationQueue }
    $r = Invoke-RestMethod -Method Put -Uri ('{0}/{1}' -f $cfg.QueueEndpoint, $Name) -Headers @{
        Authorization  = "Bearer $(Get-ARStorageToken)"
        'x-ms-version' = '2019-12-12'
    } -SkipHttpErrorCheck -StatusCodeVariable statusCode -ErrorAction Stop
    if ($statusCode -ge 400 -and $statusCode -ne 409) {
        throw "Creating queue '$Name' failed with HTTP $statusCode`: $($r | Out-String)"
    }
}

function Get-ARQueueDepth {
    <#
    .SYNOPSIS
        Approximate message count for a queue (-1 if it does not exist / errors).
        Used to surface the poison queue on the Diagnostics tab.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-ARConfig
    $uri = '{0}/{1}?comp=metadata' -f $cfg.QueueEndpoint, $Name
    try {
        $null = Invoke-RestMethod -Method Get -Uri $uri -Headers @{
            Authorization  = "Bearer $(Get-ARStorageToken)"
            'x-ms-version' = '2019-12-12'
        } -SkipHttpErrorCheck -StatusCodeVariable sc -ResponseHeadersVariable rh -ErrorAction Stop
        if ($sc -ge 400) { return -1 }
        $c = if ($rh -and $rh['x-ms-approximate-messages-count']) { $rh['x-ms-approximate-messages-count'] | Select-Object -First 1 } else { '0' }
        $n = 0; [void][int]::TryParse("$c", [ref]$n); return $n
    }
    catch { return -1 }
}

function Send-ARQueueMessage {
    <#
    .SYNOPSIS
        Posts one message to a queue (creating the queue on first use). Throws
        on failure so callers can surface it -- a silently lost message here
        means a user cleanup silently not happening.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [string]$QueueName,
        # Delay before the message becomes visible to the trigger. Used to hold
        # work while the storm guard is paused without losing it.
        [int]$VisibilityTimeoutSeconds = 0
    )
    $cfg = Get-ARConfig
    if (-not $QueueName) { $QueueName = $cfg.RevocationQueue }

    $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content))
    $body = "<QueueMessage><MessageText>$base64</MessageText></QueueMessage>"
    $uri = '{0}/{1}/messages' -f $cfg.QueueEndpoint, $QueueName
    if ($VisibilityTimeoutSeconds -gt 0) {
        # Cap at the Azure Queue maximum (7 days) minus a margin.
        $vis = [Math]::Min($VisibilityTimeoutSeconds, 604000)
        $uri += "?visibilitytimeout=$vis"
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $headers = @{
            Authorization  = "Bearer $(Get-ARStorageToken)"
            'x-ms-version' = '2019-12-12'
            'Content-Type' = 'application/xml'
        }
        $r = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -SkipHttpErrorCheck -StatusCodeVariable statusCode -ErrorAction Stop
        if ($statusCode -lt 400) { return }
        if ($statusCode -eq 404 -and $attempt -eq 1) {
            # Queue does not exist yet: create it and retry once.
            New-ARQueue -Name $QueueName
            continue
        }
        throw "Posting to queue '$QueueName' failed with HTTP $statusCode`: $($r | Out-String)"
    }
}
