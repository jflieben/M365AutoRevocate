# Weekly version check.
#
# Once a week (at a randomised time, so a whole fleet of installs never hits the
# public repo at the same instant) this compares the deployed version
# (AR_VERSION, stamped from the VERSION file at deploy time) against the VERSION
# file in the public GitHub repo. When the repo is ahead, the Diagnostics tab
# surfaces it and, unless an operator has turned it off, the service desk is
# emailed once per new version.
#
# The CHECK and the GUI notice always run; only the service-desk EMAIL is
# optional (versionCheck.notifyServicedesk in the behaviour config).
#
# State lives in the config container as version-check.json so both the timer
# (VersionChecker) and the admin API (StatusApi) can read the same result.

$script:ARVersionStateBlob = 'version-check.json'

function Test-ARVersionNewer {
    <#
    .SYNOPSIS
        True when $Latest is a strictly higher version than $Installed.
    .DESCRIPTION
        Numeric dotted comparison (1.2.0 > 1.10 is handled correctly, missing
        trailing parts count as 0). If either value is not a plain dotted number
        (e.g. the dev build 'dev'), we cannot compare and return $false so a
        non-release build is never reported as "out of date".
    #>
    [CmdletBinding()] param([string]$Installed, [string]$Latest)
    function ConvertTo-Parts {
        param([string]$V)
        if ([string]::IsNullOrWhiteSpace($V)) { return $null }
        $t = $V.Trim().TrimStart('v', 'V')
        if ($t -notmatch '^\d+(\.\d+)*$') { return $null }
        return @($t.Split('.') | ForEach-Object { [int]$_ })
    }
    $a = ConvertTo-Parts $Installed
    $b = ConvertTo-Parts $Latest
    if ($null -eq $a -or $null -eq $b) { return $false }
    $len = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $ai = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $bi = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($bi -gt $ai) { return $true }
        if ($bi -lt $ai) { return $false }
    }
    return $false
}

function Get-ARLatestPublishedVersion {
    <#
    .SYNOPSIS
        Fetches the VERSION file from the public repo and returns the trimmed
        version string. Throws on any network/validation failure so the caller
        can decide how to react (the timer treats a failure as non-fatal).
    #>
    [CmdletBinding()] param()
    $cfg = Get-ARConfig
    $resp = Invoke-RestMethod -Method Get -Uri $cfg.VersionCheckUrl -TimeoutSec 15 `
        -MaximumRedirection 3 -Headers @{ 'User-Agent' = 'M365AutoRevocate-VersionCheck' } -ErrorAction Stop
    $latest = "$resp".Trim()
    # The endpoint should return a bare version. Guard against a captive-portal /
    # error page slipping through as a "version".
    if ($latest -notmatch '^\d+(\.\d+){0,3}$') {
        throw "The version endpoint returned an unexpected value ('$([string]::Concat($latest.Substring(0,[Math]::Min(40,$latest.Length))))')."
    }
    return $latest
}

function Get-ARVersionCheckState {
    <#
    .SYNOPSIS
        Reads the persisted version-check result blob, or $null if it has never
        run. Never throws (returns $null on a read error).
    #>
    [CmdletBinding()] param()
    try {
        $text = Get-ARBlobText -Name $script:ARVersionStateBlob
        if (-not $text) { return $null }
        return ($text | ConvertFrom-Json)
    }
    catch { Write-Warning "Could not read version-check state: $($_.Exception.Message)"; return $null }
}

function Save-ARVersionCheckState {
    [CmdletBinding()] param([Parameter(Mandatory)]$State)
    Set-ARBlobText -Name $script:ARVersionStateBlob -Content ($State | ConvertTo-Json -Depth 6)
}

function Get-ARVersionCheckStatus {
    <#
    .SYNOPSIS
        A safe, self-describing view of version status for the admin API. Merges
        the live config (installed version, notify toggle) with the last stored
        check result. Never throws.
    #>
    [CmdletBinding()] param()
    $cfg = Get-ARConfig
    $notify = $true
    try { $notify = [bool](Get-ARFeatureConfig).versionCheck.notifyServicedesk } catch { }
    $state = Get-ARVersionCheckState
    return @{
        installed        = $cfg.Version
        latest           = if ($state) { $state.latestVersion } else { $null }
        updateAvailable  = if ($state) { [bool]$state.updateAvailable } else { $false }
        lastCheckUtc     = if ($state) { $state.lastCheckUtc } else { $null }
        nextCheckUtc     = if ($state) { $state.nextCheckUtc } else { $null }
        lastError        = if ($state -and $state.PSObject.Properties['lastError']) { $state.lastError } else { $null }
        notifyServicedesk = $notify
        releasesUrl      = $cfg.ReleasesUrl
    }
}

function Send-ARVersionUpdateMail {
    <#
    .SYNOPSIS
        Emails the service desk that a newer version is available, from the
        scoped sender mailbox.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Installed,
        [Parameter(Mandatory)][string]$Latest,
        [string]$ReleasesUrl
    )
    $cfg = Get-ARConfig
    $tool = ConvertTo-ARHtmlEncoded (Get-ARToolName)
    $link = if ($ReleasesUrl) { $ReleasesUrl } else { $cfg.ReleasesUrl }
    $html = '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#201f1e;max-width:640px">' +
        "<p>A newer version of <strong>$tool</strong> is available.</p>" +
        '<table style="border-collapse:collapse;margin:12px 0">' +
        '<tr><td style="padding:2px 12px 2px 0;color:#605e5c">Installed</td><td style="padding:2px 0"><strong>' + (ConvertTo-ARHtmlEncoded $Installed) + '</strong></td></tr>' +
        '<tr><td style="padding:2px 12px 2px 0;color:#605e5c">Latest</td><td style="padding:2px 0"><strong>' + (ConvertTo-ARHtmlEncoded $Latest) + '</strong></td></tr>' +
        '</table>' +
        '<p>Review the release notes, then update when convenient by re-running the deployment (or the update script).</p>' +
        '<p><a href="' + (ConvertTo-ARHtmlEncoded $link) + '">Release notes and update instructions</a></p>' +
        '<hr style="border:none;border-top:1px solid #edebe9;margin:16px 0">' +
        "<p style=`"color:#8a8886;font-size:12px`">Automated notice from $tool. " +
        'You can turn this notice off under Configuration in the admin console; the in-app update banner stays either way.</p></div>'
    $body = @{
        message         = @{ subject = "$(Get-ARToolName) update available: $Latest"; body = @{ contentType = 'HTML'; content = $html }; toRecipients = @(@{ emailAddress = @{ address = $To } }) }
        saveToSentItems = $false
    }
    Invoke-ARGraph -Method Post -Uri ('/users/' + [Uri]::EscapeDataString($cfg.SenderUpn) + '/sendMail') -Body $body | Out-Null
}

function Invoke-ARVersionCheck {
    <#
    .SYNOPSIS
        Runs the weekly version check when due, persists the result for the GUI,
        and (once per new version, unless disabled) emails the service desk.
    .DESCRIPTION
        A fixed cron cannot randomise the check time, so this runs on a frequent
        timer and only acts when the stored nextCheckUtc has passed. Each run
        schedules the next one ~7 days out with +/-2 days of jitter, so across
        many installs the load on the public repo is spread over days and times
        of day rather than arriving all at once.

        A fetch failure is NOT fatal: it is recorded and the previously known
        result is kept, so a transient GitHub outage never pages the service desk
        (via the Watchdog) and never erases a real "update available" signal.
    #>
    [CmdletBinding()] param([switch]$Force)
    $cfg = Get-ARConfig
    $now = [DateTimeOffset]::UtcNow
    $state = Get-ARVersionCheckState

    if (-not $Force -and $state -and $state.PSObject.Properties['nextCheckUtc'] -and $state.nextCheckUtc) {
        [DateTimeOffset]$next = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse("$($state.nextCheckUtc)", [ref]$next) -and $now -lt $next) {
            Write-Host "VersionChecker: not due until $($state.nextCheckUtc); skipping."
            return
        }
    }

    $installed = $cfg.Version
    # New random schedule for the next run: weekly with +/-2 days of jitter.
    $nextCheck = $now.AddDays(7).AddMinutes((Get-Random -Minimum -2880 -Maximum 2880)).ToString('o')

    $latest = $null; $fetchError = $null
    try { $latest = Get-ARLatestPublishedVersion }
    catch { $fetchError = $_.Exception.Message; Write-Warning "VersionChecker: could not read the latest version: $fetchError" }

    if (-not $latest) {
        # Keep whatever we knew before; just record the attempt and reschedule.
        $prevLatest = if ($state) { $state.latestVersion } else { $null }
        $prevUpdate = if ($state) { [bool]$state.updateAvailable } else { $false }
        $prevNotified = if ($state -and $state.PSObject.Properties['notifiedVersion']) { $state.notifiedVersion } else { $null }
        Save-ARVersionCheckState -State ([ordered]@{
                installedVersion = $installed
                latestVersion    = $prevLatest
                updateAvailable  = $prevUpdate
                lastCheckUtc     = $now.ToString('o')
                nextCheckUtc     = $nextCheck
                notifiedVersion  = $prevNotified
                lastError        = $fetchError
            })
        Write-ARSystemActivity -EventName 'Version check failed' -SummaryObject @{ error = $fetchError; installed = $installed }
        return
    }

    $updateAvailable = Test-ARVersionNewer -Installed $installed -Latest $latest
    $features = Get-ARFeatureConfig
    $notify = [bool]$features.versionCheck.notifyServicedesk
    $servicedesk = "$($features.servicedeskEmail)".Trim()
    $prevNotified = if ($state -and $state.PSObject.Properties['notifiedVersion']) { "$($state.notifiedVersion)" } else { '' }
    $notifiedVersion = $prevNotified

    Write-Host "VersionChecker: installed $installed, latest $latest, updateAvailable=$updateAvailable."

    if ($updateAvailable) {
        # Only email once per NEW version, and only if the operator left the
        # notification on. The check and the GUI banner do not depend on this.
        if ($notify -and $servicedesk -and ($prevNotified -ne $latest)) {
            try {
                Send-ARVersionUpdateMail -To $servicedesk -Installed $installed -Latest $latest -ReleasesUrl $cfg.ReleasesUrl
                $notifiedVersion = $latest
                Write-Host "VersionChecker: emailed the service desk ($servicedesk) about $latest."
            }
            catch { Write-Warning "VersionChecker: could not email the update notice: $($_.Exception.Message)" }
        }
        # Log the finding once per new version (so the activity feed is not noisy
        # on every weekly re-check of the same known update).
        if ($prevNotified -ne $latest -and (-not $state -or "$($state.latestVersion)" -ne $latest)) {
            $emailed = ($notifiedVersion -eq $latest)
            Write-ARSystemActivity -EventName "Update available: $latest" -SummaryObject @{
                installed = $installed; latest = $latest
                notifiedServicedesk = $emailed
                notificationDisabled = (-not $notify)
            }
        }
    }

    Save-ARVersionCheckState -State ([ordered]@{
            installedVersion = $installed
            latestVersion    = $latest
            updateAvailable  = $updateAvailable
            lastCheckUtc     = $now.ToString('o')
            nextCheckUtc     = $nextCheck
            notifiedVersion  = $notifiedVersion
            lastError        = $null
        })
}
