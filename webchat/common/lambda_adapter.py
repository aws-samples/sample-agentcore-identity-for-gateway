"""Run the existing webchat handlers (obo_app.py / oauth_app.py) behind API Gateway (HTTP API), unchanged.
The HTTP API event (payload format 2.0) is replayed as a raw HTTP request into the module's BaseHTTPRequestHandler `H`, and the
written HTTP response is parsed back into the payload 2.0 response format.
Env: WEBCHAT_APP=obo_app|oauth_app|rbac_app|entra_app (allowlist below). No IP filtering here: restrict access in front of the API (e.g. resource policy / WAF).
Sessions live in module memory, so the function runs with reserved concurrency 1 (one warm environment)."""
import base64, importlib, io, os, sys

sys.path.insert(0, os.path.dirname(__file__))
# Allowlist: only these modules ship in the zip. Each import is a literal, so WEBCHAT_APP can never name an arbitrary module.
_NAME = os.environ["WEBCHAT_APP"]
if _NAME == "obo_app":
    APP = importlib.import_module("obo_app")
elif _NAME == "oauth_app":
    APP = importlib.import_module("oauth_app")
elif _NAME == "rbac_app":
    APP = importlib.import_module("rbac_app")
elif _NAME == "entra_app":
    APP = importlib.import_module("entra_app")
else:
    raise RuntimeError(f"WEBCHAT_APP must be one of obo_app, oauth_app, rbac_app, entra_app; got {_NAME!r}")


class _Handler(APP.H):
    def __init__(self, raw, client_ip):
        self.raw = raw
        super().__init__(None, (client_ip, 0), None)

    def setup(self):
        self.rfile, self.wfile = io.BytesIO(self.raw), io.BytesIO()

    def finish(self):
        pass


def _to_raw_request(event):
    http = event["requestContext"]["http"]
    body = event.get("body") or ""
    body = base64.b64decode(body) if event.get("isBase64Encoded") else body.encode()
    target = event["rawPath"] + (f"?{event['rawQueryString']}" if event.get("rawQueryString") else "")
    headers = {k: v for k, v in event.get("headers", {}).items() if k not in ("content-length", "cookie")}
    headers["content-length"] = str(len(body))
    if event.get("cookies"):
        headers["cookie"] = "; ".join(event["cookies"])
    head = "".join(f"{k}: {v}\r\n" for k, v in headers.items())
    return f"{http['method']} {target} HTTP/1.1\r\n{head}\r\n".encode() + body


def _to_response(raw):
    head, _, body = raw.partition(b"\r\n\r\n")
    status_line, *lines = head.decode("iso-8859-1").split("\r\n")
    headers, cookies = {}, []
    for line in lines:
        k, v = line.split(":", 1)
        if k.lower() == "set-cookie":
            cookies.append(v.strip())
        else:
            headers[k] = v.strip()
    return {"statusCode": int(status_line.split()[1]), "headers": headers, "cookies": cookies,
            "body": body.decode("utf-8"), "isBase64Encoded": False}


def handler(event, _context):
    ip = event["requestContext"]["http"]["sourceIp"]
    return _to_response(_Handler(_to_raw_request(event), ip).wfile.getvalue())
