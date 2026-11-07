# infra/cognito-idc/registry/
Record bodies that `infra/common/agent-registry.py` sends to AWS Agent Registry (`rsidc-registry`, ap-northeast-1). The script writes them here on every run, so they show exactly what was registered.
- `rsidc-data-agent.json`, `rsidc-oauth-agent.json`: AgentCore runtimes. They are `CUSTOM` records because these runtimes speak the AgentCore invocations API, not A2A.
- `rsidc-2lo-gateway.json`, `rsidc-rbac-gateway.json`, `rsidc-mall-gateway.json`, and `../../entra-id/registry/rsidc-mall-entra-gateway.json` (Microsoft Entra ID version): AgentCore gateways. They are `MCP` records with a `server.json` (2025-12-11 schema) plus the tool list, read from the deployed gateway targets.
No secrets: the records hold endpoints, client IDs and auth descriptions only.
