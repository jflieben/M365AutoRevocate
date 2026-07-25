# Inactive-user detection.
#
# A daily scan flags enabled accounts nobody has signed in to for the
# configured number of days and runs the "inactive" trigger actions on them.
#
#   * Activity source: signInActivity.lastSuccessfulSignInDateTime. When empty
#     (user never signed in, or the property predates collection) the account's
#     createdDateTime is used instead -- so brand-new accounts are never
#     flagged.
#   * Requires the AuditLog.Read.All app role AND an Entra ID P1 licence on the
#     tenant (signInActivity is a premium property).
#   * Members of the configured exclusion group are never flagged (break-glass
#     accounts, service accounts, shared mailboxes that must stay).
#   * Idempotent per user via ProcessedActions partition 'inactive'. If a
#     flagged user later becomes active again (only possible when the actions
#     left the account usable), the marker is cleared so a future lapse
#     re-triggers.

function Invoke-ARInactivityScan {
    [CmdletBinding()] param()
    $features = Get-ARFeatureConfig
    if (-not $features.inactive.enabled) {
        Write-Host 'Inactive-user monitoring is disabled; nothing to scan.'
        return
    }
    if (-not (Test-ARAnyFeatureEnabled -FeatureConfig $features -Trigger 'inactive')) {
        Write-Host 'Inactive monitoring is on but no inactive-trigger actions are enabled; nothing to do.'
        return
    }

    $threshold = [int]$features.inactive.thresholdDays
    if ($threshold -lt 7) { $threshold = 7 }
    $now = [DateTimeOffset]::UtcNow

    # Exclusion set (transitive, so nested groups work).
    #
    # SAFETY: when an exclusion group IS configured but cannot be read, we must
    # NOT continue -- the group exists precisely to shield break-glass and
    # service accounts from soft deletion. Scanning without it could delete the
    # very accounts it protects. So we abort the whole scan and let it retry on
    # the next run, rather than fail open.
    $excluded = @{}
    if ($features.inactive.exclusionGroupId) {
        try {
            foreach ($id in (Get-ARExclusionGroupMemberIds -FeatureConfig $features).Keys) { $excluded[$id] = $true }
            Write-Host "Inactivity exclusion group '$($features.inactive.exclusionGroupName)': $($excluded.Count) member(s)."
        }
        catch {
            $msg = "Aborting the inactivity scan: the exclusion group ($($features.inactive.exclusionGroupId)) could not be read, so protected accounts (break-glass / service) cannot be shielded. Will retry next run. Error: $($_.Exception.Message)"
            Write-ARSystemActivity -EventName 'Inactivity scan aborted (exclusion group unreadable)' -Detail $msg
            throw $msg
        }
    }

    # Shared / room / equipment mailboxes: routinely disabled or never signed in,
    # but must NEVER be offboarded. Their Entra object ids come from Exchange
    # (Graph has no mailbox-type property). Like the exclusion group this fails
    # CLOSED -- if the mailbox types can't be read we abort rather than risk
    # flagging a shared mailbox. Turn off 'exclude shared mailboxes' to bypass.
    if ($features.inactive.excludeSharedMailboxes) {
        try {
            $nonUser = Get-ARNonUserMailboxObjectIds
            foreach ($id in $nonUser.Keys) { $excluded[$id] = $true }
        }
        catch {
            $msg = "Aborting the inactivity scan: could not read Exchange mailbox types to exclude shared/room/equipment mailboxes. The managed identity needs the 'View-Only Recipients' Exchange role (a fresh grant can take ~30 min to propagate). Turn off 'exclude shared mailboxes' in Configuration to bypass. Error: $($_.Exception.Message)"
            Write-ARSystemActivity -EventName 'Inactivity scan aborted (Exchange mailbox-type read failed)' -Detail $msg
            throw $msg
        }
    }

    # Already-processed set: one partition query instead of a lookup per user.
    $tables = Get-ARTableNames
    $processed = @{}
    foreach ($e in (Get-ARTableEntities -Table $tables.Processed -Filter "PartitionKey eq 'inactive'")) {
        $processed[$e.RowKey] = $true
    }

    # NB: when $select includes signInActivity, Graph caps the page size at 120.
    $users = @()
    try {
        $users = Invoke-ARGraph -Uri '/users?$select=id,userPrincipalName,displayName,accountEnabled,createdDateTime,signInActivity&$top=120' -All
    }
    catch {
        Write-Warning "Could not read users with signInActivity. This requires the AuditLog.Read.All app role AND an Entra ID P1 licence: $($_.Exception.Message)"
        return
    }

    # Collect the users to flag; enqueue them for the RevocationProcessor rather
    # than acting inline, so the daily timer never blocks on slow per-user
    # cleanup (a single stuck OneDrive would otherwise time the whole scan out).
    $toFlag = [System.Collections.Generic.List[object]]::new()
    $cleared = 0
    foreach ($u in $users) {
        if ($u.accountEnabled -ne $true) { continue }       # disabled accounts have their own trigger
        if ($excluded.ContainsKey($u.id)) { continue }

        $sia = $u.PSObject.Properties['signInActivity'].Value
        $lastRaw = if ($sia) { $sia.PSObject.Properties['lastSuccessfulSignInDateTime'].Value } else { $null }
        if (-not $lastRaw) { $lastRaw = $u.createdDateTime }  # never signed in -> age by creation
        if (-not $lastRaw) { continue }

        $days = ($now - [DateTimeOffset]::Parse($lastRaw)).TotalDays
        if ($days -ge $threshold) {
            if (-not $processed.ContainsKey($u.id)) { $toFlag.Add($u) }
        }
        elseif ($processed.ContainsKey($u.id)) {
            # Active again: re-arm so a future period of inactivity re-triggers.
            Clear-ARProcessed -UserId $u.id -Trigger 'inactive'
            $cleared++
        }
    }

    # Storm guard at the SOURCE. A first-time enablement in an old tenant can
    # flag thousands of dormant accounts at once. Rather than enqueue a mass of
    # soft deletes, pause and force a human to review (raise the cap on purpose,
    # tighten the threshold, or widen the exclusion group), then resume.
    $cap = [int]$features.safety.dailyCapInactive
    if ($features.safety.enabled -and $cap -gt 0 -and $toFlag.Count -gt $cap) {
        $reason = "Inactivity scan flagged $($toFlag.Count) account(s), above the daily cap of $cap. Paused for review; nothing was actioned. Raise the cap deliberately, tighten the threshold, or widen the exclusion group, then resume from the web app."
        Set-ARPaused -Reason $reason -Trigger 'inactive'
        Write-Host $reason
        return
    }

    $flagged = 0
    foreach ($u in $toFlag) {
        Write-Host "User '$($u.userPrincipalName)' inactive (threshold $threshold day(s)); enqueuing inactive actions."
        Send-ARQueueMessage -Content (@{ userId = $u.id; changeType = 'inactive' } | ConvertTo-Json -Compress)
        $flagged++
    }
    Write-Host "Inactivity scan complete: $($users.Count) user(s) scanned, $flagged enqueued, $cleared re-armed."
}
