import argparse
import random
import time

import mysql.connector

from demo_common import mysql_connection, reference_ids, seed_reference_data
from ingestion import transfer_funds


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inject-fraud", action="store_true")
    parser.add_argument("--rate", type=float, default=2.0)
    parser.add_argument("--max-transactions", type=int, default=1000)
    parser.add_argument("--max-amount", type=float, default=10000.0)
    args = parser.parse_args()
    if args.rate <= 0 or args.max_transactions < 1 or args.max_amount < 100:
        raise ValueError("rate, max-transactions, and max-amount must be positive")

    connection = mysql_connection()
    seed_reference_data(connection)
    accounts = reference_ids(connection)
    if len(accounts) < 2:
        raise RuntimeError("At least two seeded accounts are required")

    fraud_sender, fraud_receiver = accounts[0], accounts[1]
    n = 0
    while n < args.max_transactions:
        if args.inject_fraud:
            sender, receiver = fraud_sender, fraud_receiver
        else:
            sender, receiver = random.sample(accounts, 2)
        balance_cursor = connection.cursor()
        balance_cursor.execute(
            "SELECT available_balance FROM accounts WHERE account_id = %s",
            (sender,),
        )
        available = balance_cursor.fetchone()[0]
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
        n += 1
    while True:
        time.sleep(3)
if __name__ == "__main__":
    main()
