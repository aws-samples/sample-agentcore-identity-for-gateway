#!/usr/bin/env bash
# 2LO downstream: AgentCore Gateway (MCP, inbound JWT = 2LO client's M2M token only) -> Lambda -> Redshift as svc_reporting.
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
"$ROOT/.venv/bin/python" "$ROOT/infra/cognito-idc/05-seed-redshift.py" 02-svc-reporting.sql

# Lambda role: Data API as svc_reporting only
LR=${PROJECT}-reporting-lambda-role
aws iam get-role --role-name $LR >/dev/null 2>&1 || { aws iam create-role --role-name $LR --tags Key=Project,Value=$PROJECT \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null; sleep 10; }
aws iam put-role-policy --role-name $LR --policy-name reporting --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
 {\"Effect\":\"Allow\",\"Action\":\"redshift:GetClusterCredentials\",\"Resource\":[\"arn:aws:redshift:${IDC_REGION}:${ACCOUNT_ID}:dbuser:${REDSHIFT_CLUSTER_ID}/svc_reporting\",\"arn:aws:redshift:${IDC_REGION}:${ACCOUNT_ID}:dbname:${REDSHIFT_CLUSTER_ID}/${REDSHIFT_DB}\"]},
 {\"Effect\":\"Allow\",\"Action\":\"redshift-data:ExecuteStatement\",\"Resource\":\"arn:aws:redshift:${IDC_REGION}:${ACCOUNT_ID}:cluster:${REDSHIFT_CLUSTER_ID}\"},
 {\"Effect\":\"Allow\",\"Action\":[\"redshift-data:DescribeStatement\",\"redshift-data:GetStatementResult\"],\"Resource\":\"*\"},
 {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${R}:${ACCOUNT_ID}:*\"}]}"
(cd "$ROOT/infra/cognito-idc/lambda/reporting" && rm -f /tmp/reporting.zip && zip -q /tmp/reporting.zip handler.py)
FN=${PROJECT}-reporting
if aws lambda get-function --region $R --function-name $FN >/dev/null 2>&1; then
  aws lambda update-function-code --region $R --function-name $FN --zip-file fileb:///tmp/reporting.zip >/dev/null
else
  aws lambda create-function --region $R --function-name $FN --runtime python3.12 --handler handler.handler --timeout 30 \
    --role arn:aws:iam::${ACCOUNT_ID}:role/$LR --zip-file fileb:///tmp/reporting.zip --tags Project=$PROJECT \
    --environment "Variables={REDSHIFT_REGION=$IDC_REGION,REDSHIFT_CLUSTER_ID=$REDSHIFT_CLUSTER_ID,REDSHIFT_DB=$REDSHIFT_DB}" >/dev/null
fi
aws lambda wait function-active-v2 --region $R --function-name $FN
save REPORTING_LAMBDA_ARN $(aws lambda get-function --region $R --function-name $FN --query Configuration.FunctionArn --output text)

# Gateway role: invoke this one Lambda
GR=${PROJECT}-gateway-role
# Trust: only AgentCore, only from this account AND only for this project's gateway(s). aws:SourceArn uses a name-prefix
# wildcard because the role must exist before the gateway (gateway IDs are "<name>-<suffix>"). Re-runs re-apply the trust.
TRUST="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"bedrock-agentcore.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT_ID}\"},\"ArnLike\":{\"aws:SourceArn\":\"arn:aws:bedrock-agentcore:${R}:${ACCOUNT_ID}:gateway/${PROJECT}-2lo-gateway-*\"}}}]}"
if aws iam get-role --role-name $GR >/dev/null 2>&1; then aws iam update-assume-role-policy --role-name $GR --policy-document "$TRUST"
else aws iam create-role --role-name $GR --tags Key=Project,Value=$PROJECT --assume-role-policy-document "$TRUST" >/dev/null; sleep 10; fi
aws iam put-role-policy --role-name $GR --policy-name invoke-reporting --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"$REPORTING_LAMBDA_ARN\"}]}"
sleep 10   # IAM eventual consistency: CreateGatewayTarget validates this policy immediately

if [ -z "${GW_ID:-}" ]; then
  save GW_ID $(aws bedrock-agentcore-control create-gateway --region $R --name ${PROJECT}-2lo-gateway --role-arn arn:aws:iam::${ACCOUNT_ID}:role/$GR \
    --protocol-type MCP --authorizer-type CUSTOM_JWT \
    --authorizer-configuration "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"$COGNITO_DISCOVERY_URL\",\"allowedClients\":[\"$C2LO_CLIENT_ID\"]}}" \
    --query gatewayId --output text)
fi
for i in $(seq 30); do s=$(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $GW_ID --query status --output text); [ "$s" = READY ] && break; sleep 5; done
save GW_URL $(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $GW_ID --query gatewayUrl --output text)
if [ "$(aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $GW_ID --query 'length(items)' --output text)" = 0 ]; then
  aws bedrock-agentcore-control create-gateway-target --region $R --gateway-identifier $GW_ID --name reporting \
    --target-configuration "{\"mcp\":{\"lambda\":{\"lambdaArn\":\"$REPORTING_LAMBDA_ARN\",\"toolSchema\":{\"inlinePayload\":[{\"name\":\"get_sales_report\",\"description\":\"Sales orders report (service account)\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]}}}}" \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' >/dev/null
fi
sleep 10
aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $GW_ID --query '{status:status,url:gatewayUrl,auth:authorizerConfiguration}'
aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $GW_ID --query 'items[].[name,status]' --output text
