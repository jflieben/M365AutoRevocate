# Microsoft Graph access using the Function App's managed identity.
#
# We deliberately avoid the Microsoft.Graph SDK modules. Tokens come straight
# from the App Service managed-identity endpoint; Graph is called over REST.

$script:ARTokenCache = @{}   # resource -> @{ Token = ...; ExpiresOn = [datetimeoffset] }

function Get-ARManagedIdentityToken {
    <#
    .SYNOPSIS
        Acquires an access token for a resource from the managed identity.
    .DESCRIPTION
        Uses the App Service / Functions identity endpoint (IDENTITY_ENDPOINT +
        IDENTITY_HEADER). Tokens are cached in-process until ~5 min before expiry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Resource
    )

    $cached = $script:ARTokenCache[$Resource]
    if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        return $cached.Token
    }

    $endpoint = [Environment]::GetEnvironmentVariable('IDENTITY_ENDPOINT')
    $header   = [Environment]::GetEnvironmentVariable('IDENTITY_HEADER')
    if ([string]::IsNullOrWhiteSpace($endpoint) -or [string]::IsNullOrWhiteSpace($header)) {
        throw 'Managed identity is not available (IDENTITY_ENDPOINT / IDENTITY_HEADER missing). Ensure a system-assigned identity is enabled on the Function App.'
    }

    $uri = '{0}?resource={1}&api-version=2019-08-01' -f $endpoint, [Uri]::EscapeDataString($Resource)
    try {
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $header } -ErrorAction Stop
    }
    catch {
        throw "Failed to acquire a managed-identity token for '$Resource': $($_.Exception.Message)"
    }

    $expiresOn = [DateTimeOffset]::FromUnixTimeSeconds([long]$response.expires_on)
    $script:ARTokenCache[$Resource] = @{ Token = $response.access_token; ExpiresOn = $expiresOn }
    return $response.access_token
}

function Get-ARGraphToken {
    [CmdletBinding()] param()
    $cfg = Get-ARConfig
    return Get-ARManagedIdentityToken -Resource $cfg.GraphResource
}

function Invoke-ARGraph {
    <#
    .SYNOPSIS
        Calls Microsoft Graph with managed-identity auth, paging and throttling
        handled.
    .PARAMETER Uri
        Absolute Graph URL, or a path relative to the API root (e.g. '/users').
    .PARAMETER All
        Follow @odata.nextLink and return the concatenated 'value' collection.
    .PARAMETER Raw
        Return the HTTP response object instead of the parsed body (used to read
        status codes, e.g. distinguishing 404 from 200).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('Get', 'Post', 'Patch', 'Put', 'Delete')][string]$Method = 'Get',
        $Body,
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'v1.0',
        [switch]$All,
        [switch]$Raw,
        [int]$MaxRetries = 5
    )

    $cfg = Get-ARConfig
    if ($Uri -notmatch '^https?://') {
        $Uri = '{0}/{1}/{2}' -f $cfg.GraphResource, $ApiVersion, $Uri.TrimStart('/')
    }

    $results = [System.Collections.Generic.List[object]]::new()

    while ($true) {
        $headers = @{
            Authorization    = "Bearer $(Get-ARGraphToken)"
            'Content-Type'   = 'application/json'
            ConsistencyLevel = 'eventual'
        }

        $params = @{
            Method                  = $Method
            Uri                     = $Uri
            Headers                 = $headers
            ErrorAction             = 'Stop'
            StatusCodeVariable      = 'statusCode'
            SkipHttpErrorCheck      = $true
            ResponseHeadersVariable = 'respHeaders'
        }
        if ($null -ne $Body) {
            $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        }

        $attempt = 0
        while ($true) {
            $attempt++
            $response = Invoke-RestMethod @params

            # Throttling / transient server errors: honour Retry-After.
            if ($statusCode -in @(429, 503, 504, 500) -and $attempt -le $MaxRetries) {
                $retryAfter = 0
                if ($respHeaders -and $respHeaders['Retry-After']) {
                    [void][int]::TryParse(($respHeaders['Retry-After'] | Select-Object -First 1), [ref]$retryAfter)
                }
                if ($retryAfter -le 0) { $retryAfter = [Math]::Min(60, [Math]::Pow(2, $attempt)) }
                Write-Warning "Graph returned $statusCode for $Method $Uri; retrying in ${retryAfter}s (attempt $attempt/$MaxRetries)."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            break
        }

        if ($Raw) {
            return [pscustomobject]@{ StatusCode = $statusCode; Body = $response; Headers = $respHeaders }
        }

        if ($statusCode -ge 400) {
            $detail = if ($response) { ($response | ConvertTo-Json -Depth 8 -Compress) } else { '(no body)' }
            throw "Graph $Method $Uri failed with HTTP $statusCode`: $detail"
        }

        if ($All -and $response -and ($response.PSObject.Properties.Name -contains 'value')) {
            foreach ($item in $response.value) { $results.Add($item) }
            $next = $response.'@odata.nextLink'
            if ($next) { $Uri = $next; continue }
            return $results
        }

        return $response
    }
}

function Get-ARSharePointMyHost {
    <#
    .SYNOPSIS
        Returns the tenant's OneDrive host, e.g. 'contoso-my.sharepoint.com'.
    .DESCRIPTION
        Derived from /sites/root so we never need the tenant name in config.
        Cached for the life of the worker.
    #>
    [CmdletBinding()] param()
    if ($script:ARMyHost) { return $script:ARMyHost }

    $root = Invoke-ARGraph -Uri '/sites/root?$select=webUrl'
    if (-not $root.webUrl) { throw 'Could not resolve /sites/root to determine the OneDrive host.' }
    $rootHost = ([Uri]$root.webUrl).Host                       # contoso.sharepoint.com
    $tenant   = $rootHost.Split('.')[0]                        # contoso
    $suffix   = $rootHost.Substring($tenant.Length)            # .sharepoint.com
    $script:ARMyHost = '{0}-my{1}' -f $tenant, $suffix         # contoso-my.sharepoint.com
    return $script:ARMyHost
}
