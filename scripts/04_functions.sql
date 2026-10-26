-- ============================================================================
-- 04_functions.sql
-- AML Bank DBMS Project
-- MySQL 8.0 - User-Defined Functions
-- ============================================================================

USE aml_bank_db;

DELIMITER $$


-- ============================================================================
-- FUNCTION 1: CALCULATE TRANSACTION RISK SCORE
-- ============================================================================
-- Purpose:
--   Calculate a base risk score from the transaction amount and type.
--
-- Scoring is illustrative and intended for this academic project.
-- It is NOT a regulatory scoring model.
--
-- Higher values indicate higher preliminary risk.
-- ============================================================================

DROP FUNCTION IF EXISTS fn_transaction_risk_score$$

CREATE FUNCTION fn_transaction_risk_score(
    p_amount DECIMAL(15,2),
    p_transaction_type VARCHAR(30)
)
RETURNS INT
DETERMINISTIC
NO SQL
BEGIN
    DECLARE v_score INT DEFAULT 0;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN 0;
    END IF;

    -- Base score based on transaction amount.
    IF p_amount >= 100000 THEN
        SET v_score = v_score + 50;
    ELSEIF p_amount >= 50000 THEN
        SET v_score = v_score + 35;
    ELSEIF p_amount >= 10000 THEN
        SET v_score = v_score + 20;
    ELSEIF p_amount >= 5000 THEN
        SET v_score = v_score + 10;
    END IF;

    -- Additional score based on transaction type.
    CASE p_transaction_type
        WHEN 'WIRE' THEN
            SET v_score = v_score + 20;

        WHEN 'ATM_WITHDRAWAL' THEN
            SET v_score = v_score + 10;

        WHEN 'MERCHANT_PAYMENT' THEN
            SET v_score = v_score + 5;

        WHEN 'P2P_TRANSFER' THEN
            SET v_score = v_score + 10;

        ELSE
            SET v_score = v_score + 0;
    END CASE;

    RETURN v_score;
END$$


-- ============================================================================
-- FUNCTION 2: CLASSIFY TRANSACTION RISK
-- ============================================================================
-- Purpose:
--   Convert a numeric risk score into a readable category.
--
-- Classification:
--   0-19   -> LOW
--   20-39  -> MEDIUM
--   40-59  -> HIGH
--   60+    -> CRITICAL
-- ============================================================================

DROP FUNCTION IF EXISTS fn_risk_category$$

CREATE FUNCTION fn_risk_category(
    p_risk_score INT
)
RETURNS VARCHAR(10)
DETERMINISTIC
NO SQL
BEGIN
    IF p_risk_score IS NULL OR p_risk_score < 0 THEN
        RETURN 'INVALID';
    ELSEIF p_risk_score >= 60 THEN
        RETURN 'CRITICAL';
    ELSEIF p_risk_score >= 40 THEN
        RETURN 'HIGH';
    ELSEIF p_risk_score >= 20 THEN
        RETURN 'MEDIUM';
    ELSE
        RETURN 'LOW';
    END IF;
END$$


-- ============================================================================
-- FUNCTION 3: CALCULATE ACCOUNT AVAILABLE BALANCE
-- ============================================================================
-- Purpose:
--   Return the current available balance for an existing account.
--
-- Note:
--   This is a read-only calculation. It does not lock the account and should
--   not be used as the sole balance check before a financial update.
--   Stored procedures must perform their own locking and validation.
-- ============================================================================

DROP FUNCTION IF EXISTS fn_available_balance$$

CREATE FUNCTION fn_available_balance(
    p_account_id BIGINT
)
RETURNS DECIMAL(15,2)
READS SQL DATA
BEGIN
    DECLARE v_balance DECIMAL(15,2) DEFAULT NULL;

    SELECT available_balance
    INTO v_balance
    FROM accounts
    WHERE account_id = p_account_id;

    RETURN v_balance;
END$$


DELIMITER ;