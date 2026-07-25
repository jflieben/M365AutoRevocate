# Exchange Online read access (RBAC for Applications) for mailbox metadata that
# Microsoft Graph does not expose: RecipientTypeDetails (SharedMailbox,
# RoomMailbox, EquipmentMailbox), keyed to the Entra object id via
# ExternalDirectoryObjectId.
#
# Why: shared/room/equipment mailboxes are routinely disabled and/or never
# signed in, but must NEVER be offboarded. The inactivity scan uses this to skip
# them. Graph has no property for mailbox type, so we read it from Exchange.
#
# How: the Exchange Online admin REST API (the same InvokeCommand backend the EXO
# PowerShell module uses) with an app-only managed-identity token for the
# outlook.office365.com resource. The managed identity needs a read role
# (the deploy grants 'View-Only Recipients'); the same service principal that
# already holds the mailbox-scoped Mail.Send. One paged call per scan (cached),
# never per user, so it stays performant.

$script:ARNonUserMbxCache = $null
$script:ARNonUserMbxCacheAt = [DateTimeOffset]::MinValue

function Get-ARExoToken {
    [CmdletBinding()] param()
    $cfg = Get-ARConfig
    return Get-ARManagedIdentityToken -Resource $cfg.ExoResource
}

function Invoke-ARExoCommand {
    <#
    .SYNOPSIS
        Runs an Exchange Online admin cmdlet over REST (InvokeCommand) and
        follows paging. Returns the concatenated 'value' array. Throws on error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CmdletName, [hashtable]$Parameters)
    $cfg = Get-ARConfig
    if ([string]::IsNullOrWhiteSpace($cfg.TenantId)) { throw 'AR_TENANT_ID is not set; cannot call Exchange Online.' }

    $postUri = '{0}/adminapi/beta/{1}/InvokeCommand' -f $cfg.ExoResource.TrimEnd('/'), $cfg.TenantId
    $bodyJson = @{ CmdletInput = @{ CmdletName = $CmdletName; Parameters = $Parameters } } | ConvertTo-Json -Depth 10 -Compress

    $results = [System.Collections.Generic.List[object]]::new()
    $uri = $postUri
    $isFirst = $true
    while ($uri) {
        $headers = @{
            Authorization  = "Bearer $(Get-ARExoToken)"
            Accept         = 'application/json'
            'Prefer'       = 'odata.maxpagesize=1000'
        }
        $rh = $null
        if ($isFirst) {
            $headers['Content-Type'] = 'application/json'
            $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $bodyJson -SkipHttpErrorCheck -StatusCodeVariable sc -ResponseHeadersVariable rh -ErrorAction Stop
            $isFirst = $false
        }
        else {
            $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable sc -ResponseHeadersVariable rh -ErrorAction Stop
        }
        if ($sc -ge 400) {
            # On a 401/403 the body is usually empty (null bytes); the real reason
            # is in the response headers. x-ms-diagnostics is the Office 365 error
            # detail (e.g. audience/role/principal problems); WWW-Authenticate
            # carries the bearer challenge.
            $bodyText = ("$resp" -replace "`0", '').Trim()
            $detail = if ($bodyText) { $bodyText } else { '(empty body)' }
            $diag = ''
            if ($rh) {
                foreach ($k in @($rh.Keys)) {
                    if ("$k" -imatch '^(x-ms-diagnostics|WWW-Authenticate|x-ms-diagnostic-info|x-calculatedbetarget|request-id)$' -and $rh[$k]) {
                        $diag += " [$k=$((@($rh[$k]) -join '; '))]"
                    }
                }
            }
            $hint = if ($sc -in 401, 403) {
                " -- HTTP $sc means Exchange rejected the token: the managed identity's service principal is likely not registered in Exchange, or lacks the 'View-Only Recipients' role (RBAC for Applications; a fresh grant can take ~30 min). Confirm the deploy's 'Exchange Online (mailbox-scoped mail)' step succeeded. See docs/permissions.md."
            }
            else { '' }
            throw "Exchange Online $CmdletName failed (HTTP $sc): $detail$diag$hint"
        }
        if ($resp -and $resp.PSObject.Properties['value'] -and $resp.value) { foreach ($v in $resp.value) { $results.Add($v) } }
        $uri = if ($resp) { $resp.'@odata.nextLink' } else { $null }
    }
    return $results
}

function Get-ARNonUserMailboxObjectIds {
    <#
    .SYNOPSIS
        Hashtable (Entra object id -> RecipientTypeDetails) of every shared, room
        and equipment mailbox in the tenant. Cached per worker for ~60 min
        (mailbox types change rarely). Throws if Exchange cannot be read.
    #>
    [CmdletBinding()] param([switch]$Refresh)
    if (-not $Refresh -and $null -ne $script:ARNonUserMbxCache -and
        ([DateTimeOffset]::UtcNow - $script:ARNonUserMbxCacheAt).TotalMinutes -lt 60) {
        return $script:ARNonUserMbxCache
    }
    $set = @{}
    # The InvokeCommand REST endpoint runs SERVER-side Exchange cmdlets, so it is
    # Get-Mailbox (not the client-only Get-EXOMailbox, which the module maps to a
    # different REST resource). Get-Mailbox has no -Properties parameter; it
    # returns ExternalDirectoryObjectId and RecipientTypeDetails by default. The
    # RecipientTypeDetails filter keeps the result set to just these mailbox types.
    $mbx = Invoke-ARExoCommand -CmdletName 'Get-Mailbox' -Parameters @{
        RecipientTypeDetails = @('SharedMailbox', 'RoomMailbox', 'EquipmentMailbox')
        ResultSize           = 'Unlimited'
    }
    foreach ($m in $mbx) {
        $oid = $m.PSObject.Properties['ExternalDirectoryObjectId'].Value
        if ($oid) { $set["$oid"] = "$($m.RecipientTypeDetails)" }
    }
    $script:ARNonUserMbxCache = $set
    $script:ARNonUserMbxCacheAt = [DateTimeOffset]::UtcNow
    Write-Host "Exchange mailbox-type exclusion: $($set.Count) shared/room/equipment mailbox(es)."
    return $set
}
