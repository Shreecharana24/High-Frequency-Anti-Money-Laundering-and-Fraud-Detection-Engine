import argparse
import random
import time
from collections import defaultdict
from decimal import Decimal
from typing import Any

import mysql.connector

from demo_common import mysql_connection, reference_ids, seed_reference_data
from ingestion import transfer_funds


GENERATION_COUNT = 1000
MIN_GENERATED_AMOUNT = 100
MAX_GENERATED_AMOUNT = 200
WORKER_RATE = 50


def _claim_generation_job(
    connection: mysql.connector.MySQLConnection,
) -> dict[str, Any] | None:
    cursor = connection.cursor(dictionary=True)
    try:
        connection.start_transaction()
        cursor.execute(
            """
            SELECT job_id, requested_count
            FROM transaction_generation_jobs
            WHERE status = 'QUEUED'
            ORDER BY job_id
            LIMIT 1
            FOR UPDATE SKIP LOCKED
            """
        )
        job = cursor.fetchone()
        if job is None:
            connection.rollback()
            return None
        cursor.execute(
            """
            UPDATE transaction_generation_jobs
            SET status = 'RUNNING', started_at = CURRENT_TIMESTAMP(3)
            WHERE job_id = %s
            """,
            (job["job_id"],),
        )
        connection.commit()
        return job
    except mysql.connector.Error:
        connection.rollback()
        raise
    finally:
        cursor.close()


def _eligible_accounts(
    connection: mysql.connector.MySQLConnection, requested_count: int
) -> list[int]:
    cursor = connection.cursor(dictionary=True)
    try:
        cursor.execute(
            """
            SELECT account_id, currency, available_balance
            FROM accounts a
            JOIN users u ON u.user_id = a.user_id
            WHERE u.is_frozen = FALSE
            ORDER BY account_id
            """
        )
        rows = cursor.fetchall()
    finally:
        cursor.close()

    currency_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        currency_groups[row["currency"]].append(row)

    eligible_groups: list[list[dict[str, Any]]] = []
    for group in currency_groups.values():
        if len(group) < 2:
            continue
        for index, account in enumerate(group):
            send_count = requested_count // len(group) + (
                1 if index < requested_count % len(group) else 0
            )
            minimum_balance = Decimal(send_count * MAX_GENERATED_AMOUNT)
            if Decimal(account["available_balance"]) < minimum_balance:
                break
        else:
            eligible_groups.append(group)

    if not eligible_groups:
        raise RuntimeError(
            "No same-currency account group has sufficient funds for 1,000 transactions"
        )
    selected_group = max(eligible_groups, key=len)
    return [int(account["account_id"]) for account in selected_group]


def _update_generation_job(
    connection: mysql.connector.MySQLConnection,
    job_id: int,
    status: str,
    generated_count: int,
    error_message: str | None = None,
) -> None:
    cursor = connection.cursor()
    try:
        cursor.execute(
            """
            UPDATE transaction_generation_jobs
            SET status = %s,
                generated_count = %s,
                error_message = %s,
                finished_at = CASE
                    WHEN %s IN ('COMPLETED', 'FAILED')
                    THEN CURRENT_TIMESTAMP(3)
                    ELSE finished_at
                END
            WHERE job_id = %s
            """,
            (status, generated_count, error_message, status, job_id),
        )
        connection.commit()
    except mysql.connector.Error:
        connection.rollback()
        raise
    finally:
        cursor.close()


def _process_generation_job(
    connection: mysql.connector.MySQLConnection, job: dict[str, Any]
) -> None:
    job_id = int(job["job_id"])
    generated_count = 0
    try:
        requested_count = int(job["requested_count"])
        if requested_count != GENERATION_COUNT:
            raise RuntimeError("Generation jobs must request exactly 1,000 transactions")
        accounts = _eligible_accounts(connection, requested_count)
        for index in range(requested_count):
            sender = accounts[index % len(accounts)]
            receiver = accounts[(index + 1) % len(accounts)]
            amount = round(random.uniform(MIN_GENERATED_AMOUNT, MAX_GENERATED_AMOUNT), 2)
            transfer_funds(connection, sender, receiver, amount)
            generated_count += 1
            if generated_count % 25 == 0 or generated_count == requested_count:
                _update_generation_job(
                    connection, job_id, "RUNNING", generated_count
                )
            time.sleep(1 / WORKER_RATE)
        _update_generation_job(
            connection, job_id, "COMPLETED", generated_count
        )
        print(
            f"Completed transaction generation job {job_id}: {generated_count} rows",
            flush=True,
        )
    except (mysql.connector.Error, RuntimeError, ValueError) as error:
        connection.rollback()
        _update_generation_job(
            connection, job_id, "FAILED", generated_count, str(error)[:2000]
        )
        print(
            f"Transaction generation job {job_id} failed after "
            f"{generated_count} rows: {error}",
            flush=True,
        )


def _run_worker() -> None:
    while True:
        connection = None
        try:
            connection = mysql_connection()
            job = _claim_generation_job(connection)
            if job is None:
                time.sleep(1)
            else:
                _process_generation_job(connection, job)
        except mysql.connector.Error as error:
            print(f"Generation worker database error: {error}", flush=True)
            time.sleep(2)
        finally:
            if connection is not None:
                connection.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--inject-fraud", action="store_true")
    parser.add_argument("--rate", type=float, default=2.0)
    parser.add_argument("--max-transactions", type=int, default=1000)
    parser.add_argument("--max-amount", type=float, default=10000.0)
    args = parser.parse_args()
    if args.worker:
        _run_worker()
        return
    if args.rate <= 0 or args.max_transactions < 1 or args.max_amount < 100:
        raise ValueError("rate, max-transactions, and max-amount must be positive")

    connection = mysql_connection()
    try:
        seed_reference_data(connection)
        accounts = reference_ids(connection)
        if len(accounts) < 2:
            raise RuntimeError("At least two seeded accounts are required")

        fraud_sender, fraud_receiver = accounts[0], accounts[1]
        generated = 0
        while generated < args.max_transactions:
            if args.inject_fraud:
                sender, receiver = fraud_sender, fraud_receiver
            else:
                sender, receiver = random.sample(accounts, 2)
            balance_cursor = connection.cursor()
            try:
                balance_cursor.execute(
                    "SELECT available_balance FROM accounts WHERE account_id = %s",
                    (sender,),
                )
                available = balance_cursor.fetchone()[0]
            finally:
                balance_cursor.close()
            if available < 100:
                print(
                    f"Generator stopped: account {sender} has only "
                    f"${available:.2f} available",
                    flush=True,
                )
                break
            amount = round(random.uniform(100, min(args.max_amount, float(available))), 2)
            try:
                transaction_id = transfer_funds(connection, sender, receiver, amount)
            except mysql.connector.Error as error:
                print(f"Transaction rejected: {error.msg}", flush=True)
                time.sleep(1 / args.rate)
                continue
            print(f"Generated transaction {transaction_id}: ${amount:.2f}", flush=True)
            time.sleep(1 / args.rate)
            generated += 1
    finally:
        connection.close()


if __name__ == "__main__":
    main()
