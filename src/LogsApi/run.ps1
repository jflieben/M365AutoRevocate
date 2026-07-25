using namespace System.Net

# Admin API: paged activity-log entries for the web app. Protected by Easy Auth
# (see ConfigApi). ActivityLog RowKeys are inverted ticks, so ascending order ==
# newest first and a page-by-page walk streams the log newest to oldest.
#
# Query parameters:
#   top     - page size (default 50, max 200)
#   trigger - server-side filter: delete | disable | inactive | system
#   ct      - continuation token from the previous response's nextCt

param($Request, $TriggerMetadata)

$top = 50
if ($Request.Query -and $Request.Query['top']) { [void][int]::TryParse($Request.Query['top'], [ref]$top) }
if ($top -le 0 -or $top -gt 200) { $top = 50 }

$trigger = ''
if ($Request.Query -and $Request.Query['trigger']) { $trigger = "$($Request.Query['trigger'])".ToLowerInvariant() }
if ($trigger -notin @('delete', 'disable', 'inactive', 'system')) { $trigger = '' }

$nextPk = ''; $nextRk = ''
if ($Request.Query -and $Request.Query['ct']) {
    $ctParts = "$($Request.Query['ct'])" -split '\|', 2
    $nextPk = $ctParts[0]
    if ($ctParts.Count -gt 1) { $nextRk = $ctParts[1] }
}

try {
    $auth = Test-ARAdminRequest -Request $Request
    if (-not $auth.Ok) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]$auth.Status
                Headers    = @{ 'Content-Type' = 'application/json' }
                Body       = (@{ error = $auth.Error } | ConvertTo-Json)
            })
        return
    }

    Initialize-ARTables   # inside try so storage errors surface in the response
    $tables = Get-ARTableNames

    $filter = "PartitionKey eq 'log'"
    if ($trigger) { $filter += " and Trigger eq '$trigger'" }

    $page = Get-ARTablePage -Table $tables.Activity -Filter $filter -Top $top -NextPartitionKey $nextPk -NextRowKey $nextRk
    $items = foreach ($e in $page.Items) {
        [pscustomobject]@{
            timestamp   = $e.TimestampUtc
            userId      = $e.UserId
            upn         = $e.UserPrincipalName
            displayName = $e.DisplayName
            trigger     = $e.Trigger
            event       = $e.Event
            dryRun      = $e.DryRun
            summary     = $e.Summary
        }
    }
    $nextCt = if ($page.NextPartitionKey) { '{0}|{1}' -f $page.NextPartitionKey, $page.NextRowKey } else { '' }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = (@{ items = @($items); nextCt = $nextCt } | ConvertTo-Json -Depth 8)
        })
}
catch {
    Write-Error "LogsApi failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::InternalServerError
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = (@{ error = $_.Exception.Message } | ConvertTo-Json)
        })
}
