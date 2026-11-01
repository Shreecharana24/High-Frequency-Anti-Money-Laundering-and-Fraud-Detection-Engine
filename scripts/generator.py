import argparse
import random
import time

from demo_common import mysql_connection, reference_ids, seed_reference_data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inject-fraud", action="store_true")
    parser.add_argument("--rate", type=float, default=2.0)
    args = parser.parse_args()

    connection = mysql_connection()
    seed_reference_data(connection)
    accounts = reference_ids(connection)
    if len(accounts) < 2:
        raise RuntimeError("At least two seeded accounts are required")

    cursor = connection.cursor()
    fraud_sender, fraud_receiver = accounts[0], accounts[1]
    n = 0 # counter for the number of transactions generated
    while n < 1000: # limited to 1000 transactions for testing purposes. keep it like this for now, but we can change it later if needed
        if args.inject_fraud:
            sender, receiver = fraud_sender, fraud_receiver
        else:
            sender, receiver = random.sample(accounts, 2)
        amount = round(random.uniform(100, 10000), 2)
        cursor.execute(
            """
            INSERT INTO transactions
                (sender_account_id, receiver_account_id, amount,
                 transaction_type, status)
            VALUES (%s, %s, %s, 'P2P_TRANSFER', 'COMPLETED')
            """,
            (sender, receiver, amount),
        )
        connection.commit()
        print(f"Generated transaction {cursor.lastrowid}: ${amount:.2f}", flush=True)
        time.sleep((1 / args.rate) + 3 )        # added 3 seconds to slow down the generation of transactions
        n += 1
    while True:
        time.sleep(3) # keep the script running to allow for detection of transactions
if __name__ == "__main__":
    main()
