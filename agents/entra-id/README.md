# agents/entra-id/
Entra ID track agent (Parts 2–4: 3LO, 2LO, OBO) on AgentCore Runtime `rsidc_entra_agent`. Its users sign in with **Microsoft Entra ID** (inbound customJWTAuthorizer, audience = `rsidc-entra-agent`).

All outbound flows go through ONE AgentCore Identity credential provider, `rsidc-entra` (MicrosoftOauth2). Modes:
- `whoami`: the inbound token's claims;
- `2lo`: M2M (the agent's own app-only token) → `rsidc-mall-entra-gateway`;
- `obo` / `obo_graph`: `ON_BEHALF_OF_TOKEN_EXCHANGE` (Entra OBO, RFC 7523) → a token for `rsidc-mall-api` / Graph that carries the **user**;
- `3lo`: USER_FEDERATION → consent → Token Vault → Graph `/me`, with an identity guard.

Deploy with `infra/entra-id/03-entra-agent-setup.py` (Entra side) and `infra/entra-id/04-entra-agentcore.sh` (AgentCore side).
