"""AgentCore Runtime entrypoint for the 2LO / 3LO test cases (separate from the OBO agent).

Payload:
  {"mode": "2lo"}                                   agent gets its OWN token (M2M) and calls the Gateway reporting tool
  {"mode": "3lo", "return_url": "...", "force": b, "prompt_login": b}
                                                    agent gets a USER-delegated token from the Token Vault, or an auth URL
"""
import base64, json, os, urllib.parse

import boto3
import urllib3  # already installed with boto3/botocore
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from bedrock_agentcore.runtime.context import BedrockAgentCoreContext

app = BedrockAgentCoreApp()
identity = boto3.client("bedrock-agentcore", region_name=os.environ["AWS_REGION"])


def claims(jwt: str) -> dict:
    keep = ("iss", "sub", "client_id", "username", "email", "scope", "token_use", "aud")
    c = json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))
    return {k: c[k] for k in keep if k in c}


def http_json(url: str, token: str, body: dict | None = None) -> dict:
    if urllib.parse.urlparse(url).scheme != "https":
        raise ValueError("only https URLs are allowed")
    r = urllib3.PoolManager().request("POST" if body else "GET", url, body=json.dumps(body).encode() if body else None, timeout=30.0,
                                      redirects=False, headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                                                                "Accept": "application/json, text/event-stream"})
    if r.status >= 400:  # urllib3 does not raise on HTTP errors
        raise RuntimeError(f"HTTP {r.status} from {urllib.parse.urlparse(url).netloc}")
    return json.loads(r.data)


def two_lo(wat: str) -> dict:
    # 2LO / M2M: no user in the loop -- the token represents the AGENT (Cognito client_credentials).
    tok = identity.get_resource_oauth2_token(workloadIdentityToken=wat, resourceCredentialProviderName=os.environ["CP_2LO"],
                                             scopes=["rsidc-reports/read"], oauth2Flow="M2M")["accessToken"]
    call = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "reporting___get_sales_report", "arguments": {}}}
    res = http_json(os.environ["GW_URL"], tok, call)
    report = json.loads(res["result"]["content"][0]["text"])
    return {"flow": "2LO", "outbound_token_claims": claims(tok), "gateway_result": report}


def three_lo(wat: str, payload: dict) -> dict:
    # 3LO / USER_FEDERATION: token is bound to (this agent, this user) in the Token Vault; needs one-time user consent.
    args = dict(workloadIdentityToken=wat, resourceCredentialProviderName=os.environ["CP_3LO"],
                scopes=["openid", "email", "profile"], oauth2Flow="USER_FEDERATION",
                resourceOauth2ReturnUrl=payload["return_url"], forceAuthentication=bool(payload.get("force")))
    if payload.get("session_uri"):
        # Collect the token for THIS consent session (SDK polling contract); otherwise an older vault token may be served.
        args["sessionUri"] = payload["session_uri"]
    if payload.get("prompt_login"):
        # Force the IdP to re-authenticate instead of silently reusing an existing browser session.
        args["customParameters"] = {"prompt": "login"}
    r = identity.get_resource_oauth2_token(**args)
    if not r.get("accessToken"):
        return {"flow": "3LO", "status": "CONSENT_REQUIRED", "authorizationUrl": r.get("authorizationUrl"),
                "sessionUri": r.get("sessionUri"), "sessionStatus": r.get("sessionStatus")}
    profile = http_json(os.environ["COGNITO_DOMAIN"] + "/oauth2/userInfo", r["accessToken"])
    caller = payload.get("_caller_email")
    if not caller or profile.get("email", "").lower() != caller.lower():
        # Defence in depth: the vault token must belong to the same person who is calling the agent.
        return {"flow": "3LO", "status": "IDENTITY_MISMATCH", "caller_email": caller, "vault_token_email": profile.get("email")}
    return {"flow": "3LO", "status": "TOKEN_FROM_VAULT", "outbound_token_claims": claims(r["accessToken"]), "userinfo": profile}


@app.entrypoint
def invoke(payload, context):
    wat = BedrockAgentCoreContext.get_workload_access_token()
    if not wat:
        return {"error": "no workload access token (inbound JWT required)"}
    auth = {k.lower(): v for k, v in (context.request_headers or {}).items()}.get("authorization", "")
    payload["_caller_email"] = claims(auth.split(" ", 1)[1]).get("email") if auth.lower().startswith("bearer ") else None
    try:
        return two_lo(wat) if payload.get("mode") == "2lo" else three_lo(wat, payload)
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}


if __name__ == "__main__":
    app.run()
