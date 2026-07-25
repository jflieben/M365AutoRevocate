/* This file is OVERWRITTEN by the deploy script with your tenant's real values.
   The placeholders below let the page load (and show a "not configured" message)
   before deployment. Do not put secrets here -- delegated auth uses no secret. */
window.AR_AUTH = {
  clientId: "REPLACE_CLIENT_ID",
  tenantId: "REPLACE_TENANT_ID",
  apiBase: "REPLACE_API_BASE",   // e.g. https://func-autorevocate-12345.azurewebsites.net/api
  apiScope: "REPLACE_API_SCOPE"  // e.g. api://<clientId>/access_as_user
};
