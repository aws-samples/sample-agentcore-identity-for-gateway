"""Web GUI for Gateway tool RBAC (per-user tool RBAC on AgentCore Gateway): sign in on Cognito (code + PKCE, OBO client),
then call each gateway's MCP endpoint with the user's ACCESS token (it carries the `roles` claim from the Pre Token trigger).
For every tool the GUI shows: listed by tools/list? and the result of a direct tools/call, so hidden tools prove that
Cedar denies them too. Tokens stay server-side (in memory, keyed by an HttpOnly cookie).
Run:  infra/common/run.sh .venv/bin/python webchat/cognito-idc/rbac_app.py   then open http://localhost:8082"""
import base64, hashlib, json, os, secrets, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import requests

for _p in (".", "../common"):  # "." = Lambda zip layout (flat webchat/), "../common" = this repo
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), _p))
from websec import PENDING_TTL, SESSION_TTL, TTLStore, cookie, json_for_script, SECURITY_HEADERS, same_origin_post  # noqa: E402

DOMAIN, CLIENT = os.environ["COGNITO_DOMAIN"], os.environ["COGNITO_CLIENT_ID"]
if urllib.parse.urlparse(DOMAIN).scheme != "https":  # fail fast: DOMAIN is used for outbound token calls
    raise SystemExit(f"COGNITO_DOMAIN must be an https:// URL, got: {DOMAIN!r}")
BASE = os.environ.get("WEB_BASE_URL", "http://localhost:8082"); REDIRECT = f"{BASE}/callback"
# Each gateway: MCP URL + the full tool catalogue (so the GUI can also try tools that tools/list hides).
GATEWAYS = {
    "demo": {"url": os.environ["RBAC_GW_URL"], "title": "Demo · IdC groups → roles",
             "tools": ["sales___get_sales_summary", "crm___get_customer_contacts"]},
    "mall": {"url": os.environ["MALL_GW_URL"], "title": "Customer version · Cognito groups → roles",
             "tools": ["mall___get_mall_list", "mall___get_footfall_summary", "mall___get_hourly_traffic", "mall___get_zone_comparison"]},
}
# Entra ID version: Microsoft Entra ID sign-in (public client, code + PKCE) for the Entra-trusting gateway. Separate session cookie.
ENTRA = {"tenant": os.environ.get("ENTRA_TENANT_ID"), "client": os.environ.get("ENTRA_CLIENT_ID"), "api": os.environ.get("ENTRA_API_APP_ID")}
ENTRA_GW = {"url": os.environ.get("ENTRA_GW_URL"), "title": "Entra ID version · App Roles → roles", "tools": GATEWAYS["mall"]["tools"]}
ENTRA_REDIRECT, ENTRA_SIGNED_OUT = f"{BASE}/entra/callback", f"{BASE}/entra/signed-out"  # both registered on the Entra app
SESSIONS, PENDING, ESESSIONS = TTLStore(SESSION_TTL), TTLStore(PENDING_TTL), TTLStore(SESSION_TTL)
PAGE = open(os.path.join(os.path.dirname(__file__), "rbac_index.html"), encoding="utf-8").read()


def claims(jwt):
    return json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))


def html_text(t):
    return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def rpc(url, token, method, params=None):
    body = {"jsonrpc": "2.0", "id": 1, "method": method, **({"params": params} if params is not None else {})}
    r = requests.post(url, json=body, timeout=60, headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                                                         "Accept": "application/json, text/event-stream"})
    if not r.ok:  # not raised: check_gateway reports the status per tool (a missing/denied token is a result here, not a crash)
        print(f"gateway {method} -> HTTP {r.status_code}")
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, {"raw": r.text[:300]}


def check_gateway(gw, token):
    """tools/list, then tools/call on every catalogue tool. A Cedar deny is HTTP 200 with result.isError=true."""
    s, j = rpc(gw["url"], token, "tools/list")
    listed = sorted(t["name"] for t in j.get("result", {}).get("tools", []))
    rows = []
    for name in gw["tools"]:
        cs, cj = rpc(gw["url"], token, "tools/call", {"name": name, "arguments": {}})
        res = cj.get("result", {})
        ok = cs == 200 and "error" not in cj and not res.get("isError")
        text = (cj.get("error") or {}).get("message") or (res.get("content") or [{}])[0].get("text", "")
        rows.append({"tool": name, "listed": name in listed, "allowed": ok, "http": cs, "detail": text[:400]})
    return {"title": gw["title"], "list_http": s, "listed": listed, "rows": rows}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body=b"", ctype="text/html; charset=utf-8", headers=()):
        self.send_response(code); self.send_header("Content-Type", ctype)
        for k, v in SECURITY_HEADERS: self.send_header(k, v)
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def cookies(self):
        return dict(p.strip().split("=", 1) for p in self.headers.get("Cookie", "").split(";") if "=" in p)

    def session(self):
        c = self.cookies(); return c.get("rsid", ""), SESSIONS.get(c.get("rsid", ""))

    def entra_session(self):
        c = self.cookies(); return c.get("esid", ""), ESESSIONS.get(c.get("esid", ""))

    def entra_get(self, path, q):
        """/entra/login -> Entra authorize (PKCE); /entra/callback -> code exchange; /entra/logout."""
        esid, e = self.entra_session(); authority = f"https://login.microsoftonline.com/{ENTRA['tenant']}/oauth2/v2.0"
        if path == "/entra/login":
            verifier, state = secrets.token_urlsafe(48), secrets.token_urlsafe(16); PENDING[state] = verifier
            ch = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            p = dict(response_type="code", client_id=ENTRA["client"], redirect_uri=ENTRA_REDIRECT, state=state, prompt="login",
                     scope=f"openid profile api://{ENTRA['api']}/mcp.access", code_challenge=ch, code_challenge_method="S256")
            return self.send(302, headers=[("Location", f"{authority}/authorize?{urllib.parse.urlencode(p)}")])
        if path == "/entra/callback":
            verifier = PENDING.pop(q.get("state", [""])[0], None)
            if not verifier or "code" not in q:
                return self.send(400, f"Entra sign-in failed: {html_text(q.get('error_description', ['state mismatch'])[0])} <a href='/'>Back</a>")
            resp = requests.post(f"{authority}/token", timeout=15, data=dict(grant_type="authorization_code", client_id=ENTRA["client"],
                                 code=q["code"][0], redirect_uri=ENTRA_REDIRECT, code_verifier=verifier,
                                 scope=f"api://{ENTRA['api']}/mcp.access"))
            r = resp.json()  # Entra returns the error code and description as JSON on 4xx
            if not resp.ok: return self.send(400, f"Entra token error: {html_text(r.get('error', ''))} <a href='/'>Back</a>")
            c = claims(r["access_token"]); esid = secrets.token_urlsafe(24)
            ESESSIONS[esid] = {"access": r["access_token"], "login_hint": claims(r["id_token"]).get("login_hint") if r.get("id_token") else None, "roles": c.get("roles", []), "user": c.get("preferred_username", c.get("upn", "?")),
                               "claims": {k: c.get(k) for k in ("ver", "iss", "aud", "azp", "scp")}}
            return self.send(302, headers=[("Location", "/#entra"), ("Set-Cookie", cookie("esid", esid, BASE))])
        if path == "/entra/logout":  # state change is POST-only (CSRF); GET never logs out
            return self.send(405, "use POST", headers=[("Allow", "POST")])
        if path == "/entra/signed-out":
            return self.send(302, headers=[("Location", "/?entra=signed-out#entra"), ("Set-Cookie", "esid=; Max-Age=0; Path=/")])
        self.send(404, "not found")

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query); sid, s = self.session()
        if u.path == "/":
            _, e = self.entra_session()
            view = {"signedIn": bool(s), "user": s["user"] if s else "", "roles": s["roles"] if s else [],
                    "gateways": {k: g["title"] for k, g in GATEWAYS.items()},
                    "entra": {"enabled": bool(ENTRA_GW["url"]), "title": ENTRA_GW["title"], "signedIn": bool(e),
                              "user": e["user"] if e else "", "roles": e["roles"] if e else [], "claims": e["claims"] if e else {}}}
            return self.send(200, PAGE.replace("__STATE__", json_for_script(view)))
        if u.path.startswith("/entra/") and ENTRA_GW["url"]:
            return self.entra_get(u.path, q)
        if u.path == "/login":
            verifier, state = secrets.token_urlsafe(48), secrets.token_urlsafe(16); PENDING[state] = verifier
            ch = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            p = dict(response_type="code", client_id=CLIENT, redirect_uri=REDIRECT, scope="openid email profile",
                     state=state, code_challenge=ch, code_challenge_method="S256", prompt="login")
            return self.send(302, headers=[("Location", f"{DOMAIN}/oauth2/authorize?{urllib.parse.urlencode(p)}")])
        if u.path == "/callback":
            verifier = PENDING.pop(q.get("state", [""])[0], None)
            if not verifier or "code" not in q: return self.send(400, "Invalid or expired sign-in. <a href='/'>Back</a>")
            resp = requests.post(f"{DOMAIN}/oauth2/token", timeout=15, data=dict(grant_type="authorization_code", client_id=CLIENT,
                                 code=q["code"][0], redirect_uri=REDIRECT, code_verifier=verifier))
            resp.raise_for_status()
            tok = resp.json()
            ac, idc = claims(tok["access_token"]), claims(tok["id_token"]); sid = secrets.token_urlsafe(24)
            SESSIONS[sid] = {"access": tok["access_token"], "roles": ac.get("roles", []),
                             "user": f"{ac.get('username')} ({idc.get('email')})"}
            return self.send(302, headers=[("Location", "/"), ("Set-Cookie", cookie("rsid", sid, BASE))])
        if u.path == "/logout":  # state change is POST-only (CSRF); GET never logs out
            return self.send(405, "use POST", headers=[("Allow", "POST")])
        self.send(404, "not found")

    def do_POST(self):
        if self.path == "/logout":
            if not same_origin_post(self.headers, BASE): return self.send(403, json.dumps({"error": "cross-site request rejected"}), "application/json")
            SESSIONS.pop(self.session()[0], None)
            lo = f"{DOMAIN}/logout?{urllib.parse.urlencode(dict(client_id=CLIENT, logout_uri=BASE + '/'))}"
            return self.send(200, json.dumps({"location": lo}), "application/json", [("Set-Cookie", "rsid=; Max-Age=0; Path=/")])
        if self.path == "/entra/logout" and ENTRA_GW["url"]:  # end the app session AND the Entra SSO session; logout_hint skips the account picker
            if not same_origin_post(self.headers, BASE): return self.send(403, json.dumps({"error": "cross-site request rejected"}), "application/json")
            esid, e = self.entra_session(); ESESSIONS.pop(esid, None)
            p = {"post_logout_redirect_uri": ENTRA_SIGNED_OUT, **({"logout_hint": e["login_hint"]} if e and e.get("login_hint") else {})}
            lo = f"https://login.microsoftonline.com/{ENTRA['tenant']}/oauth2/v2.0/logout?{urllib.parse.urlencode(p)}"
            return self.send(200, json.dumps({"location": lo}), "application/json", [("Set-Cookie", "esid=; Max-Age=0; Path=/")])
        if self.path == "/api/check/entra":
            _, e = self.entra_session()
            if not e or not ENTRA_GW["url"]: return self.send(401, json.dumps({"error": "sign in with Entra ID first"}), "application/json")
            return self.send(200, json.dumps(check_gateway(ENTRA_GW, e["access"])), "application/json")
        _, s = self.session()
        if not s: return self.send(401, json.dumps({"error": "sign in first"}), "application/json")
        gw = GATEWAYS.get(self.path.removeprefix("/api/check/"))
        if not gw: return self.send(404, "{}", "application/json")
        self.send(200, json.dumps(check_gateway(gw, s["access"])), "application/json")


if __name__ == "__main__":
    print(f"open {BASE}  (Ctrl+C to stop)")
    ThreadingHTTPServer(("127.0.0.1", 8082), H).serve_forever()
