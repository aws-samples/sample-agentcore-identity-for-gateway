#!/usr/bin/env bash
# Separate AgentCore Runtime for the 2LO/3LO tests (the OBO runtime from step 8 is not touched).
# Same inbound auth (Cognito JWT) and VPC; its own execution role (no Redshift, no IdC, no Bedrock model access).
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
BUCKET=${PROJECT}-artifacts-${ACCOUNT_ID}-${R}; ROLE=${PROJECT}-oauth-runtime-role; RETURN_URLS="http://localhost:8765/callback http://localhost:8081/3lo/callback"   # tests + 2LO/3LO web GUI
aws iam get-role --role-name $ROLE >/dev/null 2>&1 || { aws iam create-role --role-name $ROLE --tags Key=Project,Value=$PROJECT --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"bedrock-agentcore.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT_ID}\"},\"ArnLike\":{\"aws:SourceArn\":\"arn:aws:bedrock-agentcore:${R}:${ACCOUNT_ID}:*\"}}}]}" >/dev/null; sleep 10; }
sed -e "s/__REGION__/$R/g" -e "s/__ACCOUNT__/$ACCOUNT_ID/g" -e "s/__BUCKET__/$BUCKET/g" -e "s|__CP2LO_SECRET__|$CP2LO_SECRET_ARN|" -e "s|__CP3LO_SECRET__|$CP3LO_SECRET_ARN|" \
  "$ROOT/infra/cognito-idc/policies/oauth-runtime-permissions.json" > /tmp/$ROLE.json
aws iam put-role-policy --role-name $ROLE --policy-name oauth-runtime --policy-document file:///tmp/$ROLE.json
save OAUTH_RT_ROLE_ARN arn:aws:iam::${ACCOUNT_ID}:role/$ROLE

B="$ROOT/build-oauth"; rm -rf "$B"; mkdir -p "$B/pkg"
uv pip install -q --python-platform aarch64-manylinux2014 --python-version 3.12 --only-binary=:all: --target "$B/pkg" -r "$ROOT/agents/cognito-idc/oauth/requirements.txt"
cp "$ROOT/agents/cognito-idc/oauth/main.py" "$B/pkg/"; (cd "$B/pkg" && zip -qr "$B/agent.zip" .)
KEY=agent_oauth/$(date +%Y%m%d%H%M%S)/agent.zip; aws s3 cp --only-show-errors "$B/agent.zip" s3://$BUCKET/$KEY; rm -rf "$B"

python3 - "$BUCKET" "$KEY" <<'PY'
import json, os, sys
b, k = sys.argv[1:3]; e = os.environ
json.dump({
  "agentRuntimeArtifact": {"codeConfiguration": {"code": {"s3": {"bucket": b, "prefix": k}}, "runtime": "PYTHON_3_12", "entryPoint": ["main.py"]}},
  "roleArn": e["OAUTH_RT_ROLE_ARN"],
  "networkConfiguration": {"networkMode": "VPC", "networkModeConfig": {"subnets": [e["RT_PRIV_SUBNET_1"], e["RT_PRIV_SUBNET_2"]], "securityGroups": [e["RT_SG_ID"]]}},
  "authorizerConfiguration": {"customJWTAuthorizer": {"discoveryUrl": e["COGNITO_DISCOVERY_URL"], "allowedAudience": [e["COGNITO_CLIENT_ID"]]}},
  "requestHeaderConfiguration": {"requestHeaderAllowlist": ["Authorization"]},
  "protocolConfiguration": {"serverProtocol": "HTTP"},
  "environmentVariables": {"CP_2LO": "rsidc-2lo-cognito", "CP_3LO": "rsidc-3lo-cognito", "GW_URL": e["GW_URL"], "COGNITO_DOMAIN": e["COGNITO_DOMAIN"]},
}, open("/tmp/oauth-rt-spec.json", "w"))
PY
if [ -z "${OAUTH_RT_ID:-}" ]; then
  save OAUTH_RT_ID $(aws bedrock-agentcore-control create-agent-runtime --region $R --agent-runtime-name ${PROJECT}_oauth_agent --cli-input-json file:///tmp/oauth-rt-spec.json --query agentRuntimeId --output text)
else
  aws bedrock-agentcore-control update-agent-runtime --region $R --agent-runtime-id $OAUTH_RT_ID --cli-input-json file:///tmp/oauth-rt-spec.json >/dev/null
fi
for i in $(seq 60); do s=$(aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $OAUTH_RT_ID --query status --output text); [[ $s == READY || $s == *FAILED ]] && break; sleep 10; done
save OAUTH_RT_ARN $(aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $OAUTH_RT_ID --query agentRuntimeArn --output text)
WI=$(aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $OAUTH_RT_ID --query workloadIdentityDetails.workloadIdentityArn --output text)
save OAUTH_WI_NAME ${WI##*/}
# 3LO session binding: AgentCore Identity only redirects the user back to allowlisted return URLs.
aws bedrock-agentcore-control update-workload-identity --region $R --name ${WI##*/} --allowed-resource-oauth2-return-urls $RETURN_URLS >/dev/null
aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $OAUTH_RT_ID --query '{status:status,version:agentRuntimeVersion,net:networkConfiguration.networkMode,reason:failureReason,wi:workloadIdentityDetails.workloadIdentityArn}'
aws bedrock-agentcore-control get-workload-identity --region $R --name ${WI##*/} --query '{name:name,returnUrls:allowedResourceOauth2ReturnUrls}'
