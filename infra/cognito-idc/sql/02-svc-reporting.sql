-- 2LO test: ONE shared service identity for the reporting tool behind AgentCore Gateway.
-- Deliberately broad (all rows, all columns) like a typical service account, to contrast with per-user OBO.
CREATE USER svc_reporting PASSWORD DISABLE;
GRANT USAGE ON SCHEMA sales TO svc_reporting;
GRANT SELECT ON sales.orders TO svc_reporting;
ATTACH RLS POLICY rls_all_rows ON sales.orders TO svc_reporting;
