# Notification email: hands off a deleted user's leftover artifacts to their
# manager (or the service desk) via Graph sendMail, using the managed identity.

function ConvertTo-ARHtmlEncoded {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-ARToolName {
    <#
    .SYNOPSIS
        The display name used in email bodies. Configurable (behaviour config) so
        IT can make the messages recognisable to managers; falls back to the
        product name.
    #>
    [CmdletBinding()] param()
    $name = ''
    try { $name = "$((Get-ARFeatureConfig).toolName)".Trim() } catch { }
    if (-not $name) { $name = 'M365AutoRevocate' }
    return $name
}

function Get-ARPowerPlatformSummaryLines {
    <#
    .SYNOPSIS
        Human-readable line(s) for a Power Platform action result (disable /
        delete / re-own), listing the flows and apps actually actioned so the
        manager sees exactly which objects changed.
    #>
    [CmdletBinding()] param([string]$Verb, [string]$PastVerb, $Summary, [bool]$Dry, [string]$Prefix)
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $Summary) { return $lines }
    $total = [int]$Summary.Total
    if ($total -eq 0) { $lines.Add("No owned Power Platform flows or apps to $Verb."); return $lines }

    # Name the objects that were (or would be) actioned, capped so a prolific
    # owner does not produce a giant email.
    $acted = @($Summary.Items | Where-Object { $_.Result -notmatch '^(error|already|skipped)' })
    $names = @($acted | ForEach-Object { "$($_.Kind) '$($_.Name)'" })
    $shown = @($names | Select-Object -First 15)
    $suffix = if ($names.Count -gt $shown.Count) { " and $($names.Count - $shown.Count) more" } else { '' }
    $list = if ($shown.Count) { ': ' + ($shown -join ', ') + $suffix } else { '' }

    if ($Dry) { $lines.Add($Prefix + "$total owned Power Platform object(s) would be ${PastVerb}$list.") }
    else {
        $done = [int]$Summary.Succeeded
        if ($done -gt 0) { $lines.Add($Prefix + "$done owned Power Platform object(s) ${PastVerb}$list.") }
    }
    if ([int]$Summary.Errors -gt 0) { $lines.Add("$([int]$Summary.Errors) Power Platform object(s) could not be ${PastVerb}; see the activity log.") }
    return $lines
}

function Get-ARActionSummaryLines {
    <#
    .SYNOPSIS
        Turns the actions summary into human-readable sentences of what ACTUALLY
        happened (so the email never claims a change that did not occur).
        OneDrive and the manager hand-off have their own sections and are skipped.
    #>
    [CmdletBinding()] param($Actions)
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $Actions) { return $lines }
    foreach ($p in $Actions.PSObject.Properties) {
        $v = $p.Value
        if (-not $v) { continue }
        $dry = [bool]($v.PSObject.Properties['DryRun'] -and $v.DryRun)
        $pfx = if ($dry) { '[simulated] ' } else { '' }
        switch ($p.Name) {
            'revokeSessions' {
                if ($v.PSObject.Properties['Revoked'] -and $v.Revoked) { $lines.Add($pfx + 'Sign-in and refresh tokens revoked.') }
                elseif ($dry) { $lines.Add($pfx + 'Sign-in and refresh tokens would be revoked.') }
                elseif ($v.PSObject.Properties['Error'] -and $v.Error) { $lines.Add('Token revocation failed: ' + $v.Error) }
            }
            'autoReply' {
                if ($v.PSObject.Properties['Set'] -and $v.Set) { $lines.Add($pfx + 'Auto-reply set on the mailbox.') }
                elseif ($dry) { $lines.Add($pfx + 'An auto-reply would be set on the mailbox.') }
                elseif ($v.PSObject.Properties['Error'] -and $v.Error) { $lines.Add('Setting the auto-reply failed: ' + $v.Error) }
            }
            'forward' {
                if ($v.PSObject.Properties['RuleCreated'] -and $v.RuleCreated) { $lines.Add($pfx + "Forwarding rule added, sending new mail to $($v.Address).") }
                elseif ($dry) { $lines.Add($pfx + "Mail would be forwarded to $($v.Address).") }
                elseif ($v.PSObject.Properties['Reason'] -and $v.Reason) { $lines.Add('Mail forward skipped (' + $v.Reason + ').') }
                elseif ($v.PSObject.Properties['Error'] -and $v.Error) { $lines.Add('Adding the forward rule failed: ' + $v.Error) }
            }
            'cancelMeetings' {
                $c = [int]$v.Cancelled
                if ($c -gt 0) { $lines.Add($pfx + "$c organised meeting(s)/series cancelled and attendees notified.") }
                elseif (-not $dry) { $lines.Add('No future organised meetings needed cancelling.') }
            }
            'removeLicenses' {
                $r = [int]$v.Removed
                if ($dry -and $v.PSObject.Properties['WouldRemove']) { $lines.Add($pfx + "$([int]$v.WouldRemove) directly-assigned licence(s) would be removed.") }
                elseif ($r -gt 0) { $lines.Add($pfx + "$r directly-assigned licence(s) removed.") }
                elseif ($v.PSObject.Properties['Error'] -and $v.Error) { $lines.Add('Licence removal failed: ' + $v.Error) }
                else { $lines.Add('No directly-assigned licences to remove.') }
            }
            'removeFromGroups' {
                $r = [int]$v.Removed
                if ($r -gt 0) { $lines.Add($pfx + "Removed from $r group(s).") }
                else { $lines.Add('No removable group memberships.') }
            }
            'disableDevices' {
                $t = [int]$v.Total; $dis = [int]$v.Disabled
                if ($t -eq 0) { $lines.Add('No owned devices to disable.') }
                elseif ($dry) { $lines.Add($pfx + "$t owned device(s) would be disabled.") }
                elseif ($dis -gt 0) { $lines.Add($pfx + "$dis owned device(s) disabled (sign-in blocked).") }
                else { $lines.Add('Owned devices were already disabled; left unchanged.') }
            }
            'deleteDevices' {
                $t = [int]$v.Total; $del = [int]$v.Deleted
                if ($t -eq 0) { $lines.Add('No owned devices to delete.') }
                elseif ($dry) { $lines.Add($pfx + "$t owned device(s) would be deleted.") }
                elseif ($del -gt 0) { $lines.Add($pfx + "$del owned device(s) permanently deleted.") }
            }
            'disablePowerPlatform' {
                foreach ($l in (Get-ARPowerPlatformSummaryLines -Verb 'disable' -PastVerb 'disabled' -Summary $v -Dry $dry -Prefix $pfx)) { $lines.Add($l) }
            }
            'reownPowerPlatform' {
                foreach ($l in (Get-ARPowerPlatformSummaryLines -Verb 're-own' -PastVerb 're-owned' -Summary $v -Dry $dry -Prefix $pfx)) { $lines.Add($l) }
            }
            'deletePowerPlatform' {
                foreach ($l in (Get-ARPowerPlatformSummaryLines -Verb 'delete' -PastVerb 'deleted' -Summary $v -Dry $dry -Prefix $pfx)) { $lines.Add($l) }
            }
            'disableAccount' {
                if ($v.PSObject.Properties['Disabled'] -and $v.Disabled) { $lines.Add($pfx + 'Account disabled (sign-in blocked).') }
                elseif ($v.PSObject.Properties['AlreadyDisabled'] -and $v.AlreadyDisabled) { $lines.Add('Account was already disabled; left unchanged.') }
                elseif ($dry) { $lines.Add($pfx + 'The account would be disabled.') }
                elseif ($v.PSObject.Properties['Error'] -and $v.Error) { $lines.Add('Disabling the account failed: ' + $v.Error) }
            }
            'softDeleteUser' {
                if ($v.PSObject.Properties['Deleted'] -and $v.Deleted) { $lines.Add($pfx + 'Account soft-deleted (moved to the recycle bin).') }
                elseif ($dry) { $lines.Add($pfx + 'The account would be soft-deleted.') }
                elseif ($v.PSObject.Properties['Error'] -and $v.Error) { $lines.Add('Soft delete failed: ' + $v.Error) }
            }
        }
    }
    return $lines
}

function Get-ARNotificationHtml {
    [CmdletBinding()]
    param($DeletedUpn, $DeletedDisplayName, $DeletedUserId, $Trigger, $EventDescription, $OneDrive, $Artifacts, $Recipient, $Actions, [string]$ToolName = 'M365AutoRevocate')

    # Neutral, trigger-aware opening: the tool REACTS to these events, it does not
    # cause the inactivity/disable/deletion, so never phrase it as if it did.
    $intro = switch ($Trigger) {
        'inactive' { 'was flagged as <strong>inactive</strong> by automated monitoring' }
        'disable'  { 'was found to be <strong>disabled</strong>' }
        default    { 'was <strong>' + (ConvertTo-ARHtmlEncoded $EventDescription) + '</strong>' }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#201f1e;max-width:640px">')
    [void]$sb.Append("<p>Hello $(ConvertTo-ARHtmlEncoded $Recipient.DisplayName),</p>")
    [void]$sb.Append("<p>The account below $intro. The automated offboarding actions listed here ran; please review and take any manual follow-up needed.</p>")

    # The manager knows the person by name; UPN and object id are noise here.
    [void]$sb.Append('<table style="border-collapse:collapse;margin:12px 0">')
    [void]$sb.Append('<tr><td style="padding:2px 12px 2px 0;color:#605e5c">User</td><td style="padding:2px 0"><strong>' +
                     (ConvertTo-ARHtmlEncoded $DeletedDisplayName) + '</strong></td></tr>')
    [void]$sb.Append('</table>')

    # What the tool actually did (only real outcomes).
    $actionLines = @(Get-ARActionSummaryLines -Actions $Actions)
    if ($actionLines.Count -gt 0) {
        [void]$sb.Append('<h3 style="margin:16px 0 4px">Automated actions</h3><ul style="margin:4px 0">')
        foreach ($line in $actionLines) { [void]$sb.Append('<li>' + (ConvertTo-ARHtmlEncoded $line) + '</li>') }
        [void]$sb.Append('</ul>')
    }

    # OneDrive outcome -- only shown when the unshare action actually ran
    # ($OneDrive is $null when the feature is not enabled, so we don't mention it).
    if ($OneDrive) {
        [void]$sb.Append('<h3 style="margin:16px 0 4px">OneDrive</h3>')
        if ($OneDrive.SharingDisabled) {
            [void]$sb.Append('<ul style="margin:4px 0">')
            if ($OneDrive.WebUrl) { [void]$sb.Append('<li>Site: ' + (ConvertTo-ARHtmlEncoded $OneDrive.WebUrl) + '</li>') }
            [void]$sb.Append('<li>All sharing on this OneDrive has been disabled; existing shared links no longer work.</li>')
            [void]$sb.Append('</ul>')
        }
        elseif ($OneDrive.PSObject.Properties['Error'] -and $OneDrive.Error) {
            [void]$sb.Append('<ul style="margin:4px 0">')
            if ($OneDrive.WebUrl) { [void]$sb.Append('<li>Site: ' + (ConvertTo-ARHtmlEncoded $OneDrive.WebUrl) + '</li>') }
            [void]$sb.Append('<li style="color:#a4262c">Automated unshare did not complete: ' + (ConvertTo-ARHtmlEncoded $OneDrive.Error) + '. Please review sharing on this OneDrive manually.</li>')
            [void]$sb.Append('</ul>')
        }
        else {
            [void]$sb.Append('<p>No OneDrive was found for this user (never provisioned, or already removed).</p>')
        }
    }

    # Owned artifacts
    [void]$sb.Append('<h3 style="margin:16px 0 4px">Artifacts still owned by the user</h3>')
    if ($Artifacts -and $Artifacts.Count -gt 0) {
        [void]$sb.Append('<table style="border-collapse:collapse;margin:4px 0" border="0">')
        [void]$sb.Append('<tr style="text-align:left"><th style="padding:4px 16px 4px 0;border-bottom:1px solid #edebe9">Type</th>' +
                         '<th style="padding:4px 0;border-bottom:1px solid #edebe9">Name</th></tr>')
        foreach ($a in $Artifacts) {
            [void]$sb.Append('<tr><td style="padding:4px 16px 4px 0">' + (ConvertTo-ARHtmlEncoded $a.Type) +
                             '</td><td style="padding:4px 0">' + (ConvertTo-ARHtmlEncoded $a.DisplayName) + '</td></tr>')
        }
        [void]$sb.Append('</table>')
        [void]$sb.Append('<p style="color:#605e5c">These objects may now be orphaned (e.g. groups/teams/apps with no other owner). ' +
                         'Please reassign ownership or decommission them.</p>')
    }
    else {
        [void]$sb.Append('<p>No groups, teams, applications, devices or other objects are still owned by this user. Nothing to hand over.</p>')
    }

    if ($Recipient.Kind -eq 'servicedesk') {
        [void]$sb.Append('<p style="color:#605e5c"><em>This was sent to the service desk because the user had no ' +
                         'active manager on record.</em></p>')
    }

    [void]$sb.Append('<hr style="border:none;border-top:1px solid #edebe9;margin:16px 0">')
    [void]$sb.Append('<p style="color:#8a8886;font-size:12px">Automated message from ' + (ConvertTo-ARHtmlEncoded $ToolName) + '.</p>')
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function Send-ARAlertMail {
    <#
    .SYNOPSIS
        Sends a plain operational alert (used by the Watchdog) from the scoped
        sender mailbox to the service desk.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$To, [Parameter(Mandatory)][string]$Subject, [string[]]$Issues)
    $cfg = Get-ARConfig
    $tool = ConvertTo-ARHtmlEncoded (Get-ARToolName)
    $items = ($Issues | ForEach-Object { '<li>' + (ConvertTo-ARHtmlEncoded $_) + '</li>' }) -join ''
    $html = '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#201f1e;max-width:640px">' +
        "<p>$tool detected the following health issue(s):</p><ul>" + $items + '</ul>' +
        '<p>Open the admin web app <strong>Diagnostics</strong> tab for detail.</p>' +
        '<hr style="border:none;border-top:1px solid #edebe9;margin:16px 0">' +
        "<p style=`"color:#8a8886;font-size:12px`">Automated health alert from $tool.</p></div>"
    $body = @{
        message         = @{ subject = $Subject; body = @{ contentType = 'HTML'; content = $html }; toRecipients = @(@{ emailAddress = @{ address = $To } }) }
        saveToSentItems = $false
    }
    Invoke-ARGraph -Method Post -Uri ('/users/' + [Uri]::EscapeDataString($cfg.SenderUpn) + '/sendMail') -Body $body | Out-Null
}

function Send-ARNotificationMail {
    [CmdletBinding()]
    param(
        [string]$DeletedUpn, [string]$DeletedDisplayName, [string]$DeletedUserId,
        [string]$Trigger, [string]$EventDescription, $OneDrive, $Artifacts,
        [Parameter(Mandatory)]$Recipient, $Actions
    )
    $cfg = Get-ARConfig
    if (-not $Recipient.Email) {
        Write-Warning "No recipient email resolved for $DeletedUpn; cannot send hand-off mail."
        return
    }

    # Neutral subject: describe the state we reacted to, not an action we took.
    $state = switch ($Trigger) {
        'inactive' { 'inactive account' }
        'disable'  { 'disabled account' }
        default    { 'departed user' }
    }
    $subject = "Offboarding cleanup: $DeletedDisplayName ($state)"
    $html    = Get-ARNotificationHtml -DeletedUpn $DeletedUpn -DeletedDisplayName $DeletedDisplayName `
        -DeletedUserId $DeletedUserId -Trigger $Trigger -EventDescription $EventDescription -OneDrive $OneDrive -Artifacts $Artifacts -Recipient $Recipient -Actions $Actions -ToolName (Get-ARToolName)

    if ($cfg.DryRun) {
        Write-Host "[DryRun] Would send '$subject' to $($Recipient.Email) ($($Recipient.Kind))."
        return
    }

    $body = @{
        message         = @{
            subject      = $subject
            body         = @{ contentType = 'HTML'; content = $html }
            toRecipients = @(@{ emailAddress = @{ address = $Recipient.Email } })
        }
        saveToSentItems = $false
    }
    Invoke-ARGraph -Method Post -Uri ('/users/' + [Uri]::EscapeDataString($cfg.SenderUpn) + '/sendMail') -Body $body | Out-Null
    Write-Host "Sent offboarding hand-off for '$DeletedUpn' to $($Recipient.Email) ($($Recipient.Kind))."
}
