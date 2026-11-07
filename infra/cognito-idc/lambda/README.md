# infra/cognito-idc/lambda/
`reporting/handler.py` is the AgentCore Gateway Lambda target for the 2LO test. It runs a fixed report on Redshift as the shared
service user `svc_reporting` (Data API + GetClusterCredentials), so the end user's identity is **not** propagated. Deployed by `infra/cognito-idc/11-2lo-gateway.sh`.

Gateway tool RBAC, demo version:
- `rbac_tools/`: tool A and tool B Lambda targets, deployed by `infra/cognito-idc/15-rbac-gateway.sh`.
- `pretoken/`: the Cognito Pre Token Generation trigger that turns IdC group mappings into a `roles` claim, deployed by `infra/cognito-idc/15-rbac-pretoken.py`.

Gateway tool RBAC, customer version (used by Part 1 · Amazon Quick):
- `../common/lambda/mall_tools/` (shared with the Entra track): the customer's 4 mall tools as one Gateway Lambda target, deployed by `infra/cognito-idc/16-mall-gateway.sh`. `pretoken/` now also reads Cognito groups (`ROLE_SOURCES=cognito,idc`).
