# High-Frequency Anti-Money Laundering (AML) & Fraud Engine
### Hybrid OLTP (MySQL 8.0) + OLAP (ClickHouse) Architecture

A high-performance, enterprise-grade financial infrastructure designed for low-latency operational payment processing paired with real-time Anti-Money Laundering (AML) pattern detection across millions of records.

---

## Executive Summary & Problem Statement

Modern financial institutions face a fundamental database challenge:
1. **Operational Writes (OLTP):** Card authorizations and transfers require millisecond write latencies, strict ACID compliance, and non-blocking locks to prevent checkout timeouts.
2. **Analytical Scans (OLAP):** AML regulations require continuously scanning hundreds of millions of historical transactions to detect complex fraud patterns (smurfing, high-velocity bursts, and multi-hop mule networks).

Running heavy aggregation queries directly on an operational database (MySQL) consumes CPU/RAM, triggers table locks, and causes payment failures. 

**This Project's Solution:** A dual-engine hybrid architecture where **MySQL 8.0** handles live payment execution and streams data in real time via binary log Change Data Capture (CDC) to **ClickHouse**, a columnar database where sliding-window fraud queries run with sub-50ms latency without affecting operational throughput.

---

## System Architecture

```text
                 [Simulated Payment Stream (Python Client)]
                                     │
                                     ▼ (ACID Writes <5ms)
                 ┌───────────────────────────────────────┐
                 │           MySQL 8.0 (OLTP)            │
                 │  - Core Ledger, Users, Accounts, Txns │
                 │  - InnoDB Engine, Strict Constraints  │
                 │  - Binlog (ROW format + GTID)         │
                 └───────────────────┬───────────────────┘
                                     │
                                     │ (Native CDC Sync via
                                     │  MaterializedMySQL Engine)
                                     ▼
                 ┌───────────────────────────────────────┐
                 │           ClickHouse (OLAP)           │
                 │  - ReplacingMergeTree Replicas        │
                 │  - Columnar Storage & Aggregations    │
                 │  - Sliding Window AML Engine          │
                 └───────────────────┬───────────────────┘
                                     │
                                     ▼
                   ┌───────────────────────────────────┐
                   │    Real-Time AML Risk Dashboard   │
                   │   (Grafana / Flagged Txn Alerts)  │
                   └───────────────────────────────────┘
```

## Database Features & Schema Design

The relational schema implements advanced database design principles tailored for enterprise financial systems:

- **1:1 Relationship:** `users` ↔ `user_kyc_profiles` (Mandatory KYC verification record).
- **1:N Relationship:** `users` ↔ `accounts` (One user owning multiple bank accounts).
- **M:N Relationship:** `users` ↔ `organizations` via `user_organization_roles` junction table (Corporate ownership tracking).
- **Ternary Relationship (3-Way):** `transaction_audits` linking `(Transaction, Compliance Officer, Fraud Rule)` simultaneously.
- **Derived / Generated Keys:** MySQL `STORED GENERATED` columns for automated balance calculations (`available_balance`) and transaction deduplication hashes (`idempotency_hash`).
- **Participation Constraints:**
  - **Total Participation (Mandatory):** `accounts.user_id NOT NULL` (An account must belong to a registered user).
  - **Partial Participation (Optional):** `transactions.merchant_id NULL` (Nullable for P2P transfers; populated for merchant checkouts).

## Directory Structure

```text
.
├── docker-compose.yml             # Container configuration (MySQL, ClickHouse, Grafana)
├── config/
│   ├── mysql.cnf                  # MySQL binlog, GTID, and InnoDB settings
│   └── clickhouse_init.sql        # MaterializedMySQL engine CDC replication setup
├── scripts/
│   ├── 01_schema_oltp.sql         # MySQL DDL (Tables, Constraints, Generated Keys)
│   ├── 02_stored_procedures.sql   # Atomic transfer execution logic & locks
│   ├── 03_aml_rules.sql           # ClickHouse OLAP detection queries
│   └── simulate_traffic.py        # Synthetic transaction load generation script
└── README.md                      # Project documentation
```

## Quickstart & Local Setup

### Prerequisites

- **Docker** (v20.10+) and **Docker Compose** (v2.0+)
- **Python 3.10+** (for synthetic traffic generation)

### 1. Clone & Spin Up Containers

```bash
git clone https://github.com/your-username/aml-fraud-engine.git
cd aml-fraud-engine

# Start MySQL, ClickHouse, and Grafana containers
docker-compose up -d
```

### 2. Verify CDC Sync Status

Check that ClickHouse is actively reading MySQL's binary logs:

```bash
docker exec -it clickhouse-server clickhouse-client --query "SHOW DATABASES;"
```
You should see `aml_clickhouse_olap` listed in the output.

### 3. Run Traffic & Fraud Simulation

```bash
pip install faker mysql-connector-python
python scripts/simulate_traffic.py
```
This script populates standard banking activity and injects fraudulent smurfing and velocity patterns into MySQL.
