import os
import time

import clickhouse_connect

from demo_common import mysql_connection, seed_reference_data


def main():
    mysql = mysql_connection()
    seed_reference_data(mysql)
    clickhouse = clickhouse_connect.get_client(
        host=os.getenv("CLICKHOUSE_HOST", "localhost"),
        port=8123,
    )
    last_id = 0
    mysql_cursor = mysql.cursor(dictionary=True)

    while True:
        mysql_cursor.execute(
            """
            SELECT transaction_id, sender_account_id, receiver_account_id,
                   amount, created_at, status
            FROM transactions
            WHERE transaction_id > %s
            ORDER BY transaction_id
            """,
            (last_id,),
        )
        transactions = mysql_cursor.fetchall()
        if transactions:
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
                    for row in transactions
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
            for row in transactions:
                count = clickhouse.query(
                    """
                    SELECT count()
                    FROM aml_detection.transactions
                    WHERE sender_account_id = {sender:UInt64}
                      AND created_at BETWEEN
                          {created:DateTime64(3)} - INTERVAL 10 SECOND
                          AND {created:DateTime64(3)}
                    """,
                    parameters={
                        "sender": row["sender_account_id"],
                        "created": row["created_at"],
                    },
                ).result_rows[0][0]
                if count >= 5:
                    audit_cursor = mysql.cursor()
                    audit_cursor.execute(
                        """
                        INSERT IGNORE INTO transaction_audits
                            (transaction_id, officer_id, rule_id,
                             review_outcome, notes)
                        SELECT %s, officer_id, rule_id, 'ESCALATED',
                               'Five transactions from one sender within 10 seconds'
                        FROM compliance_officers, fraud_rules
                        WHERE badge_number = 'DEMO-OFFICER'
                          AND rule_code = 'VELOCITY_5_IN_10S'
                        """,
                        (row["transaction_id"],),
                    )
                    mysql.commit()
                    audit_cursor.close()
                    print(
                        f"FLAGGED transaction {row['transaction_id']} "
                        f"(sender {row['sender_account_id']}): velocity rule",
                        flush=True,
                    )
            last_id = transactions[-1]["transaction_id"]
        time.sleep(1)


if __name__ == "__main__":
    main()
