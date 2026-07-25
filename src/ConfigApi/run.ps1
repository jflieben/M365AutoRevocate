using namespace System.Net

# Admin API: read (GET) and save (POST) the behavioural config.
#
# Authorisation is enforced by App Service Easy Auth in front of this function
# AND, defense in depth, by Test-ARAdminRequest here (validates the delegated
# bearer token itself and fails closed). authLevel is 'anonymous' only in the
# Functions sense. We record who made the change for the audit log.
#
# The response carries firstRun=true until the first save, which drives the
# web app's setup wizard.

param($Request, $TriggerMetadata)

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 12)
        })
}

try {
    $auth = Test-ARAdminRequest -Request $Request
    if (-not $auth.Ok) { Send-Json -Status $auth.Status -Object @{ error = $auth.Error }; return }

    Initialize-ARTables   # inside try so storage/config errors surface in the response

    if ($Request.Method -eq 'POST') {
        $raw = $Request.Body
        if ($raw -is [string]) { $raw = $raw | ConvertFrom-Json }

        # --- Validate emails up front (400, not a silent coercion) -------------
        $svc = "$($raw.servicedeskEmail)".Trim()
        if (-not (Test-AREmailAddress -Address $svc)) {
            Send-Json -Status 400 -Object @{ error = "Service desk address '$svc' is not a valid email." }; return
        }

        # Forward address: valid syntax, and (unless external forwarding is
        # explicitly allowed) it must be on one of the tenant's VERIFIED domains.
        # The forward rule is the tool's highest-risk exfiltration surface.
        $fwd = if ($raw.features -and $raw.features.forward) { "$($raw.features.forward.address)".Trim() } else { '' }
        $fwdEnabled = $raw.features -and $raw.features.forward -and ([bool]$raw.features.forward.atInactive -or [bool]$raw.features.forward.atDisable)
        if ($fwd) {
            if (-not (Test-AREmailAddress -Address $fwd)) {
                Send-Json -Status 400 -Object @{ error = "Forward-to address '$fwd' is not a valid email." }; return
            }
            if ($fwdEnabled -and -not [bool]$raw.allowExternalForward) {
                $fwdDomain = ($fwd -split '@')[-1].ToLowerInvariant()
                $verified = @()
                try {
                    $d = Invoke-ARGraph -Uri '/domains?$select=id,isVerified' -All
                    $verified = @($d | Where-Object { $_.isVerified } | ForEach-Object { "$($_.id)".ToLowerInvariant() })
                }
                catch { Write-Warning "Could not read tenant domains for forward validation: $($_.Exception.Message)" }
                if ($verified.Count -gt 0 -and $fwdDomain -notin $verified) {
                    Send-Json -Status 400 -Object @{ error = "Forward-to domain '$fwdDomain' is not a verified tenant domain. Enable 'allow external forwarding' deliberately if this is intended." }
                    return
                }
            }
        }

        # --- Resolve the exclusion group by OBJECT ID --------------------------
        # The exclusion group is GLOBAL (it shields break-glass/service accounts
        # from every trigger, not just inactivity), so it is resolved whenever a
        # group is supplied, regardless of whether inactive monitoring is on.
        # Display names are NOT unique in Entra, so the id is authoritative. The
        # web app submits the id it selected; we verify it exists and is a
        # security group, and echo the current display name back. A name without
        # a matching id is rejected (a typo must never silently exclude nobody).
        $exclusionId = ''
        $exclusionName = ''
        if ($raw.inactive) {
            $reqId = "$($raw.inactive.exclusionGroupId)".Trim()
            $reqName = "$($raw.inactive.exclusionGroupName)".Trim()
            if ($reqId) {
                $g = Invoke-ARGraph -Uri ('/groups/' + [Uri]::EscapeDataString($reqId) + '?$select=id,displayName,securityEnabled') -Raw
                if ($g.StatusCode -ge 400 -or -not $g.Body.id) {
                    Send-Json -Status 400 -Object @{ error = "Exclusion group id '$reqId' was not found in Entra." }; return
                }
                if (-not $g.Body.securityEnabled) {
                    Send-Json -Status 400 -Object @{ error = "Exclusion group '$($g.Body.displayName)' is not a security group." }; return
                }
                $exclusionId = $g.Body.id
                $exclusionName = $g.Body.displayName
            }
            elseif ($reqName) {
                Send-Json -Status 400 -Object @{ error = "Pick the exclusion group from the suggestions so its id is used (names are not unique)." }; return
            }
            $raw.inactive | Add-Member -NotePropertyName exclusionGroupId -NotePropertyValue $exclusionId -Force
            $raw.inactive | Add-Member -NotePropertyName exclusionGroupName -NotePropertyValue $exclusionName -Force
        }

        # Capture the pre-save state so the audit entry can show old -> new.
        $before = Get-ARFeatureConfig
        $saved = Save-ARFeatureConfig -Raw $raw
        $caller = if ($auth.Caller) { $auth.Caller } else { 'unknown' }

        # If delete timing switched hard -> soft, drain any stranded pending
        # hard-deletes so they are not orphaned.
        if ("$($before.mode)" -eq 'hard' -and "$($saved.mode)" -eq 'soft') {
            try { $drained = Convert-ARPendingToSoft; if ($drained) { Write-Host "Drained $drained pending hard-delete(s) to the soft path." } }
            catch { Write-Warning "Could not drain pending hard-deletes: $($_.Exception.Message)" }
        }

        $diff = Compare-ARConfig -Old $before -New $saved
        Write-Host "Config saved by $caller ($($diff.Count) change(s))."
        Write-ARSystemActivity -EventName "Configuration changed ($($diff.Count) setting$(if ($diff.Count -ne 1) { 's' }))" `
            -Actor $caller -SummaryObject $(if ($diff.Count -gt 0) { $diff } else { @{ note = 'saved without changes' } })
        Send-Json -Status 200 -Object @{ catalog = @(Get-ARFeatureCatalog); config = $saved; firstRun = $false }
    }
    else {
        $firstRun = -not (Test-ARConfigBlobExists)
        Send-Json -Status 200 -Object @{ catalog = @(Get-ARFeatureCatalog); config = Get-ARFeatureConfig; firstRun = $firstRun; version = (Get-ARConfig).Version }
    }
}
catch {
    Write-Error "ConfigApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
