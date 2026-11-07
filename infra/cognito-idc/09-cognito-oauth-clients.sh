#!/usr/bin/env bash
# Adds OAuth clients to the EXISTING Cognito pool for the 2LO / 3LO test cases (the OBO client is untouched):
#   - hosted (managed) login domain, needed for the 3LO authorization-code flow
#   - resource server rsidc-reports with scope "read"            -> 2LO (client_credentials)
#   - rsidc-2lo-agent : confidential client, client_credentials only (the AGENT's own identity)
#   - rsidc-3lo-agent : confidential client, authorization code only (USER-delegated); callback set in step 10
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION; P=$COGNITO_POOL_ID
DOMAIN=${PROJECT}-${ACCOUNT_ID}
aws cognito-idp describe-user-pool-domain --region $R --domain $DOMAIN --query 'DomainDescription.Status' --output text 2>/dev/null | grep -q ACTIVE \
  || aws cognito-idp create-user-pool-domain --region $R --user-pool-id $P --domain $DOMAIN >/dev/null
save COGNITO_DOMAIN https://${DOMAIN}.auth.${R}.amazoncognito.com
aws cognito-idp describe-resource-server --region $R --user-pool-id $P --identifier rsidc-reports >/dev/null 2>&1 \
  || aws cognito-idp create-resource-server --region $R --user-pool-id $P --identifier rsidc-reports --name "rsidc reporting API" --scopes ScopeName=read,ScopeDescription="read reports" >/dev/null
if [ -z "${C2LO_CLIENT_ID:-}" ]; then
  save C2LO_CLIENT_ID $(aws cognito-idp create-user-pool-client --region $R --user-pool-id $P --client-name ${PROJECT}-2lo-agent \
    --generate-secret --allowed-o-auth-flows client_credentials --allowed-o-auth-scopes rsidc-reports/read \
    --allowed-o-auth-flows-user-pool-client --read-attributes email email_verified --write-attributes name given_name family_name --access-token-validity 60 --token-validity-units AccessToken=minutes \
    --query UserPoolClient.ClientId --output text)
fi
if [ -z "${C3LO_CLIENT_ID:-}" ]; then
  save C3LO_CLIENT_ID $(aws cognito-idp create-user-pool-client --region $R --user-pool-id $P --client-name ${PROJECT}-3lo-agent \
    --generate-secret --allowed-o-auth-flows code --allowed-o-auth-scopes openid email profile \
    --allowed-o-auth-flows-user-pool-client --read-attributes email email_verified --write-attributes name given_name family_name --supported-identity-providers COGNITO \
    --callback-urls https://example.invalid/placeholder --explicit-auth-flows ALLOW_REFRESH_TOKEN_AUTH \
    --query UserPoolClient.ClientId --output text)
fi
# Managed login v2: required for the OIDC `prompt=login` parameter (the classic hosted UI, v1, ignores it).
aws cognito-idp update-user-pool-domain --region $R --user-pool-id $P --domain $DOMAIN --managed-login-version 2 >/dev/null
aws cognito-idp describe-managed-login-branding-by-client --region $R --user-pool-id $P --client-id $C3LO_CLIENT_ID >/dev/null 2>&1 \
  || aws cognito-idp create-managed-login-branding --region $R --user-pool-id $P --client-id $C3LO_CLIENT_ID --use-cognito-provided-values >/dev/null
for c in $C2LO_CLIENT_ID $C3LO_CLIENT_ID; do
  aws cognito-idp describe-user-pool-client --region $R --user-pool-id $P --client-id $c --query 'UserPoolClient.[ClientName,AllowedOAuthFlows,AllowedOAuthScopes]' --output text
done
curl -s $COGNITO_DISCOVERY_URL | python3 -c 'import json,sys;d=json.load(sys.stdin);print({k:d.get(k) for k in ("authorization_endpoint","token_endpoint","userinfo_endpoint")})'
