"""Security checks for the GUI apps (F-02, F-03, F-04). No network, no AWS: clients are stubs.
Run from the repo root:  .venv/bin/python webchat/tests/test_security.py"""
import importlib, io, os, sys, types, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
for d in ("common", "cognito-idc", "entra-id"):
    sys.path.insert(0, os.path.join(HERE, "..", d))
os.environ.update(COGNITO_DOMAIN="https://idp.example", COGNITO_CLIENT_ID="c", OAUTH_RT_ARN="arn:rt", RT_REGION="us-east-1",
                  ENTRA_TENANT_ID="t", ENTRA_CLIENT_ID="c", ENTRA_AGENT_APP_ID="a", ENTRA_RT_ARN="arn:rt",
                  RBAC_GW_URL="https://gw", MALL_GW_URL="https://gw", AWS_DEFAULT_REGION="us-east-1",
                  AWS_ACCESS_KEY_ID="x", AWS_SECRET_ACCESS_KEY="x")  # dummy: boto3 client creation only, never called
import websec  # noqa: E402

oauth_app, entra_app = importlib.import_module("oauth_app"), importlib.import_module("entra_app")
obo_app, rbac_app = importlib.import_module("obo_app"), importlib.import_module("rbac_app")


class Stub:
    def __init__(self): self.calls = []
    def complete_resource_token_auth(self, **kw): self.calls.append(kw)


def post(app, path, headers=None):
    """Drive app.H.do_POST without a socket; return (status, headers dict, body)."""
    h = object.__new__(app.H)
    h.path, h.requestline, h.request_version, h.command = path, f"POST {path} HTTP/1.1", "HTTP/1.1", "POST"
    h.headers, h.wfile, h.client_address = {"Content-Length": "0", **(headers or {})}, io.BytesIO(), ("127.0.0.1", 0)
    h.rfile = io.BytesIO(b"")
    h.do_POST()
    head, _, body = h.wfile.getvalue().partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    return int(lines[0].split()[1]), dict(l.split(": ", 1) for l in lines[1:]), body.decode()


def get(app, path, cookie_header=""):
    """Drive app.H.do_GET without a socket; return (status, headers dict, body)."""
    h = object.__new__(app.H)
    h.path, h.requestline, h.request_version, h.command = path, f"GET {path} HTTP/1.1", "HTTP/1.1", "GET"
    h.headers, h.wfile, h.client_address = {"Cookie": cookie_header}, io.BytesIO(), ("127.0.0.1", 0)
    h.do_GET()
    head, _, body = h.wfile.getvalue().partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    return int(lines[0].split()[1]), dict(l.split(": ", 1) for l in lines[1:]), body.decode()


class Escaping(unittest.TestCase):
    def test_no_markup_chars_survive(self):
        out = websec.json_for_script({"a": "</script><img onerror=x>", "b": "x y &"})
        for bad in ("</", "<", ">", "&", " ", " "):
            self.assertNotIn(bad, out)

    def test_round_trips(self):
        import json
        v = {"a": "</script><img onerror=x>", "b": "x y&"}
        self.assertEqual(json.loads(websec.json_for_script(v)), v)

    def test_oauth_index_page_escaped(self):
        sid = "s1"; oauth_app.SESSIONS[sid] = {"token": "t", "user": "</script><script>alert(1)</script>"}
        _, _, body = get(oauth_app, "/", f"osid={sid}")
        self.assertNotIn("</script><script>", body)


class Callback3lo(unittest.TestCase):
    def run_cb(self, app, pending, returned):
        stub, calls = Stub(), []
        app.ident = stub
        app_fn = "call_agent" if app is oauth_app else "agent"
        setattr(app, app_fn, lambda s, p: calls.append(p) or {"http": 200})
        sess = {"token": "t", "user": "u", "inbound": {}}
        if pending: sess["pending_session_uri"], sess["pending_at"] = pending, __import__("time").time()
        app.SESSIONS["sidx"] = sess
        ck = ("osid" if app is oauth_app else "esid") + "=sidx"
        status, _, body = get(app, f"/3lo/callback?session_id={returned}", ck)
        return status, stub, calls, sess

    def test_mismatch_rejected_and_pending_cleared(self):
        for app in (oauth_app, entra_app):
            status, stub, calls, sess = self.run_cb(app, "urn:ours", "urn:attacker")
            self.assertEqual(status, 400, app.__name__)
            self.assertEqual(stub.calls, []); self.assertEqual(calls, [])
            self.assertNotIn("pending_session_uri", sess)

    def test_no_pending_rejected(self):
        for app in (oauth_app, entra_app):
            status, stub, _, _ = self.run_cb(app, None, "urn:any")
            self.assertEqual((status, stub.calls), (400, []))

    def test_match_completes_once(self):
        for app in (oauth_app, entra_app):
            status, stub, calls, sess = self.run_cb(app, "urn:ours", "urn:ours")
            self.assertEqual(status, 302); self.assertEqual(len(stub.calls), 1)
            self.assertNotIn("pending_session_uri", sess)
            ck = ("osid" if app is oauth_app else "esid") + "=sidx"
            status, _, _ = get(app, "/3lo/callback?session_id=urn:ours", ck)  # replay
            self.assertEqual((status, len(stub.calls)), (400, 1))


# app -> (logout path, session cookie name, session store); every GUI has a Cognito/Entra logout
LOGOUTS = [(obo_app, "/logout", "sid", obo_app.SESSIONS), (oauth_app, "/logout", "osid", oauth_app.SESSIONS),
           (rbac_app, "/logout", "rsid", rbac_app.SESSIONS), (entra_app, "/entra/logout", "esid", entra_app.SESSIONS)]
PAGES = [(obo_app, "/"), (oauth_app, "/"), (rbac_app, "/"), (entra_app, "/")]


class Hardening(unittest.TestCase):  # T-14
    def test_headers_on_every_html_response(self):
        for app, path in PAGES:
            _, h, _ = get(app, path)
            self.assertEqual(dict(websec.SECURITY_HEADERS).items() <= h.items(), True, app.__name__)
            self.assertIn("frame-ancestors 'none'", h["Content-Security-Policy"])
            self.assertEqual((h["X-Frame-Options"], h["X-Content-Type-Options"], h["Referrer-Policy"]), ("DENY", "nosniff", "no-referrer"))
            self.assertNotIn("script-src", h["Content-Security-Policy"])
        _, h, _ = get(oauth_app, "/nope"); self.assertEqual(h["X-Frame-Options"], "DENY")  # error pages too

    def test_get_logout_does_not_log_out(self):
        for app, path, ck, store in LOGOUTS:
            store["s1"] = {"token": "t", "user": "u", "access": "t", "roles": []}
            status, h, _ = get(app, path, f"{ck}=s1")
            self.assertEqual(status, 405, app.__name__); self.assertIsNotNone(store.get("s1"), app.__name__)
            self.assertNotIn("Set-Cookie", h)

    def test_cross_origin_post_rejected(self):
        for app, path, ck, store in LOGOUTS:
            for hdr in ({"Sec-Fetch-Site": "cross-site"}, {"Sec-Fetch-Site": "same-site"}, {"Origin": "https://evil.example"},
                        {"Origin": "null"}, {}):
                store["s1"] = {"token": "t", "user": "u", "access": "t", "roles": []}
                status, _, _ = post(app, path, {"Cookie": f"{ck}=s1", **hdr})
                self.assertEqual(status, 403, (app.__name__, hdr)); self.assertIsNotNone(store.get("s1"))

    def test_same_origin_post_logs_out(self):
        import json
        for app, path, ck, store in LOGOUTS:
            for hdr in ({"Sec-Fetch-Site": "same-origin"}, {"Origin": app.BASE}):
                store["s1"] = {"token": "t", "user": "u", "access": "t", "roles": []}
                status, h, body = post(app, path, {"Cookie": f"{ck}=s1", **hdr})
                self.assertEqual(status, 200, (app.__name__, hdr)); self.assertIsNone(store.get("s1"))
                self.assertIn("Max-Age=0", h["Set-Cookie"]); self.assertTrue(json.loads(body)["location"].startswith("https://"))

    def test_pages_wire_logout_as_post(self):
        for name in ("cognito-idc/index.html", "cognito-idc/oauth_index.html", "cognito-idc/rbac_index.html", "entra-id/entra_index.html"):
            with open(os.path.join(HERE, "..", name), encoding="utf-8") as fh: page = fh.read()
            self.assertNotIn('href="/logout"', page); self.assertNotIn('href="/entra/logout"', page)
            self.assertIn("method: \"POST\"", page); self.assertIn("data-logout", page)


class Cookies(unittest.TestCase):
    def test_secure_only_for_https(self):
        self.assertIn("Secure", websec.cookie("a", "b", "https://x.example"))
        self.assertNotIn("Secure", websec.cookie("a", "b", "http://localhost:8080"))
        for c in (websec.cookie("a", "b", "https://x"), websec.cookie("a", "b", "http://x")):
            self.assertTrue(all(f in c for f in ("HttpOnly", "SameSite=Lax", "Path=/", "Max-Age=3600")))


class Store(unittest.TestCase):
    def test_ttl_and_cap(self):
        now = [0.0]; st = websec.TTLStore(10, max_entries=3, clock=lambda: now[0])
        for i in range(5): st[i] = i
        self.assertEqual(len(st), 3); self.assertIsNone(st.get(0)); self.assertEqual(st.get(4), 4)
        now[0] = 11
        self.assertIsNone(st.get(4)); self.assertEqual(len(st), 0)

    def test_pending_expires(self):
        s = {"pending_session_uri": "u", "pending_at": 0}
        self.assertIsNone(websec.take_pending_3lo(s, clock=lambda: websec.PENDING_TTL + 1))
        self.assertNotIn("pending_session_uri", s)


if __name__ == "__main__":
    unittest.main(verbosity=2)
