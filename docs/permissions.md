# Permissions & identity

M365AutoRevocate runs with **no secrets and no certificates**. The Function
App's system-assigned **managed identity** is the only credential the running
tool uses - for Microsoft Graph *and* for the Azure Table/Blob state.

(The deploy script uses admin credentials and, for a couple of admin-time storage
data-plane operations, the storage account key. Those are deploy-time only; the
running tool never uses keys.)

## Microsoft Graph application permissions (managed identity)

> The machine-readable source of truth for every API permission (and any Entra
> directory role) is [`deploy/permissions.json`](../deploy/permissions.json).
> Both `Deploy-M365AutoRevocate.ps1` and `Update-M365AutoRevocate.ps1` reconcile
> the managed identity against it and grant anything missing, so a new feature's
> permission is added in one place and applied on the next deploy or update. The
> table below is the human-readable explanation.

| Permission | Why it is needed |
|-----------|------------------|
| `User.ReadWrite.All` | Read soft-deleted users, `manager`, `ownedObjects`; create the `/users` subscription; `revokeSignInSessions`; disable accounts; remove licences. |
| `User.DeleteRestore.All` | Soft delete inactive users. |
| `Directory.Read.All` | Directory recycle bin, `/users` subscription, exclusion-group membership. |
| `GroupMember.ReadWrite.All` | Remove inactive users from their groups. |
| `Device.ReadWrite.All` | Disable and/or delete the Entra devices a departing user owns. |
| `AuditLog.Read.All` | Read `signInActivity` for inactive-user detection. **Also requires an Entra ID P1 licence** on the tenant. |
| `Sites.FullControl.All` | Enumerate and delete sharing permissions on any user's OneDrive. |
| `MailboxSettings.ReadWrite` | Set the auto-reply and create the forwarding inbox rule. |
| `Calendars.ReadWrite` | Cancel meetings the user organised (notifies attendees). |

These are **tenant-wide** because the actions operate on *arbitrary* departing
users, only known at event time. If you don't use some actions you can drop the
matching permission:

- No OneDrive unshare → drop `Sites.FullControl.All`.
- No auto-reply/forward → drop `MailboxSettings.ReadWrite`.
- No meeting cancellation → drop `Calendars.ReadWrite`.
- No inactive-user monitoring → drop `AuditLog.Read.All` (the others below may
  still be needed at the disable trigger).
- No soft delete at any trigger → drop `User.DeleteRestore.All`.
- No group removal at any trigger → drop `GroupMember.ReadWrite.All`.
- No device disable/delete at any trigger → drop `Device.ReadWrite.All`.
- No token revocation/licence removal and you only act at delete →
  `User.Read.All` suffices instead of `User.ReadWrite.All`.

Note on soft-deleting users: accounts holding privileged directory roles cannot
be deleted by an app with these permissions alone - that is a Graph safeguard,
and such deletions will show as errors in the activity log.

## Power Platform actions (no Graph permission)

The **Disable / Delete / Re-own Power Platform objects** actions operate on the
cloud flows and canvas apps a user owns, through the Power Platform *admin* REST
APIs (`api.bap.microsoft.com`, `api.flow.microsoft.com`, `api.powerapps.com`).
There is **no Microsoft Graph app role** for this, and consenting Graph
permissions does nothing here. Instead an admin authorises the managed identity
as a Power Platform management application **once**, from a PowerShell session
signed in as a Power Platform / Global Administrator:

```powershell
Install-Module -Name "Microsoft.PowerApps.Administration.PowerShell"
Add-PowerAppsAccount
New-PowerAppManagementApp -ApplicationId "<managed-identity-app-id>"
```

The exact app id is shown in the admin web app (Actions tab -> "Power Platform
actions" -> "How to enable"). Until this is done the tool cannot reach the admin
APIs, so those actions stay greyed out in the web app and cannot be enabled.

Apps have no enable/disable flag, so "disable" quarantines the app: a quarantined
app **cannot be opened or played by anyone** (the owner included).
Flow re-own adds the manager as a **co-owner** because a
flow's original owner cannot be reassigned; app re-own is a true ownership
transfer.

## Mail sending: Exchange Online RBAC for Applications (scoped)

The hand-off email is **not** sent with a tenant-wide Graph `Mail.Send`. Instead
the deploy script uses **Exchange Online RBAC for Applications** to grant the
managed identity a send permission scoped to just the sender mailbox. It also
verifies the mailbox exists before continuing. Equivalent manual steps:

```powershell
Connect-ExchangeOnline
Get-Mailbox -Identity noreply@contoso.com                     # verify it exists
New-ServicePrincipal -AppId <MI-AppId> -ObjectId <MI-ObjectId> -DisplayName M365AutoRevocate
New-ManagementScope -Name AR-Sender -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'noreply@contoso.com'"
New-ManagementRoleAssignment -Name AR-Sender-MailSend -App <MI-AppId> -Role 'Application Mail.Send' -CustomResourceScope AR-Sender
```

The tool still calls Graph `POST /users/{sender}/sendMail`; Exchange authorizes it
via this scoped assignment. RBAC for Applications may take up to ~30 minutes to
take effect.

### Read-only recipient access (mailbox types)

To **exclude shared, room and equipment mailboxes** from offboarding at **every**
trigger (inactive, disable and delete), the tool reads `RecipientTypeDetails`
from the Exchange **admin REST API** (Graph has no mailbox-type property). This
needs **two** grants on the managed identity, which do different things:

1. **`Exchange.ManageAsApp`** application permission on the **Office 365 Exchange
   Online** resource (`00000002-0000-0ff1-ce00-000000000000`). This is what lets
   the identity's token be **accepted** by the Exchange management endpoint at
   all. Without it Exchange rejects the token outright with **HTTP 401
   `invalid_token`** (regardless of any role assignment). It requires admin
   consent.
2. The built-in **`View-Only Recipients`** Exchange management role (tenant-wide,
   read-only), granted via **RBAC for Applications**. This **scopes** what the
   (now-accepted) token may do - here, read recipients.

## Admin web app (delegated)

The web app signs users in with **delegated** Entra auth (MSAL) and is gated by an
**Entra security group**:

- An Entra **app registration** (SPA redirect = static site URL, an
  `access_as_user` scope) is created by deploy.
- Its enterprise app has **"assignment required"** on, and the admin security
  group (resolved from `-AdminGroupName`) is assigned - so only group members can
  sign in.
- **App Service Easy Auth** on the Function App validates the delegated token on
  the admin API (`/api/config`, `/api/logs`, `/api/status`, `/api/groups`,
  `/api/preview`, `/api/resume`). The Graph webhook path
  (`/api/NotificationHandler`) is excluded so Graph can still call it (protected
  by its function key).
- **Defense in depth:** each admin function *also* validates the bearer token
  itself (RS256 against the tenant JWKS, audience `api://<clientId>`, issuer,
  expiry) using `AR_TENANT_ID` + `AR_ADMIN_CLIENT_ID`, and fails closed. So a
  disabled or misconfigured Easy Auth becomes a visible 401 instead of a
  silently open API.

The admin API never touches M365 data with the *user's* token - it uses the
managed identity; the user's token only proves group membership.

## Azure RBAC (storage data plane, managed identity)

| Role | Why |
|------|-----|
| `Storage Blob Data Owner` | Flex host storage, deployment container, and the config blob. |
| `Storage Queue Data Contributor` | The `revocations` work queue. |
| `Storage Table Data Contributor` | State + activity-log tables. |

## What the tool never has at runtime

- No client secret or certificate anywhere.
- No storage account **keys** in configuration (data plane is AAD-authenticated).
- No tenant-wide `Mail.Send` (sending is mailbox-scoped via Exchange RBAC).
- `AR_CLIENT_STATE` is not a credential - just a token Graph echoes back to prove
  a notification belongs to our subscription.
