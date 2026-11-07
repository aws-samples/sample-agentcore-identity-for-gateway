"""Seed tables + IdC-group grants as the Redshift admin via the Data API (admin secret from Secrets Manager).
The Data API is IAM-authenticated and does not traverse the cluster security group; it is used ONLY for admin setup."""
import os, sys, threading, time, boto3

rs = boto3.Session().client("redshift-data", region_name=os.environ["IDC_REGION"])
with open(os.path.join(os.path.dirname(__file__), "sql", sys.argv[1] if len(sys.argv) > 1 else "01-seed-and-grants.sql"), encoding="utf-8") as f:
    sql = f.read()


def wait_statement(statement_id, deadline_s=300):
    """Poll DescribeStatement until terminal (the Data API has no waiter): capped exponential backoff and a deadline.
    Event.wait is an interruptible timer, not a blind sleep."""
    timer, delay, end = threading.Event(), 0.5, time.monotonic() + deadline_s
    while time.monotonic() < end:
        d = rs.describe_statement(Id=statement_id)
        if d["Status"] in ("FINISHED", "FAILED", "ABORTED"):
            return d
        timer.wait(delay)
        delay = min(delay * 2, 5)
    raise TimeoutError(f"statement {statement_id} not finished after {deadline_s}s")


stmts = [s.strip() for s in "\n".join(l for l in sql.splitlines() if not l.strip().startswith("--")).split(";") if s.strip()]
for s in stmts:
    r = rs.execute_statement(ClusterIdentifier=os.environ["REDSHIFT_CLUSTER_ID"], Database=os.environ["REDSHIFT_DB"],
                             SecretArn=os.environ["REDSHIFT_ADMIN_SECRET_ARN"], Sql=s)
    d = wait_statement(r["Id"])
    status = d["Status"] if d["Status"] == "FINISHED" else f'{d["Status"]}: {d.get("Error")}'
    print(f"[{status}] {s.splitlines()[0][:90]}")
    if d["Status"] != "FINISHED" and "already" not in str(d.get("Error")):
        sys.exit(1)
