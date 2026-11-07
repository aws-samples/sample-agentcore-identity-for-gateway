#!/usr/bin/env bash
# Deploy the agent to AgentCore Runtime (direct code deploy, arm64 zip) in VPC mode with:
#   - inbound auth: Cognito JWT (AgentCore Identity customJWTAuthorizer, audience = app client id)
#   - Authorization header forwarded to the agent (needed for identity propagation to Redshift)
#   - execution role from step 06 (no Redshift permissions); IdC app from step 07
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
BUCKET=${PROJECT}-artifacts-${ACCOUNT_ID}-${R}
aws s3api head-bucket --bucket $BUCKET 2>/dev/null || aws s3api create-bucket --bucket $BUCKET --region $R --create-bucket-configuration LocationConstraint=$R >/dev/null
aws s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Package: linux/arm64 wheels + agent source
B="$ROOT/build"; rm -rf "$B"; mkdir -p "$B/pkg"
uv pip install -q --python-platform aarch64-manylinux2014 --python-version 3.12 --only-binary=:all: --target "$B/pkg" -r "$ROOT/agents/cognito-idc/obo/requirements.txt"
cp "$ROOT/agents/cognito-idc/obo/main.py" "$ROOT/agents/cognito-idc/obo/redshift_tools.py" "$B/pkg/"
(cd "$B/pkg" && zip -qr "$B/agent.zip" .)
KEY=agent/$(date +%Y%m%d%H%M%S)/agent.zip
aws s3 cp --only-show-errors "$B/agent.zip" s3://$BUCKET/$KEY

python3 - "$BUCKET" "$KEY" <<'PY'
import json, os, sys, subprocess
bucket, key = sys.argv[1:3]
e = os.environ
spec = {
  "agentRuntimeArtifact": {"codeConfiguration": {"code": {"s3": {"bucket": bucket, "prefix": key}}, "runtime": "PYTHON_3_12", "entryPoint": ["main.py"]}},
  "roleArn": e["RT_ROLE_ARN"],
  "networkConfiguration": {"networkMode": "VPC", "networkModeConfig": {"subnets": [e["RT_PRIV_SUBNET_1"], e["RT_PRIV_SUBNET_2"]], "securityGroups": [e["RT_SG_ID"]]}},
  "authorizerConfiguration": {"customJWTAuthorizer": {"discoveryUrl": e["COGNITO_DISCOVERY_URL"], "allowedAudience": [e["COGNITO_CLIENT_ID"]]}},
  "requestHeaderConfiguration": {"requestHeaderAllowlist": ["Authorization"]},
  "protocolConfiguration": {"serverProtocol": "HTTP"},
  "environmentVariables": {"REDSHIFT_HOST": e["REDSHIFT_HOST"], "REDSHIFT_DB": e["REDSHIFT_DB"], "MODEL_ID": "global.anthropic.claude-sonnet-5-5",
                           "IDC_REGION": e["IDC_REGION"], "AGENT_IDC_APP_ARN": e.get("AGENT_IDC_APP_ARN", "")},
}
json.dump(spec, open("/tmp/rt-spec.json", "w"))
PY
if [ -z "${RT_ID:-}" ]; then
  save RT_ID $(aws bedrock-agentcore-control create-agent-runtime --region $R --agent-runtime-name ${PROJECT}_data_agent --cli-input-json file:///tmp/rt-spec.json --query agentRuntimeId --output text)
else
  aws bedrock-agentcore-control update-agent-runtime --region $R --agent-runtime-id $RT_ID --cli-input-json file:///tmp/rt-spec.json >/dev/null
fi
for i in $(seq 60); do s=$(aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $RT_ID --query status --output text); [[ $s == READY || $s == *FAILED ]] && break; sleep 10; done
save RT_ARN $(aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $RT_ID --query agentRuntimeArn --output text)
aws bedrock-agentcore-control get-agent-runtime --region $R --agent-runtime-id $RT_ID --query '{status:status,version:agentRuntimeVersion,net:networkConfiguration.networkMode,auth:authorizerConfiguration,headers:requestHeaderConfiguration,reason:failureReason}'
