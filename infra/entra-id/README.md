# infra/entra-id/
Provisioning for the **Microsoft Entra ID** track (Parts 1–4 in `data/entra-id/`; index: [`data/entra-id/README.md`](../../data/entra-id/README.md)).

**Prerequisite: the Cognito track must be deployed through step `16` first** (`../cognito-idc/16-mall-gateway.sh`). It creates the mall Lambda `rsidc-mall-tools` and the gateway role `rsidc-mall-gateway-role` that `02-entra-gateway.sh` reuses; `04-entra-agentcore.sh` also needs the S3 artifacts bucket from Cognito step `08`. Other prerequisites: `az login --tenant <tenant> --allow-no-subscriptions` as a Global Administrator and `ENTRA_TENANT_ID` in the shell or `infra/state.env`.

Run in this order:
1. `01-entra-setup.py`: Entra app registrations (`rsidc-mall-api`, `rsidc-mall-test-client`), App Roles and test users. Prints the IDs to put into `state.env`.
2. `02-entra-gateway.sh [ENFORCE|LOG_ONLY]` (ENFORCE by default; LOG_ONLY allows every tool and only logs): Gateway that trusts Entra directly, plus its Cedar policies. Reads the IDs from step 1.
3. `03-entra-agent-setup.py`: the agent app `rsidc-entra-agent`, consent and client secret (local, gitignored `tests/.entra-agent.env`, created by this step).
4. `04-entra-agentcore.sh`: AgentCore Identity credential provider and the Entra runtime. It calls `03` again to add the provider's callback URL.
- `policies/`: IAM documents for the Entra runtime, gateway and web GUI role. `registry/`: the Agent Registry record for the Entra gateway.
Boundary: Entra-only. Reuses `../common/` (config, `lambda/mall_tools`) and the mall gateway role created by `../cognito-idc/16-mall-gateway.sh`. Secrets are written to `tests/.entra-*.env` (gitignored), never into this folder.

## Teardown
`99-teardown.sh [--dry-run] [--yes] [--with-cloudfront --profile <p>] [--with-entra-apps]`. Run it after `../common/99-teardown.sh` and before `../cognito-idc/99-teardown.sh`.
- Default: AWS resources of this account only. Gateway `ENTRA_GW_ID` with targets, policy engine `ENTRA_PE_ID` with 4 policies, runtime `ENTRA_RT_ID` (and its log groups), workload identity `ENTRA_WI_NAME`, credential provider `rsidc-entra`, role `rsidc-entra-runtime-role`, the `entra-gateway` inline policy on the Cognito-owned gateway role, the Entra web GUI Lambda and HTTP API, and the `agent_entra/` prefix in the artifacts bucket. The mall Lambda, `rsidc-mall-gateway-role` and the bucket stay.
- `--with-cloudfront --profile <p>`: the Part 1 custom-domain stack, which lives in the account that owns the domain (CloudFront distribution, function `mcp-prm`, response headers policy, ACM certificate in us-east-1, Route 53 alias and validation records). Set `CF_DOMAIN` (for example `mcp.agentzone.click`). The distribution is only deleted if its alias is `CF_DOMAIN` and its origin is the Entra gateway.
- `--with-entra-apps`: deletes the Entra app registrations through `az` (tenant admin). The test users `wei`, `ds1`, `chen` stay.
