import os
import time

import mysql.connector


def mysql_connection():
    for _ in range(30):
        try:
            return mysql.connector.connect(
                host=os.getenv("MYSQL_HOST", "localhost"),
                user=os.getenv("MYSQL_USER", "aml_user"),
                password=os.getenv("MYSQL_PASSWORD", "aml_pass"),
                database=os.getenv("MYSQL_DATABASE", "aml_bank_db"),
            )
        except mysql.connector.Error:
            time.sleep(2)
    raise RuntimeError("Could not connect to MySQL")


def seed_reference_data(connection):
    cursor = connection.cursor()
    cursor.execute(
        """
        INSERT IGNORE INTO users (user_id, full_name, email, phone)
        VALUES (1, 'Demo Sender', 'sender@example.com', '5550000001'),
               (2, 'Demo Receiver', 'receiver@example.com', '5550000002')
        """
    )
    cursor.execute(
        """
        INSERT IGNORE INTO accounts
            (account_id, user_id, account_number, account_type, total_balance)
        VALUES (1, 1, 'DEMO00000000000001', 'CHECKING', 1000000.00),
               (2, 2, 'DEMO00000000000002', 'CHECKING', 1000000.00)
        """
    )
    cursor.execute(
        """
        INSERT IGNORE INTO compliance_officers
            (officer_id, badge_number, officer_name, clearance_level)
        VALUES (1, 'DEMO-OFFICER', 'Demo Compliance Officer', 'ADMIN')
        """
    )
    cursor.execute(
        """
        INSERT IGNORE INTO fraud_rules
            (rule_id, rule_code, description, base_penalty_score)
        VALUES (1, 'VELOCITY_5_IN_10S',
                'Five or more transactions from one sender within ten seconds',
                10)
        """
    )
    connection.commit()
    cursor.close()


def reference_ids(connection):
    cursor = connection.cursor()
    cursor.execute("SELECT account_id FROM accounts ORDER BY account_id")
    accounts = [row[0] for row in cursor.fetchall()]
    cursor.close()
    return accounts
