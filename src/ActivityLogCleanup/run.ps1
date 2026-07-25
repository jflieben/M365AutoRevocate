# Weekly maintenance (Sunday 03:45 UTC):
#   * activity-log retention: delete ActivityLog rows older than the configurable
#     logRetentionDays (Configuration tab; default 365, clamped 7..3650).
#   * snapshot prune: retire DirectorySnapshot rows for users deleted well past
#     the hard-delete window, so the table (and the personal data it holds) does
#     not grow forever.

param($Timer)

Initialize-ARTables

Invoke-ARFunctionRun -Name 'ActivityLogCleanup' -Script {
    $features = Get-ARFeatureConfig
    $days = [int]$features.logRetentionDays
    if ($days -le 0) { $days = 365 }
    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-$days).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $tables = Get-ARTableNames

    # Timestamp is the system property, so this needs no schema of its own. The
    # activity log lives in a single partition ('log'), so expired rows can be
    # removed in entity-group transactions (100 at a time) instead of one-by-one.
    $old = @(Get-ARTableEntities -Table $tables.Activity -Filter "PartitionKey eq 'log' and Timestamp lt datetime'$cutoff'")
    Write-Host "ActivityLogCleanup: retention $days day(s); $($old.Count) entries older than $cutoff."
    $deleted = 0
    if ($old.Count -gt 0) {
        $deleted = Invoke-ARTableBatchDelete -Table $tables.Activity -PartitionKey 'log' -RowKeys @($old | ForEach-Object { $_.RowKey })
        Write-Host "ActivityLogCleanup: deleted $deleted of $($old.Count) expired entries."
        Write-ARSystemActivity -EventName "Activity log cleanup: removed $deleted entries older than $days days"
    }

    # Snapshot prune (retire long-deleted users' cached rows).
    try { $pruned = Invoke-ARSnapshotPrune -RetainDays 60; if ($pruned -gt 0) { Write-ARSystemActivity -EventName "Directory snapshot prune: removed $pruned long-deleted user row(s)" } }
    catch { Write-Warning "Snapshot prune failed: $($_.Exception.Message)" }
}
