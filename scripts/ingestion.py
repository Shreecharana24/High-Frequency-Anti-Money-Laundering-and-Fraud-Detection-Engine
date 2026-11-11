import mysql.connector


def transfer_funds(
    connection: mysql.connector.MySQLConnection,
    sender_account_id: int,
    receiver_account_id: int,
    amount: float,
) -> int:
    """Execute the authoritative atomic transfer procedure."""
    cursor = connection.cursor()
    try:
        cursor.execute(
            "CALL sp_transfer_funds(%s, %s, %s)",
            (sender_account_id, receiver_account_id, amount),
        )
        connection.commit()
        cursor.execute(
            """
            SELECT transaction_id
            FROM transactions
            WHERE sender_account_id = %s
              AND receiver_account_id = %s
              AND amount = %s
            ORDER BY transaction_id DESC
            LIMIT 1
            """,
            (sender_account_id, receiver_account_id, amount),
        )
        row = cursor.fetchone()
        if row is None:
            raise RuntimeError("Transfer procedure committed without a transaction")
        return int(row[0])
    except mysql.connector.Error:
        connection.rollback()
        raise
    finally:
        cursor.close()
