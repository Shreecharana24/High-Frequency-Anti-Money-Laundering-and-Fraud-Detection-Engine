import json
import os
import time
from datetime import datetime

import clickhouse_connect
import mysql.connector

from demo_common import mysql_connection


def _query_rows(
    clickhouse: clickhouse_connect.driver.Client, query: str
) -> list[dict]:
    result = clickhouse.query(query)
    return [dict(zip(result.column_names, row)) for row in result.result_rows]


def _rule_queries() -> dict[str, tuple[str, str, str]]:
    return {
        "AML_STRUCTURING": (
            """
            SELECT anchor.transaction_id AS transaction_id,
                   anchor.sender_account_id AS sender_account_id,
                   count() AS transaction_count,
                   sum(candidate.amount) AS total_amount,
                   min(anchor.created_at) AS window_start
            FROM aml_detection.transactions AS anchor
            INNER JOIN aml_detection.transactions AS candidate
              ON candidate.sender_account_id = anchor.sender_account_id
             AND candidate.currency = anchor.currency
            WHERE anchor.status = 'COMPLETED'
              AND anchor.amount < 10000
              AND candidate.status = 'COMPLETED'
              AND candidate.amount < 10000
              AND candidate.created_at >= anchor.created_at
              AND candidate.created_at < addHours(anchor.created_at, 24)
            GROUP BY anchor.transaction_id, anchor.sender_account_id
            HAVING count() >= 3
            """,
            "HIGH",
            "Possible structuring: repeated sub-threshold transfers in 24 hours",
        ),
        "AML_VELOCITY": (
            """
            SELECT anchor.transaction_id AS transaction_id,
                   anchor.sender_account_id AS sender_account_id,
                   count() AS transaction_count,
                   sum(candidate.amount) AS total_amount,
                   min(anchor.created_at) AS window_start
            FROM aml_detection.transactions AS anchor
            INNER JOIN aml_detection.transactions AS candidate
              ON candidate.sender_account_id = anchor.sender_account_id
             AND candidate.currency = anchor.currency
            WHERE anchor.status = 'COMPLETED'
              AND candidate.status = 'COMPLETED'
              AND candidate.created_at >= anchor.created_at
              AND candidate.created_at < addMinutes(anchor.created_at, 10)
            GROUP BY anchor.transaction_id, anchor.sender_account_id
            HAVING count() >= 5
            """,
            "CRITICAL",
            "High transaction velocity: five or more transfers in ten minutes",
        ),
        "AML_PASS_THROUGH": (
            """
            SELECT incoming.transaction_id AS transaction_id,
                   incoming.receiver_account_id AS sender_account_id,
                   outgoing.transaction_id AS related_transaction_id,
                   dateDiff('minute', incoming.created_at, outgoing.created_at)
                       AS minutes_between,
                   incoming.amount AS incoming_amount,
                   outgoing.amount AS outgoing_amount
            FROM aml_detection.transactions AS incoming
            INNER JOIN aml_detection.transactions AS outgoing
              ON outgoing.sender_account_id = incoming.receiver_account_id
             AND outgoing.currency = incoming.currency
            WHERE incoming.status = 'COMPLETED'
              AND outgoing.status = 'COMPLETED'
              AND outgoing.created_at >= incoming.created_at
              AND outgoing.created_at <= addMinutes(incoming.created_at, 60)
              AND outgoing.amount <= incoming.amount
            """,
            "HIGH",
            "Rapid pass-through: received funds were sent onward within one hour",
        ),
        "AML_MULTI_HOP": (
            """
            SELECT first_tx.transaction_id AS transaction_id,
                   first_tx.sender_account_id AS sender_account_id,
                   second_tx.receiver_account_id AS destination_account_id,
                   first_tx.receiver_account_id AS intermediary_account_id
            FROM aml_detection.transactions AS first_tx
            INNER JOIN aml_detection.transactions AS second_tx
              ON second_tx.sender_account_id = first_tx.receiver_account_id
            WHERE first_tx.status = 'COMPLETED'
              AND second_tx.status = 'COMPLETED'
              AND second_tx.created_at >= first_tx.created_at
              AND second_tx.created_at <= addHours(first_tx.created_at, 24)
              AND first_tx.sender_account_id <> second_tx.receiver_account_id
            """,
            "CRITICAL",
            "Multi-hop chain: funds moved through an intermediary account",
        ),
        "AML_HIGH_VALUE": (
            """
            SELECT transaction_id AS transaction_id,
                   sender_account_id AS sender_account_id,
                   amount AS amount
            FROM aml_detection.transactions
            WHERE status = 'COMPLETED' AND amount >= 10000
            """,
            "HIGH",
            "High-value transfer: amount exceeded the configured threshold",
        ),
        "AML_HIGH_RISK_CUSTOMER": (
            """
            SELECT transaction_id AS transaction_id,
                   sender_account_id AS sender_account_id,
                   sender_risk_level AS risk_level
            FROM aml_detection.transactions
            WHERE status = 'COMPLETED'
              AND sender_risk_level IN ('HIGH', 'CRITICAL')
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


def _process_rules(
    connection: mysql.connector.MySQLConnection,
    clickhouse: clickhouse_connect.driver.Client,
) -> int:
    cursor = connection.cursor(dictionary=True)
    try:
        rule_ids = _ensure_rule_ids(cursor)
        created = 0
        for rule_code, (query, severity, title) in _rule_queries().items():
            rule_id = rule_ids.get(rule_code)
            if rule_id is None:
                raise RuntimeError(f"Configured detection rule is missing: {rule_code}")
            rows = _query_rows(clickhouse, query)
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
            SELECT t.transaction_id, t.sender_account_id, t.receiver_account_id,
                   t.amount, t.currency, t.created_at, t.status,
                   u.risk_level AS sender_risk_level
            FROM transactions t
            JOIN accounts a ON a.account_id = t.sender_account_id
            JOIN users u ON u.user_id = a.user_id
            WHERE t.transaction_id > %s
            ORDER BY t.transaction_id
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
                        row["currency"],
                        row["created_at"],
                        row["status"],
                        row["sender_risk_level"],
                    )
                    for row in rows
                ],
                column_names=[
                    "transaction_id",
                    "sender_account_id",
                    "receiver_account_id",
                    "amount",
                    "currency",
                    "created_at",
                    "status",
                    "sender_risk_level",
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
        alerts = _process_rules(mysql, clickhouse)
        if mirrored or alerts:
            print(
                f"Processed {mirrored} new transactions and created {alerts} new alerts",
                flush=True,
            )
        time.sleep(5)


if __name__ == "__main__":
    main()
