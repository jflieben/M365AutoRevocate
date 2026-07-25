using namespace System.Net

# Admin API: resume processing after the storm guard has paused it. Clears the
# latch and resets today's action counters so the run that tripped it can
# proceed. Records who resumed. Protected by Easy Auth + Test-ARAdminRequest.

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

    Initialize-ARTables
    $caller = if ($auth.Caller) { $auth.Caller } else { 'unknown' }
    $wasPaused = Test-ARPaused
    Clear-ARPaused -Actor $caller
    Write-Host "Processing resumed by $caller (was paused: $wasPaused)."
    Send-Json -Status 200 -Object @{ resumed = $true; wasPaused = $wasPaused }
}
catch {
    Write-Error "ResumeApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
