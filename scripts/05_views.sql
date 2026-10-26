-- ============================================================================
-- 05_views.sql
-- AML Bank DBMS Project
-- MySQL 8.0 - Views and Reporting
-- ============================================================================

USE aml_bank_db;


-- ============================================================================
-- VIEW 1: CUSTOMER ACCOUNT SUMMARY
-- ============================================================================
-- Shows each account alongside its owner and balance information.
-- ============================================================================

CREATE OR REPLACE VIEW v_account_summary AS
SELECT
    u.user_id,
    u.full_name,
    u.risk_level AS customer_risk_level,
    u.is_frozen,
    a.account_id,
    a.account_number,
    a.account_type,
    a.currency,
    a.total_balance,
    a.held_funds,
    a.available_balance,
    a.created_at AS account_created_at
FROM users u
JOIN accounts a
    ON u.user_id = a.user_id;


-- ============================================================================
-- VIEW 2: TRANSACTION DETAILS
-- ============================================================================
-- Combines transactions with sender, receiver, and merchant information.
-- ============================================================================

CREATE OR REPLACE VIEW v_transaction_details AS
SELECT
    t.transaction_id,
    t.created_at,
    t.transaction_type,
    t.status,
    t.amount,
    t.currency,

    sender.account_id AS sender_account_id,
    sender_user.user_id AS sender_user_id,
    sender_user.full_name AS sender_name,

    receiver.account_id AS receiver_account_id,
    receiver_user.user_id AS receiver_user_id,
    receiver_user.full_name AS receiver_name,

    m.merchant_id,
    m.merchant_name,
    m.category_code AS merchant_category

FROM transactions t

JOIN accounts sender
    ON t.sender_account_id = sender.account_id

JOIN users sender_user
    ON sender.user_id = sender_user.user_id

JOIN accounts receiver
    ON t.receiver_account_id = receiver.account_id

JOIN users receiver_user
    ON receiver.user_id = receiver_user.user_id

LEFT JOIN merchants m
    ON t.merchant_id = m.merchant_id;


-- ============================================================================
-- VIEW 3: HIGH-RISK TRANSACTIONS
-- ============================================================================
-- Finds completed transactions involving high-risk customers or transactions
-- whose illustrative calculated risk score is high or critical.
--
-- Risk score thresholds come from fn_transaction_risk_score() and
-- fn_risk_category(), defined in 04_functions.sql.
-- ============================================================================

CREATE OR REPLACE VIEW v_high_risk_transactions AS
SELECT
    td.transaction_id,
    td.created_at,
    td.sender_user_id,
    td.sender_name,
    td.receiver_user_id,
    td.receiver_name,
    td.amount,
    td.currency,
    td.transaction_type,
    td.status,

    fn_transaction_risk_score(
        td.amount,
        td.transaction_type
    ) AS calculated_risk_score,

    fn_risk_category(
        fn_transaction_risk_score(
            td.amount,
            td.transaction_type
        )
    ) AS calculated_risk_category

FROM v_transaction_details td

JOIN users sender_user
    ON td.sender_user_id = sender_user.user_id

JOIN users receiver_user
    ON td.receiver_user_id = receiver_user.user_id

WHERE td.status = 'COMPLETED'
  AND (
      sender_user.risk_level IN ('HIGH', 'CRITICAL')
      OR receiver_user.risk_level IN ('HIGH', 'CRITICAL')
      OR fn_risk_category(
          fn_transaction_risk_score(
              td.amount,
              td.transaction_type
          )
      ) IN ('HIGH', 'CRITICAL')
  );


-- ============================================================================
-- VIEW 4: CUSTOMER TRANSACTION SUMMARY
-- ============================================================================
-- Summarizes outgoing and incoming transaction activity per customer.
-- Only completed transactions are counted.
-- ============================================================================

CREATE OR REPLACE VIEW v_customer_transaction_summary AS
SELECT
    u.user_id,
    u.full_name,
    u.risk_level,

    COALESCE(outgoing.transaction_count, 0)
        AS outgoing_transaction_count,

    COALESCE(outgoing.total_amount, 0.00)
        AS outgoing_total_amount,

    COALESCE(incoming.transaction_count, 0)
        AS incoming_transaction_count,

    COALESCE(incoming.total_amount, 0.00)
        AS incoming_total_amount

FROM users u

LEFT JOIN (
    SELECT
        a.user_id,
        COUNT(*) AS transaction_count,
        SUM(t.amount) AS total_amount
    FROM transactions t
    JOIN accounts a
        ON t.sender_account_id = a.account_id
    WHERE t.status = 'COMPLETED'
    GROUP BY a.user_id
) outgoing
    ON u.user_id = outgoing.user_id

LEFT JOIN (
    SELECT
        a.user_id,
        COUNT(*) AS transaction_count,
        SUM(t.amount) AS total_amount
    FROM transactions t
    JOIN accounts a
        ON t.receiver_account_id = a.account_id
    WHERE t.status = 'COMPLETED'
    GROUP BY a.user_id
) incoming
    ON u.user_id = incoming.user_id;


-- ============================================================================
-- VIEW 5: COMPLIANCE AUDIT REPORT
-- ============================================================================
-- Connects transactions to the officer and fraud rule involved in each audit.
-- ============================================================================

CREATE OR REPLACE VIEW v_compliance_audit_report AS
SELECT
    ta.audit_id,
    ta.reviewed_at,
    ta.review_outcome,
    ta.notes,

    t.transaction_id,
    t.amount,
    t.currency,
    t.transaction_type,
    t.status AS transaction_status,

    co.officer_id,
    co.officer_name,
    co.clearance_level,

    fr.rule_id,
    fr.rule_code,
    fr.description AS fraud_rule_description,
    fr.base_penalty_score

FROM transaction_audits ta

JOIN transactions t
    ON ta.transaction_id = t.transaction_id

JOIN compliance_officers co
    ON ta.officer_id = co.officer_id

JOIN fraud_rules fr
    ON ta.rule_id = fr.rule_id;


-- ============================================================================
-- VIEW 6: SUSPICIOUS MERCHANT ACTIVITY
-- ============================================================================
-- Summarizes completed merchant payments by merchant.
-- This is a reporting view, not by itself a fraud determination.
-- ============================================================================

CREATE OR REPLACE VIEW v_merchant_transaction_summary AS
SELECT
    m.merchant_id,
    m.merchant_name,
    m.category_code,
    m.city,
    m.country,

    COUNT(t.transaction_id) AS transaction_count,

    COALESCE(SUM(t.amount), 0.00) AS total_transaction_amount,

    COALESCE(AVG(t.amount), 0.00) AS average_transaction_amount,

    MAX(t.created_at) AS last_transaction_at

FROM merchants m

LEFT JOIN transactions t
    ON m.merchant_id = t.merchant_id
   AND t.status = 'COMPLETED'

GROUP BY
    m.merchant_id,
    m.merchant_name,
    m.category_code,
    m.city,
    m.country;


-- ============================================================================
-- END OF VIEWS
-- ============================================================================