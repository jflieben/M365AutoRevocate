# Daily health watchdog (06:00 UTC). Emails the service desk when a worker is
# failing, the subscription is missing/expired, the snapshot is stale, the
# poison queue is non-empty, or processing is paused. Silent when healthy.

param($Timer)

Initialize-ARTables

Invoke-ARFunctionRun -Name 'Watchdog' -Script {
    Invoke-ARWatchdog
}
