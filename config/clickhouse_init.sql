CREATE DATABASE IF NOT EXISTS aml_detection;

CREATE TABLE IF NOT EXISTS aml_detection.transactions (
    transaction_id UInt64,
    sender_account_id UInt64,
    receiver_account_id UInt64,
    amount Decimal(15, 2),
    currency LowCardinality(String),
    created_at DateTime64(3),
    status LowCardinality(String),
    sender_risk_level LowCardinality(String)
)
ENGINE = ReplacingMergeTree
ORDER BY transaction_id;
