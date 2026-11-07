# data/cognito-idc/ — Amazon Cognito + IAM Identity Center track

Step-by-step guide for AgentCore Identity 2LO, 3LO and OBO, and AgentCore Gateway tool RBAC, with Amazon Cognito as the identity provider and IAM Identity Center for identity propagation to Amazon Redshift. Every page has an English and a Chinese (`.zh-CN.html`) version. Each page carries the commands, the recorded results, the verification checks, the findings and the teardown for its part. The pages are static (nothing on them calls AWS): open them in a browser, for example `python3 -m http.server --bind 127.0.0.1 --directory data 8000` from the repo root, then `http://127.0.0.1:8000/cognito-idc/foundation.html`.

## Pages

| Page | Covers | Scripts it uses |
|---|---|---|
| [foundation.html](foundation.html) · [中文](foundation.zh-CN.html) | Start here. Overview of the four scenarios, prerequisites, Step 1 (runtime VPC with one egress IP), Step 2 (Cognito pool and users), admin-only user creation, Step 14 (web GUIs on API Gateway + Lambda), Agent Registry, cost, full teardown | `infra/cognito-idc/01`, `02`, `14`; `infra/common/agent-registry.py`; the three `99-teardown.sh` |
| [part1-quick.html](part1-quick.html) · [中文](part1-quick.zh-CN.html) | Part 1: Amazon Quick as the 3LO client of the customer ("mall") Gateway, per-user Cedar by Cognito groups, replay, troubleshooting | `infra/cognito-idc/16-mall-*`, `15-rbac-pretoken.py` |
| [part2-3lo.html](part2-3lo.html) · [中文](part2-3lo.zh-CN.html) | Part 2: 3LO (user consent, Token Vault, session binding), web GUI panel, comparison with OBO | `infra/cognito-idc/09`, `10`, `12`, `13` |
| [part3-2lo.html](part3-2lo.html) · [中文](part3-2lo.zh-CN.html) | Part 3: 2LO (client credentials), Gateway → Lambda → Redshift service user, shared OAuth runtime | `infra/cognito-idc/09` to `13` |
| [part4-obo.html](part4-obo.html) · [中文](part4-obo.zh-CN.html) | Part 4: OBO (Cognito JWT → IAM Identity Center token → Redshift as the user): trusted token issuer, Redshift cluster, seed data, runtime role, IdC agent app, runtime, access-control matrix, negative tests | `infra/cognito-idc/03` to `08` |
| [gateway-rbac.html](gateway-rbac.html) · [中文](gateway-rbac.zh-CN.html) | Gateway tool RBAC: IdC groups → Cognito `roles` claim → Cedar on AgentCore Gateway (Steps 15.0–15.5), RBAC web GUI, findings | `infra/cognito-idc/15-rbac-*` |

Also here: [playground.html](playground.html) (replay of all web GUIs), [flow.html](flow.html) (animated OBO / 2LO / 3LO token flows), [flow-rbac.html](flow-rbac.html) (animated Gateway RBAC), [quick-mcp-connector.md](quick-mcp-connector.md) (Amazon Quick connector settings), `img/` (architecture diagrams and console screenshots).

## Prerequisites

- AWS CLI v2, `uv`, Python 3.12, `nc` and `zip`; an AWS profile with admin rights in the target account.
- An existing IAM Identity Center instance (ap-east-1 here) with the test users wei, zhang, chen and ds1 in the groups risk-team, marketing-team, platform-team and data-scientists.
- The tooling virtual environment in the repo root (see [Install](../../README.md#install)).
- Everything runs from the repo root through `infra/common/run.sh`, which loads `infra/common/00-config.sh` (Regions, project prefix) and the local, gitignored state file `infra/state.env` that the scripts create.
- Details and costs: [foundation.html](foundation.html) → Overview and Cost.

## Step order across pages

| # | What | Scripts | Page |
|---|---|---|---|
| 1 | Foundation: prerequisites, Steps 1–2 | `infra/cognito-idc/01`, `02` | [foundation.html](foundation.html) · [中文](foundation.zh-CN.html) |
| 2 | Part 4 · OBO: Steps 3–10 | `infra/cognito-idc/03` to `08` | [part4-obo.html](part4-obo.html) · [中文](part4-obo.zh-CN.html) |
| 3 | Part 3 · 2LO: Steps 9–13 | `infra/cognito-idc/09` to `13` | [part3-2lo.html](part3-2lo.html) · [中文](part3-2lo.zh-CN.html) |
| 4 | Part 2 · 3LO | `infra/cognito-idc/09`, `10`, `12`, `13` | [part2-3lo.html](part2-3lo.html) · [中文](part2-3lo.zh-CN.html) |
| 5 | Foundation: Step 14 web GUIs | `infra/cognito-idc/14` | [foundation.html](foundation.html) · [中文](foundation.zh-CN.html) |
| 6 | Gateway RBAC: Step 15 | `infra/cognito-idc/15-rbac-*` | [gateway-rbac.html](gateway-rbac.html) · [中文](gateway-rbac.zh-CN.html) |
| 7 | Part 1 · Quick: Step 16 (mall gateway) + Quick console | `infra/cognito-idc/16-mall-*` | [part1-quick.html](part1-quick.html) · [中文](part1-quick.zh-CN.html) |
| 8 | Agent Registry (optional) | `infra/common/agent-registry.py` | [foundation.html](foundation.html) · [中文](foundation.zh-CN.html) |

The Microsoft Entra ID track ([`../entra-id/`](../entra-id/README.md)) reuses resources from step 7 (`16-mall-*`), so deploy this track through step 16 first.

## Teardown order

Run from the repo root, in this order. Each script prints the plan, asks you to type `yes` (or takes `--yes`), and supports `--dry-run`. `infra/cognito-idc/99-teardown.sh` covers steps 01–16 and deletes the Redshift cluster without a final snapshot.

```
infra/common/run.sh ./infra/common/99-teardown.sh        # Agent Registry
infra/common/run.sh ./infra/entra-id/99-teardown.sh      # Entra ID track (skip if never deployed)
infra/common/run.sh ./infra/cognito-idc/99-teardown.sh   # steps 01-16
```

Amazon Quick connectors are deleted in the Quick console (see [part1-quick.html](part1-quick.html) → Setup → Teardown).
