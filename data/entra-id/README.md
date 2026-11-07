# data/entra-id/ — Microsoft Entra ID track

Step-by-step guide for Amazon Quick, AgentCore Gateway tool RBAC and AgentCore Identity 3LO, 2LO and OBO, with Microsoft Entra ID as the identity provider. Each page carries the architecture, a replay of the recorded results, the hop-by-hop internals, the setup steps with screenshots and an FAQ. Every page has an English and a Chinese (`.zh-CN.html`) version. The pages are static (nothing on them calls AWS or Entra): open them in a browser, for example `python3 -m http.server --bind 127.0.0.1 --directory data 8000` from the repo root, then `http://127.0.0.1:8000/entra-id/part1-quick.html`.

## Pages

| Page | Covers | Scripts it uses |
|---|---|---|
| [part1-quick.html](part1-quick.html) · [中文](part1-quick.zh-CN.html) | Part 1: Amazon Quick → Entra ID → custom domain (Amazon CloudFront) → AgentCore Gateway, per-user tool access from Entra App Roles + Cedar | `infra/entra-id/01`, `02` (+ CloudFront and DNS setup on the page) |
| [part2-3lo.html](part2-3lo.html) · [中文](part2-3lo.zh-CN.html) | Part 2: 3LO, user consent through AgentCore Identity (USER_FEDERATION), token in the Token Vault, Microsoft Graph `/me` | `infra/entra-id/03`, `04`; web GUI via `infra/cognito-idc/14` |
| [part3-2lo.html](part3-2lo.html) · [中文](part3-2lo.zh-CN.html) | Part 3: 2LO, client credentials through AgentCore Identity, app-only token to the Gateway | `infra/entra-id/02`, `03`, `04` |
| [part4-obo.html](part4-obo.html) · [中文](part4-obo.zh-CN.html) | Part 4: OBO, the user's Entra token exchanged on-behalf-of through AgentCore Identity, per-user Gateway tools | `infra/entra-id/01` to `04` |

Also here: [flow-rbac.html](flow-rbac.html) (animated per-user tool RBAC with Entra App Roles) and `img/` (architecture diagrams and Entra admin center screenshots, secrets redacted).

## Prerequisites

- **The Cognito + IAM Identity Center track deployed through step 16 first** ([`../cognito-idc/`](../cognito-idc/README.md)). `infra/cognito-idc/16-mall-gateway.sh` creates the mall Lambda `rsidc-mall-tools` and the gateway role `rsidc-mall-gateway-role` that `infra/entra-id/02-entra-gateway.sh` reuses; `04-entra-agentcore.sh` also needs the S3 artifacts bucket from Cognito step 08.
- A Microsoft Entra ID tenant, and `az login --tenant <tenant> --allow-no-subscriptions` as a Global Administrator; `ENTRA_TENANT_ID` in the shell or in `infra/state.env`.
- For Part 1: a domain verified in the Entra tenant (the Application ID URI must be on it) and a Route 53 hosted zone for it.
- Everything runs from the repo root through `infra/common/run.sh`.

## Run order

| # | Script | What it does | Pages |
|---|---|---|---|
| 1 | `infra/entra-id/01-entra-setup.py` | Entra app registrations (`rsidc-mall-api`, `rsidc-mall-test-client`), App Roles and test users; prints the IDs for `state.env` | 1 |
| 2 | `infra/entra-id/02-entra-gateway.sh LOG_ONLY\|ENFORCE` | AgentCore Gateway that trusts Entra directly, plus its Cedar policies | 1, 3, 4 |
| 3 | `infra/entra-id/03-entra-agent-setup.py` | Agent app `rsidc-entra-agent`, consent and client secret (saved to a local, gitignored file) | 2, 3, 4 |
| 4 | `infra/entra-id/04-entra-agentcore.sh` | AgentCore Identity credential provider and the Entra agent runtime (re-runs step 3 to add the provider's callback URL) | 2, 3, 4 |

The custom domain for Part 1 (ACM certificate, CloudFront distribution with the `mcp-prm` function and response headers policy, Route 53 records) is set up as described on [part1-quick.html](part1-quick.html) → Setup. The Entra web GUI is deployed with the Cognito GUIs by `infra/cognito-idc/14-deploy-webchat.sh`.

## Teardown order

Run from the repo root, in this order. Each script prints the plan, asks you to type `yes` (or takes `--yes`), and supports `--dry-run`.

```
infra/common/run.sh ./infra/common/99-teardown.sh        # Agent Registry
infra/common/run.sh ./infra/entra-id/99-teardown.sh      # this track; add --with-cloudfront --profile <p> and/or --with-entra-apps
infra/common/run.sh ./infra/cognito-idc/99-teardown.sh   # Cognito track (only if you are removing it too)
```

`--with-cloudfront --profile <p>` removes the Part 1 custom-domain stack in the account that owns the domain (set `CF_DOMAIN`); `--with-entra-apps` deletes the Entra app registrations through `az`. The Entra test users stay; remove them in the Entra admin center. Amazon Quick connectors are deleted in the Quick console.
