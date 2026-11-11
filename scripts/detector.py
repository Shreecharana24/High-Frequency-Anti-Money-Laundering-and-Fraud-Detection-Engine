import json
import os
import time
from collections.abc import Callable
from datetime import datetime

import clickhouse_connect
import mysql.connector

from demo_common import mysql_connection


RuleQuery = Callable[[mysql.connector.cursor.MySQLCursorDict], list[dict]]


def _query_rows(cursor: mysql.connector.cursor.MySQLCursorDict, query: str) -> list[dict]:
    cursor.execute(query)
    return list(cursor.fetchall())


def _rule_queries() -> dict[str, tuple[str, str, str]]:
    return {
        "AML_STRUCTURING": (
            """
            SELECT anchor.transaction_id, anchor.sender_account_id,
                   COUNT(*) AS transaction_count, SUM(candidate.amount) AS total_amount,
                   MIN(anchor.created_at) AS window_start
            FROM transactions anchor
            JOIN transactions candidate
              ON candidate.sender_account_id = anchor.sender_account_id
             AND candidate.currency = anchor.currency
             AND candidate.status = 'COMPLETED'
             AND candidate.amount < 10000
             AND candidate.created_at >= anchor.created_at
             AND candidate.created_at < anchor.created_at + INTERVAL 24 HOUR
            WHERE anchor.status = 'COMPLETED'
              AND anchor.amount < 10000
            GROUP BY anchor.transaction_id, anchor.sender_account_id
            HAVING COUNT(*) >= 3
            """,
            "HIGH",
            "Possible structuring: repeated sub-threshold transfers in 24 hours",
        ),
        "AML_VELOCITY": (
            """
            SELECT anchor.transaction_id, anchor.sender_account_id,
                   COUNT(*) AS transaction_count, SUM(candidate.amount) AS total_amount,
                   MIN(anchor.created_at) AS window_start
            FROM transactions anchor
            JOIN transactions candidate
              ON candidate.sender_account_id = anchor.sender_account_id
             AND candidate.currency = anchor.currency
             AND candidate.status = 'COMPLETED'
             AND candidate.created_at >= anchor.created_at
             AND candidate.created_at < anchor.created_at + INTERVAL 10 MINUTE
            WHERE anchor.status = 'COMPLETED'
            GROUP BY anchor.transaction_id, anchor.sender_account_id
            HAVING COUNT(*) >= 5
            """,
            "CRITICAL",
            "High transaction velocity: five or more transfers in ten minutes",
        ),
        "AML_PASS_THROUGH": (
            """
            SELECT i.incoming_transaction_id AS transaction_id,
                   i.account_id AS sender_account_id,
                   o.outgoing_transaction_id AS related_transaction_id,
                   TIMESTAMPDIFF(MINUTE, i.received_at, o.sent_at) AS minutes_between,
                   i.incoming_amount, o.outgoing_amount
            FROM (
                SELECT transaction_id AS incoming_transaction_id,
                       receiver_account_id AS account_id, amount AS incoming_amount,
                       currency, created_at AS received_at
                FROM transactions WHERE status = 'COMPLETED'
            ) i
            JOIN (
                SELECT transaction_id AS outgoing_transaction_id,
                       sender_account_id AS account_id, amount AS outgoing_amount,
                       currency, created_at AS sent_at
                FROM transactions WHERE status = 'COMPLETED'
            ) o ON o.account_id = i.account_id
              AND o.currency = i.currency
              AND o.sent_at >= i.received_at
              AND o.sent_at <= i.received_at + INTERVAL 60 MINUTE
            WHERE o.outgoing_amount <= i.incoming_amount
            """,
            "HIGH",
            "Rapid pass-through: received funds were sent onward within one hour",
        ),
        "AML_MULTI_HOP": (
            """
            SELECT first_tx.transaction_id, first_tx.sender_account_id,
                   second_tx.receiver_account_id AS destination_account_id,
                   first_tx.receiver_account_id AS intermediary_account_id
            FROM transactions first_tx
            JOIN transactions second_tx
              ON second_tx.sender_account_id = first_tx.receiver_account_id
             AND second_tx.status = 'COMPLETED'
             AND second_tx.created_at >= first_tx.created_at
             AND second_tx.created_at <= first_tx.created_at + INTERVAL 24 HOUR
            WHERE first_tx.status = 'COMPLETED'
              AND first_tx.sender_account_id <> second_tx.receiver_account_id
            """,
            "CRITICAL",
            "Multi-hop chain: funds moved through an intermediary account",
        ),
        "AML_HIGH_VALUE": (
            """
            SELECT transaction_id, sender_account_id, amount
            FROM transactions
            WHERE status = 'COMPLETED' AND amount >= 10000
            """,
            "HIGH",
            "High-value transfer: amount exceeded the configured threshold",
        ),
        "AML_HIGH_RISK_CUSTOMER": (
            """
            SELECT t.transaction_id, t.sender_account_id, u.risk_level
            FROM transactions t
            JOIN accounts a ON a.account_id = t.sender_account_id
            JOIN users u ON u.user_id = a.user_id
            WHERE t.status = 'COMPLETED'
              AND u.risk_level IN ('HIGH', 'CRITICAL')
            """,
            "HIGH",
            "High-risk customer activity: sender has elevated customer risk",
        ),
    }


def _ensure_rule_ids(cursor: mysql.connector.cursor.MySQLCursorDict) -> dict[str, int]:
    cursor.execute("SELECT rule_id, rule_code FROM fraud_rules")
    return {row["rule_code"]: int(row["rule_id"]) for row in cursor.fetchall()}


def _create_alert(
    connection: mysql.connector.MySQLConnection,
    rule_id: int,
    rule_code: str,
    severity: str,
    title: str,
    row: dict,
) -> bool:
    transaction_id = row.get("transaction_id")
    account_id = row.get("sender_account_id")
    alert_key = f"detector:{rule_code}:{transaction_id}:{account_id}"
    score = {"LOW": 25, "MEDIUM": 50, "HIGH": 75, "CRITICAL": 95}[severity]
    evidence = json.dumps(
        {key: value.isoformat() if isinstance(value, datetime) else value for key, value in row.items()},
        default=str,
    )
    cursor = connection.cursor()
    try:
        cursor.execute(
            """
            INSERT IGNORE INTO fraud_alerts
                (transaction_id, account_id, rule_id, alert_key, severity,
                 risk_score, status, title, summary, detected_at)
            VALUES (%s, %s, %s, %s, %s, %s, 'OPEN', %s, %s, CURRENT_TIMESTAMP(3))
            """,
            (transaction_id, account_id, rule_id, alert_key, severity, score, title, title),
        )
        if cursor.rowcount == 0:
            connection.rollback()
            return False
        alert_id = cursor.lastrowid
        cursor.execute(
            """
            INSERT INTO fraud_alert_evidence
                (alert_id, evidence_type, evidence_data)
            VALUES (%s, 'AMOUNT_AGGREGATE', %s)
            """,
            (alert_id, evidence),
        )
        connection.commit()
        return True
    except mysql.connector.Error:
        connection.rollback()
        raise
    finally:
        cursor.close()


def _process_rules(connection: mysql.connector.MySQLConnection) -> int:
    cursor = connection.cursor(dictionary=True)
    try:
        rule_ids = _ensure_rule_ids(cursor)
        created = 0
        for rule_code, (query, severity, title) in _rule_queries().items():
            rule_id = rule_ids.get(rule_code)
            if rule_id is None:
                raise RuntimeError(f"Configured detection rule is missing: {rule_code}")
            rows = _query_rows(cursor, query)
            run_started = datetime.now()
            cursor.execute(
                """
                INSERT INTO rule_execution_runs
                    (rule_id, execution_started_at, execution_status, records_scanned)
                VALUES (%s, %s, 'RUNNING', %s)
                """,
                (rule_id, run_started, len(rows)),
            )
            run_id = cursor.lastrowid
            connection.commit()
            rule_created = 0
            for row in rows:
                if _create_alert(connection, rule_id, rule_code, severity, title, row):
                    rule_created += 1
                    created += 1
            cursor.execute(
                """
                UPDATE rule_execution_runs
                SET execution_finished_at = CURRENT_TIMESTAMP(3),
                    execution_status = 'SUCCEEDED',
                    alerts_created = %s
                WHERE run_id = %s
                """,
                (rule_created, run_id),
            )
            connection.commit()
        return created
    finally:
        cursor.close()


def _mirror_transactions(
    mysql: mysql.connector.MySQLConnection,
    clickhouse: clickhouse_connect.driver.Client,
) -> int:
    mysql_cursor = mysql.cursor(dictionary=True)
    try:
        current = clickhouse.query(
            "SELECT coalesce(max(transaction_id), 0) FROM aml_detection.transactions"
        ).result_rows[0][0]
        mysql_cursor.execute(
            """
            SELECT transaction_id, sender_account_id, receiver_account_id,
                   amount, created_at, status
            FROM transactions
            WHERE transaction_id > %s
            ORDER BY transaction_id
            """,
            (current,),
        )
        rows = list(mysql_cursor.fetchall())
        if rows:
            clickhouse.insert(
                "aml_detection.transactions",
                [
                    (
                        row["transaction_id"],
                        row["sender_account_id"],
                        row["receiver_account_id"],
                        row["amount"],
                        row["created_at"],
                        row["status"],
                    )
                    for row in rows
                ],
                column_names=[
                    "transaction_id",
                    "sender_account_id",
                    "receiver_account_id",
                    "amount",
                    "created_at",
                    "status",
                ],
            )
        return len(rows)
    finally:
        mysql_cursor.close()


def main() -> None:
    mysql = mysql_connection()
    clickhouse = clickhouse_connect.get_client(
        host=os.getenv("CLICKHOUSE_HOST", "localhost"),
        port=8123,
    )
    while True:
        mirrored = _mirror_transactions(mysql, clickhouse)
        alerts = _process_rules(mysql)
        if mirrored or alerts:
            print(
                f"Processed {mirrored} new transactions and created {alerts} new alerts",
                flush=True,
            )
        time.sleep(5)


if __name__ == "__main__":
    main()
