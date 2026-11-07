"""Entra ID track, Gateway tool RBAC (Entra ID version of the mall tool RBAC): configure the Entra tenant via Microsoft Graph (Entra ID Free only, no Azure
subscription resources). Idempotent: objects are looked up by name and created only if missing.
Creates:
  - app rsidc-mall-api: api://<appId>, delegated scope mcp.access, v2 access tokens, 4 App Roles Tools.Mall.{List,Footfall,Hourly,Zone}
  - app rsidc-mall-test-client: public client (auth code + PKCE), permission mcp.access + openid/profile/email, admin-consented
  - users wei / ds1 / chen (passwords only in tests/.entra-users.env, gitignored, never printed)
  - App Role assignments (Free tier: per USER): wei -> all 4, ds1 -> List + Footfall, chen -> none
Prereq: az login --tenant <tenant> --allow-no-subscriptions (as a Global Administrator).
Run: .venv/bin/python infra/entra-id/01-entra-setup.py   (prints IDs to put in infra/state.env)"""
import base64, json, os, secrets, string, subprocess, sys, uuid, requests  # nosec B404 -- fixed-argv az call only

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TENANT = os.environ["ENTRA_TENANT_ID"]   # your Entra tenant ID (set in infra/state.env or the shell)
G = "https://graph.microsoft.com/v1.0"
GRAPH_APP = "00000003-0000-0000-c000-000000000000"   # Microsoft Graph
ROLES = {"Tools.Mall.List": "Mall List", "Tools.Mall.Footfall": "Mall Footfall", "Tools.Mall.Hourly": "Mall Hourly", "Tools.Mall.Zone": "Mall Zone"}
USERS = {"wei": list(ROLES), "ds1": ["Tools.Mall.List", "Tools.Mall.Footfall"], "chen": []}
REDIRECTS = (["http://localhost:8765/callback"] + ([f"{os.environ['WEB_RBAC_URL']}/entra/{p}" for p in ("callback", "signed-out")] if os.environ.get("WEB_RBAC_URL") else [])  # RBAC web GUI
             + ([f"{os.environ['WEB_ENTRA_URL']}/entra/{p}" for p in ("callback", "signed-out")] if os.environ.get("WEB_ENTRA_URL") else [])  # Entra GUI
             + os.environ.get("ENTRA_EXTRA_REDIRECTS", "").split())

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


# --- API app (resource the gateway trusts) ---
api = one("/applications", "displayName eq 'rsidc-mall-api'")
if not api:
    api = g("POST", "/applications", {
        "displayName": "rsidc-mall-api", "signInAudience": "AzureADMyOrg",
        "api": {"requestedAccessTokenVersion": 2, "oauth2PermissionScopes": [{
            "id": str(uuid.uuid4()), "value": "mcp.access", "type": "User", "isEnabled": True,
            "adminConsentDisplayName": "Call the mall MCP tools", "adminConsentDescription": "Call the mall MCP tools through AgentCore Gateway",
            "userConsentDisplayName": "Call the mall MCP tools", "userConsentDescription": "Call the mall MCP tools through AgentCore Gateway"}]},
        "appRoles": [{"id": str(uuid.uuid4()), "allowedMemberTypes": ["User"], "value": v, "displayName": d,
                      "description": f"May call the {d} tool", "isEnabled": True} for v, d in ROLES.items()]})
    print("created app rsidc-mall-api")
if api.get("identifierUris") != [f"api://{api['appId']}"]:
    g("PATCH", f"/applications/{api['id']}", {"identifierUris": [f"api://{api['appId']}"]})
api = g("GET", f"/applications/{api['id']}")
assert api["api"]["requestedAccessTokenVersion"] == 2, "access tokens must be v2"
scope_id = api["api"]["oauth2PermissionScopes"][0]["id"]
role_ids = {r["value"]: r["id"] for r in api["appRoles"]}
api_sp = sp_for(api["appId"])

# --- test client (public client: auth code + PKCE) ---
graph_sp = sp_for(GRAPH_APP)
graph_scopes = {s["value"]: s["id"] for s in graph_sp["oauth2PermissionScopes"] if s["value"] in ("openid", "profile", "email", "offline_access")}
cli = one("/applications", "displayName eq 'rsidc-mall-test-client'")
body = {"publicClient": {"redirectUris": REDIRECTS}, "isFallbackPublicClient": True,
        "optionalClaims": {"idToken": [{"name": "login_hint", "essential": False}]},   # -> logout_hint: sign-out without the account picker
        "requiredResourceAccess": [{"resourceAppId": api["appId"], "resourceAccess": [{"id": scope_id, "type": "Scope"}]},
                                   {"resourceAppId": GRAPH_APP, "resourceAccess": [{"id": i, "type": "Scope"} for i in graph_scopes.values()]}]}
if not cli:
    cli = g("POST", "/applications", {"displayName": "rsidc-mall-test-client", "signInAudience": "AzureADMyOrg", **body}); print("created app rsidc-mall-test-client")
else:  # keep permissions added by later parts (e.g. 19: access_as_user on the agent API)
    mine = {r["resourceAppId"] for r in body["requiredResourceAccess"]}
    body["requiredResourceAccess"] += [r for r in cli.get("requiredResourceAccess", []) if r["resourceAppId"] not in mine]
    g("PATCH", f"/applications/{cli['id']}", body)
cli_sp = sp_for(cli["appId"])
for res_sp, scopes in ((api_sp, "mcp.access"), (graph_sp, " ".join(graph_scopes))):   # admin consent for all users
    if not one("/oauth2PermissionGrants", f"clientId eq '{cli_sp['id']}' and resourceId eq '{res_sp['id']}'"):
        g("POST", "/oauth2PermissionGrants", {"clientId": cli_sp["id"], "consentType": "AllPrincipals", "resourceId": res_sp["id"], "scope": scopes})

# --- users + App Role assignments (per user: Entra ID Free) ---
domain = next(d["id"] for d in g("GET", "/domains")["value"] if d["isDefault"])
pw_file = os.path.join(ROOT, "tests", ".entra-users.env")
pws = {}
if os.path.exists(pw_file):
    with open(pw_file, encoding="utf-8") as f:
        pws = dict(l.strip().split("=", 1) for l in f if "=" in l)
assigned = {(a["principalId"], a["appRoleId"]) for a in g("GET", f"/servicePrincipals/{api_sp['id']}/appRoleAssignedTo")["value"]}
for name, roles in USERS.items():
    upn = f"{name}@{domain}"
    u = one("/users", f"userPrincipalName eq '{upn}'")
    if not u:
        pw = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(18)) + "aA1!"
        u = g("POST", "/users", {"accountEnabled": True, "displayName": name, "mailNickname": name, "userPrincipalName": upn,
                                 "passwordProfile": {"password": pw, "forceChangePasswordNextSignIn": False}})
        pws[f"ENTRA_PW_{name.upper()}"] = pw; print(f"created user {upn}")
    for r in roles:
        if (u["id"], role_ids[r]) not in assigned:
            g("POST", f"/servicePrincipals/{api_sp['id']}/appRoleAssignedTo", {"principalId": u["id"], "resourceId": api_sp["id"], "appRoleId": role_ids[r]})
os.makedirs(os.path.dirname(pw_file), exist_ok=True)
with os.fdopen(os.open(pw_file, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f:  # 0600 from creation
    f.writelines(f"{k}={v}\n" for k, v in pws.items())
os.chmod(pw_file, 0o600)

print(f"ENTRA_TENANT_ID={TENANT}\nENTRA_API_APP_ID={api['appId']}\nENTRA_TEST_CLIENT_ID={cli['appId']}\nENTRA_DOMAIN={domain}")
for a in g("GET", f"/servicePrincipals/{api_sp['id']}/appRoleAssignedTo")["value"]:
    print(f"  assignment: {a['principalDisplayName']:6} -> {next(k for k, v in role_ids.items() if v == a['appRoleId'])}")
