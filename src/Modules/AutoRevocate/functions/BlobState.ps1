# Blob storage access (managed identity / AAD), used for the editable config
# blob that the admin web app reads and writes.

function Invoke-ARBlob {
    <#
    .SYNOPSIS
        Low-level Azure Blob REST call with managed-identity (AAD) auth.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,   # e.g. "container/blob.json" or "container?restype=container"
        [ValidateSet('Get', 'Put', 'Delete', 'Head')][string]$Method = 'Get',
        [string]$Body,
        [hashtable]$ExtraHeaders
    )
    $cfg = Get-ARConfig
    $uri = '{0}/{1}' -f $cfg.BlobEndpoint, $Path

    $headers = @{
        Authorization  = "Bearer $(Get-ARStorageToken)"
        'x-ms-version' = '2021-08-06'
        'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
    }
    if ($ExtraHeaders) { $ExtraHeaders.GetEnumerator() | ForEach-Object { $headers[$_.Key] = $_.Value } }

    $params = @{
        Method                  = $Method
        Uri                     = $uri
        Headers                 = $headers
        ErrorAction             = 'Stop'
        StatusCodeVariable      = 'statusCode'
        SkipHttpErrorCheck      = $true
        ResponseHeadersVariable = 'respHeaders'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) { $params.Body = $Body }

    $response = Invoke-RestMethod @params
    return [pscustomobject]@{ StatusCode = $statusCode; Body = $response; Headers = $respHeaders }
}

function Initialize-ARConfigContainer {
    [CmdletBinding()] param()
    $cfg = Get-ARConfig
    $r = Invoke-ARBlob -Method Put -Path ("{0}?restype=container" -f $cfg.ConfigContainer) -ExtraHeaders @{ 'Content-Length' = '0' }
    if ($r.StatusCode -ge 400 -and $r.StatusCode -ne 409) {
        throw "Failed to create config container '$($cfg.ConfigContainer)' (HTTP $($r.StatusCode))."
    }
}

function Get-ARBlobText {
    <#
    .SYNOPSIS
        Returns the text content of a blob in the config container, or $null (404).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-ARConfig
    $r = Invoke-ARBlob -Method Get -Path ('{0}/{1}' -f $cfg.ConfigContainer, $Name)
    if ($r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -ge 400) { throw "Reading blob '$Name' failed (HTTP $($r.StatusCode))." }
    if ($r.Body -is [string]) { return $r.Body }
    return ($r.Body | ConvertTo-Json -Depth 30)   # ConvertFrom auto-parsed JSON; re-serialise to text
}

function Set-ARBlobText {
    <#
    .SYNOPSIS
        Writes (overwrites) a block blob in the config container.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Content)
    $cfg = Get-ARConfig
    $r = Invoke-ARBlob -Method Put -Path ('{0}/{1}' -f $cfg.ConfigContainer, $Name) -Body $Content -ExtraHeaders @{
        'x-ms-blob-type' = 'BlockBlob'
        'Content-Type'   = 'application/json'
    }
    if ($r.StatusCode -ge 400) { throw "Writing blob '$Name' failed (HTTP $($r.StatusCode))." }
}
