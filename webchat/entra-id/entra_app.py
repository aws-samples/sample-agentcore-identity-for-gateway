"""Web GUI for the Entra ID track, Parts 2–4 (Microsoft Entra ID x AgentCore Identity): sign in with Entra ID (public client, code + PKCE),
then drive the Entra agent runtime rsidc_entra_agent in three separate panels: 2LO (M2M), OBO (token exchange) and
3LO (USER_FEDERATION consent -> Token Vault -> Microsoft Graph). The user's Entra access token (aud = rsidc-entra-agent)
stays server-side (in memory, keyed by an HttpOnly cookie); the page only ever sees claims, never tokens.
Run:  infra/common/run.sh .venv/bin/python webchat/entra-id/entra_app.py   then open http://localhost:8083"""
import base64, hashlib, json, os, secrets, sys, time, urllib.parse, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3, requests

for _p in (".", "../common"):  # "." = Lambda zip layout (flat webchat/), "../common" = this repo
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), _p))
from invoke import invoke  # noqa: E402
from websec import PENDING_TTL, SESSION_TTL, TTLStore, cookie, json_for_script, take_pending_3lo, SECURITY_HEADERS, same_origin_post  # noqa: E402

TENANT, CLIENT, AGENT, RT = (os.environ[k] for k in ("ENTRA_TENANT_ID", "ENTRA_CLIENT_ID", "ENTRA_AGENT_APP_ID", "ENTRA_RT_ARN"))
BASE = os.environ.get("WEB_BASE_URL", "http://localhost:8083")
REDIRECT, SIGNED_OUT, RETURN_3LO = f"{BASE}/entra/callback", f"{BASE}/entra/signed-out", f"{BASE}/3lo/callback"
AUTHORITY = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0"
SCOPE = f"openid profile offline_access api://{AGENT}/access_as_user"
KEEP = ("ver", "iss", "aud", "azp", "scp", "roles", "preferred_username", "name")
# Session binding (3LO) is the APP's job: Lambda execution role locally = operator credentials.
ident = boto3.client("bedrock-agentcore", region_name=os.environ["RT_REGION"])
SESSIONS, PENDING = TTLStore(SESSION_TTL), TTLStore(PENDING_TTL)  # sid -> session; OAuth state -> PKCE verifier
PAGE = open(os.path.join(os.path.dirname(__file__), "entra_index.html"), encoding="utf-8").read()


def claims(jwt):
    c = json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))
    return {k: c[k] for k in KEEP if k in c}


def esc(t):
    return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def agent(s, payload):
    status, body = invoke(s["token"], payload, runtime_arn=RT, session_id=f"rsidc-web-entra-{payload['mode']}-{uuid.uuid4()}")
    return {"http": status, **(body if isinstance(body, dict) else {"raw": str(body)[:200]})}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body=b"", ctype="text/html; charset=utf-8", headers=()):
        self.send_response(code); self.send_header("Content-Type", ctype)
        for k, v in SECURITY_HEADERS: self.send_header(k, v)
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def session(self):
        c = dict(p.strip().split("=", 1) for p in self.headers.get("Cookie", "").split(";") if "=" in p)
        return c.get("esid", ""), SESSIONS.get(c.get("esid", ""))

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query); sid, s = self.session()
        if u.path == "/":
            view = {"signedIn": bool(s), "user": s["user"] if s else "", "inbound": s["inbound"] if s else {},
                    "last3lo": s.get("last3lo") if s else None, "signedOut": q.get("signed-out") == ["1"]}
            return self.send(200, PAGE.replace("__STATE__", json_for_script(view)))
        if u.path == "/entra/login":
            verifier, state = secrets.token_urlsafe(48), secrets.token_urlsafe(16); PENDING[state] = verifier
            ch = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            p = dict(response_type="code", client_id=CLIENT, redirect_uri=REDIRECT, scope=SCOPE, state=state, prompt="login",
                     code_challenge=ch, code_challenge_method="S256")
            return self.send(302, headers=[("Location", f"{AUTHORITY}/authorize?{urllib.parse.urlencode(p)}")])
        if u.path == "/entra/callback":
            verifier = PENDING.pop(q.get("state", [""])[0], None)
            if not verifier or "code" not in q:
                return self.send(400, f"Entra sign-in failed: {esc(q.get('error_description', ['state mismatch'])[0])} <a href='/'>Back</a>")
            resp = requests.post(f"{AUTHORITY}/token", timeout=15, data=dict(grant_type="authorization_code", client_id=CLIENT,
                                 code=q["code"][0], redirect_uri=REDIRECT, code_verifier=verifier, scope=SCOPE))
            r = resp.json()  # Entra returns the error code and description as JSON on 4xx
            if not resp.ok: return self.send(400, f"Entra token error: {esc(r.get('error', ''))} <a href='/'>Back</a>")
            idc = json.loads(base64.urlsafe_b64decode(r["id_token"].split(".")[1] + "==")) if r.get("id_token") else {}
            inbound = claims(r["access_token"]); sid = secrets.token_urlsafe(24)
            SESSIONS[sid] = {"token": r["access_token"], "login_hint": idc.get("login_hint"), "inbound": inbound,
                             "user": inbound.get("preferred_username", "?")}
            return self.send(302, headers=[("Location", "/"), ("Set-Cookie", cookie("esid", sid, BASE))])
        if u.path == "/entra/logout":  # state change is POST-only (CSRF); GET never logs out
            return self.send(405, "use POST", headers=[("Allow", "POST")])
        if u.path == "/entra/signed-out":
            return self.send(302, headers=[("Location", "/?signed-out=1"), ("Set-Cookie", "esid=; Max-Age=0; Path=/")])
        if u.path == "/3lo/start" and s:  # ask the agent; consent needed -> send the browser to the authorizationUrl (LOGIN 2)
            r = agent(s, {"mode": "3lo", "return_url": RETURN_3LO, "force": q.get("force") == ["1"]})
            if r.get("status") == "CONSENT_REQUIRED" and r.get("authorizationUrl"):
                s["pending_session_uri"], s["pending_at"] = r.get("sessionUri"), time.time()
                s["last3lo"] = {"step": "redirected to Entra consent", "agent": {k: v for k, v in r.items() if k != "authorizationUrl"}}
                return self.send(302, headers=[("Location", r["authorizationUrl"])])
            s["last3lo"] = {"step": "token already in the vault", "agent": r}
            return self.send(302, headers=[("Location", "/#p3lo")])
        if u.path == "/3lo/callback" and s:  # AgentCore Identity redirects here after consent -> bind the session to THIS user
            session_uri = q.get("session_id", [""])[0]
            pending = take_pending_3lo(s)  # one-time: cleared whether or not it matches
            if not pending or session_uri != pending:  # not the session THIS browser session started: fail closed
                s["last3lo"] = {"step": "callback rejected", "binding": {"matchesPending": False}}
                return self.send(400, "3LO callback does not match a consent started in this session. <a href='/'>Back</a>")
            bind = {"matchesPending": True}
            try:
                ident.complete_resource_token_auth(sessionUri=session_uri, userIdentifier={"userToken": s["token"]})
                bind["CompleteResourceTokenAuth"] = "OK (bound to the signed-in Entra user)"
            except Exception as e:
                bind["CompleteResourceTokenAuth"] = f"{type(e).__name__}: {e}"
            r = agent(s, {"mode": "3lo", "return_url": RETURN_3LO, "session_uri": session_uri})
            s["last3lo"] = {"step": "consent completed", "binding": bind, "agent": r}
            return self.send(302, headers=[("Location", "/#p3lo")])
        if u.path.startswith("/3lo/"): return self.send(302, headers=[("Location", "/")])
        self.send(404, "not found")

    def do_POST(self):
        if self.path == "/entra/logout":  # end the app session AND the Entra SSO session; logout_hint skips the account picker
            if not same_origin_post(self.headers, BASE): return self.send(403, json.dumps({"error": "cross-site request rejected"}), "application/json")
            sid, s = self.session(); SESSIONS.pop(sid, None)
            p = {"post_logout_redirect_uri": SIGNED_OUT, **({"logout_hint": s["login_hint"]} if s and s.get("login_hint") else {})}
            return self.send(200, json.dumps({"location": f"{AUTHORITY}/logout?{urllib.parse.urlencode(p)}"}), "application/json", [("Set-Cookie", "esid=; Max-Age=0; Path=/")])
        _, s = self.session()
        if not s: return self.send(401, json.dumps({"error": "sign in with Entra ID first"}), "application/json")
        mode = {"/api/2lo": "2lo", "/api/obo": "obo", "/api/obo_graph": "obo_graph", "/api/3lo": "3lo"}.get(self.path)
        if not mode: return self.send(404, "{}", "application/json")
        payload = {"mode": mode, **({"return_url": RETURN_3LO} if mode == "3lo" else {})}
        r = agent(s, payload); r.pop("authorizationUrl", None)   # vault check only: never redirect from a POST
        self.send(200, json.dumps({"inbound": s["inbound"], "result": r}), "application/json")


if __name__ == "__main__":
    print(f"open {BASE}  (Ctrl+C to stop)")
    ThreadingHTTPServer(("127.0.0.1", 8083), H).serve_forever()
