#!/usr/bin/env bash
# Entra ID track, Parts 2–4 (Entra ID x AgentCore Identity): ONE MicrosoftOauth2 credential provider (rsidc-entra) for 2LO / 3LO / OBO,
# and a NEW runtime rsidc_entra_agent whose inbound auth trusts Entra (aud = rsidc-entra-agent). Nothing existing changes.
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
CP=${PROJECT}-entra; ROLE=${PROJECT}-entra-runtime-role; BUCKET=${PROJECT}-artifacts-${ACCOUNT_ID}-${R}
# 1) credential provider (client secret read from the gitignored file, never echoed)
if ! aws bedrock-agentcore-control get-oauth2-credential-provider --region $R --name $CP >/dev/null 2>&1; then
  ROOT="$ROOT" "$ROOT/.venv/bin/python" - "$CP" <<'PY'
import json, os, subprocess, sys, tempfile
sec = dict(l.strip().split("=", 1) for l in open(os.path.join(os.environ["ROOT"], "tests/.entra-agent.env")) if "=" in l)["ENTRA_AGENT_CLIENT_SECRET"]
spec = {"name": sys.argv[1], "credentialProviderVendor": "MicrosoftOauth2", "oauth2ProviderConfigInput": {"microsoftOauth2ProviderConfig": {
        "clientId": os.environ["ENTRA_AGENT_APP_ID"], "clientSecret": sec, "tenantId": os.environ["ENTRA_TENANT_ID"]}}}
fd, spec_path = tempfile.mkstemp(suffix=".json")  # mkstemp creates the file 0600; the secret never goes on argv
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(spec, f)
    subprocess.run(["aws", "bedrock-agentcore-control", "create-oauth2-credential-provider", "--region", os.environ["RT_REGION"],
                    "--cli-input-json", "file://" + spec_path], check=True, stdout=subprocess.DEVNULL)
finally:
    os.unlink(spec_path)
PY
fi
save CP_ENTRA_CALLBACK $(aws bedrock-agentcore-control get-oauth2-credential-provider --region $R --name $CP --query callbackUrl --output text)
save CP_ENTRA_SECRET_ARN $(aws bedrock-agentcore-control get-oauth2-credential-provider --region $R --name $CP --query clientSecretArn.secretArn --output text)
AGENT_REDIRECTS="$CP_ENTRA_CALLBACK" "$ROOT/.venv/bin/python" "$ROOT/infra/entra-id/03-entra-agent-setup.py" | grep redirectUris   # 3LO redirect on the Entra app
# 2) runtime role (least privilege: only this provider + its secret + its own workload identity)
aws iam get-role --role-name $ROLE >/dev/null 2>&1 || { aws iam create-role --role-name $ROLE --tags Key=Project,Value=$PROJECT --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"bedrock-agentcore.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT_ID}\"},\"ArnLike\":{\"aws:SourceArn\":\"arn:aws:bedrock-agentcore:${R}:${ACCOUNT_ID}:*\"}}}]}" >/dev/null; sleep 10; }
sed -e "s/__REGION__/$R/g" -e "s/__ACCOUNT__/$ACCOUNT_ID/g" -e "s/__BUCKET__/$BUCKET/g" -e "s|__CP_SECRET__|$CP_ENTRA_SECRET_ARN|" "$ROOT/infra/entra-id/policies/entra-runtime-permissions.json" > /tmp/$ROLE.json
aws iam put-role-policy --role-name $ROLE --policy-name entra-runtime --policy-document file:///tmp/$ROLE.json
save ENTRA_RT_ROLE_ARN arn:aws:iam::${ACCOUNT_ID}:role/$ROLE
# 3) code -> S3 -> runtime (PUBLIC network: it only talks to Entra, Graph and the gateway over HTTPS)
B="$ROOT/build-entra"; rm -rf "$B"; mkdir -p "$B/pkg"
uv pip install -q --python-platform aarch64-manylinux2014 --python-version 3.12 --only-binary=:all: --target "$B/pkg" -r "$ROOT/agents/entra-id/requirements.txt"
cp "$ROOT/agents/entra-id/main.py" "$B/pkg/"; (cd "$B/pkg" && zip -qr "$B/agent.zip" .)
KEY=agent_entra/$(date +%Y%m%d%H%M%S)/agent.zip; aws s3 cp --only-show-errors "$B/agent.zip" s3://$BUCKET/$KEY; rm -rf "$B"
python3 - "$BUCKET" "$KEY" <<'PY'
import json, os, sys
b, k = sys.argv[1:3]; e = os.environ
json.dump({
  "agentRuntimeArtifact": {"codeConfiguration": {"code": {"s3": {"bucket": b, "prefix": k}}, "runtime": "PYTHON_3_12", "entryPoint": ["main.py"]}},
  "roleArn": e["ENTRA_RT_ROLE_ARN"], "networkConfiguration": {"networkMode": "PUBLIC"},
  "authorizerConfiguration": {"customJWTAuthorizer": {"discoveryUrl": f"https://login.microsoftonline.com/{e['ENTRA_TENANT_ID']}/v2.0/.well-known/openid-configuration",
                                                      "allowedAudience": [e["ENTRA_AGENT_APP_ID"]]}},
  "requestHeaderConfiguration": {"requestHeaderAllowlist": ["Authorization"]},
  "protocolConfiguration": {"serverProtocol": "HTTP"},
  "environmentVariables": {"CP_ENTRA": "rsidc-entra", "MALL_API_APP_ID": e["ENTRA_API_APP_ID"], "ENTRA_GW_URL": e["ENTRA_GW_URL"],
                           # T-04: only these Entra client apps (token azp/appid) may call the agent; extra ids via ENTRA_EXTRA_ALLOWED_CLIENT_IDS
                           "ENTRA_ALLOWED_CLIENT_IDS": ",".join(filter(None, [e.get("ENTRA_TEST_CLIENT_ID", ""), e.get("ENTRA_EXTRA_ALLOWED_CLIENT_IDS", "")]))},
}, open("/tmp/entra-rt-spec.json", "w", encoding="utf-8"))
PY
if [ -z "${ENTRA_RT_ID:-}" ]; then
  for try in 1 2 3 4 5 6; do  # retries cover IAM propagation of the new role
    ID=$(aws bedrock-agentcore-control create-agent-runtime --region $R --agent-runtime-name ${PROJECT}_entra_agent --cli-input-json file:///tmp/entra-rt-spec.json --query agentRuntimeId --output text) && break; sleep 10; done
  save ENTRA_RT_ID $ID
else
  aws bedrock-agentcore-control update-agent-runtime --region $R --agent-runtime-id $ENTRA_RT_ID --cli-input-json file:///tmp/entra-rt-spec.json >/dev/null
fi
for i in $(seq 60); do s=$(aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $ENTRA_RT_ID --query status --output text); [[ $s == READY || $s == *FAILED ]] && break; sleep 10; done
save ENTRA_RT_ARN $(aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $ENTRA_RT_ID --query agentRuntimeArn --output text)
WI=$(aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $ENTRA_RT_ID --query workloadIdentityDetails.workloadIdentityArn --output text); save ENTRA_WI_NAME ${WI##*/}
# merge, never replace: keeps the Entra GUI's /3lo/callback (added by 14-deploy-webchat.sh)
CURU=$(aws bedrock-agentcore-control get-workload-identity --region $R --name ${WI##*/} --query 'allowedResourceOauth2ReturnUrls' --output text 2>/dev/null || true)
aws bedrock-agentcore-control update-workload-identity --region $R --name ${WI##*/} --allowed-resource-oauth2-return-urls $(echo $CURU http://localhost:8765/callback ${WEB_ENTRA_URL:+$WEB_ENTRA_URL/3lo/callback} | tr ' \t' '\n\n' | grep -v '^None$' | grep . | sort -u) >/dev/null
aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $ENTRA_RT_ID --query '{status:status,net:networkConfiguration.networkMode,auth:authorizerConfiguration,reason:failureReason}'
