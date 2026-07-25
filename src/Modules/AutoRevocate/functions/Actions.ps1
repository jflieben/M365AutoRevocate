# Revocation actions performed when a monitored user is deleted.
#
# Everything here is idempotent and honours Config.DryRun (when set, destructive
# calls are logged but not sent). The orchestrator is Invoke-ARRevocation.

function Get-ARDeletedUser {
    <#
    .SYNOPSIS
        Reads a soft-deleted user from the directory recycle bin, or $null if it
        is no longer there (already purged / never existed).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    $path = '/directory/deletedItems/microsoft.graph.user/' + $UserId +
            '?$select=id,userPrincipalName,displayName,mail,deletedDateTime,department,jobTitle,companyName,accountEnabled'
    $r = Invoke-ARGraph -Uri $path -Raw
    if ($r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -ge 400) { throw "Fetching deleted user $UserId failed with HTTP $($r.StatusCode)." }
    return $r.Body
}

function Get-ARDirectoryEntry {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    $tables = Get-ARTableNames
    return Get-ARTableEntity -Table $tables.Directory -PartitionKey 'user' -RowKey $UserId
}

function Resolve-ARRecipient {
    <#
    .SYNOPSIS
        Decides who receives the artifact hand-off email: the user's manager if
        still active, otherwise the service desk. At the 'disable' trigger the
        manager is read live; at 'delete' it comes from the directory snapshot
        (Graph has dropped the relationship by then).
    #>
    [CmdletBinding()] param(
        [string]$UserId,
        [ValidateSet('inactive', 'disable', 'delete')][string]$Trigger = 'delete',
        $CacheEntry,
        [string]$ServicedeskEmail
    )

    $mgrBody = $null
    if ($Trigger -in @('inactive', 'disable') -and $UserId) {
        try {
            $m = Invoke-ARGraph -Uri ('/users/' + $UserId + '/manager?$select=id,userPrincipalName,mail,accountEnabled,displayName') -Raw
            if ($m.StatusCode -lt 400) { $mgrBody = $m.Body }
        }
        catch { }
    }
    else {
        $managerId = if ($CacheEntry) { $CacheEntry.PSObject.Properties['ManagerId'].Value } else { $null }
        if ($managerId) {
            try { $mgrBody = Invoke-ARGraph -Uri ('/users/' + $managerId + '?$select=id,userPrincipalName,mail,accountEnabled,displayName') }
            catch { Write-Host "Manager $managerId could not be resolved; falling back to service desk." }
        }
    }

    if ($mgrBody -and $mgrBody.id) {
        $mail = if ($mgrBody.mail) { $mgrBody.mail } else { $mgrBody.userPrincipalName }
        if ($mgrBody.accountEnabled -eq $true -and $mail) {
            return [pscustomobject]@{ Email = $mail; Kind = 'manager'; DisplayName = $mgrBody.displayName }
        }
    }
    return [pscustomobject]@{ Email = $ServicedeskEmail; Kind = 'servicedesk'; DisplayName = 'Service Desk' }
}

function Find-ARUserOneDrive {
    <#
    .SYNOPSIS
        Locates the deleted user's OneDrive drive. Prefers the cached driveId
        captured by the directory snapshot; otherwise reconstructs the personal
        site URL from the UPN. OneDrive survives user deletion for the tenant's
        retention window, so this generally still resolves.
    #>
    [CmdletBinding()] param([string]$UserId, [string]$UserPrincipalName, $Snapshot, [string]$Trigger = 'delete')

    # Live path: account still exists (disable trigger) -> ask Graph directly.
    if ($UserId) {
        try {
            $d = Invoke-ARGraph -Uri ('/users/' + $UserId + '/drive?$select=id,webUrl') -Raw
            if ($d.StatusCode -lt 400 -and $d.Body.id) {
                return [pscustomobject]@{ DriveId = $d.Body.id; WebUrl = $d.Body.webUrl; Source = 'live' }
            }
        }
        catch { }
    }

    $cachedDrive = if ($Snapshot) { $Snapshot.PSObject.Properties['DriveId'].Value } else { $null }
    if ($cachedDrive) {
        $webUrl = $Snapshot.PSObject.Properties['DriveWebUrl'].Value
        return [pscustomobject]@{ DriveId = $cachedDrive; WebUrl = $webUrl; Source = 'cache' }
    }

    if (-not $UserPrincipalName) { return $null }
    try {
        $myHost = Get-ARSharePointMyHost
        $munged = ($UserPrincipalName -replace '[^a-zA-Z0-9-]', '_')
        $site   = Invoke-ARGraph -Uri ('/sites/' + $myHost + ':/personal/' + $munged + '?$select=id,webUrl')
        if (-not $site.id) { return $null }
        $drive  = Invoke-ARGraph -Uri ('/sites/' + $site.id + '/drive?$select=id,webUrl')
        return [pscustomobject]@{ DriveId = $drive.id; WebUrl = $drive.webUrl; Source = 'constructed' }
    }
    catch {
        Write-Host "No OneDrive resolved for '$UserPrincipalName': $($_.Exception.Message)"
        return $null
    }
}

function Get-ARUserArtifacts {
    <#
    .SYNOPSIS
        Lists artifacts the user still owns. At 'disable' this is read live from
        Graph; at 'delete' it comes from the directory snapshot (Graph has
        dropped ownership by then).
    #>
    [CmdletBinding()] param([string]$UserId, $CacheEntry, [string]$Trigger = 'delete')
    $list = [System.Collections.Generic.List[object]]::new()

    if ($Trigger -in @('inactive', 'disable') -and $UserId) {
        try {
            $owned = Invoke-ARGraph -Uri ('/users/' + $UserId + '/ownedObjects?$select=id,displayName') -All
            foreach ($o in $owned) {
                $list.Add([pscustomobject]@{
                        Type        = ($o.'@odata.type' -replace '#microsoft\.graph\.', '')
                        DisplayName = $o.displayName; Id = $o.id; Detail = ''
                    })
            }
            return $list
        }
        catch { Write-Warning "Live ownedObjects lookup failed for $UserId; trying snapshot: $($_.Exception.Message)" }
    }

    $ownedJson = if ($CacheEntry) { $CacheEntry.PSObject.Properties['OwnedObjects'].Value } else { $null }
    if ($ownedJson) {
        try {
            foreach ($o in ($ownedJson | ConvertFrom-Json)) {
                $list.Add([pscustomobject]@{ Type = $o.type; DisplayName = $o.displayName; Id = $o.id; Detail = $o.detail })
            }
        }
        catch { Write-Warning "Could not parse cached OwnedObjects for artifact list: $($_.Exception.Message)" }
    }
    return $list
}

function Test-ARProcessed {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId, [Parameter(Mandatory)][string]$Trigger)
    $tables = Get-ARTableNames
    $e = Get-ARTableEntity -Table $tables.Processed -PartitionKey $Trigger -RowKey $UserId
    # Only a COMPLETED marker counts as processed. An in-flight claim (see
    # Start-ARProcessedClaim) exists but is not yet completed.
    return [bool]($e -and "$($e.Completed)".ToLowerInvariant() -eq 'true')
}

function Start-ARProcessedClaim {
    <#
    .SYNOPSIS
        Atomically claims (trigger,userId) so exactly one worker processes it.
        Uses an Insert (POST to the table, not upsert): the second concurrent
        claim gets HTTP 409 and loses. Returns $true if we won the claim, $false
        if it was already claimed or completed (idempotent skip).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId, [Parameter(Mandatory)][string]$Trigger)
    $tables = Get-ARTableNames
    $entity = @{
        PartitionKey    = $Trigger
        RowKey          = $UserId
        Trigger         = $Trigger
        Completed       = 'false'
        ClaimedDateTime = [DateTimeOffset]::UtcNow.ToString('o')
    }
    # Plain POST insert = fail-if-exists. 409 means a row already exists.
    $r = Invoke-ARTable -Method Post -Path $tables.Processed -Body $entity -Raw
    if ($r.StatusCode -lt 400) { return $true }
    if ($r.StatusCode -ne 409) { throw "Could not claim ($Trigger,$UserId) (HTTP $($r.StatusCode))." }

    # A row exists. Completed -> already done (idempotent skip). Otherwise it is
    # an in-flight claim; if it is stale (>15 min, i.e. a crashed worker left it
    # behind) we take it over so the user is not blocked forever.
    $existing = Get-ARTableEntity -Table $tables.Processed -PartitionKey $Trigger -RowKey $UserId
    if (-not $existing) { return $false }
    if ("$($existing.Completed)".ToLowerInvariant() -eq 'true') { return $false }
    $claimedAt = [DateTimeOffset]::MinValue
    if ($existing.PSObject.Properties['ClaimedDateTime'] -and [DateTimeOffset]::TryParse("$($existing.ClaimedDateTime)", [ref]$claimedAt)) {
        if (([DateTimeOffset]::UtcNow - $claimedAt).TotalMinutes -lt 15) { return $false }  # actively being worked
    }
    Write-Warning "Reclaiming a stale in-flight claim for ($Trigger,$UserId)."
    Set-ARTableEntity -Table $tables.Processed -PartitionKey $Trigger -RowKey $UserId -Properties $entity
    return $true
}

function Undo-ARProcessedClaim {
    # Release an uncompleted claim so a retry can re-take it (used when
    # processing fails after claiming). Never removes a completed marker.
    [CmdletBinding()] param([string]$UserId, [string]$Trigger)
    $tables = Get-ARTableNames
    try {
        $e = Get-ARTableEntity -Table $tables.Processed -PartitionKey $Trigger -RowKey $UserId
        if ($e -and "$($e.Completed)".ToLowerInvariant() -ne 'true') {
            Remove-ARTableEntity -Table $tables.Processed -PartitionKey $Trigger -RowKey $UserId
        }
    }
    catch { Write-Warning "Could not release claim ($Trigger,$UserId): $($_.Exception.Message)" }
}

function Set-ARProcessed {
    [CmdletBinding()] param([string]$UserId, [string]$Upn, [string]$Trigger, $Result)
    $tables = Get-ARTableNames
    # Merge (not replace) so the original ClaimedDateTime is preserved.
    Merge-ARTableEntity -Table $tables.Processed -PartitionKey $Trigger -RowKey $UserId -Properties @{
        UserPrincipalName = $Upn
        Trigger           = $Trigger
        Completed         = 'true'
        ProcessedDateTime = [DateTimeOffset]::UtcNow.ToString('o')
        Summary           = ($Result | ConvertTo-Json -Depth 8 -Compress)
    }
}

function Clear-ARProcessed {
    # Used when a user is re-enabled so a future disable re-triggers.
    [CmdletBinding()] param([string]$UserId, [string]$Trigger)
    $tables = Get-ARTableNames
    try { Remove-ARTableEntity -Table $tables.Processed -PartitionKey $Trigger -RowKey $UserId } catch { }
}

function Write-ARActivity {
    <#
    .SYNOPSIS
        Appends a chronological entry to the ActivityLog table (newest first),
        which the admin web app reads. Written even on dry runs.
    #>
    [CmdletBinding()] param($Result)
    $tables = Get-ARTableNames
    # RowKey = (max ticks - now) zero-padded => ascending RowKey is newest-first.
    $rowKey = ('{0:D19}' -f ([DateTime]::MaxValue.Ticks - [DateTime]::UtcNow.Ticks))
    try {
        Set-ARTableEntity -Table $tables.Activity -PartitionKey 'log' -RowKey $rowKey -Properties @{
            TimestampUtc      = [DateTimeOffset]::UtcNow.ToString('o')
            UserId            = $Result.UserId
            UserPrincipalName = $Result.Upn
            DisplayName       = $Result.DisplayName
            Trigger           = $Result.Trigger
            Event             = $Result.Event
            DryRun            = [string]$Result.DryRun
            Summary           = ($Result.Actions | ConvertTo-Json -Depth 8 -Compress)
        }
    }
    catch { Write-Warning "Failed to write activity log entry: $($_.Exception.Message)" }
}

function Write-ARSystemActivity {
    <#
    .SYNOPSIS
        Appends a SYSTEM entry to the activity log (subscription lifecycle,
        config saves, dropped notifications) so operators see the tool's own
        actions alongside user cleanups. Never throws.
    .PARAMETER Actor
        Who performed the action (e.g. the signed-in admin saving config).
        Shown in the log's User column; '(system)' when omitted.
    .PARAMETER SummaryObject
        Structured detail (e.g. a config diff) serialised into the entry's
        expandable Details field. Takes precedence over -Detail.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$EventName,
        [string]$Detail,
        [string]$Actor,
        $SummaryObject
    )
    $tables = Get-ARTableNames
    $rowKey = ('{0:D19}' -f ([DateTime]::MaxValue.Ticks - [DateTime]::UtcNow.Ticks))
    $summary = if ($null -ne $SummaryObject) { $SummaryObject | ConvertTo-Json -Depth 10 -Compress }
    else { @{ detail = "$Detail" } | ConvertTo-Json -Compress }
    try {
        Set-ARTableEntity -Table $tables.Activity -PartitionKey 'log' -RowKey $rowKey -Properties @{
            TimestampUtc      = [DateTimeOffset]::UtcNow.ToString('o')
            UserId            = ''
            UserPrincipalName = "$Actor"
            DisplayName       = if ($Actor) { $Actor } else { '(system)' }
            Trigger           = 'system'
            Event             = $EventName
            DryRun            = 'False'
            Summary           = $summary
        }
    }
    catch { Write-Warning "Failed to write system activity entry: $($_.Exception.Message)" }
}

function Invoke-ARRevocation {
    <#
    .SYNOPSIS
        Orchestrates the configured actions for one user at one trigger.
    .PARAMETER Trigger
        'inactive' (account dormant past the threshold), 'disable' (account
        deactivated, still exists) or 'delete' (removed).
    .PARAMETER DeleteTiming
        For 'delete': 'soft' (recycle bin) or 'hard' (permanent). Messaging only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][ValidateSet('inactive', 'disable', 'delete')][string]$Trigger,
        [ValidateSet('soft', 'hard')][string]$DeleteTiming = 'soft',
        $DeletedUser,
        $Snapshot,
        $FeatureConfig
    )
    $cfg = Get-ARConfig
    if (-not $FeatureConfig) { $FeatureConfig = Get-ARFeatureConfig }

    # Global exclusion gate FIRST: exclusion-group members (break-glass / service
    # accounts) and shared/room/equipment mailboxes are NEVER acted on, at ANY
    # trigger. Checked before the dedup claim and storm guard so an excluded user
    # consumes neither. Fails CLOSED on a read error (throw -> the queue retries)
    # so we never act on a protected account while uncertain -- except at 'delete',
    # where the object is already gone (exclusion is inherently best-effort and a
    # read error must not block cleanup of a genuinely-deleted account).
    try {
        $excl = Test-ARUserExcluded -UserId $UserId -FeatureConfig $FeatureConfig
    }
    catch {
        if ($Trigger -eq 'delete') {
            Write-Warning "Invoke-ARRevocation: exclusion check failed for deleted user $UserId; proceeding with delete-trigger cleanup: $($_.Exception.Message)"
            $excl = [pscustomobject]@{ Excluded = $false }
        }
        else {
            Write-Warning "Invoke-ARRevocation: could not evaluate exclusions for $UserId ($Trigger); skipping this run to stay safe (will retry): $($_.Exception.Message)"
            throw
        }
    }
    if ($excl.Excluded) {
        Write-Host "Invoke-ARRevocation: user $UserId is excluded ($($excl.Reason)); ignoring at trigger '$Trigger'."
        return [pscustomobject]@{ Excluded = $true; Reason = $excl.Reason; UserId = $UserId; Trigger = $Trigger }
    }

    # Atomic dedup claim FIRST, so duplicate notifications (an updated + a
    # deleted for the same user often arrive together) never both run and never
    # consume storm-guard budget. Skipped in dry-run so simulations repeat.
    if (-not $cfg.DryRun) {
        if (-not (Start-ARProcessedClaim -UserId $UserId -Trigger $Trigger)) {
            Write-Host "User $UserId already processed/claimed for trigger '$Trigger'; skipping (idempotent)."
            return
        }
    }

    # Storm guard: the circuit breaker. Blocks (and, on breach, pauses the whole
    # tool) so one bulk event cannot cascade into a mass of cleanups. If blocked
    # we release the claim so the action is retried after an admin resumes.
    $guard = Test-ARStormGuard -Trigger $Trigger -FeatureConfig $FeatureConfig
    if (-not $guard.Allowed) {
        if (-not $cfg.DryRun) { Undo-ARProcessedClaim -UserId $UserId -Trigger $Trigger }
        Write-Warning "Invoke-ARRevocation: blocked for $UserId trigger=${Trigger}: $($guard.Reason)"
        return [pscustomobject]@{ Blocked = $true; Paused = $guard.Paused; Reason = $guard.Reason; UserId = $UserId; Trigger = $Trigger }
    }

    try {
    # Resolve identity/context differently for a live vs deleted account.
    $isLive = $Trigger -in @('inactive', 'disable')
    $upn = $null; $display = $null
    if ($isLive) {
        try {
            $u = Invoke-ARGraph -Uri ('/users/' + $UserId + '?$select=id,userPrincipalName,displayName,accountEnabled') -Raw
            if ($u.StatusCode -lt 400) { $upn = $u.Body.userPrincipalName; $display = $u.Body.displayName }
        }
        catch { }
    }
    else {
        if (-not $DeletedUser) { $DeletedUser = Get-ARDeletedUser -UserId $UserId }
        if ($DeletedUser) { $upn = $DeletedUser.userPrincipalName; $display = $DeletedUser.displayName }
    }
    if (-not $Snapshot) { $Snapshot = Get-ARDirectoryEntry -UserId $UserId }
    if (-not $upn -and $Snapshot) { $upn = $Snapshot.UserPrincipalName; $display = $Snapshot.DisplayName }
    if (-not $display) { $display = $upn }

    $liveUserId = if ($isLive) { $UserId } else { $null }
    $eventDesc = switch ($Trigger) {
        'inactive' { 'flagged as inactive' }
        'disable'  { 'deactivated' }
        default    { if ($DeleteTiming -eq 'hard') { 'permanently deleted' } else { 'deleted' } }
    }
    Write-Host "Processing '$upn' ($UserId) trigger=$Trigger dryRun=$($cfg.DryRun)."

    $actions = [ordered]@{}

    if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'unshareOneDrive' -Trigger $Trigger) {
        $drive = Find-ARUserOneDrive -UserId $liveUserId -UserPrincipalName $upn -Snapshot $Snapshot -Trigger $Trigger
        if ($drive) {
            # Disable sharing on the whole personal site: one flag on the site
            # collection that kills every existing link and blocks new ones. This
            # is O(1); there is no per-item fallback (walking a large drive cannot
            # finish in a function timeout). If it fails we record the error so an
            # operator can see it, rather than doing unbounded work.
            $siteUrl = Get-ARPersonalSiteUrl -WebUrl $drive.WebUrl
            $od = $null
            if ($siteUrl) {
                try { $od = Set-ARSiteSharingDisabled -SiteUrl $siteUrl }
                catch {
                    Write-Warning "Site-level sharing disable failed for $siteUrl`: $($_.Exception.Message)"
                    $od = [pscustomobject]@{ SharingDisabled = $false; Error = $_.Exception.Message; SiteUrl = $siteUrl }
                }
            }
            else {
                Write-Warning "Could not derive the personal site URL from '$($drive.WebUrl)'."
                $od = [pscustomobject]@{ SharingDisabled = $false; Error = 'could not derive the personal site URL' }
            }
            $od | Add-Member -NotePropertyName WebUrl -NotePropertyValue $drive.WebUrl -Force
            $actions['unshareOneDrive'] = $od
        }
        else {
            Write-Host 'unshareOneDrive: no OneDrive found for this user; skipping.'
            $actions['unshareOneDrive'] = [pscustomobject]@{ Skipped = 'no OneDrive found' }
        }
    }

    # Disable sign-in first (inactive trigger only), then revoke live sessions so
    # nothing survives. Reports whether it actually changed state -- an already-
    # disabled account is left untouched and the email/audit says so.
    if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'disableAccount' -Trigger $Trigger) {
        $actions['disableAccount'] = Set-ARUserDisabled -UserId $UserId
    }
    if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'revokeSessions' -Trigger $Trigger) {
        $actions['revokeSessions'] = Invoke-ARRevokeSessions -UserId $UserId
    }
    if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'autoReply' -Trigger $Trigger) {
        $actions['autoReply'] = Set-ARAutoReply -UserId $UserId -Message $FeatureConfig.features.autoReply.message
    }
    if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'forward' -Trigger $Trigger) {
        $actions['forward'] = Set-ARMailboxForward -UserId $UserId -Address $FeatureConfig.features.forward.address
    }
    if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'cancelMeetings' -Trigger $Trigger) {
        $actions['cancelMeetings'] = Invoke-ARCancelOrganisedMeetings -UserId $UserId -Comment $FeatureConfig.features.cancelMeetings.comment
    }

    # Licence/group removal and soft delete (inactive + disable triggers). Order
    # matters: licences and groups after the mailbox/OneDrive work, and soft
    # delete strictly LAST -- everything above needs the account to still exist.
    if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'removeLicenses' -Trigger $Trigger) {
        $actions['removeLicenses'] = Remove-ARUserLicenses -UserId $UserId
    }
    if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'removeFromGroups' -Trigger $Trigger) {
        $actions['removeFromGroups'] = Remove-ARUserFromGroups -UserId $UserId
    }

    # Resolve the hand-off recipient + artifacts BEFORE the soft delete (both are
    # read from the live account for inactive/disable triggers), but SEND the
    # email AFTER every action so it can report exactly what happened -- including
    # the soft delete. This is why notifyManager is not run inline above.
    $notify = Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'notifyManager' -Trigger $Trigger
    $recipient = $null; $artifacts = @()
    if ($notify) {
        try {
            $artifacts = @(Get-ARUserArtifacts -UserId $liveUserId -CacheEntry $Snapshot -Trigger $Trigger)
            $recipient = Resolve-ARRecipient -UserId $liveUserId -Trigger $Trigger -CacheEntry $Snapshot -ServicedeskEmail $FeatureConfig.servicedeskEmail
        }
        catch { Write-Warning "Could not resolve hand-off recipient/artifacts for $upn`: $($_.Exception.Message)" }
    }

    if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature 'softDeleteUser' -Trigger $Trigger) {
        $actions['softDeleteUser'] = Invoke-ARSoftDeleteUser -UserId $UserId
    }

    if ($notify -and $recipient) {
        # Isolate mail failure: sending can fail transiently (Exchange RBAC for
        # Applications takes up to ~30 min to propagate). That must NOT abort the
        # revocation and poison the queue -- the work is already done.
        try {
            $odForMail = if ($actions.Contains('unshareOneDrive')) { $actions['unshareOneDrive'] } else { $null }
            Send-ARNotificationMail -DeletedUpn $upn -DeletedDisplayName $display -DeletedUserId $UserId `
                -Trigger $Trigger -EventDescription $eventDesc -OneDrive $odForMail -Artifacts $artifacts `
                -Recipient $recipient -Actions ([pscustomobject]$actions)
            $actions['notifyManager'] = [pscustomobject]@{ Recipient = $recipient.Email; Kind = $recipient.Kind; ArtifactCount = $artifacts.Count }
        }
        catch {
            Write-Warning "notifyManager failed for $upn (continuing; the rest of the cleanup stands): $($_.Exception.Message)"
            $actions['notifyManager'] = [pscustomobject]@{ Sent = $false; Error = $_.Exception.Message }
        }
    }

    $result = [pscustomobject][ordered]@{
        UserId = $UserId; Upn = $upn; DisplayName = $display
        Trigger = $Trigger; DeleteTiming = $DeleteTiming; Event = $eventDesc
        DryRun = $cfg.DryRun; Actions = [pscustomobject]$actions
    }

    if (-not $cfg.DryRun) { Set-ARProcessed -UserId $UserId -Trigger $Trigger -Upn $upn -Result $result }
    Write-ARActivity -Result $result
    Write-Host "Invoke-ARRevocation: done for '$upn' trigger=$Trigger. Actions: $(if ($actions.Count) { ($actions.Keys -join ', ') } else { 'none enabled' }). Activity log entry written."
    return $result
    }
    catch {
        # Processing failed after we claimed: release the claim so a queue retry
        # (or the next scan) can re-take and complete it, rather than the user
        # being permanently stuck as "in flight".
        if (-not $cfg.DryRun) { Undo-ARProcessedClaim -UserId $UserId -Trigger $Trigger }
        throw
    }
}
