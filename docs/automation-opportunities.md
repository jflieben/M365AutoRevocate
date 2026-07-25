# Offboarding automation opportunities

The README asks for a "deep search" of what else could be automated when a user
is deleted. This is that catalogue. Each item lists whether it is **feasible
with Microsoft Graph application permissions** (what this tool uses), the
permission it would need, and its status in this project.

Legend for **Status**: ✅ implemented · 🟡 optional/extension point wired but off
by default · 🔭 proposed (not built) · ✋ needs a non-Graph API / manual step.

Each implemented action is independently configurable to run **at inactive**,
**at disable**, **at delete**, or any combination, from the admin web app.

## Implemented

| # | Action | Trigger(s) | Graph surface | Permission | Status |
|---|--------|-----------|---------------|-----------|--------|
| 1 | **Unshare OneDrive** - delete every sharing link / non-inherited grant | inactive, disable, delete | `GET/DELETE /drives/{id}/items/{id}/permissions` | `Sites.FullControl.All` | ✅ |
| 2 | **Hand-off email** to the manager (fallback service desk) listing leftover artifacts | inactive, disable, delete | `POST /users/{sender}/sendMail` (EXO RBAC scoped) | EXO `Application Mail.Send` | ✅ |
| 3 | **Revoke sign-in / refresh tokens** | inactive, disable | `POST /users/{id}/revokeSignInSessions` | `User.ReadWrite.All` | ✅ |
| 4 | **Set an auto-reply** on the mailbox | inactive, disable | `PATCH /users/{id}/mailboxSettings` | `MailboxSettings.ReadWrite` | ✅ |
| 5 | **Add a mailbox forward** (inbox rule) | inactive, disable | `POST /users/{id}/mailFolders/inbox/messageRules` | `MailboxSettings.ReadWrite` | ✅ |
| 6 | **Cancel organised meetings** & notify attendees | inactive, disable | `POST /users/{id}/events/{id}/cancel` | `Calendars.ReadWrite` | ✅ |
| 7 | **Inactive-user detection** - daily scan on `lastSuccessfulSignInDateTime` (fallback: creation date), with an exclusion group | inactive | `GET /users?$select=signInActivity` | `AuditLog.Read.All` + Entra ID P1 | ✅ |
| 8 | **Remove directly assigned licences** | inactive | `POST /users/{id}/assignLicense` | `User.ReadWrite.All` | ✅ |
| 9 | **Remove group memberships** (dynamic/mail-enabled skipped) | inactive | `DELETE /groups/{id}/members/{id}/$ref` | `GroupMember.ReadWrite.All` | ✅ |
| 10 | **Soft delete the account** (always last) | inactive | `DELETE /users/{id}` | `User.DeleteRestore.All` | ✅ |
| 11 | **Owned-object capture** (groups/Teams/apps) via pre-deletion snapshot | delete | `GET /users/{id}/ownedObjects` | `User.ReadWrite.All` | ✅ (always cached) |
| 12 | **Audit trail / activity log** of every run (incl. dry runs) | - | Azure Table `ActivityLog` | - | ✅ |

## High-value, safe to add next

| # | Action | Why it matters | Graph surface | Permission | Status |
|---|--------|----------------|---------------|-----------|--------|
| 13 | **Grant the manager temporary access to the OneDrive** before retention deletes it, and link it in the hand-off email | Lets the manager actually retrieve files, not just be told they exist | `POST /drives/{id}/root/invite` | `Sites.FullControl.All` | 🔭 (see note) |
| 14 | **Re-own orphaned groups/Teams** - where the deleted user was the *only* owner, add the service desk (or manager) as owner | Owner-less M365 groups can't be managed and drift | `GET /groups/{id}/owners`, `POST /groups/{id}/owners/$ref` | `Group.ReadWrite.All` | 🔭 |
| 15 | **Re-own orphaned enterprise apps / SP registrations** the user owned | App ownership gaps block credential rotation & lifecycle | `POST /servicePrincipals/{id}/owners/$ref` | `Application.ReadWrite.All` | 🔭 |
| 16 | **Export the cleanup record to Log Analytics** instead of (or as well as) a table | Central SIEM visibility | Log Ingestion API | - | 🔭 |

> **Note on #13 vs. #1.** The README's intent for OneDrive is "unshare it so all
> links stop working," which #1 does. #5 is the natural complement - kill the
> *external* links but grant the *manager* a fresh, controlled link so the files
> can be recovered during the retention window. It is left as an opt-in because
> it re-shares data and some orgs want a hard stop. The hook is obvious: call
> `root/invite` for the manager inside `Invoke-ARRevocation` after the unshare.

## Feasible but higher-risk / broader blast radius

| # | Action | Notes | Permission |
|---|--------|-------|-----------|
| 9  | **Reassign SharePoint site collection admins** for sites the user solely administered | Needs enumeration of site admins; SharePoint admin surface is clunky via Graph | `Sites.FullControl.All` |
| 10 | **Remove stale PIM eligible/active role assignments** referencing the principal | Deletion usually clears these, but tenants accumulate orphans | `RoleManagement.ReadWrite.Directory` |
| 11 | **Delete registered/owned devices** that are now orphaned | Capture `ownedDevices` in the snapshot first | `Device.ReadWrite.All` |
| 12 | **Revoke guest sponsorships** where the user sponsored external guests | Sponsors become dangling references | `User.ReadWrite.All` |

## The disable trigger (now implemented)

The tool subscribes to `updated,deleted` and, on an `accountEnabled → false`
transition, runs the disable-trigger actions above (revoke sessions, auto-reply,
forward, cancel meetings - plus optionally OneDrive unshare / notify manager).
Still open in this space:

- **Convert the mailbox to shared** - Exchange Online only (`Set-Mailbox -Type Shared`); ✋ non-Graph.
- **Remove delegate / send-as permissions** - Exchange Online. ✋

## Not Microsoft Graph (document as manual runbook)

- **Power Platform** flows/apps/connections owned by the user → Power Platform admin APIs. ✋
- **Azure RBAC role assignments** on subscriptions/resources → ARM (`Microsoft.Authorization`), not Graph. ✋
- **Third-party SaaS** (SCIM deprovisioning) → the IdP / SaaS app. ✋

## Design principles applied here

1. **Everything destructive is idempotent and logged.** Re-running never
   double-acts (see the `ProcessedActions` table + the atomic claim in `Invoke-ARRevocation`).
2. **Capture-before-you-lose-it.** Anything Graph erases on deletion (manager,
   ownership, drive id) is snapshotted ahead of time (`DirectorySnapshot`).
3. **Default to the README's literal intent; make the spicier actions opt-in.**
   Broad, re-sharing, or cross-object-mutating actions ship as documented
   extension points rather than on-by-default behaviour.
