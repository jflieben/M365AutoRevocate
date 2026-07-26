# Offboarding automation opportunities

| # | Action | Why it matters | Graph surface | Permission | Status |
|---|--------|----------------|---------------|-----------|--------|
| 13 | **Grant the manager temporary access to the OneDrive** before retention deletes it, and link it in the hand-off email | Lets the manager actually retrieve files, not just be told they exist | `POST /drives/{id}/root/invite` | `Sites.FullControl.All` | 🔭 (see note) |
| 14 | **Re-own orphaned groups/Teams** - where the deleted user was the *only* owner, add the service desk (or manager) as owner | Owner-less M365 groups can't be managed and drift | `GET /groups/{id}/owners`, `POST /groups/{id}/owners/$ref` | `Group.ReadWrite.All` | 🔭 |
| 15 | **Re-own orphaned enterprise apps / SP registrations** the user owned | App ownership gaps block credential rotation & lifecycle | `POST /servicePrincipals/{id}/owners/$ref` | `Application.ReadWrite.All` | 🔭 |
| 16 | **Export the cleanup record to Log Analytics** instead of (or as well as) a table | Central SIEM visibility | Log Ingestion API | - | 🔭 |

## Feasible but higher-risk / broader blast radius

| # | Action | Notes | Permission |
|---|--------|-------|-----------|
| 9  | **Reassign SharePoint site collection admins** for sites the user solely administered | Needs enumeration of site admins; SharePoint admin surface is clunky via Graph | `Sites.FullControl.All` |
| 10 | **Remove stale PIM eligible/active role assignments** referencing the principal | Deletion usually clears these, but tenants accumulate orphans | `RoleManagement.ReadWrite.Directory` |
| 11 | **Delete registered/owned devices** that are now orphaned | Capture `ownedDevices` in the snapshot first | `Device.ReadWrite.All` |
| 12 | **Revoke guest sponsorships** where the user sponsored external guests | Sponsors become dangling references | `User.ReadWrite.All` |

## Not Microsoft Graph

- **Power Platform** flows/apps/connections owned by the user → Power Platform admin APIs. ✋
- **Azure RBAC role assignments** on subscriptions/resources → ARM (`Microsoft.Authorization`), not Graph. ✋
- **Third-party SaaS** (SCIM deprovisioning) → the IdP / SaaS app. ✋