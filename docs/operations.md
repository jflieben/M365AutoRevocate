# Operations runbook

Day-two operations and the failure modes a new operator will actually hit. The
**Diagnostics** tab of the admin web app is the first stop for all of these.

## First run

1. Deploy, then open the web app. It starts in **simulation mode** (dry run) and
   shows a **Simulation** banner.
2. Complete the setup wizard (simulation on/off, delete timing, service desk,
   inactivity, exclusion group). Set **safety limits** before enabling anything
   destructive.
3. Watch the **Activity log** for a few real offboardings. Dry-run entries show
   exactly what *would* happen.
4. When confident, turn off simulation under **Configuration → Simulation mode**
   in the web app.

## The circuit breaker paused everything

A red **"Processing is paused"** banner means a run hit a daily cap or the
percent ceiling (e.g. a bulk disable, or a first inactivity scan flagged
thousands). Nothing is running; queued work is held.

1. Open the **Activity log**; the "PAUSED by storm guard" entry states the reason
   and count.
2. Decide: is this a real mass event you want to process, or a mistake? If a
   mistake, fix the cause (restore the accounts, correct the sync) first.
3. If intended, raise the relevant cap on the **Configuration** tab (deliberately),
   then click **Review & resume**. Resume clears the latch and today's counters.

## Mail isn't sending (right after deploy)

Exchange Online RBAC for Applications takes **up to ~30 minutes** to propagate.
Hand-off emails will fail until then; the failure is recorded in the action
summary and the rest of the cleanup still runs. It resolves itself. If it
persists beyond an hour, re-check the mailbox scoping (docs/permissions.md).

## An action fails with "permission" errors

The Diagnostics tab shows a **Missing Graph permission(s)** banner listing any
role an enabled action needs but the identity lacks. Grant + consent it on the
Function App's enterprise application (Global Admin / Privileged Role Admin), or
disable the action.

## Inactivity monitoring says P1 required

`signInActivity` is an Entra ID **P1** premium property and needs the
`AuditLog.Read.All` role. Without both, the scan and the what-if preview cannot
read sign-in data. Assign a P1 licence (tenant-level) and grant the role.

## Something silently stopped

Check the **Function health** table:

- A row that has **never run** (timers) usually means the trigger sync did not
  happen - re-run the deploy, or trigger `syncfunctiontriggers`.
- A **red/error** row shows its last error message. Click through to the Azure
  portal invocations for full logs.
- **Directory snapshot stale** (>48h) degrades delete-time manager/ownership. The
  Watchdog emails the service desk when this happens.

## Poison queue is non-empty

A non-zero **Poison** count on Diagnostics means messages failed processing
repeatedly (5 attempts). Investigate the last error in Application Insights; a
persistently unreachable user or a bug is the usual cause. After fixing, you can
re-drive the message from the `revocations-poison` queue in the portal.

## Missed a deletion/disable

The daily **Reconciliation sweep** (05:15 UTC) enumerates deleted and disabled
users and enqueues any not yet processed, so a missed notification self-corrects
within a day. To force it, trigger `ReconciliationSweep` from the portal.

## Force a directory snapshot

Trigger `DirectorySnapshot` from the portal (Function app → DirectorySnapshot →
Code + Test → Test/Run). Large first-time enumerations resume across runs.

## Roll back a bad config save

The previous config is kept as `config.previous.json` in the `autorevocate-config`
container; copy it over `config.json`. Storage blob versioning (enabled at deploy)
also keeps the full history.
