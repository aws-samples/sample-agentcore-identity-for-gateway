-- Run as the Redshift admin (rsadmin). Grants target IdC GROUP roles only (AWSIDC:<group>).
CREATE SCHEMA IF NOT EXISTS sales;
CREATE SCHEMA IF NOT EXISTS marketing;
CREATE SCHEMA IF NOT EXISTS risk;

DROP TABLE IF EXISTS sales.orders;
CREATE TABLE sales.orders (order_id INT, region VARCHAR(16), customer_email VARCHAR(128), amount DECIMAL(12,2), order_date DATE);
INSERT INTO sales.orders VALUES
 (1,'APAC','alice@cust.example','1200.00','2026-09-01'),
 (2,'APAC','bob@cust.example','560.50','2026-09-03'),
 (3,'EMEA','carol@cust.example','980.00','2026-09-05'),
 (4,'AMER','dave@cust.example','2300.00','2026-09-07'),
 (5,'EMEA','erin@cust.example','150.25','2026-09-09');

DROP TABLE IF EXISTS marketing.campaigns;
CREATE TABLE marketing.campaigns (campaign_id INT, name VARCHAR(64), budget DECIMAL(12,2), status VARCHAR(16));
INSERT INTO marketing.campaigns VALUES (1,'Mid-Autumn Promo',50000,'ACTIVE'),(2,'Double 11',120000,'PLANNED');

DROP TABLE IF EXISTS risk.credit_limits;
CREATE TABLE risk.credit_limits (customer_email VARCHAR(128), credit_limit DECIMAL(12,2), risk_score INT);
INSERT INTO risk.credit_limits VALUES ('alice@cust.example',10000,720),('carol@cust.example',5000,640);

-- IdC groups surface in Redshift as roles in the AWSIDC namespace.
CREATE ROLE "AWSIDC:risk-team";
CREATE ROLE "AWSIDC:marketing-team";
CREATE ROLE "AWSIDC:platform-team";
CREATE ROLE "AWSIDC:data-scientists";

-- risk-team: owns risk data (read/write), can read all sales rows
GRANT USAGE ON SCHEMA risk, sales TO ROLE "AWSIDC:risk-team";
GRANT SELECT, INSERT, UPDATE ON risk.credit_limits TO ROLE "AWSIDC:risk-team";
GRANT SELECT ON sales.orders TO ROLE "AWSIDC:risk-team";

-- marketing-team: read/update campaigns; sales only non-PII columns (column-level grant)
GRANT USAGE ON SCHEMA marketing, sales TO ROLE "AWSIDC:marketing-team";
GRANT SELECT, UPDATE ON marketing.campaigns TO ROLE "AWSIDC:marketing-team";
GRANT SELECT (order_id, region, amount, order_date) ON sales.orders TO ROLE "AWSIDC:marketing-team";

-- platform-team: read-only everywhere
GRANT USAGE ON SCHEMA sales, marketing, risk TO ROLE "AWSIDC:platform-team";
GRANT SELECT ON sales.orders, marketing.campaigns, risk.credit_limits TO ROLE "AWSIDC:platform-team";

-- data-scientists: intentionally no grants (authenticated != authorized)

-- Row-level security on sales.orders: marketing sees APAC only; others see all rows.
CREATE RLS POLICY rls_apac_only WITH (region VARCHAR(16)) USING (region = 'APAC');
CREATE RLS POLICY rls_all_rows USING (true);
ATTACH RLS POLICY rls_apac_only ON sales.orders TO ROLE "AWSIDC:marketing-team";
ATTACH RLS POLICY rls_all_rows ON sales.orders TO ROLE "AWSIDC:risk-team", ROLE "AWSIDC:platform-team";
ALTER TABLE sales.orders ROW LEVEL SECURITY ON;
