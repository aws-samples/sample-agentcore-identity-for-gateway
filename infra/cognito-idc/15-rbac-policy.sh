#!/usr/bin/env bash
# Gateway tool RBAC (demo version): Policy Engine + one FIXED Cedar permit per tool, attached to the RBAC gateway.
# Cedar never names a group: tool X requires role "Tools.X.Read" in the token's `roles` claim (Entra App Role format).
# Who has which role is decided in IAM Identity Center (group Description), see 15-rbac-idc-groups.sh.
# Usage: 15-rbac-policy.sh [ENFORCE|LOG_ONLY]   (default ENFORCE; LOG_ONLY = dry run: every tool allowed, decisions only logged)
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION; MODE=${1:-ENFORCE}
case "$MODE" in
  ENFORCE) ;;
  LOG_ONLY) echo "WARNING: LOG_ONLY mode: the policy engine only LOGS decisions. EVERY tool is allowed for EVERY authenticated caller, no RBAC is enforced. Use only for a dry run, then re-run with ENFORCE (the default)." >&2 ;;
  *) echo "Usage: $(basename "$0") [ENFORCE|LOG_ONLY]  (default ENFORCE)" >&2; exit 2 ;;
esac
PE_NAME=${PROJECT}_rbac_pe
if [ -z "${RBAC_PE_ID:-}" ]; then
  save RBAC_PE_ID $(aws bedrock-agentcore-control create-policy-engine --region $R --name $PE_NAME \
    --description "rsidc Part 3: per-user tool RBAC on rsidc-rbac-gateway" --query policyEngineId --output text)
fi
for i in $(seq 30); do s=$(aws bedrock-agentcore-control get-policy-engine --region $R --policy-engine-id $RBAC_PE_ID --query status --output text); [ "$s" = ACTIVE ] && break; sleep 5; done
save RBAC_PE_ARN $(aws bedrock-agentcore-control get-policy-engine --region $R --policy-engine-id $RBAC_PE_ID --query policyEngineArn --output text)

# Attach (or switch mode). UpdateGateway needs the full gateway definition, so the current one is copied back.
G=$(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $RBAC_GW_ID --output json)
aws bedrock-agentcore-control update-gateway --region $R --gateway-identifier $RBAC_GW_ID \
  --name "$(jq -r .name <<<"$G")" --role-arn "$(jq -r .roleArn <<<"$G")" --protocol-type MCP \
  --authorizer-type CUSTOM_JWT --authorizer-configuration "$(jq -c .authorizerConfiguration <<<"$G")" \
  --policy-engine-configuration "{\"arn\":\"$RBAC_PE_ARN\",\"mode\":\"$MODE\"}" >/dev/null
for i in $(seq 30); do s=$(aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $RBAC_GW_ID --query status --output text); [ "$s" = READY ] && break; sleep 5; done

policy() {  # $1 policy name, $2 action (target___tool), $3 required role value
  aws bedrock-agentcore-control list-policies --region $R --policy-engine-id $RBAC_PE_ID --query "policies[?name=='$1'].policyId" --output text | grep -q . && return
  local stmt="permit(principal is AgentCore::OAuthUser, action == AgentCore::Action::\"$2\", resource == AgentCore::Gateway::\"$RBAC_GW_ARN\") when { principal.hasTag(\"roles\") && principal.getTag(\"roles\") like \"*\\\"$3\\\"*\" };"
  aws bedrock-agentcore-control create-policy --region $R --policy-engine-id $RBAC_PE_ID --name $1 \
    --description "$2 requires role $3" --definition "$(jq -cn --arg s "$stmt" '{cedar:{statement:$s}}')" >/dev/null
}
policy tool_sales_summary sales___get_sales_summary Tools.Sales.Read
policy tool_customer_contacts crm___get_customer_contacts Tools.CRM.Read
sleep 5
aws bedrock-agentcore-control list-policies --region $R --policy-engine-id $RBAC_PE_ID --query 'policies[].{name:name,status:status,reason:statusReasons}' --output json
aws bedrock-agentcore-control get-gateway --region $R --gateway-identifier $RBAC_GW_ID --query '{status:status,policy:policyEngineConfiguration}'
