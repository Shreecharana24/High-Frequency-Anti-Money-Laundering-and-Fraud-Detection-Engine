-- ============================================================================
-- 06_aml_rules.sql
-- AML Bank DBMS Project
-- MySQL 8.0 - AML Detection using CTEs and Window Functions
-- ============================================================================

USE aml_bank_db;


-- ============================================================================
-- RULE 1: STRUCTURING / SMURFING DETECTION
-- ============================================================================
-- Objective:
--   Identify accounts sending multiple relatively small transactions within
--   a rolling 24-hour period.
--
-- Illustrative criteria:
--   - Each transaction is below 10,000.
--   - At least 3 transactions occur in the 24-hour window.
--
-- NOTE:
--   These values are project parameters, not universal AML thresholds.
-- ============================================================================

WITH eligible_transactions AS (
    SELECT
        t.transaction_id,
        t.sender_account_id,
        a.user_id,
        t.amount,
        t.currency,
        t.created_at
    FROM transactions t
    JOIN accounts a
        ON a.account_id = t.sender_account_id
    WHERE t.status = 'COMPLETED'
      AND t.amount < 10000.00
),
smurfing_candidates AS (
    SELECT
        anchor.transaction_id AS window_start_transaction_id,
        anchor.sender_account_id,
        anchor.user_id,
        anchor.currency,
        anchor.created_at AS window_start,
        COUNT(DISTINCT candidate.transaction_id) AS transaction_count,
        SUM(candidate.amount) AS total_amount,
        MAX(candidate.created_at) AS last_transaction_at
    FROM eligible_transactions anchor
    JOIN eligible_transactions candidate
        ON candidate.sender_account_id = anchor.sender_account_id
       AND candidate.currency = anchor.currency
       AND candidate.created_at >= anchor.created_at
       AND candidate.created_at < anchor.created_at + INTERVAL 24 HOUR
    GROUP BY
        anchor.transaction_id,
        anchor.sender_account_id,
        anchor.user_id,
        anchor.currency,
        anchor.created_at
    HAVING COUNT(DISTINCT candidate.transaction_id) >= 3
)
SELECT
    sender_account_id,
    user_id,
    currency,
    window_start,
    last_transaction_at,
    transaction_count,
    total_amount,
    'POSSIBLE_STRUCTURING' AS alert_type
FROM smurfing_candidates
ORDER BY transaction_count DESC, total_amount DESC;


-- ============================================================================
-- RULE 2: HIGH-VELOCITY TRANSACTION DETECTION
-- ============================================================================
-- Objective:
--   Identify accounts making many outgoing transactions within 10 minutes.
--
-- Demonstrates:
--   CTEs, COUNT, rolling time-window joins, aggregation.
--
-- Illustrative criterion:
--   At least 5 completed outgoing transactions in 10 minutes.
-- ============================================================================

WITH completed_outgoing AS (
    SELECT
        transaction_id,
        sender_account_id,
        amount,
        currency,
        created_at
    FROM transactions
    WHERE status = 'COMPLETED'
),
velocity_windows AS (
    SELECT
        anchor.transaction_id AS window_start_transaction_id,
        anchor.sender_account_id,
        anchor.created_at AS window_start,
        COUNT(DISTINCT candidate.transaction_id) AS transaction_count,
        SUM(candidate.amount) AS total_amount
    FROM completed_outgoing anchor
    JOIN completed_outgoing candidate
        ON candidate.sender_account_id = anchor.sender_account_id
       AND candidate.currency = anchor.currency
       AND candidate.created_at >= anchor.created_at
       AND candidate.created_at < anchor.created_at + INTERVAL 10 MINUTE
    GROUP BY
        anchor.transaction_id,
        anchor.sender_account_id,
        anchor.created_at
    HAVING COUNT(DISTINCT candidate.transaction_id) >= 5
)
SELECT
    sender_account_id,
    window_start,
    transaction_count,
    total_amount,
    'HIGH_TRANSACTION_VELOCITY' AS alert_type
FROM velocity_windows
ORDER BY transaction_count DESC, total_amount DESC;


-- ============================================================================
-- RULE 3: RAPID PASS-THROUGH ACTIVITY
-- ============================================================================
-- Objective:
--   Identify accounts receiving funds and then sending funds onward soon
--   afterwards.
--
-- Illustrative criterion:
--   An account receives a completed transfer and sends a completed transfer
--   within 60 minutes of that receipt.
--
-- This is a screening signal, not proof of money laundering.
-- ============================================================================

WITH incoming_transfers AS (
    SELECT
        transaction_id AS incoming_transaction_id,
        receiver_account_id AS account_id,
        amount AS incoming_amount,
        currency,
        created_at AS received_at
    FROM transactions
    WHERE status = 'COMPLETED'
),
outgoing_transfers AS (
    SELECT
        transaction_id AS outgoing_transaction_id,
        sender_account_id AS account_id,
        receiver_account_id AS destination_account_id,
        amount AS outgoing_amount,
        currency,
        created_at AS sent_at
    FROM transactions
    WHERE status = 'COMPLETED'
)
SELECT
    i.account_id,
    i.incoming_transaction_id,
    o.outgoing_transaction_id,
    i.incoming_amount,
    o.outgoing_amount,
    i.currency,
    i.received_at,
    o.sent_at,
    TIMESTAMPDIFF(
        MINUTE,
        i.received_at,
        o.sent_at
    ) AS minutes_between,
    'RAPID_PASS_THROUGH' AS alert_type
FROM incoming_transfers i
JOIN outgoing_transfers o
    ON o.account_id = i.account_id
   AND o.currency = i.currency
   AND o.sent_at >= i.received_at
   AND o.sent_at <= i.received_at + INTERVAL 60 MINUTE
WHERE o.outgoing_amount <= i.incoming_amount
ORDER BY i.received_at DESC;


-- ============================================================================
-- RULE 4: MULTI-HOP TRANSACTION CHAINS
-- ============================================================================
-- Objective:
--   Trace paths through accounts using completed transactions.
--
-- Demonstrates:
--   Recursive CTEs, graph traversal, cycle avoidance, path construction.
--
-- The query starts with completed transactions and follows subsequent
-- transactions within 24 hours of the first transaction.
--
-- Maximum path depth: 4 edges.
-- Paths with at least 2 edges are returned.
-- ============================================================================

WITH RECURSIVE transaction_chains AS (

    -- Anchor member: each completed transaction starts a chain.
    SELECT
        t.transaction_id AS first_transaction_id,
        t.sender_account_id AS source_account_id,
        t.receiver_account_id AS current_account_id,
        t.created_at AS first_transaction_at,
        t.created_at AS last_transaction_at,
        1 AS hop_count,

        CAST(
            CONCAT(
                t.sender_account_id,
                ',',
                t.receiver_account_id
            )
            AS CHAR(2000)
        ) AS account_path,

        CAST(
            CONCAT(',', t.transaction_id, ',')
            AS CHAR(2000)
        ) AS transaction_path

    FROM transactions t
    WHERE t.status = 'COMPLETED'

    UNION ALL

    -- Recursive member: follow outgoing transfers from the current account.
    SELECT
        chain.first_transaction_id,
        chain.source_account_id,
        next_tx.receiver_account_id,
        chain.first_transaction_at,
        next_tx.created_at,
        chain.hop_count + 1,

        CONCAT(
            chain.account_path,
            ',',
            next_tx.receiver_account_id
        ),

        CONCAT(
            chain.transaction_path,
            next_tx.transaction_id,
            ','
        )

    FROM transaction_chains chain
    JOIN transactions next_tx
        ON next_tx.sender_account_id = chain.current_account_id
       AND next_tx.status = 'COMPLETED'
       AND next_tx.created_at >= chain.last_transaction_at
       AND next_tx.created_at <=
           chain.first_transaction_at + INTERVAL 24 HOUR

    WHERE chain.hop_count < 4

      -- Avoid revisiting an account within the same path.
      AND FIND_IN_SET(
          CAST(next_tx.receiver_account_id AS CHAR),
          chain.account_path
      ) = 0
)
SELECT
    source_account_id,
    current_account_id AS destination_account_id,
    first_transaction_id,
    first_transaction_at,
    last_transaction_at,
    hop_count,
    account_path,
    transaction_path,
    'MULTI_HOP_CHAIN' AS alert_type
FROM transaction_chains
WHERE hop_count >= 2
ORDER BY hop_count DESC, first_transaction_at DESC;


-- ============================================================================
-- RULE 5: TRANSACTION VELOCITY USING WINDOW FUNCTIONS
-- ============================================================================
-- Objective:
--   Compare each completed transaction with the previous transaction
--   from the same sender account.
--
-- Demonstrates:
--   LAG(), COUNT() OVER(), SUM() OVER().
--
-- Note:
--   The count and sum are cumulative within the selected history, not
--   rolling 10-minute totals. RULE 2 performs the rolling-window detection.
-- ============================================================================

WITH ordered_transactions AS (
    SELECT
        transaction_id,
        sender_account_id,
        receiver_account_id,
        amount,
        currency,
        created_at,

        LAG(created_at) OVER (
            PARTITION BY sender_account_id
            ORDER BY created_at, transaction_id
        ) AS previous_transaction_at,

        COUNT(*) OVER (
            PARTITION BY sender_account_id
            ORDER BY created_at, transaction_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_transaction_count,

        SUM(amount) OVER (
            PARTITION BY sender_account_id
            ORDER BY created_at, transaction_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_amount

    FROM transactions
    WHERE status = 'COMPLETED'
)
SELECT
    transaction_id,
    sender_account_id,
    receiver_account_id,
    amount,
    currency,
    created_at,
    previous_transaction_at,
    TIMESTAMPDIFF(
        SECOND,
        previous_transaction_at,
        created_at
    ) AS seconds_since_previous_transaction,
    cumulative_transaction_count,
    cumulative_amount
FROM ordered_transactions
ORDER BY sender_account_id, created_at, transaction_id;
 