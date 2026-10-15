CREATE DATABASE IF NOT EXISTS aml_bank_db
    DEFAULT CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE aml_bank_db;

-- Stores customer identity, contact details, and risk status.
CREATE TABLE users (
    user_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    full_name VARCHAR(100) NOT NULL,

    email VARCHAR(150) NOT NULL UNIQUE,

    phone VARCHAR(20) NOT NULL,

    risk_level ENUM(
        'LOW',
        'MEDIUM',
        'HIGH',
        'CRITICAL'
    ) NOT NULL DEFAULT 'LOW',

    is_frozen BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
) ENGINE = InnoDB;

-- Stores each customer's KYC documents and verification status.
CREATE TABLE user_kyc_profiles (
    kyc_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    user_id BIGINT NOT NULL UNIQUE,

    national_id_hash VARCHAR(64) NOT NULL,

    document_type ENUM(
        'PASSPORT',
        'NATIONAL_ID',
        'DRIVING_LICENSE'
    ) NOT NULL,

    verification_status ENUM(
        'PENDING',
        'VERIFIED',
        'REJECTED'
    ) NOT NULL DEFAULT 'PENDING',

    verified_at TIMESTAMP NULL,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_kyc_user
        FOREIGN KEY (user_id)
        REFERENCES users(user_id)
        ON DELETE CASCADE
) ENGINE = InnoDB;

-- Stores registered organizations and their legal identifiers.
CREATE TABLE organizations (
    org_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    legal_name VARCHAR(150) NOT NULL,

    tax_identifier VARCHAR(50) NOT NULL UNIQUE,

    country VARCHAR(3) NOT NULL,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE = InnoDB;

-- Associates users with organizations and records their roles and ownership.
CREATE TABLE user_organization_roles (
    user_id BIGINT NOT NULL,

    org_id BIGINT NOT NULL,

    role ENUM(
        'DIRECTOR',
        'BENEFICIAL_OWNER',
        'SIGNATORY',
        'AUDITOR'
    ) NOT NULL,

    equity_percentage DECIMAL(5,2) NOT NULL DEFAULT 0.00,

    assigned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (user_id, org_id, role),

    CONSTRAINT chk_equity_percentage
        CHECK (
            equity_percentage >= 0
            AND equity_percentage <= 100
        ),

    CONSTRAINT fk_uor_user
        FOREIGN KEY (user_id)
        REFERENCES users(user_id)
        ON DELETE CASCADE,

    CONSTRAINT fk_uor_org
        FOREIGN KEY (org_id)
        REFERENCES organizations(org_id)
        ON DELETE CASCADE
) ENGINE = InnoDB;

-- Stores customer and business bank accounts with their balances.
CREATE TABLE accounts (
    account_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    user_id BIGINT NOT NULL,

    account_number VARCHAR(20) NOT NULL UNIQUE,

    account_type ENUM(
        'SAVINGS',
        'CHECKING',
        'CORPORATE',
        'ESCROW'
    ) NOT NULL,

    total_balance DECIMAL(15,2) NOT NULL DEFAULT 0.00,

    held_funds DECIMAL(15,2) NOT NULL DEFAULT 0.00,

    available_balance DECIMAL(15,2)
        GENERATED ALWAYS AS (
            total_balance - held_funds
        ) STORED,

    currency VARCHAR(3) NOT NULL DEFAULT 'USD',

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_total_balance
        CHECK (total_balance >= 0),

    CONSTRAINT chk_held_funds
        CHECK (
            held_funds >= 0
            AND held_funds <= total_balance
        ),

    CONSTRAINT fk_account_user
        FOREIGN KEY (user_id)
        REFERENCES users(user_id)
        ON DELETE RESTRICT
) ENGINE = InnoDB;

-- Stores merchants and their categories and geographic locations.
CREATE TABLE merchants (
    merchant_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    merchant_name VARCHAR(100) NOT NULL,

    category_code VARCHAR(10) NOT NULL,

    location POINT NOT NULL,

    city VARCHAR(50) NOT NULL,

    country VARCHAR(3) NOT NULL,

    SPATIAL INDEX idx_merchant_location (location)
) ENGINE = InnoDB;

-- Records money transfers and payments between accounts.
CREATE TABLE transactions (
    transaction_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    sender_account_id BIGINT NOT NULL,

    receiver_account_id BIGINT NOT NULL,

    merchant_id BIGINT NULL,

    amount DECIMAL(15,2) NOT NULL,

    currency VARCHAR(3) NOT NULL DEFAULT 'USD',

    transaction_type ENUM(
        'P2P_TRANSFER',
        'MERCHANT_PAYMENT',
        'WIRE',
        'ATM_WITHDRAWAL'
    ) NOT NULL,

    status ENUM(
        'PENDING',
        'COMPLETED',
        'FAILED',
        'BLOCKED'
    ) NOT NULL DEFAULT 'PENDING',

    created_at TIMESTAMP(3) DEFAULT CURRENT_TIMESTAMP(3),

    idempotency_hash VARCHAR(64)
        GENERATED ALWAYS AS (
            SHA2(
                CONCAT(
                    sender_account_id,
                    '-',
                    receiver_account_id,
                    '-',
                    amount,
                    '-',
                    created_at
                ),
                256
            )
        ) STORED UNIQUE,

    CONSTRAINT chk_transaction_amount
        CHECK (amount > 0),

    CONSTRAINT chk_different_accounts
        CHECK (sender_account_id <> receiver_account_id),

    CONSTRAINT fk_transaction_sender
        FOREIGN KEY (sender_account_id)
        REFERENCES accounts(account_id),

    CONSTRAINT fk_transaction_receiver
        FOREIGN KEY (receiver_account_id)
        REFERENCES accounts(account_id),

    CONSTRAINT fk_transaction_merchant
        FOREIGN KEY (merchant_id)
        REFERENCES merchants(merchant_id)
) ENGINE = InnoDB;

-- Stores compliance staff authorized to review transactions.
CREATE TABLE compliance_officers (
    officer_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    badge_number VARCHAR(30) NOT NULL UNIQUE,

    officer_name VARCHAR(100) NOT NULL,

    clearance_level ENUM(
        'LEVEL_1',
        'LEVEL_2',
        'ADMIN'
    ) NOT NULL
) ENGINE = InnoDB;

-- Defines fraud detection rules and their base penalty scores.
CREATE TABLE fraud_rules (
    rule_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    rule_code VARCHAR(50) NOT NULL UNIQUE,

    description TEXT NOT NULL,

    base_penalty_score INT NOT NULL,

    CONSTRAINT chk_penalty_score
        CHECK (base_penalty_score >= 0)
) ENGINE = InnoDB;

-- Records officer reviews of transactions against fraud rules.
CREATE TABLE transaction_audits (
    audit_id BIGINT AUTO_INCREMENT PRIMARY KEY,

    transaction_id BIGINT NOT NULL,

    officer_id BIGINT NOT NULL,

    rule_id BIGINT NOT NULL,

    review_outcome ENUM(
        'ESCALATED',
        'CLEARED',
        'REPORTED_TO_REGULATOR'
    ) NOT NULL,

    notes TEXT,

    reviewed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_ternary_audit
        UNIQUE (
            transaction_id,
            officer_id,
            rule_id
        ),

    CONSTRAINT fk_audit_transaction
        FOREIGN KEY (transaction_id)
        REFERENCES transactions(transaction_id)
        ON DELETE CASCADE,

    CONSTRAINT fk_audit_officer
        FOREIGN KEY (officer_id)
        REFERENCES compliance_officers(officer_id),

    CONSTRAINT fk_audit_rule
        FOREIGN KEY (rule_id)
        REFERENCES fraud_rules(rule_id)
) ENGINE = InnoDB;


CREATE INDEX idx_accounts_user
    ON accounts(user_id);

CREATE INDEX idx_transactions_sender
    ON transactions(sender_account_id);

CREATE INDEX idx_transactions_receiver
    ON transactions(receiver_account_id);

CREATE INDEX idx_transactions_created_at
    ON transactions(created_at);

CREATE INDEX idx_transactions_status
    ON transactions(status);

CREATE INDEX idx_transactions_type
    ON transactions(transaction_type);

CREATE INDEX idx_transactions_merchant
    ON transactions(merchant_id);

CREATE INDEX idx_audits_transaction
    ON transaction_audits(transaction_id);

CREATE INDEX idx_audits_rule
    ON transaction_audits(rule_id);