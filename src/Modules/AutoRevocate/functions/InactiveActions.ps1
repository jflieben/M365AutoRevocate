# Lifecycle actions for a still-live account: disabling it, licence removal,
# group removal and soft deletion. Licence/group/soft-delete apply at the
# 'inactive' and 'disable' triggers; disabling only at 'inactive' (a disabled
# account is already disabled). All Graph REST, DryRun-aware, returning small
# summaries for the audit record.

function Set-ARUserDisabled {
    <#
    .SYNOPSIS
        Disables the account (blocks sign-in) by setting accountEnabled = false.
        Only offered at the 'inactive' trigger. Reads the current state first and,
        if the account is already disabled, leaves it untouched and reports that --
        so the audit record and hand-off email never claim a change that did not
        actually happen.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    $cfg = Get-ARConfig
    $current = $null
    try {
        $u = Invoke-ARGraph -Uri ('/users/' + $UserId + '?$select=id,accountEnabled')
        $current = $u.accountEnabled
    }
    catch { Write-Warning "Reading accountEnabled failed for ${UserId}: $($_.Exception.Message)" }

    if ($current -eq $false) {
        Write-Host "Account $UserId is already disabled; leaving unchanged."
        return [pscustomobject]@{ Disabled = $false; AlreadyDisabled = $true }
    }
    if ($cfg.DryRun) {
        Write-Host "[DryRun] Would disable account $UserId."
        return [pscustomobject]@{ Disabled = $false; WouldDisable = $true; DryRun = $true }
    }
    try {
        $null = Invoke-ARGraph -Method Patch -Uri ('/users/' + $UserId) -Body @{ accountEnabled = $false }
        Write-Host "Disabled account $UserId."
        return [pscustomobject]@{ Disabled = $true }
    }
    catch {
        Write-Warning "Disabling the account failed for ${UserId}: $($_.Exception.Message)"
        return [pscustomobject]@{ Disabled = $false; Error = $_.Exception.Message }
    }
}

function Remove-ARUserLicenses {
    <#
    .SYNOPSIS
        Removes the user's DIRECTLY assigned licences. Group-based licences
        cannot be removed per-user; they are released when the group membership
        goes (see Remove-ARUserFromGroups).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    $cfg = Get-ARConfig
    try {
        $u = Invoke-ARGraph -Uri ('/users/' + $UserId + '?$select=id,licenseAssignmentStates')
        $direct = @($u.licenseAssignmentStates | Where-Object {
                $_ -and -not $_.assignedByGroup -and $_.state -in @('Active', 'ActiveWithError')
            } | ForEach-Object { $_.skuId } | Select-Object -Unique)
    }
    catch {
        Write-Warning "Reading licence assignments failed for ${UserId}: $($_.Exception.Message)"
        return [pscustomobject]@{ Removed = 0; Error = $_.Exception.Message }
    }

    if ($direct.Count -eq 0) {
        Write-Host "No directly assigned licences on $UserId."
        return [pscustomobject]@{ Removed = 0 }
    }
    if ($cfg.DryRun) {
        Write-Host "[DryRun] Would remove $($direct.Count) licence(s) from $UserId."
        return [pscustomobject]@{ Removed = 0; WouldRemove = $direct.Count; DryRun = $true }
    }
    try {
        $null = Invoke-ARGraph -Method Post -Uri ('/users/' + $UserId + '/assignLicense') -Body @{
            addLicenses = @(); removeLicenses = @($direct)
        }
        Write-Host "Removed $($direct.Count) directly assigned licence(s) from $UserId."
        return [pscustomobject]@{ Removed = $direct.Count }
    }
    catch {
        Write-Warning "Licence removal failed for ${UserId}: $($_.Exception.Message)"
        return [pscustomobject]@{ Removed = 0; Error = $_.Exception.Message }
    }
}

function Remove-ARUserFromGroups {
    <#
    .SYNOPSIS
        Removes the user from every group they are a direct member of, except
        dynamic groups (membership is rule-driven) and mail-enabled non-M365
        groups (distribution lists / mail-enabled security groups are Exchange-
        managed and cannot be modified via this Graph API).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    $cfg = Get-ARConfig
    $summary = [pscustomobject]@{ Removed = 0; SkippedDynamic = 0; SkippedExchange = 0; Errors = 0; DryRun = [bool]$cfg.DryRun }

    $groups = @()
    try {
        $memberOf = Invoke-ARGraph -Uri ('/users/' + $UserId + '/memberOf?$select=id,displayName,groupTypes,mailEnabled,securityEnabled&$top=999') -All
        $groups = @($memberOf | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' })
    }
    catch {
        Write-Warning "Listing group memberships failed for ${UserId}: $($_.Exception.Message)"
        $summary.Errors++
        return $summary
    }

    foreach ($g in $groups) {
        $groupTypes = @($g.groupTypes)
        if ($groupTypes -contains 'DynamicMembership') { $summary.SkippedDynamic++; continue }
        # Mail-enabled but not a Microsoft 365 group => Exchange distribution
        # list or mail-enabled security group; not modifiable via /members/$ref.
        if ($g.mailEnabled -and ($groupTypes -notcontains 'Unified')) { $summary.SkippedExchange++; continue }

        if ($cfg.DryRun) { $summary.Removed++; continue }
        try {
            $null = Invoke-ARGraph -Method Delete -Uri ('/groups/' + $g.id + '/members/' + $UserId + '/$ref')
            $summary.Removed++
        }
        catch { Write-Warning "Removing $UserId from group '$($g.displayName)' failed: $($_.Exception.Message)"; $summary.Errors++ }
    }
    Write-Host "Group removal for ${UserId}: removed=$($summary.Removed) dynamic=$($summary.SkippedDynamic) exchange=$($summary.SkippedExchange) errors=$($summary.Errors)."
    return $summary
}

function Invoke-ARSoftDeleteUser {
    <#
    .SYNOPSIS
        Soft deletes the account (moves it to the directory recycle bin). Must
        run AFTER every other action -- they all need the account to exist.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    $cfg = Get-ARConfig
    if ($cfg.DryRun) {
        Write-Host "[DryRun] Would soft delete user $UserId."
        return [pscustomobject]@{ Deleted = $false; DryRun = $true }
    }
    try {
        $null = Invoke-ARGraph -Method Delete -Uri ('/users/' + $UserId)
        Write-Host "Soft deleted user $UserId."
        return [pscustomobject]@{ Deleted = $true }
    }
    catch {
        Write-Warning "Soft delete failed for ${UserId}: $($_.Exception.Message)"
        return [pscustomobject]@{ Deleted = $false; Error = $_.Exception.Message }
    }
}
