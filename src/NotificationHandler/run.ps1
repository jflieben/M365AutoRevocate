using namespace System.Net

# HTTP endpoint that Microsoft Graph calls for change notifications.
#
# Two jobs, both of which must be FAST (Graph enforces a short response window):
#   1. Answer the subscription validation handshake by echoing validationToken.
#   2. For each 'updated'/'deleted' notification, validate clientState and drop
#      the user id onto the 'revocations' queue for asynchronous processing.
#
# The queue is written over REST with the managed identity (Send-ARQueueMessage)
# rather than a host output binding: a binding failure kills the invocation
# before our code runs, invisibly. No heavy work happens here -- OneDrive
# unshare etc. run in RevocationProcessor.

param($Request, $TriggerMetadata)

# --- 1. Validation handshake ---------------------------------------------------
$validationToken = $null
if ($Request.Query) { $validationToken = $Request.Query['validationToken'] }
if ($validationToken) {
    Write-Host 'Responding to Graph subscription validation handshake.'
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Headers    = @{ 'Content-Type' = 'text/plain' }
            Body       = [string]$validationToken
        })
    return
}

# --- 2. Change notifications ---------------------------------------------------
try {
    $cfg = Get-ARConfig

    # Normalise the body: depending on the request's exact content-type header
    # the worker hands it to us pre-parsed, as a string, or as raw bytes. The
    # property-existence idiom (PSObject.Properties['value']) silently returns
    # nothing on a Hashtable body, so use plain member access throughout.
    $rawBody = $Request.Body
    $bodyType = if ($null -eq $rawBody) { 'null' } else { $rawBody.GetType().Name }
    $payload = $rawBody
    if ($payload -is [byte[]]) { $payload = [System.Text.Encoding]::UTF8.GetString($payload) }
    if ($payload -is [string]) {
        try { $payload = $payload | ConvertFrom-Json }
        catch { Write-Warning "Notification body is not valid JSON ($($payload.Length) chars): $($_.Exception.Message)" }
    }
    $notifications = @()
    if ($payload -and $payload.value) { $notifications = @($payload.value) }
    Write-Host "NotificationHandler: received $($notifications.Count) notification(s) (body arrived as $bodyType)."
    if ($notifications.Count -eq 0 -and $rawBody) {
        # A non-empty body we could not interpret is the one case that must not
        # pass silently: log what it looked like (truncated, no secrets).
        $preview = ("$(if ($rawBody -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($rawBody) } else { $rawBody | ConvertTo-Json -Compress -Depth 5 })")
        if ($preview.Length -gt 500) { $preview = $preview.Substring(0, 500) + '...' }
        Write-Warning "NotificationHandler: body contained no notifications. Preview: $preview"
    }

    $seen = @{}
    $selfHealed = $false
    $lifecycleHandled = $false
    $messages = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $notifications) {
        Write-Host "NotificationHandler: notification changeType=$($n.changeType) subscription=$($n.subscriptionId) resource=$($n.resource)."
        # Lifecycle events (reauthorizationRequired / subscriptionRemoved / missed)
        # are handled by the SubscriptionManager timer; just note them here.
        if ($n.lifecycleEvent) {
            # reauthorizationRequired / subscriptionRemoved / missed all mean
            # "reconcile the subscription now" -- don't wait up to 6h for the
            # SubscriptionManager timer. Once per invocation.
            Write-Warning "Lifecycle event received: $($n.lifecycleEvent) for subscription $($n.subscriptionId)."
            Write-ARSystemActivity -EventName "Subscription lifecycle event: $($n.lifecycleEvent)" -Detail "subscriptionId=$($n.subscriptionId)"
            if (-not $lifecycleHandled) {
                $lifecycleHandled = $true
                try { Update-ARSubscriptionState | Out-Null } catch { Write-Warning "Lifecycle reconcile failed: $($_.Exception.Message)" }
            }
            continue
        }

        if ($n.clientState -ne $cfg.ClientState) {
            # This notification failed authentication (its clientState is not
            # ours). Drop it. It MAY be a legitimate case of our clientState
            # having rotated while the live subscription still carries the old
            # value -- so we attempt a self-heal, but only for OUR recorded
            # subscription id and at most once an hour (see
            # Invoke-ARConstrainedSelfHeal). We never delete an arbitrary id the
            # untrusted caller names.
            Write-Warning "Dropping notification for subscription $($n.subscriptionId): clientState mismatch."
            Write-ARSystemActivity -EventName 'Change notification dropped (clientState mismatch)' -Detail "subscriptionId=$($n.subscriptionId)"
            if (-not $selfHealed) {
                $selfHealed = $true
                try { Invoke-ARConstrainedSelfHeal -SubscriptionId $n.subscriptionId }
                catch { Write-Warning "Constrained self-heal failed: $($_.Exception.Message)" }
            }
            continue
        }

        # 'deleted' -> delete trigger; 'updated' -> possible disable trigger.
        $change = if ($n.changeType -match 'deleted') { 'deleted' } elseif ($n.changeType -match 'updated') { 'updated' } else { $null }
        if (-not $change) { Write-Host "NotificationHandler: ignoring unsupported changeType '$($n.changeType)'."; continue }

        $id = $n.resourceData.id
        if (-not $id) { Write-Warning 'NotificationHandler: notification had no resourceData.id; skipping.'; continue }

        $key = "$change|$id"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $messages.Add((@{ userId = $id; changeType = $change } | ConvertTo-Json -Compress))
        Write-Host "Queuing $change for user $id."
    }

    foreach ($m in $messages) {
        Send-ARQueueMessage -Content $m
    }
    Write-Host "NotificationHandler: enqueued $($messages.Count) message(s) on the revocations queue."

    # Heartbeat so the Diagnostics tab reflects that Graph is reaching us at all.
    # Sampled (at most once per 30s per worker) because in a large tenant this
    # endpoint fires constantly and must not write the table on every POST.
    Write-ARHeartbeatSampled -Name 'NotificationHandler' -Status ok
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Accepted })
}
catch {
    # Return 5xx so Graph retries rather than silently dropping the event.
    Write-Error "Failed to process notification: $($_.Exception.Message)"
    Write-ARHeartbeat -Name 'NotificationHandler' -Status error -ErrorMessage $_.Exception.Message
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::InternalServerError
            Body       = 'Notification processing failed.'
        })
}
