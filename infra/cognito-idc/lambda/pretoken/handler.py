"""Cognito Pre Token Generation V2 trigger (Gateway tool RBAC, demo and customer versions).
The group -> tool mapping lives in the Description of the user's groups, e.g. "[rsidc-rbac] tools=Tools.Sales.Read".
Sources (env ROLE_SOURCES, comma-separated, union of all):
  cognito : the user's Cognito groups (event groupConfiguration) -> GetGroup Description   (customer version)
  idc     : the user's IAM Identity Center groups, looked up by email -> DescribeGroup     (demo version)
The union is written to the ACCESS token as an Entra-style `roles` claim, which the Gateway's Cedar policies match.
Fail closed: any Identity Store error raises, so Cognito fails the sign-in rather than issuing a token without `roles`.
A user who is not in IdC, or whose groups have no mapping, gets roles=[] (all tools denied)."""
import os, re, boto3

SOURCES = set(os.environ.get("ROLE_SOURCES", "idc").split(","))
ids = boto3.client("identitystore", region_name=os.environ["IDC_REGION"])
STORE = os.environ["IDENTITY_STORE_ID"]
idp = boto3.client("cognito-idp")
MAPPING = re.compile(r"\[rsidc-rbac\]\s*tools=([\w.,]+)")


def parse(desc):
    hit = MAPPING.search(desc or "")
    return {t for t in hit.group(1).split(",") if t} if hit else set()


def cognito_roles(pool_id, groups):
    roles = set()
    for g in groups:
        roles |= parse(idp.get_group(UserPoolId=pool_id, GroupName=g)["Group"].get("Description"))
    return roles


def roles_for(email):
    try:
        uid = ids.get_user_id(IdentityStoreId=STORE, AlternateIdentifier={
            "UniqueAttribute": {"AttributePath": "emails.value", "AttributeValue": email}})["UserId"]
    except ids.exceptions.ResourceNotFoundException:
        return set()
    roles = set()
    for page in ids.get_paginator("list_group_memberships_for_member").paginate(IdentityStoreId=STORE, MemberId={"UserId": uid}):
        for m in page["GroupMemberships"]:
            roles |= parse(ids.describe_group(IdentityStoreId=STORE, GroupId=m["GroupId"]).get("Description"))
    return roles


def handler(event, _context):
    roles = set()
    if "cognito" in SOURCES:
        groups = (event["request"].get("groupConfiguration") or {}).get("groupsToOverride") or []
        roles |= cognito_roles(event["userPoolId"], groups)
    attrs = event["request"]["userAttributes"]
    email = attrs.get("email", "")
    # Fail closed: an unverified email must never select an IdC identity (F-01). Log the reason, never the address.
    verified = str(attrs.get("email_verified", "")).lower() == "true"
    if "idc" in SOURCES and email and not verified:
        print(f"user={event.get('userName')} idc roles skipped: email_verified is not true")
    elif "idc" in SOURCES and email:
        roles |= roles_for(email)
    roles = sorted(roles)
    print(f"user={event.get('userName')} trigger={event.get('triggerSource')} roles={roles}")
    event["response"]["claimsAndScopeOverrideDetails"] = {
        "accessTokenGeneration": {"claimsToAddOrOverride": {"roles": roles}}}
    return event
