"""Enable browser sign-in (Cognito managed login, authorization code + PKCE) on the EXISTING OBO app client,
so the ID token keeps the same audience the runtime authorizer and IdC TTI already trust. Nothing else changes.
UpdateUserPoolClient resets omitted fields, so the full current config is copied back; before/after diff printed."""
import os, boto3
idp = boto3.Session().client("cognito-idp", region_name=os.environ["RT_REGION"])
pool, cid = os.environ["COGNITO_POOL_ID"], os.environ["COGNITO_CLIENT_ID"]
CALLBACKS = ["http://localhost:8080/callback", "http://localhost:8081/callback"]   # 8080 = OBO GUI, 8081 = 2LO/3LO GUI
LOGOUTS = ["http://localhost:8080/", "http://localhost:8081/"]
WEB = os.environ.get("WEBCHAT_URLS", "").split()  # deployed GUIs (API Gateway HTTP API URLs), set by infra/cognito-idc/14-deploy-webchat.sh
CALLBACKS += [f"{u}/callback" for u in WEB]; LOGOUTS += [f"{u}/" for u in WEB]
WRITE_ATTRS = ["name", "given_name", "family_name"]  # deliberately excludes email
before = idp.describe_user_pool_client(UserPoolId=pool, ClientId=cid)["UserPoolClient"]
keep = ("ClientName", "RefreshTokenValidity", "AccessTokenValidity", "IdTokenValidity", "TokenValidityUnits", "ExplicitAuthFlows",
        "SupportedIdentityProviders", "CallbackURLs", "LogoutURLs", "AllowedOAuthFlows", "AllowedOAuthScopes",
        "AllowedOAuthFlowsUserPoolClient", "PreventUserExistenceErrors", "EnableTokenRevocation",
        "EnablePropagateAdditionalUserContextData", "AuthSessionValidity", "ReadAttributes", "WriteAttributes")
upd = {k: before[k] for k in keep if k in before}
# F-01: users must not be able to rewrite `email` (IdC TTI + pre-token RBAC key off it)
upd.update(ReadAttributes=sorted(set(before.get("ReadAttributes", [])) | {"email", "email_verified"}), WriteAttributes=WRITE_ATTRS)
upd.update(SupportedIdentityProviders=["COGNITO"], CallbackURLs=sorted(set(before.get("CallbackURLs", []) + CALLBACKS)),
           LogoutURLs=sorted(set(before.get("LogoutURLs", []) + LOGOUTS)), AllowedOAuthFlows=["code"],
           AllowedOAuthScopes=["openid", "email", "profile"], AllowedOAuthFlowsUserPoolClient=True)
idp.update_user_pool_client(UserPoolId=pool, ClientId=cid, **upd)
after = idp.describe_user_pool_client(UserPoolId=pool, ClientId=cid)["UserPoolClient"]
for k in sorted(set(before) | set(after)):
    if k not in ("LastModifiedDate",) and before.get(k) != after.get(k):
        print(f"changed {k}: {before.get(k)} -> {after.get(k)}")
try:
    idp.describe_managed_login_branding_by_client(UserPoolId=pool, ClientId=cid)
except idp.exceptions.ResourceNotFoundException:
    idp.create_managed_login_branding(UserPoolId=pool, ClientId=cid, UseCognitoProvidedValues=True); print("managed login branding created")
