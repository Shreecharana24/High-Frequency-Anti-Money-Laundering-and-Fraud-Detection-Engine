# AML Fraud Detection Engine

The project uses MySQL as the source of truth and ClickHouse as the analytical
transaction mirror. The current Docker stack initializes the complete MySQL
schema, stored procedures, triggers, functions, views, alert tables, and
deterministic development fixtures. The Python generator and detector remain
development workers; the transaction service and operations API are planned
for the next phases.

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
6. [`scripts/08_seed_data.sql`](scripts/08_seed_data.sql)

The seed file creates at least ten rows in every MySQL table and includes known
synthetic risk patterns. [`scripts/06_aml_rules.sql`](scripts/06_aml_rules.sql)
contains analytical rule queries and is intentionally not an initialization
script. [`scripts/07_test_cases.sql`](scripts/07_test_cases.sql) remains a
destructive, development-only test script and is intentionally not run by
Docker startup.

ClickHouse creates its transaction mirror from
[`config/clickhouse_init.sql`](config/clickhouse_init.sql).

## Services

- **generator** — Uses the atomic `sp_transfer_funds` procedure, so generated
  transactions update both account balances and transaction/event history.
- **detector** — Mirrors new MySQL transactions into ClickHouse and runs the
  configured structuring, velocity, pass-through, multi-hop, high-value, and
  high-risk-customer rules. It persists deduplicated alerts and evidence in
  `fraud_alerts` and `fraud_alert_evidence`.
- **api** — Provides alert review, transaction, rule, metrics, and health
  endpoints on port 8000.

The generator is bounded by default:

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
GET   /api/v1/alerts
GET   /api/v1/alerts/{alert_id}
PATCH /api/v1/alerts/{alert_id}
POST  /api/v1/alerts/{alert_id}/notes
GET   /api/v1/transactions
GET   /api/v1/rules
GET   /api/v1/metrics
```

Assign and move an alert into investigation:

```bash
curl -X PATCH http://localhost:8000/api/v1/alerts/1 \
  -H 'Content-Type: application/json' \
  -d '{"assigned_officer_id": 1, "status": "INVESTIGATING"}'
```

Add a review note:

```bash
curl -X POST http://localhost:8000/api/v1/alerts/1/notes \
  -H 'Content-Type: application/json' \
  -d '{"officer_id": 1, "note": "Reviewed transaction timing and counterparties."}'
```

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
