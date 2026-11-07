#!/usr/bin/env bash
# Teardown for the Microsoft Entra ID track (steps 01-04). Run AFTER common/99-teardown.sh and BEFORE
# cognito-idc/99-teardown.sh (the Entra gateway still uses the Cognito-owned mall Lambda and gateway role).
#
# Default scope = AWS resources of THIS account/Region (RT_REGION), by IDs from infra/state.env or ${PROJECT}-prefixed names:
#   - web GUI  : Lambda + HTTP API ${PROJECT}-webchat-entra, inline policy `webchat-entra` on ${PROJECT}-webchat-role
#   - runtime  : ENTRA_RT_ID (+ its log groups), workload identity ENTRA_WI_NAME, credential provider ${PROJECT}-entra
#                (AgentCore deletes the client-secret Secrets Manager entry it manages together with the provider)
#   - gateway  : ENTRA_GW_ID + its targets, policy engine ENTRA_PE_ID + 4 Cedar policies
#   - IAM      : role ${PROJECT}-entra-runtime-role; inline policy `entra-gateway` on the shared ${PROJECT}-mall-gateway-role
#   - S3       : only the agent_entra/ prefix of ${PROJECT}-artifacts-<account>-<region>
# NOT touched: the Cognito-owned mall Lambda ${PROJECT}-mall-tools, ${PROJECT}-mall-gateway-role (only the extra inline
# policy is removed), ${PROJECT}-webchat-role, the artifacts bucket, anything in Entra unless --with-entra-apps.
#
# Usage: infra/entra-id/99-teardown.sh [--dry-run] [--yes] [--with-cloudfront --profile <p>] [--with-entra-apps]
#   --with-cloudfront --profile <p>   also delete the Part 1 custom-domain stack. It lives in ANOTHER account (the one that
#                                     owns the domain), reached through AWS CLI profile <p>. Needs env CF_DOMAIN (e.g.
#                                     mcp.agentzone.click). Optional env: CF_FUNCTION_NAME (default mcp-prm),
#                                     CF_RHP_NAME (default mcp-agentzone-www-authenticate), CF_ZONE_ID (default: looked up),
#                                     CF_ORIGIN_HOST (default: host of ENTRA_GW_URL). These names have no ${PROJECT} prefix, so
#                                     the distribution is only deleted if its alias is CF_DOMAIN AND its origin is the Entra gateway.
#   --with-entra-apps                 also delete the Entra app registrations via `az` (needs a tenant admin session in tenant
#                                     ENTRA_TENANT_ID). Deleted apps stay recoverable in Entra for 30 days. The users
#                                     wei/ds1/chen created by 01-entra-setup.py are NOT deleted (remove them in the Entra portal).
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; source "$ROOT/infra/common/teardown-lib.sh"
R=$RT_REGION; WITH_CF=0; WITH_APPS=0; CF_PROFILE=""
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-; exit "${1:-2}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --with-cloudfront) WITH_CF=1;;
    --with-entra-apps) WITH_APPS=1;;
    --profile) CF_PROFILE=${2:?--profile needs a value}; shift;;
    -h|--help) usage 0;;
    *) td_flag "$1" || usage 2;;
  esac; shift
done
[ "$WITH_CF" = 0 ] || { [ -n "$CF_PROFILE" ] || die "--with-cloudfront needs --profile <p>"; [ -n "${CF_DOMAIN:-}" ] || die "--with-cloudfront needs env CF_DOMAIN"; }

cf() { aws --profile "$CF_PROFILE" "$@"; }   # CLI for the domain account

# ---- CloudFront / ACM / Route 53 (domain account) -------------------------------------------------------------------
r53_zone() {  # hosted zone ID for CF_DOMAIN: CF_ZONE_ID, else the zone with the longest matching name
  [ -n "${CF_ZONE_ID:-}" ] && { echo "$CF_ZONE_ID"; return; }
  local d=$CF_DOMAIN id
  while [[ "$d" == *.* ]]; do
    id=$(ls_ cf route53 list-hosted-zones-by-name --dns-name "$d" --query "HostedZones[?Name=='$d.'].Id | [0]" --output text)
    [ -n "$id" ] && [ "$id" != None ] && { echo "${id##*/}"; return; }
    d=${d#*.}
  done
}
r53_delete_record() {  # zone name type : DELETE the exact record set currently there
  local zone=$1 name=$2 type=$3 rr
  rr=$(cf route53 list-resource-record-sets --hosted-zone-id "$zone" --query "ResourceRecordSets[?Name=='$name.' && Type=='$type'] | [0]" --output json) || return 1
  [ "$rr" = null ] && { echo "record $type $name does not exist"; return 1; }   # matched as not found
  cf route53 change-resource-record-sets --hosted-zone-id "$zone" \
    --change-batch "$(jq -c '{Changes:[{Action:"DELETE",ResourceRecordSet:.}]}' <<<"$rr")" >/dev/null
}
cf_drop_distribution() {  # disable -> wait deployed -> delete. Explicit `|| return 1`: set -e is off inside del's `if`.
  local id=$1 cfg etag
  cfg=$(cf cloudfront get-distribution-config --id "$id" --output json) || return 1
  etag=$(jq -r .ETag <<<"$cfg")
  if [ "$(jq -r .DistributionConfig.Enabled <<<"$cfg")" = true ]; then
    jq -c '.DistributionConfig | .Enabled=false' <<<"$cfg" > "/tmp/${PROJECT}-cf-disable.json"
    cf cloudfront update-distribution --id "$id" --if-match "$etag" --distribution-config "file:///tmp/${PROJECT}-cf-disable.json" >/dev/null || return 1
    cf cloudfront wait distribution-deployed --id "$id" || return 1
  fi
  etag=$(cf cloudfront get-distribution-config --id "$id" --query ETag --output text) || return 1
  cf cloudfront delete-distribution --id "$id" --if-match "$etag"
}
cf_drop_function() { local e; e=$(cf cloudfront describe-function --name "$1" --query ETag --output text) || return 1; cf cloudfront delete-function --name "$1" --if-match "$e"; }
cf_drop_rhp() { local e; e=$(cf cloudfront get-response-headers-policy --id "$1" --query ETag --output text) || return 1; cf cloudfront delete-response-headers-policy --id "$1" --if-match "$e"; }

teardown_cloudfront() {
  local fn=${CF_FUNCTION_NAME:-mcp-prm} rhp=${CF_RHP_NAME:-mcp-agentzone-www-authenticate}
  local origin=${CF_ORIGIN_HOST:-} zone dist cert rhp_id rec
  [ -n "$origin" ] || { have ENTRA_GW_URL && origin=$(sed -e 's|^https://||' -e 's|/.*||' <<<"$ENTRA_GW_URL"); }
  [ -n "$origin" ] || die "CloudFront cleanup needs ENTRA_GW_URL in state.env or env CF_ORIGIN_HOST to verify the distribution origin"
  zone=$(r53_zone)
  dist=$(ls_ cf cloudfront list-distributions --query "DistributionList.Items[?Aliases.Items!=null && contains(Aliases.Items,'$CF_DOMAIN') && Origins.Items[0].DomainName=='$origin'].Id" --output text)
  cert=$(ls_ cf acm list-certificates --region us-east-1 --query "CertificateSummaryList[?DomainName=='$CF_DOMAIN'].CertificateArn | [0]" --output text)
  dist=${dist//None/}; [ "$cert" = None ] && cert=""
  rhp_id=$(ls_ cf cloudfront list-response-headers-policies --type custom --query "ResponseHeadersPolicyList.Items[?ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name=='$rhp'].ResponseHeadersPolicy.Id | [0]" --output text)
  [ "$rhp_id" = None ] && rhp_id=""
  if [ -n "$zone" ]; then
    del "Route 53 A alias $CF_DOMAIN (zone $zone)" r53_delete_record "$zone" "$CF_DOMAIN" A
    del "Route 53 AAAA alias $CF_DOMAIN (zone $zone)" r53_delete_record "$zone" "$CF_DOMAIN" AAAA
    if [ -n "$cert" ]; then   # ACM DNS-validation CNAME(s), read from the certificate before it is deleted
      for rec in $(ls_ cf acm describe-certificate --region us-east-1 --certificate-arn "$cert" --query 'Certificate.DomainValidationOptions[].ResourceRecord.Name' --output text); do
        del "Route 53 ACM validation CNAME ${rec%.} (zone $zone)" r53_delete_record "$zone" "${rec%.}" CNAME; done
    fi
  else note "no Route 53 hosted zone found for $CF_DOMAIN: DNS records skipped"; fi
  for dist in $dist; do del "CloudFront distribution $dist ($CF_DOMAIN -> $origin); disabled first, takes minutes" cf_drop_distribution "$dist"; done
  [ -z "$cert" ] || del "ACM certificate $cert (us-east-1)" cf acm delete-certificate --region us-east-1 --certificate-arn "$cert"
  del "CloudFront function $fn" cf_drop_function "$fn"
  [ -z "$rhp_id" ] || del "CloudFront response headers policy $rhp ($rhp_id)" cf_drop_rhp "$rhp_id"
}

# ---- Entra app registrations (az) ---------------------------------------------------------------------------------
az_app_ids() {  # display name, optional known appId -> appId(s)
  if [ -n "${2:-}" ]; then echo "$2"; else ls_ az ad app list --display-name "$1" --query "[?displayName=='$1'].appId" -o tsv; fi
}
teardown_entra_apps() {
  local cur n id
  cur=$(az account show --query tenantId -o tsv) || die "az is not logged in (az login --tenant \$ENTRA_TENANT_ID --allow-no-subscriptions)"
  [ "$cur" = "${ENTRA_TENANT_ID:-}" ] || die "az tenant $cur does not match ENTRA_TENANT_ID in state.env"
  for n in "rsidc-entra-agent ${ENTRA_AGENT_APP_ID:-}" "rsidc-mall-test-client ${ENTRA_TEST_CLIENT_ID:-}" "rsidc-mall-api ${ENTRA_API_APP_ID:-}" "rsidc-quick-mcp-entra"; do
    # shellcheck disable=SC2086
    set -- $n
    for id in $(az_app_ids "$@"); do del "Entra app registration $1 ($id)" az ad app delete --id "$id"; done
  done
  del "local Entra secret files tests/.entra-*.env" rm -f "$ROOT"/tests/.entra-agent.env "$ROOT"/tests/.entra-users.env "$ROOT"/tests/.entra-quick-client.env
}

# ---- AWS (this account) ---------------------------------------------------------------------------------------------
teardown() {
  local bucket=${PROJECT}-artifacts-${ACCOUNT_ID}-${R}
  # 1. web GUI of the Entra track (deployed by cognito-idc/14-deploy-webchat.sh)
  td_http_api "${PROJECT}-webchat-entra"
  td_lambda "${PROJECT}-webchat-entra"
  del "inline policy webchat-entra on ${PROJECT}-webchat-role (role itself stays: Cognito track)" aws iam delete-role-policy --role-name "${PROJECT}-webchat-role" --policy-name webchat-entra
  # 2. runtime, then its workload identity and the credential provider it used
  td_runtime ENTRA_RT_ID
  if have ENTRA_WI_NAME; then td_workload_identity "$ENTRA_WI_NAME"; else note "ENTRA_WI_NAME not set: workload identity skipped"; fi
  td_cred_provider "${PROJECT}-entra"
  # 3. gateway (targets -> gateway), then policies -> policy engine
  td_gateway_stack entra "${ENTRA_GW_ID:-}" "${ENTRA_PE_ID:-}"
  # 4. IAM: only what the Entra track added
  del "inline policy entra-gateway on ${PROJECT}-mall-gateway-role (role itself stays: Cognito track)" aws iam delete-role-policy --role-name "${PROJECT}-mall-gateway-role" --policy-name entra-gateway
  td_role "${PROJECT}-entra-runtime-role"
  # 5. runtime code uploaded by 04-entra-agentcore.sh (shared bucket stays)
  del "S3 objects s3://$bucket/agent_entra/" aws s3 rm "s3://$bucket/agent_entra/" --recursive --only-show-errors
  # 6. optional
  [ "$WITH_CF" = 0 ] || teardown_cloudfront
  [ "$WITH_APPS" = 0 ] || teardown_entra_apps
}

td_main teardown
td_forget ENTRA_GW_ID ENTRA_GW_URL ENTRA_GW_ARN ENTRA_PE_ID ENTRA_PE_ARN CP_ENTRA_CALLBACK CP_ENTRA_SECRET_ARN \
          ENTRA_RT_ROLE_ARN ENTRA_RT_ID ENTRA_RT_ARN ENTRA_WI_NAME WEB_ENTRA_URL
td_finish
