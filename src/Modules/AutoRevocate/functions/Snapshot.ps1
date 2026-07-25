# Directory snapshot.
#
# When a user is deleted, Graph severs their relationships: /users/{id}/manager
# and /users/{id}/ownedObjects stop resolving and deletedItems will not expand
# them. So the only way to email "the manager" or list "artifacts still owned"
# after deletion is to have cached that context *before* deletion. This caches,
# for every user, their manager, profile, owned objects, and OneDrive id.
#
# SCALE: a naive "loop every user, 3 sequential Graph calls each" cannot finish
# in a large tenant within a function timeout. This implementation is:
#   * DELTA-based  -- /users/delta with a persisted token, so after the first
#     full pass each run only touches users that CHANGED.
#   * BATCHED      -- relationship look-ups go through Graph $batch (20/req),
#     cutting round-trips ~20x.
#   * CHECKPOINTED -- it runs to a time budget, persists where it got to, and
#     resumes on the next run, so a huge first pass spans several runs instead
#     of dying at the timeout with nothing saved.
# Removed (soft-deleted) users are NOT dropped -- their cached row is stamped
# with DeletedUtc and kept, because hard-delete cleanup needs it up to 29 days
# later. Pruning happens well after that window (see Invoke-ARSnapshotPrune).

$script:ARSnapshotStateBlob = 'snapshot-state.json'

function Get-ARSnapshotState {
    [CmdletBinding()] param()
    try {
        $text = Get-ARBlobText -Name $script:ARSnapshotStateBlob
        if ($text) { return $text | ConvertFrom-Json }
    }
    catch { Write-Warning "Could not read snapshot state: $($_.Exception.Message)" }
    return [pscustomobject]@{ deltaLink = ''; nextLink = ''; size = 0 }
}

function Set-ARSnapshotState {
    [CmdletBinding()] param([Parameter(Mandatory)]$State)
    Set-ARBlobText -Name $script:ARSnapshotStateBlob -Content ($State | ConvertTo-Json -Compress)
}

function Invoke-ARGraphBatch {
    <#
    .SYNOPSIS
        Runs up to N GET requests through Graph $batch (20 per HTTP call).
        Returns a hashtable of id -> response object ({ status; body; headers }).
        Individual sub-request failures are returned as-is, never thrown, so one
        bad user never aborts the pass.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][object[]]$Requests)
    $out = @{}
    for ($i = 0; $i -lt $Requests.Count; $i += 20) {
        $end = [Math]::Min($i + 19, $Requests.Count - 1)
        $chunk = $Requests[$i..$end]
        $body = @{ requests = @($chunk | ForEach-Object { @{ id = "$($_.id)"; method = 'GET'; url = $_.url } }) }
        try {
            $resp = Invoke-ARGraph -Method Post -Uri '/$batch' -Body $body
            foreach ($r in $resp.responses) { $out["$($r.id)"] = $r }
        }
        catch { Write-Warning "Graph `$batch chunk failed (users may be skipped this pass): $($_.Exception.Message)" }
    }
    return $out
}

function Update-ARSnapshotUsers {
    <#
    .SYNOPSIS
        Refreshes the cached rows for a set of live users, fetching
        manager/drive/ownedObjects in batches. Returns how many were written.
    #>
    [CmdletBinding()] param([object[]]$Users)
    if (-not $Users -or $Users.Count -eq 0) { return 0 }
    $tables = Get-ARTableNames

    $reqs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Users.Count; $i++) {
        $uid = $Users[$i].id
        $reqs.Add(@{ id = "m$i"; url = "/users/$uid/manager?`$select=id,userPrincipalName,mail,accountEnabled" })
        $reqs.Add(@{ id = "d$i"; url = "/users/$uid/drive?`$select=id,webUrl" })
        $reqs.Add(@{ id = "o$i"; url = "/users/$uid/ownedObjects?`$select=id,displayName&`$top=100" })
    }
    $resp = Invoke-ARGraphBatch -Requests $reqs

    $written = 0
    for ($i = 0; $i -lt $Users.Count; $i++) {
        $u = $Users[$i]
        $props = @{
            UserPrincipalName = $u.userPrincipalName
            DisplayName       = $u.displayName
            Department        = $u.department
            AccountEnabled    = [string]$u.accountEnabled
            SnapshotDateTime  = [DateTimeOffset]::UtcNow.ToString('o')
        }

        $m = $resp["m$i"]
        if ($m -and [int]$m.status -lt 400 -and $m.body.id) {
            $props.ManagerId    = $m.body.id
            $props.ManagerUpn   = $m.body.userPrincipalName
            $props.ManagerEmail = if ($m.body.mail) { $m.body.mail } else { $m.body.userPrincipalName }
        }

        $d = $resp["d$i"]
        if ($d -and [int]$d.status -lt 400 -and $d.body.id) {
            $props.DriveId     = $d.body.id
            $props.DriveWebUrl = $d.body.webUrl
        }

        $o = $resp["o$i"]
        if ($o -and [int]$o.status -lt 400 -and $o.body.value) {
            $ownedList = foreach ($obj in $o.body.value) {
                [pscustomobject]@{
                    id          = $obj.id
                    type        = ($obj.'@odata.type' -replace '#microsoft\.graph\.', '')
                    displayName = $obj.displayName
                    detail      = ''
                }
            }
            $ownedArr = @($ownedList)
            if ($ownedArr.Count -gt 0) {
                $json = ($ownedArr | ConvertTo-Json -Depth 5 -Compress)
                # Table string properties cap at 64KB. Keep the row writable by
                # truncating; record that we did so it's visible in the mail/log.
                if ($json.Length -gt 60000) {
                    $props.OwnedObjects   = (@($ownedArr | Select-Object -First 100) | ConvertTo-Json -Depth 5 -Compress)
                    $props.OwnedTruncated = 'true'
                }
                else { $props.OwnedObjects = $json }
                # If the owned page itself was capped, note more may exist.
                if ($o.body.'@odata.nextLink') { $props.OwnedTruncated = 'true' }
            }
        }

        try { Set-ARTableEntity -Table $tables.Directory -PartitionKey 'user' -RowKey $u.id -Properties $props; $written++ }
        catch { Write-Warning "Snapshot write failed for $($u.userPrincipalName): $($_.Exception.Message)" }
    }
    return $written
}

function Update-ARDirectorySnapshot {
    [CmdletBinding()] param([int]$TimeBudgetSeconds = 480)
    $tables = Get-ARTableNames
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $budgetMs = $TimeBudgetSeconds * 1000

    $state = Get-ARSnapshotState
    $size  = [int]$state.size
    # Resume mid-enumeration if we checkpointed; else continue from the delta
    # token; else start a fresh full enumeration.
    $pageUri = if ($state.nextLink) { $state.nextLink }
               elseif ($state.deltaLink) { $state.deltaLink }
               else { '/users/delta?$select=id,userPrincipalName,displayName,department,accountEnabled' }
    $fromScratch = -not ($state.nextLink -or $state.deltaLink)
    if ($fromScratch) { $size = 0; Write-Host 'Directory snapshot: starting a full delta enumeration (first run or reset).' }
    else { Write-Host 'Directory snapshot: incremental (delta).' }

    $totalWritten = 0; $totalRemoved = 0; $pages = 0
    while ($true) {
        if ($sw.ElapsedMilliseconds -gt $budgetMs) {
            Write-Host "Directory snapshot: time budget reached after $pages page(s); will resume next run."
            break
        }
        $page = Invoke-ARGraph -Uri $pageUri
        $pages++
        $users = @($page.value)

        $toRefresh = [System.Collections.Generic.List[object]]::new()
        $removed = [System.Collections.Generic.List[string]]::new()
        foreach ($u in $users) {
            if ($u.PSObject.Properties['@removed']) { $removed.Add($u.id) }
            elseif ($u.id) { $toRefresh.Add($u) }
        }

        $w = Update-ARSnapshotUsers -Users $toRefresh
        $totalWritten += $w
        $size += ($toRefresh.Count)

        foreach ($id in $removed) {
            # Keep the cached context; just stamp when it left so hard-delete
            # cleanup still has it, and the prune pass can retire it later.
            try { Merge-ARTableEntity -Table $tables.Directory -PartitionKey 'user' -RowKey $id -Properties @{ DeletedUtc = [DateTimeOffset]::UtcNow.ToString('o') } }
            catch { Write-Warning "Could not stamp removed user $id in the snapshot: $($_.Exception.Message)" }
            $totalRemoved++
            $size = [Math]::Max(0, $size - 1)
        }

        $next  = $page.'@odata.nextLink'
        $delta = $page.'@odata.deltaLink'
        if ($next) {
            $state = [pscustomobject]@{ deltaLink = $state.deltaLink; nextLink = $next; size = $size }
            Set-ARSnapshotState -State $state
            $pageUri = $next
            continue
        }
        # Enumeration complete for this cycle: store the delta token for next run.
        $state = [pscustomobject]@{ deltaLink = "$delta"; nextLink = ''; size = $size }
        Set-ARSnapshotState -State $state
        Write-Host 'Directory snapshot: enumeration complete; delta token stored.'
        break
    }

    try { Set-ARDirectorySize -Size ([Math]::Max(0, $size)) } catch { Write-Warning "Could not record directory size: $($_.Exception.Message)" }
    Write-Host "Directory snapshot pass: $totalWritten user(s) refreshed, $totalRemoved marked removed, ~$size total. (pages=$pages)"
}

function Invoke-ARSnapshotPrune {
    <#
    .SYNOPSIS
        Deletes snapshot rows for users removed more than $RetainDays ago (well
        past the 29-day hard-delete window), so the table -- and the personal
        data it holds -- does not grow forever.
    #>
    [CmdletBinding()] param([int]$RetainDays = 60)
    $tables = Get-ARTableNames
    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-$RetainDays)
    $rows = @(Get-ARTableEntities -Table $tables.Directory -Filter "PartitionKey eq 'user'")
    $pruned = 0
    foreach ($r in $rows) {
        $del = $r.PSObject.Properties['DeletedUtc']
        if (-not $del -or -not $del.Value) { continue }
        $when = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse("$($del.Value)", [ref]$when) -and $when -lt $cutoff) {
            try { Remove-ARTableEntity -Table $tables.Directory -PartitionKey 'user' -RowKey $r.RowKey; $pruned++ }
            catch { Write-Warning "Could not prune snapshot row $($r.RowKey): $($_.Exception.Message)" }
        }
    }
    if ($pruned -gt 0) { Write-Host "Snapshot prune: removed $pruned row(s) for users deleted over $RetainDays days ago." }
    return $pruned
}
