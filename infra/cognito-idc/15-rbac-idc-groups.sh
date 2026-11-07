#!/usr/bin/env bash
# Gateway tool RBAC (demo version): project-owned IdC groups that carry the group -> tool mapping in their Description.
# The pre-existing groups (risk-team, data-scientists, ...) were NOT created by this project, so their Descriptions are
# never written. Usage: 15-rbac-idc-groups.sh [set-viewer-tools "<csv>"]   (the optional form is used by test 7)
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$IDC_REGION; S=$IDENTITY_STORE_ID
TAG="[rsidc-rbac]"
gid() { aws identitystore list-groups --region $R --identity-store-id $S --filters AttributePath=DisplayName,AttributeValue=$1 --query 'Groups[0].GroupId' --output text; }
uid() { aws identitystore get-user-id --region $R --identity-store-id $S --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"emails.value\",\"AttributeValue\":\"$1\"}}" --query UserId --output text; }
ensure_group() {  # $1 name, $2 tools csv. Creates the group, or updates its Description only if it is ours.
  local g; g=$(gid $1)
  if [ "$g" = None ]; then
    aws identitystore create-group --region $R --identity-store-id $S --display-name $1 --description "$TAG tools=$2" >/dev/null
  else
    local d; d=$(aws identitystore describe-group --region $R --identity-store-id $S --group-id $g --query Description --output text)
    case "$d" in "$TAG"*) ;; *) echo "REFUSING: $1 exists and its Description is not ours: $d" >&2; exit 1;; esac
    aws identitystore update-group --region $R --identity-store-id $S --group-id $g \
      --operations "[{\"AttributePath\":\"description\",\"AttributeValue\":\"$TAG tools=$2\"}]"
  fi
}
member() {  # $1 group name, $2 email (idempotent)
  aws identitystore create-group-membership --region $R --identity-store-id $S --group-id $(gid $1) --member-id UserId=$(uid $2) >/dev/null 2>&1 || true
}
if [ "${1:-}" = set-viewer-tools ]; then ensure_group ${PROJECT}-gw-viewer "$2"; else
  ensure_group ${PROJECT}-gw-analyst Tools.Sales.Read,Tools.CRM.Read   # user1 (wei): tool A + tool B
  ensure_group ${PROJECT}-gw-viewer Tools.Sales.Read                   # user2 (ds1): tool A only
  member ${PROJECT}-gw-analyst wei@techfinance.example.com
  member ${PROJECT}-gw-viewer "${DS1_EMAIL:-ds1@techfinance.example.com}"                      # ds1 email in Cognito and IdC (set DS1_EMAIL)
fi
for g in ${PROJECT}-gw-analyst ${PROJECT}-gw-viewer; do
  id=$(gid $g); d=$(aws identitystore describe-group --region $R --identity-store-id $S --group-id $id --query Description --output text)
  m=$(aws identitystore list-group-memberships --region $R --identity-store-id $S --group-id $id --query 'GroupMemberships[].MemberId.UserId' --output text)
  echo "$g ($id): $d | members: $m"
done
