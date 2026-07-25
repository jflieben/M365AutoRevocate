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

function Get-ARFeatureRoleMap {
    # Each configurable feature -> the Graph app role(s) it needs at runtime.
    # (notifyManager sends via Exchange RBAC, not a Graph role, so it maps to none.)
    return @{
        unshareOneDrive  = @('Sites.FullControl.All')
        notifyManager    = @()
        revokeSessions   = @('User.ReadWrite.All')
        autoReply        = @('MailboxSettings.ReadWrite')
        forward          = @('MailboxSettings.ReadWrite')
        cancelMeetings   = @('Calendars.ReadWrite')
        disableAccount   = @('User.ReadWrite.All')
        removeLicenses   = @('User.ReadWrite.All')
        removeFromGroups = @('GroupMember.ReadWrite.All')
        softDeleteUser   = @('User.DeleteRestore.All')
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
