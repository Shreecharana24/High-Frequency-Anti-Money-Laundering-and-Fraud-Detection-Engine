import argparse
from getpass import getpass

import mysql.connector
from fastapi import HTTPException

from .api import _hash_password, _normalize_email
from .demo_common import mysql_connection


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create the first login account for an existing admin officer."
    )
    parser.add_argument(
        "--badge-number",
        required=True,
        help="Badge number of an existing ADMIN compliance officer",
    )
    args = parser.parse_args()

    try:
        email = _normalize_email(input("Admin email: "))
    except HTTPException as error:
        parser.error(error.detail)
    password = getpass("Password (at least 12 characters): ")
    confirmation = getpass("Confirm password: ")
    if len(password) < 12:
        parser.error("Password must contain at least 12 characters")
    if password != confirmation:
        parser.error("Passwords do not match")

    connection = mysql_connection()
    cursor = connection.cursor(dictionary=True)
    try:
        cursor.execute(
            """
            SELECT COUNT(*) AS active_admin_accounts
            FROM compliance_officers o
            JOIN compliance_officer_accounts a ON a.officer_id = o.officer_id
            WHERE o.clearance_level = 'ADMIN' AND a.is_active = TRUE
            """
        )
        if cursor.fetchone()["active_admin_accounts"] > 0:
            parser.error("An active admin account already exists; use the Admin API")
        cursor.execute(
            """
            SELECT officer_id, clearance_level
            FROM compliance_officers
            WHERE badge_number = %s
            """,
            (args.badge_number,),
        )
        officer = cursor.fetchone()
        if officer is None or officer["clearance_level"] != "ADMIN":
            parser.error("Badge number must belong to an existing ADMIN officer")
        cursor.execute(
            "SELECT account_id FROM compliance_officer_accounts WHERE officer_id = %s",
            (officer["officer_id"],),
        )
        if cursor.fetchone() is not None:
            parser.error("This officer already has a login account")
        cursor.execute(
            """
            INSERT INTO compliance_officer_accounts
                (officer_id, email, password_hash)
            VALUES (%s, %s, %s)
            """,
            (officer["officer_id"], email, _hash_password(password)),
        )
        connection.commit()
        print(f"Admin login created for {email}")
    except mysql.connector.IntegrityError as error:
        connection.rollback()
        parser.error(f"Email or officer account already exists: {error}")
    except mysql.connector.Error:
        connection.rollback()
        raise
    finally:
        cursor.close()
        connection.close()


if __name__ == "__main__":
    main()
