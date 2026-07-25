# Data handling & privacy

M365AutoRevocate processes and caches personal data in order to complete
offboarding after a user is gone. This page states exactly what is stored, where,
for how long, and how to purge it. All storage is in **your** tenant's Azure
subscription (the resource group the deploy created); nothing leaves it.

## What is stored

| Store (Azure Table/Blob) | Personal data | Why |
|--------------------------|---------------|-----|
| `DirectorySnapshot` (table) | Every user's UPN, display name, department, manager id/UPN/email, owned-object list, OneDrive id | Graph severs these relationships on deletion, so they must be cached *before* deletion to email the manager and list leftover artifacts. |
| `PendingHardDeletes` (table) | UPN + display name of users soft-deleted, awaiting permanent deletion (hard mode only) | To run cleanup at permanent deletion. |
| `ProcessedActions` (table) | User id + UPN + a summary of actions taken | Idempotency + audit. |
| `ActivityLog` (table) | Per-run detail: user name/UPN/id, actions, timestamps; plus system events incl. the admin UPN who saved config | The audit feed shown in the web app. |
| `config.json` / `config.previous.json` (blob) | The exclusion group name, service desk and forward addresses | Behavioural configuration. |
| `SafetyState` / `FunctionHeartbeats` (tables) | No personal data (counters, timestamps, function status) | Circuit breaker + diagnostics. |

Application Insights also records operational logs (function traces). These
contain user ids/UPNs in log lines; their retention is governed by the Log
Analytics workspace the deploy creates (default 30 days).

## Retention

- **Activity log:** configurable on the Configuration tab (`logRetentionDays`,
  default 365, clamped 7-3650). The weekly cleanup deletes older entries.
- **Directory snapshot:** rows for users deleted more than **60 days** ago are
  pruned by the weekly maintenance run (well past the 30-day hard-delete window).
  Live users' rows are refreshed, not accumulated.
- **Processed/pending:** processed markers persist for idempotency; pending rows
  are removed once the hard delete completes.
- **App Insights / Log Analytics:** per the workspace retention setting.

## Purging on decommission

Run the uninstaller without `-KeepData`:

```powershell
./deploy/Remove-M365AutoRevocate.ps1 -SubscriptionId <sub> -SenderUpn noreply@contoso.com
```

This deletes the resource group, which removes every table, blob, and the Log
Analytics workspace along with it. With `-KeepData` the storage account is
retained for audit; delete it later with `az group delete`.

## Lawful basis / DPA notes

The data cached is the minimum needed to complete a legitimate administrative
task (offboarding) that the tenant already has the rights to perform directly in
Microsoft 365. No data is shared with Lieben Consultancy or any third party; the
tool runs entirely within the customer tenant on the customer's managed identity.
