"""Redshift access bound to the *calling end user's* identity via IdC trusted identity propagation.

Flow: caller JWT --CreateTokenWithIAM (jwt-bearer, once)--> IdC access token --ACCESS_TOKEN--> Redshift.
Redshift runs the session as AWSIDC:<idc-user>, so every GRANT/RLS rule for that user's IdC groups applies.
The raw JWT is single-use at IdC (jti replay protection), hence the exchange-once-and-cache design.
There is deliberately no service-account fallback.
"""
import hashlib
import os
import threading
import time

import boto3
import redshift_connector

MAX_ROWS = 50
# redshift_connector IdpTokenAuthPlugin token_type enum (kind of token passed), not a secret.
IDC_TOKEN_TYPE = "ACCESS_TOKEN"  # nosec B105 - token type enum, not a secret
_cache: dict = {}  # sha256(caller JWT) -> (idc_access_token, expires_at)
_lock = threading.Lock()


class MissingUserToken(Exception):
    pass


def idc_access_token(user_jwt: str) -> str:
    if not user_jwt:
        # Fail closed: without a token redshift_connector would fall back to the runtime's AWS credentials.
        raise MissingUserToken("No end-user JWT on this request; refusing to connect to Redshift.")
    key = hashlib.sha256(user_jwt.encode()).hexdigest()
    with _lock:
        hit = _cache.get(key)
        if hit and hit[1] - 60 > time.time():
            return hit[0]
        oidc = boto3.client("sso-oidc", region_name=os.environ["IDC_REGION"])
        r = oidc.create_token_with_iam(
            clientId=os.environ["AGENT_IDC_APP_ARN"],
            grantType="urn:ietf:params:oauth:grant-type:jwt-bearer",
            assertion=user_jwt,
        )
        _cache[key] = (r["accessToken"], time.time() + r["expiresIn"])
        return r["accessToken"]


def connect_as_user(user_jwt: str):
    return redshift_connector.connect(
        host=os.environ["REDSHIFT_HOST"],
        port=int(os.environ.get("REDSHIFT_PORT", "5439")),
        database=os.environ.get("REDSHIFT_DB", "dev"),
        credentials_provider="IdpTokenAuthPlugin",
        token=idc_access_token(user_jwt),
        token_type=IDC_TOKEN_TYPE,
        ssl=True,
        timeout=20,
    )


def run_sql(user_jwt: str, sql: str) -> dict:
    """Execute one statement as the end user. Returns rows for queries, rowcount for DML. Errors are returned, not raised."""
    try:
        conn = connect_as_user(user_jwt)
    except Exception as e:  # surfaced to the LLM/caller so denials are visible
        return {"ok": False, "stage": "connect", "error": f"{type(e).__name__}: {e}"}
    try:
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute(sql)
        if cur.description:
            cols = [d[0] for d in cur.description]
            rows = [[str(v) for v in r] for r in cur.fetchmany(MAX_ROWS)]
            return {"ok": True, "columns": cols, "rows": rows}
        return {"ok": True, "rowcount": cur.rowcount}
    except Exception as e:
        return {"ok": False, "stage": "execute", "error": f"{type(e).__name__}: {e}"}
    finally:
        conn.close()
