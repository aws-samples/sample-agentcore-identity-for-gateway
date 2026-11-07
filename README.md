# agentcore-identity-for-gateway

Validates that an **AgentCore Runtime** data agent querying/updating **Amazon Redshift** respects
**IAM Identity Center** access control end to end, via trusted identity propagation, with network access to Redshift restricted to the operator IP and the runtime egress IP.

## Repository layout
Two identity-provider **tracks** share one layout: every code folder has a `cognito-idc/` subfolder (Amazon Cognito + IAM Identity Center), an `entra-id/` subfolder (Microsoft Entra ID) and, where both tracks use the same code, a `common/` subfolder.

```
.
├── README.md            this file
├── requirements.txt     Python tooling for the operator machine (root .venv)
├── data/                interactive guides (static HTML, open in a browser), diagrams, screenshots
│   ├── cognito-idc/     README.md (track index) + foundation, Parts 1–4, Gateway tool RBAC; English and 中文
│   └── entra-id/        README.md (track index) + Parts 1–4, English and 中文
├── infra/               numbered, idempotent provisioning scripts (AWS CLI / Python), IAM policies, Lambda code
│   ├── common/          00-config.sh, run.sh, agent-registry.py, teardown-lib.sh, shared mall_tools Lambda
│   ├── cognito-idc/     01 … 16 and 99-teardown.sh
│   └── entra-id/        01 … 04 and 99-teardown.sh (needs Cognito step 16 first)
├── agents/              AgentCore Runtime agent sources
│   ├── cognito-idc/     obo/ (OBO data agent → Redshift), oauth/ (2LO / 3LO agent)
│   └── entra-id/        Entra agent (2LO / 3LO / OBO)
└── webchat/             browser GUIs: run locally or deploy behind API Gateway → Lambda
    ├── common/          lambda_adapter.py, invoke.py (AgentCore Runtime client)
    ├── cognito-idc/     obo_app.py, oauth_app.py, rbac_app.py
    └── entra-id/        entra_app.py
```

Every folder has its own `README.md` with its purpose and conventions. Each `infra/` track folder has a `99-teardown.sh`; run them in the order common → entra-id → cognito-idc.

## Choose your identity provider
Both tracks cover the same four parts: Part 1 · Amazon Quick → Gateway, Part 2 · 3LO, Part 3 · 2LO, Part 4 · OBO, plus per-user Gateway tool RBAC.

| | Amazon Cognito + IAM Identity Center | Microsoft Entra ID |
|---|---|---|
| Start here (index) | [`data/cognito-idc/README.md`](data/cognito-idc/README.md): pages, step order, prerequisites, teardown | [`data/entra-id/README.md`](data/entra-id/README.md): pages, run order, prerequisites, teardown |
| Interactive pages | [Foundation](data/cognito-idc/foundation.html) ([中文](data/cognito-idc/foundation.zh-CN.html)) · [Part 1 · Quick](data/cognito-idc/part1-quick.html) ([中文](data/cognito-idc/part1-quick.zh-CN.html)) · [Part 2 · 3LO](data/cognito-idc/part2-3lo.html) ([中文](data/cognito-idc/part2-3lo.zh-CN.html)) · [Part 3 · 2LO](data/cognito-idc/part3-2lo.html) ([中文](data/cognito-idc/part3-2lo.zh-CN.html)) · [Part 4 · OBO](data/cognito-idc/part4-obo.html) ([中文](data/cognito-idc/part4-obo.zh-CN.html)) · [Gateway tool RBAC](data/cognito-idc/gateway-rbac.html) ([中文](data/cognito-idc/gateway-rbac.zh-CN.html)) | [Part 1 · Quick](data/entra-id/part1-quick.html) ([中文](data/entra-id/part1-quick.zh-CN.html)) · [Part 2 · 3LO](data/entra-id/part2-3lo.html) ([中文](data/entra-id/part2-3lo.zh-CN.html)) · [Part 3 · 2LO](data/entra-id/part3-2lo.html) ([中文](data/entra-id/part3-2lo.zh-CN.html)) · [Part 4 · OBO](data/entra-id/part4-obo.html) ([中文](data/entra-id/part4-obo.zh-CN.html)) |
| Animated flows | [Token flows](data/cognito-idc/flow.html) · [Tool RBAC flow](data/cognito-idc/flow-rbac.html) · [Playground](data/cognito-idc/playground.html) | [Tool RBAC flow](data/entra-id/flow-rbac.html) |
| Infra scripts | [`infra/cognito-idc/`](infra/cognito-idc/): `01` … `16`, `99-teardown.sh` | [`infra/entra-id/`](infra/entra-id/): `01` … `04`, `99-teardown.sh` |
| Agents | [`agents/cognito-idc/`](agents/cognito-idc/): `obo/` (OBO), `oauth/` (2LO / 3LO) | [`agents/entra-id/`](agents/entra-id/): one agent for 2LO / 3LO / OBO |
| Web GUI | [`webchat/cognito-idc/`](webchat/cognito-idc/): `obo_app.py`, `oauth_app.py`, `rbac_app.py` | [`webchat/entra-id/`](webchat/entra-id/): `entra_app.py` |

**Shared by both (`common/` folders):** [`infra/common/`](infra/common/) (config, `run.sh`, Agent Registry, the mall Gateway Lambda `lambda/mall_tools`) and [`webchat/common/`](webchat/common/) (Lambda adapter, AgentCore Runtime client). The Entra gateway reuses the mall Lambda and gateway role created by the Cognito track's step 16, so deploy the Cognito track through step 16 first.

## Install
Prerequisites (an existing IAM Identity Center instance, an AWS CLI profile, tools) and the step-by-step install of the whole test environment are in **[`infra/README.md`](infra/README.md)**. Read the cost note below first.

## Generative AI in this sample
This sample introduces Amazon Bedrock AgentCore capabilities as offered in overseas AWS Regions. Only one component uses a generative AI model: the Part 4 OBO data agent ([`agents/cognito-idc/obo/`](agents/cognito-idc/obo/)) calls a model on Amazon Bedrock through Strands Agents, from AgentCore Runtime in ap-southeast-1 (Singapore). The model is set by `MODEL_ID` (default: an Anthropic Claude cross-Region inference profile); choose a model that is available to you in your Region. All other agents and the Gateway tools are deterministic code.
- The agent sends the user's question and the Redshift query results (synthetic sample data) to the model. It runs the SQL the model chooses, limited only by the signed-in user's Redshift grants.
- Model output can be inaccurate. Review it before you rely on it, and consider [Amazon Bedrock Guardrails](https://aws.amazon.com/bedrock/guardrails/) for production use. See the [AWS Responsible AI Policy](https://aws.amazon.com/machine-learning/responsible-ai/policy/).

## ⚠️ Cost and disclaimer
- **This deploys billable AWS resources** in your account: a Redshift cluster, NAT gateways, AgentCore Runtime / Gateway / Identity, Lambda, API Gateway, Cognito and CloudWatch Logs. Redshift and the NAT gateways are billed **for every hour they exist, even when idle**; the rest is billed per request. This repo doesn't quote prices: check the [AWS Pricing Calculator](https://calculator.aws/) for your Region and usage, and see "Cost" in [`data/cognito-idc/foundation.html`](data/cognito-idc/foundation.html) for how each resource is billed.
- **Tear down when you're done** to stop charges: run the three teardown scripts in this order: `infra/common/99-teardown.sh`, `infra/entra-id/99-teardown.sh`, `infra/cognito-idc/99-teardown.sh` (steps 01–16; add `--dry-run` first, details in [`infra/README.md`](infra/README.md#teardown)). Then check the Billing console and Cost Explorer for anything left over. The teardown deletes Redshift **without a final snapshot**.
- **Disclaimer:** this is sample code for learning and testing, not production-ready. You're responsible for any cost it incurs, and for the security and compliance of anything you deploy with it. Review the scripts before you run them, and use a non-production account. This sample is provided "as is", without warranty of any kind. This is sample code, for non-production usage. You should work with your security and legal teams to meet your organizational security, regulatory and compliance requirements before deployment.


## 2LO vs 3LO vs OBO

| Aspect | 2-Legged OAuth | 3-Legged OAuth | On-Behalf-Of (OBO) |
|---|---|---|---|
| Parties involved | 2 (App + Service) | 3 (User + App + Service) | 3+ (User → App → Service chain) |
| User consent required | ❌ No | ✅ Yes (explicit grant) | ✅ Yes (initial, then flows down) |
| User involved | ❌ No | ✅ Yes (actively grants permission) | ✅ Yes (but indirectly) |
| Authentication flow | Server-to-server only | User → redirect → login → consent | User token → App token → Service token |
| Use case | Automated/scheduled tasks, webhooks, service integrations | User login ("Sign in with Google"), app accessing user data | App accessing downstream services on behalf of the user |
| Token exchange | App signs request with own credentials | Authorization code → Access token | User's access token → new token with different scopes/permissions |
| Identity preserved | App's identity only | User's identity | User's identity (passed through the chain) |
| Common in | OAuth 1.0 (legacy), some enterprise APIs | OAuth 2.0 (modern standard) | OAuth 2.0, Microsoft/Azure, AWS Bedrock agents |
| Example | Cron job calling API nightly | "Login with GitHub" in your app | Agent calling AWS Lambda on behalf of the logged-in user |
| Security model | Credentials shared between services | User never shares credentials; app gets limited token | User delegates, identity chain validated at each step |
| Revocation | Service-level (remove API key) | User can revoke anytime in account settings | User revokes original grant; cascades down |

How each one maps to this repo:

| | 2LO | 3LO | OBO |
|---|---|---|---|
| Agent | `agents/cognito-idc/oauth/` (`mode=2lo`) | `agents/cognito-idc/oauth/` (`mode=3lo`) | `agents/cognito-idc/obo/` |
| Token mechanism | `GetResourceOauth2Token(M2M)` → Cognito `client_credentials` | `GetResourceOauth2Token(USER_FEDERATION)` → consent → Token Vault | Cognito JWT → IdC `CreateTokenWithIAM` (trusted token issuer) |
| Identity seen by Redshift | `svc_reporting` (same rows for every user) | n/a (calls Cognito `userInfo` as the user) | `AWSIDC:<user>` (row-level security, grants per IdC group) |

## Security, contributing and license
- See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information, including how to report a security issue.
- This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
- Third-party content and attributions: [THIRD_PARTY.md](THIRD_PARTY.md). Code of conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
