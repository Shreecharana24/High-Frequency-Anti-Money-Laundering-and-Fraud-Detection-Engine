CREATE DATABASE IF NOT EXISTS aml_clickhouse_olap;

CREATE TABLE IF NOT EXISTS aml_clickhouse_olap.transactions (
    transaction_id UInt64,
    sender_account_id UInt64,
    receiver_account_id UInt64,
    amount Decimal(18, 2),
    currency String,
    transaction_type String,
    created_at DateTime,
    status String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at, transaction_id);

CREATE TABLE IF NOT EXISTS aml_clickhouse_olap.aml_alerts (
    alert_id UInt64,
    alert_type String,
    created_at DateTime,
    severity String,
    summary String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at, alert_id);
