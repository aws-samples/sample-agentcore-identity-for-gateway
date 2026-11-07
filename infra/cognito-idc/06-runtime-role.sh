#!/usr/bin/env bash
# AgentCore Runtime execution role. Deliberately has NO Redshift permissions: the only way to reach
# Redshift is with an end user's identity (token exchange permission is added in step 07).
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
BUCKET=${PROJECT}-artifacts-${ACCOUNT_ID}-${R}
ROLE=${PROJECT}-agent-runtime-role
if ! aws iam get-role --role-name $ROLE >/dev/null 2>&1; then
  aws iam create-role --role-name $ROLE --tags Key=Project,Value=${PROJECT} --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"bedrock-agentcore.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT_ID}\"},\"ArnLike\":{\"aws:SourceArn\":\"arn:aws:bedrock-agentcore:${R}:${ACCOUNT_ID}:*\"}}}]}" >/dev/null
  sleep 10
fi
sed -e "s/__REGION__/$R/g" -e "s/__ACCOUNT__/$ACCOUNT_ID/g" -e "s/__BUCKET__/$BUCKET/g" "$ROOT/infra/cognito-idc/policies/agent-runtime-permissions.json" > /tmp/${ROLE}.json
aws iam put-role-policy --role-name $ROLE --policy-name agent-runtime --policy-document file:///tmp/${ROLE}.json
save RT_ROLE_ARN arn:aws:iam::${ACCOUNT_ID}:role/$ROLE

