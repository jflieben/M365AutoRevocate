# Daily reconciliation sweep (05:15 UTC). Catches deletions/disables that were
# missed because a change notification was never delivered (outage, subscription
# gap). Enqueues any unprocessed user so the pipeline is a fast path backed by a
# reliable reconciler rather than a must-never-miss dependency.

param($Timer)

Initialize-ARTables

Invoke-ARFunctionRun -Name 'ReconciliationSweep' -Script {
    Invoke-ARReconciliationSweep
}
