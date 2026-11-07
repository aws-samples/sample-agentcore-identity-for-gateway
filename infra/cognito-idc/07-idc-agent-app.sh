#!/usr/bin/env bash
# Customer-managed IdC application for the agent (trusted identity propagation for custom apps):
#   caller JWT --(sso-oauth:CreateTokenWithIAM, jwt-bearer, once)--> IdC access token (reusable ~1h)
#   IdC access token --(token_type=ACCESS_TOKEN)--> Redshift as AWSIDC:<user>
# Only the AgentCore runtime role may perform the exchange (ActorPolicy), and only for assigned groups.
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$IDC_REGION
if [ -z "${AGENT_IDC_APP_ARN:-}" ]; then
  save AGENT_IDC_APP_ARN $(aws sso-admin create-application --region $R --instance-arn $IDC_INSTANCE_ARN \
    --application-provider-arn arn:aws:sso::aws:applicationProvider/custom --name ${PROJECT}-data-agent \
    --description "AgentCore data agent - TIP to Redshift" --portal-options Visibility=DISABLED \
    --query ApplicationArn --output text)
fi
aws sso-admin put-application-grant --region $R --application-arn $AGENT_IDC_APP_ARN \
  --grant-type urn:ietf:params:oauth:grant-type:jwt-bearer \
  --grant "{\"JwtBearer\":{\"AuthorizedTokenIssuers\":[{\"TrustedTokenIssuerArn\":\"$TTI_ARN\",\"AuthorizedAudiences\":[\"$COGNITO_CLIENT_ID\"]}]}}"
aws sso-admin put-application-authentication-method --region $R --application-arn $AGENT_IDC_APP_ARN \
  --authentication-method-type IAM \
  --authentication-method "{\"Iam\":{\"ActorPolicy\":{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"$RT_ROLE_ARN\"},\"Action\":\"sso-oauth:CreateTokenWithIAM\",\"Resource\":\"$AGENT_IDC_APP_ARN\"},{\"Sid\":\"DenyEveryoneElseIncludingAdmins\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"sso-oauth:CreateTokenWithIAM\",\"Resource\":\"$AGENT_IDC_APP_ARN\",\"Condition\":{\"ArnNotEquals\":{\"aws:PrincipalArn\":\"$RT_ROLE_ARN\"}}}]}}}"
# ^ explicit Deny: same-account IAM admins with sso-oauth:* would otherwise be able to exchange users' JWTs.
aws sso-admin put-application-access-scope --region $R --application-arn $AGENT_IDC_APP_ARN --scope redshift:connect
aws sso-admin put-application-assignment-configuration --region $R --application-arn $AGENT_IDC_APP_ARN --assignment-required
for g in risk-team marketing-team platform-team data-scientists; do
  gid=$(aws identitystore get-group-id --region $R --identity-store-id $IDENTITY_STORE_ID --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"displayName\",\"AttributeValue\":\"$g\"}}" --query GroupId --output text)
  aws sso-admin create-application-assignment --region $R --application-arn $AGENT_IDC_APP_ARN --principal-id $gid --principal-type GROUP 2>/dev/null || true
done
# Runtime role may call CreateTokenWithIAM on this one app only.
aws iam put-role-policy --role-name ${RT_ROLE_ARN##*/} --policy-name idc-token-exchange --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sso-oauth:CreateTokenWithIAM\",\"Resource\":\"$AGENT_IDC_APP_ARN\"}]}"
aws sso-admin list-application-access-scopes --region $R --application-arn $AGENT_IDC_APP_ARN --query 'Scopes[].Scope'
aws sso-admin list-application-grants --region $R --application-arn $AGENT_IDC_APP_ARN --query 'Grants[].Grant.JwtBearer'
aws sso-admin list-application-assignments --region $R --application-arn $AGENT_IDC_APP_ARN --query 'length(ApplicationAssignments)'
