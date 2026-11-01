# AML Fraud Detection Engine Demo

This demo uses MySQL as the source of truth and ClickHouse for fast fraud
detection queries. The generator submits two synthetic transactions per second.
With `--inject-fraud`, all transactions use the same sender account, allowing
the detector to identify suspicious transaction velocity.

## Run

```bash
docker compose up --build
```

If port 3306 is already in use:

```bash
MYSQL_PORT=3307 docker compose up --build
```

MySQL initializes from
[`scripts/01_schema_oltp.sql`](scripts/01_schema_oltp.sql). ClickHouse creates
its transaction mirror from [`config/clickhouse_init.sql`](config/clickhouse_init.sql).

## Services

- **generator** — Seeds demo users, accounts, compliance data, and fraud rules,
  then inserts completed P2P transactions.
- **detector** — Copies new MySQL transactions into ClickHouse, detects five or
  more transactions from one sender within ten seconds, prints alerts, and
  writes `ESCALATED` rows to `transaction_audits`.

## View flagged transactions

```bash
docker compose exec mysql mysql -uaml_user -paml_pass aml_bank_db \
  -e "SELECT * FROM transaction_audits ORDER BY audit_id;"
```

To remove the demo data and re-run schema initialization:

```bash
docker compose down -v
```
