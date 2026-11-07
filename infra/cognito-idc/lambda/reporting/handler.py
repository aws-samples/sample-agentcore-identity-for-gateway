"""AgentCore Gateway Lambda target for the 2LO test: runs a fixed report on Redshift as the shared
service user svc_reporting (Redshift Data API + GetClusterCredentials). The caller's identity is NOT propagated."""
import json, os, threading, time, boto3

rsd = boto3.client("redshift-data", region_name=os.environ["REDSHIFT_REGION"])
SQL = "SELECT TRIM(current_user) AS redshift_user, order_id, region, customer_email, amount FROM sales.orders ORDER BY order_id"


def _wait_statement(statement_id, deadline_s=25):
    """Poll DescribeStatement until the statement is terminal. The Redshift Data API has no waiter, so poll with capped
    exponential backoff and a deadline (< the 30 s function timeout). Event.wait is an interruptible timer, not a blind sleep."""
    timer, delay, end = threading.Event(), 0.1, time.monotonic() + deadline_s
    while time.monotonic() < end:
        d = rsd.describe_statement(Id=statement_id)
        if d["Status"] in ("FINISHED", "FAILED", "ABORTED"):
            return d
        timer.wait(delay)
        delay = min(delay * 2, 2)
    raise TimeoutError(f"statement {statement_id} not finished after {deadline_s}s")


def handler(event, context):
    tool = (context.client_context.custom or {}).get("bedrockAgentCoreToolName", "") if context.client_context else ""
    r = rsd.execute_statement(ClusterIdentifier=os.environ["REDSHIFT_CLUSTER_ID"], Database=os.environ["REDSHIFT_DB"],
                              DbUser="svc_reporting", Sql=SQL)
    d = _wait_statement(r["Id"])
    if d["Status"] != "FINISHED":
        return {"tool": tool, "error": d.get("Error")}
    res = rsd.get_statement_result(Id=r["Id"])
    cols = [c["name"] for c in res["ColumnMetadata"]]
    rows = [[next(iter(v.values())) for v in rec] for rec in res["Records"]]
    return {"tool": tool, "columns": cols, "rows": rows}
