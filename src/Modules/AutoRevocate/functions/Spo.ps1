# SharePoint Online tenant-admin operations (raw CSOM over REST, managed
# identity, no PnP/SPO modules).
#
# Unsharing a OneDrive is done the way an admin would: set the personal site's
# SharingCapability to Disabled, one flag on the site collection. Existing
# sharing links stop resolving and nothing new can be shared. This is O(1) and
# replaces walking every item (which cannot finish within a function timeout on
# a large drive); there is no per-item fallback -- without the SharePoint
# 'Sites.FullControl.All' app role this action fails and is recorded as such.
#
# Requires an app-only token for the tenant ADMIN host with the SharePoint
# 'Sites.FullControl.All' APPLICATION role, granted on the 'Office 365
# SharePoint Online' service principal (appId 00000003-0000-0ff1-ce00-
# 000000000000) by the deploy script. This is a SharePoint role, distinct from
# the Graph app role of the same name.

function Get-ARSharePointAdminHost {
    <#
    .SYNOPSIS
        Returns the tenant admin host, e.g. 'contoso-admin.sharepoint.com'.
    #>
    [CmdletBinding()] param()
    return ((Get-ARSharePointMyHost) -replace '-my\.', '-admin.')
}

function Get-ARPersonalSiteUrl {
    <#
    .SYNOPSIS
        Reduces a OneDrive drive/web URL to its site-collection URL, e.g.
        https://contoso-my.sharepoint.com/personal/user_contoso_com.
    #>
    [CmdletBinding()] param([string]$WebUrl)
    if (-not $WebUrl) { return $null }
    try {
        $u = [Uri]$WebUrl
        $segs = @($u.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ })
        if ($segs.Count -ge 2 -and $segs[0] -ieq 'personal') {
            return ('{0}://{1}/personal/{2}' -f $u.Scheme, $u.Host, $segs[1])
        }
        return $null
    }
    catch { return $null }
}

function Set-ARSiteSharingDisabled {
    <#
    .SYNOPSIS
        Disables all sharing on one site collection (equivalent of
        Set-SPOSite -SharingCapability Disabled). Throws on failure so the
        caller can record the error (there is no per-item fallback).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$SiteUrl)
    $cfg = Get-ARConfig
    if ($cfg.DryRun) {
        Write-Host "[DryRun] Would disable sharing on $SiteUrl."
        return [pscustomobject]@{ SharingDisabled = $true; DryRun = $true; SiteUrl = $SiteUrl }
    }

    $adminHost = Get-ARSharePointAdminHost
    $token = Get-ARManagedIdentityToken -Resource "https://$adminHost"
    $escapedUrl = [System.Security.SecurityElement]::Escape($SiteUrl)

    # CSOM: Tenant.GetSitePropertiesByUrl(url, true) -> SharingCapability = 0
    # (Disabled) -> Update(). The Tenant CSOM type id is a well-known constant.
    $xml = '<Request AddExpandoFieldTypeSuffix="true" SchemaVersion="15.0.0.0" LibraryVersion="16.0.0.0" ApplicationName="M365AutoRevocate" xmlns="http://schemas.microsoft.com/sharepoint/clientquery/2009">' +
           '<Actions><ObjectPath Id="2" ObjectPathId="1" /><ObjectPath Id="4" ObjectPathId="3" />' +
           '<SetProperty Id="5" ObjectPathId="3" Name="SharingCapability"><Parameter Type="Enum">0</Parameter></SetProperty>' +
           '<Method Name="Update" Id="6" ObjectPathId="3" /></Actions>' +
           '<ObjectPaths><Constructor Id="1" TypeId="{268004ae-ef6b-4e9b-8425-127220d84719}" />' +
           '<Method Id="3" ParentId="1" Name="GetSitePropertiesByUrl"><Parameters>' +
           "<Parameter Type=`"String`">$escapedUrl</Parameter><Parameter Type=`"Boolean`">true</Parameter>" +
           '</Parameters></Method></ObjectPaths></Request>'

    $resp = Invoke-RestMethod -Method Post -Uri "https://$adminHost/_vti_bin/client.svc/ProcessQuery" `
        -Headers @{ Authorization = "Bearer $token" } -ContentType 'text/xml' -Body $xml -ErrorAction Stop

    # ProcessQuery answers with a JSON array whose first element carries
    # ErrorInfo when the batch failed.
    $first = $resp | Select-Object -First 1
    if ($first -and $first.ErrorInfo) {
        throw "SharePoint rejected the sharing change on $SiteUrl`: $($first.ErrorInfo.ErrorMessage)"
    }
    Write-Host "Sharing disabled on $SiteUrl (site-level flag)."
    return [pscustomobject]@{ SharingDisabled = $true; SiteUrl = $SiteUrl }
}
