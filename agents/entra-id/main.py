"""Entra ID track, Parts 2–4 (3LO, 2LO, OBO): AgentCore Runtime agent whose users sign in with Microsoft Entra ID. All three outbound patterns go through
ONE AgentCore Identity credential provider (vendor MicrosoftOauth2, app rsidc-entra-agent):

  {"mode": "whoami"}                       the inbound Entra token as the runtime authorizer accepted it
  {"mode": "2lo"}                          M2M: the AGENT's own app-only token -> Entra-trusting Gateway (app roles)
  {"mode": "obo"}                          ON_BEHALF_OF_TOKEN_EXCHANGE: inbound user token -> token for rsidc-mall-api
                                           with the USER's roles -> Gateway (per-user Cedar)
  {"mode": "obo_graph"}                    OBO to Microsoft Graph /me (the downstream sees the user, no consent prompt)
  {"mode": "3lo", "return_url": "...", "session_uri"?: "...", "force"?: bool}
                                           USER_FEDERATION: consent once -> Token Vault -> Graph /me as the user
"""
import base64, json, os, urllib.parse

import boto3
import urllib3  # already installed with boto3/botocore
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from bedrock_agentcore.runtime.context import BedrockAgentCoreContext

app = BedrockAgentCoreApp()
identity = boto3.client("bedrock-agentcore", region_name=os.environ["AWS_REGION"])
CP, MALL_API, GW = os.environ["CP_ENTRA"], os.environ["MALL_API_APP_ID"], os.environ["ENTRA_GW_URL"]
# Client apps allowed to call this agent (comma-separated app ids). The runtime authorizer only checks aud/iss, so any
# app that obtained a token for this API would pass it; empty = fail closed.
ALLOWED_CLIENTS = {c.strip().lower() for c in os.environ.get("ENTRA_ALLOWED_CLIENT_IDS", "").split(",") if c.strip()}
TOOLS = ["mall___get_mall_list", "mall___get_footfall_summary", "mall___get_hourly_traffic", "mall___get_zone_comparison"]
KEEP = ("ver", "iss", "aud", "azp", "appid", "idtyp", "scp", "roles", "preferred_username", "upn", "name", "oid", "sub")


def claims(jwt: str) -> dict:
    c = json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))
    return {k: c[k] for k in KEEP if k in c}


def check_caller(inbound: dict, allowed: set[str]) -> str | None:
    """None if the token's client app (azp for v2 tokens, appid for v1) is allowlisted, else the rejection reason."""
    client = (inbound.get("azp") or inbound.get("appid") or "").lower()
    if not allowed:
        return "ENTRA_ALLOWED_CLIENT_IDS is not configured (fail closed)"
    if not client:
        return "token has no azp/appid claim"
    return None if client in allowed else f"client app {client} is not allowed to call this agent"


def require_https(url: str) -> str:
    if urllib.parse.urlparse(url).scheme != "https":
        raise ValueError(f"only https URLs are allowed: {url!r}")
    return url


def http_json(url: str, token: str, body: dict | None = None) -> tuple[int, dict]:
    require_https(url)
    r = urllib3.PoolManager().request("POST" if body else "GET", url, body=json.dumps(body).encode() if body else None, timeout=30.0,
                                      redirects=False, headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                                                                "Accept": "application/json, text/event-stream"})
    if r.status >= 400:  # urllib3 does not raise on HTTP errors; the caller reports the status
        return r.status, {"error": r.data.decode()[:200]}
    return r.status, json.loads(r.data)


def gateway_check(token: str) -> dict:
    """tools/list, then tools/call on every tool. A Cedar deny is HTTP 200 + result.isError."""
    s, j = http_json(GW, token, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    listed = sorted(t["name"] for t in j.get("result", {}).get("tools", []))
    calls = {}
    for t in TOOLS:
        cs, cj = http_json(GW, token, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                       "params": {"name": t, "arguments": {"mall_id": "HK01", "date": "2026-10-01"}}})
        calls[t] = cs == 200 and "error" not in cj and not cj.get("result", {}).get("isError")
    return {"list_http": s, "listed": listed, "allowed": calls}


def token(wat: str, flow: str, scopes: list[str], **extra) -> dict:
    return identity.get_resource_oauth2_token(workloadIdentityToken=wat, resourceCredentialProviderName=CP,
                                              scopes=scopes, oauth2Flow=flow, **extra)


def two_lo(wat):
    t = token(wat, "M2M", [f"api://{MALL_API}/.default"])["accessToken"]
    return {"flow": "2LO", "outbound_token_claims": claims(t), "gateway": gateway_check(t)}


def obo(wat):
    t = token(wat, "ON_BEHALF_OF_TOKEN_EXCHANGE", [f"api://{MALL_API}/mcp.access"])["accessToken"]
    return {"flow": "OBO", "outbound_token_claims": claims(t), "gateway": gateway_check(t)}


def obo_graph(wat, caller_oid):
    t = token(wat, "ON_BEHALF_OF_TOKEN_EXCHANGE", ["User.Read"])["accessToken"]
    s, me = http_json("https://graph.microsoft.com/v1.0/me", t)
    if s == 200 and (not caller_oid or (me.get("id") or "").lower() != caller_oid.lower()):  # exchange must yield the caller
        return {"flow": "OBO->Graph", "status": "IDENTITY_MISMATCH", "caller_oid": caller_oid, "graph_oid": me.get("id")}
    return {"flow": "OBO->Graph", "graph_http": s, "me": {k: me.get(k) for k in ("displayName", "userPrincipalName", "id")}}


def three_lo(wat, payload, caller_oid):
    args = dict(resourceOauth2ReturnUrl=payload["return_url"], forceAuthentication=bool(payload.get("force")))
    if payload.get("session_uri"): args["sessionUri"] = payload["session_uri"]
    r = token(wat, "USER_FEDERATION", ["User.Read", "offline_access"], **args)
    if not r.get("accessToken"):
        return {"flow": "3LO", "status": "CONSENT_REQUIRED", "authorizationUrl": r.get("authorizationUrl"), "sessionUri": r.get("sessionUri")}
    s, me = http_json("https://graph.microsoft.com/v1.0/me", r["accessToken"])
    # the vault token must belong to the person calling the agent: compare the immutable object id, not the (renamable) UPN
    if not caller_oid or (me.get("id") or "").lower() != caller_oid.lower():
        return {"flow": "3LO", "status": "IDENTITY_MISMATCH", "caller_oid": caller_oid, "vault_token_oid": me.get("id")}
    return {"flow": "3LO", "status": "TOKEN_FROM_VAULT", "graph_http": s,
            "me": {k: me.get(k) for k in ("displayName", "userPrincipalName", "id")}}


@app.entrypoint
def invoke(payload, context):
    wat = BedrockAgentCoreContext.get_workload_access_token()
    if not wat:
        return {"error": "no workload access token (inbound JWT required)"}
    auth = {k.lower(): v for k, v in (context.request_headers or {}).items()}.get("authorization", "")
    inbound = claims(auth.split(" ", 1)[1]) if auth.lower().startswith("bearer ") else {}
    mode = payload.get("mode")
    denied = check_caller(inbound, ALLOWED_CLIENTS)
    if denied:
        return {"error": f"caller not allowed: {denied}"}
    try:
        if mode == "whoami": return {"flow": "inbound", "inbound_token_claims": inbound}
        if mode == "2lo": return two_lo(wat)
        if mode == "obo": return obo(wat)
        if mode == "obo_graph": return obo_graph(wat, inbound.get("oid"))
        if mode == "3lo": return three_lo(wat, payload, inbound.get("oid"))
        return {"error": f"unknown mode {mode}"}
    except Exception as e:
        return {"flow": mode, "error": f"{type(e).__name__}: {e}"}


if __name__ == "__main__":
    app.run()
