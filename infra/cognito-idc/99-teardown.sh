#!/usr/bin/env bash
# Deletes EVERYTHING created by steps 01-16 (reverse dependency order: gateways/targets/policy engines before the Lambdas
# and roles they use, the Cognito user pool near the end). Irreversible: Redshift is deleted without a final snapshot.
# Does NOT touch the pre-existing IAM Identity Center instance, its users or pre-existing groups (only the two
# project-owned groups ${PROJECT}-gw-analyst / ${PROJECT}-gw-viewer, and only if their Description carries our tag).
# Run order for the whole project: common/99-teardown.sh -> entra-id/99-teardown.sh -> this script. The Entra track
# reuses the mall Lambda and gateway role created by step 16, so this script refuses to run while ENTRA_GW_ID is still in
# state.env (override: ALLOW_WITH_ENTRA=1).
#
# Usage: infra/cognito-idc/99-teardown.sh [--dry-run] [--yes]
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; source "$ROOT/infra/common/teardown-lib.sh"
R=$RT_REGION; I=$IDC_REGION
for a in "$@"; do td_flag "$a" || { echo "usage: $0 [--dry-run] [--yes]" >&2; exit 2; }; done
if have ENTRA_GW_ID && [ "${ALLOW_WITH_ENTRA:-0}" != 1 ]; then
  msg="ENTRA_GW_ID is still set: run infra/entra-id/99-teardown.sh first (the Entra gateway uses the mall Lambda and role)"
  [ "$DRY" = 1 ] && echo "WARNING: $msg" >&2 || die "$msg"
fi

teardown() {
  local bucket=${PROJECT}-artifacts-${ACCOUNT_ID}-${R} g id d

  # ---- steps 13-16 ------------------------------------------------------------------------------------------------
  # 15: the Pre Token trigger must leave the pool before its Lambda goes (a missing trigger Lambda blocks every sign-in)
  if have COGNITO_POOL_ID; then
    del "detach Pre Token Generation trigger from pool $COGNITO_POOL_ID (15-rbac-pretoken.py --detach)" \
      "$ROOT/.venv/bin/python" "$ROOT/infra/cognito-idc/15-rbac-pretoken.py" --detach
  fi
  # 14: web GUIs (Lambda + HTTP API each; the entra one is also removed by entra-id/99-teardown.sh)
  for g in obo oauth rbac entra; do td_http_api "${PROJECT}-webchat-$g"; td_lambda "${PROJECT}-webchat-$g"; done
  td_role "${PROJECT}-webchat-role"
  note "13 (web login client): it is a setting on the OBO app client, removed with the user pool below"
  # 16: customer version (mall)
  td_gw_logs mall
  td_gateway_stack mall "${MALL_GW_ID:-}" "${MALL_PE_ID:-}"
  td_lambda "${PROJECT}-mall-tools"
  if have COGNITO_POOL_ID; then
    have QUICK_CLIENT_ID && del "Cognito app client rsidc-quick-mcp ($QUICK_CLIENT_ID)" \
      aws cognito-idp delete-user-pool-client --region "$R" --user-pool-id "$COGNITO_POOL_ID" --client-id "$QUICK_CLIENT_ID"
    have MALL_GW_URL && del "Cognito resource server $MALL_GW_URL" \
      aws cognito-idp delete-resource-server --region "$R" --user-pool-id "$COGNITO_POOL_ID" --identifier "$MALL_GW_URL"
    for g in mall-analyst mall-viewer; do
      del "Cognito group $g" aws cognito-idp delete-group --region "$R" --user-pool-id "$COGNITO_POOL_ID" --group-name "$g"; done
  fi
  td_role "${PROJECT}-mall-gateway-role"
  td_role "${PROJECT}-mall-tools-role"
  del "local file tests/.quick-client.env" rm -f "$ROOT/tests/.quick-client.env"
  # 15: Gateway tool RBAC demo
  td_gw_logs rbac
  td_gateway_stack rbac "${RBAC_GW_ID:-}" "${RBAC_PE_ID:-}"
  have RBAC_TEST_WI && td_workload_identity "$RBAC_TEST_WI"
  td_lambda "${PROJECT}-tool-sales"
  td_lambda "${PROJECT}-tool-crm"
  del "Lambda alias live on ${PROJECT}-pretoken-roles" aws lambda delete-alias --region "$R" --function-name "${PROJECT}-pretoken-roles" --name live
  td_lambda "${PROJECT}-pretoken-roles"
  td_role "${PROJECT}-rbac-gateway-role"
  td_role "${PROJECT}-pretoken-roles-role"
  # 15: project-owned IdC groups; the Description tag proves we created them (15-rbac-idc-groups.sh)
  for g in ${PROJECT}-gw-analyst ${PROJECT}-gw-viewer; do
    id=$(ls_ aws identitystore list-groups --region "$I" --identity-store-id "$IDENTITY_STORE_ID" \
      --filters "AttributePath=DisplayName,AttributeValue=$g" --query 'Groups[0].GroupId' --output text)
    [ -n "$id" ] && [ "$id" != None ] || continue
    d=$(ls_ aws identitystore describe-group --region "$I" --identity-store-id "$IDENTITY_STORE_ID" --group-id "$id" --query Description --output text)
    case "$d" in "[rsidc-rbac]"*) del "IdC group $g ($id, memberships go with it)" aws identitystore delete-group --region "$I" --identity-store-id "$IDENTITY_STORE_ID" --group-id "$id";;
                 *) note "IdC group $g exists but its Description is not ours: left alone";; esac
  done

  # ---- steps 09-12: 2LO / 3LO ---------------------------------------------------------------------------------------
  td_runtime OAUTH_RT_ID
  have OAUTH_WI_NAME && td_workload_identity "$OAUTH_WI_NAME"
  td_gateway_stack 2lo "${GW_ID:-}" ""
  td_lambda "${PROJECT}-reporting"
  td_cred_provider "${PROJECT}-2lo-cognito"
  td_cred_provider "${PROJECT}-3lo-cognito"
  td_role "${PROJECT}-oauth-runtime-role"
  td_role "${PROJECT}-reporting-lambda-role"
  td_role "${PROJECT}-gateway-role"
  if have COGNITO_POOL_ID; then
    del "Cognito domain ${PROJECT}-${ACCOUNT_ID}" aws cognito-idp delete-user-pool-domain --region "$R" --user-pool-id "$COGNITO_POOL_ID" --domain "${PROJECT}-${ACCOUNT_ID}"
  fi

  # ---- steps 06-08: OBO runtime + artifacts ------------------------------------------------------------------------
  td_runtime RT_ID
  del "S3 objects s3://$bucket" aws s3 rm "s3://$bucket" --recursive --only-show-errors
  del "S3 bucket $bucket" aws s3api delete-bucket --bucket "$bucket" --region "$R"

  # ---- steps 03-07: IdC applications, Redshift ---------------------------------------------------------------------
  have AGENT_IDC_APP_ARN && del "IdC application $AGENT_IDC_APP_ARN" aws sso-admin delete-application --region "$I" --application-arn "$AGENT_IDC_APP_ARN"
  del "Redshift cluster $REDSHIFT_CLUSTER_ID (NO final snapshot)" aws redshift delete-cluster --region "$I" --cluster-identifier "$REDSHIFT_CLUSTER_ID" --skip-final-cluster-snapshot
  if [ "$MODE" = run ] && [ "$DRY" = 0 ]; then
    aws redshift wait cluster-deleted --region "$I" --cluster-identifier "$REDSHIFT_CLUSTER_ID" \
      || { FAILED=$((FAILED + 1)); echo "  FAILED: waiting for Redshift cluster deletion" >&2; }
  fi
  del "Redshift parameter group ${PROJECT}-redshift-pg" aws redshift delete-cluster-parameter-group --region "$I" --parameter-group-name "${PROJECT}-redshift-pg"
  have REDSHIFT_IDC_APP_ARN && del "Redshift IdC application $REDSHIFT_IDC_APP_ARN" aws redshift delete-redshift-idc-application --region "$I" --redshift-idc-application-arn "$REDSHIFT_IDC_APP_ARN"
  have TTI_ARN && del "IdC trusted token issuer $TTI_ARN" aws sso-admin delete-trusted-token-issuer --region "$I" --trusted-token-issuer-arn "$TTI_ARN"
  del "Redshift subnet group ${PROJECT}-subnets" aws redshift delete-cluster-subnet-group --region "$I" --cluster-subnet-group-name "${PROJECT}-subnets"
  have RS_SG_ID && del "Redshift security group $RS_SG_ID" aws ec2 delete-security-group --region "$I" --group-id "$RS_SG_ID"
  td_role "${PROJECT}-agent-runtime-role"
  td_role "${PROJECT}-redshift-idc-role"

  # ---- step 02: Cognito user pool (clients, groups, branding go with it) ------------------------------------------
  have COGNITO_POOL_ID && del "Cognito user pool $COGNITO_POOL_ID" aws cognito-idp delete-user-pool --region "$R" --user-pool-id "$COGNITO_POOL_ID"

  # ---- step 01: runtime VPC (AgentCore ENIs can take a while to release after runtime deletion) -------------------
  if have RT_VPC_ID; then
    have RT_NAT_ID && del "NAT gateway $RT_NAT_ID" aws ec2 delete-nat-gateway --region "$R" --nat-gateway-id "$RT_NAT_ID"
    if [ "$MODE" = run ] && [ "$DRY" = 0 ] && have RT_NAT_ID; then
      aws ec2 wait nat-gateway-deleted --region "$R" --nat-gateway-ids "$RT_NAT_ID" \
        || { FAILED=$((FAILED + 1)); echo "  FAILED: waiting for NAT gateway deletion" >&2; }
    fi
    have RT_EIP_ALLOC && del "Elastic IP $RT_EIP_ALLOC" aws ec2 release-address --region "$R" --allocation-id "$RT_EIP_ALLOC"
    if have RT_SG_ID; then
      wait_empty "runtime ENIs of $RT_SG_ID" aws ec2 describe-network-interfaces --region "$R" --filters "Name=group-id,Values=$RT_SG_ID" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
      del "runtime security group $RT_SG_ID" aws ec2 delete-security-group --region "$R" --group-id "$RT_SG_ID"
    fi
    for id in ${RT_PUB_SUBNET:-} ${RT_PRIV_SUBNET_1:-} ${RT_PRIV_SUBNET_2:-}; do del "subnet $id" aws ec2 delete-subnet --region "$R" --subnet-id "$id"; done
    for id in ${RT_PUB_RTB:-} ${RT_PRIV_RTB:-}; do del "route table $id" aws ec2 delete-route-table --region "$R" --route-table-id "$id"; done
    if have RT_IGW_ID; then
      del "detach internet gateway $RT_IGW_ID" aws ec2 detach-internet-gateway --region "$R" --internet-gateway-id "$RT_IGW_ID" --vpc-id "$RT_VPC_ID"
      del "internet gateway $RT_IGW_ID" aws ec2 delete-internet-gateway --region "$R" --internet-gateway-id "$RT_IGW_ID"
    fi
    del "VPC $RT_VPC_ID" aws ec2 delete-vpc --region "$R" --vpc-id "$RT_VPC_ID"
  fi
}

td_main teardown
td_finish
echo "Remove infra/state.env and tests/.users.env if you will not redeploy."
