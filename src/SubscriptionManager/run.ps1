# Creates and renews the Graph change-notification subscription.
#
# Runs on startup (so the subscription exists immediately after deployment --
# and the validation call-back hits a warm app) and every 6 hours thereafter to
# renew well before expiry. Also ensures the state tables exist.

param($Timer)

Initialize-ARTables

Invoke-ARFunctionRun -Name 'SubscriptionManager' -Script {
    $sub = Update-ARSubscriptionState
    Write-Host "Subscription healthy: id=$($sub.id) expires=$($sub.expirationDateTime)."
}
