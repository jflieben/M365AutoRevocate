# Reconciliation sweep.
#
# Graph only retries an undelivered change notification for a limited window, so
# an outage, a subscription gap, or a self-heal flap can drop a deletion or
# disable PERMANENTLY. For a destructive-by-omission tool ("we failed to unshare
# a departed user's OneDrive") that is not acceptable. This daily sweep compares
# the directory's actual state against what we have processed and enqueues
# anything missed -- turning the whole notification pipeline into a fast path
# backed by a reliable reconciler.

function Invoke-ARReconciliationSweep {
    [CmdletBinding()] param()
    if (Test-ARPaused) { Write-Host 'Storm guard is paused; skipping the reconciliation sweep.'; return }

    $features = Get-ARFeatureConfig
    $tables = Get-ARTableNames
    $anyDelete  = Test-ARAnyFeatureEnabled -FeatureConfig $features -Trigger 'delete'
    $anyDisable = Test-ARAnyFeatureEnabled -FeatureConfig $features -Trigger 'disable'
    if (-not $anyDelete -and -not $anyDisable) {
        Write-Host 'Reconciliation sweep: no delete/disable features enabled; nothing to reconcile.'
        return
    }

    $deleteCandidates  = [System.Collections.Generic.List[string]]::new()
    $disableCandidates = [System.Collections.Generic.List[string]]::new()

    # 1) Soft-deleted users in the recycle bin not yet processed at 'delete'
    #    (and not already queued for hard-delete).
    if ($anyDelete) {
        $processed = @{}
        foreach ($e in (Get-ARTableEntities -Table $tables.Processed -Filter "PartitionKey eq 'delete'")) { $processed[$e.RowKey] = $true }
        foreach ($p in (Get-ARTableEntities -Table $tables.Pending)) { $processed[$p.RowKey] = $true }
        try {
            $deleted = Invoke-ARGraph -Uri '/directory/deletedItems/microsoft.graph.user?$select=id&$top=100' -All
            foreach ($d in $deleted) { if ($d.id -and -not $processed.ContainsKey($d.id)) { $deleteCandidates.Add($d.id) } }
        }
        catch { Write-Warning "Reconcile: could not enumerate deleted users: $($_.Exception.Message)" }
    }

    # 2) Currently-disabled accounts not yet processed at 'disable', minus the
    #    globally-excluded ones (exclusion group + shared/room/equipment
    #    mailboxes). Fails CLOSED like the scan: if the exclusions can't be built
    #    we skip the disable sweep this run rather than risk enqueuing a protected
    #    account (the account still exists, so a later run recovers it).
    if ($anyDisable) {
        $excluded = @{}
        $exclOk = $true
        try { $excluded = Get-ARExclusionObjectIds -FeatureConfig $features }
        catch { $exclOk = $false; Write-Warning "Reconcile: skipping the disable sweep this run -- exclusions could not be built (protected accounts could not be shielded): $($_.Exception.Message)" }
        if ($exclOk) {
            $processed = @{}
            foreach ($e in (Get-ARTableEntities -Table $tables.Processed -Filter "PartitionKey eq 'disable'")) { $processed[$e.RowKey] = $true }
            try {
                $disabled = Invoke-ARGraph -Uri '/users?$filter=accountEnabled eq false&$select=id&$top=999' -All
                foreach ($u in $disabled) {
                    if ($u.id -and -not $processed.ContainsKey($u.id) -and -not $excluded.ContainsKey($u.id)) { $disableCandidates.Add($u.id) }
                }
            }
            catch { Write-Warning "Reconcile: could not enumerate disabled users: $($_.Exception.Message)" }
        }
    }

    # Source-side storm guard: a first-ever sweep (or a long outage) can surface a
    # huge backlog. Rather than flood the queue, pause and let an admin review.
    $capDelete  = [int]$features.safety.dailyCapDelete
    $capDisable = [int]$features.safety.dailyCapDisable
    if ($features.safety.enabled) {
        if ($capDelete -gt 0 -and $deleteCandidates.Count -gt $capDelete) {
            $reason = "Reconciliation found $($deleteCandidates.Count) unprocessed deleted user(s), above the delete cap of $capDelete. Paused for review."
            Set-ARPaused -Reason $reason -Trigger 'delete'; Write-Host $reason; return
        }
        if ($capDisable -gt 0 -and $disableCandidates.Count -gt $capDisable) {
            $reason = "Reconciliation found $($disableCandidates.Count) unprocessed disabled user(s), above the disable cap of $capDisable. Paused for review."
            Set-ARPaused -Reason $reason -Trigger 'disable'; Write-Host $reason; return
        }
    }

    $enqueued = 0
    foreach ($id in $deleteCandidates)  { Send-ARQueueMessage -Content (@{ userId = $id; changeType = 'deleted' } | ConvertTo-Json -Compress); $enqueued++ }
    foreach ($id in $disableCandidates) { Send-ARQueueMessage -Content (@{ userId = $id; changeType = 'updated' } | ConvertTo-Json -Compress); $enqueued++ }

    Write-Host "Reconciliation sweep: enqueued $enqueued missed user(s) ($($deleteCandidates.Count) delete, $($disableCandidates.Count) disable)."
    if ($enqueued -gt 0) { Write-ARSystemActivity -EventName "Reconciliation sweep enqueued $enqueued missed user(s)" -Detail "delete=$($deleteCandidates.Count) disable=$($disableCandidates.Count)" }
}
