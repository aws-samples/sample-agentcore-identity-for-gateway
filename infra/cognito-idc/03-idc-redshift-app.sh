#!/usr/bin/env bash
# Trusted identity propagation: Cognito JWT -> IdC Trusted Token Issuer -> IdC user (by email) -> Redshift (AWSIDC:<user>)
set -euo pipefail; source "$(dirname "$0")/../common/00-config.sh"; R=$IDC_REGION; D="$(dirname "$0")"

if [ -z "${TTI_ARN:-}" ]; then
  save TTI_ARN $(aws sso-admin create-trusted-token-issuer --region $R --instance-arn $IDC_INSTANCE_ARN \
    --name ${PROJECT}-cognito --trusted-token-issuer-type OIDC_JWT \
    --trusted-token-issuer-configuration "OidcJwtConfiguration={IssuerUrl=${COGNITO_ISSUER},ClaimAttributePath=email,IdentityStoreAttributePath=emails.value,JwksRetrievalOption=OPEN_ID_DISCOVERY}" \
    --query TrustedTokenIssuerArn --output text)
fi

ROLE=${PROJECT}-redshift-idc-role
if ! aws iam get-role --role-name $ROLE >/dev/null 2>&1; then
  # confused-deputy guard: aws:SourceAccount = this account; aws:SourceArn = this cluster or this account's Redshift IdC application
  sed -e "s/__ACCOUNT__/$ACCOUNT_ID/g" -e "s/__REGION__/$R/g" -e "s/__CLUSTER__/$REDSHIFT_CLUSTER_ID/g" "$D/policies/redshift-idc-trust.json" > /tmp/$ROLE-trust.json
  aws iam create-role --role-name $ROLE --assume-role-policy-document file:///tmp/$ROLE-trust.json --tags Key=Project,Value=${PROJECT} >/dev/null
  sleep 10
fi
aws iam put-role-policy --role-name $ROLE --policy-name redshift-idc --policy-document file://$D/policies/redshift-idc-permissions.json
save REDSHIFT_IDC_ROLE_ARN arn:aws:iam::${ACCOUNT_ID}:role/$ROLE

if [ -z "${REDSHIFT_IDC_APP_ARN:-}" ]; then
  save REDSHIFT_IDC_APP_ARN $(aws redshift create-redshift-idc-application --region $R \
    --idc-instance-arn $IDC_INSTANCE_ARN --redshift-idc-application-name ${PROJECT}-redshift \
    --identity-namespace $REDSHIFT_NAMESPACE --idc-display-name ${PROJECT}-redshift \
    --iam-role-arn $REDSHIFT_IDC_ROLE_ARN \
    --authorized-token-issuer-list "[{\"TrustedTokenIssuerArn\":\"${TTI_ARN}\",\"AuthorizedAudiencesList\":[\"${COGNITO_CLIENT_ID}\"]}]" \
    --query RedshiftIdcApplication.RedshiftIdcApplicationArn --output text)
fi
save REDSHIFT_IDC_SSO_APP_ARN $(aws redshift describe-redshift-idc-applications --region $R --redshift-idc-application-arn $REDSHIFT_IDC_APP_ARN --query 'RedshiftIdcApplications[0].IdcManagedApplicationArn' --output text)

# Only these IdC groups may use the Redshift app (data-engineers intentionally NOT assigned).
for g in risk-team marketing-team platform-team data-scientists; do
  gid=$(aws identitystore get-group-id --region $R --identity-store-id $IDENTITY_STORE_ID --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"displayName\",\"AttributeValue\":\"$g\"}}" --query GroupId --output text)
  aws sso-admin create-application-assignment --region $R --application-arn $REDSHIFT_IDC_SSO_APP_ARN --principal-id $gid --principal-type GROUP 2>/dev/null || true
done
aws redshift describe-redshift-idc-applications --region $R --redshift-idc-application-arn $REDSHIFT_IDC_APP_ARN --query 'RedshiftIdcApplications[0].{ns:IdentityNamespace,status:IdcOnboardStatus,sso:IdcManagedApplicationArn,tti:AuthorizedTokenIssuerList}'
aws sso-admin list-application-assignments --region $R --application-arn $REDSHIFT_IDC_SSO_APP_ARN --query 'ApplicationAssignments[].PrincipalId' --output text
