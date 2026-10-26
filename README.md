# High-Frequency Anti-Money Laundering (AML) & Fraud Detection Engine

## Overview
This project models a hybrid financial data platform built for two different workloads:

- MySQL 8.0 for low-latency OLTP operations such as transfers, account updates, and audit records.
- ClickHouse for high-speed analytical queries used for AML risk detection and fraud investigations.

The SQL layer is the foundation. Before moving to Docker and ClickHouse, the database schema, procedures, triggers, functions, and AML rules must all run successfully in order.

## Project structure

```text
aml-bank-db/
├── README.md
├── docker-compose.yml
├── config/
│   ├── mysql.cnf
│   └── clickhouse_init.sql
├── scripts/
│   ├── 01_schema_oltp.sql
│   ├── 02_stored_procedures.sql
│   ├── 03_triggers.sql
│   ├── 04_functions.sql
│   ├── 05_views.sql
│   ├── 06_aml_rules.sql
│   └── 07_test_cases.sql
└── .gitignore
```

## SQL execution order
Run each file in this order in MySQL 8.0:

1. 01_schema_oltp.sql
2. 02_stored_procedures.sql
3. 03_triggers.sql
4. 04_functions.sql
5. 05_views.sql
6. 06_aml_rules.sql
7. 07_test_cases.sql

The order matters because later files depend on tables, stored procedures, triggers, views, and functions created earlier.

## Why Docker Compose is useful
Docker Compose is used to orchestrate multiple services like MySQL, ClickHouse, and Grafana in one controlled environment.

It helps with:
- one-command startup and shutdown
- consistent local environment setup
- easier networking between services
- isolation from the host machine configuration

It does not make the project inherently more complex; it reduces drift and keeps the stack reproducible. The complexity comes from the architecture itself, not Docker Compose.

## Local startup

```bash
docker compose up -d
```

Then verify that:

```bash
docker compose ps
```

You can inspect MySQL and ClickHouse services separately once the containers are running.

## Notes
- The MySQL layer is the system of record.
- ClickHouse is for analytical querying and AML detection.
- The project is intentionally split between OLTP and OLAP to avoid operational slowdowns caused by analytical workloads on the live transactional database.
