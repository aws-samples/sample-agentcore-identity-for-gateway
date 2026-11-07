# infra/common/lambda/mall_tools/
Gateway tool RBAC, customer version (used by Part 1 · Amazon Quick). The customer's 4 mall-footfall tools, implemented as **one** AgentCore Gateway Lambda target named `mall`.
- **Tools:** `get_mall_list`, `get_footfall_summary`, `get_hourly_traffic`, `get_zone_comparison`. Through the Gateway they appear as `mall___<tool>`.
- **Schemas:** `tools.json` holds the inline tool schema registered on the target.
- **Where MCP and auth live:** the Gateway is the MCP server that Amazon Quick connects to. This Lambda has no public endpoint and no per-user logic. Only the Gateway role can invoke it. Per-user tool RBAC is Cedar at the Gateway.
- **Data:** deterministic mock data. The real tools run parameterized SQL on MySQL, with credentials from Secrets Manager.
- **Shared:** also the target of the Entra gateway (`infra/entra-id/02-entra-gateway.sh`), which reuses this Lambda.
- **Deploy:** `infra/common/run.sh bash infra/cognito-idc/16-mall-gateway.sh`.
