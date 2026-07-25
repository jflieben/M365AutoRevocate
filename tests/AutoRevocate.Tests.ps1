# Pester tests for M365AutoRevocate's pure logic (no Azure / Graph needed).
# Run: Invoke-Pester ./tests

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\AutoRevocate\AutoRevocate.psd1'
    Import-Module $modulePath -Force
}

Describe 'Test-AREmailAddress' {
    It 'accepts a normal address' { Test-AREmailAddress -Address 'a@contoso.com' | Should -BeTrue }
    It 'accepts empty (means unset)' { Test-AREmailAddress -Address '' | Should -BeTrue }
    It 'rejects a bare word' { Test-AREmailAddress -Address 'nope' | Should -BeFalse }
    It 'rejects missing TLD' { Test-AREmailAddress -Address 'a@b' | Should -BeFalse }
    It 'rejects embedded space' { Test-AREmailAddress -Address 'a b@c.com' | Should -BeFalse }
}

Describe 'ConvertTo-ARSanitisedSafety' {
    It 'defaults a non-numeric cap' { (ConvertTo-ARSanitisedSafety -Raw ([pscustomobject]@{ dailyCapInactive = 'x' })).dailyCapInactive | Should -Be 25 }
    It 'clamps a negative cap to 0' { (ConvertTo-ARSanitisedSafety -Raw ([pscustomobject]@{ dailyCapDisable = -3 })).dailyCapDisable | Should -Be 0 }
    It 'clamps percent over 100' { (ConvertTo-ARSanitisedSafety -Raw ([pscustomobject]@{ percentCeiling = 500 })).percentCeiling | Should -Be 100 }
    It 'enabled defaults true when absent' { (ConvertTo-ARSanitisedSafety -Raw ([pscustomobject]@{})).enabled | Should -BeTrue }
    It 'honours enabled=false' { (ConvertTo-ARSanitisedSafety -Raw ([pscustomobject]@{ enabled = $false })).enabled | Should -BeFalse }
}

Describe 'ConvertTo-ARSanitisedConfig' {
    It 'lowercases and validates mode, defaulting bad values to soft' {
        (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ mode = 'HARD' })).mode | Should -Be 'hard'
        (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ mode = 'weird' })).mode | Should -Be 'soft'
    }
    It 'blanks an invalid service desk email' {
        (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ servicedeskEmail = 'bad' })).servicedeskEmail | Should -Be ''
    }
    It 'clamps log retention to the 7..3650 range' {
        (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ logRetentionDays = 2 })).logRetentionDays | Should -Be 7
        (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ logRetentionDays = 99999 })).logRetentionDays | Should -Be 3650
    }
    It 'clamps the inactivity threshold to a 7-day floor' {
        (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ inactive = [pscustomobject]@{ enabled = $true; thresholdDays = 1 } })).inactive.thresholdDays | Should -Be 7
    }
    It 'forces an unsupported trigger off (softDeleteUser only supports inactive)' {
        $c = ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ features = [pscustomobject]@{ softDeleteUser = [pscustomobject]@{ atDelete = $true; atInactive = $true } } })
        $c.features.softDeleteUser.atDelete | Should -BeFalse
        $c.features.softDeleteUser.atInactive | Should -BeTrue
    }
    It 'blanks an invalid forward address' {
        $c = ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ features = [pscustomobject]@{ forward = [pscustomobject]@{ address = 'not valid'; atDisable = $true } } })
        $c.features.forward.address | Should -Be ''
    }
    It 'always includes a safety block' {
        (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{})).safety | Should -Not -BeNullOrEmpty
    }
    It 'defaults dry run ON (fail safe) when the field is absent and no legacy env is set' {
        $saved = $env:AR_DRY_RUN
        try {
            Remove-Item Env:\AR_DRY_RUN -ErrorAction SilentlyContinue
            (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{})).dryRun | Should -BeTrue
        }
        finally { if ($null -ne $saved) { $env:AR_DRY_RUN = $saved } }
    }
    It 'honours an explicit dryRun=false' {
        (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ dryRun = $false })).dryRun | Should -BeFalse
    }
    It 'migrates from the legacy AR_DRY_RUN app setting when the field is absent' {
        $saved = $env:AR_DRY_RUN
        try {
            $env:AR_DRY_RUN = 'false'
            (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{})).dryRun | Should -BeFalse
        }
        finally {
            if ($null -ne $saved) { $env:AR_DRY_RUN = $saved } else { Remove-Item Env:\AR_DRY_RUN -ErrorAction SilentlyContinue }
        }
    }
    It 'an explicit dryRun always wins over the legacy env' {
        $saved = $env:AR_DRY_RUN
        try {
            $env:AR_DRY_RUN = 'false'
            (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ dryRun = $true })).dryRun | Should -BeTrue
        }
        finally {
            if ($null -ne $saved) { $env:AR_DRY_RUN = $saved } else { Remove-Item Env:\AR_DRY_RUN -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Compare-ARConfig' {
    It 'reports only changed leaves' {
        $a = ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ mode = 'soft' })
        $b = ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ mode = 'hard' })
        $diff = Compare-ARConfig -Old $a -New $b
        $diff.Keys | Should -Contain 'mode'
        $diff['mode'].old | Should -Be 'soft'
        $diff['mode'].new | Should -Be 'hard'
    }
    It 'returns no changes for identical configs' {
        $a = ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ mode = 'soft' })
        (Compare-ARConfig -Old $a -New $a).Count | Should -Be 0
    }
}

Describe 'Get-ARPersonalSiteUrl' {
    It 'reduces a OneDrive web URL to the site collection' {
        Get-ARPersonalSiteUrl -WebUrl 'https://contoso-my.sharepoint.com/personal/jos_contoso_com/Documents' |
            Should -Be 'https://contoso-my.sharepoint.com/personal/jos_contoso_com'
    }
    It 'returns null for a non-personal URL' {
        Get-ARPersonalSiteUrl -WebUrl 'https://contoso.sharepoint.com/sites/team' | Should -BeNullOrEmpty
    }
    It 'returns null for empty input' { Get-ARPersonalSiteUrl -WebUrl '' | Should -BeNullOrEmpty }
}

Describe 'ConvertFrom-ARBase64Url' {
    It 'round-trips a JWT-style base64url segment' {
        $json = '{"alg":"RS256","typ":"JWT"}'
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        [Text.Encoding]::UTF8.GetString((ConvertFrom-ARBase64Url $b64)) | Should -Be $json
    }
}

Describe 'Test-ARFeatureEnabled' {
    It 'reads the per-trigger flag from a sanitised config' {
        $c = ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ features = [pscustomobject]@{ revokeSessions = [pscustomobject]@{ atDisable = $true } } })
        Test-ARFeatureEnabled -FeatureConfig $c -Feature 'revokeSessions' -Trigger 'disable' | Should -BeTrue
        Test-ARFeatureEnabled -FeatureConfig $c -Feature 'revokeSessions' -Trigger 'inactive' | Should -BeFalse
    }
}

Describe 'Feature catalog trigger scope' {
    It 'disableAccount supports inactive only' {
        $f = (Get-ARFeatureCatalog | Where-Object key -eq 'disableAccount')
        $f.supports | Should -Be @('inactive')
    }
    It 'licence/group/soft-delete removal support inactive AND disable' {
        foreach ($k in 'removeLicenses', 'removeFromGroups', 'softDeleteUser') {
            $s = (Get-ARFeatureCatalog | Where-Object key -eq $k).supports
            $s | Should -Contain 'inactive'
            $s | Should -Contain 'disable'
        }
    }
    It 'forces disableAccount off at unsupported triggers' {
        $c = ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{ features = [pscustomobject]@{ disableAccount = [pscustomobject]@{ atInactive = $true; atDisable = $true; atDelete = $true } } })
        $c.features.disableAccount.atInactive | Should -BeTrue
        $c.features.disableAccount.atDisable | Should -BeFalse
        $c.features.disableAccount.atDelete | Should -BeFalse
    }
}

Describe 'Test-ARUserExcluded (global exclusions)' {
    It 'returns false when nothing is configured (no external calls)' {
        $fc = [pscustomobject]@{ inactive = [pscustomobject]@{ exclusionGroupId = ''; excludeSharedMailboxes = $false } }
        (Test-ARUserExcluded -UserId 'u1' -FeatureConfig $fc).Excluded | Should -BeFalse
    }
    It 'excludes a shared/room/equipment mailbox' {
        Mock -ModuleName AutoRevocate Get-ARNonUserMailboxObjectIds { @{ 'shared1' = 'SharedMailbox' } }
        $fc = [pscustomobject]@{ inactive = [pscustomobject]@{ exclusionGroupId = ''; excludeSharedMailboxes = $true } }
        $r = Test-ARUserExcluded -UserId 'shared1' -FeatureConfig $fc
        $r.Excluded | Should -BeTrue
        $r.Reason | Should -Match 'mailbox'
        (Test-ARUserExcluded -UserId 'someone-else' -FeatureConfig $fc).Excluded | Should -BeFalse
    }
    It 'excludes an exclusion-group member' {
        Mock -ModuleName AutoRevocate Get-ARExclusionGroupMemberIds { @{ 'bg1' = $true } }
        $fc = [pscustomobject]@{ inactive = [pscustomobject]@{ exclusionGroupId = 'grp'; excludeSharedMailboxes = $false } }
        (Test-ARUserExcluded -UserId 'bg1' -FeatureConfig $fc).Excluded | Should -BeTrue
        (Test-ARUserExcluded -UserId 'other' -FeatureConfig $fc).Excluded | Should -BeFalse
    }
    It 'propagates a read failure (callers fail closed)' {
        Mock -ModuleName AutoRevocate Get-ARNonUserMailboxObjectIds { throw 'EXO unreachable' }
        $fc = [pscustomobject]@{ inactive = [pscustomobject]@{ exclusionGroupId = ''; excludeSharedMailboxes = $true } }
        { Test-ARUserExcluded -UserId 'x' -FeatureConfig $fc } | Should -Throw
    }
}

Describe 'Test-ARVersionNewer' {
    It 'detects a newer patch' { Test-ARVersionNewer -Installed '1.0.0' -Latest '1.0.1' | Should -BeTrue }
    It 'detects a newer minor' { Test-ARVersionNewer -Installed '1.2.0' -Latest '1.3.0' | Should -BeTrue }
    It 'detects a newer major' { Test-ARVersionNewer -Installed '1.9.9' -Latest '2.0.0' | Should -BeTrue }
    It 'is false for equal versions' { Test-ARVersionNewer -Installed '1.4.2' -Latest '1.4.2' | Should -BeFalse }
    It 'is false when the installed is ahead' { Test-ARVersionNewer -Installed '2.0.0' -Latest '1.9.9' | Should -BeFalse }
    It 'compares numerically, not lexically (1.10 > 1.9)' { Test-ARVersionNewer -Installed '1.9.0' -Latest '1.10.0' | Should -BeTrue }
    It 'treats missing trailing parts as zero' { Test-ARVersionNewer -Installed '1.0' -Latest '1.0.0' | Should -BeFalse }
    It 'sees a shorter installed as older when the extra part is non-zero' { Test-ARVersionNewer -Installed '1.0' -Latest '1.0.1' | Should -BeTrue }
    It 'tolerates a leading v' { Test-ARVersionNewer -Installed 'v1.0.0' -Latest 'v1.0.1' | Should -BeTrue }
    It 'cannot compare a non-release build and returns false' { Test-ARVersionNewer -Installed 'dev' -Latest '1.0.1' | Should -BeFalse }
    It 'returns false when the latest is unparseable' { Test-ARVersionNewer -Installed '1.0.0' -Latest 'not-a-version' | Should -BeFalse }
}

Describe 'Version-check config (versionCheck.notifyServicedesk)' {
    It 'defaults the notification ON when the field is absent' {
        (ConvertTo-ARSanitisedConfig -Raw ([pscustomobject]@{})).versionCheck.notifyServicedesk | Should -BeTrue
    }
    It 'honours an explicit off' {
        $raw = [pscustomobject]@{ versionCheck = [pscustomobject]@{ notifyServicedesk = $false } }
        (ConvertTo-ARSanitisedConfig -Raw $raw).versionCheck.notifyServicedesk | Should -BeFalse
    }
    It 'is present in the default config' {
        (Get-ARDefaultConfig).versionCheck.notifyServicedesk | Should -BeTrue
    }
}

Describe 'Invoke-ARVersionCheck (orchestration)' {
    BeforeEach {
        Mock -ModuleName AutoRevocate Get-ARConfig { [pscustomobject]@{ Version = '1.0.0'; ReleasesUrl = 'https://example/releases'; SenderUpn = 'sender@contoso.com' } }
        Mock -ModuleName AutoRevocate Get-ARFeatureConfig { [pscustomobject]@{ servicedeskEmail = 'sd@contoso.com'; versionCheck = [pscustomobject]@{ notifyServicedesk = $true } } }
        Mock -ModuleName AutoRevocate Save-ARVersionCheckState { }
        Mock -ModuleName AutoRevocate Send-ARVersionUpdateMail { }
        Mock -ModuleName AutoRevocate Write-ARSystemActivity { }
        Mock -ModuleName AutoRevocate Get-ARLatestPublishedVersion { '1.0.1' }
    }

    It 'does nothing when the next check is not yet due' {
        Mock -ModuleName AutoRevocate Get-ARVersionCheckState { [pscustomobject]@{ nextCheckUtc = [DateTimeOffset]::UtcNow.AddDays(5).ToString('o'); latestVersion = '1.0.0' } }
        Invoke-ARVersionCheck
        Should -Invoke -ModuleName AutoRevocate Get-ARLatestPublishedVersion -Times 0
        Should -Invoke -ModuleName AutoRevocate Save-ARVersionCheckState -Times 0
    }

    It 'emails the service desk once when a newer version appears' {
        Mock -ModuleName AutoRevocate Get-ARVersionCheckState { $null }   # first run
        Invoke-ARVersionCheck
        Should -Invoke -ModuleName AutoRevocate Send-ARVersionUpdateMail -Times 1
        Should -Invoke -ModuleName AutoRevocate Save-ARVersionCheckState -Times 1
    }

    It 'does not email when notification is disabled (but still records the update)' {
        Mock -ModuleName AutoRevocate Get-ARFeatureConfig { [pscustomobject]@{ servicedeskEmail = 'sd@contoso.com'; versionCheck = [pscustomobject]@{ notifyServicedesk = $false } } }
        Mock -ModuleName AutoRevocate Get-ARVersionCheckState { $null }
        Invoke-ARVersionCheck
        Should -Invoke -ModuleName AutoRevocate Send-ARVersionUpdateMail -Times 0
        Should -Invoke -ModuleName AutoRevocate Save-ARVersionCheckState -Times 1
    }

    It 'does not re-email a version it already notified about' {
        Mock -ModuleName AutoRevocate Get-ARVersionCheckState { [pscustomobject]@{ nextCheckUtc = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o'); latestVersion = '1.0.1'; updateAvailable = $true; notifiedVersion = '1.0.1' } }
        Invoke-ARVersionCheck
        Should -Invoke -ModuleName AutoRevocate Send-ARVersionUpdateMail -Times 0
    }

    It 'is fail-safe on a fetch error: records the attempt, emails nothing, does not throw' {
        Mock -ModuleName AutoRevocate Get-ARLatestPublishedVersion { throw 'network down' }
        Mock -ModuleName AutoRevocate Get-ARVersionCheckState { $null }
        { Invoke-ARVersionCheck } | Should -Not -Throw
        Should -Invoke -ModuleName AutoRevocate Send-ARVersionUpdateMail -Times 0
        Should -Invoke -ModuleName AutoRevocate Save-ARVersionCheckState -Times 1
    }
}
