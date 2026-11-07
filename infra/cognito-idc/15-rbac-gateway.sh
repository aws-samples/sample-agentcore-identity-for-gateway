#!/usr/bin/env bash
# Gateway tool RBAC (demo version): two Lambda tools behind a NEW gateway that accepts the END USER's Cognito access token
# (allowedClients = OBO client). The 2LO gateway from step 11 is untouched. Policy is attached by 15-rbac-policy.sh.
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
LR=${PROJECT}-reporting-lambda-role   # reuse step 11's role: Data API as svc_reporting only
(cd "$ROOT/infra/cognito-idc/lambda/rbac_tools" && rm -f /tmp/rbac_tools.zip && zip -q /tmp/rbac_tools.zip handler.py)
for t in sales crm; do
  FN=${PROJECT}-tool-$t
  if aws lambda get-function --region $R --function-name $FN >/dev/null 2>&1; then
    aws lambda update-function-code --region $R --function-name $FN --zip-file fileb:///tmp/rbac_tools.zip >/dev/null
  else
    aws lambda create-function --region $R --function-name $FN --runtime python3.12 --handler handler.handler --timeout 30 \
      --role arn:aws:iam::${ACCOUNT_ID}:role/$LR --zip-file fileb:///tmp/rbac_tools.zip --tags Project=$PROJECT \
      --environment "Variables={TOOL=$t,REDSHIFT_REGION=$IDC_REGION,REDSHIFT_CLUSTER_ID=$REDSHIFT_CLUSTER_ID,REDSHIFT_DB=$REDSHIFT_DB}" >/dev/null
  fi
  aws lambda wait function-active-v2 --region $R --function-name $FN
done
SALES_ARN=arn:aws:lambda:$R:${ACCOUNT_ID}:function:${PROJECT}-tool-sales; CRM_ARN=arn:aws:lambda:$R:${ACCOUNT_ID}:function:${PROJECT}-tool-crm

GR=${PROJECT}-rbac-gateway-role
# Trust: only AgentCore, only from this account AND only for this project's gateway(s). aws:SourceArn uses a name-prefix
# wildcard because the role must exist before the gateway (gateway IDs are "<name>-<suffix>"). Re-runs re-apply the trust.
TRUST="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"bedrock-agentcore.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT_ID}\"},\"ArnLike\":{\"aws:SourceArn\":\"arn:aws:bedrock-agentcore:${R}:${ACCOUNT_ID}:gateway/${PROJECT}-rbac-gateway-*\"}}}]}"
if aws iam get-role --role-name $GR >/dev/null 2>&1; then aws iam update-assume-role-policy --role-name $GR --policy-document "$TRUST"
else aws iam create-role --role-name $GR --tags Key=Project,Value=$PROJECT --assume-role-policy-document "$TRUST" >/dev/null; sleep 10; fi
sed -e "s/__REGION__/$R/g" -e "s/__ACCOUNT__/$ACCOUNT_ID/g" -e "s|__SALES__|$SALES_ARN|" -e "s|__CRM__|$CRM_ARN|" \
  "$ROOT/infra/cognito-idc/policies/rbac-gateway-permissions.json" > /tmp/$GR.json
aws iam put-role-policy --role-name $GR --policy-name rbac-gateway --policy-document file:///tmp/$GR.json

if [ -z "${RBAC_GW_ID:-}" ]; then
  save RBAC_GW_ID $(aws bedrock-agentcore-control create-gateway --region $R --name ${PROJECT}-rbac-gateway --role-arn arn:aws:iam::${ACCOUNT_ID}:role/$GR \
    --protocol-type MCP --authorizer-type CUSTOM_JWT \
    --authorizer-configuration "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"$COGNITO_DISCOVERY_URL\",\"allowedClients\":[\"$COGNITO_CLIENT_ID\"]}}" \
    --query gatewayId --output text)
fi
for i in $(seq 30); do s=$(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $RBAC_GW_ID --query status --output text); [ "$s" = READY ] && break; sleep 5; done
save RBAC_GW_URL $(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $RBAC_GW_ID --query gatewayUrl --output text)
save RBAC_GW_ARN $(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $RBAC_GW_ID --query gatewayArn --output text)
target() {  # $1 target name, $2 lambda arn, $3 tool name, $4 description
  aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $RBAC_GW_ID --query "items[?name=='$1'].targetId" --output text | grep -q . && return
  for try in 1 2 3 4 5 6; do  # retries cover IAM propagation of the role policy just written
  aws bedrock-agentcore-control create-gateway-target --region $R --gateway-identifier $RBAC_GW_ID --name $1 \
    --target-configuration "{\"mcp\":{\"lambda\":{\"lambdaArn\":\"$2\",\"toolSchema\":{\"inlinePayload\":[{\"name\":\"$3\",\"description\":\"$4\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]}}}}" \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' >/dev/null && return
  sleep 10; done; return 1
}
target sales $SALES_ARN get_sales_summary "Tool A: sales totals per region (no PII)"
target crm $CRM_ARN get_customer_contacts "Tool B: customer contact emails per order (PII)"
for i in $(seq 30); do n=$(aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $RBAC_GW_ID --query "length(items[?status=='READY'])" --output text); [ "$n" = 2 ] && break; sleep 5; done
# Test-only workload identity (not linked to a runtime) so a test client can obtain a 2LO M2M token through
# AgentCore Identity without reading the client secret. Used only to prove the RBAC gateway rejects M2M tokens.
aws bedrock-agentcore-control get-workload-identity --region $R --name ${PROJECT}-rbac-test-client >/dev/null 2>&1 || \
  aws bedrock-agentcore-control create-workload-identity --region $R --name ${PROJECT}-rbac-test-client --tags Project=$PROJECT >/dev/null
save RBAC_TEST_WI ${PROJECT}-rbac-test-client
aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $RBAC_GW_ID --query '{id:gatewayId,status:status,url:gatewayUrl,auth:authorizerConfiguration,policy:policyEngineConfiguration}'
aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $RBAC_GW_ID --query 'items[].[name,status]' --output text
