-- ============================================================================
-- 07_test_cases.sql
-- AML Bank DBMS Project
-- MySQL 8.0 - Sample Data and Integration Tests
-- ============================================================================
-- WARNING:
-- This is a development test script. It deletes existing rows from the
-- project tables before inserting a fresh test dataset.
--
-- Run only against your development database.
-- Prerequisites:
--   01_schema_oltp.sql
--   02_stored_procedures.sql
--   03_triggers.sql
--   04_functions.sql
--   05_views.sql
--   06_aml_rules.sql
-- ============================================================================

USE aml_bank_db;

-- ============================================================================
-- PART 1: RESET DEVELOPMENT TEST DATA
-- ============================================================================

DELETE FROM transaction_audits;
DELETE FROM transactions;
DELETE FROM transaction_event_log;
DELETE FROM account_balance_history;
DELETE FROM accounts;
DELETE FROM user_organization_roles;
DELETE FROM user_kyc_profiles;
DELETE FROM merchants;
DELETE FROM compliance_officers;
DELETE FROM fraud_rules;
DELETE FROM organizations;
DELETE FROM users;

-- ============================================================================
-- PART 2: INSERT USERS
-- ============================================================================

INSERT INTO users
    (full_name, email, phone, risk_level, is_frozen)
VALUES
    ('Alice Sharma', 'alice.test@example.com', '9000000001', 'LOW', FALSE),
    ('Bob Kumar', 'bob.test@example.com', '9000000002', 'MEDIUM', FALSE),
    ('Carol Rao', 'carol.test@example.com', '9000000003', 'HIGH', FALSE),
    ('David Singh', 'david.test@example.com', '9000000004', 'LOW', FALSE),
    ('Eva Nair', 'eva.test@example.com', '9000000005', 'CRITICAL', FALSE);

SET @alice = (
    SELECT user_id FROM users
    WHERE email = 'alice.test@example.com'
);

SET @bob = (
    SELECT user_id FROM users
    WHERE email = 'bob.test@example.com'
);

SET @carol = (
    SELECT user_id FROM users
    WHERE email = 'carol.test@example.com'
);

SET @david = (
    SELECT user_id FROM users
    WHERE email = 'david.test@example.com'
);

SET @eva = (
    SELECT user_id FROM users
    WHERE email = 'eva.test@example.com'
);


-- ============================================================================
-- PART 3: INSERT KYC PROFILES (1:1 RELATIONSHIP)
-- ============================================================================

INSERT INTO user_kyc_profiles
    (user_id, national_id_hash, document_type, verification_status, verified_at)
VALUES
    (@alice, SHA2('TEST-ID-ALICE', 256), 'NATIONAL_ID',
     'VERIFIED', CURRENT_TIMESTAMP),
    (@bob, SHA2('TEST-ID-BOB', 256), 'PASSPORT',
     'VERIFIED', CURRENT_TIMESTAMP),
    (@carol, SHA2('TEST-ID-CAROL', 256), 'NATIONAL_ID',
     'VERIFIED', CURRENT_TIMESTAMP),
    (@david, SHA2('TEST-ID-DAVID', 256), 'DRIVING_LICENSE',
     'VERIFIED', CURRENT_TIMESTAMP),
    (@eva, SHA2('TEST-ID-EVA', 256), 'PASSPORT',
     'VERIFIED', CURRENT_TIMESTAMP);


-- ============================================================================
-- PART 4: ORGANIZATIONS AND M:N RELATIONSHIP
-- ============================================================================

INSERT INTO organizations
    (legal_name, tax_identifier, country)
VALUES
    ('Green Finance Test Ltd', 'TEST-TAX-001', 'IND'),
    ('Digital Trade Test Pvt Ltd', 'TEST-TAX-002', 'IND');

SET @org1 = (
    SELECT org_id FROM organizations
    WHERE tax_identifier = 'TEST-TAX-001'
);

SET @org2 = (
    SELECT org_id FROM organizations
    WHERE tax_identifier = 'TEST-TAX-002'
);

INSERT INTO user_organization_roles
    (user_id, org_id, role, equity_percentage)
VALUES
    (@alice, @org1, 'DIRECTOR', 20.00),
    (@alice, @org2, 'AUDITOR', 0.00),
    (@bob, @org1, 'BENEFICIAL_OWNER', 35.00),
    (@carol, @org2, 'SIGNATORY', 0.00);


-- ============================================================================
-- PART 5: INSERT ACCOUNTS
-- ============================================================================
-- Account balances are opening test snapshots.
-- The seeded historical AML transactions below are analytical fixtures;
-- they do not debit or credit these balances.
-- ============================================================================

INSERT INTO accounts
    (user_id, account_number, account_type,
     total_balance, held_funds, currency)
VALUES
    (@alice, 'TEST-ACC-001', 'SAVINGS',   100000.00, 0.00, 'USD'),
    (@bob,   'TEST-ACC-002', 'CHECKING',    5000.00, 0.00, 'USD'),
    (@carol, 'TEST-ACC-003', 'SAVINGS',     8000.00, 0.00, 'USD'),
    (@david, 'TEST-ACC-004', 'CHECKING',    3000.00, 0.00, 'USD'),
    (@eva,   'TEST-ACC-005', 'CORPORATE',  50000.00, 0.00, 'USD');

SET @acc_alice = (
    SELECT account_id FROM accounts WHERE account_number = 'TEST-ACC-001'
);

SET @acc_bob = (
    SELECT account_id FROM accounts WHERE account_number = 'TEST-ACC-002'
);

SET @acc_carol = (
    SELECT account_id FROM accounts WHERE account_number = 'TEST-ACC-003'
);

SET @acc_david = (
    SELECT account_id FROM accounts WHERE account_number = 'TEST-ACC-004'
);

SET @acc_eva = (
    SELECT account_id FROM accounts WHERE account_number = 'TEST-ACC-005'
);


-- ============================================================================
-- PART 6: MERCHANTS
-- ============================================================================
-- MySQL POINT uses X = longitude and Y = latitude.
-- SRID 4326 is used for geographic coordinates.
-- ============================================================================

INSERT INTO merchants
    (merchant_name, category_code, location, city, country)
VALUES
    (
        'Test Retail Store',
        'RETAIL',
        ST_GeomFromText('POINT(77.5946 12.9716)', 4326, 'axis-order=long-lat'),
        'Bengaluru',
        'IND'
    ),
    (
        'Test Digital Exchange',
        'CRYPTO',
        ST_GeomFromText('POINT(77.6000 12.9800)', 4326, 'axis-order=long-lat'),
        'Bengaluru',
        'IND'
    );

SET @merchant_retail = (
    SELECT merchant_id
    FROM merchants
    WHERE merchant_name = 'Test Retail Store'
);

SET @merchant_crypto = (
    SELECT merchant_id
    FROM merchants
    WHERE merchant_name = 'Test Digital Exchange'
);


-- ============================================================================
-- PART 7: COMPLIANCE OFFICERS AND FRAUD RULES
-- ============================================================================

INSERT INTO compliance_officers
    (badge_number, officer_name, clearance_level)
VALUES
    ('TEST-OFF-001', 'Officer Meera', 'LEVEL_1'),
    ('TEST-OFF-002', 'Officer Arjun', 'LEVEL_2');

SET @officer1 = (
    SELECT officer_id
    FROM compliance_officers
    WHERE badge_number = 'TEST-OFF-001'
);

SET @officer2 = (
    SELECT officer_id
    FROM compliance_officers
    WHERE badge_number = 'TEST-OFF-002'
);

INSERT INTO fraud_rules
    (rule_code, description, base_penalty_score)
VALUES
    ('AML_STRUCTURING_TEST',
     'Multiple small transfers within a short time window', 40),
    ('AML_VELOCITY_TEST',
     'Unusually frequent outgoing transactions', 30),
    ('AML_MULTIHOP_TEST',
     'Funds routed through multiple intermediate accounts', 50);

SET @rule_structuring = (
    SELECT rule_id FROM fraud_rules
    WHERE rule_code = 'AML_STRUCTURING_TEST'
);

SET @rule_velocity = (
    SELECT rule_id FROM fraud_rules
    WHERE rule_code = 'AML_VELOCITY_TEST'
);


-- ============================================================================
-- PART 8: INSERT TRANSACTION HISTORY
-- ============================================================================
-- All timestamps are explicitly separated to avoid collisions in the
-- generated idempotency_hash.
--
-- Pattern A:
--   Alice sends 5 small transfers within 10 minutes.
--   Candidate for both structuring and velocity rules.
--
-- Pattern B:
--   Alice -> Bob -> Carol -> David.
--   Candidate for rapid pass-through and multi-hop analysis.
--
-- Pattern C:
--   A merchant payment.
--
-- These are synthetic test events, not evidence of actual wrongdoing.
-- ============================================================================

INSERT INTO transactions
    (sender_account_id, receiver_account_id, merchant_id,
     amount, currency, transaction_type, status, created_at)
VALUES
    -- Five small outgoing transactions from Alice.
    (@acc_alice, @acc_bob, NULL,
     1900.00, 'USD', 'P2P_TRANSFER', 'COMPLETED',
     CURRENT_TIMESTAMP(3) - INTERVAL 50 MINUTE),

    (@acc_alice, @acc_bob, NULL,
     1800.00, 'USD', 'P2P_TRANSFER', 'COMPLETED',
     CURRENT_TIMESTAMP(3) - INTERVAL 48 MINUTE),

    (@acc_alice, @acc_carol, NULL,
     1700.00, 'USD', 'P2P_TRANSFER', 'COMPLETED',
     CURRENT_TIMESTAMP(3) - INTERVAL 46 MINUTE),

    (@acc_alice, @acc_david, NULL,
     1600.00, 'USD', 'P2P_TRANSFER', 'COMPLETED',
     CURRENT_TIMESTAMP(3) - INTERVAL 44 MINUTE),

    (@acc_alice, @acc_eva, NULL,
     1500.00, 'USD', 'P2P_TRANSFER', 'COMPLETED',
     CURRENT_TIMESTAMP(3) - INTERVAL 42 MINUTE),

    -- A multi-hop chain: Alice -> Bob -> Carol -> David.
    (@acc_bob, @acc_carol, NULL,
     1200.00, 'USD', 'P2P_TRANSFER', 'COMPLETED',
     CURRENT_TIMESTAMP(3) - INTERVAL 39 MINUTE),

    (@acc_carol, @acc_david, NULL,
     900.00, 'USD', 'P2P_TRANSFER', 'COMPLETED',
     CURRENT_TIMESTAMP(3) - INTERVAL 35 MINUTE),

    -- Merchant payment example.
    (@acc_eva, @acc_alice, @merchant_retail,
     250.00, 'USD', 'MERCHANT_PAYMENT', 'COMPLETED',
     CURRENT_TIMESTAMP(3) - INTERVAL 20 MINUTE),

    -- A pending transaction for status-transition tests.
    (@acc_bob, @acc_eva, NULL,
     100.00, 'USD', 'P2P_TRANSFER', 'PENDING',
     CURRENT_TIMESTAMP(3) - INTERVAL 10 MINUTE);


SET @tx_alice_bob = (
    SELECT transaction_id
    FROM transactions
    WHERE sender_account_id = @acc_alice
      AND receiver_account_id = @acc_bob
      AND amount = 1900.00
    ORDER BY transaction_id DESC
    LIMIT 1
);

SET @tx_pending = (
    SELECT transaction_id
    FROM transactions
    WHERE sender_account_id = @acc_bob
      AND receiver_account_id = @acc_eva
      AND status = 'PENDING'
    ORDER BY transaction_id DESC
    LIMIT 1
);


-- ============================================================================
-- PART 9: TERNARY RELATIONSHIP TEST DATA
-- ============================================================================
-- Each audit associates one transaction, one officer, and one fraud rule.
-- ============================================================================

INSERT INTO transaction_audits
    (transaction_id, officer_id, rule_id, review_outcome, notes)
VALUES
    (@tx_alice_bob, @officer1, @rule_structuring,
     'ESCALATED', 'Synthetic test case for repeated small transfers'),

    (@tx_alice_bob, @officer2, @rule_velocity,
     'REPORTED_TO_REGULATOR', 'Synthetic test case for high velocity');


-- ============================================================================
-- PART 10: TEST GENERATED COLUMNS AND RELATIONSHIPS
-- ============================================================================

-- Test 1: One user can own accounts; each account has one owner.
SELECT
    user_id,
    full_name,
    account_id,
    account_number,
    total_balance,
    held_funds,
    available_balance
FROM v_account_summary
ORDER BY user_id, account_id;


-- Test 2: M:N relationship between users and organizations.
SELECT
    u.full_name,
    o.legal_name,
    uor.role,
    uor.equity_percentage
FROM user_organization_roles uor
JOIN users u ON u.user_id = uor.user_id
JOIN organizations o ON o.org_id = uor.org_id
ORDER BY u.full_name, o.legal_name;


-- Test 3: Transaction details and optional merchant.
SELECT *
FROM v_transaction_details
ORDER BY created_at;


-- Test 4: Verify generated transaction hashes.
SELECT
    transaction_id,
    sender_account_id,
    receiver_account_id,
    amount,
    created_at,
    idempotency_hash
FROM transactions
ORDER BY transaction_id;


-- Test 5: Verify the ternary audit relationship.
SELECT *
FROM v_compliance_audit_report
ORDER BY audit_id;


-- ============================================================================
-- PART 11: TEST USER-DEFINED FUNCTIONS
-- ============================================================================

SELECT
    fn_transaction_risk_score(12000.00, 'WIRE') AS example_risk_score,
    fn_risk_category(
        fn_transaction_risk_score(12000.00, 'WIRE')
    ) AS example_risk_category;


SELECT
    account_id,
    account_number,
    fn_available_balance(account_id) AS function_balance,
    available_balance AS generated_column_balance
FROM accounts;


-- ============================================================================
-- PART 12: TEST TRIGGER-GENERATED HISTORY
-- ============================================================================

-- Hold and release funds through the stored procedures.
-- These operations should create account_balance_history rows.

CALL sp_hold_funds(@acc_alice, 50.00);

SELECT
    account_id,
    total_balance,
    held_funds,
    available_balance
FROM accounts
WHERE account_id = @acc_alice;

CALL sp_release_held_funds(@acc_alice, 50.00);

SELECT *
FROM account_balance_history
WHERE account_id = @acc_alice
ORDER BY history_id;


-- ============================================================================
-- PART 13: TEST SUCCESSFUL ATOMIC TRANSFER
-- ============================================================================

-- Transfers $25 from Alice to Bob.
-- Expected:
--   Alice's total balance decreases by $25.
--   Bob's total balance increases by $25.
--   A completed P2P transaction is inserted.
--   Balance-history and transaction-event triggers fire.

CALL sp_transfer_funds(@acc_alice, @acc_bob, 25.00);

SELECT
    account_id,
    account_number,
    total_balance,
    available_balance
FROM accounts
WHERE account_id IN (@acc_alice, @acc_bob);

SELECT *
FROM transaction_event_log
ORDER BY event_id DESC
LIMIT 10;


-- ============================================================================
-- PART 14: VERIFY VIEWS
-- ============================================================================

SELECT * FROM v_customer_transaction_summary;

SELECT * FROM v_high_risk_transactions;

SELECT * FROM v_merchant_transaction_summary;


-- ============================================================================
-- PART 15: REVIEW AML RESULTS
-- ============================================================================
-- Execute the individual AML queries from 06_aml_rules.sql after this script.
--
-- Expected patterns:
--   Rule 1: Alice's five small outgoing transfers should be candidates.
--   Rule 2: Alice's five outgoing transfers should meet the 5-in-10-minute
--           velocity criterion.
--   Rule 3: Bob and Carol have incoming funds followed by outgoing transfers.
--   Rule 4: Multi-hop paths can include Alice -> Bob -> Carol -> David.
--
-- Actual results depend on timestamps, successful script execution, and the
-- exact detection query.
-- ============================================================================

-- ============================================================================
-- END OF TEST CASES
-- ============================================================================