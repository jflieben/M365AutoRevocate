# Shared deployment helpers used by BOTH Deploy-M365AutoRevocate.ps1 and
# Update-M365AutoRevocate.ps1.
#
# This file reconciles the managed identity's required permissions against the
# single source of truth in permissions.json, so a new feature that needs another
# API permission or directory role is added in ONE place and picked up by both the
# full deploy and the (idempotent) update.
#
# Requires the dot-sourcing script to have already defined Invoke-Az (both scripts
# do) and az to be signed in. $PSScriptRoot below always resolves to this file's
# folder (deploy/), so it finds permissions.json regardless of who dot-sources it.

function Get-ARRequirements {
    <#
    .SYNOPSIS
        Loads permissions.json (the permission catalog) from next to the scripts.
    #>
    [CmdletBinding()] param()
    $path = Join-Path $PSScriptRoot 'permissions.json'
    if (-not (Test-Path $path)) { throw "permissions.json not found next to the deploy scripts ($path)." }
    return (Get-Content $path -Raw | ConvertFrom-Json)
}

function Invoke-ARGraphJson {
    <#
    .SYNOPSIS
        'az rest' to Microsoft Graph, parsing the JSON response. A request body is
        written to a temp file and passed as @file (inline JSON gets mangled and
        Graph rejects it). Returns the parsed object, or $null on an allowed failure.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [switch]$AllowFail
    )
    if ($null -ne $Body) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("argraph-$([Guid]::NewGuid().ToString('N')).json")
        [System.IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
        try {
            $out = Invoke-Az -AzArgs @('rest', '--method', $Method, '--uri', $Uri, '--headers', 'Content-Type=application/json', '--body', "@$tmp") -AllowFail:$AllowFail
        }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    else {
        $out = Invoke-Az -AzArgs @('rest', '--method', $Method, '--uri', $Uri) -AllowFail:$AllowFail
    }
    if (-not $out) { return $null }
    try { return ($out | Out-String | ConvertFrom-Json) } catch { return $null }
}

function Update-ARPermission {
    <#
    .SYNOPSIS
        Reconciles the managed identity's API application permissions (app roles on
        Microsoft Graph, SharePoint Online, Exchange Online) and Entra directory
        roles against permissions.json, granting whatever is missing. Idempotent, so
        it is safe to run on every deploy and update -- newly added requirements get
        applied automatically.
    .DESCRIPTION
        Returns a list of human-readable descriptions of anything it could NOT grant
        (empty = fully reconciled). Granting requires the signed-in operator to be
        Global Administrator or Privileged Role Administrator; failures are reported,
        not thrown, so an unattended update without those rights degrades gracefully.
    .PARAMETER PrincipalId
        Object id of the Function App's system-assigned managed identity (its
        service principal), which the permissions are granted TO.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PrincipalId)

    $req = Get-ARRequirements
    $failed = [System.Collections.Generic.List[string]]::new()

    # --- Application permissions (app roles) ---------------------------------
    # One read of what the identity already holds, reused for every check.
    $existing = Invoke-ARGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" -AllowFail
    $existingList = if ($existing -and $existing.value) { @($existing.value) } else { @() }

    # Resolve each referenced resource service principal once (by its well-known appId).
    $spByKey = @{}
    foreach ($key in $req.resources.PSObject.Properties.Name) {
        $meta = $req.resources.$key
        $spByKey[$key] = Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $meta.appId) -AllowFail | Out-String | ConvertFrom-Json
    }

    foreach ($role in $req.appRoles) {
        $resKey = "$($role.resource)"
        $meta = $req.resources.$resKey
        $resName = if ($meta) { $meta.displayName } else { $resKey }
        $label = "$($role.value) ($resName)"
        $sp = $spByKey[$resKey]
        if (-not $sp -or -not $sp.id) {
            Write-Warning "Could not resolve the '$resName' service principal; '$($role.value)' cannot be granted."
            $failed.Add($label); continue
        }
        $appRole = $sp.appRoles | Where-Object { $_.value -eq $role.value -and $_.allowedMemberTypes -contains 'Application' } | Select-Object -First 1
        if (-not $appRole) {
            Write-Warning "App role '$($role.value)' not found on '$resName'; skipping."
            $failed.Add($label); continue
        }
        if ($existingList | Where-Object { $_.appRoleId -eq $appRole.id -and $_.resourceId -eq $sp.id }) {
            Write-Host "Already granted: $label"
            continue
        }
        Write-Host "Granting: $label"
        $grant = Invoke-ARGraphJson -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" `
            -Body @{ principalId = $PrincipalId; resourceId = $sp.id; appRoleId = $appRole.id } -AllowFail
        if (-not $grant) {
            Write-Warning "Could not grant '$label' (needs Global Administrator / Privileged Role Administrator)."
            $failed.Add($label)
        }
    }

    # --- Entra directory roles ------------------------------------------------
    # None today; permissions.json can add them (by templateId and/or displayName)
    # for a future feature and both deploy and update will assign them here.
    foreach ($dr in @($req.directoryRoles)) {
        $name = if ($dr.displayName) { "$($dr.displayName)" } else { "$($dr.templateId)" }
        $def = $null
        if ($dr.templateId) {
            $enc = [Uri]::EscapeDataString("templateId eq '$($dr.templateId)'")
            $def = Invoke-ARGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=$enc" -AllowFail
        }
        if ((-not ($def -and $def.value)) -and $dr.displayName) {
            $enc = [Uri]::EscapeDataString("displayName eq '$($dr.displayName)'")
            $def = Invoke-ARGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=$enc" -AllowFail
        }
        $roleDef = if ($def -and $def.value) { @($def.value)[0] } else { $null }
        if (-not $roleDef) { Write-Warning "Directory role '$name' not found; skipping."; $failed.Add("directory role: $name"); continue }

        $enc = [Uri]::EscapeDataString("principalId eq '$PrincipalId' and roleDefinitionId eq '$($roleDef.id)'")
        $assigned = Invoke-ARGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=$enc" -AllowFail
        if ($assigned -and $assigned.value -and @($assigned.value).Count -gt 0) {
            Write-Host "Already assigned directory role: $name"; continue
        }
        Write-Host "Assigning directory role: $name"
        $grant = Invoke-ARGraphJson -Method POST -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' `
            -Body @{ roleDefinitionId = $roleDef.id; principalId = $PrincipalId; directoryScopeId = '/' } -AllowFail
        if (-not $grant) {
            Write-Warning "Could not assign directory role '$name' (needs Privileged Role Administrator / Global Administrator)."
            $failed.Add("directory role: $name")
        }
    }

    return $failed
}
