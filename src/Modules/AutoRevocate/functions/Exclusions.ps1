# Global exclusions: accounts the tool must NEVER act on, at ANY trigger
# (inactive, disable OR delete).
#
#   * Members of the configured exclusion group (break-glass / service accounts).
#   * Shared / room / equipment mailboxes (never offboarded; their Entra object
#     ids come from Exchange -- see Exo.ps1).
#
# Both are checked wherever the tool would act or enqueue work. They are RELIABLE
# while the account still exists (inactive / disable). At the delete trigger the
# object is already gone from the directory (and its mailbox from Exchange), so
# these can no longer see it -- delete-trigger exclusion is therefore best effort.
#
# The exclusion-group membership is cached per worker (like the mailbox set) so
# the high-volume per-user path never makes a Graph call per event.

$script:ARExclGroupCache = $null
$script:ARExclGroupCacheAt = [DateTimeOffset]::MinValue
$script:ARExclGroupCacheId = $null

function Get-ARExclusionGroupMemberIds {
    <#
    .SYNOPSIS
        Hashtable (object id -> $true) of the transitive USER members of the
        configured exclusion group. Empty when no group is configured. Cached per
        worker for ~15 min (keyed on the group id, so a config change re-reads).
        Throws if the group is configured but cannot be read (callers fail closed).
    #>
    [CmdletBinding()] param($FeatureConfig, [switch]$Refresh)
    if (-not $FeatureConfig) { $FeatureConfig = Get-ARFeatureConfig }
    $groupId = "$($FeatureConfig.inactive.exclusionGroupId)"
    if (-not $groupId) { return @{} }
    if (-not $Refresh -and $null -ne $script:ARExclGroupCache -and $script:ARExclGroupCacheId -eq $groupId -and
        ([DateTimeOffset]::UtcNow - $script:ARExclGroupCacheAt).TotalMinutes -lt 15) {
        return $script:ARExclGroupCache
    }
    $set = @{}
    $members = Invoke-ARGraph -Uri ('/groups/' + $groupId + '/transitiveMembers/microsoft.graph.user?$select=id&$top=999') -All
    foreach ($m in $members) { if ($m.id) { $set[$m.id] = $true } }
    $script:ARExclGroupCache = $set
    $script:ARExclGroupCacheId = $groupId
    $script:ARExclGroupCacheAt = [DateTimeOffset]::UtcNow
    return $set
}

function Get-ARExclusionObjectIds {
    <#
    .SYNOPSIS
        Combined set (object id -> reason string) of every account globally
        excluded from offboarding: exclusion-group members + shared/room/equipment
        mailboxes, per the config toggles. Throws if a configured source cannot be
        read (batch callers fail closed). Used by the scan, the reconciliation
        sweep and the preview; the per-user path uses Test-ARUserExcluded.
    #>
    [CmdletBinding()] param($FeatureConfig)
    if (-not $FeatureConfig) { $FeatureConfig = Get-ARFeatureConfig }
    $set = @{}
    if ($FeatureConfig.inactive.exclusionGroupId) {
        foreach ($id in (Get-ARExclusionGroupMemberIds -FeatureConfig $FeatureConfig).Keys) { $set[$id] = 'exclusion group' }
    }
    if ($FeatureConfig.inactive.excludeSharedMailboxes) {
        foreach ($kv in (Get-ARNonUserMailboxObjectIds).GetEnumerator()) { $set["$($kv.Key)"] = "mailbox type: $($kv.Value)" }
    }
    return $set
}

function Test-ARUserExcluded {
    <#
    .SYNOPSIS
        Is this user globally excluded from ALL offboarding? True if they are a
        member of the exclusion group, or (when 'exclude shared mailboxes' is on)
        their mailbox is a shared/room/equipment mailbox. Returns a small object
        { Excluded; Reason }.

        Reliable while the account still exists (inactive / disable). At the delete
        trigger the object is gone, so this returns Excluded=$false there (it can
        no longer see the deleted account); callers treat delete as best effort.

        Throws if a configured exclusion source cannot be read, so callers fail
        CLOSED (skip + retry) rather than risk acting on a protected account.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId, $FeatureConfig)
    if (-not $FeatureConfig) { $FeatureConfig = Get-ARFeatureConfig }

    if ($FeatureConfig.inactive.exclusionGroupId) {
        if ((Get-ARExclusionGroupMemberIds -FeatureConfig $FeatureConfig).ContainsKey($UserId)) {
            return [pscustomobject]@{ Excluded = $true; Reason = 'exclusion group' }
        }
    }
    if ($FeatureConfig.inactive.excludeSharedMailboxes) {
        $mbx = Get-ARNonUserMailboxObjectIds
        if ($mbx.ContainsKey($UserId)) {
            return [pscustomobject]@{ Excluded = $true; Reason = "mailbox type: $($mbx[$UserId])" }
        }
    }
    return [pscustomobject]@{ Excluded = $false; Reason = $null }
}
