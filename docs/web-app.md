# Admin web app

A small single-page app, hosted as a **static website in the storage account**,
that lets admins configure the tool and read its activity log - without touching
Azure or redeploying.

## What it does

- **First-run setup wizard** - the first sign-in (before any config has been
  saved) asks the basics: soft vs hard delete timing, whether to monitor for
  inactive users, the inactivity threshold, and an exclusion group for
  break-glass/service accounts. Saving writes the config blob and lands on the
  Actions tab; after that the wizard never shows again. It is followed by a
  short **callout tour** across the four tabs (shown once per browser via
  localStorage).
- **Actions tab (default)** - the matrix of every action with three checkboxes:
  *at inactive*, *at disable* and *at delete*. Actions that can't run at a given
  moment show that box greyed out (the same rule is enforced server-side, so a
  hand-edited request can't bypass it). Actions with options (auto-reply text,
  forward address, cancellation note) show those inputs inline.
- **Configuration tab** - delete timing (soft/hard), service desk address, and
  the inactivity settings (on/off, threshold, exclusion group).
- **Activity log tab** - the most recent entries from the `ActivityLog` table:
  user cleanups (including dry runs) with expandable per-run detail, plus
  **system events** (Graph subscription created/renewed/recreated, config
  saves, dropped notifications) so the feed is never empty on a healthy system.
- **Diagnostics tab** - the Graph subscription's health as a one-line verdict
  (the full details: id, resource/changeType, expiry countdown, masked callback
  URL sit behind a "Show details" button) and a **function health** table: last
  run, status, duration, and the last error message of every worker function
  (from the `FunctionHeartbeats` table each function writes into). Function
  names **link to their invocation logs in the Azure portal**. Functions that
  have never run say so - that itself is a finding.

The exclusion group field **autocompletes against real Entra security groups**
(`GET /api/groups?search=…`, served by the managed identity) in both the wizard
and the Configuration tab; free text that doesn't match a suggestion blocks the
save client-side, and the API independently resolves the name to an object id
at save time and rejects the save (HTTP 400) if the group cannot be found - a
typo must never silently exclude nobody.

## Where the config lives

Behavioural config is a single JSON blob, `config.json`, in the
`autorevocate-config` container. The functions read it fresh on each event
(so edits apply immediately) and the web API reads/writes it. The **catalog** of
which actions exist and which triggers each supports is defined in code
(`FeatureConfig.ps1 → Get-ARFeatureCatalog`) and returned by the API, so the UI
and runtime can never drift.

If no blob exists yet, the service desk address seeds from the
`AR_SERVICEDESK_EMAIL` app setting, delete timing defaults to soft (chosen in the
wizard), and only the two original behaviours (OneDrive unshare + notify manager)
are on at delete - and the API reports `firstRun: true`, which is what makes the
web app show the setup wizard.

## Auth model

```
Browser (static site)  --MSAL delegated sign-in-->  Entra
        |  bearer token (aud api://<appId>)
        v
Function App admin API  --Easy Auth validates token, group-gated-->  200 / 401
        |  (acts with the managed identity, not the user's token)
        v
Config blob / ActivityLog table
```

- **Delegated** sign-in via MSAL (`msal-browser`). No secret in the page - only
  the public client id, tenant id, API base, and scope (`authConfig.js`, written
  by deploy).
- **Group-gated**: the app registration's enterprise app requires assignment and
  only the nominated security group is assigned, so non-members can't get a token.
- **Easy Auth** on the Function App validates the token for the admin API and
  returns 401 otherwise. `/api/NotificationHandler` is excluded so Graph's webhook
  still works (it uses a function key).
- The user's token is used **only** to prove group membership; all M365/storage
  access is done by the managed identity.

## Finishing setup by hand

The deploy script does all of this, but if the web/auth step fails (it wraps the
Entra + Easy Auth calls in try/catch), complete it manually:

1. **Static website**: enable it on the storage account, index + 404 =
   `index.html`. Note the `https://<acct>.z##.web.core.windows.net/` URL.
2. **App registration**: create one; add a SPA redirect URI = the static site URL
   (and `.../index.html`); expose an API scope `access_as_user`; set the
   identifier URI `api://<appId>`.
3. **Enterprise app**: set "assignment required" and assign the admin group.
4. **Easy Auth** on the Function App: Microsoft provider with that client id,
   issuer `https://login.microsoftonline.com/<tenantId>/v2.0`, allowed audience
   `api://<appId>`, unauthenticated action **Return 401**, excluded path
   `/api/NotificationHandler`. Add the static site URL to the app's **CORS**
   allowed origins.
5. **Upload** the `web/` folder to the `$web` container after writing
   `authConfig.js` with the real `clientId` / `tenantId` / `apiBase` / `apiScope`.

## Notes / gotchas

- CORS preflight (`OPTIONS`) against an Easy-Auth-protected app can be finicky;
  the static origin must be in the Function App's CORS allowed origins. Just as
  important: Easy Auth must use `unauthenticatedClientAction = AllowAnonymous`,
  **not** `Return401`. A browser preflight carries no `Authorization` header, so
  `Return401` makes Easy Auth reject the `OPTIONS` before the CORS header is
  added, and the SPA fails with "No 'Access-Control-Allow-Origin' header"
  despite the origin being allow-listed. With `AllowAnonymous` the API is still
  protected: Easy Auth validates any token that IS present, and every admin
  function independently validates the bearer token (RS256/JWKS/aud/iss/exp) and
  fails closed. Fix a live app with:
  `az webapp auth update --name <func> --resource-group <rg> --unauthenticated-client-action AllowAnonymous`.
- `msal-browser.min.js` (currently **v4.x**) is **bundled locally** in `web/`
  (not loaded from a CDN), so content filtering can't break sign-in. MSAL v3+
  requires `msalInstance.initialize()` before any other call; `app.js` does this
  and chains sign-in off it. To upgrade MSAL, replace the file and keep that
  contract.
- The static site is hosted in a **separate storage account** (`arweb<suffix>`)
  that the managed identity has no access to, so a runtime compromise cannot
  rewrite the admin page. The deploy uploads it with that account's own key.
- The page also shows global **banners** (dry-run simulation, storm-guard pause
  with a resume button, poison queue, missing Graph permissions) on every tab,
  and a **version** footer.
- Everything the page shows comes from the managed identity's own data - the page
  can't do anything the tool itself can't.
