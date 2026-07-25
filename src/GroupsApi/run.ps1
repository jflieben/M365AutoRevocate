using namespace System.Net

# Admin API: search Entra security groups by display-name prefix, powering the
# exclusion-group autocomplete in the web app (config tab + setup wizard).
# Protected by Easy Auth like the other admin endpoints; the lookup itself runs
# with the managed identity (Directory.Read.All).

param($Request, $TriggerMetadata)

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 6)
        })
}

try {
    $auth = Test-ARAdminRequest -Request $Request
    if (-not $auth.Ok) { Send-Json -Status $auth.Status -Object @{ error = $auth.Error }; return }

    $search = ''
    if ($Request.Query -and $Request.Query['search']) { $search = "$($Request.Query['search'])".Trim() }
    if ($search.Length -lt 2) { Send-Json -Status 200 -Object @{ items = @() }; return }

    $escaped = $search -replace "'", "''"
    $filter = [Uri]::EscapeDataString("securityEnabled eq true and startswith(displayName,'$escaped')")
    $result = Invoke-ARGraph -Uri ('/groups?$filter=' + $filter + '&$select=id,displayName&$top=10')

    $items = @($result.value | ForEach-Object { @{ id = $_.id; displayName = $_.displayName } })
    Send-Json -Status 200 -Object @{ items = $items }
}
catch {
    Write-Error "GroupsApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
