"""AgentCore Gateway Lambda targets for the RBAC test (Gateway tool RBAC, demo version). One code base, two functions:
TOOL=sales -> get_sales_summary (region aggregates, no PII); TOOL=crm -> get_customer_contacts (customer emails, PII).
Runs on Redshift as the shared service user svc_reporting. Authorization happens at the Gateway (Cedar), not here."""
import os, threading, time, boto3

rsd = boto3.client("redshift-data", region_name=os.environ["REDSHIFT_REGION"])
SQL = {
    "sales": "SELECT region, COUNT(*) AS orders, SUM(amount) AS total_amount FROM sales.orders GROUP BY region ORDER BY region",
    "crm": "SELECT order_id, customer_email FROM sales.orders ORDER BY order_id",
}[os.environ["TOOL"]]


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
