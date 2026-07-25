# Additional offboarding actions that operate on a still-live account, so they
# only make sense at the "disable" trigger (the catalog marks them disable-only).
# All are Graph REST -- no Exchange Online module at runtime.
#
# Each honours Config.DryRun and returns a small summary for the audit record.

function Invoke-ARRevokeSessions {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    $cfg = Get-ARConfig
    if ($cfg.DryRun) { Write-Host "[DryRun] Would revoke sign-in sessions for $UserId."; return [pscustomobject]@{ Revoked = $false; DryRun = $true } }
    try {
        $null = Invoke-ARGraph -Method Post -Uri ('/users/' + $UserId + '/revokeSignInSessions')
        Write-Host "Revoked sign-in sessions for $UserId."
        return [pscustomobject]@{ Revoked = $true }
    }
    catch { Write-Warning "revokeSignInSessions failed for $UserId`: $($_.Exception.Message)"; return [pscustomobject]@{ Revoked = $false; Error = $_.Exception.Message } }
}

function Set-ARAutoReply {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId, [string]$Message)
    $cfg = Get-ARConfig
    if ([string]::IsNullOrWhiteSpace($Message)) { $Message = 'This person has left the organisation and this mailbox is no longer monitored.' }
    if ($cfg.DryRun) { Write-Host "[DryRun] Would set auto-reply for $UserId."; return [pscustomobject]@{ Set = $false; DryRun = $true } }
    $body = @{
        automaticRepliesSetting = @{
            status               = 'alwaysEnabled'
            externalAudience     = 'all'
            internalReplyMessage = $Message
            externalReplyMessage = $Message
        }
    }
    try {
        $null = Invoke-ARGraph -Method Patch -Uri ('/users/' + $UserId + '/mailboxSettings') -Body $body
        Write-Host "Set auto-reply for $UserId."
        return [pscustomobject]@{ Set = $true }
    }
    catch { Write-Warning "Setting auto-reply failed for $UserId`: $($_.Exception.Message)"; return [pscustomobject]@{ Set = $false; Error = $_.Exception.Message } }
}

function Set-ARMailboxForward {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId, [string]$Address)
    $cfg = Get-ARConfig
    if ([string]::IsNullOrWhiteSpace($Address)) {
        Write-Host "Forward feature enabled but no forward-to address configured for $UserId; skipping."
        return [pscustomobject]@{ RuleCreated = $false; Reason = 'no address configured' }
    }
    if ($cfg.DryRun) { Write-Host "[DryRun] Would forward $UserId's mail to $Address."; return [pscustomobject]@{ RuleCreated = $false; DryRun = $true; Address = $Address } }
    $body = @{
        displayName = 'M365AutoRevocate forward'
        sequence    = 1
        isEnabled   = $true
        conditions  = @{}
        actions     = @{
            forwardTo           = @(@{ emailAddress = @{ address = $Address } })
            stopProcessingRules = $false
        }
    }
    try {
        $null = Invoke-ARGraph -Method Post -Uri ('/users/' + $UserId + '/mailFolders/inbox/messageRules') -Body $body
        Write-Host "Created forwarding rule for $UserId -> $Address."
        return [pscustomobject]@{ RuleCreated = $true; Address = $Address }
    }
    catch { Write-Warning "Creating forward rule failed for $UserId`: $($_.Exception.Message)"; return [pscustomobject]@{ RuleCreated = $false; Error = $_.Exception.Message } }
}

function Invoke-ARCancelOrganisedMeetings {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId, [string]$Comment)
    $cfg = Get-ARConfig
    if ([string]::IsNullOrWhiteSpace($Comment)) { $Comment = 'This meeting is cancelled because the organiser has left the organisation.' }
    $summary = [pscustomobject]@{ Scanned = 0; Cancelled = 0; Errors = 0; DryRun = [bool]$cfg.DryRun }

    # Use calendarView (which EXPANDS recurrences) over a forward window rather
    # than a $filter on events.start. A recurring series created in the past has
    # a start in the past, so a start-ge-now filter would miss it while its
    # future occurrences keep firing. From an expanded occurrence we cancel the
    # whole SERIES via its seriesMasterId (once), and single events by their id.
    $start = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $end   = [DateTimeOffset]::UtcNow.AddMonths(12).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $uri = '/users/' + $UserId + '/calendarView?startDateTime=' + $start + '&endDateTime=' + $end +
        '&$select=id,subject,isOrganizer,type,seriesMasterId&$top=100'
    $events = @()
    try { $events = Invoke-ARGraph -Uri $uri -All }
    catch { Write-Warning "Listing calendar view failed for $UserId`: $($_.Exception.Message)"; $summary.Errors++; return $summary }

    # Collect distinct cancellation targets (series master once, single events once).
    $targets = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($ev in $events) {
        if ($summary.Scanned -ge 2000) { break }   # safety cap on expansion
        $summary.Scanned++
        if (-not $ev.isOrganizer) { continue }
        $target = if ($ev.seriesMasterId) { $ev.seriesMasterId } else { $ev.id }
        if ($target) { [void]$targets.Add($target) }
    }

    foreach ($id in $targets) {
        if ($cfg.DryRun) { $summary.Cancelled++; continue }
        try {
            $null = Invoke-ARGraph -Method Post -Uri ('/users/' + $UserId + '/events/' + $id + '/cancel') -Body @{ comment = $Comment }
            $summary.Cancelled++
        }
        catch { Write-Warning "Cancelling event $id failed: $($_.Exception.Message)"; $summary.Errors++ }
    }
    Write-Host "Meeting cancellation for ${UserId}: scanned=$($summary.Scanned) series/events cancelled=$($summary.Cancelled) errors=$($summary.Errors)."
    return $summary
}
