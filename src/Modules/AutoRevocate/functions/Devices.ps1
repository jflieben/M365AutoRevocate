# Device offboarding actions: disable and/or delete the Entra devices a departing
# user owns (registered/joined). Graph REST, DryRun-aware, returning small
# summaries for the audit record.
#
# These apply at every trigger (inactive, disable, delete). At 'inactive' and
# 'disable' the account is live, so the owned-device set is read straight from
# Graph. At 'delete' the user object is gone and /users/{id}/ownedDevices no
# longer resolves, so the set comes from the directory snapshot that captured it
# before deletion (see Snapshot.ps1). Device objects survive user deletion, so
# disabling/deleting them by their cached object id still works.
#
# Needs the Graph 'Device.ReadWrite.All' app role (see deploy/permissions.json).

function Get-ARUserOwnedDevices {
    <#
    .SYNOPSIS
        Returns the Entra devices the user owns. At 'inactive'/'disable' read live
        from Graph; at 'delete' from the directory snapshot (Graph has dropped the
        ownership by then). Each item: { Id; DisplayName; DeviceId; AccountEnabled;
        OperatingSystem }.
    #>
    [CmdletBinding()] param([string]$UserId, $CacheEntry, [string]$Trigger = 'delete')
    $list = [System.Collections.Generic.List[object]]::new()

    if ($Trigger -in @('inactive', 'disable') -and $UserId) {
        try {
            $owned = Invoke-ARGraph -Uri ('/users/' + $UserId + '/ownedDevices/microsoft.graph.device?$select=id,displayName,deviceId,accountEnabled,operatingSystem&$top=100') -All
            foreach ($d in $owned) {
                if (-not $d.id) { continue }
                $list.Add([pscustomobject]@{ Id = $d.id; DisplayName = $d.displayName; DeviceId = $d.deviceId; AccountEnabled = $d.accountEnabled; OperatingSystem = $d.operatingSystem })
            }
            return $list
        }
        catch { Write-Warning "Live ownedDevices lookup failed for $UserId; trying snapshot: $($_.Exception.Message)" }
    }

    $json = if ($CacheEntry) { $CacheEntry.PSObject.Properties['OwnedDevices'].Value } else { $null }
    if ($json) {
        try {
            foreach ($d in ($json | ConvertFrom-Json)) {
                if (-not $d.id) { continue }
                $list.Add([pscustomobject]@{ Id = $d.id; DisplayName = $d.displayName; DeviceId = $d.deviceId; AccountEnabled = $d.accountEnabled; OperatingSystem = $d.operatingSystem })
            }
        }
        catch { Write-Warning "Could not parse cached OwnedDevices for $UserId`: $($_.Exception.Message)" }
    }
    return $list
}

function Disable-ARUserDevices {
    <#
    .SYNOPSIS
        Blocks sign-in on each owned device (PATCH accountEnabled = false).
        Already-disabled devices are left untouched and counted separately.
    #>
    [CmdletBinding()] param([object[]]$Devices)
    $cfg = Get-ARConfig
    $summary = [pscustomobject]@{ Total = 0; Disabled = 0; AlreadyDisabled = 0; Errors = 0; DryRun = [bool]$cfg.DryRun }
    if (-not $Devices -or $Devices.Count -eq 0) { Write-Host 'disableDevices: user owns no devices; skipping.'; return $summary }

    foreach ($d in $Devices) {
        if (-not $d.Id) { continue }
        $summary.Total++
        if ($d.AccountEnabled -eq $false) { $summary.AlreadyDisabled++; continue }
        if ($cfg.DryRun) { $summary.Disabled++; continue }
        try {
            $null = Invoke-ARGraph -Method Patch -Uri ('/devices/' + $d.Id) -Body @{ accountEnabled = $false }
            $summary.Disabled++
        }
        catch { Write-Warning "Disabling device '$($d.DisplayName)' ($($d.Id)) failed: $($_.Exception.Message)"; $summary.Errors++ }
    }
    Write-Host "Device disable: total=$($summary.Total) disabled=$($summary.Disabled) alreadyDisabled=$($summary.AlreadyDisabled) errors=$($summary.Errors)."
    return $summary
}

function Remove-ARUserDevices {
    <#
    .SYNOPSIS
        Permanently deletes each owned device object (DELETE /devices/{id}).
    #>
    [CmdletBinding()] param([object[]]$Devices)
    $cfg = Get-ARConfig
    $summary = [pscustomobject]@{ Total = 0; Deleted = 0; Errors = 0; DryRun = [bool]$cfg.DryRun }
    if (-not $Devices -or $Devices.Count -eq 0) { Write-Host 'deleteDevices: user owns no devices; skipping.'; return $summary }

    foreach ($d in $Devices) {
        if (-not $d.Id) { continue }
        $summary.Total++
        if ($cfg.DryRun) { $summary.Deleted++; continue }
        try {
            $null = Invoke-ARGraph -Method Delete -Uri ('/devices/' + $d.Id)
            $summary.Deleted++
        }
        catch { Write-Warning "Deleting device '$($d.DisplayName)' ($($d.Id)) failed: $($_.Exception.Message)"; $summary.Errors++ }
    }
    Write-Host "Device delete: total=$($summary.Total) deleted=$($summary.Deleted) errors=$($summary.Errors)."
    return $summary
}
