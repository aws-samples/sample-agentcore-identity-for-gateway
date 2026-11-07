"""Set AllowAdminCreateUserOnly=true on Cognito user pools that still allow self sign-up.

Safe by default: it only PRINTS what it would change (dry run). Pass --apply to make changes.
Scope by default: pools whose name starts with "$PROJECT-" (default rsidc-) in the Region(s) given by
--regions (default: $RT_REGION). Widening the scope is explicit: --all-pools (any pool name) and
--all-regions (every enabled Region). UpdateUserPool resets omitted settings to defaults, so the full
current config is copied back and only AdminCreateUserConfig.AllowAdminCreateUserOnly changes; a
before/after diff is printed per pool.

  python3 infra/cognito-idc/ops/cognito-disable-self-signup.py                 # dry run, project pools
  python3 infra/cognito-idc/ops/cognito-disable-self-signup.py --apply         # change project pools
"""
import argparse, json, os, boto3

ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
ap.add_argument("--apply", action="store_true", help="make the changes (default: dry run)")
ap.add_argument("--regions", default=os.environ.get("RT_REGION", "ap-southeast-1"), help="comma-separated Regions")
ap.add_argument("--all-regions", action="store_true", help="every Region enabled for the account")
ap.add_argument("--name-prefix", default=os.environ.get("PROJECT", "rsidc") + "-", help="only pools whose name starts with this")
ap.add_argument("--all-pools", action="store_true", help="every pool, regardless of name")
args = ap.parse_args()
DRY = not args.apply
s = boto3.Session()
regions = ([r["RegionName"] for r in s.client("ec2", region_name="us-east-1").describe_regions()["Regions"]]
           if args.all_regions else [r.strip() for r in args.regions.split(",") if r.strip()])
print(("DRY RUN (no changes; pass --apply to change)" if DRY else "APPLY") +
      f" | regions={','.join(regions)} | pools={'ALL' if args.all_pools else args.name_prefix + '*'}")
VOLATILE = {"LastModifiedDate", "EstimatedNumberOfUsers"}

def flat(d, p=""):
    out = {}
    for k, v in (d or {}).items():
        out.update(flat(v, f"{p}{k}.") if isinstance(v, dict) else {f"{p}{k}": v})
    return out

for region in regions:
    c = s.client("cognito-idp", region_name=region)
    try:
        pools = [p["Id"] for pg in c.get_paginator("list_user_pools").paginate(MaxResults=60) for p in pg["UserPools"]
                 if args.all_pools or p["Name"].startswith(args.name_prefix)]
    except Exception as e:  # region not enabled for this account / no access: report and move on
        print(f"skip {region}: {type(e).__name__}")
        continue
    update_fields = c.meta.service_model.operation_model("UpdateUserPool").input_shape.members
    for pid in pools:
        before = c.describe_user_pool(UserPoolId=pid)["UserPool"]
        if before.get("AdminCreateUserConfig", {}).get("AllowAdminCreateUserOnly"):
            continue
        params = {k: v for k, v in before.items() if k in update_fields}
        params["UserPoolId"] = pid
        params["PoolName"] = before["Name"]
        params["UserPoolTags"] = before.get("UserPoolTags", {})
        acu = dict(before.get("AdminCreateUserConfig", {}))
        acu.pop("UnusedAccountValidityDays", None)  # deprecated; conflicts with PasswordPolicy.TemporaryPasswordValidityDays
        acu["AllowAdminCreateUserOnly"] = True
        params["AdminCreateUserConfig"] = acu
        print(f"== {region} {pid} ({before['Name']}) users={before.get('EstimatedNumberOfUsers')}" + (" -> would set AllowAdminCreateUserOnly=true" if DRY else ""))
        if DRY:
            continue
        try:
            c.update_user_pool(**params)
        except Exception as e:
            print(f"   FAILED: {type(e).__name__}: {e}")
            continue
        after = c.describe_user_pool(UserPoolId=pid)["UserPool"]
        b, a = flat(before), flat(after)
        diff = {k: (b.get(k), a.get(k)) for k in set(b) | set(a) if b.get(k) != a.get(k) and k.split(".")[0] not in VOLATILE}
        print("   changed:", json.dumps(diff, default=str))
