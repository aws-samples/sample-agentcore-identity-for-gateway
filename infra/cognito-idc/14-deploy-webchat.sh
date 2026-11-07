#!/usr/bin/env bash
# Deploy the four web GUIs (webchat/cognito-idc/obo_app.py = OBO, oauth_app.py = 2LO/3LO, rbac_app.py = Gateway tool RBAC, webchat/entra-id/entra_app.py = Entra 2LO/3LO/OBO) as Lambdas behind API Gateway HTTP APIs
# (HTTPS; no Function URL; the Lambda resource policy only allows this API, never a public principal).
# Access control: Cognito sign-in only (admin-created users). No IP allowlist yet; add one in front of the API.
# Throttling: $default stage rate/burst limit per API (THROTTLE_RATE / THROTTLE_BURST). WAF cannot attach to HTTP APIs, see README.md (CloudFront + WAF).
# Also registers the new URLs as Cognito callbacks (step 13) and as a 3LO return URL on the OAuth workload identity.
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
ROLE=${PROJECT}-webchat-role
aws iam get-role --role-name $ROLE >/dev/null 2>&1 || { aws iam create-role --role-name $ROLE --tags Key=Project,Value=$PROJECT --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null; sleep 10; }
sed -e "s/__REGION__/$R/g" -e "s/__ACCOUNT__/$ACCOUNT_ID/g" -e "s/__WI__/$OAUTH_WI_NAME/g" -e "s|__CP3LO_SECRET__|$CP3LO_SECRET_ARN|" "$ROOT/infra/cognito-idc/policies/webchat-permissions.json" > /tmp/$ROLE.json
aws iam put-role-policy --role-name $ROLE --policy-name webchat --policy-document file:///tmp/$ROLE.json
# Entra ID GUI (Parts 2–4): separate, additive inline policy (3LO session binding reads the provider secret as the caller)
sed -e "s/__REGION__/$R/g" -e "s/__ACCOUNT__/$ACCOUNT_ID/g" -e "s/__ENTRA_WI__/$ENTRA_WI_NAME/g" -e "s|__CP_ENTRA_SECRET__|$CP_ENTRA_SECRET_ARN|" "$ROOT/infra/entra-id/policies/webchat-entra-permissions.json" > /tmp/$ROLE-entra.json
aws iam put-role-policy --role-name $ROLE --policy-name webchat-entra --policy-document file:///tmp/$ROLE-entra.json

B="$ROOT/build-webchat"; rm -rf "$B"; mkdir -p "$B/pkg/webchat"
uv pip install -q --python-platform aarch64-manylinux2014 --python-version 3.12 --only-binary=:all: --target "$B/pkg" requests boto3
# source folders differ per track, but the zip layout stays flat (webchat/*) so the handler name is unchanged
cp "$ROOT"/webchat/cognito-idc/{obo_app.py,oauth_app.py,rbac_app.py,index.html,oauth_index.html,rbac_index.html} "$ROOT"/webchat/entra-id/{entra_app.py,entra_index.html} "$ROOT"/webchat/common/{lambda_adapter.py,invoke.py,websec.py} "$B/pkg/webchat/"
(cd "$B/pkg" && zip -qr "$B/webchat.zip" .)

# Per-API throttle (requests/s steady, burst). A cost/abuse brake; the real caller limit is Cognito sign-in. Override via env.
THROTTLE_RATE=${THROTTLE_RATE:-10}; THROTTLE_BURST=${THROTTLE_BURST:-20}
deploy() {  # $1 = function suffix; prints the HTTP API endpoint
  local FN=${PROJECT}-webchat-$1 API_ID
  if aws lambda get-function --region $R --function-name $FN >/dev/null 2>&1; then
    aws lambda update-function-code --region $R --function-name $FN --zip-file fileb://$B/webchat.zip >/dev/null
  else
    aws lambda create-function --region $R --function-name $FN --runtime python3.12 --architectures arm64 --timeout 180 --memory-size 256 \
      --role arn:aws:iam::${ACCOUNT_ID}:role/$ROLE --handler webchat/lambda_adapter.handler --zip-file fileb://$B/webchat.zip \
      --tags Project=$PROJECT >/dev/null
    aws lambda wait function-active-v2 --region $R --function-name $FN
    aws lambda put-function-concurrency --region $R --function-name $FN --reserved-concurrent-executions 1 >/dev/null  # in-memory sessions
  fi
  aws lambda delete-function-url-config --region $R --function-name $FN 2>/dev/null || true  # earlier revision used Function URLs
  aws lambda wait function-updated-v2 --region $R --function-name $FN
  API_ID=$(aws apigatewayv2 get-apis --region $R --query "Items[?Name=='$FN'].ApiId | [0]" --output text)
  if [ "$API_ID" = "None" ]; then  # quick create: $default route + Lambda proxy (payload 2.0) + auto-deployed $default stage
    API_ID=$(aws apigatewayv2 create-api --region $R --name $FN --protocol-type HTTP --tags Project=$PROJECT \
      --target arn:aws:lambda:$R:${ACCOUNT_ID}:function:$FN --query ApiId --output text)
    aws lambda add-permission --region $R --function-name $FN --statement-id apigw --action lambda:InvokeFunction \
      --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$R:${ACCOUNT_ID}:$API_ID/*" >/dev/null
  fi
  # Stage-wide throttling (applies on every run). --default-route-settings replaces the whole object, so merge into the current one.
  DRS=$(aws apigatewayv2 get-stage --region $R --api-id $API_ID --stage-name '$default' --output json | jq -c ".DefaultRouteSettings // {} | .ThrottlingBurstLimit=$THROTTLE_BURST | .ThrottlingRateLimit=$THROTTLE_RATE")
  aws apigatewayv2 update-stage --region $R --api-id $API_ID --stage-name '$default' --default-route-settings "$DRS" >/dev/null
  aws apigatewayv2 get-api --region $R --api-id $API_ID --query ApiEndpoint --output text
}
OBO_URL=$(deploy obo obo_app); OAUTH_URL=$(deploy oauth oauth_app); RBAC_URL=$(deploy rbac rbac_app); ENTRA_URL=$(deploy entra entra_app)
save WEB_OBO_URL $OBO_URL; save WEB_OAUTH_URL $OAUTH_URL; save WEB_RBAC_URL $RBAC_URL; save WEB_ENTRA_URL $ENTRA_URL
COMMON="COGNITO_DOMAIN=$COGNITO_DOMAIN,COGNITO_CLIENT_ID=$COGNITO_CLIENT_ID,RT_REGION=$R"
aws lambda update-function-configuration --region $R --function-name ${PROJECT}-webchat-obo \
  --environment "Variables={$COMMON,WEBCHAT_APP=obo_app,RT_ARN=$RT_ARN,WEB_BASE_URL=$OBO_URL}" >/dev/null
aws lambda update-function-configuration --region $R --function-name ${PROJECT}-webchat-oauth \
  --environment "Variables={$COMMON,WEBCHAT_APP=oauth_app,OAUTH_RT_ARN=$OAUTH_RT_ARN,WEB_BASE_URL=$OAUTH_URL,OBO_WEB_URL=$OBO_URL}" >/dev/null
aws lambda update-function-configuration --region $R --function-name ${PROJECT}-webchat-rbac \
  --environment "Variables={$COMMON,WEBCHAT_APP=rbac_app,RBAC_GW_URL=$RBAC_GW_URL,MALL_GW_URL=$MALL_GW_URL,WEB_BASE_URL=$RBAC_URL,ENTRA_TENANT_ID=${ENTRA_TENANT_ID:-},ENTRA_CLIENT_ID=${ENTRA_TEST_CLIENT_ID:-},ENTRA_API_APP_ID=${ENTRA_API_APP_ID:-},ENTRA_GW_URL=${ENTRA_GW_URL:-}}" >/dev/null
rm -rf "$B"

aws lambda update-function-configuration --region $R --function-name ${PROJECT}-webchat-entra \
  --environment "Variables={WEBCHAT_APP=entra_app,RT_REGION=$R,ENTRA_TENANT_ID=$ENTRA_TENANT_ID,ENTRA_CLIENT_ID=$ENTRA_TEST_CLIENT_ID,ENTRA_AGENT_APP_ID=$ENTRA_AGENT_APP_ID,ENTRA_RT_ARN=$ENTRA_RT_ARN,WEB_BASE_URL=$ENTRA_URL}" >/dev/null
# Entra GUI: sign-in redirects on the Entra test client, 3LO return URL on the Entra agent's workload identity (merged, never replaced)
WEB_RBAC_URL=$RBAC_URL WEB_ENTRA_URL=$ENTRA_URL "$ROOT/.venv/bin/python" "$ROOT/infra/entra-id/01-entra-setup.py" >/dev/null
ECUR=$(aws bedrock-agentcore-control get-workload-identity --region $R --name $ENTRA_WI_NAME --query 'allowedResourceOauth2ReturnUrls' --output text)
aws bedrock-agentcore-control update-workload-identity --region $R --name $ENTRA_WI_NAME \
  --allowed-resource-oauth2-return-urls $(echo $ECUR http://localhost:8765/callback $ENTRA_URL/3lo/callback | tr ' \t' '\n\n' | grep . | sort -u) >/dev/null
WEBCHAT_URLS="$OBO_URL $OAUTH_URL $RBAC_URL" "$ROOT/.venv/bin/python" "$ROOT/infra/cognito-idc/13-web-login-client.py"   # Cognito callback + logout URLs
CUR=$(aws bedrock-agentcore-control get-workload-identity --region $R --name $OAUTH_WI_NAME --query 'allowedResourceOauth2ReturnUrls' --output text)
aws bedrock-agentcore-control update-workload-identity --region $R --name $OAUTH_WI_NAME \
  --allowed-resource-oauth2-return-urls $(echo $CUR $OAUTH_URL/3lo/callback | tr ' ' '\n' | sort -u) >/dev/null
aws bedrock-agentcore-control get-workload-identity --region $R --name $OAUTH_WI_NAME --query allowedResourceOauth2ReturnUrls
echo "OBO GUI:     $OBO_URL"; echo "2LO/3LO GUI: $OAUTH_URL"; echo "RBAC GUI:    $RBAC_URL"; echo "Entra GUI:   $ENTRA_URL"
