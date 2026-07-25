# Configuration surface for M365AutoRevocate.
#
# There are two layers of configuration:
#
#   * INFRA settings (this file, Get-ARConfig) live in Function App application
#     settings. They are endpoints/secrets set once at deploy time and are not
#     meant to be edited by operators. Nothing here grants M365 access -- the
#     tool authenticates only with its managed identity. AR_CLIENT_STATE is just
#     a token Graph echoes back so we can prove a notification is ours.
#
#   * BEHAVIOUR settings (FeatureConfig.ps1, Get-ARFeatureConfig) live in a JSON
#     blob in the storage account so the admin web app can read and edit them
#     live: mode, service desk address, and the per-feature disable/delete
#     matrix with each feature's option values.

$script:ARConfigCache = $null

function Get-ARConfig {
    <#
    .SYNOPSIS
        Returns infra configuration (endpoints/secrets), read once per worker.
    #>
    [CmdletBinding()]
    param([switch]$Refresh)

    if ($script:ARConfigCache -and -not $Refresh) { return $script:ARConfigCache }

    function Get-Setting {
        param([string]$Name, [string]$Default = $null, [switch]$Required)
        $value = [Environment]::GetEnvironmentVariable($Name)
        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($Required) { throw "Required application setting '$Name' is not configured." }
            return $Default
        }
        return $value.Trim()
    }
    function Get-BoolSetting {
        param([string]$Name, [bool]$Default)
        $value = [Environment]::GetEnvironmentVariable($Name)
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        return @('true', '1', 'yes', 'on') -contains $value.Trim().ToLowerInvariant()
    }

    $config = [pscustomobject]@{
        # Operational
        # DryRun is NO LONGER an infra/app setting: it moved to the behaviour
        # config (FeatureConfig) so operators flip simulation on/off live in the
        # web app. It is exposed here as a live ScriptProperty (added below) so
        # every existing `$cfg.DryRun` consumer keeps working AND picks up an
        # operator's change within the behaviour-config TTL -- rather than being
        # frozen for the life of a worker (this infra object is cached forever).

        # Mail
        SenderUpn            = Get-Setting -Name 'AR_SENDER_UPN' -Required          # mailbox used for POST /users/{id}/sendMail

        # Subscription
        SubscriptionResource   = Get-Setting -Name 'AR_SUBSCRIPTION_RESOURCE' -Default '/users'
        SubscriptionChangeType = Get-Setting -Name 'AR_SUBSCRIPTION_CHANGETYPE' -Default 'updated,deleted'
        # Not Required: on the very first boot (right after code deploy, before
        # the deploy sets the URL and restarts) this is empty. SubscriptionManager
        # skips quietly rather than recording a scary error heartbeat on day one.
        NotificationUrl        = Get-Setting -Name 'AR_NOTIFICATION_URL' -Default ''
        ClientState            = Get-Setting -Name 'AR_CLIENT_STATE' -Required

        # State store (Azure Storage, AAD auth via managed identity)
        TableEndpoint        = (Get-Setting -Name 'AR_TABLE_ENDPOINT' -Required).TrimEnd('/')
        BlobEndpoint         = (Get-Setting -Name 'AR_BLOB_ENDPOINT' -Required).TrimEnd('/')
        # Queue endpoint falls back to a derivation from the table endpoint so
        # existing deployments work without a new app setting.
        QueueEndpoint        = (Get-Setting -Name 'AR_QUEUE_ENDPOINT' -Default ((Get-Setting -Name 'AR_TABLE_ENDPOINT' -Required) -replace '\.table\.', '.queue.')).TrimEnd('/')
        RevocationQueue      = 'revocations'
        ConfigContainer      = Get-Setting -Name 'AR_CONFIG_CONTAINER' -Default 'autorevocate-config'

        # Cloud endpoints (override for sovereign clouds)
        GraphResource        = Get-Setting -Name 'AR_GRAPH_RESOURCE' -Default 'https://graph.microsoft.com'
        StorageResource      = Get-Setting -Name 'AR_STORAGE_RESOURCE' -Default 'https://storage.azure.com'
        # Exchange Online admin REST endpoint (mailbox-type lookups; sovereign override).
        ExoResource          = Get-Setting -Name 'AR_EXO_RESOURCE' -Default 'https://outlook.office365.com'

        # Admin API auth (defense in depth under Easy Auth). The admin functions
        # validate the delegated bearer token themselves against these, so a
        # disabled/misconfigured Easy Auth becomes a visible 401 rather than a
        # silently open API. Written by the deploy script; empty disables the
        # in-function JWT check (Easy Auth then stands alone -- logged loudly).
        TenantId             = Get-Setting -Name 'AR_TENANT_ID'
        AdminClientId        = Get-Setting -Name 'AR_ADMIN_CLIENT_ID'
        # OpenID authority host (override for sovereign clouds).
        LoginResource        = Get-Setting -Name 'AR_LOGIN_HOST' -Default 'https://login.microsoftonline.com'
        Version              = Get-Setting -Name 'AR_VERSION' -Default 'dev'

        # Weekly version check: where to read the latest published VERSION and
        # where to point operators for release notes. Defaults target the public
        # repo; override only for a fork or an air-gapped mirror.
        VersionCheckUrl      = Get-Setting -Name 'AR_VERSION_URL' -Default 'https://raw.githubusercontent.com/jflieben/M365AutoRevocate/main/VERSION'
        ReleasesUrl          = Get-Setting -Name 'AR_RELEASES_URL' -Default 'https://github.com/jflieben/M365AutoRevocate'
    }

    # DryRun is a LIVE view of the behaviour config, not a cached snapshot: this
    # infra object is cached for the life of the worker, so reading a frozen
    # boolean would keep a long-lived worker simulating (or acting) even after an
    # operator flipped it in the web app. Get-ARFeatureConfig has its own ~60s
    # TTL, so the flip takes effect quickly. Read-only (there is no setter).
    $config | Add-Member -MemberType ScriptProperty -Name DryRun -Value { [bool](Get-ARFeatureConfig).dryRun }

    $script:ARConfigCache = $config
    return $config
}

# Table names used by the tool. Kept together so the deploy script and the
# runtime agree on the schema.
$script:ARTables = [pscustomobject]@{
    Pending    = 'PendingHardDeletes'   # users soft-deleted, awaiting permanent deletion (hard delete-timing)
    Directory  = 'DirectorySnapshot'    # cached manager/profile/ownership/accountEnabled, refreshed by DirectorySnapshot timer
    Processed  = 'ProcessedActions'     # dedup, partitioned by trigger (inactive|disable|delete)
    Activity   = 'ActivityLog'          # chronological audit feed shown in the admin web app
    Heartbeats = 'FunctionHeartbeats'   # last run/status/error per function, shown on the Diagnostics tab
    Safety     = 'SafetyState'          # storm-guard counters + paused flag (circuit breaker)
}

function Get-ARTableNames { return $script:ARTables }

$script:ARConfigBlobName = 'config.json'
function Get-ARConfigBlobName { return $script:ARConfigBlobName }
