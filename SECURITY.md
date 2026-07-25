# Security

## The honest headline

M365AutoRevocate's managed identity can **read and modify most of the tenant**:
it can delete users, strip group memberships and licences, unshare any OneDrive,
change mailbox settings, and cancel calendar events. That power is inherent to
what the tool does (offboarding cleanup on arbitrary departing users). Treat the
admin web app and the admin security group as **Tier 0 / privileged access**:
compromise of either is, effectively, tenant compromise.

This document describes the trust boundaries, what the tool does to defend them,
and what the operator must do.

## Trust boundaries

| Boundary | Control |
|----------|---------|
| Who can change behaviour (config) | Delegated Entra sign-in (MSAL) gated by an **assignment-required** enterprise app + the nominated admin security group, **and** in-function bearer-token validation (RS256 against tenant JWKS, audience, issuer, expiry). Both must pass; the API fails closed. |
| Graph webhook endpoint | Function key in the URL **plus** `clientState` validation on every notification. Mismatched notifications are dropped; self-heal is constrained to our own subscription id and rate-limited. |
| Runtime credentials | Managed identity only. No secrets, certificates, or storage keys at runtime. |
| Static admin SPA | Hosted in a **separate storage account** the managed identity has no access to, so a runtime compromise cannot rewrite the page to harvest admin tokens. |
| Mail sending | Exchange Online RBAC for Applications scoped to a **single sender mailbox** - no tenant-wide `Mail.Send`. |

## What the tool does to protect you

- **Circuit breaker (storm guard).** Per-trigger daily caps and a percent-of-
  directory ceiling. One bulk event (a mass disable, an accidental sync
  deletion, a first inactivity scan) trips the breaker: processing pauses and an
  admin must review and resume. This is the primary defence against a single
  mistake becoming thousands of irreversible actions.
- **Fail-closed inactivity scan.** If the exclusion group can't be read, the scan
  aborts rather than run without shielding break-glass/service accounts.
- **Defense in depth on the admin API.** Every admin function validates the token
  itself, so a disabled or misconfigured Easy Auth is a visible 401, not a
  silently open API.
- **Forward-target restriction.** The mailbox-forward address (the tool's most
  attractive exfiltration knob) is validated and, by default, limited to verified
  tenant domains.
- **Everything destructive is idempotent, dry-runnable, and logged** (including
  who changed the config, with an old→new diff).
- **Watchdog + reconciliation.** A daily reconciliation sweep catches missed
  events; a daily watchdog emails the service desk on failures, a stale snapshot,
  a non-empty poison queue, or a pause.

## What the operator must do

1. **Treat the admin group as privileged.** Use PIM for its membership; keep it
   small; prefer a role-assignable group (the deploy attempts this). Any group
   owner or Groups Administrator who can add members effectively gains the tool's
   power.
2. **Start in simulation (dry run)** (on by default) and watch the activity
   log before enabling destructive actions. Turn it off in the web app under
   **Configuration → Simulation mode** when confident.
3. **Set safety limits and an exclusion group** before turning on inactivity
   monitoring or any delete/soft-delete action.
4. **Grant only the Graph roles you use.** The Diagnostics tab nudges when an
   enabled action lacks its permission; conversely, drop roles for actions you
   never enable (see [docs/permissions.md](docs/permissions.md)).
5. **Protect the subscription and monitor the log.** The Diagnostics tab shows
   subscription health, function heartbeats, the poison queue, and pause state.

## Reporting a vulnerability

Please report security issues privately to the repository owner (Lieben
Consultancy) rather than opening a public issue.
