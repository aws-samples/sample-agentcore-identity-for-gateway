# webchat/
Layout: [`cognito-idc/`](cognito-idc/) (OBO, 2LO/3LO and tool RBAC GUIs), `entra-id/` (Entra GUI, local only), [`common/`](common/) (`lambda_adapter.py`, the API Gateway to handler adapter used by every app). Each app loads its HTML from its own folder; file names are unchanged.

Local browser UI for the OBO data agent: Cognito managed login (code + PKCE) -> chat -> AgentCore Runtime with the user's ID token.
Run `infra/common/run.sh .venv/bin/python webchat/cognito-idc/obo_app.py`, open http://localhost:8080, sign in as wei/zhang/chen/ds1 (passwords are in the local, gitignored `tests/.users.env`, created by `infra/cognito-idc/02-cognito.sh`).
Binds 127.0.0.1 only; tokens stay server-side in memory. Requires `infra/cognito-idc/13-web-login-client.py` (adds the localhost callback to the OBO client).

## 2LO / 3LO GUI (`oauth_app.py`, port 8081)
`infra/common/run.sh .venv/bin/python webchat/cognito-idc/oauth_app.py`, then open http://localhost:8081. It uses the separate OAuth runtime `rsidc_oauth_agent`.
- **2LO panel**: the agent's own M2M token → AgentCore Gateway → Lambda → Redshift as `svc_reporting`. It shows the token claims (no user) and the rows, which are the same for every user.
- **3LO panel**: login 2 (consent at Cognito) → AgentCore callback → `/3lo/callback` → `CompleteResourceTokenAuth` (session binding, using the operator's AWS credentials; only when the returned `session_id` is the one this browser session started, single use, otherwise HTTP 400) → Token Vault → `userInfo`. Options: force re-consent; `prompt=login` (observed to store no token).
- Requires the 8081 callback on the Cognito client (`infra/cognito-idc/13-web-login-client.py`) and `http://localhost:8081/3lo/callback` on the OAuth workload identity (`infra/cognito-idc/12-deploy-oauth-runtime.sh`).

## Deployed on AWS (`infra/cognito-idc/14-deploy-webchat.sh`)
Both apps run unchanged as Lambdas behind API Gateway HTTP APIs (HTTPS, because Cognito only allows http callbacks for localhost). `lambda_adapter.py` replays each payload 2.0 event into the app's `BaseHTTPRequestHandler`.
- **Access:** Cognito sign-in only, with admin-created users. There's no IP allowlist yet; add one in front of the API. The Lambda resource policy allows only its own API; there's no Function URL and no public principal.
- **Sessions** are kept in memory (expire after 1 h; OAuth state after 10 min; capped at 1000 entries; cookies are `Secure` when `WEB_BASE_URL` is https), so each function has reserved concurrency 1. If the environment is recycled or redeployed, sign in again. A request made while another is still running gets HTTP 429. The HTTP API integration timeout is 30 s.
- The OAuth GUI's `CompleteResourceTokenAuth` runs as the function role `rsidc-webchat-role`, which also needs `GetSecretValue` on the 3LO provider secret.

## Tool RBAC GUI (`rbac_app.py`, port 8082 locally, `rsidc-webchat-rbac` on AWS)
Signs in on Cognito (OBO client, code + PKCE). The access token, which carries the `roles` claim from the Pre Token trigger, stays server-side.
For the Gateway tool RBAC demo gateway and customer gateway (the one Part 1 · Amazon Quick uses) it runs `tools/list`, then calls **every** catalogue tool directly. Each tool is shown as listed or hidden, and allowed or denied (a Cedar deny is HTTP 200 + `isError`).
Requests from the page are sent one at a time, because the Lambda has reserved concurrency 1.
- The RBAC GUI also has an optional Microsoft Entra ID card, hidden unless the `ENTRA_*` env vars are set (local only, see `README-entra-id.md`).
