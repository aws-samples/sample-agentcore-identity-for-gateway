"""Gateway tool RBAC: deploy the Cognito Pre Token Generation V2 trigger (infra/cognito-idc/lambda/pretoken) and attach it to
the user pool. Cognito calls the alias `live`, never $LATEST: new code goes to $LATEST, is pre-flighted for every pool
user, and only then published and the alias moved. The trigger fails closed, so a broken version on the live path
would block every sign-in (OBO, 3LO, webchat).
UpdateUserPool resets omitted settings, so the full current config is copied back (AdminCreateUserOnly stays true)
and a before/after diff is printed. `--detach` removes only the trigger (teardown)."""
import io, json, os, sys, threading, zipfile, boto3

S = boto3.Session(); R, ACCT = os.environ["RT_REGION"], os.environ["ACCOUNT_ID"]
POOL, PROJECT = os.environ["COGNITO_POOL_ID"], os.environ["PROJECT"]
FN, ROLE = f"{PROJECT}-pretoken-roles", f"{PROJECT}-pretoken-roles-role"
ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
iam, lam, idp = S.client("iam"), S.client("lambda", region_name=R), S.client("cognito-idp", region_name=R)


def flat(d, p=""):
    out = {}
    for k, v in (d or {}).items():
        out.update(flat(v, f"{p}{k}.") if isinstance(v, dict) else {f"{p}{k}": v})
    return out


def deploy_lambda():
    try:
        iam.get_role(RoleName=ROLE)
    except iam.exceptions.NoSuchEntityException:
        iam.create_role(RoleName=ROLE, Tags=[{"Key": "Project", "Value": PROJECT}], AssumeRolePolicyDocument=json.dumps(
            {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]}))
        iam.get_waiter("role_exists").wait(RoleName=ROLE)
    # The identity store belongs to the IdC instance owner (the management account for an org instance run from a delegated admin).
    IDC_ACCT = next(i["OwnerAccountId"] for i in S.client("sso-admin", region_name=os.environ["IDC_REGION"]).list_instances()["Instances"]
                    if i["InstanceArn"] == os.environ["IDC_INSTANCE_ARN"])
    with open(os.path.join(ROOT, "infra/cognito-idc/policies/rbac-pretoken-permissions.json"), encoding="utf-8") as f:
        doc = f.read()
    doc = doc \
        .replace("__IDC_ACCOUNT__", IDC_ACCT).replace("__ACCOUNT__", ACCT).replace("__REGION__", R).replace("__STORE__", os.environ["IDENTITY_STORE_ID"]).replace("__POOL__", POOL)
    iam.put_role_policy(RoleName=ROLE, PolicyName="read-idc-groups", PolicyDocument=doc)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.write(os.path.join(ROOT, "infra/cognito-idc/lambda/pretoken/handler.py"), "handler.py")
    env = {"Variables": {"IDC_REGION": os.environ["IDC_REGION"], "IDENTITY_STORE_ID": os.environ["IDENTITY_STORE_ID"],
                         "ROLE_SOURCES": "cognito,idc"}}  # customer version adds Cognito groups; demo version (IdC) keeps working
    try:
        lam.update_function_code(FunctionName=FN, ZipFile=buf.getvalue())
        lam.get_waiter("function_updated_v2").wait(FunctionName=FN)
        lam.update_function_configuration(FunctionName=FN, Environment=env)
    except lam.exceptions.ResourceNotFoundException:
        for _ in range(6):  # new role may not be assumable yet: IAM propagation has no waiter, so retry the create
            try:
                lam.create_function(FunctionName=FN, Runtime="python3.12", Handler="handler.handler", Timeout=5, MemorySize=256,
                                    Role=f"arn:aws:iam::{ACCT}:role/{ROLE}", Code={"ZipFile": buf.getvalue()}, Environment=env,
                                    Tags={"Project": PROJECT})
                break
            except lam.exceptions.InvalidParameterValueException:
                threading.Event().wait(10)  # fixed interval between create retries (bounded by range(6))
    lam.get_waiter("function_updated_v2").wait(FunctionName=FN)


def promote():
    """Publish the pre-flighted $LATEST and point alias `live` at it; returns the alias ARN used by Cognito."""
    ver = lam.publish_version(FunctionName=FN)["Version"]
    try:
        arn = lam.update_alias(FunctionName=FN, Name="live", FunctionVersion=ver)["AliasArn"]
    except lam.exceptions.ResourceNotFoundException:
        arn = lam.create_alias(FunctionName=FN, Name="live", FunctionVersion=ver)["AliasArn"]
    try:
        lam.add_permission(FunctionName=FN, Qualifier="live", StatementId="cognito-live", Action="lambda:InvokeFunction",
                           Principal="cognito-idp.amazonaws.com", SourceArn=f"arn:aws:cognito-idp:{R}:{ACCT}:userpool/{POOL}")
    except lam.exceptions.ResourceConflictException:
        pass
    print(f"promoted version {ver} -> alias live")
    return arn


def preflight():
    for u in idp.list_users(UserPoolId=POOL)["Users"]:
        email = next((a["Value"] for a in u["Attributes"] if a["Name"] == "email"), "")
        groups = [g["GroupName"] for g in idp.admin_list_groups_for_user(UserPoolId=POOL, Username=u["Username"])["Groups"]]
        ev = {"version": "2", "triggerSource": "TokenGeneration_Authentication", "userName": u["Username"], "userPoolId": POOL,
              "request": {"userAttributes": {"email": email}, "groupConfiguration": {"groupsToOverride": groups}}, "response": {}}
        r = lam.invoke(FunctionName=FN, Payload=json.dumps(ev))
        out = json.loads(r["Payload"].read())
        if r.get("FunctionError"):
            sys.exit(f"pre-flight FAILED for {u['Username']}: {out}  (trigger NOT attached)")
        print(f"pre-flight {u['Username']:6} roles={out['response']['claimsAndScopeOverrideDetails']['accessTokenGeneration']['claimsToAddOrOverride']['roles']}")


def set_trigger(arn):
    before = idp.describe_user_pool(UserPoolId=POOL)["UserPool"]
    fields = idp.meta.service_model.operation_model("UpdateUserPool").input_shape.members
    params = {k: v for k, v in before.items() if k in fields}
    params.update(UserPoolId=POOL, PoolName=before["Name"], UserPoolTags=before.get("UserPoolTags", {}))
    acu = dict(before.get("AdminCreateUserConfig", {})); acu.pop("UnusedAccountValidityDays", None)
    acu["AllowAdminCreateUserOnly"] = True; params["AdminCreateUserConfig"] = acu
    lc = dict(before.get("LambdaConfig", {})); lc.pop("PreTokenGeneration", None); lc.pop("PreTokenGenerationConfig", None)
    if arn:
        lc["PreTokenGenerationConfig"] = {"LambdaVersion": "V2_0", "LambdaArn": arn}
    params["LambdaConfig"] = lc
    idp.update_user_pool(**params)
    after = idp.describe_user_pool(UserPoolId=POOL)["UserPool"]
    b, a = flat(before), flat(after)
    diff = {k: (b.get(k), a.get(k)) for k in set(b) | set(a) if b.get(k) != a.get(k) and k.split(".")[0] not in ("LastModifiedDate", "EstimatedNumberOfUsers")}
    print("UpdateUserPool diff:", json.dumps(diff, default=str))
    assert after["AdminCreateUserConfig"]["AllowAdminCreateUserOnly"] is True


if "--detach" in sys.argv:
    set_trigger(None)
else:
    deploy_lambda(); preflight(); set_trigger(promote())
