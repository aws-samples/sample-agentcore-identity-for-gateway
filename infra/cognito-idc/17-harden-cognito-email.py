"""F-01 hardening for an EXISTING deployment: users must not be able to rewrite their own `email`
(IdC trusted-token-issuer mapping, pre-token RBAC and the 3LO identity check all key off it). Idempotent.
  1) user pool: AttributesRequireVerificationBeforeUpdate=[email]  (UpdateUserPool resets omitted fields -> full read-modify-write)
  2) every app client: WriteAttributes excludes email, ReadAttributes keeps email/email_verified (same full-config copy)
Before/after diffs are printed; the pool's AllowAdminCreateUserOnly is asserted to stay true."""
import os, boto3
idp = boto3.Session().client("cognito-idp", region_name=os.environ["RT_REGION"])
POOL = os.environ["COGNITO_POOL_ID"]
WRITE = ["name", "given_name", "family_name"]
READ = ["email", "email_verified"] + WRITE


def show(before, after, skip=("LastModifiedDate", "EstimatedNumberOfUsers", "ClientSecret")):
    for k in sorted(set(before) | set(after)):
        if k not in skip and before.get(k) != after.get(k):
            print(f"  changed {k}: {before.get(k)} -> {after.get(k)}")


# 1) user pool
before = idp.describe_user_pool(UserPoolId=POOL)["UserPool"]
fields = idp.meta.service_model.operation_model("UpdateUserPool").input_shape.members
params = {k: v for k, v in before.items() if k in fields}
params.update(UserPoolId=POOL, PoolName=before["Name"], UserPoolTags=before.get("UserPoolTags", {}))
acu = dict(before.get("AdminCreateUserConfig", {})); acu.pop("UnusedAccountValidityDays", None)
acu["AllowAdminCreateUserOnly"] = True; params["AdminCreateUserConfig"] = acu
params["UserAttributeUpdateSettings"] = {"AttributesRequireVerificationBeforeUpdate": ["email"]}
if "email" not in before.get("AutoVerifiedAttributes", []):  # the setting only works with email auto-verification
    params["AutoVerifiedAttributes"] = sorted(set(before.get("AutoVerifiedAttributes", [])) | {"email"})
print("user pool", POOL)
idp.update_user_pool(**params)
after = idp.describe_user_pool(UserPoolId=POOL)["UserPool"]
show(before, after)
assert after["AdminCreateUserConfig"]["AllowAdminCreateUserOnly"] is True

# 2) app clients
KEEP = ("ClientName", "RefreshTokenValidity", "AccessTokenValidity", "IdTokenValidity", "TokenValidityUnits", "ExplicitAuthFlows",
        "SupportedIdentityProviders", "CallbackURLs", "LogoutURLs", "DefaultRedirectURI", "AllowedOAuthFlows", "AllowedOAuthScopes",
        "AllowedOAuthFlowsUserPoolClient", "PreventUserExistenceErrors", "EnableTokenRevocation",
        "EnablePropagateAdditionalUserContextData", "AuthSessionValidity", "AnalyticsConfiguration")
for var in ("COGNITO_CLIENT_ID", "C2LO_CLIENT_ID", "C3LO_CLIENT_ID", "QUICK_CLIENT_ID"):
    cid = os.environ.get(var)
    if not cid:
        continue
    c = idp.describe_user_pool_client(UserPoolId=POOL, ClientId=cid)["UserPoolClient"]
    upd = {k: c[k] for k in KEEP if k in c}
    upd.update(ReadAttributes=sorted(set(c.get("ReadAttributes", [])) | set(READ)), WriteAttributes=WRITE)
    print(f"client {var} {c['ClientName']}")
    idp.update_user_pool_client(UserPoolId=POOL, ClientId=cid, **upd)
    show(c, idp.describe_user_pool_client(UserPoolId=POOL, ClientId=cid)["UserPoolClient"])
