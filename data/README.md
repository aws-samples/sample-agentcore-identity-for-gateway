# data/
Published pages, diagrams and screenshots, split by identity provider. Open the `.html` files in a browser (they are static and call nothing); GitHub shows them as source.

## `cognito-idc/` — Amazon Cognito + IAM Identity Center (index: [`cognito-idc/README.md`](cognito-idc/README.md))
- `foundation.html`: overview, prerequisites, Steps 1–2 (VPC, Cognito), Step 14 (web GUIs), Agent Registry, cost and teardown.
- `part1-quick.html`: Part 1, Amazon Quick → mall Gateway (3LO by Quick, per-user Cedar by Cognito groups).
- `part2-3lo.html`, `part3-2lo.html`, `part4-obo.html`: Part 2 · 3LO, Part 3 · 2LO, Part 4 · OBO (setup, recorded results, replay, findings).
- `gateway-rbac.html`: Gateway tool RBAC (IdC groups → Cognito roles claim → Cedar), Steps 15.0–15.5.
- `playground.html`: interactive replay of the web GUIs (Quick, 3LO, 2LO, OBO, Gateway tool RBAC) with recorded results and hop-by-hop internals.
- `flow.html`: animated OBO / 2LO / 3LO token flows. `flow-rbac.html`: animated per-user tool RBAC (IAM Identity Center groups; Amazon Quick + Cognito groups).
- `quick-mcp-connector.md`: how to connect Amazon Quick to the mall gateway.
- `img/`: architecture diagrams (`architecture*.svg`) and AWS console screenshots (`console/`).

## `entra-id/` — Microsoft Entra ID (index: [`entra-id/README.md`](entra-id/README.md))
- `part1-quick.html`: Amazon Quick → Entra ID → custom domain (CloudFront) → AgentCore Gateway.
- `part2-3lo.html`, `part3-2lo.html`, `part4-obo.html`: 3LO, 2LO and OBO through AgentCore Identity with Entra ID.
- `flow-rbac.html`: animated per-user tool RBAC with Entra App Roles.
- `img/`: architecture diagrams and Entra admin center screenshots (secrets redacted).
