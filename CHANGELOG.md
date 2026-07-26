# Changelog

All notable changes to M365AutoRevocate are documented here. The version is the
single source in `VERSION` (stamped into the module manifest, the `AR_VERSION`
app setting, and the web app footer at deploy time).

## 1.0.1
- **Cloud Shell IP whitelisting.** In Azure Cloud Shell the auto-detected IP is
  the container's Azure egress, so it asks for your IP/CIDR (and hints at it from 
  your recent Entra sign-in logs). Auto-detect still applies elsewhere.
- **API permissions maintained in one place and auto-reconciled.** The Graph /
  SharePoint / Exchange app roles (and any Entra directory roles) now live in
  `deploy/permissions.json`. Both the full deploy and updates
  reconcile the managed identity against it
- **Configurable tool name in emails.** A new "Tool name in emails" setting
  (Configuration tab) replaces "M365AutoRevocate" in the messages sent to managers
  and the service desk, so IT can make them recognisable. Defaults to the product
  name.
- **Cleaner hand-off email.** Dropped the always-empty "Detail" column from the
  owned-artifacts table, and `tokenLifetimePolicy` objects (which a manager cannot
  act on) are no longer listed.

## 1.0.0

### Features
- **Weekly update check.** checks for new versions weekly, can be disabled in config
- **New action "Disable the account"** (inactive trigger only): blocks sign-in by
  disabling the account. It reads the current state first and, if the account is
  already disabled, leaves it untouched
- **"Preview next changes"** on the Actions tab opens a projected-changes view
  across all three triggers

### UX
- The Actions table shows a **loading spinner** until the config has loaded,
  instead of appearing blank for the first couple of seconds.
- **Simulation (dry run)** config setting

### Deploy
- **One-line installer (`install.ps1`).** Run
  `iex (irm https://raw.githubusercontent.com/jflieben/M365AutoRevocate/main/install.ps1)`
  in Azure Cloud Shell (PowerShell)
- **Automatic releases.** The CI workflow publishes a GitHub release (code, web,
  installer, checksums) the first time a bumped `VERSION` reaches `main`.
- **New optional `-Tags` parameter** to apply resource-group tags

### Platform
- **Function App runtime upgraded to PowerShell 7.6** (7.4 is being retired).
- **The Graph subscription is created during install** now, not lazily on the
  first cold start

### Safety
- **Circuit breaker (storm guard).** Per-trigger daily caps and a percent-of-
  directory ceiling. On breach the tool pauses all processing and surfaces a
  "review & resume" banner in the web app, so one bulk event (an accidental mass
  disable, a sync mishap, a first inactivity scan in an old tenant) cannot
  cascade into thousands of cleanups.
- **Inactivity scan fails closed.** If the exclusion group cannot be read, the
  scan aborts instead of running without protecting break-glass/service accounts.
- **Admin API defense in depth.** Every admin function validates the delegated
  bearer token itself (RS256 against tenant JWKS, audience, issuer, expiry) and
  fails closed
- **Exclusion group resolved by object id**, not the non-unique display name.
- **Forward/service-desk addresses validated**; the mailbox-forward target is
  restricted to verified tenant domains unless external forwarding is explicitly
  allowed.
- **Dry-run defaults to on** when unset (fail safe).

### Correctness
- Recurring meetings are now cancelled via `calendarView` (series with future
  occurrences are no longer missed).
- Atomic idempotency claim (insert-or-409) prevents duplicate processing when an
  `updated` and a `deleted` arrive together.
- Directory snapshot is resilient per user and truncates oversized owned-object
  lists (64KB table-property cap).
- Delete-timing hard->soft drains any stranded pending hard-deletes.
- Mail failure no longer aborts (and poisons) the whole cleanup.
- Duplicate Graph subscriptions are pruned; lifecycle events reconcile inline.

### Scale
- **Directory snapshot reworked**: delta queries + `$batch` + time-budgeted
  checkpointing, so it stays proportional to churn and resumes across runs
  instead of dying at the timeout in a large tenant. Long-deleted rows are pruned.
- Inactivity scan enqueues work instead of processing inline.
- OneDrive unshare is site-level only (O(1));
- Activity-log cleanup uses entity-group batch deletes.
