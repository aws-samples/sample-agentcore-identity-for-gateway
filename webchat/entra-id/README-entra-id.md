# webchat/entra-id/: Microsoft Entra ID GUIs

## Tool RBAC GUI: Entra ID card (`rbac_app.py`)
- **Entra ID version:** "Sign in with Entra ID" (`/entra/login` → `/entra/callback`, public client with PKCE, separate `esid` cookie) adds a card for `rsidc-mall-entra-gateway`. The token's native `roles` claim comes from Entra App Roles. Requires the `ENTRA_*` and `ENTRA_GW_URL` env vars; without them the Entra card is hidden.

## Entra ID demo GUI (`entra_app.py`, port 8083 locally, `rsidc-webchat-entra` on AWS: `https://<api-id>.execute-api.<region>.amazonaws.com`, printed by `infra/cognito-idc/14-deploy-webchat.sh`)
One page for the three Entra flows against runtime `rsidc_entra_agent`, the Entra counterpart of the GUIs above.
- **Sign in with Entra ID:** public client `rsidc-mall-test-client`, code + PKCE, scope `api://<rsidc-entra-agent>/access_as_user`. The token stays server-side (cookie `esid`); the page shows claims only. **Sign out** uses `logout_hint` and returns to `/entra/signed-out`.
- **Panels:**
  - **2LO:** app-only token and gateway table;
  - **OBO:** inbound vs outbound claims, the per-user gateway table, and Graph /me;
  - **3LO:** consent → `/3lo/callback` → `CompleteResourceTokenAuth` (the function role `rsidc-webchat-role` with the inline policy `webchat-entra`) → Token Vault → Graph /me.
- Requests are sent one at a time, because of reserved concurrency 1.
- **Users:** the demo users wei, ds1 and chen sign in with password only, which requires Entra Security defaults to be disabled in a test tenant; a user with MFA registered (lo3user) works with Security defaults on.
