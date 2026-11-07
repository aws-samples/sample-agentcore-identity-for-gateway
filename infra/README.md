# infra/
Provisioning for the PoC. Run every script through `infra/common/run.sh` (it loads `common/00-config.sh` and `state.env`).

## Layout
| Folder | Contents |
|---|---|
| [`common/`](common/) | Used by both identity tracks: `00-config.sh`, `run.sh`, `agent-registry.py`, `teardown-lib.sh`, `99-teardown.sh`, `lambda/mall_tools` |
| [`cognito-idc/`](cognito-idc/) | Amazon Cognito + IAM Identity Center track: steps `01`–`16`, `17` (one-off hardening), `99-teardown.sh`, `lambda/`, `policies/`, `registry/`, `sql/`, `ops/` |
| [`entra-id/`](entra-id/) | Microsoft Entra ID track: steps `01`–`04`, `99-teardown.sh`, `policies/`, `registry/`. Needs Cognito step `16` first |

Step numbers are per track (`cognito-idc` 01–16 plus the one-off `17`, `entra-id` 01–04). `state.env` stays at `infra/state.env` (gitignored); scripts find it through `ROOT`, which `common/00-config.sh` sets to the repository root.

## Prerequisites / assumptions
- **IAM Identity Center is already enabled** in your AWS account (organization or account instance) in `IDC_REGION`. These scripts don't create or delete the IdC instance.
- **Set your IdC values** before running anything (export them, add them to `infra/state.env`, or edit the defaults in `common/00-config.sh`; the scripts stop with an error while they are still placeholders):
  - `IDC_INSTANCE_ARN`: your instance ARN, `arn:aws:sso:::instance/ssoins-<id>` (IAM Identity Center console → Settings → Instance ARN, or `aws sso-admin list-instances --region <IDC_REGION>`);
  - `IDENTITY_STORE_ID`: the matching identity store ID, `d-<id>` (same command / page);
  - `IDC_REGION` and `RT_REGION` if you use other Regions.
- **Deployment uses a named AWS CLI profile.** Set `AWS_PROFILE` in `common/00-config.sh` (default: `default`) to a profile in `~/.aws/config` with permissions to create the resources (IAM, VPC, Cognito, Redshift, AgentCore, Lambda, API Gateway). Check it with `aws sts get-caller-identity --profile <name>`.
- `ACCOUNT_ID` is looked up from that profile (`aws sts get-caller-identity`), so you don't set it.

- **IdC test users and groups already exist**: users `wei`, `zhang`, `chen`, `ds1` in the groups `risk-team`, `marketing-team`, `platform-team`, `data-scientists`. The IdC user's email must equal the email that `02-cognito.sh` gives the Cognito user (the trusted token issuer maps by email); edit the list in `02-cognito.sh` to match your IdC users.
- **Tools on the operator machine (macOS):** AWS CLI v2, [`uv`](https://docs.astral.sh/uv/), `zip`, `nc`, `curl`, `openssl`. The scripts use BSD `sed -i ''`, so on Linux change it to `sed -i`.

## Install the test environment
Run from the project root. Every step is idempotent: if one fails, fix the cause and re-run it. Resource IDs are saved to `infra/state.env`, and test-user passwords to `tests/.users.env` (both local, gitignored, created by step 02 of the Cognito track). Expected output and console checks for each step are in the interactive pages in [`../data/cognito-idc/`](../data/cognito-idc/) (index: [`../data/cognito-idc/README.md`](../data/cognito-idc/README.md)).

**0. Python venv** in the project root (used by the Python steps and the local GUIs; the agents' own dependencies are packaged separately by `08` / `12`):
```bash
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r requirements.txt
PY=.venv/bin/python
```

**1. Shared foundation + OBO** (Cognito JWT → IdC → Redshift as the user):
```bash
infra/common/run.sh ./infra/cognito-idc/01-runtime-network.sh          # VPC, NAT, fixed egress IP for the runtimes
infra/common/run.sh ./infra/cognito-idc/02-cognito.sh                  # user pool (admin-create only), OBO client, 4 users
infra/common/run.sh ./infra/cognito-idc/03-idc-redshift-app.sh         # IdC trusted token issuer + Redshift IdC application
infra/common/run.sh ./infra/cognito-idc/04-redshift-cluster.sh         # Redshift ra3.large; SG = operator IPs + runtime egress IP only (~10 min)
infra/common/run.sh $PY infra/cognito-idc/05-seed-redshift.py          # tables, grants to IdC group roles, RLS
infra/common/run.sh ./infra/cognito-idc/06-runtime-role.sh             # runtime execution role (no Redshift permissions)
infra/common/run.sh ./infra/cognito-idc/07-idc-agent-app.sh            # customer-managed IdC app for the agent token exchange
infra/common/run.sh ./infra/cognito-idc/08-deploy-runtime.sh           # agents/cognito-idc/obo/ -> AgentCore Runtime rsidc_data_agent
```
Check: the OBO runtime (`rsidc_data_agent`) is READY in the console and, invoked as each of the four users, returns only the rows that user's IdC group may see (recorded result: 16/16 checks in the matrix).

**2. 2LO and 3LO** (AgentCore Identity: client credentials, user consent + Token Vault):
```bash
infra/common/run.sh ./infra/cognito-idc/09-cognito-oauth-clients.sh    # Cognito domain, resource server, 2LO + 3LO clients
infra/common/run.sh $PY infra/cognito-idc/10-credential-providers.py   # credential providers rsidc-2lo-cognito / rsidc-3lo-cognito
infra/common/run.sh ./infra/cognito-idc/11-2lo-gateway.sh              # 2LO Gateway -> lambda/reporting -> Redshift svc_reporting
infra/common/run.sh ./infra/cognito-idc/12-deploy-oauth-runtime.sh     # agents/cognito-idc/oauth/ -> runtime rsidc_oauth_agent
```
Check: the 2LO gateway lists the reporting tools for a client-credentials token, and the 3LO flow opens a browser for user consent (recorded result: 18/18 checks).

**3. Web GUIs** (optional; API Gateway HTTP API → Lambda):
```bash
infra/common/run.sh $PY infra/cognito-idc/13-web-login-client.py       # localhost callbacks for running the GUIs locally
infra/common/run.sh bash infra/cognito-idc/14-deploy-webchat.sh        # deploy the GUIs and register their callback URLs; prints the URLs
```

**4. Gateway per-user tool RBAC** (optional; demo with IdC groups):
```bash
infra/common/run.sh ./infra/cognito-idc/15-rbac-idc-groups.sh          # creates project-owned IdC groups rsidc-gw-* only
infra/common/run.sh ./infra/cognito-idc/15-rbac-gateway.sh             # Gateway + lambda/rbac_tools targets
infra/common/run.sh $PY infra/cognito-idc/15-rbac-pretoken.py          # Cognito Pre Token trigger -> roles claim (alias "live")
infra/common/run.sh ./infra/cognito-idc/15-rbac-policy.sh              # Cedar policies, ENFORCE by default (pass LOG_ONLY to dry-run: allows every tool, only logs)
```
Check: with `ENFORCE`, a token whose `roles` claim lacks a role gets that tool filtered from `tools/list` and denied on `tools/call`.

**5. Customer version: Amazon Quick → mall gateway** (optional; RBAC from Cognito groups):
```bash
infra/common/run.sh $PY infra/cognito-idc/16-mall-cognito.py           # Cognito groups, Quick app client, resource server
infra/common/run.sh $PY infra/cognito-idc/15-rbac-pretoken.py          # re-run: adds Cognito groups as a role source
infra/common/run.sh ./infra/cognito-idc/16-mall-gateway.sh             # Gateway rsidc-mall-gateway + lambda/mall_tools
infra/common/run.sh ./infra/cognito-idc/16-mall-logs.sh                # policy decision logs (CloudWatch)
infra/common/run.sh ./infra/cognito-idc/16-mall-policy.sh ENFORCE
```
Check: with `ENFORCE`, each Cognito group sees and can call only its own mall tools (recorded result: 25/25 checks).
Then connect Amazon Quick as described in [`../data/cognito-idc/quick-mcp-connector.md`](../data/cognito-idc/quick-mcp-connector.md).

**Existing deployments: lock the `email` attribute** (run once on a pool created before this change; idempotent, creates nothing):
```bash
infra/common/run.sh $PY infra/cognito-idc/17-harden-cognito-email.py  # email not client-writable; email changes need verification
```
The IdC trusted token issuer, the Pre Token trigger's IdC lookup and the 3LO identity check all key on `email`, so users must not be able to change it. New installs get this from steps `02`, `09`, `13` and `16`: no app client lists `email` in its write attributes, and the pool sets `AttributesRequireVerificationBeforeUpdate=email` (an email change only takes effect after the new address is verified). The Pre Token trigger also skips the IdC lookup unless `email_verified` is `true`. `17` applies the same settings to an existing pool and its OBO, 2LO, 3LO and Quick clients. On a new install, also run it once after step `10`: `10-credential-providers.py` rewrites the 3LO client without its attribute lists. `UpdateUserPool` and `UpdateUserPoolClient` reset omitted settings, so the script reads the full current configuration, writes it back with only these fields changed, prints a before/after diff, and checks that admin-only user creation (`AllowAdminCreateUserOnly=true`) is still on.

**6. Agent Registry** (optional): `infra/common/run.sh $PY infra/common/agent-registry.py` (add `REGISTRY_REGION=us-east-1` for Quick in us-east-1).

## Teardown
Three scripts, one per folder. Run them in this order (later ones depend on earlier ones being gone, not the other way round):

| # | Script | Removes |
|---|---|---|
| 1 | `infra/common/99-teardown.sh` | Agent Registry records and the `rsidc-registry` registry (Tokyo and us-east-1; found by name) |
| 2 | `infra/entra-id/99-teardown.sh` | Entra gateway, targets, policy engine and Cedar policies, Entra runtime, workload identity, credential provider, runtime role, Entra GUI Lambda/API. Does not touch the Cognito-owned mall Lambda or role |
| 3 | `infra/cognito-idc/99-teardown.sh` | Steps 01–16: web GUIs, RBAC and mall gateways, Pre Token trigger, 2LO/3LO, OBO runtime, Redshift (no final snapshot), Cognito, VPC |

All three: `--dry-run` prints the plan and the commands without deleting, `--yes` skips the `yes` prompt, deletes are idempotent (not-found is skipped, other errors are reported and the exit code is non-zero), and only `rsidc`-prefixed names or IDs from `state.env` are touched.
```bash
infra/common/run.sh infra/common/99-teardown.sh --dry-run          # then without --dry-run
infra/common/run.sh infra/entra-id/99-teardown.sh --dry-run
infra/common/run.sh infra/cognito-idc/99-teardown.sh --dry-run
```
`entra-id/99-teardown.sh` also takes `--with-cloudfront --profile <p>` (the Part 1 custom-domain stack in the domain account; needs `CF_DOMAIN`) and `--with-entra-apps` (deletes the Entra app registrations through `az`). See the cost note in [`../README.md`](../README.md).

## Files
- `common/00-config.sh`: regions, IdC instance, names and operator IPs. `save` persists resource IDs to `state.env` (gitignored).
- `cognito-idc/17-harden-cognito-email.py`: one-off, idempotent hardening of an existing pool and its app clients (see above). Teardown has nothing to remove for it.
- `cognito-idc/01`–`08`: numbered, idempotent steps. Re-running one is safe. See [`../data/cognito-idc/README.md`](../data/cognito-idc/README.md) for the page index and step order.
- `*/99-teardown.sh`, `common/teardown-lib.sh`: teardown scripts and their shared helpers (see Teardown above). They never touch the pre-existing IdC instance, users or groups.
- `cognito-idc/lambda/`: code for the Lambdas these scripts deploy: `reporting` (11, 2LO Gateway target), `rbac_tools` (15), `pretoken` (15-rbac-pretoken.py, Cognito trigger). `common/lambda/mall_tools` + `tools.json` (16, also reused by the Entra gateway in `entra-id/02`).
- `cognito-idc/policies/`: IAM trust and permission documents (Entra ones are in `entra-id/policies/`). `cognito-idc/sql/`: admin seed data, grants to IdC group roles, RLS.
Conventions: tag everything `Project=rsidc`; no `0.0.0.0/0` ingress; no Redshift permissions on the runtime role.
- `15-rbac-*`, Gateway tool RBAC (demo version). Run in this order: `15-rbac-idc-groups.sh`, `15-rbac-gateway.sh`, `15-rbac-pretoken.py`, `15-rbac-policy.sh [ENFORCE|LOG_ONLY]`, `15-rbac-logs.sh`. It only *creates* project-owned IdC groups (`rsidc-gw-*`). Pre-existing IdC groups are read but never modified.
- `16-mall-*`, Gateway tool RBAC customer version, used by Part 1 (Amazon Quick → Gateway MCP → Lambda tools, RBAC from Cognito groups). Run in this order: `16-mall-cognito.py`, `15-rbac-pretoken.py` (adds the Cognito source and the `live` alias), `16-mall-gateway.sh`, `16-mall-logs.sh`, `16-mall-policy.sh [ENFORCE|LOG_ONLY]`.
