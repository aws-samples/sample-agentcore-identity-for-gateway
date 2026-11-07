#!/usr/bin/env bash
# Gateway tool RBAC (customer version): Policy Engine + one FIXED Cedar permit per mall tool, attached to the mall gateway.
# Cedar never names a group: tool X requires role "Tools.Mall.X" in the token's `roles` claim. Who has which role is
# decided by the Cognito group Description (16-mall-cognito.py), resolved at sign-in by the Pre Token Gen trigger.
# Usage: 16-mall-policy.sh [ENFORCE|LOG_ONLY]   (default ENFORCE; LOG_ONLY = dry run: every tool allowed, decisions only logged)
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION; MODE=${1:-ENFORCE}
case "$MODE" in
  ENFORCE) ;;
  LOG_ONLY) echo "WARNING: LOG_ONLY mode: the policy engine only LOGS decisions. EVERY tool is allowed for EVERY authenticated caller, no RBAC is enforced. Use only for a dry run, then re-run with ENFORCE (the default)." >&2 ;;
  *) echo "Usage: $(basename "$0") [ENFORCE|LOG_ONLY]  (default ENFORCE)" >&2; exit 2 ;;
esac
if [ -z "${MALL_PE_ID:-}" ]; then
  save MALL_PE_ID $(aws bedrock-agentcore-control create-policy-engine --region $R --name ${PROJECT}_mall_pe \
    --description "rsidc Part 4: per-user tool RBAC on rsidc-mall-gateway (customer version)" --query policyEngineId --output text)
fi
for i in $(seq 30); do s=$(aws bedrock-agentcore-control get-policy-engine --region $R --policy-engine-id $MALL_PE_ID --query status --output text); [ "$s" = ACTIVE ] && break; sleep 5; done
save MALL_PE_ARN $(aws bedrock-agentcore-control get-policy-engine --region $R --policy-engine-id $MALL_PE_ID --query policyEngineArn --output text)
policy() {  # $1 policy name, $2 action (target___tool), $3 required role value
  aws bedrock-agentcore-control list-policies --region $R --policy-engine-id $MALL_PE_ID --query "policies[?name=='$1'].policyId" --output text | grep -q . && return
  local stmt="permit(principal is AgentCore::OAuthUser, action == AgentCore::Action::\"$2\", resource == AgentCore::Gateway::\"$MALL_GW_ARN\") when { principal.hasTag(\"roles\") && principal.getTag(\"roles\") like \"*\\\"$3\\\"*\" };"
  aws bedrock-agentcore-control create-policy --region $R --policy-engine-id $MALL_PE_ID --name $1 \
    --description "$2 requires role $3" --definition "$(jq -cn --arg s "$stmt" '{cedar:{statement:$s}}')" >/dev/null
}
policy mall_list     mall___get_mall_list        Tools.Mall.List
policy mall_footfall mall___get_footfall_summary Tools.Mall.Footfall
policy mall_hourly   mall___get_hourly_traffic   Tools.Mall.Hourly
policy mall_zone     mall___get_zone_comparison  Tools.Mall.Zone
for i in $(seq 30); do n=$(aws bedrock-agentcore-control list-policies --region $R --policy-engine-id $MALL_PE_ID --query "length(policies[?status=='ACTIVE'])" --output text); [ "$n" = 4 ] && break; sleep 5; done
# Attach (or switch mode). UpdateGateway needs the full gateway definition, so the current one is copied back.
G=$(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $MALL_GW_ID --output json)
aws bedrock-agentcore-control update-gateway --region $R --gateway-identifier $MALL_GW_ID \
  --name "$(jq -r .name <<<"$G")" --role-arn "$(jq -r .roleArn <<<"$G")" --protocol-type MCP --description "$(jq -r .description <<<"$G")" \
  --authorizer-type CUSTOM_JWT --authorizer-configuration "$(jq -c .authorizerConfiguration <<<"$G")" \
  --policy-engine-configuration "{\"arn\":\"$MALL_PE_ARN\",\"mode\":\"$MODE\"}" >/dev/null
for i in $(seq 30); do s=$(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $MALL_GW_ID --query status --output text); [ "$s" = READY ] && break; sleep 5; done
aws bedrock-agentcore-control list-policies --region $R --policy-engine-id $MALL_PE_ID --query 'policies[].{name:name,status:status}' --output text
aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $MALL_GW_ID --query '{status:status,policy:policyEngineConfiguration,auth:authorizerConfiguration.customJWTAuthorizer.allowedClients}'
