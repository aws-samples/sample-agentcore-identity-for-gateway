"""AgentCore Identity outbound credential providers (CustomOauth2 -> Cognito):
  rsidc-2lo-cognito : M2M / client_credentials (agent acts as itself)
  rsidc-3lo-cognito : USER_FEDERATION / authorization code (user consents; token kept in the Token Vault per agent+user)
Client secrets are read from Cognito and handed straight to AgentCore Identity (stored in its Secrets Manager vault), never printed.
Then sets the 3LO Cognito client's callback URL to the provider's AgentCore callback (copying the full client config,
because UpdateUserPoolClient resets omitted fields)."""
import os, subprocess, boto3  # nosec B404 -- fixed-argv bash call only

S = boto3.Session(); R = os.environ["RT_REGION"]
idp = S.client("cognito-idp", region_name=R); ac = S.client("bedrock-agentcore-control", region_name=R)
pool = os.environ["COGNITO_POOL_ID"]

def save(k, v):
    # Static script; k/v are passed as positional args ($1/$2), never interpolated into shell source.
    # List argv with fixed executable "bash", no shell=True.
    subprocess.run(["bash", "-c", 'source infra/common/00-config.sh >/dev/null; save "$1" "$2"', "_", k, v], check=True)  # nosec B603  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit

def provider(name, client_id):
    secret = idp.describe_user_pool_client(UserPoolId=pool, ClientId=client_id)["UserPoolClient"]["ClientSecret"]
    cfg = {"customOauth2ProviderConfig": {"oauthDiscovery": {"discoveryUrl": os.environ["COGNITO_DISCOVERY_URL"]},
                                          "clientId": client_id, "clientSecret": secret}}
    try:
        r = ac.create_oauth2_credential_provider(name=name, credentialProviderVendor="CustomOauth2", oauth2ProviderConfigInput=cfg)
    except ac.exceptions.ValidationException as e:
        if "already exists" not in str(e): raise
        r = ac.update_oauth2_credential_provider(name=name, credentialProviderVendor="CustomOauth2", oauth2ProviderConfigInput=cfg)
    print(f"{name}: arn={r['credentialProviderArn']}\n  callbackUrl={r.get('callbackUrl')}\n  secret={r['clientSecretArn']['secretArn']}")
    return r

p2 = provider("rsidc-2lo-cognito", os.environ["C2LO_CLIENT_ID"])
p3 = provider("rsidc-3lo-cognito", os.environ["C3LO_CLIENT_ID"])
save("CP2LO_ARN", p2["credentialProviderArn"]); save("CP3LO_ARN", p3["credentialProviderArn"])
save("CP2LO_SECRET_ARN", p2["clientSecretArn"]["secretArn"]); save("CP3LO_SECRET_ARN", p3["clientSecretArn"]["secretArn"])

c = idp.describe_user_pool_client(UserPoolId=pool, ClientId=os.environ["C3LO_CLIENT_ID"])["UserPoolClient"]
upd = {k: c[k] for k in ("ClientName", "RefreshTokenValidity", "AccessTokenValidity", "IdTokenValidity", "TokenValidityUnits",
       "ExplicitAuthFlows", "SupportedIdentityProviders", "AllowedOAuthFlows", "AllowedOAuthScopes",
       "AllowedOAuthFlowsUserPoolClient", "PreventUserExistenceErrors", "EnableTokenRevocation",
       "EnablePropagateAdditionalUserContextData", "AuthSessionValidity", "ReadAttributes", "WriteAttributes") if k in c}  # copy all, or UpdateUserPoolClient resets them
upd["CallbackURLs"] = [p3["callbackUrl"]]
upd["WriteAttributes"] = ["name", "given_name", "family_name"]  # email stays admin-only (see 17-harden-cognito-email.py)
idp.update_user_pool_client(UserPoolId=pool, ClientId=c["ClientId"], **upd)
after = idp.describe_user_pool_client(UserPoolId=pool, ClientId=c["ClientId"])["UserPoolClient"]
print("3LO client callback ->", after["CallbackURLs"], "| flows", after["AllowedOAuthFlows"], after["AllowedOAuthScopes"])
