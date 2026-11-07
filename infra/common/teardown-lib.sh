#!/usr/bin/env bash
# Shared helpers for the three 99-teardown.sh scripts. Source after common/00-config.sh; do not execute.
#
# Contract of every teardown script:
#   1. define ONE function (e.g. `teardown`) that calls del / td_* helpers in dependency order;
#   2. call `td_main teardown`.
# td_main runs that function twice: MODE=plan prints what will be deleted (read-only list/describe calls only),
# then, after confirmation, MODE=run executes the deletions. `--dry-run` prints the commands instead of running them.
# Safety: names are only deleted when they start with ${PROJECT}- / ${PROJECT}_ (need_prefix); everything else is
# addressed by an ID read from infra/state.env. Not-found errors are skipped, every other error is reported and the
# script exits non-zero at the end (nothing is silenced with `|| true`).
# Bash 3.2 compatible (macOS): no associative arrays.

DRY=0; YES=0; MODE=plan; FAILED=0
NOTFOUND_RE='NotFound|NoSuchEntity|NoSuchBucket|NoSuchKey|does not exist|NotAttached'

td_flag() {  # common flags; returns 1 if $1 is not one of them
  case "$1" in
    --dry-run) DRY=1;;
    --yes) YES=1;;
    *) return 1;;
  esac
}

die() { echo "ERROR: $*" >&2; exit 1; }
have() { eval "[ -n \"\${$1:-}\" ]"; }   # have VAR: state variable is set and non-empty
need_prefix() {  # refuse anything that is not ours
  case "$1" in "${PROJECT}-"*|"${PROJECT}_"*|*"/${PROJECT}-"*) ;; *) die "refusing to touch '$1': not prefixed with ${PROJECT}";; esac
}
note() { [ "$MODE" = plan ] && echo "  * $*" || true; }

# del "description" command args...   : plan -> print description; run -> execute (or print with --dry-run)
del() {
  local desc=$1 out; shift
  if [ "$MODE" = plan ]; then echo "  - $desc"; return 0; fi
  if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; return 0; fi
  if out=$("$@" 2>&1); then echo "  deleted: $desc"
  elif grep -qE "$NOTFOUND_RE" <<<"$out"; then echo "  skip (not found): $desc"
  else FAILED=$((FAILED + 1)); echo "  FAILED: $desc" >&2; echo "    ${out//$'\n'/ }" >&2
  fi
}

# ls_ command...  : read-only list/describe used to enumerate children; prints stdout, empty if the parent is gone
ls_() {
  local out
  if out=$("$@" 2>&1); then printf '%s' "$out"
  elif grep -qE "$NOTFOUND_RE" <<<"$out"; then :
  else echo "  WARN: $* -> ${out//$'\n'/ }" >&2
  fi
}

# wait_empty "what" command...  : after an async delete, wait until the list command prints nothing (run mode only)
wait_empty() {
  local what=$1 i; shift
  { [ "$MODE" = run ] && [ "$DRY" = 0 ]; } || return 0
  for i in $(seq 90); do
    [ -z "$(ls_ "$@" | tr -d '[:space:]')" ] && return 0
    sleep 5
  done
  FAILED=$((FAILED + 1)); echo "  FAILED: timed out waiting for $what to disappear" >&2
}

# ---- AWS building blocks (Region = $R, set by the caller) ----------------------------------------------------------
td_role() {  # IAM role with all inline/attached policies
  need_prefix "$1"
  local p
  for p in $(ls_ aws iam list-role-policies --role-name "$1" --query 'PolicyNames[]' --output text); do
    del "IAM inline policy $1/$p" aws iam delete-role-policy --role-name "$1" --policy-name "$p"; done
  for p in $(ls_ aws iam list-attached-role-policies --role-name "$1" --query 'AttachedPolicies[].PolicyArn' --output text); do
    del "IAM detach $p from $1" aws iam detach-role-policy --role-name "$1" --policy-arn "$p"; done
  del "IAM role $1" aws iam delete-role --role-name "$1"
}
td_lambda() { need_prefix "$1"; del "Lambda function $1 ($R)" aws lambda delete-function --region "$R" --function-name "$1"; }
td_http_api() {  # API Gateway HTTP API(s) by exact name
  need_prefix "$1"
  local id
  for id in $(ls_ aws apigatewayv2 get-apis --region "$R" --query "Items[?Name=='$1'].ApiId" --output text); do
    del "API Gateway HTTP API $1 ($id)" aws apigatewayv2 delete-api --region "$R" --api-id "$id"; done
}
td_runtime() {  # AgentCore runtime by ID, then its auto-created log groups (matched by the unique runtime ID)
  have "$1" || { note "$1 not set in state.env: runtime skipped"; return 0; }
  local id=${!1} lg
  del "AgentCore runtime $id ($R)" aws bedrock-agentcore-control delete-agent-runtime --region "$R" --agent-runtime-id "$id"
  wait_empty "runtime $id" aws bedrock-agentcore-control get-agent-runtime --region "$R" --agent-runtime-id "$id" --query status --output text
  for lg in $(ls_ aws logs describe-log-groups --region "$R" --log-group-name-prefix "/aws/bedrock-agentcore/runtimes/$id" --query 'logGroups[].logGroupName' --output text); do
    del "log group $lg" aws logs delete-log-group --region "$R" --log-group-name "$lg"; done
}
td_workload_identity() { need_prefix "$1"; del "AgentCore workload identity $1" aws bedrock-agentcore-control delete-workload-identity --region "$R" --name "$1"; }
td_cred_provider() { need_prefix "$1"; del "AgentCore OAuth2 credential provider $1" aws bedrock-agentcore-control delete-oauth2-credential-provider --region "$R" --name "$1"; }

# td_gateway_stack label gatewayId policyEngineId   (either ID may be empty). Order: targets -> gateway -> policies -> engine.
td_gateway_stack() {
  local label=$1 gw=${2:-} pe=${3:-} t p
  if [ -n "$gw" ]; then
    for t in $(ls_ aws bedrock-agentcore-control list-gateway-targets --region "$R" --gateway-identifier "$gw" --query 'items[].targetId' --output text); do
      del "$label gateway target $t" aws bedrock-agentcore-control delete-gateway-target --region "$R" --gateway-identifier "$gw" --target-id "$t"; done
    wait_empty "$label gateway targets" aws bedrock-agentcore-control list-gateway-targets --region "$R" --gateway-identifier "$gw" --query 'items[].targetId' --output text
    del "$label gateway $gw ($R)" aws bedrock-agentcore-control delete-gateway --region "$R" --gateway-identifier "$gw"
    wait_empty "$label gateway" aws bedrock-agentcore-control get-gateway --region "$R" --gateway-identifier "$gw" --query status --output text
  else note "$label gateway: no ID in state.env, skipped"; fi
  if [ -n "$pe" ]; then
    for p in $(ls_ aws bedrock-agentcore-control list-policies --region "$R" --policy-engine-id "$pe" --query 'policies[].policyId' --output text); do
      del "$label Cedar policy $p" aws bedrock-agentcore-control delete-policy --region "$R" --policy-engine-id "$pe" --policy-id "$p"; done
    wait_empty "$label policies" aws bedrock-agentcore-control list-policies --region "$R" --policy-engine-id "$pe" --query 'policies[].policyId' --output text
    del "$label policy engine $pe" aws bedrock-agentcore-control delete-policy-engine --region "$R" --policy-engine-id "$pe"
  fi
}

# td_gw_logs rbac|mall : CloudWatch log delivery created by 15-rbac-logs.sh / 16-mall-logs.sh
td_gw_logs() {
  local src=${PROJECT}-$1-gw-logs dst=${PROJECT}-$1-gw-cwl lg=/aws/vendedlogs/bedrock-agentcore/gateway/${PROJECT}-$1-gateway d
  for d in $(ls_ aws logs describe-deliveries --region "$R" --query "deliveries[?deliverySourceName=='$src'].id" --output text); do
    del "log delivery $d ($src)" aws logs delete-delivery --region "$R" --id "$d"; done
  del "log delivery source $src" aws logs delete-delivery-source --region "$R" --name "$src"
  del "log delivery destination $dst" aws logs delete-delivery-destination --region "$R" --name "$dst"
  del "log group $lg" aws logs delete-log-group --region "$R" --log-group-name "$lg"
}

# ---- driver ---------------------------------------------------------------------------------------------------------
td_forget() {  # drop variables from infra/state.env after a fully successful real run
  { [ "$MODE" = run ] && [ "$DRY" = 0 ] && [ "$FAILED" = 0 ]; } || return 0
  local v; for v in "$@"; do sed -i '' "/^export $v=/d" "$STATE_FILE"; done
  echo "removed $# variable(s) from $STATE_FILE"
}

td_main() {  # td_main function_name
  [ -n "${ACCOUNT_ID:-}" ] || die "ACCOUNT_ID is empty: AWS credentials for profile '$AWS_PROFILE' are not usable"
  echo "Account $ACCOUNT_ID | profile $AWS_PROFILE | project $PROJECT | region(s) $RT_REGION / $IDC_REGION"
  echo "Will delete:"
  MODE=plan; "$1"
  if [ "$DRY" = 1 ]; then
    echo; echo "--dry-run: commands that would run (nothing is executed):"
    MODE=run; "$1"; echo "dry-run finished, nothing deleted."; return 0
  fi
  if [ "$YES" != 1 ]; then
    local c; read -r -p "Type 'yes' to delete everything listed above: " c; [ "$c" = yes ] || die "aborted, nothing deleted"
  fi
  MODE=run; FAILED=0; "$1"
}

td_finish() {  # call after td_main (and td_forget)
  [ "$DRY" = 1 ] && return 0
  [ "$FAILED" = 0 ] || die "$FAILED step(s) failed, see FAILED lines above; fix and re-run (the script is idempotent)"
  echo "Done."
}
