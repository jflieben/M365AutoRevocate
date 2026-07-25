# Changelog

All notable changes to M365AutoRevocate are documented here. The version is the
single source in `VERSION` (stamped into the module manifest, the `AR_VERSION`
app setting, and the web app footer at deploy time).

## Unreleased

### Features
- **Weekly update check.** A new `VersionChecker` timer compares the deployed
  version against the `VERSION` file in the public repo about once a week, at a
  randomised time so many installs never hit the repo at the same instant. When
  the repo is ahead, the admin console shows an "Update available" banner (and
  annotates the footer version), and, unless disabled, the service desk is
  emailed once per new version. The check and the in-app banner always run; only
  the email is optional, via the setup wizard or Configuration
  ("Email service desk about new versions"). Status (installed, latest, last
  checked) is on the Diagnostics tab. Override targets with the `AR_VERSION_URL`
  and `AR_RELEASES_URL` app settings for a fork or internal mirror.
- **New action "Disable the account"** (inactive trigger only): blocks sign-in by
  disabling the account. It reads the current state first and, if the account is
  already disabled, leaves it untouched and says so, so the audit/email never
  claim a change that did not happen.
- **Licence removal, group removal and soft delete now also run at the disable
  trigger** (previously inactive-only), so a disabled account can be fully cleaned
  up as well as an inactive one.
- **"Preview next changes"** on the Actions tab opens a projected-changes view
  across all three triggers: the inactive accounts the next scan will flag, the
  already-disabled accounts the reconciliation will still action, and the deleted
  accounts awaiting cleanup. It lists display name, UPN and the dates we know
  (created, last sign-in, deleted, and in hard mode when each is due), not just a
  count. It reflects the on-screen (unsaved) settings so you can check before you
  save. The old inline count on the Configuration tab is retired in its favour.

### UX
- The Actions table now shows a **loading spinner** until the config has loaded,
  instead of appearing blank for the first couple of seconds.
- **Simulation (dry run) moved into the tool.** It used to be a deploy-time
  `-DryRun` switch / `AR_DRY_RUN` app setting that operators could barely see or
  change. It is now a first-class behaviour setting: a question in the setup
  wizard and a toggle on the Configuration tab (**Simulation mode**). Flipping it
  takes effect live (no redeploy or restart), and the on-screen banner links
  straight to it. New installs start in simulation; existing deployments keep
  their current mode across the upgrade (migrated from `AR_DRY_RUN` on first read)
  and persist it on the next save.

### Deploy
- **One-line installer (`install.ps1`).** Run
  `iex (irm https://raw.githubusercontent.com/jflieben/M365AutoRevocate/main/install.ps1)`
  in Azure Cloud Shell (PowerShell): it downloads the latest release straight
  from GitHub, prompts for the five settings, and runs the full deployment. This
  is now the recommended/fastest install (and update) path. It also takes
  parameters for unattended runs and a `-Version` to pin a release.
- **Automatic releases.** A `Release` GitHub workflow watches the `VERSION` file
  on `main`; when it changes (and no matching release exists yet) it runs the
  test gate, packages the function code, web app, checksums and installer, and
  publishes a `v<version>` GitHub release. CI is now test-only and reused by the
  release workflow so the gate lives in one place.
- **Removed the `-Mode` deploy switch** (and the `AR_MODE` app setting it wrote).
  Delete timing (soft/hard) is chosen in the setup wizard and edited on the
  Configuration tab, so it no longer needs a command-line default. A pre-existing
  `AR_MODE` from an older deploy is still honoured as the seed default.
- **New optional `-Tags` parameter** to apply resource-group tags at install, for
  tenants whose governance requires them (e.g. `-Tags @{ CostCentre = '1234' }`).
  Tags are only written when supplied, so a re-run without `-Tags` never clears
  existing (or policy-inherited) resource-group tags.
- **Removed the `-DryRun` deploy switch** and the `AR_DRY_RUN` app setting;
  simulation is configured in the web app now (see above).
- **Removed the unattended install switches `-CreateAdminGroup` and
  `-SkipExchange`.** When the admin security group is missing the deploy now asks
  before creating it, and Exchange Online scoping always runs (it already skips
  gracefully with a warning if the sign-in or mailbox lookup fails).

### Platform
- **Function App runtime upgraded to PowerShell 7.6** (7.4 is being retired).
  Deploy now provisions new apps on 7.6 and migrates an existing app in place on
  re-run (Flex Consumption pins the runtime at create time), so no app is left
  on the retiring version.
- **The Graph subscription is created during install** now, not lazily on the
  first cold start, so `/api/status` shows a healthy subscription right away
  instead of an alarming "missing" state on a brand-new deployment.

## 1.0.0

First distribution-ready release. Hardening pass for public use, including very
large tenants.

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
  fails closed, so a disabled/misconfigured Easy Auth is a visible 401 rather
  than a silently open API.
- **Exclusion group resolved by object id**, not the non-unique display name.
- **Forward/service-desk addresses validated**; the mailbox-forward target is
  restricted to verified tenant domains unless external forwarding is explicitly
  allowed.
- **Dry-run defaults to on** when unset (fail safe).
- **Constrained subscription self-heal**: only our recorded subscription id, at
  most once per hour, so a forged-notification flood cannot flap the subscription.

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
- `updated` firehose: early exit before any Graph call when nothing is enabled,
  per-worker config cache, sampled heartbeat.
- Inactivity scan enqueues work instead of processing inline.
- OneDrive unshare is site-level only (O(1)); the unbounded per-item fallback
  was removed.
- Activity-log cleanup uses entity-group batch deletes.

### Reliability
- **Reconciliation sweep** (daily) enqueues any deletion/disable missed because a
  notification was never delivered.
- Poison-queue depth surfaced on Diagnostics with a banner.
- **Watchdog** (daily) emails the service desk on failing functions, a missing/
  expired subscription, a stale snapshot, a non-empty poison queue, or a pause.
- Config saves keep a rollback copy; storage blob versioning enabled at deploy.

### Distribution
- Versioning (`VERSION` + `AR_VERSION` + UI footer), `LICENSE`, this changelog.
- `-UpdateOnly` deploy mode (code + web only, no interactive Exchange/consent).
- `Remove-M365AutoRevocate.ps1` uninstaller.
- Unattended install switches (`-CreateAdminGroup`, `-SkipExchange`) and earlier
  preflight checks.
- GitHub Actions CI (PSScriptAnalyzer + Pester) and a Pester suite for the pure
  logic.
