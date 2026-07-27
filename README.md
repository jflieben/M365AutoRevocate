# M365AutoRevocate

<img src="logo.png" alt="M365AutoRevocate logo" width="120" align="right" />

Automated offboarding cleanup for Microsoft 365, the trick is to use Microsoft Graph
change notifications and a small admin web app for config / monitoring.

When a user goes **inactive**, is **disabled**, or is **deleted** it runs the offboarding actions you have enabled. It authenticates with a **managed identity** only - no client secrets or certificates!

## What it can do

| Action | At inactive | At disable | At delete |
|--------|:----------:|:---------:|:--------:|
| Stop sharing the OneDrive (remove every sharing link/grant) | ✓ | ✓ | ✓ |
| Notify manager of owned artifacts (fallback: service desk) | ✓ | ✓ | ✓ |
| Disable owned devices (block sign-in, reversible) | ✓ | ✓ | ✓ |
| Delete owned devices (remove the device object) | ✓ | ✓ | ✓ |
| Disable Power Platform objects (stop flows, quarantine apps) † | ✓ | ✓ | ✓ |
| Delete Power Platform objects (flows & canvas apps) † | ✓ | ✓ | ✓ |
| Re-own Power Platform objects to the manager † | ✓ | ✓ | ✓ |
| Revoke sign-in / refresh tokens | ✓ | ✓ | - |
| Set an auto-reply on the mailbox | ✓ | ✓ | - |
| Add a mailbox forward (inbox rule) | ✓ | ✓ | - |
| Cancel meetings the user organised & notify attendees | ✓ | ✓ | - |
| Remove directly assigned licences | ✓ | - | - |
| Remove group memberships | ✓ | - | - |
| Soft delete the account (always runs last) | ✓ | - | - |

† **Power Platform actions** act on the flows and canvas apps a user owns. An admin has to authorise the tool as a Power Platform admin once, as the GUI will guide you. See [docs/permissions.md](docs/permissions.md).

For **delete**, you choose **soft** (acts when the user hits the recycle bin) or
**hard** (acts once the user is permanently deleted - at the latest one day
before the automatic 30-day purge). See [docs/architecture.md](docs/architecture.md).

## Quick start

Prerequisites: **Global Administrator or Privileged Role Administrator** to consent permissions and register the web app for SSO; **Exchange Administrator** (scoped mailbox send); and an **Entra security group** for the web-app admins.

### Fastest: one line in Azure Cloud Shell (recommended)

1. Open [Azure Cloud Shell](https://shell.azure.com) and choose **PowerShell**
   (you are already signed in to Azure there).
2. Run:

   ```powershell
   iex (irm https://raw.githubusercontent.com/jflieben/M365AutoRevocate/main/install.ps1)
   ```

The installer downloads the **latest release**, asks for the five settings
(subscription id, region, sender mailbox, service desk email, admin group) and
runs the full deployment. To pin a version or run it unattended, download it and
pass parameters instead:

```powershell
irm https://raw.githubusercontent.com/jflieben/M365AutoRevocate/main/install.ps1 -OutFile install.ps1
./install.ps1 -SubscriptionId <sub> -Location westeurope `
    -SenderUpn noreply@contoso.com -ServicedeskEmail servicedesk@contoso.com `
    -AdminGroupName "M365AutoRevocate Admins" -Tags @{ CostCentre = '1234' }
```

## Inactive-user monitoring

A daily scan flags enabled accounts with no successful sign-in
(`signInActivity.lastSuccessfulSignInDateTime`) and runs the inactive-trigger actions on them. Never-signed-in accounts age from their **creation date** (new accounts are safe). Requires an **Entra ID P1** licence (the sign-in activity property is premium).

## Global exclusions (never touched)

- **Exclusion group** - an Entra security group whose (transitive) members are
  ignored everywhere. Use it for break-glass and service accounts.
- **Shared / room / equipment mailboxes** - detected from Exchange
  (`RecipientTypeDetails`) since Graph has no mailbox-type property. On by default.

## Admin web app

The deploy publishes a small **static web app in the storage account**. The
first sign-in runs a short **setup wizard** (delete timing, inactive monitoring,
threshold, exclusion group). Admins can:

- toggle each action's inactive/disable/delete triggers and set their options
  (auto-reply text, forward address, cancellation note),
- adjust the timing, service desk address, and inactivity settings,
- view a live activity log of everything the tool has done.

It uses **delegated Entra sign-in** (MSAL) and is restricted to an **Entra
security group** you nominate. The behavioural config lives in a JSON blob in the
storage account. See [docs/web-app.md](docs/web-app.md).

## Trigger

- A Graph subscription on `/users` (`updated,deleted`) calls an HTTP function.
- A daily **inactivity scan** drives the inactive trigger (when enabled).
- Events are queued and processed asynchronously
- A daily **directory snapshot** (mandatory, auto-seeded at deploy time) caches
  each user's manager and ownership *before* deletion - Graph erases those
  relationships on delete, so they must be captured ahead of time.
- Sending the hand-off email uses **Exchange Online RBAC for Applications**,
  scoped to a single sender mailbox - no tenant-wide `Mail.Send` :).

Diagram and details: [docs/architecture.md](docs/architecture.md).

## Advanced installation from a local clone

```powershell
./deploy/Deploy-M365AutoRevocate.ps1 `
    -SubscriptionId   <your-subscription-id> `
    -Location         westeurope `
    -ServicedeskEmail servicedesk@contoso.com `
    -SenderUpn        noreply@contoso.com `
    -AdminGroupName   "M365AutoRevocate Admins"
```

Add `-Tags @{ CostCentre = '1234'; Env = 'prod' }` if your tenant requires tags
on the resource group.

Then open the
web app: the **setup wizard** takes it from there. The tool starts in
**simulation (dry run)** mode; when you are confident, turn it off under
**Configuration &rarr; Simulation mode** in the web app.

## Permissions (summary)

Managed-identity Graph app roles: `User.ReadWrite.All`, `User.DeleteRestore.All`,
`Directory.Read.All`, `GroupMember.ReadWrite.All`, `AuditLog.Read.All`,
`Sites.FullControl.All`, `MailboxSettings.ReadWrite`, `Calendars.ReadWrite`.
Mail **sending** is granted separately and narrowly via Exchange Online RBAC
scoped to the sender mailbox. Reading **mailbox types** (to exclude shared/room/
equipment mailboxes) needs `Exchange.ManageAsApp` plus the `View-Only Recipients` Exchange role. Storage data plane uses AAD (no keys). The app roles (and any directory roles) are defined once in [`deploy/permissions.json`](deploy/permissions.json). Full rationale and how to tighten: [docs/permissions.md](docs/permissions.md).

## Network access

By default the deploy locks both public surfaces down:

- **Function App** (admin API + the Graph webhook): App Service access
  restrictions allow only your public IP, with the unmatched rule action set to
  **block**. It *also* allows Microsoft Graph's change-notification ranges so
  deletions/disables keep arriving:
  `20.20.32.0/19`, `20.190.128.0/18`, `20.231.128.0/19`, `40.126.0.0/18`
  (row #23 of Microsoft's
  [additional Office 365 IP addresses and URLs](https://learn.microsoft.com/en-us/microsoft-365/enterprise/additional-office365-ip-addresses-and-urls?view=o365-worldwide)).
- **Admin web site** (its own storage account, `arweb<suffix>`): storage firewall
  default action **Deny**, allowing only your public IP.

Outside Azure Cloud Shell the deploy detects your current public IP
automatically. **In Azure Cloud Shell** the detected address is the Cloud Shell
container's Azure egress (not yours): it asks for
the IP/CIDR to allow instead, and tries to show your recent sign-in source IPs
(from the Entra sign-in logs) to help you pick the right one. Pass
`-AllowedAdminIp <ip/cidr>` to skip the prompt.

The **state** storage account (`arevoc<suffix>`) is deliberately left open: the
tool reaches its Table/Blob/Queue over the public endpoints via AAD, and the
Functions host needs account-level access. Only the two *inbound* surfaces above
are restricted.

**Changing who can reach it:**

- Allow another IP/CIDR at deploy time: add `-AllowedAdminIp <ip-or-cidr>` (repeatable)
  to `Deploy-M365AutoRevocate.ps1`. Re-running is idempotent (it replaces the
  `AR-*` rules).
- In the portal: **Function App > Networking > Access restrictions** (keep the
  `AR-Graph-*` rules), and **storage account `arweb<suffix>` > Networking**.
- To opt out entirely (leaves both surfaces public, **not recommended**): pass
  `-SkipNetworkLockdown`. Only do this if you front the app with your own network
  controls (e.g. a corporate proxy / Front Door with WAF).

Note: the admin API is defence-in-depth already (App Service Easy Auth + an
in-function token check, restricted to the admin security group), so a locked-out
IP fails safe. The network lockdown simply removes the surface from the open
internet.

## Configuration

Infra settings live in Function App application settings (written by deploy).
**Behavioural** settings - delete timing, service desk, inactivity monitoring,
and the per-action trigger matrix with option values - live in a config **blob**
and are edited from the web app (or by editing `config.json` in the
`autorevocate-config` container).

## Limitations & caveats

- **Manager/ownership need the snapshot.** Graph drops those on deletion, so the
  delete-time manager email and artifact list depend on the daily snapshot.
- **Disable detection is best-effort.** `updated` notifications don't say what
  changed, so the tool reads `accountEnabled` per notification. High-volume in
  large tenants; it short-circuits when no disable-actions are enabled.
- **Hard-delete timing is poll-based** (reconciler schedule); it acts when the
  account is purged or one day before the automatic 30-day purge.
- **Inactivity detection needs Entra ID P1** (`signInActivity` is premium) and
  the threshold has a 7-day floor as a typo guard.
- **Broad mailbox/calendar/group permissions** are unavoidable for actions that
  act on arbitrary departing users. Sending stays narrowly scoped.
- **The state storage account must keep public network access** (the tool
  reaches its Table/Blob/Queue over the public endpoints via AAD). The deploy's
  network lockdown restricts only the two *inbound* surfaces (Function App + admin
  web site), never the state account - see [Network access](#network-access).
- **Sovereign clouds:** endpoint overrides exist (`AR_GRAPH_RESOURCE`,
  `AR_STORAGE_RESOURCE`, `AR_LOGIN_HOST`) but are untested; commercial cloud is
  the supported target.
- **Large-tenant first snapshot:** the directory snapshot is delta-based and
  checkpointed, so the very first full pass in a 100k+ tenant can span several
  nightly runs before manager/ownership data is complete for everyone.
- **Data handling / privacy:** the tool caches personal data (managers,
  ownership, UPNs) to function after deletion - see [docs/privacy.md](docs/privacy.md).

See also [SECURITY.md](SECURITY.md) and [CHANGELOG.md](CHANGELOG.md).

## Safety (circuit breaker)

Because a single mistake elsewhere (a mass disable, an accidental directory-sync
deletion, turning on inactivity monitoring in an old tenant) could otherwise
cascade into thousands of irreversible cleanups, the tool has a **circuit
breaker**: configurable per-trigger daily caps and a percent-of-directory
ceiling. When a run would exceed a limit it **pauses all processing** and shows a
"review & resume" banner in the web app; queued work is held (not lost) until an
admin resumes. See
[SECURITY.md](SECURITY.md).

## Upgrading

```powershell
./deploy/Update-M365AutoRevocate.ps1 -SubscriptionId <sub> -SenderUpn noreply@contoso.com
```

Redeploys the function code and web app, stamps the new version, and reconciles
the managed identity's API permissions against `deploy/permissions.json`. There are no interactive prompts (suitable for scheduled patching). Granting new permissions needs Global Admin / Privileged Role Admin; without that the missing grants are reported, not fatal. The version is shown in the web app footer.

Re-running the **one-line installer** also updates you: it pulls the latest
release and runs the (idempotent) full deploy, which does everything the update
does plus the Exchange scoping and app registration.

Releases are cut automatically: when a bumped `VERSION` reaches `main`, the CI
workflow's release job (gated on the test job) packages the code/web/installer
and publishes a GitHub release for that version. The in-app weekly
[update check](#update-notifications) compares against that.

### Update notifications

A `VersionChecker` timer compares this install's version against the `VERSION`
file in the public repo about once a week, at a randomised time (so a fleet of
installs never hits the repo all at once). When the repo is ahead:

- the admin console always shows an "Update available" banner and annotates the
  footer version, and
- unless you turn it off, the service desk is emailed once per new version.

## Uninstalling

```powershell
./deploy/Remove-M365AutoRevocate.ps1 -SubscriptionId <sub> -SenderUpn noreply@contoso.com [-KeepData]
```

Removes the resource group, the admin Entra app registration, and the Exchange
Online mailbox scoping. `-KeepData` keeps the storage account (state + activity
log) for audit. The Graph subscription expires on its own once nothing renews it.

## License

See [LICENSE](LICENSE). Commercial (re)use requires prior written consent;
otherwise free to use/modify with attribution. Built by Lieben Consultancy.
