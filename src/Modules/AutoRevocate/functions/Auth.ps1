# Defense-in-depth authentication for the admin API.
#
# App Service Easy Auth sits in front of these functions and is the primary
# gate. But Easy Auth has failed silently before (a bad az call left the API
# open once already), and an operator could disable it later. So every admin
# function ALSO validates the caller itself, and fails CLOSED. That turns
# "Easy Auth misconfigured" from silent tenant exposure into a visible 401.
#
# The real check is a full RS256 validation of the delegated bearer token
# (signature against the tenant's JWKS, audience = our API, issuer = our
# tenant, not expired). An attacker cannot forge that even if Easy Auth is off
# and they spoof the X-MS-CLIENT-PRINCIPAL header. The principal header is used
# only to name the caller for the audit log.

$script:ARJwksCache = $null

function ConvertFrom-ARBase64Url {
    param([Parameter(Mandatory)][string]$Value)
    $s = $Value.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } 1 { $s += '===' } }
    return [Convert]::FromBase64String($s)
}

function Get-ARJwks {
    [CmdletBinding()] param([switch]$Refresh)
    if ($script:ARJwksCache -and -not $Refresh) { return $script:ARJwksCache }
    $cfg = Get-ARConfig
    $uri = '{0}/{1}/discovery/v2.0/keys' -f $cfg.LoginResource.TrimEnd('/'), $cfg.TenantId
    $resp = Invoke-RestMethod -Method Get -Uri $uri -ErrorAction Stop
    $script:ARJwksCache = $resp.keys
    return $script:ARJwksCache
}

function Test-ARJwt {
    <#
    .SYNOPSIS
        Validates a JWT access token (RS256) against the tenant JWKS and the
        expected audience/issuer. Returns @{ Valid; Caller; Error }.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Token)
    $cfg = Get-ARConfig
    $parts = $Token.Split('.')
    if ($parts.Count -ne 3) { return @{ Valid = $false; Error = 'malformed token' } }

    try {
        $header  = [Text.Encoding]::UTF8.GetString((ConvertFrom-ARBase64Url $parts[0])) | ConvertFrom-Json
        $payload = [Text.Encoding]::UTF8.GetString((ConvertFrom-ARBase64Url $parts[1])) | ConvertFrom-Json
    }
    catch { return @{ Valid = $false; Error = 'unparseable token' } }

    if ($header.alg -ne 'RS256') { return @{ Valid = $false; Error = "unexpected alg '$($header.alg)'" } }

    # Audience must be our API (accept both the api:// URI and the bare client id).
    $aud = "$($payload.aud)"
    $okAud = @("api://$($cfg.AdminClientId)", "$($cfg.AdminClientId)") -contains $aud
    if (-not $okAud) { return @{ Valid = $false; Error = "wrong audience '$aud'" } }

    # Issuer must be our tenant (v1 sts.windows.net or v2 login endpoint).
    $iss = "$($payload.iss)"
    if ($iss -notmatch [regex]::Escape($cfg.TenantId)) { return @{ Valid = $false; Error = "wrong issuer '$iss'" } }

    # Expiry / not-before (allow 5 min clock skew).
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($payload.exp -and [long]$payload.exp -lt ($now - 300)) { return @{ Valid = $false; Error = 'token expired' } }
    if ($payload.nbf -and [long]$payload.nbf -gt ($now + 300)) { return @{ Valid = $false; Error = 'token not yet valid' } }

    # Signature: find the signing key by kid, verify over header.payload.
    $signed = [Text.Encoding]::ASCII.GetBytes($parts[0] + '.' + $parts[1])
    $sig    = ConvertFrom-ARBase64Url $parts[2]
    $verified = $false
    foreach ($refresh in @($false, $true)) {
        $keys = Get-ARJwks -Refresh:$refresh
        $jwk = $keys | Where-Object { $_.kid -eq $header.kid } | Select-Object -First 1
        if (-not $jwk) { continue }
        try {
            $rsa = [System.Security.Cryptography.RSA]::Create()
            $rp = [System.Security.Cryptography.RSAParameters]::new()
            $rp.Modulus  = ConvertFrom-ARBase64Url $jwk.n
            $rp.Exponent = ConvertFrom-ARBase64Url $jwk.e
            $rsa.ImportParameters($rp)
            $verified = $rsa.VerifyData($signed, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        }
        catch { return @{ Valid = $false; Error = "signature check error: $($_.Exception.Message)" } }
        if ($verified) { break }
        if (-not $refresh) { continue }  # kid found but bad sig: no point retrying
    }
    if (-not $verified) { return @{ Valid = $false; Error = 'signature not verified (unknown key or bad signature)' } }

    $caller = @($payload.preferred_username, $payload.upn, $payload.unique_name, $payload.name) |
        Where-Object { $_ } | Select-Object -First 1
    return @{ Valid = $true; Caller = "$caller" }
}

function Get-ARClientPrincipalName {
    <#
    .SYNOPSIS
        Best-effort caller name from the Easy Auth principal header (audit log).
    #>
    [CmdletBinding()] param($Request)
    if (-not $Request.Headers) { return $null }
    foreach ($h in 'x-ms-client-principal-name', 'X-MS-CLIENT-PRINCIPAL-NAME') {
        if ($Request.Headers[$h]) { return $Request.Headers[$h] }
    }
    foreach ($h in 'x-ms-client-principal', 'X-MS-CLIENT-PRINCIPAL') {
        if (-not $Request.Headers[$h]) { continue }
        try {
            $principal = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Request.Headers[$h])) | ConvertFrom-Json
            foreach ($type in 'preferred_username', 'upn', 'unique_name', 'name', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn') {
                $claim = $principal.claims | Where-Object { $_.typ -eq $type } | Select-Object -First 1
                if ($claim.val) { return $claim.val }
            }
        }
        catch { Write-Warning "Could not decode the client principal header: $($_.Exception.Message)" }
    }
    return $null
}

function Get-ARBearerToken {
    [CmdletBinding()] param($Request)
    if (-not $Request.Headers) { return $null }
    foreach ($h in 'authorization', 'Authorization') {
        $v = $Request.Headers[$h]
        if ($v -and "$v" -match '^\s*Bearer\s+(.+)$') { return $Matches[1].Trim() }
    }
    return $null
}

function Test-ARAdminRequest {
    <#
    .SYNOPSIS
        The gate every admin function calls first. Returns
        @{ Ok; Status; Error; Caller }. Fails CLOSED.
    #>
    [CmdletBinding()] param($Request)
    $cfg = Get-ARConfig
    $principalName = Get-ARClientPrincipalName -Request $Request

    # When the API auth ids are configured (the deploy sets them), the JWT is
    # the authoritative check -- valid even if Easy Auth were disabled.
    if ($cfg.AdminClientId -and $cfg.TenantId) {
        $token = Get-ARBearerToken -Request $Request
        if (-not $token) {
            return @{ Ok = $false; Status = 401; Error = 'No bearer token presented.'; Caller = $principalName }
        }
        $res = Test-ARJwt -Token $token
        if (-not $res.Valid) {
            Write-Warning "Admin request rejected: $($res.Error)."
            return @{ Ok = $false; Status = 401; Error = 'Invalid or unauthorised token.'; Caller = $principalName }
        }
        $caller = if ($res.Caller) { $res.Caller } elseif ($principalName) { $principalName } else { 'unknown' }
        return @{ Ok = $true; Status = 200; Caller = $caller }
    }

    # No API auth ids configured: fall back to requiring the Easy Auth principal
    # header (Easy Auth alone). Log loudly -- this is the weaker posture.
    Write-Warning 'AR_ADMIN_CLIENT_ID / AR_TENANT_ID not configured; relying on Easy Auth alone (no in-function token validation).'
    if (-not $principalName) {
        return @{ Ok = $false; Status = 401; Error = 'Not authenticated (no Easy Auth principal).'; Caller = $null }
    }
    return @{ Ok = $true; Status = 200; Caller = $principalName }
}
