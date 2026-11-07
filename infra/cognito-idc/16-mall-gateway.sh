#!/usr/bin/env bash
# Gateway tool RBAC (customer version): AgentCore Gateway IS the MCP server that Amazon Quick connects to.
#   inbound : Cognito JWT, allowedClients = Quick app client (rsidc-quick-mcp) + OBO client (scripted tests)
#   target  : ONE Lambda target "mall" with the customer's 4 tools (infra/common/lambda/mall_tools) -> tool names mall___<tool>
#   outbound: Gateway IAM role -> lambda:InvokeFunction. The Lambda has no URL and no resource policy, so it cannot be
#             reached around the Gateway (anti-bypass). Policy (Cedar) is attached by 16-mall-policy.sh.
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
FN=${PROJECT}-mall-tools; LR=${PROJECT}-mall-tools-role; GR=${PROJECT}-mall-gateway-role
LTRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam get-role --role-name $LR >/dev/null 2>&1 || { aws iam create-role --role-name $LR --tags Key=Project,Value=$PROJECT --assume-role-policy-document "$LTRUST" >/dev/null; sleep 10; }
sed -e "s/__REGION__/$R/g" -e "s/__ACCOUNT__/$ACCOUNT_ID/g" "$ROOT/infra/cognito-idc/policies/mall-tools-permissions.json" > /tmp/$LR.json
aws iam put-role-policy --role-name $LR --policy-name mall-tools --policy-document file:///tmp/$LR.json
(cd "$ROOT/infra/common/lambda/mall_tools" && rm -f /tmp/mall_tools.zip && zip -q /tmp/mall_tools.zip handler.py)
if aws lambda get-function --region $R --function-name $FN >/dev/null 2>&1; then
  aws lambda update-function-code --region $R --function-name $FN --zip-file fileb:///tmp/mall_tools.zip >/dev/null
else
  for try in 1 2 3 4 5 6; do
    aws lambda create-function --region $R --function-name $FN --runtime python3.12 --architectures arm64 --handler handler.handler \
      --timeout 10 --role arn:aws:iam::${ACCOUNT_ID}:role/$LR --zip-file fileb:///tmp/mall_tools.zip --tags Project=$PROJECT >/dev/null && break
    sleep 10; done
fi
aws lambda wait function-active-v2 --region $R --function-name $FN
MALL_FN=arn:aws:lambda:$R:${ACCOUNT_ID}:function:$FN

# Trust: only AgentCore, only from this account AND only for this project's gateway(s). aws:SourceArn uses a name-prefix
# wildcard because the role must exist before the gateway (gateway IDs are "<name>-<suffix>"). Re-runs re-apply the trust.
TRUST="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"bedrock-agentcore.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT_ID}\"},\"ArnLike\":{\"aws:SourceArn\":[\"arn:aws:bedrock-agentcore:${R}:${ACCOUNT_ID}:gateway/${PROJECT}-mall-gateway-*\",\"arn:aws:bedrock-agentcore:${R}:${ACCOUNT_ID}:gateway/${PROJECT}-mall-entra-gateway-*\"]}}}]}"
if aws iam get-role --role-name $GR >/dev/null 2>&1; then aws iam update-assume-role-policy --role-name $GR --policy-document "$TRUST"
else aws iam create-role --role-name $GR --tags Key=Project,Value=$PROJECT --assume-role-policy-document "$TRUST" >/dev/null; sleep 10; fi
sed -e "s/__REGION__/$R/g" -e "s/__ACCOUNT__/$ACCOUNT_ID/g" -e "s|__MALL_FN__|$MALL_FN|" "$ROOT/infra/cognito-idc/policies/mall-gateway-permissions.json" > /tmp/$GR.json
aws iam put-role-policy --role-name $GR --policy-name mall-gateway --policy-document file:///tmp/$GR.json

if [ -z "${MALL_GW_ID:-}" ]; then
  save MALL_GW_ID $(aws bedrock-agentcore-control create-gateway --region $R --name ${PROJECT}-mall-gateway --role-arn arn:aws:iam::${ACCOUNT_ID}:role/$GR \
    --protocol-type MCP --authorizer-type CUSTOM_JWT --description "rsidc Part 4: customer version (Amazon Quick -> Gateway MCP -> Lambda tools)" \
    --authorizer-configuration "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"$COGNITO_DISCOVERY_URL\",\"allowedClients\":[\"$QUICK_CLIENT_ID\",\"$COGNITO_CLIENT_ID\"]}}" \
    --query gatewayId --output text)
fi
for i in $(seq 30); do s=$(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $MALL_GW_ID --query status --output text); [ "$s" = READY ] && break; sleep 5; done
save MALL_GW_URL $(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $MALL_GW_ID --query gatewayUrl --output text)
save MALL_GW_ARN $(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $MALL_GW_ID --query gatewayArn --output text)
if ! aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $MALL_GW_ID --query "items[?name=='mall'].targetId" --output text | grep -q .; then
  CFG=$(python3 -c "import json,sys;print(json.dumps({'mcp':{'lambda':{'lambdaArn':sys.argv[1],'toolSchema':{'inlinePayload':json.load(open(sys.argv[2]))}}}}))" $MALL_FN "$ROOT/infra/common/lambda/mall_tools/tools.json")
  for try in 1 2 3 4 5 6; do  # retries cover IAM propagation of the gateway role policy
    aws bedrock-agentcore-control create-gateway-target --region $R --gateway-identifier $MALL_GW_ID --name mall \
      --description "Customer mall-footfall tools (4)" --target-configuration "$CFG" \
      --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' >/dev/null && break
    sleep 10; done
fi
for i in $(seq 30); do s=$(aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $MALL_GW_ID --query "items[?name=='mall'].status|[0]" --output text); [ "$s" = READY ] && break; sleep 5; done
aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $MALL_GW_ID --query '{id:gatewayId,status:status,url:gatewayUrl,auth:authorizerConfiguration,policy:policyEngineConfiguration}'
aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $MALL_GW_ID --query 'items[].[name,status]' --output text
echo "Lambda resource policy (expect none -> only the Gateway role can invoke it):"
aws lambda get-policy --region $R --function-name $FN 2>&1 | grep -o "ResourceNotFoundException" || true
aws lambda get-function-url-config --region $R --function-name $FN 2>&1 | grep -o "ResourceNotFoundException" || true
