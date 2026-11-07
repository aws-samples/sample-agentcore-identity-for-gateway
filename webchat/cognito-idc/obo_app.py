"""Local web chat for the OBO data agent: sign in on Cognito managed login (auth code + PKCE), then chat.
The ID token stays server-side (in memory, keyed by an HttpOnly session cookie) and is sent to AgentCore Runtime
as the bearer token. One runtime session per sign-in, so the IdC token exchange happens once (single-use JWT).
Run:  infra/common/run.sh .venv/bin/python webchat/cognito-idc/obo_app.py   then open http://localhost:8080"""
import base64, hashlib, html, json, os, secrets, sys, urllib.parse, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

for _p in (".", "../common"):  # "." = Lambda zip layout (flat webchat/), "../common" = this repo
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), _p))
from invoke import invoke  # noqa: E402
from websec import PENDING_TTL, SESSION_TTL, TTLStore, cookie, SECURITY_HEADERS, same_origin_post  # noqa: E402
import requests  # noqa: E402

DOMAIN, CLIENT = os.environ["COGNITO_DOMAIN"], os.environ["COGNITO_CLIENT_ID"]
if urllib.parse.urlparse(DOMAIN).scheme != "https":  # outbound token calls must be https only (no file:/http:)
    raise SystemExit(f"COGNITO_DOMAIN must be an https:// URL, got: {DOMAIN!r}")
BASE = os.environ.get("WEB_BASE_URL", "http://localhost:8080")  # API Gateway HTTP API endpoint URL when deployed (infra/cognito-idc/14-deploy-webchat.sh)
REDIRECT = f"{BASE}/callback"
SESSIONS, PENDING = TTLStore(SESSION_TTL), TTLStore(PENDING_TTL)  # sid -> {token, user, runtime_session}; state -> code_verifier
PAGE = open(os.path.join(os.path.dirname(__file__), "index.html"), encoding="utf-8").read()


def claims(jwt):
    return json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body=b"", ctype="text/html; charset=utf-8", headers=()):
        self.send_response(code); self.send_header("Content-Type", ctype)
        for k, v in SECURITY_HEADERS: self.send_header(k, v)
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def session(self):
        c = dict(p.strip().split("=", 1) for p in self.headers.get("Cookie", "").split(";") if "=" in p)
        return SESSIONS.get(c.get("sid", ""))

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        if u.path == "/":
            s = self.session()
            return self.send(200, PAGE.replace("__USER__", html.escape(s["user"]) if s else "")
                                      .replace("__SIGNEDIN__", "true" if s else "false"))
        if u.path == "/login":
            verifier = secrets.token_urlsafe(48); state = secrets.token_urlsafe(16); PENDING[state] = verifier
            challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            params = dict(response_type="code", client_id=CLIENT, redirect_uri=REDIRECT, scope="openid email profile",
                          state=state, code_challenge=challenge, code_challenge_method="S256", prompt="login")
            return self.send(302, headers=[("Location", f"{DOMAIN}/oauth2/authorize?{urllib.parse.urlencode(params)}")])
        if u.path == "/callback":
            verifier = PENDING.pop(q.get("state", [""])[0], None)
            if not verifier or "code" not in q:
                return self.send(400, "Invalid or expired sign-in (state mismatch). <a href='/'>Back</a>")
            resp = requests.post(f"{DOMAIN}/oauth2/token", timeout=15, data=dict(grant_type="authorization_code", client_id=CLIENT,
                                 code=q["code"][0], redirect_uri=REDIRECT, code_verifier=verifier))
            resp.raise_for_status()
            tok = resp.json()["id_token"]
            c = claims(tok); sid = secrets.token_urlsafe(24)
            SESSIONS[sid] = {"token": tok, "user": f"{c.get('cognito:username')} ({c.get('email')})",
                             "runtime_session": f"rsidc-web-{uuid.uuid4()}"}
            return self.send(302, headers=[("Location", "/"), ("Set-Cookie", cookie("sid", sid, BASE))])
        if u.path == "/logout":  # state change is POST-only (CSRF); GET never logs out
            return self.send(405, "use POST", headers=[("Allow", "POST")])
        self.send(404, "not found")

    def do_POST(self):
        if self.path == "/logout":
            if not same_origin_post(self.headers, BASE): return self.send(403, json.dumps({"error": "cross-site request rejected"}), "application/json")
            c = dict(p.strip().split("=", 1) for p in self.headers.get("Cookie", "").split(";") if "=" in p)
            SESSIONS.pop(c.get("sid", ""), None)
            lo = f"{DOMAIN}/logout?{urllib.parse.urlencode(dict(client_id=CLIENT, logout_uri=BASE + '/'))}"
            return self.send(200, json.dumps({"location": lo}), "application/json", [("Set-Cookie", "sid=; Max-Age=0; Path=/")])
        s = self.session()
        if self.path != "/api/ask" or not s:
            return self.send(401, json.dumps({"error": "sign in first"}), "application/json")
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        body = {"sql": payload["sql"]} if payload.get("sql") else {"prompt": payload.get("prompt", "")}
        status, res = invoke(s["token"], body, session_id=s["runtime_session"])
        self.send(200, json.dumps({"status": status, "result": res}), "application/json")


if __name__ == "__main__":
    print("open http://localhost:8080  (Ctrl+C to stop)")
    ThreadingHTTPServer(("127.0.0.1", 8080), H).serve_forever()
