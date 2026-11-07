#!/usr/bin/env bash
# Entra ID track, Gateway tool RBAC: a Gateway that trusts Microsoft Entra ID directly (no Cognito, no Pre Token trigger).
# PREREQUISITE: the Cognito track through step 16 (cognito-idc/16-mall-gateway.sh) must have run: it creates the mall Lambda
#   rsidc-mall-tools and the gateway role rsidc-mall-gateway-role used below. Run after 01-entra-setup.py.
#   inbound : CUSTOM_JWT, discovery = the tenant's v2 OIDC metadata, allowedAudience = the rsidc-mall-api app ID
#             (Entra v2 access tokens carry the client in `azp`, not `client_id`, so audience is the right check)
#   target  : the same mall Lambda + gateway role as the Cognito customer version.
#   policy  : its own engine with the same 4 fixed Cedar rules; Entra's native App Role claim `roles` is matched
# Usage: 02-entra-gateway.sh [ENFORCE|LOG_ONLY]   (default ENFORCE; LOG_ONLY = dry run: every tool allowed, decisions only logged)
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION; MODE=${1:-ENFORCE}
case "$MODE" in
  ENFORCE) ;;
  LOG_ONLY) echo "WARNING: LOG_ONLY mode: the policy engine only LOGS decisions. EVERY tool is allowed for EVERY authenticated caller, no RBAC is enforced. Use only for a dry run, then re-run with ENFORCE (the default)." >&2 ;;
  *) echo "Usage: $(basename "$0") [ENFORCE|LOG_ONLY]  (default ENFORCE)" >&2; exit 2 ;;
esac
DISC="https://login.microsoftonline.com/$ENTRA_TENANT_ID/v2.0/.well-known/openid-configuration"
GR=${PROJECT}-mall-gateway-role; MALL_FN=arn:aws:lambda:$R:${ACCOUNT_ID}:function:${PROJECT}-mall-tools
AUTH="{\"customJWTAuthorizer\":{\"discoveryUrl\":\"$DISC\",\"allowedAudience\":[\"$ENTRA_API_APP_ID\"]}}"
if [ -z "${ENTRA_GW_ID:-}" ]; then
  save ENTRA_GW_ID $(aws bedrock-agentcore-control create-gateway --region $R --name ${PROJECT}-mall-entra-gateway --role-arn arn:aws:iam::${ACCOUNT_ID}:role/$GR \
    --protocol-type MCP --authorizer-type CUSTOM_JWT --description "rsidc Part 6: Entra ID version (Entra JWT + App Roles -> Cedar -> mall tools)" \
    --authorizer-configuration "$AUTH" --query gatewayId --output text)
fi
wait_gw() { for i in $(seq 30); do s=$(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $ENTRA_GW_ID --query status --output text); [ "$s" = READY ] && return; sleep 5; done; }
wait_gw
save ENTRA_GW_URL $(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $ENTRA_GW_ID --query gatewayUrl --output text)
save ENTRA_GW_ARN $(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $ENTRA_GW_ID --query gatewayArn --output text)
if ! aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $ENTRA_GW_ID --query "items[?name=='mall'].targetId" --output text | grep -q .; then
  CFG=$(python3 -c "import json,sys;print(json.dumps({'mcp':{'lambda':{'lambdaArn':sys.argv[1],'toolSchema':{'inlinePayload':json.load(open(sys.argv[2]))}}}}))" $MALL_FN "$ROOT/infra/common/lambda/mall_tools/tools.json")
  aws bedrock-agentcore-control create-gateway-target --region $R --gateway-identifier $ENTRA_GW_ID --name mall \
    --description "Customer mall-footfall tools (4)" --target-configuration "$CFG" \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' >/dev/null
fi
for i in $(seq 30); do s=$(aws bedrock-agentcore-control list-gateway-targets --region $R --gateway-identifier $ENTRA_GW_ID --query "items[?name=='mall'].status|[0]" --output text); [ "$s" = READY ] && break; sleep 5; done

if [ -z "${ENTRA_PE_ID:-}" ]; then
  save ENTRA_PE_ID $(aws bedrock-agentcore-control create-policy-engine --region $R --name ${PROJECT}_mall_entra_pe \
    --description "rsidc Part 6: per-user tool RBAC on rsidc-mall-entra-gateway (Entra App Roles)" --query policyEngineId --output text)
fi
for i in $(seq 30); do s=$(aws bedrock-agentcore-control get-policy-engine --region $R --policy-engine-id $ENTRA_PE_ID --query status --output text); [ "$s" = ACTIVE ] && break; sleep 5; done
save ENTRA_PE_ARN $(aws bedrock-agentcore-control get-policy-engine --region $R --policy-engine-id $ENTRA_PE_ID --query policyEngineArn --output text)
policy() {  # identical rule shape to the Cognito customer version; only the gateway ARN differs
  aws bedrock-agentcore-control list-policies --region $R --policy-engine-id $ENTRA_PE_ID --query "policies[?name=='$1'].policyId" --output text | grep -q . && return
  local stmt="permit(principal is AgentCore::OAuthUser, action == AgentCore::Action::\"$2\", resource == AgentCore::Gateway::\"$ENTRA_GW_ARN\") when { principal.hasTag(\"roles\") && principal.getTag(\"roles\") like \"*\\\"$3\\\"*\" };"
  aws bedrock-agentcore-control create-policy --region $R --policy-engine-id $ENTRA_PE_ID --name $1 \
    --description "$2 requires Entra App Role $3" --definition "$(jq -cn --arg s "$stmt" '{cedar:{statement:$s}}')" >/dev/null
}
policy entra_mall_list     mall___get_mall_list        Tools.Mall.List
policy entra_mall_footfall mall___get_footfall_summary Tools.Mall.Footfall
policy entra_mall_hourly   mall___get_hourly_traffic   Tools.Mall.Hourly
policy entra_mall_zone     mall___get_zone_comparison  Tools.Mall.Zone
for i in $(seq 30); do n=$(aws bedrock-agentcore-control list-policies --region $R --policy-engine-id $ENTRA_PE_ID --query "length(policies[?status=='ACTIVE'])" --output text); [ "$n" = 4 ] && break; sleep 5; done
# The shared gateway role gets a SEPARATE inline policy for this engine (the Cognito customer version's policy is left untouched).
sed -e "s|__ENTRA_PE_ARN__|$ENTRA_PE_ARN|" -e "s|__ENTRA_GW_ARN__|$ENTRA_GW_ARN|" "$ROOT/infra/entra-id/policies/entra-gateway-permissions.json" > /tmp/$GR-entra.json
aws iam put-role-policy --role-name $GR --policy-name entra-gateway --policy-document file:///tmp/$GR-entra.json
G=$(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $ENTRA_GW_ID --output json)
for try in 1 2 3 4 5 6; do aws bedrock-agentcore-control update-gateway --region $R --gateway-identifier $ENTRA_GW_ID \
  --name "$(jq -r .name <<<"$G")" --role-arn "$(jq -r .roleArn <<<"$G")" --protocol-type MCP --description "$(jq -r .description <<<"$G")" \
  --authorizer-type CUSTOM_JWT --authorizer-configuration "$(jq -c .authorizerConfiguration <<<"$G")" \
  --policy-engine-configuration "{\"arn\":\"$ENTRA_PE_ARN\",\"mode\":\"$MODE\"}" >/dev/null && break; sleep 10; done  # IAM propagation
wait_gw
aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $ENTRA_GW_ID --query '{id:gatewayId,status:status,url:gatewayUrl,auth:authorizerConfiguration,policy:policyEngineConfiguration}'
aws bedrock-agentcore-control list-policies --region $R --policy-engine-id $ENTRA_PE_ID --query 'policies[].[name,status]' --output text
