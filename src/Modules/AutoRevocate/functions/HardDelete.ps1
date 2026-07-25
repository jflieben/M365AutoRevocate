# Hard-delete handling.
#
# Graph has no "permanently deleted" change notification, so in hard mode we
# record the soft-delete, then a timer (HardDeleteReconciler) watches the
# directory recycle bin. Cleanup runs when the user leaves the bin (manually
# purged) or, at the latest, ONE DAY BEFORE the automatic 30-day purge -- so the
# actions always run while the object (and its OneDrive mapping) still resolves.
# Identity is captured up front because it is gone once the object is purged.

function Add-ARPendingHardDelete {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    $tables = Get-ARTableNames

    $du = $null
    try { $du = Get-ARDeletedUser -UserId $UserId } catch { Write-Warning "Could not read deleted user $UserId when queuing hard-delete: $($_.Exception.Message)" }

    $snapshot  = Get-ARDirectoryEntry -UserId $UserId
    $upn       = if ($du -and $du.userPrincipalName) { $du.userPrincipalName } elseif ($snapshot) { $snapshot.UserPrincipalName } else { '' }
    $display   = if ($du -and $du.displayName) { $du.displayName } elseif ($snapshot) { $snapshot.DisplayName } else { '' }
    $deletedDt = if ($du -and $du.deletedDateTime) { $du.deletedDateTime } else { [DateTimeOffset]::UtcNow.ToString('o') }

    Set-ARTableEntity -Table $tables.Pending -PartitionKey 'pending' -RowKey $UserId -Properties @{
        UserPrincipalName = $upn
        DisplayName       = $display
        DeletedDateTime   = $deletedDt
        FirstSeen         = [DateTimeOffset]::UtcNow.ToString('o')
        Attempts          = '0'
    }
    Write-Host "Recorded pending hard-delete for '$upn' ($UserId); awaiting permanent deletion."
}

function Convert-ARPendingToSoft {
    <#
    .SYNOPSIS
        Called when delete timing changes hard -> soft. Otherwise the pending
        rows would be stranded (the reconciler no-ops in soft mode and nothing
        else reads them). Re-queues each as a normal delete so it flows through
        the standard pipeline (and the storm guard), then clears the row.
    #>
    [CmdletBinding()] param()
    $tables = Get-ARTableNames
    $pending = @(Get-ARTableEntities -Table $tables.Pending)
    $n = 0
    foreach ($p in $pending) {
        Send-ARQueueMessage -Content (@{ userId = $p.RowKey; changeType = 'deleted' } | ConvertTo-Json -Compress)
        try { Remove-ARTableEntity -Table $tables.Pending -PartitionKey 'pending' -RowKey $p.RowKey } catch { Write-Warning "Could not clear pending row $($p.RowKey): $($_.Exception.Message)" }
        $n++
    }
    if ($n -gt 0) { Write-ARSystemActivity -EventName "Delete timing changed to soft: re-queued $n pending hard-delete(s) for processing" }
    return $n
}

function Invoke-ARHardDeleteReconcile {
    <#
    .SYNOPSIS
        Runs the pending hard-deletes and acts on any that have been permanently
        deleted (or exceeded the configured maximum wait).
    #>
    [CmdletBinding()] param()
    $cfg      = Get-ARConfig
    $features = Get-ARFeatureConfig
    if (Test-ARPaused) { Write-Host 'Storm guard is paused; skipping hard-delete reconciliation (pending rows are kept).'; return }
    # Entra keeps soft-deleted users for 30 days, then purges automatically. We
    # act one day before that purge at the latest, so cleanup never races the
    # object's disappearance.
    $actAfterDays = 29
    $tables   = Get-ARTableNames
    $pending  = Get-ARTableEntities -Table $tables.Pending
    Write-Host "HardDeleteReconciler: $($pending.Count) pending user(s)."

    foreach ($p in $pending) {
        $userId = $p.RowKey
        $du = $null
        try { $du = Get-ARDeletedUser -UserId $userId }
        catch { Write-Warning "Recycle-bin check failed for $userId; will retry next run: $($_.Exception.Message)"; continue }

        $purged      = ($null -eq $du)
        $waitElapsed = $false
        if ($p.DeletedDateTime) {
            $deletedDt = [DateTimeOffset]::Parse($p.DeletedDateTime)
            if (([DateTimeOffset]::UtcNow - $deletedDt).TotalDays -ge $actAfterDays) { $waitElapsed = $true }
        }

        if ($purged -or $waitElapsed) {
            $reason = if ($purged) { 'permanently deleted' } else { 'one day before automatic purge' }
            Write-Host "Hard-delete triggered for '$($p.UserPrincipalName)' ($userId): $reason."

            $snapshot = Get-ARDirectoryEntry -UserId $userId
            if (-not $snapshot) {
                $snapshot = [pscustomobject]@{ UserPrincipalName = $p.UserPrincipalName; DisplayName = $p.DisplayName }
            }
            $r = Invoke-ARRevocation -UserId $userId -Trigger 'delete' -DeleteTiming 'hard' -Snapshot $snapshot -FeatureConfig $features

            # Keep the pending row if the storm guard blocked this cleanup, so a
            # later run (after resume) still completes it. It also stops the loop
            # here since the tool is now paused.
            if ($r -and $r.PSObject.Properties['Blocked'] -and $r.Blocked) {
                Write-Warning "HardDeleteReconciler: paused by storm guard while processing $userId; stopping. Pending rows are kept."
                break
            }
            if (-not $cfg.DryRun) {
                Remove-ARTableEntity -Table $tables.Pending -PartitionKey 'pending' -RowKey $userId
            }
        }
        else {
            $attempts = 0; [void][int]::TryParse($p.Attempts, [ref]$attempts)
            Set-ARTableEntity -Table $tables.Pending -PartitionKey 'pending' -RowKey $userId -Properties @{
                UserPrincipalName = $p.UserPrincipalName
                DisplayName       = $p.DisplayName
                DeletedDateTime   = $p.DeletedDateTime
                FirstSeen         = $p.FirstSeen
                Attempts          = [string]($attempts + 1)
            }
        }
    }
}
