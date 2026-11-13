# AML Fraud Detection Engine

## Project overview

This project is an internal bank operations system for detecting and reviewing
suspicious transactions. It is intended for bank compliance staff, not bank
customers. Rows in the MySQL `users` table represent customers whose activity
is monitored; they are not dashboard accounts and do not sign in.

The current project is a development prototype. Its generator creates
synthetic bank activity, and its detector evaluates configured AML rules and
creates alerts. It is not connected to a live bank transaction system.

## How the system works

1. **Transaction data:** MySQL is the source of truth for customers, accounts,
   transactions, alerts, and investigation history.
2. **Detection:** The Python detector checks transactions against configured
   AML rules and stores alerts and their supporting evidence in MySQL.
3. **Analytics:** The detector also mirrors transaction data into ClickHouse
   for analytical use.
4. **Operations API:** The FastAPI backend lets authenticated compliance
   officers review alerts and access the operations data allowed by their
   clearance level.
5. **Dashboard:** The browser dashboard is served by the API at
   `http://localhost:8000`. It is for compliance staff only; there is no
   customer-facing portal or live bank transaction feed in the current stack.

## Who uses the system

All dashboard accounts belong to the bank's compliance team. The database
defines three officer clearance levels:

- **LEVEL_1 — Analyst:** Can see alerts assigned to them, review alert evidence,
  add investigation notes, and move an assigned alert into investigation.
- **LEVEL_2 — Senior analyst:** Can see all alerts and transactions, assign or
  reassign alerts, and clear, escalate, or report alerts.
- **ADMIN — System administrator:** Has alert and transaction access and can
  create officer accounts, change officer clearance levels, and deactivate
  accounts.

All three levels can view the configured detection rules. Rule behavior is
currently defined in code, so rules cannot yet be changed through the API.
There is no public self-registration: bootstrap the first Admin from the
command line, then use the dashboard's **Officer access** page to register
Level 1, Level 2, or additional Admin accounts.

## Run

```bash
docker compose up --build
```

If port 3306 is already in use:

```bash
MYSQL_PORT=3307 docker compose up --build
```

On a clean volume, MySQL executes these files in order:

1. [`scripts/01_schema_oltp.sql`](scripts/01_schema_oltp.sql)
2. [`scripts/02_stored_procedures.sql`](scripts/02_stored_procedures.sql)
3. [`scripts/03_triggers.sql`](scripts/03_triggers.sql)
4. [`scripts/04_functions.sql`](scripts/04_functions.sql)
5. [`scripts/05_views.sql`](scripts/05_views.sql)
6. [`scripts/07_officer_auth.sql`](scripts/07_officer_auth.sql)
7. [`scripts/07_transaction_generation.sql`](scripts/07_transaction_generation.sql)
8. [`scripts/08_seed_data.sql`](scripts/08_seed_data.sql)

The seed file creates deterministic synthetic bank activity and known risk
patterns. Authentication accounts and sessions are intentionally not seeded;
create the first admin login after startup. [`scripts/06_aml_rules.sql`](scripts/06_aml_rules.sql)
contains analytical rule queries and is intentionally not an initialization
script. [`scripts/07_test_cases.sql`](scripts/07_test_cases.sql) remains a
destructive, development-only test script and is intentionally not run by
Docker startup.

ClickHouse creates its transaction mirror from
[`config/clickhouse_init.sql`](config/clickhouse_init.sql).

## Services

- **generator** — Uses the atomic `sp_transfer_funds` procedure, so generated
  transactions update both account balances and transaction/event history. It
  waits for an authorized request from the dashboard before generating a
  1,000-row batch.
- **detector** — Mirrors new MySQL transactions into ClickHouse and runs the
  configured structuring, velocity, pass-through, multi-hop, high-value, and
  high-risk-customer rules. It persists deduplicated alerts and evidence in
  `fraud_alerts` and `fraud_alert_evidence`.
- **api** — Provides alert review, transaction, rule, metrics, and health
  endpoints and serves the dashboard on port 8000. Only compliance officers
  sign in; bank customers in `users` are monitored records and do not have
  dashboard accounts.

The transactions page includes **Generate 1,000 transactions** for Level 2 and
Admin officers. The request is queued for the generator worker; its progress
and result appear in the dashboard. The same worker can also be run manually:

```bash
docker compose run --rm generator \
  python scripts/generator.py --inject-fraud --max-transactions 100
```

Use `--rate` to control transactions per second and `--max-amount` to cap
individual transfers. A transfer rejected for insufficient funds is reported
and retried; the generator stops cleanly when the selected sender has less than
$100 available.

## Backend API

The API is available at `http://localhost:8000`. Interactive OpenAPI
documentation is available at `http://localhost:8000/docs`.

Useful endpoints:

```text
GET   /health
POST  /api/v1/auth/login
GET   /api/v1/auth/me
POST  /api/v1/auth/logout
GET   /api/v1/officers                 (ADMIN)
POST  /api/v1/officers                 (ADMIN)
POST  /api/v1/officers/{officer_id}/account (ADMIN)
PATCH /api/v1/officers/{officer_id}    (ADMIN)
GET   /api/v1/officers/assignable      (LEVEL_2, ADMIN)
GET   /api/v1/alerts
GET   /api/v1/alerts/{alert_id}
PATCH /api/v1/alerts/{alert_id}
POST  /api/v1/alerts/{alert_id}/notes
GET   /api/v1/transactions
POST  /api/v1/transactions/generate    (LEVEL_2, ADMIN)
GET   /api/v1/transactions/generation/latest
GET   /api/v1/transactions/generation/{job_id}
GET   /api/v1/rules
GET   /api/v1/metrics
```

Create the first login for an existing seeded admin officer. The command
prompts for an email and password; it does not use a hard-coded demo password:

```bash
docker compose run --rm api \
  python -m scripts.bootstrap_admin --badge-number SEED-OFF-003
```

Log in and use the returned bearer token for protected endpoints:

```bash
curl -X POST http://localhost:8000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"your-password"}'
```

For protected requests, send `Authorization: Bearer <access_token>`. Review
notes use the authenticated officer identity; clients must not send an
`officer_id`:

```bash
curl -X POST http://localhost:8000/api/v1/alerts/1/notes \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' \
  -d '{"note":"Reviewed transaction timing and counterparties."}'
```

For an existing MySQL volume, initialization scripts will not rerun
automatically. Apply both new support-table scripts once:

```powershell
Get-Content -Raw scripts/07_officer_auth.sql | docker compose exec -T mysql mysql -uaml_user -paml_pass aml_bank_db
Get-Content -Raw scripts/07_transaction_generation.sql | docker compose exec -T mysql mysql -uaml_user -paml_pass aml_bank_db
```

The API stores password hashes (not plaintext passwords), issues revocable
eight-hour bearer sessions, and locks an account for 15 minutes after five
failed login attempts. Set `DASHBOARD_ORIGINS` to the frontend origin(s) when
serving the dashboard from a different host.

## Start from a clean database

Initialization scripts run only when the MySQL volume is empty. Use this after
changing schema or fixture scripts:

```bash
docker compose down -v
docker compose up --build
```

## View generated transactions

```bash
docker compose exec mysql mysql -uaml_user -paml_pass aml_bank_db \
  -e "SELECT transaction_id, sender_account_id, receiver_account_id, amount, transaction_type, status, created_at FROM transactions ORDER BY transaction_id DESC LIMIT 25;"
```

## View flagged transactions and evidence

The durable alert report is the primary query for flagged activity:

```bash
docker compose exec mysql mysql -uaml_user -paml_pass aml_bank_db \
  -e "SELECT alert_id, alert_key, severity, alert_status, rule_code, transaction_id, title, detected_at FROM v_fraud_alert_report ORDER BY detected_at DESC;"
```

To see supporting evidence:

```bash
docker compose exec mysql mysql -uaml_user -paml_pass aml_bank_db \
  -e "SELECT fa.alert_id, fa.alert_key, e.evidence_type, e.evidence_data FROM fraud_alerts fa JOIN fraud_alert_evidence e ON e.alert_id = fa.alert_id ORDER BY fa.alert_id, e.evidence_id;"
```

The original human-review relationship is still available:

```bash
docker compose exec mysql mysql -uaml_user -paml_pass aml_bank_db \
  -e "SELECT * FROM v_compliance_audit_report ORDER BY audit_id;"
```

## Verify seeded table coverage

```bash
docker compose exec mysql mysql -uaml_user -paml_pass aml_bank_db \
  -e "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='aml_bank_db' AND table_type='BASE TABLE' ORDER BY table_name;"
```
