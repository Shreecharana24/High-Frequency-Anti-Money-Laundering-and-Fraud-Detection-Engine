-- ============================================================================
-- 03_triggers.sql
-- AML Bank DBMS Project
-- MySQL 8.0 - Triggers and Automatic Audit Logging
-- ============================================================================

USE aml_bank_db;

DELIMITER $$


-- ============================================================================
-- 1. ACCOUNT BALANCE HISTORY TABLE
-- ============================================================================
-- Stores changes to balances and held funds.
--
-- This is separate from transaction_audits, which represents the ternary
-- relationship between transactions, compliance officers, and fraud rules.
-- ============================================================================

CREATE TABLE IF NOT EXISTS account_balance_history (
    history_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    account_id BIGINT NOT NULL,

    old_total_balance DECIMAL(15,2) NOT NULL,
    new_total_balance DECIMAL(15,2) NOT NULL,

    old_held_funds DECIMAL(15,2) NOT NULL,
    new_held_funds DECIMAL(15,2) NOT NULL,

    change_type ENUM(
        'DEPOSIT_OR_CREDIT',
        'WITHDRAWAL_OR_DEBIT',
        'FUNDS_HELD',
        'FUNDS_RELEASED',
        'OTHER'
    ) NOT NULL,

    changed_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    changed_by VARCHAR(288) NOT NULL,

    INDEX idx_balance_history_account (account_id),
    INDEX idx_balance_history_time (changed_at)

) ENGINE = InnoDB;


-- ============================================================================
-- 2. TRANSACTION EVENT LOG
-- ============================================================================
-- Records transaction creation and status changes.
-- ============================================================================

CREATE TABLE IF NOT EXISTS transaction_event_log (
    event_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    transaction_id BIGINT NOT NULL,

    event_type ENUM(
        'TRANSACTION_CREATED',
        'STATUS_CHANGED'
    ) NOT NULL,

    old_status ENUM(
        'PENDING',
        'COMPLETED',
        'FAILED',
        'BLOCKED'
    ) NULL,

    new_status ENUM(
        'PENDING',
        'COMPLETED',
        'FAILED',
        'BLOCKED'
    ) NOT NULL,

    event_time TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    changed_by VARCHAR(288) NOT NULL,

    INDEX idx_event_transaction (transaction_id),
    INDEX idx_event_time (event_time)

) ENGINE = InnoDB;


-- ============================================================================
-- 3. TRIGGER: VALIDATE TRANSACTION BEFORE INSERT
-- ============================================================================
-- Enforces consistency between transaction type and merchant participation.
--
-- P2P_TRANSFER:
--   merchant_id must be NULL.
--
-- MERCHANT_PAYMENT:
--   merchant_id must not be NULL.
--
-- Also ensures sender and receiver account currencies match the transaction.
-- ============================================================================

DROP TRIGGER IF EXISTS trg_validate_transaction_insert$$

CREATE TRIGGER trg_validate_transaction_insert
BEFORE INSERT ON transactions
FOR EACH ROW
BEGIN
    DECLARE v_sender_currency VARCHAR(3);
    DECLARE v_receiver_currency VARCHAR(3);

    IF NEW.transaction_type = 'P2P_TRANSFER'
       AND NEW.merchant_id IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'P2P transfers must not reference a merchant';
    END IF;

    IF NEW.transaction_type = 'MERCHANT_PAYMENT'
       AND NEW.merchant_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Merchant payments require a merchant';
    END IF;

    SELECT currency
    INTO v_sender_currency
    FROM accounts
    WHERE account_id = NEW.sender_account_id;

    SELECT currency
    INTO v_receiver_currency
    FROM accounts
    WHERE account_id = NEW.receiver_account_id;

    IF v_sender_currency <> v_receiver_currency
       OR NEW.currency <> v_sender_currency THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Transaction and account currencies must match';
    END IF;
END$$


-- ============================================================================
-- 4. TRIGGER: RECORD ACCOUNT BALANCE CHANGES
-- ============================================================================
-- Automatically records changes to total_balance or held_funds.
--
-- The trigger does not update balances itself. Stored procedures remain
-- responsible for executing the financial operation.
-- ============================================================================

DROP TRIGGER IF EXISTS trg_account_balance_history$$

CREATE TRIGGER trg_account_balance_history
AFTER UPDATE ON accounts
FOR EACH ROW
BEGIN
    DECLARE v_change_type VARCHAR(30);

    IF NOT (OLD.total_balance <=> NEW.total_balance)
       OR NOT (OLD.held_funds <=> NEW.held_funds) THEN

        SET v_change_type = 'OTHER';

        IF NEW.held_funds > OLD.held_funds
           AND NEW.total_balance = OLD.total_balance THEN
            SET v_change_type = 'FUNDS_HELD';

        ELSEIF NEW.held_funds < OLD.held_funds
           AND NEW.total_balance = OLD.total_balance THEN
            SET v_change_type = 'FUNDS_RELEASED';

        ELSEIF NEW.total_balance > OLD.total_balance THEN
            SET v_change_type = 'DEPOSIT_OR_CREDIT';

        ELSEIF NEW.total_balance < OLD.total_balance THEN
            SET v_change_type = 'WITHDRAWAL_OR_DEBIT';
        END IF;

        INSERT INTO account_balance_history (
            account_id,
            old_total_balance,
            new_total_balance,
            old_held_funds,
            new_held_funds,
            change_type,
            changed_by
        )
        VALUES (
            NEW.account_id,
            OLD.total_balance,
            NEW.total_balance,
            OLD.held_funds,
            NEW.held_funds,
            v_change_type,
            USER()
        );
    END IF;
END$$


-- ============================================================================
-- 5. TRIGGER: LOG NEW TRANSACTIONS
-- ============================================================================
-- Automatically creates a transaction event whenever a transaction row
-- is inserted.
-- ============================================================================

DROP TRIGGER IF EXISTS trg_transaction_created$$

CREATE TRIGGER trg_transaction_created
AFTER INSERT ON transactions
FOR EACH ROW
BEGIN
    INSERT INTO transaction_event_log (
        transaction_id,
        event_type,
        old_status,
        new_status,
        changed_by
    )
    VALUES (
        NEW.transaction_id,
        'TRANSACTION_CREATED',
        NULL,
        NEW.status,
        USER()
    );
END$$


-- ============================================================================
-- 6. TRIGGER: VALIDATE TRANSACTION STATUS CHANGES
-- ============================================================================
-- Permitted transitions:
--
--   PENDING -> COMPLETED
--   PENDING -> FAILED
--   PENDING -> BLOCKED
--
-- A transaction may retain its current status.
-- Terminal statuses cannot be changed to a different status.
-- ============================================================================

DROP TRIGGER IF EXISTS trg_validate_transaction_status$$

CREATE TRIGGER trg_validate_transaction_status
BEFORE UPDATE ON transactions
FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN

        IF OLD.status <> 'PENDING' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                    'Only pending transactions may change status';
        END IF;

    END IF;
END$$


-- ============================================================================
-- 7. TRIGGER: LOG TRANSACTION STATUS CHANGES
-- ============================================================================
-- Records a status change after the update succeeds.
-- ============================================================================

DROP TRIGGER IF EXISTS trg_transaction_status_log$$

CREATE TRIGGER trg_transaction_status_log
AFTER UPDATE ON transactions
FOR EACH ROW
BEGIN
    IF NOT (OLD.status <=> NEW.status) THEN

        INSERT INTO transaction_event_log (
            transaction_id,
            event_type,
            old_status,
            new_status,
            changed_by
        )
        VALUES (
            NEW.transaction_id,
            'STATUS_CHANGED',
            OLD.status,
            NEW.status,
            USER()
        );

    END IF;
END$$


DELIMITER ;
