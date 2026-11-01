CREATE DATABASE IF NOT EXISTS aml_detection;

CREATE TABLE IF NOT EXISTS aml_detection.transactions (
    transaction_id UInt64,
    sender_account_id UInt64,
    receiver_account_id UInt64,
    amount Decimal(15, 2),
    created_at DateTime64(3),
    status String
)
ENGINE = MergeTree
ORDER BY (sender_account_id, created_at, transaction_id);
