#!/usr/bin/env bash
# Cognito = the OIDC IdP that end users sign in to. Its ID token is:
#   (1) validated by AgentCore Runtime inbound auth (AgentCore Identity), and
#   (2) trusted by IAM Identity Center (Trusted Token Issuer) -> mapped to the IdC user by email.
# Users are admin-created only (no self sign-up) and mirror existing IdC users' emails.
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$RT_REGION
USERS_FILE="$ROOT/tests/.users.env"   # local only, chmod 600, gitignored

if [ -z "${COGNITO_POOL_ID:-}" ]; then
  save COGNITO_POOL_ID $(aws cognito-idp create-user-pool --region $R --pool-name ${PROJECT}-users \
    --admin-create-user-config AllowAdminCreateUserOnly=true \
    --auto-verified-attributes email --user-attribute-update-settings AttributesRequireVerificationBeforeUpdate=email \
    --policies 'PasswordPolicy={MinimumLength=12,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=false}' \
    --user-pool-tags Project=${PROJECT} --query UserPool.Id --output text)
fi
if [ -z "${COGNITO_CLIENT_ID:-}" ]; then
  save COGNITO_CLIENT_ID $(aws cognito-idp create-user-pool-client --region $R --user-pool-id $COGNITO_POOL_ID \
    --client-name ${PROJECT}-agent-client --no-generate-secret \
    --read-attributes email email_verified name given_name family_name --write-attributes name given_name family_name \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --id-token-validity 60 --access-token-validity 60 --token-validity-units IdToken=minutes,AccessToken=minutes \
    --query UserPoolClient.ClientId --output text)
fi
save COGNITO_ISSUER https://cognito-idp.${R}.amazonaws.com/${COGNITO_POOL_ID}
save COGNITO_DISCOVERY_URL ${COGNITO_ISSUER}/.well-known/openid-configuration

# Test personas (IdC user -> IdC group): wei->risk-team, zhang->marketing-team, chen->platform-team, ds1->data-scientists
mkdir -p "$(dirname "$USERS_FILE")"; touch "$USERS_FILE"; chmod 600 "$USERS_FILE"
for u in wei:wei@techfinance.example.com zhang:zhang@techfinance.example.com chen:chen@techfinance.example.com ds1:${DS1_EMAIL:-ds1@techfinance.example.com}; do
  name=${u%%:*}; email=${u#*:}
  if ! aws cognito-idp admin-get-user --region $R --user-pool-id $COGNITO_POOL_ID --username $name >/dev/null 2>&1; then
    pw="Rs$(openssl rand -hex 8)Aa1"
    aws cognito-idp admin-create-user --region $R --user-pool-id $COGNITO_POOL_ID --username $name \
      --user-attributes Name=email,Value=$email Name=email_verified,Value=true --message-action SUPPRESS >/dev/null
    # password goes via a 0600 temp file (file://), never on argv (visible in ps / shell history)
    pwjson=$(umask 077; mktemp); trap 'rm -f "$pwjson"' EXIT
    printf '{"UserPoolId":"%s","Username":"%s","Password":"%s","Permanent":true}' "$COGNITO_POOL_ID" "$name" "$pw" > "$pwjson"
    aws cognito-idp admin-set-user-password --region $R --cli-input-json "file://$pwjson"
    rm -f "$pwjson"
    sed -i '' "/^PW_${name}=/d" "$USERS_FILE"; echo "PW_${name}=$pw" >> "$USERS_FILE"
  fi
done
aws cognito-idp list-users --region $R --user-pool-id $COGNITO_POOL_ID --query 'Users[].[Username,Attributes[?Name==`email`].Value|[0],UserStatus]' --output table
