"""Invoke the AgentCore Runtime over HTTPS with an end-user bearer token (OAuth inbound auth; no SigV4)."""
import json, os, urllib.parse, uuid, requests

def invoke(token, payload, session_id=None, timeout=300, runtime_arn=None):
    arn = urllib.parse.quote(runtime_arn or os.environ["RT_ARN"], safe="")
    url = f"https://bedrock-agentcore.{os.environ['RT_REGION']}.amazonaws.com/runtimes/{arn}/invocations?qualifier=DEFAULT"
    headers = {"Content-Type": "application/json",
               "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": session_id or f"rsidc-{uuid.uuid4()}"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    r = requests.post(url, headers=headers, data=json.dumps(payload), timeout=timeout)
    if not r.ok:  # not raised: callers return the status to the GUI, which shows 401/403 verbatim
        print(f"AgentCore Runtime invoke -> HTTP {r.status_code}")
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, r.text
