# Permission self-check.
#
# Surfaces "roles this configuration needs vs roles the managed identity actually
# holds", so an operator who enables an action whose Graph permission was never
# consented sees a clear nudge instead of a silent runtime failure. Read-only.

$script:ARMiOid = $null

function Get-ARManagedIdentityObjectId {
    <#
    .SYNOPSIS
        The managed identity's own service-principal object id, taken from the
        'oid' claim of a token it issued. Cached per worker.
    #>
    [CmdletBinding()] param()
    if ($script:ARMiOid) { return $script:ARMiOid }
    $token = Get-ARGraphToken
    $parts = $token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    try {
        $payload = [Text.Encoding]::UTF8.GetString((ConvertFrom-ARBase64Url $parts[1])) | ConvertFrom-Json
        $script:ARMiOid = $payload.oid
    }
    catch { return $null }
    return $script:ARMiOid
}

$script:ARMiAppId = $null

function Get-ARManagedIdentityAppId {
    <#
    .SYNOPSIS
        The managed identity's application (client) id, from the 'appid' claim of
        a token it issued. This is the value an admin passes to
        New-PowerAppManagementApp to authorise the tool in Power Platform. Cached.
    #>
    [CmdletBinding()] param()
    if ($script:ARMiAppId) { return $script:ARMiAppId }
    $token = Get-ARGraphToken
    $parts = $token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    try {
        $payload = [Text.Encoding]::UTF8.GetString((ConvertFrom-ARBase64Url $parts[1])) | ConvertFrom-Json
        $script:ARMiAppId = if ($payload.PSObject.Properties['appid']) { $payload.appid } else { $payload.azp }
    }
    catch { return $null }
    return $script:ARMiAppId
}

function Get-ARFeatureRoleMap {
    # Each configurable feature -> the Graph app role(s) it needs at runtime.
    # (notifyManager sends via Exchange RBAC, not a Graph role, so it maps to none.)
    return @{
        unshareOneDrive  = @('Sites.FullControl.All')
        notifyManager    = @()
        disableDevices   = @('Device.ReadWrite.All')
        deleteDevices    = @('Device.ReadWrite.All')
        revokeSessions   = @('User.ReadWrite.All')
        autoReply        = @('MailboxSettings.ReadWrite')
        forward          = @('MailboxSettings.ReadWrite')
        cancelMeetings   = @('Calendars.ReadWrite')
        disableAccount   = @('User.ReadWrite.All')
        removeLicenses   = @('User.ReadWrite.All')
        removeFromGroups = @('GroupMember.ReadWrite.All')
        softDeleteUser   = @('User.DeleteRestore.All')
        # Power Platform actions are NOT gated by a Graph app role; access is
        # granted out of band with New-PowerAppManagementApp. The web app detects
        # it separately (Get-ARPowerPlatformStatus), so they map to no Graph role.
        disablePowerPlatform = @()
        deletePowerPlatform  = @()
        reownPowerPlatform   = @()
    }
}

function Get-ARPermissionStatus {
    <#
    .SYNOPSIS
        Returns @{ role; granted } for every Graph app role the current config
        requires, so the web app can nudge when something is enabled but not
        consented.
    #>
    [CmdletBinding()] param($FeatureConfig)
    if (-not $FeatureConfig) { $FeatureConfig = Get-ARFeatureConfig }

    $map = Get-ARFeatureRoleMap
    $required = [System.Collections.Generic.HashSet[string]]::new()
    [void]$required.Add('Directory.Read.All')   # always needed (subscription + exclusion group)
    foreach ($f in Get-ARFeatureCatalog) {
        $entry = $FeatureConfig.features.$($f.key)
        if ($entry -and ([bool]$entry.atInactive -or [bool]$entry.atDisable -or [bool]$entry.atDelete)) {
            foreach ($r in $map[$f.key]) { [void]$required.Add($r) }
        }
    }
    if ($FeatureConfig.inactive.enabled) { [void]$required.Add('AuditLog.Read.All') }

    $granted = @{}
    try {
        $oid = Get-ARManagedIdentityObjectId
        if ($oid) {
            $graphSp = Invoke-ARGraph -Uri "/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?`$select=id,appRoles"
            $roleById = @{}
            foreach ($ar in $graphSp.appRoles) { $roleById["$($ar.id)"] = $ar.value }
            $assigns = Invoke-ARGraph -Uri "/servicePrincipals/$oid/appRoleAssignments?`$select=appRoleId" -All
            foreach ($a in $assigns) { if ($roleById.ContainsKey("$($a.appRoleId)")) { $granted[$roleById["$($a.appRoleId)"]] = $true } }
        }
    }
    catch { Write-Warning "Could not read granted app roles: $($_.Exception.Message)" }

    $out = foreach ($r in ($required | Sort-Object)) { [pscustomobject]@{ role = $r; granted = [bool]$granted[$r] } }
    return @($out)
}
