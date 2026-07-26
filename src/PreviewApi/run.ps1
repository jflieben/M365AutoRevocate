using namespace System.Net

# Admin API: a what-if of the changes the tool will make next, across all three
# triggers, so the admin sees the blast radius -- with display names, UPNs and
# the dates we know (created / last sign-in / deleted) -- BEFORE it happens.
#
#   inactive - enabled accounts past the threshold the next daily scan will flag
#   disable  - already-disabled accounts the reconciliation will still act on
#   delete   - soft-deleted accounts awaiting delete-trigger cleanup
#
# It reflects the config POSTed in the request body (the on-screen, possibly
# unsaved settings) when present, else the saved config. signInActivity cannot be
# combined with other properties in a Graph $filter, so the inactive set is
# enumerated (as the scanner does) under a time budget: an exact count and full
# detail for a normal tenant, a sampled estimate for a very large one. Each block
# also caps the DETAIL rows returned (large counts are reported as a number).

param($Request, $TriggerMetadata)

$MaxDetail = 200

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 8)
        })
}

function Get-AREnabledActionLabels {
    param($FeatureConfig, [string]$Trigger)
    $labels = [System.Collections.Generic.List[string]]::new()
    foreach ($f in Get-ARFeatureCatalog) {
        if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature $f.key -Trigger $Trigger) { $labels.Add($f.label) }
    }
    return @($labels)
}

try {
    $auth = Test-ARAdminRequest -Request $Request
    if (-not $auth.Ok) { Send-Json -Status $auth.Status -Object @{ error = $auth.Error }; return }

    # Config: prefer the (possibly unsaved) config the caller POSTs so the preview
    # matches exactly what they are about to save; fall back to the saved config.
    $features = $null
    if ($Request.Method -eq 'POST' -and $Request.Body) {
        $raw = $Request.Body
        if ($raw -is [string]) { try { $raw = $raw | ConvertFrom-Json } catch { $raw = $null } }
        if ($raw) { try { $features = [pscustomobject](ConvertTo-ARSanitisedConfig -Raw $raw) } catch { Write-Warning "Preview: could not sanitise posted config, using saved: $($_.Exception.Message)" } }
    }
    if (-not $features) { $features = Get-ARFeatureConfig -Fresh }

    $now = [DateTimeOffset]::UtcNow
    $tables = Get-ARTableNames
    $triggers = [ordered]@{}

    # Global exclusions (exclusion group + shared/room/equipment mailboxes), built
    # ONCE and applied to the live triggers (inactive + disable). Best-effort for a
    # preview: on a read error we note it rather than aborting the whole preview.
    # Deleted accounts can't be matched here (they are gone), so the delete block
    # does not apply this.
    $exclusionSet = @{}
    $exclusionNotes = [System.Collections.Generic.List[string]]::new()
    if ($features.inactive.exclusionGroupId) {
        try { foreach ($id in (Get-ARExclusionGroupMemberIds -FeatureConfig $features).Keys) { $exclusionSet[$id] = $true } }
        catch { $exclusionNotes.Add("exclusion group could not be read (not applied): $($_.Exception.Message)") }
    }
    if ($features.inactive.excludeSharedMailboxes) {
        try { foreach ($id in (Get-ARNonUserMailboxObjectIds).Keys) { $exclusionSet[$id] = $true } }
        catch { $exclusionNotes.Add("shared/room/equipment mailboxes could not be read (not excluded): $($_.Exception.Message)") }
    }

    # ---------- inactive: enabled accounts the next daily scan would flag ----------
    # @() so a single enabled action stays an array through the function-return
    # boundary (a bare array is unrolled to a scalar and would serialise as a
    # string, breaking the client's actions.map()).
    $inActions = @(Get-AREnabledActionLabels -FeatureConfig $features -Trigger 'inactive')
    $inBlock = [ordered]@{
        applicable = $false; note = ''; thresholdDays = [int]$features.inactive.thresholdDays
        actions = $inActions; count = 0; detailCount = 0; truncated = $false; sampled = $false; scanned = 0; items = @(); notes = @()
    }
    if (-not $features.inactive.enabled) { $inBlock.note = 'Inactive-user monitoring is off.' }
    elseif ($inActions.Count -eq 0) { $inBlock.note = 'No actions are set to run at the inactive trigger.' }
    else {
        $inBlock.applicable = $true
        $threshold = [int]$features.inactive.thresholdDays; if ($threshold -lt 7) { $threshold = 7 }
        $inBlock.thresholdDays = $threshold
        $notes = [System.Collections.Generic.List[string]]::new()
        foreach ($n in $exclusionNotes) { $notes.Add($n) }
        $processed = @{}
        foreach ($e in (Get-ARTableEntities -Table $tables.Processed -Filter "PartitionKey eq 'inactive'")) { $processed[$e.RowKey] = $true }

        $items = [System.Collections.Generic.List[object]]::new()
        $count = 0; $scanned = 0; $budgetHit = $false
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $uri = '/users?$select=id,accountEnabled,displayName,userPrincipalName,createdDateTime,signInActivity&$top=120'
        while ($uri) {
            if ($sw.ElapsedMilliseconds -gt 8000) { $budgetHit = $true; break }
            $page = Invoke-ARGraph -Uri $uri
            foreach ($u in @($page.value)) {
                $scanned++
                if ($u.accountEnabled -ne $true) { continue }
                if ($exclusionSet.ContainsKey($u.id)) { continue }
                if ($processed.ContainsKey($u.id)) { continue }   # already flagged; won't re-fire
                $sia = $u.PSObject.Properties['signInActivity'].Value
                $lastRaw = if ($sia) { $sia.PSObject.Properties['lastSuccessfulSignInDateTime'].Value } else { $null }
                $basis = if ($lastRaw) { $lastRaw } else { $u.createdDateTime }
                if (-not $basis) { continue }
                if (($now - [DateTimeOffset]::Parse($basis)).TotalDays -lt $threshold) { continue }
                $count++
                if ($items.Count -lt $MaxDetail) {
                    $items.Add([pscustomobject]@{ displayName = $u.displayName; upn = $u.userPrincipalName; createdDateTime = $u.createdDateTime; lastSignIn = $lastRaw })
                }
            }
            $uri = $page.'@odata.nextLink'
        }
        $inBlock.count = $count; $inBlock.detailCount = $items.Count; $inBlock.truncated = ($count -gt $items.Count)
        $inBlock.sampled = $budgetHit; $inBlock.scanned = $scanned; $inBlock.items = @($items)
        if ($budgetHit) { $notes.Add("stopped after $scanned accounts (large tenant); the count is a partial estimate") }
        $inBlock.notes = @($notes)
    }
    $triggers.inactive = $inBlock

    # ---------- disable: already-disabled accounts not yet processed ----------
    $disActions = @(Get-AREnabledActionLabels -FeatureConfig $features -Trigger 'disable')
    $disBlock = [ordered]@{ applicable = $false; note = ''; actions = $disActions; count = 0; detailCount = 0; truncated = $false; sampled = $false; scanned = 0; items = @(); notes = @() }
    if ($disActions.Count -eq 0) { $disBlock.note = 'No actions are set to run at the disable trigger.' }
    else {
        $disBlock.applicable = $true
        $processed = @{}
        foreach ($e in (Get-ARTableEntities -Table $tables.Processed -Filter "PartitionKey eq 'disable'")) { $processed[$e.RowKey] = $true }

        $items = [System.Collections.Generic.List[object]]::new()
        $count = 0; $scanned = 0; $budgetHit = $false
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # signInActivity can't be combined with the accountEnabled filter, so this
        # block reports created dates only (last sign-in shown as unknown).
        $uri = '/users?$filter=accountEnabled eq false&$select=id,displayName,userPrincipalName,createdDateTime&$top=999'
        while ($uri) {
            if ($sw.ElapsedMilliseconds -gt 6000) { $budgetHit = $true; break }
            $page = Invoke-ARGraph -Uri $uri
            foreach ($u in @($page.value)) {
                $scanned++
                if (-not $u.id) { continue }
                if ($processed.ContainsKey($u.id)) { continue }
                if ($exclusionSet.ContainsKey($u.id)) { continue }   # excluded group / shared mailbox
                $count++
                if ($items.Count -lt $MaxDetail) {
                    $items.Add([pscustomobject]@{ displayName = $u.displayName; upn = $u.userPrincipalName; createdDateTime = $u.createdDateTime; lastSignIn = $null })
                }
            }
            $uri = $page.'@odata.nextLink'
        }
        $disBlock.count = $count; $disBlock.detailCount = $items.Count; $disBlock.truncated = ($count -gt $items.Count)
        $disBlock.sampled = $budgetHit; $disBlock.scanned = $scanned; $disBlock.items = @($items)
        $notes = [System.Collections.Generic.List[string]]::new()
        $notes.Add('Already-disabled accounts not yet processed; the daily reconciliation will action these.')
        foreach ($n in $exclusionNotes) { $notes.Add($n) }
        if ($budgetHit) { $notes.Add("stopped after $scanned accounts (large tenant); the count is a partial estimate") }
        $disBlock.notes = @($notes)
    }
    $triggers.disable = $disBlock

    # ---------- delete: soft-deleted accounts awaiting cleanup ----------
    $delActions = @(Get-AREnabledActionLabels -FeatureConfig $features -Trigger 'delete')
    $delBlock = [ordered]@{ applicable = $false; note = ''; mode = "$($features.mode)"; actions = $delActions; count = 0; detailCount = 0; truncated = $false; sampled = $false; scanned = 0; items = @(); notes = @() }
    if ($delActions.Count -eq 0) { $delBlock.note = 'No actions are set to run at the delete trigger.' }
    else {
        $delBlock.applicable = $true
        $isHard = ("$($features.mode)" -eq 'hard')
        $processed = @{}
        foreach ($e in (Get-ARTableEntities -Table $tables.Processed -Filter "PartitionKey eq 'delete'")) { $processed[$e.RowKey] = $true }
        $pending = @{}
        foreach ($p in (Get-ARTableEntities -Table $tables.Pending)) { $pending[$p.RowKey] = $p }

        $items = [System.Collections.Generic.List[object]]::new()
        $seen = @{}
        $count = 0; $scanned = 0; $budgetHit = $false
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $uri = '/directory/deletedItems/microsoft.graph.user?$select=id,displayName,userPrincipalName,deletedDateTime,createdDateTime&$top=100'
        while ($uri) {
            if ($sw.ElapsedMilliseconds -gt 5000) { $budgetHit = $true; break }
            $page = Invoke-ARGraph -Uri $uri
            foreach ($u in @($page.value)) {
                $scanned++
                if (-not $u.id) { continue }
                if ($processed.ContainsKey($u.id)) { continue }   # delete-trigger cleanup already done
                $seen[$u.id] = $true
                $count++
                if ($items.Count -lt $MaxDetail) {
                    $due = $null
                    if ($isHard -and $u.deletedDateTime) { try { $due = ([DateTimeOffset]::Parse($u.deletedDateTime).AddDays(29)).ToString('o') } catch { } }
                    $items.Add([pscustomobject]@{ displayName = $u.displayName; upn = $u.userPrincipalName; createdDateTime = $u.createdDateTime; deletedDateTime = $u.deletedDateTime; dueDate = $due; source = 'recycle-bin' })
                }
            }
            $uri = $page.'@odata.nextLink'
        }
        # Pending hard-deletes already purged from the recycle bin still owe cleanup.
        if ($isHard) {
            foreach ($k in $pending.Keys) {
                if ($seen.ContainsKey($k) -or $processed.ContainsKey($k)) { continue }
                $count++
                if ($items.Count -lt $MaxDetail) {
                    $p = $pending[$k]
                    $due = $null
                    if ($p.DeletedDateTime) { try { $due = ([DateTimeOffset]::Parse("$($p.DeletedDateTime)").AddDays(29)).ToString('o') } catch { } }
                    $items.Add([pscustomobject]@{ displayName = $p.DisplayName; upn = $p.UserPrincipalName; createdDateTime = $null; deletedDateTime = "$($p.DeletedDateTime)"; dueDate = $due; source = 'pending-purge' })
                }
            }
        }
        $delBlock.count = $count; $delBlock.detailCount = $items.Count; $delBlock.truncated = ($count -gt $items.Count)
        $delBlock.sampled = $budgetHit; $delBlock.scanned = $scanned; $delBlock.items = @($items)
        $notes = [System.Collections.Generic.List[string]]::new()
        if ($isHard) { $notes.Add('Hard-delete mode: acted on ~29 days after deletion, or as soon as the account is permanently purged.') }
        else { $notes.Add('Soft-delete mode: acted on at the next reconciliation (or immediately on the deletion notification).') }
        if ($budgetHit) { $notes.Add("stopped after $scanned recycle-bin accounts; the count is a partial estimate") }
        $delBlock.notes = @($notes)
    }
    $triggers.delete = $delBlock

    Send-Json -Status 200 -Object ([ordered]@{
            generatedUtc = $now.ToString('o')
            mode         = "$($features.mode)"
            triggers     = $triggers
        })
}
catch {
    Write-Error "PreviewApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
