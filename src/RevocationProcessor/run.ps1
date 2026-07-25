# Processes one change-notification message from the 'revocations' queue.
#
#   changeType 'deleted'  -> delete trigger. Soft mode: act now. Hard mode:
#                            record as pending for HardDeleteReconciler.
#   changeType 'updated'  -> potential disable. If the account is now disabled
#                            and disable-features are configured, act.
#   changeType 'inactive' -> the daily scanner flagged this user; run the
#                            inactive-trigger actions.
#
# Throwing lets the queue retry (and eventually poison) on transient failures.

param($QueueItem, $TriggerMetadata)

Initialize-ARTables

Invoke-ARFunctionRun -Name 'RevocationProcessor' -Script {
    $rawPreview = if ($QueueItem -is [string]) { $QueueItem } else { $QueueItem | ConvertTo-Json -Compress -Depth 5 }
    Write-Host "RevocationProcessor: dequeued message (attempt $($TriggerMetadata.DequeueCount)): $rawPreview"

    $msg = if ($QueueItem -is [string]) {
        try { $QueueItem | ConvertFrom-Json } catch { [pscustomobject]@{ userId = $QueueItem; changeType = 'deleted' } }
    }
    else { $QueueItem }

    $userId = $msg.userId
    if (-not $userId) { Write-Warning 'Queue message had no userId; ignoring.'; return }
    $changeType = if ($msg.changeType) { $msg.changeType } else { 'deleted' }

    # Circuit breaker: if the tool is paused, do NOT process. Re-queue this work
    # (as a fresh, delayed message so it survives and its dequeue count resets)
    # and return, so the current message completes cleanly.
    if (Test-ARPaused) {
        Write-Warning "RevocationProcessor: paused by storm guard; re-queuing $changeType for $userId (1h delay) instead of processing."
        Send-ARQueueMessage -Content (@{ userId = $userId; changeType = $changeType } | ConvertTo-Json -Compress) -VisibilityTimeoutSeconds 3600
        return
    }

    $features = Get-ARFeatureConfig
    Write-Host "RevocationProcessor: user=$userId changeType=$changeType mode=$($features.mode)."

    # If an action just tripped the breaker, its result carries Blocked=true and
    # the claim was released; re-queue the message so it runs after a resume.
    function Test-ARBlockedResult {
        param($Result, [string]$UserId, [string]$ChangeType)
        if ($Result -and $Result.PSObject.Properties['Blocked'] -and $Result.Blocked) {
            Write-Warning "RevocationProcessor: action for $UserId was blocked by the storm guard; re-queuing (1h delay)."
            Send-ARQueueMessage -Content (@{ userId = $UserId; changeType = $ChangeType } | ConvertTo-Json -Compress) -VisibilityTimeoutSeconds 3600
            return $true
        }
        return $false
    }

    function Invoke-DeleteTrigger {
        param([string]$UserId, $Features, $DeletedUser, [string]$ChangeType)
        if (-not (Test-ARAnyFeatureEnabled -FeatureConfig $Features -Trigger 'delete')) {
            Write-Host 'RevocationProcessor: no delete-trigger features enabled; ignoring the deletion.'
            return
        }
        if ($Features.mode -eq 'hard') {
            Write-Host "RevocationProcessor: mode=hard; recording pending hard delete for $UserId (actions run at purge, or 29 days after deletion)."
            Add-ARPendingHardDelete -UserId $UserId
        }
        else {
            Write-Host "RevocationProcessor: mode=soft; running delete actions for $UserId now."
            $r = Invoke-ARRevocation -UserId $UserId -Trigger 'delete' -DeleteTiming 'soft' -DeletedUser $DeletedUser -FeatureConfig $Features
            [void](Test-ARBlockedResult -Result $r -UserId $UserId -ChangeType $ChangeType)
        }
    }

    # Scanner-driven inactive work: flagged by InactivityScanner, processed here
    # so the daily timer never blocks on slow per-user cleanup.
    if ($changeType -match 'inactive') {
        if (-not (Test-ARAnyFeatureEnabled -FeatureConfig $features -Trigger 'inactive')) {
            Write-Host 'RevocationProcessor: no inactive-trigger features enabled; ignoring.'
            return
        }
        $r = Invoke-ARRevocation -UserId $userId -Trigger 'inactive' -FeatureConfig $features
        [void](Test-ARBlockedResult -Result $r -UserId $userId -ChangeType 'inactive')
        return
    }

    if ($changeType -match 'deleted') {
        # A true 'deleted' notification: Graph only sends this on PERMANENT
        # deletion of directory resources (soft deletes arrive as 'updated').
        Invoke-DeleteTrigger -UserId $userId -Features $features -ChangeType $changeType
        return
    }

    if ($changeType -match 'updated') {
        # Fast skip: if neither the disable NOR the delete trigger has any
        # feature enabled, an 'updated' event can never do anything. Avoid the
        # per-event Graph call entirely (the high-volume firehose path). NB: a
        # soft delete also arrives as 'updated', so we must still process when
        # ANY delete feature is on, even if no disable feature is.
        $anyDisable = Test-ARAnyFeatureEnabled -FeatureConfig $features -Trigger 'disable'
        $anyDelete  = Test-ARAnyFeatureEnabled -FeatureConfig $features -Trigger 'delete'
        if (-not $anyDisable -and -not $anyDelete) {
            Write-Host 'RevocationProcessor: updated event but no disable/delete features enabled; skipping without a Graph call.'
            return
        }

        $enabled = $null; $goneFromLive = $false
        try {
            $u = Invoke-ARGraph -Uri ('/users/' + $userId + '?$select=id,accountEnabled') -Raw
            if ($u.StatusCode -eq 404) { $goneFromLive = $true }
            elseif ($u.StatusCode -lt 400) { $enabled = $u.Body.accountEnabled }
            else { Write-Warning "RevocationProcessor: accountEnabled check for $userId returned HTTP $($u.StatusCode); giving up."; return }
        }
        catch { Write-Warning "accountEnabled check failed for $userId`: $($_.Exception.Message)"; return }

        if ($goneFromLive) {
            # Graph quirk: a SOFT delete raises only an 'updated' notification
            # (the object still exists, in the recycle bin). The 'deleted'
            # changeType is reserved for permanent deletion, which is 30 days
            # away. So: updated + not live + in the recycle bin = soft delete.
            $deletedUser = $null
            try { $deletedUser = Get-ARDeletedUser -UserId $userId } catch { Write-Warning "Recycle-bin lookup failed for $userId`: $($_.Exception.Message)" }
            if ($deletedUser) {
                Write-Host "RevocationProcessor: user '$($deletedUser.userPrincipalName)' ($userId) is soft-deleted (found in the recycle bin); treating as the delete trigger."
                Invoke-DeleteTrigger -UserId $userId -Features $features -DeletedUser $deletedUser -ChangeType $changeType
            }
            else {
                Write-Host "RevocationProcessor: user $userId is gone from the live directory and not in the recycle bin (already purged); nothing to do."
            }
            return
        }

        Write-Host "RevocationProcessor: user $userId accountEnabled=$enabled."
        if ($enabled -eq $false) {
            if (-not $anyDisable) {
                Write-Host 'RevocationProcessor: account is disabled but no disable-trigger features are enabled; ignoring.'
                return
            }
            Write-Host "RevocationProcessor: account is disabled; running disable actions for $userId."
            $r = Invoke-ARRevocation -UserId $userId -Trigger 'disable' -FeatureConfig $features
            [void](Test-ARBlockedResult -Result $r -UserId $userId -ChangeType $changeType)
        }
        elseif ($enabled -eq $true) {
            # Re-enabled: forget the previous disable so a future disable re-triggers.
            Clear-ARProcessed -UserId $userId -Trigger 'disable'
        }
    }
}
