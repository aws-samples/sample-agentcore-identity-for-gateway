"""Appendix (Agent Registry): catalogue this project's AgentCore runtimes and gateways (MCP servers) in AWS Agent Registry.
Agent Registry runs in only five Regions, not ap-southeast-1, so the registry lives in ap-northeast-1 (Tokyo) and the
records are created manually, as metadata pointing at the Singapore endpoints. URL sync can't be used: every
endpoint requires a JWT (Cognito, or Microsoft Entra ID for rsidc-mall-entra-gateway). Gateway tool definitions are read from the deployed targets (read-only).
Idempotent: an existing record (same name + version) is skipped. Records are submitted, then approved (manual approval).
Run: infra/common/run.sh .venv/bin/python infra/common/agent-registry.py           (Tokyo)
     REGISTRY_REGION=us-east-1 infra/common/run.sh .venv/bin/python infra/common/agent-registry.py   (for Amazon Quick: same Region as Quick)"""
import json, os, threading, boto3

REG_REGION, SRC = os.environ.get("REGISTRY_REGION", "ap-northeast-1"), os.environ["RT_REGION"]  # us-east-1 = the Quick account's home Region
s = boto3.Session()
reg = s.client("agent-registry-control", region_name=REG_REGION)
ctl = s.client("bedrock-agentcore-control", region_name=SRC)
NAME, VERSION, OWNER = "rsidc-registry", "1.0.0", "Jacky Wu (rsidc PoC)"
INFRA = os.path.join(os.path.dirname(__file__), "..")  # records are written next to their track: infra/<track>/registry/
COGNITO = f"Cognito user pool {os.environ['COGNITO_POOL_ID']} ({SRC})"


def registry_id():
    for r in reg.list_registries()["registries"]:
        if r["name"] == NAME: return r["registryId"]
    rid = reg.create_registry(name=NAME, tags={"Project": "rsidc"},
                              description="rsidc PoC: AgentCore runtimes and gateways (MCP) for the AgentCore Identity x Redshift x IdC and tool RBAC tests")["registryArn"].split("/")[-1]
    return rid


def gateway_tools(gw_id):
    tools = []
    for t in ctl.list_gateway_targets(gatewayIdentifier=gw_id)["items"]:
        cfg = ctl.get_gateway_target(gatewayIdentifier=gw_id, targetId=t["targetId"])["targetConfiguration"]["mcp"]["lambda"]["toolSchema"]
        for tool in cfg.get("inlinePayload", []):
            tools.append({"name": f"{t['name']}___{tool['name']}", "description": tool.get("description", ""),
                          "inputSchema": tool.get("inputSchema", {"type": "object", "properties": {}})})
    return {"tools": tools}


def mcp_record(name, title, desc, url, gw_id, auth):
    server = {"name": f"io.github.aws-samples/{name}", "title": title, "description": desc[:100], "version": VERSION,
              "remotes": [{"type": "streamable-http", "url": url}]}
    tools = gateway_tools(gw_id)
    return dict(name=name, displayName=title, recordType="MCP", recordVersion=VERSION,
                description=f"{desc}\nAuth: {auth}\nTools: {', '.join(t['name'] for t in tools['tools'])}\nOwner: {OWNER}",
                descriptors={"mcpServer": {"data": json.dumps(server), "dataSchemaVersion": "2025-12-11",
                                           "additionalData": {"tools": {"data": json.dumps(tools), "dataSchemaVersion": "2025-06-18"}}}})


def agent_record(name, title, desc, arn, auth):
    url = f"https://bedrock-agentcore.{SRC}.amazonaws.com/runtimes/{arn.replace(':', '%3A').replace('/', '%2F')}/invocations?qualifier=DEFAULT"
    card = {"kind": "agentcore-runtime", "name": name, "description": desc, "runtimeArn": arn, "invocationUrl": url,
            "protocol": "HTTP (AgentCore Runtime invocations)", "inboundAuth": auth, "owner": OWNER, "version": VERSION}
    return dict(name=name, displayName=title, recordType="CUSTOM", recordVersion=VERSION,
                description=f"{desc}\nInvoke: POST {url}\nAuth: {auth}\nOwner: {OWNER}",
                descriptors={"custom": {"data": json.dumps(card)}})


E = os.environ
RECORDS = [
    agent_record("rsidc-data-agent", "OBO data agent (Redshift as the user)",
                 "Strands agent on AgentCore Runtime. It exchanges the caller's Cognito JWT for an IAM Identity Center token (trusted token issuer) and queries Amazon Redshift as AWSIDC:<user>, so Redshift grants and row-level security apply per user.",
                 E["RT_ARN"], f"Bearer Cognito ID token; {COGNITO}; audience = OBO client {E['COGNITO_CLIENT_ID']}"),
    agent_record("rsidc-oauth-agent", "2LO / 3LO agent (AgentCore Identity)",
                 "Agent on AgentCore Runtime that demonstrates AgentCore Identity outbound auth: 2LO (M2M token → AgentCore Gateway → Redshift as svc_reporting) and 3LO (user consent → Token Vault → Cognito userInfo).",
                 E["OAUTH_RT_ARN"], f"Bearer Cognito ID token; {COGNITO}; audience = OBO client"),
    mcp_record("rsidc-2lo-gateway", "2LO reporting gateway", "AgentCore Gateway (MCP). A sales report through Lambda as the shared Redshift user svc_reporting; it shows the same data to every caller.",
               E["GW_URL"], E["GW_ID"], f"Bearer Cognito M2M access token; allowedClients = 2LO client {E['C2LO_CLIENT_ID']}"),
    mcp_record("rsidc-rbac-gateway", "Tool RBAC gateway (IdC groups)", "AgentCore Gateway (MCP) with Policy in AgentCore (Cedar, ENFORCE): each tool needs a role in the access token's roles claim, which is derived from IAM Identity Center group Descriptions by a Cognito Pre Token trigger.",
               E["RBAC_GW_URL"], E["RBAC_GW_ID"], f"Bearer Cognito access token with roles claim; allowedClients = OBO client; Cedar policy engine {E['RBAC_PE_ID']}"),
    mcp_record("rsidc-mall-gateway", "Mall tools gateway (Cognito groups, Quick)", "AgentCore Gateway (MCP), customer version: 4 mall footfall tools, per-user RBAC via Cedar on the roles claim (from Cognito group Descriptions). Client: Amazon Quick MCP integration (user OAuth).",
               E["MALL_GW_URL"], E["MALL_GW_ID"], f"Bearer Cognito access token with roles claim; allowedClients = Quick client + OBO client; Cedar policy engine {E['MALL_PE_ID']}"),
    mcp_record("rsidc-mall-entra-gateway", "Mall tools gateway (Microsoft Entra ID)", "AgentCore Gateway (MCP), Entra ID version: the same 4 mall tools, per-user RBAC via Cedar on Entra's native App Role claim roles. No Cognito.",
               E["ENTRA_GW_URL"], E["ENTRA_GW_ID"], f"Bearer Microsoft Entra ID v2 access token (tenant {E['ENTRA_TENANT_ID']}); allowedAudience = rsidc-mall-api {E['ENTRA_API_APP_ID']}; Cedar policy engine {E['ENTRA_PE_ID']}"),
]


def poll(get_status, done, what, tries=40, interval=3):
    """Poll a resource status until `done(status)` (Agent Registry has no waiters). Bounded: `tries` x `interval` seconds.
    Event.wait is an interruptible timer, not a blind sleep."""
    timer = threading.Event()
    for _ in range(tries):
        st = get_status()
        if done(st["status"]): return st
        if st["status"].endswith("FAILED"): raise RuntimeError(f"{what}: {st['status']} {st.get('statusReason')}")
        timer.wait(interval)
    raise TimeoutError(what)


def wait(rid, rec_id, ok):
    return poll(lambda: reg.get_registry_record(registryId=rid, recordId=rec_id), lambda s: s in ok, rec_id)


rid = registry_id()


def registry_ready():
    poll(lambda: reg.get_registry(registryId=rid), lambda s: s == "READY", f"registry {rid}", interval=5)


registry_ready()
existing = {(r["name"], r.get("recordVersion")): r for r in reg.list_registry_records(registryId=rid).get("registryRecords", [])}
for r in RECORDS:
    track = "entra-id" if "entra" in r["name"] else "cognito-idc"
    with open(os.path.join(INFRA, track, "registry", f"{r['name']}.json"), "w", encoding="utf-8") as f:
        json.dump(r, f, indent=1)
    if (r["name"], VERSION) in existing:
        print(f"skip {r['name']} (exists: {existing[(r['name'], VERSION)]['status']})"); continue
    rec_id = reg.create_registry_record(registryId=rid, **r)["recordArn"].split("/")[-1]
    wait(rid, rec_id, {"DRAFT"})
    reg.submit_registry_record_for_approval(registryId=rid, recordId=rec_id); wait(rid, rec_id, {"PENDING_APPROVAL", "APPROVED"})
    reg.update_registry_record_status(registryId=rid, recordId=rec_id, status="APPROVED", statusReason="rsidc PoC owner approval")
    print(f"{r['name']:20} {r['recordType']:6} {rec_id} {wait(rid, rec_id, {'APPROVED'})['status']}")
print(f"registry {rid} ({REG_REGION})")
