# Microsoft Graph change-notification subscription lifecycle.
#
# We subscribe to the '/users' resource with changeType 'updated,deleted'.
# Observed Graph behaviour for directory users:
#   * a SOFT delete (user moved to the recycle bin) raises an 'updated'
#     notification -- the object still exists, so RevocationProcessor detects it
#     by finding the user in the recycle bin (see RevocationProcessor).
#   * a 'deleted' notification is raised on PERMANENT deletion.
#   * an accountEnabled -> false change also arrives as 'updated' (disable).
# There is no separate notification we can rely on for the exact moment of
# permanent deletion timing, so hard mode defers and polls the recycle bin
# (see HardDeleteReconciler).
#
# Directory-resource subscriptions are short-lived, so SubscriptionManager runs
# on a timer and renews well ahead of expiry.

# Requested lifetime per (re)new. Kept comfortably under the Graph maximum for
# directory resources; the renewal timer runs far more often than this.
$script:ARSubscriptionMinutes = 1410   # ~23.5h

function Get-ARExistingSubscription {
    <#
    .SYNOPSIS
        Returns this app's existing subscription for the configured resource, or
        $null. GET /subscriptions only ever returns subscriptions owned by the
        calling application.
    #>
    [CmdletBinding()] param()
    $cfg    = Get-ARConfig
    $target = $cfg.SubscriptionResource.Trim('/')
    $subs   = Invoke-ARGraph -Uri '/subscriptions' -All
    return $subs |
        Where-Object { $_.resource.Trim('/') -ieq $target } |
        Select-Object -First 1
}

function Get-ARAllSubscriptions {
    [CmdletBinding()] param()
    $cfg    = Get-ARConfig
    $target = $cfg.SubscriptionResource.Trim('/')
    $subs   = Invoke-ARGraph -Uri '/subscriptions' -All
    return @($subs | Where-Object { $_.resource.Trim('/') -ieq $target })
}

function Remove-ARDuplicateSubscriptions {
    <#
    .SYNOPSIS
        Ensures there is at most one subscription for our resource. A race
        between the NotificationHandler self-heal and the SubscriptionManager
        timer can create a second one, which doubles every notification. Keep
        the one matching our record (else the latest expiry) and delete the
        rest. Returns the survivor (or $null).
    #>
    [CmdletBinding()] param()
    $all = @(Get-ARAllSubscriptions)
    if ($all.Count -le 1) { return ($all | Select-Object -First 1) }

    $record = Get-ARSubscriptionRecord
    $keep = $null
    if ($record) { $keep = $all | Where-Object { $_.id -eq $record.id } | Select-Object -First 1 }
    if (-not $keep) { $keep = $all | Sort-Object { [DateTimeOffset]::Parse($_.expirationDateTime) } -Descending | Select-Object -First 1 }

    foreach ($s in $all) {
        if ($s.id -eq $keep.id) { continue }
        Write-Warning "Removing duplicate subscription $($s.id) (keeping $($keep.id))."
        try { Invoke-ARGraph -Method Delete -Uri "/subscriptions/$($s.id)" } catch { Write-Warning "Could not delete duplicate subscription $($s.id): $($_.Exception.Message)" }
        Write-ARSystemActivity -EventName 'Removed duplicate Graph subscription' -Detail "deleted=$($s.id) kept=$($keep.id)"
    }
    return $keep
}

function New-ARSubscription {
    [CmdletBinding()] param([string]$ExpirationDateTime)
    $cfg  = Get-ARConfig
    $body = @{
        changeType         = $cfg.SubscriptionChangeType   # 'updated,deleted' -> disable + delete
        notificationUrl    = $cfg.NotificationUrl
        resource           = $cfg.SubscriptionResource
        expirationDateTime = $ExpirationDateTime
        clientState        = $cfg.ClientState
    }
    Write-Host "Creating Graph subscription for '$($cfg.SubscriptionResource)' (changeType=$($cfg.SubscriptionChangeType))."
    $sub = Invoke-ARGraph -Method Post -Uri '/subscriptions' -Body $body
    Save-ARSubscriptionRecord -Subscription $sub
    return $sub
}

# Graph's GET /subscriptions does not reliably return clientState, so a live
# subscription's clientState cannot be verified against ours by asking Graph.
# Instead we persist what we created the subscription WITH; comparing that
# record against the current config catches a rotated AR_CLIENT_STATE (the
# failure mode where every notification is silently dropped as unauthenticated).
$script:ARSubscriptionRecordBlob = 'subscription-state.json'

function Get-ARSubscriptionRecord {
    [CmdletBinding()] param()
    try {
        $text = Get-ARBlobText -Name $script:ARSubscriptionRecordBlob
        if ($text) { return $text | ConvertFrom-Json }
    }
    catch { Write-Warning "Could not read the subscription record: $($_.Exception.Message)" }
    return $null
}

function Save-ARSubscriptionRecord {
    [CmdletBinding()] param([Parameter(Mandatory)]$Subscription)
    $cfg = Get-ARConfig
    try {
        Set-ARBlobText -Name $script:ARSubscriptionRecordBlob -Content (@{
                id              = $Subscription.id
                clientState     = $cfg.ClientState
                notificationUrl = $cfg.NotificationUrl
                changeType      = $cfg.SubscriptionChangeType
                savedUtc        = [DateTimeOffset]::UtcNow.ToString('o')
            } | ConvertTo-Json)
    }
    catch { Write-Warning "Could not persist the subscription record: $($_.Exception.Message)" }
}

function Test-ARSelfHealAllowed {
    # Rate-limit the notification-path self-heal so a flood of forged mismatch
    # notifications cannot be used to repeatedly delete/recreate (flap) the
    # subscription and suppress events. One recreate per hour at most.
    [CmdletBinding()] param()
    $tables = Get-ARTableNames
    $e = Get-ARTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'lastSelfHeal'
    if ($e -and $e.PSObject.Properties['Utc']) {
        $last = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse("$($e.Utc)", [ref]$last) -and ([DateTimeOffset]::UtcNow - $last).TotalHours -lt 1) {
            return $false
        }
    }
    return $true
}

function Set-ARSelfHealed {
    [CmdletBinding()] param()
    $tables = Get-ARTableNames
    Set-ARTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'lastSelfHeal' -Properties @{ Utc = [DateTimeOffset]::UtcNow.ToString('o') }
}

function Invoke-ARConstrainedSelfHeal {
    <#
    .SYNOPSIS
        Recreate the subscription in response to a clientState-mismatch
        notification -- but ONLY for our own recorded subscription id, and at
        most once per hour. The mismatching notification failed authentication,
        so its subscriptionId is untrusted and must never drive a delete of an
        arbitrary id.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$SubscriptionId)
    $record = Get-ARSubscriptionRecord
    if (-not $record -or $record.id -ne $SubscriptionId) {
        Write-Warning "Self-heal skipped: subscriptionId '$SubscriptionId' does not match our recorded subscription; ignoring untrusted id. The SubscriptionManager timer will reconcile."
        return
    }
    if (-not (Test-ARSelfHealAllowed)) {
        Write-Warning 'Self-heal skipped: rate-limited (a recreate happened within the last hour). The SubscriptionManager timer will reconcile.'
        return
    }
    Set-ARSelfHealed
    try {
        try { Invoke-ARGraph -Method Delete -Uri "/subscriptions/$SubscriptionId" } catch { Write-Warning "Could not delete stale subscription $SubscriptionId`: $($_.Exception.Message)" }
        Update-ARSubscriptionState | Out-Null
        Write-Host 'NotificationHandler: recreated the Graph subscription with the current clientState.'
    }
    catch { Write-Warning "Subscription self-heal failed (the SubscriptionManager timer will retry): $($_.Exception.Message)" }
}

function Update-ARSubscriptionState {
    <#
    .SYNOPSIS
        Ensures exactly one healthy subscription exists and renews it.
    .DESCRIPTION
        Called by the SubscriptionManager timer. Creating a subscription makes
        Graph call our NotificationHandler with a validation token, so the HTTP
        endpoint must already be live (it is -- same Function App).
    #>
    [CmdletBinding()] param()
    $cfg        = Get-ARConfig
    if ([string]::IsNullOrWhiteSpace($cfg.NotificationUrl)) {
        Write-Host 'AR_NOTIFICATION_URL is not set yet (first boot before the deploy finished wiring it up); skipping subscription setup this run.'
        return $null
    }
    $expiration = [DateTimeOffset]::UtcNow.AddMinutes($script:ARSubscriptionMinutes).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    # Prune any duplicate subscriptions first (a race can create a second one,
    # doubling every notification) and use the survivor.
    $existing   = Remove-ARDuplicateSubscriptions

    if (-not $existing) {
        $sub = New-ARSubscription -ExpirationDateTime $expiration
        Write-ARSystemActivity -EventName 'Graph subscription created' -Detail "id=$($sub.id) changeType=$($sub.changeType) expires=$($sub.expirationDateTime)"
        return $sub
    }

    # Recreate if anything a PATCH renewal cannot alter is stale:
    #   * the public URL changed (e.g. function key rotated),
    #   * the change-type set changed (e.g. 'deleted' -> 'updated,deleted'),
    #   * the clientState no longer matches ours (then every notification would
    #     be dropped as unauthenticated). Graph's GET does not reliably return
    #     clientState, so this is checked against our persisted record of what
    #     the subscription was created with; no record at all also recreates,
    #     because an unverifiable subscription may be silently dropping events.
    $sameChangeTypes = (($existing.changeType -split ',' | ForEach-Object { $_.Trim() } | Sort-Object) -join ',') -eq
                       (($cfg.SubscriptionChangeType -split ',' | ForEach-Object { $_.Trim() } | Sort-Object) -join ',')
    $existingClientState = $existing.clientState
    $staleClientState = $existingClientState -and ($existingClientState -ne $cfg.ClientState)
    $record = Get-ARSubscriptionRecord
    $staleRecord = (-not $record) -or ($record.id -ne $existing.id) -or ($record.clientState -ne $cfg.ClientState)
    if ($existing.notificationUrl -ne $cfg.NotificationUrl -or -not $sameChangeTypes -or $staleClientState -or $staleRecord) {
        $reason = if ($staleClientState) { 'clientState mismatch (Graph)' }
                  elseif ($staleRecord -and -not $record) { 'clientState unverifiable (no record of this subscription)' }
                  elseif ($staleRecord) { 'clientState mismatch (stored record)' }
                  elseif (-not $sameChangeTypes) { 'changeType set changed' }
                  else { 'notification URL changed' }
        Write-Warning "Existing subscription $($existing.id) is stale ($reason); recreating."
        try { Invoke-ARGraph -Method Delete -Uri "/subscriptions/$($existing.id)" } catch { Write-Warning "Could not delete stale subscription: $($_.Exception.Message)" }
        $sub = New-ARSubscription -ExpirationDateTime $expiration
        Write-ARSystemActivity -EventName 'Graph subscription recreated' -Detail "reason=$reason id=$($sub.id)"
        return $sub
    }

    Write-Host "Renewing Graph subscription $($existing.id) until $expiration."
    $sub = Invoke-ARGraph -Method Patch -Uri "/subscriptions/$($existing.id)" -Body @{ expirationDateTime = $expiration }
    Write-ARSystemActivity -EventName 'Graph subscription renewed' -Detail "id=$($existing.id) until=$expiration"
    return $sub
}
