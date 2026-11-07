"""Local web GUI for the 2LO / 3LO test cases (separate OAuth runtime rsidc_oauth_agent; OBO GUI on :8080 is untouched).
  LOGIN 1: Cognito managed login (code + PKCE) -> ID token kept server-side -> bearer token to the OAuth runtime.
  2LO    : agent fetches its OWN M2M token (AgentCore Identity) -> AgentCore Gateway tool -> Redshift as svc_reporting.
  3LO    : agent asks AgentCore Identity for the USER's token; first time -> consent URL -> LOGIN 2 (consent at Cognito)
           -> AgentCore callback -> back to /3lo/callback?session_id=... -> CompleteResourceTokenAuth(session, user JWT)
           -> token stored in the Token Vault for (agent, user) -> agent calls Cognito userInfo with it.
Run:  infra/common/run.sh .venv/bin/python webchat/cognito-idc/oauth_app.py   then open http://localhost:8081"""
import base64, hashlib, json, os, secrets, sys, time, urllib.parse, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3

for _p in (".", "../common"):  # "." = Lambda zip layout (flat webchat/), "../common" = this repo
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), _p))
from invoke import invoke  # noqa: E402
from websec import PENDING_TTL, SESSION_TTL, TTLStore, cookie, json_for_script, take_pending_3lo, SECURITY_HEADERS, same_origin_post  # noqa: E402
import requests  # noqa: E402

DOMAIN, CLIENT, RT = os.environ["COGNITO_DOMAIN"], os.environ["COGNITO_CLIENT_ID"], os.environ["OAUTH_RT_ARN"]
if urllib.parse.urlparse(DOMAIN).scheme != "https":  # DOMAIN feeds the token request below: https only
    sys.exit(f"COGNITO_DOMAIN must be an https:// URL, got {DOMAIN!r}")
BASE = os.environ.get("WEB_BASE_URL", "http://localhost:8081"); REDIRECT = f"{BASE}/callback"; RETURN_3LO = f"{BASE}/3lo/callback"
# Session binding is the APP's job; locally it runs with the operator's AWS credentials (bedrock-agentcore:CompleteResourceTokenAuth).
ident = boto3.client(  # local: AWS_PROFILE=default via infra/common/run.sh; Lambda: execution role
    "bedrock-agentcore", region_name=os.environ["RT_REGION"])
SESSIONS, PENDING = TTLStore(SESSION_TTL), TTLStore(PENDING_TTL)  # sid -> session; OAuth state -> PKCE verifier
PAGE = open(os.path.join(os.path.dirname(__file__), "oauth_index.html"), encoding="utf-8").read() \
    .replace("http://localhost:8080", os.environ.get("OBO_WEB_URL", "http://localhost:8080"))


def claims(jwt):
    return json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))


def call_agent(s, payload):
    status, body = invoke(s["token"], payload, runtime_arn=RT, session_id=f"rsidc-web-oauth-{uuid.uuid4()}")
    return {"http": status, **(body if isinstance(body, dict) else {"raw": body})}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body=b"", ctype="text/html; charset=utf-8", headers=()):
        self.send_response(code); self.send_header("Content-Type", ctype)
        for k, v in SECURITY_HEADERS: self.send_header(k, v)
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def sid(self):
        c = dict(p.strip().split("=", 1) for p in self.headers.get("Cookie", "").split(";") if "=" in p)
        return c.get("osid", "")

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query); s = SESSIONS.get(self.sid())
        if u.path == "/":
            view = {"signedIn": bool(s), "user": s["user"] if s else "", "last3lo": s.get("last3lo") if s else None}
            return self.send(200, PAGE.replace("__STATE__", json_for_script(view)))
        if u.path == "/login":
            verifier, state = secrets.token_urlsafe(48), secrets.token_urlsafe(16); PENDING[state] = verifier
            ch = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            p = dict(response_type="code", client_id=CLIENT, redirect_uri=REDIRECT, scope="openid email profile",
                     state=state, code_challenge=ch, code_challenge_method="S256", prompt="login")
            return self.send(302, headers=[("Location", f"{DOMAIN}/oauth2/authorize?{urllib.parse.urlencode(p)}")])
        if u.path == "/callback":  # LOGIN 1 return
            verifier = PENDING.pop(q.get("state", [""])[0], None)
            if not verifier or "code" not in q: return self.send(400, "Invalid or expired sign-in. <a href='/'>Back</a>")
            resp = requests.post(f"{DOMAIN}/oauth2/token", timeout=15, data=dict(grant_type="authorization_code", client_id=CLIENT,
                                 code=q["code"][0], redirect_uri=REDIRECT, code_verifier=verifier))
            resp.raise_for_status()
            tok = resp.json()["id_token"]
            c = claims(tok); sid = secrets.token_urlsafe(24)
            SESSIONS[sid] = {"token": tok, "user": f"{c.get('cognito:username')} ({c.get('email')})"}
            return self.send(302, headers=[("Location", "/"), ("Set-Cookie", cookie("osid", sid, BASE))])
        if u.path == "/3lo/start" and s:  # ask the agent; consent needed -> send the browser to the consent URL (LOGIN 2)
            r = call_agent(s, {"mode": "3lo", "return_url": RETURN_3LO, "force": q.get("force") == ["1"],
                               "prompt_login": q.get("prompt") == ["1"]})
            if r.get("status") == "CONSENT_REQUIRED":
                s["pending_session_uri"], s["pending_at"] = r["sessionUri"], time.time()
                s["last3lo"] = {"step": "redirected to consent", "agent": r}
                return self.send(302, headers=[("Location", r["authorizationUrl"])])
            s["last3lo"] = {"step": "token already in vault", "agent": r}
            return self.send(302, headers=[("Location", "/#3lo")])
        if u.path == "/3lo/callback" and s:  # AgentCore Identity redirects here after consent -> session binding
            session_uri = q.get("session_id", [""])[0]
            pending = take_pending_3lo(s)  # one-time: cleared whether or not it matches
            if not pending or session_uri != pending:  # not the session THIS browser session started: fail closed
                s["last3lo"] = {"step": "callback rejected", "binding": {"matchesPending": False}}
                return self.send(400, "3LO callback does not match a consent started in this session. <a href='/'>Back</a>")
            bind = {"sessionUri": session_uri, "matchesPending": True}
            try:
                ident.complete_resource_token_auth(sessionUri=session_uri, userIdentifier={"userToken": s["token"]})
                bind["CompleteResourceTokenAuth"] = "OK (bound to the signed-in user)"
            except Exception as e:
                bind["CompleteResourceTokenAuth"] = f"{type(e).__name__}: {e}"
            r = call_agent(s, {"mode": "3lo", "return_url": RETURN_3LO, "session_uri": session_uri})
            s["last3lo"] = {"step": "consent completed", "binding": bind, "agent": r}
            return self.send(302, headers=[("Location", "/#3lo")])
        if u.path == "/logout":  # state change is POST-only (CSRF); GET never logs out
            return self.send(405, "use POST", headers=[("Allow", "POST")])
        if u.path.startswith("/3lo/"): return self.send(302, headers=[("Location", "/")])
        self.send(404, "not found")

    def do_POST(self):
        if self.path == "/logout":
            if not same_origin_post(self.headers, BASE): return self.send(403, json.dumps({"error": "cross-site request rejected"}), "application/json")
            SESSIONS.pop(self.sid(), None)
            lo = f"{DOMAIN}/logout?{urllib.parse.urlencode(dict(client_id=CLIENT, logout_uri=BASE + '/'))}"
            return self.send(200, json.dumps({"location": lo}), "application/json", [("Set-Cookie", "osid=; Max-Age=0; Path=/")])
        s = SESSIONS.get(self.sid())
        if not s: return self.send(401, json.dumps({"error": "sign in first"}), "application/json")
        if self.path == "/api/2lo":
            return self.send(200, json.dumps(call_agent(s, {"mode": "2lo"})), "application/json")
        if self.path == "/api/3lo":  # read-only check of the vault (no redirect)
            return self.send(200, json.dumps(call_agent(s, {"mode": "3lo", "return_url": RETURN_3LO})), "application/json")
        self.send(404, "{}", "application/json")


if __name__ == "__main__":
    print(f"open {BASE}  (Ctrl+C to stop)")
    ThreadingHTTPServer(("127.0.0.1", 8081), H).serve_forever()
