"""Entra ID track, Parts 2–4 (Entra ID x AgentCore Identity: 2LO / 3LO / OBO): Entra side, via Microsoft Graph (Entra ID Free only).
Idempotent. Creates / updates:
  - rsidc-mall-api App Roles: allowedMemberTypes += Application  (so an APP can hold Tools.Mall.* for 2LO)
  - app rsidc-entra-agent (confidential): the agent's own API (api://<appId>/access_as_user, v2 tokens) AND the OAuth
    client that the AgentCore Identity credential provider uses for all three flows:
      2LO  client_credentials  -> app-only token for rsidc-mall-api (roles = the APP's roles: List + Footfall)
      3LO  authorization code  -> delegated Microsoft Graph User.Read (consent; web redirect = AgentCore callback URL)
      OBO  jwt-bearer on_behalf_of -> delegated rsidc-mall-api mcp.access with the USER's roles
    admin consent for its delegated permissions; client secret written ONLY to tests/.entra-agent.env (0600, gitignored)
  - test client rsidc-mall-test-client: += delegated access_as_user on the agent API (users get tokens to call the runtime)
Env: AGENT_REDIRECTS (space-separated web redirect URIs, e.g. the AgentCore credential provider callbackUrl).
Run: .venv/bin/python infra/entra-id/03-entra-agent-setup.py"""
import base64, datetime, json, os, subprocess, sys, uuid, requests  # nosec B404 -- fixed-argv az call only

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TENANT = os.environ["ENTRA_TENANT_ID"]   # your Entra tenant ID
G, GRAPH_APP = "https://graph.microsoft.com/v1.0", "00000003-0000-0000-c000-000000000000"
SECRET_FILE = os.path.join(ROOT, "tests", ".entra-agent.env")
APP_ROLES_FOR_AGENT = ["Tools.Mall.List", "Tools.Mall.Footfall"]   # 2LO: what the AGENT itself may call

# Static argv (no env values): az uses the tenant you signed in to with `az login --tenant <tenant>`;
# the token's tid claim is then checked against ENTRA_TENANT_ID so the script never writes to another tenant.
tok = json.loads(subprocess.check_output(["az", "account", "get-access-token", "--resource-type", "ms-graph"]))["accessToken"]  # nosec B603 B607
_claims = json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "=" * (-len(tok.split(".")[1]) % 4)))
if _claims.get("tid") != TENANT:
    sys.exit("az is signed in to a different tenant: run az login --tenant $ENTRA_TENANT_ID --allow-no-subscriptions")
H = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}


def g(method, path, body=None):
    r = requests.request(method, G + path, headers=H, json=body, timeout=30)
    if not r.ok: sys.exit(f"{method} {path} -> {r.status_code} {r.text[:400]}")
    return r.json() if r.text else {}


def one(path, flt):
    v = g("GET", f"{path}?$filter={flt}")["value"]
    return v[0] if v else None


def sp_for(app_id):
    return one("/servicePrincipals", f"appId eq '{app_id}'") or g("POST", "/servicePrincipals", {"appId": app_id})


def grant(client_sp, res_sp, scopes):  # admin consent (AllPrincipals) for delegated scopes, merged
    cur = one("/oauth2PermissionGrants", f"clientId eq '{client_sp['id']}' and resourceId eq '{res_sp['id']}'")
    if not cur:
        g("POST", "/oauth2PermissionGrants", {"clientId": client_sp["id"], "consentType": "AllPrincipals", "resourceId": res_sp["id"], "scope": " ".join(scopes)})
    elif not set(scopes) <= set(cur["scope"].split()):
        g("PATCH", f"/oauth2PermissionGrants/{cur['id']}", {"scope": " ".join(sorted(set(cur["scope"].split()) | set(scopes)))})


def merge_rra(app, entries):  # requiredResourceAccess: merge, never drop what is already there
    rra = {r["resourceAppId"]: {(a["id"], a["type"]) for a in r["resourceAccess"]} for r in app.get("requiredResourceAccess", [])}
    for res, items in entries.items(): rra.setdefault(res, set()).update(items)
    return [{"resourceAppId": k, "resourceAccess": [{"id": i, "type": t} for i, t in sorted(v)]} for k, v in rra.items()]


# --- rsidc-mall-api: let applications hold the Tools.Mall.* roles (2LO) ---
api = one("/applications", "displayName eq 'rsidc-mall-api'")
roles = api["appRoles"]
if any("Application" not in r["allowedMemberTypes"] for r in roles):
    for r in roles: r["allowedMemberTypes"] = sorted(set(r["allowedMemberTypes"]) | {"Application"})
    g("PATCH", f"/applications/{api['id']}", {"appRoles": roles}); print("rsidc-mall-api: App Roles now allow Application")
role_ids = {r["value"]: r["id"] for r in roles}
mcp_scope = next(s["id"] for s in api["api"]["oauth2PermissionScopes"] if s["value"] == "mcp.access")
api_sp, graph_sp = sp_for(api["appId"]), sp_for(GRAPH_APP)
graph_scope = {s["value"]: s["id"] for s in graph_sp["oauth2PermissionScopes"]}

# --- the agent's app ---
agent = one("/applications", "displayName eq 'rsidc-entra-agent'")
if not agent:
    agent = g("POST", "/applications", {
        "displayName": "rsidc-entra-agent", "signInAudience": "AzureADMyOrg",
        "api": {"requestedAccessTokenVersion": 2, "oauth2PermissionScopes": [{
            "id": str(uuid.uuid4()), "value": "access_as_user", "type": "User", "isEnabled": True,
            "adminConsentDisplayName": "Call the rsidc Entra agent", "adminConsentDescription": "Call the rsidc Entra agent on AgentCore Runtime",
            "userConsentDisplayName": "Call the rsidc Entra agent", "userConsentDescription": "Call the rsidc Entra agent on AgentCore Runtime"}]}})
    print("created app rsidc-entra-agent")
redirects = sorted(set(agent.get("web", {}).get("redirectUris", [])) | set(os.environ.get("AGENT_REDIRECTS", "").split()))
g("PATCH", f"/applications/{agent['id']}", {
    "identifierUris": [f"api://{agent['appId']}"], "web": {"redirectUris": redirects},
    "optionalClaims": {"idToken": [{"name": "login_hint", "essential": False}]},
    "requiredResourceAccess": merge_rra(agent, {
        GRAPH_APP: {(graph_scope[s], "Scope") for s in ("User.Read", "openid", "profile", "offline_access")},
        api["appId"]: {(mcp_scope, "Scope")} | {(role_ids[r], "Role") for r in APP_ROLES_FOR_AGENT}})})
agent = g("GET", f"/applications/{agent['id']}")
agent_sp = sp_for(agent["appId"])
grant(agent_sp, graph_sp, ["User.Read", "openid", "profile", "offline_access"])   # 3LO / OBO-to-Graph: admin-consented
grant(agent_sp, api_sp, ["mcp.access"])                                            # OBO: delegated mall API
have = {(a["principalId"], a["appRoleId"]) for a in g("GET", f"/servicePrincipals/{api_sp['id']}/appRoleAssignedTo")["value"]}
for r in APP_ROLES_FOR_AGENT:                                                      # 2LO: application permissions
    if (agent_sp["id"], role_ids[r]) not in have:
        g("POST", f"/servicePrincipals/{api_sp['id']}/appRoleAssignedTo", {"principalId": agent_sp["id"], "resourceId": api_sp["id"], "appRoleId": role_ids[r]})

# --- client secret (only when there is none on disk) ---
if not os.path.exists(SECRET_FILE):
    end = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ")
    pw = g("POST", f"/applications/{agent['id']}/addPassword", {"passwordCredential": {"displayName": "agentcore-credential-provider", "endDateTime": end}})
    os.makedirs(os.path.dirname(SECRET_FILE), exist_ok=True)
    with os.fdopen(os.open(SECRET_FILE, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f: f.write(f"ENTRA_AGENT_CLIENT_SECRET={pw['secretText']}\n")
    os.chmod(SECRET_FILE, 0o600); print("client secret created (90 days) -> tests/.entra-agent.env")

# --- test client: may request tokens for the agent API ---
access_scope = next(s["id"] for s in agent["api"]["oauth2PermissionScopes"] if s["value"] == "access_as_user")
cli = one("/applications", "displayName eq 'rsidc-mall-test-client'")
g("PATCH", f"/applications/{cli['id']}", {"requiredResourceAccess": merge_rra(cli, {agent["appId"]: {(access_scope, "Scope")}})})
grant(sp_for(cli["appId"]), agent_sp, ["access_as_user"])

print(f"ENTRA_AGENT_APP_ID={agent['appId']}")
print("agent app roles on rsidc-mall-api:", sorted(next(k for k, v in role_ids.items() if v == a["appRoleId"])
      for a in g("GET", f"/servicePrincipals/{api_sp['id']}/appRoleAssignedTo")["value"] if a["principalId"] == agent_sp["id"]))
print("agent web redirectUris:", redirects)
