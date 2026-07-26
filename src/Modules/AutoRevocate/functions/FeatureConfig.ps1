# Behavioural configuration: the feature/trigger matrix and option values that
# the admin web app edits. Stored as a JSON blob (config.json) in the storage
# account so edits take effect without a redeploy.
#
# The feature CATALOG below is the single source of truth for which features
# exist and which triggers ("inactive" / "disable" / "delete") each supports.
# The web app fetches the catalog from the API and greys out unsupported
# triggers, so the UI and the runtime never drift.

function Get-ARFeatureCatalog {
    <#
    .SYNOPSIS
        Static description of every feature: key, label, supported triggers, and
        any option fields the operator can set.
    #>
    [CmdletBinding()] param()
    return @(
        [pscustomobject]@{
            key = 'unshareOneDrive'; label = 'Stop sharing OneDrive'
            description = 'Disable sharing on OneDrive so all existing links stop working.'
            supports = @('inactive', 'disable', 'delete'); options = @()
        },
        [pscustomobject]@{
            key = 'notifyManager'; label = 'Notify manager of owned artifacts'
            description = 'Email the manager (fallback: service desk) a list of artifacts the user still owns.'
            supports = @('inactive', 'disable', 'delete'); options = @()
        },
        [pscustomobject]@{
            key = 'disableDevices'; label = 'Disable owned devices'
            description = 'Block sign-in on every Entra device the user owns (reversible). Devices the user registered/joined are captured before deletion, so this still works at the delete trigger.'
            supports = @('inactive', 'disable', 'delete'); options = @()
        },
        [pscustomobject]@{
            key = 'deleteDevices'; label = 'Delete owned devices'
            description = 'Permanently delete every Entra device the user owns (removes the device object). Devices the user registered/joined are captured before deletion, so this still works at the delete trigger.'
            supports = @('inactive', 'disable', 'delete'); options = @()
        },
        [pscustomobject]@{
            key = 'revokeSessions'; label = 'Revoke sign-in / refresh tokens'
            description = 'Invalidate all of the user''s active sessions and refresh tokens.'
            supports = @('inactive', 'disable'); options = @()   # meaningless after deletion
        },
        [pscustomobject]@{
            key = 'autoReply'; label = 'Set an auto-reply on the mailbox'
            description = 'Turn on an automatic reply for internal and external senders.'
            supports = @('inactive', 'disable')                  # mailbox must still exist
            options  = @(
                [pscustomobject]@{ key = 'message'; label = 'Auto-reply message'; type = 'multiline'
                    default = 'This person has left the organisation and this mailbox is no longer monitored. Please contact our service desk for assistance.' }
            )
        },
        [pscustomobject]@{
            key = 'forward'; label = 'Add a mailbox forward'
            description = 'Create an inbox rule that forwards incoming mail to another address.'
            supports = @('inactive', 'disable')
            options  = @(
                [pscustomobject]@{ key = 'address'; label = 'Forward-to address'; type = 'email'; default = '' }
            )
        },
        [pscustomobject]@{
            key = 'cancelMeetings'; label = 'Cancel meetings the user organised'
            description = 'Cancel the user''s future organised meetings and notify the attendees.'
            supports = @('inactive', 'disable')
            options  = @(
                [pscustomobject]@{ key = 'comment'; label = 'Cancellation note to attendees'; type = 'multiline'
                    default = 'This meeting is cancelled because the organiser has left the organisation.' }
            )
        },
        [pscustomobject]@{
            key = 'removeLicenses'; label = 'Remove assigned licences'
            description = 'Remove directly assigned licences (group-based licences are released when group memberships are removed).'
            supports = @('inactive', 'disable'); options = @()
        },
        [pscustomobject]@{
            key = 'removeFromGroups'; label = 'Remove group memberships'
            description = 'Remove the user from every group they are a member of (dynamic and mail-enabled groups are skipped).'
            supports = @('inactive', 'disable'); options = @()
        },
        [pscustomobject]@{
            key = 'softDeleteUser'; label = 'Soft delete the account'
            description = 'Move the account to the recycle bin. Always runs AFTER all other enabled actions.'
            supports = @('inactive', 'disable'); options = @()
        },
        [pscustomobject]@{
            key = 'disableAccount'; label = 'Disable the account'
            description = 'Block sign-in by disabling the account. Only offered for inactive users (a disabled account is already disabled). Reversible.'
            supports = @('inactive'); options = @()   # a disabled/deleted account cannot be disabled again
        },
        # --- Power Platform group -------------------------------------------------
        # These act on the flows and canvas apps the user owns. They need the
        # managed identity to be authorised as a Power Platform admin (there is no
        # Graph app role for this), so the web app keeps them grouped and greyed
        # until access is detected. 'group'/'requiresCapability' are UI hints; the
        # sanitiser ignores them.
        [pscustomobject]@{
            key = 'disablePowerPlatform'; label = 'Disable Power Platform objects'
            description = 'Turn off the cloud flows the user owns and quarantine the canvas apps they own (reversible).'
            supports = @('inactive', 'disable', 'delete'); options = @()
            group = 'powerPlatform'; requiresCapability = 'powerPlatform'
        },
        [pscustomobject]@{
            key = 'deletePowerPlatform'; label = 'Delete Power Platform objects'
            description = 'Permanently delete the cloud flows and canvas apps the user owns.'
            supports = @('inactive', 'disable', 'delete'); options = @()
            group = 'powerPlatform'; requiresCapability = 'powerPlatform'
        },
        [pscustomobject]@{
            key = 'reownPowerPlatform'; label = 'Re-own Power Platform objects'
            description = 'Hand the cloud flows and canvas apps the user owns to their manager (service desk as fallback): apps are transferred outright, flows get the new owner added as a co-owner.'
            supports = @('inactive', 'disable', 'delete'); options = @()
            group = 'powerPlatform'; requiresCapability = 'powerPlatform'
        }
    )
}

function Get-ARDefaultConfig {
    <#
    .SYNOPSIS
        The config used when no blob exists yet (before the setup wizard has
        run). Only the two original behaviours are on, at delete.
    #>
    [CmdletBinding()] param()
    $mode = ([Environment]::GetEnvironmentVariable('AR_MODE'))
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'soft' }

    $features = [ordered]@{}
    foreach ($f in Get-ARFeatureCatalog) {
        $entry = [ordered]@{
            atInactive = $false
            atDisable  = $false
            atDelete   = (($f.key -in @('unshareOneDrive', 'notifyManager')) -and ('delete' -in $f.supports))
        }
        foreach ($opt in $f.options) { $entry[$opt.key] = $opt.default }
        $features[$f.key] = $entry
    }

    return [ordered]@{
        mode                 = $mode
        dryRun               = $true    # fail SAFE on a brand-new install: simulate until the operator turns it off in the wizard/config
        servicedeskEmail     = ([Environment]::GetEnvironmentVariable('AR_SERVICEDESK_EMAIL'))
        # Name shown in email bodies (e.g. "Automated message from <toolName>"), so
        # IT can make the messages recognisable to managers.
        toolName             = 'M365AutoRevocate'
        logRetentionDays     = 365
        allowExternalForward = $false
        inactive             = [ordered]@{ enabled = $false; thresholdDays = 90; exclusionGroupId = ''; exclusionGroupName = ''; excludeSharedMailboxes = $true }
        safety               = (Get-ARDefaultSafety)
        # The weekly version check itself always runs; this only governs whether
        # the service desk is emailed when a newer version is found.
        versionCheck         = [ordered]@{ notifyServicedesk = $true }
        features             = $features
    }
}

function Get-ARDefaultSafety {
    <#
    .SYNOPSIS
        Circuit-breaker defaults. Per-trigger daily caps and a percent-of-
        directory ceiling. When a run would exceed a cap the tool PAUSES all
        processing until an admin reviews and resumes. 0 for a cap means "no
        numeric cap" (the percent ceiling still applies).
    #>
    [CmdletBinding()] param()
    return [ordered]@{
        enabled        = $true
        dailyCapInactive = 25    # soft deletes / licence + group removal are the most destructive
        dailyCapDisable  = 100
        dailyCapDelete   = 100
        percentCeiling   = 20    # never act on more than this % of the directory in a day
    }
}

function ConvertTo-ARSanitisedSafety {
    [CmdletBinding()] param($Raw)
    $def = Get-ARDefaultSafety
    function Get-Int { param($v, [int]$fallback, [int]$min, [int]$max)
        $n = $fallback
        if ($null -ne $v -and [int]::TryParse("$v", [ref]$n)) { } else { $n = $fallback }
        if ($n -lt $min) { $n = $min }; if ($n -gt $max) { $n = $max }; return $n
    }
    return [ordered]@{
        enabled          = if ($null -eq $Raw -or $null -eq $Raw.enabled) { $true } else { [bool]$Raw.enabled }
        dailyCapInactive = Get-Int $Raw.dailyCapInactive $def.dailyCapInactive 0 1000000
        dailyCapDisable  = Get-Int $Raw.dailyCapDisable  $def.dailyCapDisable  0 1000000
        dailyCapDelete   = Get-Int $Raw.dailyCapDelete   $def.dailyCapDelete   0 1000000
        percentCeiling   = Get-Int $Raw.percentCeiling   $def.percentCeiling   0 100
    }
}

function Test-AREmailAddress {
    <#
    .SYNOPSIS
        Syntactic email validation. Empty is treated as valid (means "unset").
    #>
    [CmdletBinding()] param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $true }
    try { $null = [System.Net.Mail.MailAddress]::new($Address.Trim()); return ($Address.Trim() -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') }
    catch { return $false }
}

function ConvertTo-ARSanitisedConfig {
    <#
    .SYNOPSIS
        Validates/normalises a raw config object against the catalog: forces
        unsupported triggers off, keeps only known features/options, validates
        mode and the inactivity settings. Returns an ordered hashtable safe to
        persist.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Raw)

    $mode = "$($Raw.mode)".ToLowerInvariant()
    if ($mode -notin @('soft', 'hard')) { $mode = 'soft' }

    # Dry run (simulation): destructive actions are logged but never sent. This
    # is now a BEHAVIOUR setting the operator flips in the wizard/config, not a
    # deploy-time app setting. Fail SAFE: if the stored config predates this
    # field, fall back to the legacy AR_DRY_RUN app setting when present (so an
    # already-live deployment keeps its mode across the upgrade), otherwise
    # default to simulation ON. The value is persisted into the blob on the next
    # save, after which AR_DRY_RUN is no longer consulted.
    if ($null -ne $Raw.dryRun) { $dryRun = [bool]$Raw.dryRun }
    else {
        $envDry = [Environment]::GetEnvironmentVariable('AR_DRY_RUN')
        $dryRun = if ([string]::IsNullOrWhiteSpace($envDry)) { $true } else { @('true', '1', 'yes', 'on') -contains $envDry.Trim().ToLowerInvariant() }
    }

    # Inactivity settings. Threshold is clamped to a 7-day minimum so a typo can
    # never mass-flag recently active users.
    $inRaw = $Raw.inactive
    $days = 90
    if ($inRaw -and $null -ne $inRaw.thresholdDays) { [void][int]::TryParse("$($inRaw.thresholdDays)", [ref]$days) }
    if ($days -lt 7) { $days = 7 }
    # Shared/room/equipment mailboxes are excluded by default (they are commonly
    # disabled / never signed in but must never be offboarded). Defaults true
    # when the property is absent (existing configs).
    $excludeShared = if ($inRaw -and $null -ne $inRaw.excludeSharedMailboxes) { [bool]$inRaw.excludeSharedMailboxes } else { $true }
    $inactive = [ordered]@{
        enabled                = [bool]($inRaw.enabled)
        thresholdDays          = $days
        exclusionGroupId       = "$($inRaw.exclusionGroupId)"
        exclusionGroupName     = "$($inRaw.exclusionGroupName)"
        excludeSharedMailboxes = $excludeShared
    }

    $features = [ordered]@{}
    foreach ($f in Get-ARFeatureCatalog) {
        $incoming = if ($Raw.features) { $Raw.features.$($f.key) } else { $null }
        $entry = [ordered]@{
            atInactive = [bool]($incoming.atInactive) -and ('inactive' -in $f.supports)
            atDisable  = [bool]($incoming.atDisable)  -and ('disable'  -in $f.supports)
            atDelete   = [bool]($incoming.atDelete)   -and ('delete'   -in $f.supports)
        }
        foreach ($opt in $f.options) {
            $val = if ($incoming -and $null -ne $incoming.$($opt.key)) { "$($incoming.$($opt.key))" } else { $opt.default }
            $entry[$opt.key] = $val
        }
        $features[$f.key] = $entry
    }

    # Activity-log retention: clamped so a typo can neither wipe the log
    # tomorrow nor keep it forever.
    $retention = 365
    if ($null -ne $Raw.logRetentionDays) { [void][int]::TryParse("$($Raw.logRetentionDays)", [ref]$retention) }
    if ($retention -lt 7) { $retention = 7 } elseif ($retention -gt 3650) { $retention = 3650 }

    # Emails are blanked here if syntactically invalid so a bad stored value can
    # never become a live forward/notify target. The API (ConfigApi) rejects
    # invalid input up front with a 400 and also enforces the verified-domain
    # policy for the forward address; this is the last-line defensive coercion.
    $servicedesk = "$($Raw.servicedeskEmail)".Trim()
    if (-not (Test-AREmailAddress -Address $servicedesk)) { $servicedesk = '' }

    foreach ($f in Get-ARFeatureCatalog) {
        if ($f.key -eq 'forward') {
            $addr = "$($features.forward.address)".Trim()
            $features.forward.address = if (Test-AREmailAddress -Address $addr) { $addr } else { '' }
        }
    }

    # Version-check notification: on unless explicitly turned off. Absent (older
    # configs) counts as on, matching the default. The check and the GUI notice
    # are unconditional; only the email is governed here.
    $notifyVersion = if ($null -ne $Raw.versionCheck -and $null -ne $Raw.versionCheck.notifyServicedesk) { [bool]$Raw.versionCheck.notifyServicedesk } else { $true }

    # Email display name: empty falls back to the product name; capped so it can't
    # blow up an email header/footer.
    $toolName = "$($Raw.toolName)".Trim()
    if (-not $toolName) { $toolName = 'M365AutoRevocate' }
    if ($toolName.Length -gt 60) { $toolName = $toolName.Substring(0, 60).Trim() }

    return [ordered]@{
        mode                 = $mode
        dryRun               = $dryRun
        servicedeskEmail     = $servicedesk
        toolName             = $toolName
        logRetentionDays     = $retention
        allowExternalForward = [bool]($Raw.allowExternalForward)
        inactive             = $inactive
        safety               = (ConvertTo-ARSanitisedSafety -Raw $Raw.safety)
        versionCheck         = [ordered]@{ notifyServicedesk = $notifyVersion }
        features             = $features
    }
}

function Test-ARConfigBlobExists {
    <#
    .SYNOPSIS
        True once the config blob has been written (i.e. the setup wizard or a
        config save has happened). Used to drive the web app's first-run wizard.
    #>
    [CmdletBinding()] param()
    try { return ($null -ne (Get-ARBlobText -Name (Get-ARConfigBlobName))) }
    catch { return $false }
}

$script:ARFeatureConfigCache = $null
$script:ARFeatureConfigCacheAt = [DateTimeOffset]::MinValue

function Get-ARFeatureConfig {
    <#
    .SYNOPSIS
        Reads the current behavioural config from the blob (or defaults), always
        sanitised against the catalog. Cached per worker for ~60s: in a large
        tenant the high-volume 'updated' firehose would otherwise read the blob
        once per event. Web edits still apply within a minute (and Save clears
        the cache in its own worker). Use -Fresh to bypass.
    #>
    [CmdletBinding()] param([switch]$Fresh)
    if (-not $Fresh -and $script:ARFeatureConfigCache -and
        ([DateTimeOffset]::UtcNow - $script:ARFeatureConfigCacheAt).TotalSeconds -lt 60) {
        return $script:ARFeatureConfigCache
    }
    $text = $null
    try { $text = Get-ARBlobText -Name (Get-ARConfigBlobName) } catch { Write-Warning "Config blob read failed, using defaults: $($_.Exception.Message)" }
    $raw = if ($text) { try { $text | ConvertFrom-Json } catch { $null } } else { $null }
    if (-not $raw) { $raw = [pscustomobject](Get-ARDefaultConfig) }
    $result = [pscustomobject](ConvertTo-ARSanitisedConfig -Raw $raw)
    $script:ARFeatureConfigCache = $result
    $script:ARFeatureConfigCacheAt = [DateTimeOffset]::UtcNow
    return $result
}

function Save-ARFeatureConfig {
    [CmdletBinding()] param([Parameter(Mandatory)]$Raw)
    $clean = ConvertTo-ARSanitisedConfig -Raw $Raw
    # Keep the immediately-previous config so a bad save can be rolled back by
    # hand (config.previous.json -> config.json). Storage blob versioning (set at
    # deploy) keeps the full history; this is the one-click rollback.
    try {
        $current = Get-ARBlobText -Name (Get-ARConfigBlobName)
        if ($current) { Set-ARBlobText -Name 'config.previous.json' -Content $current }
    }
    catch { Write-Warning "Could not back up the current config: $($_.Exception.Message)" }
    Set-ARBlobText -Name (Get-ARConfigBlobName) -Content ($clean | ConvertTo-Json -Depth 10)
    $script:ARFeatureConfigCache = $null   # invalidate this worker's cache
    return [pscustomobject]$clean
}

function Compare-ARConfig {
    <#
    .SYNOPSIS
        Flattens two sanitised configs and returns only the changed leaves as
        an ordered map of path -> { old, new }. Used to audit config saves.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Old, [Parameter(Mandatory)]$New)

    # JSON round-trip normalises ordered hashtables and pscustomobjects into one
    # uniform object tree, so a single flattening walk covers both.
    $oldObj = $Old | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $newObj = $New | ConvertTo-Json -Depth 10 | ConvertFrom-Json

    function Get-FlatMap {
        param($Node, [string]$Prefix, [hashtable]$Map)
        foreach ($p in $Node.PSObject.Properties) {
            $path = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
            if ($p.Value -is [System.Management.Automation.PSCustomObject]) { Get-FlatMap -Node $p.Value -Prefix $path -Map $Map }
            else { $Map[$path] = "$($p.Value)" }
        }
    }
    $o = @{}; $n = @{}
    Get-FlatMap -Node $oldObj -Prefix '' -Map $o
    Get-FlatMap -Node $newObj -Prefix '' -Map $n

    $changes = [ordered]@{}
    foreach ($key in (@($o.Keys) + @($n.Keys) | Select-Object -Unique | Sort-Object)) {
        if ($o[$key] -ne $n[$key]) {
            $changes[$key] = @{ old = $o[$key]; new = $n[$key] }
        }
    }
    return $changes
}

function Test-ARFeatureEnabled {
    <#
    .SYNOPSIS
        Is $Feature configured to run at $Trigger ('inactive'|'disable'|'delete')?
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$FeatureConfig,
        [Parameter(Mandatory)][string]$Feature,
        [Parameter(Mandatory)][ValidateSet('inactive', 'disable', 'delete')][string]$Trigger
    )
    $entry = $FeatureConfig.features.$Feature
    if (-not $entry) { return $false }
    switch ($Trigger) {
        'inactive' { return [bool]$entry.atInactive }
        'disable'  { return [bool]$entry.atDisable }
        default    { return [bool]$entry.atDelete }
    }
}

function Test-ARAnyFeatureEnabled {
    <#
    .SYNOPSIS
        Is any feature configured to run at $Trigger? Lets callers cheaply skip
        work (e.g. drop 'updated' notifications, or skip the inactivity scan).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$FeatureConfig, [Parameter(Mandatory)][ValidateSet('inactive', 'disable', 'delete')][string]$Trigger)
    foreach ($f in Get-ARFeatureCatalog) {
        if (Test-ARFeatureEnabled -FeatureConfig $FeatureConfig -Feature $f.key -Trigger $Trigger) { return $true }
    }
    return $false
}
