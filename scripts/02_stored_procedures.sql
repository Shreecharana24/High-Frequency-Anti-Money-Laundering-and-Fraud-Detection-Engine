-- ============================================================================
-- 02_stored_procedures.sql
-- AML Bank DBMS Project
-- MySQL 8.0 - Stored Procedures and Transaction Management
-- ============================================================================

USE aml_bank_db;

DELIMITER $$


-- ============================================================================
-- PROCEDURE 1: TRANSFER FUNDS
-- ============================================================================
-- Purpose:
--   Transfer money from one account to another atomically.
--
-- Demonstrates:
--   1. Stored procedures and IN parameters
--   2. ACID transactions
--   3. Row-level locking using SELECT ... FOR UPDATE
--   4. Exception handling and ROLLBACK
--   5. Referential integrity
--   6. Business-rule validation
--
-- Both account rows are locked in ascending account_id order to reduce
-- deadlock risk when concurrent transfers involve the same accounts.
--
-- Assumption:
--   This procedure handles same-currency P2P transfers.
-- ============================================================================

DROP PROCEDURE IF EXISTS sp_transfer_funds$$

CREATE PROCEDURE sp_transfer_funds(
    IN p_sender_account_id BIGINT,
    IN p_receiver_account_id BIGINT,
    IN p_amount DECIMAL(15,2)
)
BEGIN
    DECLARE v_sender_available DECIMAL(15,2);
    DECLARE v_receiver_balance DECIMAL(15,2);
    DECLARE v_sender_currency VARCHAR(3);
    DECLARE v_receiver_currency VARCHAR(3);
    DECLARE v_sender_frozen BOOLEAN DEFAULT FALSE;
    DECLARE v_receiver_frozen BOOLEAN DEFAULT FALSE;
    DECLARE v_account_count INT DEFAULT 0;

    -- Any SQL exception rolls back all changes made by this procedure.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- Validate input.
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Transfer amount must be positive';
    END IF;

    IF p_sender_account_id IS NULL
       OR p_receiver_account_id IS NULL
       OR p_sender_account_id = p_receiver_account_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid sender or receiver account';
    END IF;

    START TRANSACTION;

    -- Both accounts must exist.
    SELECT COUNT(*)
    INTO v_account_count
    FROM accounts
    WHERE account_id IN (
        p_sender_account_id,
        p_receiver_account_id
    );

    IF v_account_count <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Sender or receiver account does not exist';
    END IF;

    -- Lock accounts in a consistent order to reduce deadlock risk.
    IF p_sender_account_id < p_receiver_account_id THEN

        SELECT available_balance
        INTO v_sender_available
        FROM accounts
        WHERE account_id = p_sender_account_id
        FOR UPDATE;

        SELECT total_balance
        INTO v_receiver_balance
        FROM accounts
        WHERE account_id = p_receiver_account_id
        FOR UPDATE;

    ELSE

        SELECT total_balance
        INTO v_receiver_balance
        FROM accounts
        WHERE account_id = p_receiver_account_id
        FOR UPDATE;

        SELECT available_balance
        INTO v_sender_available
        FROM accounts
        WHERE account_id = p_sender_account_id
        FOR UPDATE;

    END IF;

    -- Read account currencies and owner freeze status.
    SELECT a.currency, u.is_frozen
    INTO v_sender_currency, v_sender_frozen
    FROM accounts a
    JOIN users u ON u.user_id = a.user_id
    WHERE a.account_id = p_sender_account_id;

    SELECT a.currency, u.is_frozen
    INTO v_receiver_currency, v_receiver_frozen
    FROM accounts a
    JOIN users u ON u.user_id = a.user_id
    WHERE a.account_id = p_receiver_account_id;

    IF v_sender_frozen OR v_receiver_frozen THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Transfer blocked: an account owner is frozen';
    END IF;

    IF v_sender_currency <> v_receiver_currency THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Account currencies do not match';
    END IF;

    IF v_sender_available < p_amount THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Insufficient available balance';
    END IF;

    -- Debit sender.
    UPDATE accounts
    SET total_balance = total_balance - p_amount
    WHERE account_id = p_sender_account_id;

    -- Credit receiver.
    UPDATE accounts
    SET total_balance = total_balance + p_amount
    WHERE account_id = p_receiver_account_id;

    -- Record the completed transfer.
    INSERT INTO transactions (
        sender_account_id,
        receiver_account_id,
        merchant_id,
        amount,
        currency,
        transaction_type,
        status
    )
    VALUES (
        p_sender_account_id,
        p_receiver_account_id,
        NULL,
        p_amount,
        v_sender_currency,
        'P2P_TRANSFER',
        'COMPLETED'
    );

    COMMIT;
END$$


-- ============================================================================
-- PROCEDURE 2: HOLD FUNDS
-- ============================================================================
-- Purpose:
--   Reserve part of an account's balance without spending it.
--
-- Example:
--   A payment authorization or compliance review may require funds to be held.
--
-- available_balance is a generated column, so we update held_funds rather
-- than trying to update available_balance directly.
-- ============================================================================

DROP PROCEDURE IF EXISTS sp_hold_funds$$

CREATE PROCEDURE sp_hold_funds(
    IN p_account_id BIGINT,
    IN p_amount DECIMAL(15,2)
)
BEGIN
    DECLARE v_available DECIMAL(15,2);
    DECLARE v_frozen BOOLEAN DEFAULT FALSE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_account_id IS NULL
       OR p_amount IS NULL
       OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid account or hold amount';
    END IF;

    START TRANSACTION;

    SELECT a.available_balance, u.is_frozen
    INTO v_available, v_frozen
    FROM accounts a
    JOIN users u ON u.user_id = a.user_id
    WHERE a.account_id = p_account_id
    FOR UPDATE;

    IF v_frozen THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cannot hold funds for a frozen account';
    END IF;

    IF v_available < p_amount THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Insufficient available balance for hold';
    END IF;

    UPDATE accounts
    SET held_funds = held_funds + p_amount
    WHERE account_id = p_account_id;

    COMMIT;
END$$


-- ============================================================================
-- PROCEDURE 3: RELEASE HELD FUNDS
-- ============================================================================
-- Purpose:
--   Release funds that were previously held.
--
-- The released amount becomes available again.
-- ============================================================================

DROP PROCEDURE IF EXISTS sp_release_held_funds$$

CREATE PROCEDURE sp_release_held_funds(
    IN p_account_id BIGINT,
    IN p_amount DECIMAL(15,2)
)
BEGIN
    DECLARE v_held DECIMAL(15,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_account_id IS NULL
       OR p_amount IS NULL
       OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid account or release amount';
    END IF;

    START TRANSACTION;

    SELECT held_funds
    INTO v_held
    FROM accounts
    WHERE account_id = p_account_id
    FOR UPDATE;

    IF v_held < p_amount THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Release amount exceeds held funds';
    END IF;

    UPDATE accounts
    SET held_funds = held_funds - p_amount
    WHERE account_id = p_account_id;

    COMMIT;
END$$


DELIMITER ;
