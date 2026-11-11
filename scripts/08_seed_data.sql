-- ============================================================================
-- 08_seed_data.sql
-- Deterministic development data for the AML operations platform.
--
-- Every reference and operational table receives at least ten rows. The
-- dataset contains both normal activity and known synthetic risk patterns.
-- It is safe to run only on a fresh development database.
-- ============================================================================

USE aml_bank_db;

SET FOREIGN_KEY_CHECKS = 0;

TRUNCATE TABLE fraud_alert_evidence;
TRUNCATE TABLE fraud_alert_review_history;
TRUNCATE TABLE fraud_alerts;
TRUNCATE TABLE rule_execution_runs;
TRUNCATE TABLE transaction_audits;
TRUNCATE TABLE transactions;
TRUNCATE TABLE transaction_event_log;
TRUNCATE TABLE account_balance_history;
TRUNCATE TABLE accounts;
TRUNCATE TABLE user_organization_roles;
TRUNCATE TABLE user_kyc_profiles;
TRUNCATE TABLE merchants;
TRUNCATE TABLE compliance_officers;
TRUNCATE TABLE fraud_rules;
TRUNCATE TABLE organizations;
TRUNCATE TABLE users;

SET FOREIGN_KEY_CHECKS = 1;

INSERT INTO users
    (user_id, full_name, email, phone, risk_level, is_frozen)
VALUES
    (1, 'Alice Sharma', 'alice@example.com', '9000000001', 'LOW', FALSE),
    (2, 'Bob Kumar', 'bob@example.com', '9000000002', 'MEDIUM', FALSE),
    (3, 'Carol Rao', 'carol@example.com', '9000000003', 'HIGH', FALSE),
    (4, 'David Singh', 'david@example.com', '9000000004', 'LOW', FALSE),
    (5, 'Eva Nair', 'eva@example.com', '9000000005', 'CRITICAL', FALSE),
    (6, 'Farhan Ali', 'farhan@example.com', '9000000006', 'MEDIUM', FALSE),
    (7, 'Grace Joseph', 'grace@example.com', '9000000007', 'LOW', FALSE),
    (8, 'Hari Menon', 'hari@example.com', '9000000008', 'HIGH', FALSE),
    (9, 'Isha Patel', 'isha@example.com', '9000000009', 'LOW', FALSE),
    (10, 'Jacob Thomas', 'jacob@example.com', '9000000010', 'MEDIUM', FALSE);

INSERT INTO user_kyc_profiles
    (user_id, national_id_hash, document_type, verification_status, verified_at)
VALUES
    (1, SHA2('SEED-ID-001', 256), 'NATIONAL_ID', 'VERIFIED', CURRENT_TIMESTAMP),
    (2, SHA2('SEED-ID-002', 256), 'PASSPORT', 'VERIFIED', CURRENT_TIMESTAMP),
    (3, SHA2('SEED-ID-003', 256), 'NATIONAL_ID', 'VERIFIED', CURRENT_TIMESTAMP),
    (4, SHA2('SEED-ID-004', 256), 'DRIVING_LICENSE', 'VERIFIED', CURRENT_TIMESTAMP),
    (5, SHA2('SEED-ID-005', 256), 'PASSPORT', 'VERIFIED', CURRENT_TIMESTAMP),
    (6, SHA2('SEED-ID-006', 256), 'NATIONAL_ID', 'VERIFIED', CURRENT_TIMESTAMP),
    (7, SHA2('SEED-ID-007', 256), 'PASSPORT', 'VERIFIED', CURRENT_TIMESTAMP),
    (8, SHA2('SEED-ID-008', 256), 'NATIONAL_ID', 'VERIFIED', CURRENT_TIMESTAMP),
    (9, SHA2('SEED-ID-009', 256), 'DRIVING_LICENSE', 'VERIFIED', CURRENT_TIMESTAMP),
    (10, SHA2('SEED-ID-010', 256), 'PASSPORT', 'VERIFIED', CURRENT_TIMESTAMP);

INSERT INTO organizations (org_id, legal_name, tax_identifier, country)
VALUES
    (1, 'Green Finance Ltd', 'SEED-TAX-001', 'IND'),
    (2, 'Digital Trade Pvt Ltd', 'SEED-TAX-002', 'IND'),
    (3, 'Northstar Logistics', 'SEED-TAX-003', 'IND'),
    (4, 'Blue Ocean Exports', 'SEED-TAX-004', 'SGP'),
    (5, 'Summit Healthcare', 'SEED-TAX-005', 'USA'),
    (6, 'Riverbank Consulting', 'SEED-TAX-006', 'GBR'),
    (7, 'Metro Retail Group', 'SEED-TAX-007', 'ARE'),
    (8, 'Cedar Software Labs', 'SEED-TAX-008', 'CAN'),
    (9, 'Orchid Manufacturing', 'SEED-TAX-009', 'DEU'),
    (10, 'Harbor Energy Corp', 'SEED-TAX-010', 'AUS');

INSERT INTO user_organization_roles
    (user_id, org_id, role, equity_percentage)
VALUES
    (1, 1, 'DIRECTOR', 20.00),
    (2, 1, 'BENEFICIAL_OWNER', 35.00),
    (3, 2, 'SIGNATORY', 0.00),
    (4, 3, 'AUDITOR', 0.00),
    (5, 4, 'BENEFICIAL_OWNER', 60.00),
    (6, 5, 'DIRECTOR', 25.00),
    (7, 6, 'SIGNATORY', 0.00),
    (8, 7, 'BENEFICIAL_OWNER', 40.00),
    (9, 8, 'AUDITOR', 0.00),
    (10, 9, 'DIRECTOR', 15.00);

INSERT INTO accounts
    (account_id, user_id, account_number, account_type, total_balance,
     held_funds, currency)
VALUES
    (1, 1, 'SEED-ACC-001', 'SAVINGS', 100000.00, 0.00, 'USD'),
    (2, 2, 'SEED-ACC-002', 'CHECKING', 90000.00, 0.00, 'USD'),
    (3, 3, 'SEED-ACC-003', 'SAVINGS', 80000.00, 0.00, 'USD'),
    (4, 4, 'SEED-ACC-004', 'CHECKING', 70000.00, 0.00, 'USD'),
    (5, 5, 'SEED-ACC-005', 'CORPORATE', 200000.00, 10000.00, 'USD'),
    (6, 6, 'SEED-ACC-006', 'CHECKING', 60000.00, 0.00, 'USD'),
    (7, 7, 'SEED-ACC-007', 'SAVINGS', 50000.00, 0.00, 'USD'),
    (8, 8, 'SEED-ACC-008', 'CORPORATE', 150000.00, 5000.00, 'USD'),
    (9, 9, 'SEED-ACC-009', 'CHECKING', 40000.00, 0.00, 'USD'),
    (10, 10, 'SEED-ACC-010', 'SAVINGS', 30000.00, 0.00, 'USD');

INSERT INTO merchants
    (merchant_id, merchant_name, category_code, location, city, country)
VALUES
    (1, 'Bengaluru Retail', 'RETAIL',
     ST_GeomFromText('POINT(77.5946 12.9716)', 4326, 'axis-order=long-lat'),
     'Bengaluru', 'IND'),
    (2, 'Digital Exchange', 'CRYPTO',
     ST_GeomFromText('POINT(77.6000 12.9800)', 4326, 'axis-order=long-lat'),
     'Bengaluru', 'IND'),
    (3, 'Singapore Imports', 'IMPORT',
     ST_GeomFromText('POINT(103.8198 1.3521)', 4326, 'axis-order=long-lat'),
     'Singapore', 'SGP'),
    (4, 'London Services', 'SERVICES',
     ST_GeomFromText('POINT(-0.1276 51.5072)', 4326, 'axis-order=long-lat'),
     'London', 'GBR'),
    (5, 'New York Electronics', 'ELECTRONIC',
     ST_GeomFromText('POINT(-74.0060 40.7128)', 4326, 'axis-order=long-lat'),
     'New York', 'USA'),
    (6, 'Dubai Gold Market', 'PRECIOUS',
     ST_GeomFromText('POINT(55.2708 25.2048)', 4326, 'axis-order=long-lat'),
     'Dubai', 'ARE'),
    (7, 'Toronto Marketplace', 'MARKET',
     ST_GeomFromText('POINT(-79.3832 43.6532)', 4326, 'axis-order=long-lat'),
     'Toronto', 'CAN'),
    (8, 'Berlin Software', 'SOFTWARE',
     ST_GeomFromText('POINT(13.4050 52.5200)', 4326, 'axis-order=long-lat'),
     'Berlin', 'DEU'),
    (9, 'Sydney Travel', 'TRAVEL',
     ST_GeomFromText('POINT(151.2093 -33.8688)', 4326, 'axis-order=long-lat'),
     'Sydney', 'AUS'),
    (10, 'Mumbai Utilities', 'UTILITIES',
     ST_GeomFromText('POINT(72.8777 19.0760)', 4326, 'axis-order=long-lat'),
     'Mumbai', 'IND');

INSERT INTO compliance_officers
    (officer_id, badge_number, officer_name, clearance_level)
VALUES
    (1, 'SEED-OFF-001', 'Meera Iyer', 'LEVEL_1'),
    (2, 'SEED-OFF-002', 'Arjun Rao', 'LEVEL_2'),
    (3, 'SEED-OFF-003', 'Nisha Shah', 'ADMIN'),
    (4, 'SEED-OFF-004', 'Rohan Das', 'LEVEL_1'),
    (5, 'SEED-OFF-005', 'Priya Bose', 'LEVEL_2'),
    (6, 'SEED-OFF-006', 'Vikram Jain', 'ADMIN'),
    (7, 'SEED-OFF-007', 'Anita Roy', 'LEVEL_1'),
    (8, 'SEED-OFF-008', 'Karan Malik', 'LEVEL_2'),
    (9, 'SEED-OFF-009', 'Sonal Gupta', 'LEVEL_1'),
    (10, 'SEED-OFF-010', 'Neel Kapoor', 'ADMIN');

INSERT INTO fraud_rules
    (rule_id, rule_code, description, base_penalty_score)
VALUES
    (1, 'AML_STRUCTURING', 'Multiple small transfers within a 24-hour window', 40),
    (2, 'AML_VELOCITY', 'Five or more outgoing transfers within ten minutes', 50),
    (3, 'AML_PASS_THROUGH', 'Funds received and sent onward within sixty minutes', 45),
    (4, 'AML_MULTI_HOP', 'Funds routed through multiple intermediate accounts', 60),
    (5, 'AML_HIGH_VALUE', 'Transaction amount exceeds the high-value threshold', 55),
    (6, 'AML_HIGH_RISK_CUSTOMER', 'Transaction involves a high-risk customer', 50),
    (7, 'AML_MERCHANT_RISK', 'Transaction involves a high-risk merchant category', 45),
    (8, 'AML_NEW_ACCOUNT', 'Activity occurs shortly after account creation', 30),
    (9, 'AML_GEOGRAPHIC_ANOMALY', 'Activity crosses an unusual geography boundary', 35),
    (10, 'AML_PATTERN_COMBINATION', 'Multiple independent risk signals combine', 75);

-- A known velocity/structuring pattern, a pass-through chain, and clean
-- comparison activity. Explicit timestamps keep the fixture deterministic.
INSERT INTO transactions
    (transaction_id, sender_account_id, receiver_account_id, merchant_id,
     amount, currency, transaction_type, status, created_at)
VALUES
    (1, 1, 2, NULL, 1900.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 08:00:00.001'),
    (2, 1, 3, NULL, 1800.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 08:01:00.001'),
    (3, 1, 4, NULL, 1700.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 08:02:00.001'),
    (4, 1, 5, NULL, 1600.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 08:03:00.001'),
    (5, 1, 6, NULL, 1500.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 08:04:00.001'),
    (6, 2, 3, NULL, 1200.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 08:10:00.001'),
    (7, 3, 4, NULL, 900.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 08:20:00.001'),
    (8, 4, 5, NULL, 700.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 08:30:00.001'),
    (9, 5, 1, 1, 250.00, 'USD', 'MERCHANT_PAYMENT', 'COMPLETED', '2026-11-11 09:00:00.001'),
    (10, 6, 7, 2, 450.00, 'USD', 'MERCHANT_PAYMENT', 'COMPLETED', '2026-11-11 09:05:00.001'),
    (11, 7, 8, 3, 600.00, 'USD', 'MERCHANT_PAYMENT', 'COMPLETED', '2026-11-11 09:10:00.001'),
    (12, 8, 9, NULL, 5000.00, 'USD', 'WIRE', 'COMPLETED', '2026-11-11 09:20:00.001'),
    (13, 9, 10, NULL, 300.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 09:25:00.001'),
    (14, 10, 1, NULL, 275.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 09:30:00.001'),
    (15, 2, 5, NULL, 12500.00, 'USD', 'WIRE', 'COMPLETED', '2026-11-11 10:00:00.001'),
    (16, 3, 6, 4, 850.00, 'USD', 'MERCHANT_PAYMENT', 'COMPLETED', '2026-11-11 10:05:00.001'),
    (17, 4, 7, 5, 125.00, 'USD', 'MERCHANT_PAYMENT', 'COMPLETED', '2026-11-11 10:10:00.001'),
    (18, 6, 8, NULL, 2100.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 10:15:00.001'),
    (19, 7, 9, NULL, 1950.00, 'USD', 'P2P_TRANSFER', 'COMPLETED', '2026-11-11 10:20:00.001'),
    (20, 9, 2, NULL, 800.00, 'USD', 'P2P_TRANSFER', 'PENDING', '2026-11-11 10:25:00.001');

INSERT INTO account_balance_history
    (history_id, account_id, old_total_balance, new_total_balance,
     old_held_funds, new_held_funds, change_type, changed_at, changed_by)
VALUES
    (1, 1, 100000.00, 98100.00, 0.00, 0.00, 'WITHDRAWAL_OR_DEBIT', '2026-11-11 08:00:00.001', 'seed-fixture'),
    (2, 2, 90000.00, 91200.00, 0.00, 0.00, 'DEPOSIT_OR_CREDIT', '2026-11-11 08:10:00.001', 'seed-fixture'),
    (3, 3, 80000.00, 80900.00, 0.00, 0.00, 'DEPOSIT_OR_CREDIT', '2026-11-11 08:20:00.001', 'seed-fixture'),
    (4, 4, 70000.00, 70700.00, 0.00, 0.00, 'DEPOSIT_OR_CREDIT', '2026-11-11 08:30:00.001', 'seed-fixture'),
    (5, 5, 200000.00, 198400.00, 10000.00, 10000.00, 'WITHDRAWAL_OR_DEBIT', '2026-11-11 08:03:00.001', 'seed-fixture'),
    (6, 6, 60000.00, 61500.00, 0.00, 0.00, 'DEPOSIT_OR_CREDIT', '2026-11-11 08:04:00.001', 'seed-fixture'),
    (7, 7, 50000.00, 50450.00, 0.00, 0.00, 'DEPOSIT_OR_CREDIT', '2026-11-11 09:05:00.001', 'seed-fixture'),
    (8, 8, 150000.00, 147900.00, 5000.00, 5000.00, 'WITHDRAWAL_OR_DEBIT', '2026-11-11 09:20:00.001', 'seed-fixture'),
    (9, 9, 40000.00, 40250.00, 0.00, 0.00, 'DEPOSIT_OR_CREDIT', '2026-11-11 09:25:00.001', 'seed-fixture'),
    (10, 10, 30000.00, 30275.00, 0.00, 0.00, 'DEPOSIT_OR_CREDIT', '2026-11-11 09:30:00.001', 'seed-fixture');

INSERT INTO transaction_audits
    (audit_id, transaction_id, officer_id, rule_id, review_outcome, notes)
VALUES
    (1, 1, 1, 1, 'ESCALATED', 'Synthetic structuring evidence'),
    (2, 2, 2, 2, 'ESCALATED', 'Synthetic velocity evidence'),
    (3, 3, 3, 3, 'CLEARED', 'Reviewed pass-through context'),
    (4, 4, 4, 4, 'ESCALATED', 'Synthetic multi-hop evidence'),
    (5, 5, 5, 5, 'REPORTED_TO_REGULATOR', 'High-value review'),
    (6, 6, 6, 6, 'ESCALATED', 'High-risk customer review'),
    (7, 7, 7, 7, 'CLEARED', 'Merchant activity reviewed'),
    (8, 8, 8, 8, 'CLEARED', 'New-account signal reviewed'),
    (9, 9, 9, 9, 'ESCALATED', 'Geographic signal reviewed'),
    (10, 10, 10, 10, 'ESCALATED', 'Combined pattern review');

INSERT INTO fraud_alerts
    (alert_id, transaction_id, account_id, rule_id, alert_key, severity,
     risk_score, status, title, summary, detected_at, assigned_officer_id)
VALUES
    (1, 1, 1, 1, 'seed-structuring-001', 'HIGH', 70, 'OPEN',
     'Possible structuring', 'Repeated small outgoing transfers detected.', '2026-11-11 08:05:00.001', 1),
    (2, 5, 1, 2, 'seed-velocity-001', 'CRITICAL', 90, 'INVESTIGATING',
     'High transaction velocity', 'Five outgoing transfers occurred within ten minutes.', '2026-11-11 08:05:01.001', 2),
    (3, 6, 2, 3, 'seed-pass-through-001', 'HIGH', 65, 'OPEN',
     'Rapid pass-through', 'Funds were received and transferred onward quickly.', '2026-11-11 08:21:00.001', 3),
    (4, 8, 4, 4, 'seed-multihop-001', 'CRITICAL', 95, 'ESCALATED',
     'Multi-hop chain', 'Funds moved through multiple intermediate accounts.', '2026-11-11 08:31:00.001', 4),
    (5, 12, 8, 5, 'seed-high-value-001', 'HIGH', 75, 'OPEN',
     'High-value transfer', 'Wire amount exceeded the configured threshold.', '2026-11-11 09:21:00.001', 5),
    (6, 15, 2, 6, 'seed-high-risk-001', 'HIGH', 80, 'INVESTIGATING',
     'High-risk customer activity', 'A high-risk customer initiated a wire transfer.', '2026-11-11 10:01:00.001', 6),
    (7, 10, 6, 7, 'seed-merchant-risk-001', 'MEDIUM', 55, 'CLEARED',
     'Merchant risk signal', 'Payment matched a monitored merchant category.', '2026-11-11 09:06:00.001', 7),
    (8, 13, 9, 8, 'seed-new-account-001', 'MEDIUM', 45, 'OPEN',
     'New account activity', 'Activity occurred shortly after account opening.', '2026-11-11 09:26:00.001', 8),
    (9, 16, 3, 9, 'seed-geographic-001', 'MEDIUM', 50, 'OPEN',
     'Geographic anomaly', 'Transaction geography differs from the profile baseline.', '2026-11-11 10:06:00.001', 9),
    (10, 18, 6, 10, 'seed-combination-001', 'CRITICAL', 98, 'REPORTED',
     'Combined risk pattern', 'Multiple independent risk signals were correlated.', '2026-11-11 10:16:00.001', 10);

INSERT INTO fraud_alert_evidence
    (evidence_id, alert_id, evidence_type, evidence_data)
VALUES
    (1, 1, 'TIME_WINDOW', JSON_OBJECT('transactions', 5, 'window_minutes', 1440)),
    (2, 2, 'AMOUNT_AGGREGATE', JSON_OBJECT('transactions', 5, 'total_amount', 8500.00)),
    (3, 3, 'TRANSACTION', JSON_OBJECT('incoming_transaction_id', 1, 'outgoing_transaction_id', 6)),
    (4, 4, 'GRAPH_PATH', JSON_OBJECT('account_path', '1,2,3,4,5', 'hop_count', 4)),
    (5, 5, 'TRANSACTION', JSON_OBJECT('transaction_id', 12, 'amount', 5000.00)),
    (6, 6, 'CUSTOMER_RISK', JSON_OBJECT('customer_risk_level', 'MEDIUM', 'rule_score', 50)),
    (7, 7, 'COUNTERPARTY', JSON_OBJECT('merchant_id', 2, 'category_code', 'CRYPTO')),
    (8, 8, 'ACCOUNT', JSON_OBJECT('account_id', 9, 'account_age_days', 3)),
    (9, 9, 'COUNTERPARTY', JSON_OBJECT('merchant_id', 4, 'country', 'GBR')),
    (10, 10, 'AMOUNT_AGGREGATE', JSON_OBJECT('signals', 3, 'risk_score', 98));

INSERT INTO fraud_alert_review_history
    (review_id, alert_id, officer_id, action_type, previous_status, new_status, note)
VALUES
    (1, 1, 1, 'ASSIGNED', NULL, 'OPEN', 'Assigned for initial review'),
    (2, 2, 2, 'ASSIGNED', NULL, 'OPEN', 'Assigned to velocity specialist'),
    (3, 3, 3, 'NOTE_ADDED', 'OPEN', 'OPEN', 'Reviewed incoming and outgoing timing'),
    (4, 4, 4, 'STATUS_CHANGED', 'OPEN', 'ESCALATED', 'Escalated for multi-hop investigation'),
    (5, 5, 5, 'ASSIGNED', NULL, 'OPEN', 'Assigned for high-value review'),
    (6, 6, 6, 'STATUS_CHANGED', 'OPEN', 'INVESTIGATING', 'Customer risk context requested'),
    (7, 7, 7, 'STATUS_CHANGED', 'OPEN', 'CLEARED', 'Merchant activity verified'),
    (8, 8, 8, 'NOTE_ADDED', 'OPEN', 'OPEN', 'Account opening date reviewed'),
    (9, 9, 9, 'ASSIGNED', NULL, 'OPEN', 'Assigned for geography review'),
    (10, 10, 10, 'STATUS_CHANGED', 'OPEN', 'REPORTED', 'Synthetic report workflow example');

INSERT INTO rule_execution_runs
    (run_id, rule_id, execution_started_at, execution_finished_at,
     execution_status, records_scanned, alerts_created)
VALUES
    (1, 1, '2026-11-11 08:05:00.001', '2026-11-11 08:05:00.101', 'SUCCEEDED', 20, 1),
    (2, 2, '2026-11-11 08:05:01.001', '2026-11-11 08:05:01.101', 'SUCCEEDED', 20, 1),
    (3, 3, '2026-11-11 08:21:00.001', '2026-11-11 08:21:00.101', 'SUCCEEDED', 20, 1),
    (4, 4, '2026-11-11 08:31:00.001', '2026-11-11 08:31:00.101', 'SUCCEEDED', 20, 1),
    (5, 5, '2026-11-11 09:21:00.001', '2026-11-11 09:21:00.101', 'SUCCEEDED', 20, 1),
    (6, 6, '2026-11-11 10:01:00.001', '2026-11-11 10:01:00.101', 'SUCCEEDED', 20, 1),
    (7, 7, '2026-11-11 09:06:00.001', '2026-11-11 09:06:00.101', 'SUCCEEDED', 20, 1),
    (8, 8, '2026-11-11 09:26:00.001', '2026-11-11 09:26:00.101', 'SUCCEEDED', 20, 1),
    (9, 9, '2026-11-11 10:06:00.001', '2026-11-11 10:06:00.101', 'SUCCEEDED', 20, 1),
    (10, 10, '2026-11-11 10:16:00.001', '2026-11-11 10:16:00.101', 'SUCCEEDED', 20, 1);
