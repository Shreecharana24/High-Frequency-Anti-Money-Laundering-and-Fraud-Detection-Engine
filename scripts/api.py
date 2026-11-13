import hashlib
import hmac
import json
import os
import secrets
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Generator, Literal

import mysql.connector
from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from starlette.staticfiles import StaticFiles

from .demo_common import mysql_connection

AlertStatus = Literal["OPEN", "INVESTIGATING", "CLEARED", "ESCALATED", "REPORTED"]
ClearanceLevel = Literal["LEVEL_1", "LEVEL_2", "ADMIN"]
PASSWORD_ITERATIONS = 600_000
DUMMY_PASSWORD_HASH = (
    "pbkdf2_sha256$600000$" + "0" * 32 + "$" + "0" * 64
)
SESSION_LIFETIME = timedelta(hours=8)
MAX_LOGIN_ATTEMPTS = 5
LOGIN_LOCKOUT = timedelta(minutes=15)
bearer_scheme = HTTPBearer(auto_error=False)
ALLOWED_TRANSITIONS: dict[str, set[str]] = {
    "OPEN": {"OPEN", "INVESTIGATING", "ESCALATED", "CLEARED"},
    "INVESTIGATING": {"INVESTIGATING", "ESCALATED", "CLEARED"},
    "ESCALATED": {"ESCALATED", "REPORTED", "CLEARED"},
    "CLEARED": {"CLEARED", "OPEN"},
    "REPORTED": {"REPORTED"},
}

app = FastAPI(
    title="AML Fraud Detection API",
    version="0.5.0",
    description="Alert investigation and transaction operations API.",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        origin.strip()
        for origin in os.getenv(
            "DASHBOARD_ORIGINS", "http://localhost:5173,http://localhost:3000"
        ).split(",")
        if origin.strip()
    ],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PATCH", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)


class AlertUpdate(BaseModel):
    status: AlertStatus | None = None
    assigned_officer_id: int | None = Field(default=None, ge=1)
    resolution_notes: str | None = Field(default=None, max_length=4000)


class AlertNote(BaseModel):
    note: str = Field(min_length=1, max_length=4000)


class LoginRequest(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=256)


class OfficerCreate(BaseModel):
    badge_number: str = Field(min_length=1, max_length=30)
    officer_name: str = Field(min_length=1, max_length=100)
    clearance_level: ClearanceLevel
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=12, max_length=256)


class OfficerAccountCreate(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=12, max_length=256)


class OfficerUpdate(BaseModel):
    clearance_level: ClearanceLevel | None = None
    is_active: bool | None = None


@contextmanager
def db_connection() -> Generator[mysql.connector.MySQLConnection, None, None]:
    connection = mysql_connection()
    try:
        cursor = connection.cursor()
        try:
            cursor.execute("SET time_zone = '+00:00'")
        finally:
            cursor.close()
        yield connection
    finally:
        connection.close()


def _jsonable(row: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value.isoformat() if isinstance(value, datetime) else value
        for key, value in row.items()
    }


def _fetch_all(
    connection: mysql.connector.MySQLConnection,
    query: str,
    parameters: tuple[Any, ...] = (),
) -> list[dict[str, Any]]:
    cursor = connection.cursor(dictionary=True)
    try:
        cursor.execute(query, parameters)
        return [_jsonable(row) for row in cursor.fetchall()]
    finally:
        cursor.close()


def _fetch_one(
    connection: mysql.connector.MySQLConnection,
    query: str,
    parameters: tuple[Any, ...] = (),
) -> dict[str, Any] | None:
    rows = _fetch_all(connection, query, parameters)
    return rows[0] if rows else None


def _require_alert(
    connection: mysql.connector.MySQLConnection, alert_id: int
) -> dict[str, Any]:
    alert = _fetch_one(
        connection,
        "SELECT * FROM v_fraud_alert_report WHERE alert_id = %s",
        (alert_id,),
    )
    if alert is None:
        raise HTTPException(status_code=404, detail="Alert not found")
    return alert


def _require_officer(
    connection: mysql.connector.MySQLConnection, officer_id: int
) -> None:
    officer = _fetch_one(
        connection,
        """
        SELECT o.officer_id
        FROM compliance_officers o
        JOIN compliance_officer_accounts a ON a.officer_id = o.officer_id
        WHERE o.officer_id = %s AND a.is_active = TRUE
        """,
        (officer_id,),
    )
    if officer is None:
        raise HTTPException(status_code=404, detail="Active officer account not found")


def _normalize_email(email: str) -> str:
    normalized = email.strip().lower()
    if normalized.count("@") != 1 or any(character.isspace() for character in normalized):
        raise HTTPException(status_code=422, detail="A valid email address is required")
    return normalized


def _hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, PASSWORD_ITERATIONS
    )
    return f"pbkdf2_sha256${PASSWORD_ITERATIONS}${salt.hex()}${digest.hex()}"


def _verify_password(password: str, password_hash: str) -> bool:
    try:
        algorithm, iterations, salt_hex, digest_hex = password_hash.split("$")
        if algorithm != "pbkdf2_sha256":
            return False
        iteration_count = int(iterations)
        if not 100_000 <= iteration_count <= 1_000_000:
            return False
        salt = bytes.fromhex(salt_hex)
        expected_digest = bytes.fromhex(digest_hex)
    except (ValueError, TypeError):
        return False
    actual_digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, iteration_count
    )
    return hmac.compare_digest(actual_digest, expected_digest)


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def get_current_officer(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
) -> dict[str, Any]:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=401,
            detail="Authentication required",
            headers={"WWW-Authenticate": "Bearer"},
        )
    with db_connection() as connection:
        officer = _fetch_one(
            connection,
            """
            SELECT o.officer_id, o.officer_name, o.clearance_level, a.email
            FROM compliance_officer_sessions s
            JOIN compliance_officers o ON o.officer_id = s.officer_id
            JOIN compliance_officer_accounts a ON a.officer_id = o.officer_id
            WHERE s.token_hash = %s
              AND s.revoked_at IS NULL
              AND s.expires_at > UTC_TIMESTAMP(3)
              AND a.is_active = TRUE
            """,
            (_token_hash(credentials.credentials),),
        )
    if officer is None:
        raise HTTPException(
            status_code=401,
            detail="Invalid or expired session",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return officer


def _require_clearance(
    officer: dict[str, Any], *allowed_levels: ClearanceLevel
) -> None:
    if officer["clearance_level"] not in allowed_levels:
        raise HTTPException(status_code=403, detail="Insufficient clearance")


def _require_alert_access(alert: dict[str, Any], officer: dict[str, Any]) -> None:
    if (
        officer["clearance_level"] == "LEVEL_1"
        and alert["assigned_officer_id"] != officer["officer_id"]
    ):
        raise HTTPException(status_code=404, detail="Alert not found")


def _authorize_alert_update(
    alert: dict[str, Any],
    payload: AlertUpdate,
    officer: dict[str, Any],
) -> None:
    _require_alert_access(alert, officer)
    if officer["clearance_level"] == "LEVEL_1":
        if payload.assigned_officer_id is not None:
            raise HTTPException(status_code=403, detail="Only Level 2 or Admin can assign alerts")
        if payload.status not in (None, "INVESTIGATING"):
            raise HTTPException(status_code=403, detail="Only Level 2 or Admin can resolve alerts")
        if payload.resolution_notes is not None:
            raise HTTPException(
                status_code=403,
                detail="Level 1 officers should use the review notes endpoint",
            )
    if payload.status is not None and payload.status not in ALLOWED_TRANSITIONS[alert["alert_status"]]:
        raise HTTPException(
            status_code=409,
            detail=f"Invalid alert transition: {alert['alert_status']} -> {payload.status}",
        )


def _create_officer_account(
    connection: mysql.connector.MySQLConnection,
    payload: OfficerCreate,
) -> dict[str, Any]:
    email = _normalize_email(payload.email)
    badge_number = payload.badge_number.strip()
    officer_name = payload.officer_name.strip()
    if not badge_number or not officer_name:
        raise HTTPException(status_code=422, detail="Officer name and badge are required")
    cursor = connection.cursor()
    try:
        cursor.execute(
            """
            INSERT INTO compliance_officers
                (badge_number, officer_name, clearance_level)
            VALUES (%s, %s, %s)
            """,
            (badge_number, officer_name, payload.clearance_level),
        )
        officer_id = cursor.lastrowid
        cursor.execute(
            """
            INSERT INTO compliance_officer_accounts
                (officer_id, email, password_hash)
            VALUES (%s, %s, %s)
            """,
            (officer_id, email, _hash_password(payload.password)),
        )
        connection.commit()
        return {
            "officer_id": officer_id,
            "badge_number": badge_number,
            "officer_name": officer_name,
            "clearance_level": payload.clearance_level,
            "email": email,
            "is_active": True,
        }
    except mysql.connector.IntegrityError as error:
        connection.rollback()
        raise HTTPException(status_code=409, detail="Officer badge or email already exists") from error
    except mysql.connector.Error:
        connection.rollback()
        raise
    finally:
        cursor.close()


@app.get("/health")
def health() -> dict[str, str]:
    try:
        with db_connection() as connection:
            _fetch_one(connection, "SELECT 1 AS healthy")
        return {"status": "ok"}
    except mysql.connector.Error as error:
        raise HTTPException(status_code=503, detail="Database unavailable") from error


@app.post("/api/v1/auth/login")
def login(payload: LoginRequest) -> dict[str, Any]:
    email = _normalize_email(payload.email)
    with db_connection() as connection:
        account = _fetch_one(
            connection,
            """
            SELECT a.account_id, a.officer_id, a.password_hash, a.is_active,
                   a.locked_until > UTC_TIMESTAMP(3) AS is_locked
            FROM compliance_officer_accounts a
            WHERE a.email = %s
            """,
            (email,),
        )
        password_valid = _verify_password(
            payload.password,
            account["password_hash"] if account is not None else DUMMY_PASSWORD_HASH,
        )
        if (
            account is None
            or not account["is_active"]
            or account["is_locked"]
            or not password_valid
        ):
            if account is not None and account["is_active"] and not account["is_locked"]:
                cursor = connection.cursor()
                try:
                    cursor.execute(
                        """
                        UPDATE compliance_officer_accounts
                        SET failed_login_attempts = failed_login_attempts + 1,
                            locked_until = CASE
                                WHEN failed_login_attempts + 1 >= %s
                                THEN DATE_ADD(UTC_TIMESTAMP(3), INTERVAL %s MINUTE)
                                ELSE locked_until
                            END
                        WHERE account_id = %s
                        """,
                        (MAX_LOGIN_ATTEMPTS, int(LOGIN_LOCKOUT.total_seconds() // 60), account["account_id"]),
                    )
                    connection.commit()
                finally:
                    cursor.close()
            raise HTTPException(status_code=401, detail="Invalid email or password")

        token = secrets.token_urlsafe(32)
        expires_at = datetime.now(timezone.utc).replace(tzinfo=None) + SESSION_LIFETIME
        cursor = connection.cursor()
        try:
            cursor.execute(
                """
                UPDATE compliance_officer_accounts
                SET failed_login_attempts = 0, locked_until = NULL
                WHERE account_id = %s
                """,
                (account["account_id"],),
            )
            cursor.execute(
                """
                INSERT INTO compliance_officer_sessions
                    (officer_id, token_hash, expires_at)
                VALUES (%s, %s, %s)
                """,
                (account["officer_id"], _token_hash(token), expires_at),
            )
            connection.commit()
        finally:
            cursor.close()
    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_at": expires_at.isoformat() + "Z",
    }


@app.post("/api/v1/auth/logout", status_code=204)
def logout(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    officer: dict[str, Any] = Depends(get_current_officer),
) -> None:
    if credentials is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    with db_connection() as connection:
        cursor = connection.cursor()
        try:
            cursor.execute(
                """
                UPDATE compliance_officer_sessions
                SET revoked_at = UTC_TIMESTAMP(3)
                WHERE token_hash = %s AND officer_id = %s AND revoked_at IS NULL
                """,
                (_token_hash(credentials.credentials), officer["officer_id"]),
            )
            connection.commit()
        finally:
            cursor.close()


@app.get("/api/v1/auth/me")
def current_officer(
    officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    return officer


@app.get("/api/v1/officers")
def list_officers(
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> list[dict[str, Any]]:
    _require_clearance(current_officer, "ADMIN")
    with db_connection() as connection:
        return _fetch_all(
            connection,
            """
            SELECT o.officer_id, o.badge_number, o.officer_name,
                   o.clearance_level, a.email, a.is_active
            FROM compliance_officers o
            LEFT JOIN compliance_officer_accounts a ON a.officer_id = o.officer_id
            ORDER BY o.officer_id
            """,
        )


@app.get("/api/v1/officers/assignable")
def list_assignable_officers(
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> list[dict[str, Any]]:
    _require_clearance(current_officer, "LEVEL_2", "ADMIN")
    with db_connection() as connection:
        return _fetch_all(
            connection,
            """
            SELECT o.officer_id, o.officer_name, o.clearance_level
            FROM compliance_officers o
            JOIN compliance_officer_accounts a ON a.officer_id = o.officer_id
            WHERE a.is_active = TRUE
            ORDER BY o.officer_name, o.officer_id
            """,
        )


@app.post("/api/v1/officers", status_code=201)
def create_officer(
    payload: OfficerCreate,
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    _require_clearance(current_officer, "ADMIN")
    with db_connection() as connection:
        return _create_officer_account(connection, payload)


@app.post("/api/v1/officers/{officer_id}/account", status_code=201)
def create_officer_login(
    officer_id: int,
    payload: OfficerAccountCreate,
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    _require_clearance(current_officer, "ADMIN")
    email = _normalize_email(payload.email)
    with db_connection() as connection:
        officer = _fetch_one(
            connection,
            """
            SELECT o.officer_id, o.badge_number, o.officer_name, o.clearance_level
            FROM compliance_officers o
            WHERE o.officer_id = %s
            """,
            (officer_id,),
        )
        if officer is None:
            raise HTTPException(status_code=404, detail="Compliance officer not found")
        existing_account = _fetch_one(
            connection,
            """
            SELECT account_id
            FROM compliance_officer_accounts
            WHERE officer_id = %s
            """,
            (officer_id,),
        )
        if existing_account is not None:
            raise HTTPException(status_code=409, detail="Officer already has a login account")
        cursor = connection.cursor()
        try:
            cursor.execute(
                """
                INSERT INTO compliance_officer_accounts
                    (officer_id, email, password_hash)
                VALUES (%s, %s, %s)
                """,
                (officer_id, email, _hash_password(payload.password)),
            )
            connection.commit()
        except mysql.connector.IntegrityError as error:
            connection.rollback()
            raise HTTPException(status_code=409, detail="Email already exists") from error
        finally:
            cursor.close()
        return {
            **officer,
            "email": email,
            "is_active": True,
        }


@app.patch("/api/v1/officers/{officer_id}")
def update_officer(
    officer_id: int,
    payload: OfficerUpdate,
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    _require_clearance(current_officer, "ADMIN")
    if payload.clearance_level is None and payload.is_active is None:
        raise HTTPException(status_code=400, detail="At least one update is required")
    with db_connection() as connection:
        existing = _fetch_one(
            connection,
            """
            SELECT o.officer_id, o.clearance_level, a.is_active
            FROM compliance_officers o
            LEFT JOIN compliance_officer_accounts a ON a.officer_id = o.officer_id
            WHERE o.officer_id = %s
            """,
            (officer_id,),
        )
        if existing is None:
            raise HTTPException(status_code=404, detail="Compliance officer not found")
        if payload.is_active is not None and existing["is_active"] is None:
            raise HTTPException(
                status_code=409,
                detail="Officer has no login account; create an account before changing its state",
            )
        demotes_admin = (
            existing["clearance_level"] == "ADMIN"
            and payload.clearance_level not in (None, "ADMIN")
        )
        deactivates_admin = (
            existing["clearance_level"] == "ADMIN"
            and existing["is_active"]
            and payload.is_active is False
        )
        if demotes_admin or deactivates_admin:
            count = _fetch_one(
                connection,
                """
                SELECT COUNT(*) AS active_admins
                FROM compliance_officers o
                JOIN compliance_officer_accounts a ON a.officer_id = o.officer_id
                WHERE o.clearance_level = 'ADMIN' AND a.is_active = TRUE
                """,
            )
            if count is not None and count["active_admins"] <= 1:
                raise HTTPException(status_code=409, detail="Cannot remove the last active admin")
        cursor = connection.cursor()
        try:
            if payload.clearance_level is not None:
                cursor.execute(
                    "UPDATE compliance_officers SET clearance_level = %s WHERE officer_id = %s",
                    (payload.clearance_level, officer_id),
                )
            if payload.is_active is not None:
                cursor.execute(
                    "UPDATE compliance_officer_accounts SET is_active = %s WHERE officer_id = %s",
                    (payload.is_active, officer_id),
                )
                if payload.is_active is False:
                    cursor.execute(
                        """
                        UPDATE compliance_officer_sessions
                        SET revoked_at = UTC_TIMESTAMP(3)
                        WHERE officer_id = %s AND revoked_at IS NULL
                        """,
                        (officer_id,),
                    )
            connection.commit()
        except mysql.connector.Error as error:
            connection.rollback()
            raise HTTPException(status_code=409, detail="Officer update failed") from error
        finally:
            cursor.close()
        updated = _fetch_one(
            connection,
            """
            SELECT o.officer_id, o.badge_number, o.officer_name,
                   o.clearance_level, a.email, a.is_active
            FROM compliance_officers o
            LEFT JOIN compliance_officer_accounts a ON a.officer_id = o.officer_id
            WHERE o.officer_id = %s
            """,
            (officer_id,),
        )
        if updated is None:
            raise HTTPException(status_code=404, detail="Compliance officer not found")
        return updated


@app.get("/api/v1/alerts")
def list_alerts(
    status: AlertStatus | None = None,
    severity: Literal["LOW", "MEDIUM", "HIGH", "CRITICAL"] | None = None,
    rule_code: str | None = Query(default=None, max_length=50),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    conditions: list[str] = []
    parameters: list[Any] = []
    if status:
        conditions.append("alert_status = %s")
        parameters.append(status)
    if severity:
        conditions.append("severity = %s")
        parameters.append(severity)
    if rule_code:
        conditions.append("rule_code = %s")
        parameters.append(rule_code)
    if current_officer["clearance_level"] == "LEVEL_1":
        conditions.append("assigned_officer_id = %s")
        parameters.append(current_officer["officer_id"])
    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    with db_connection() as connection:
        rows = _fetch_all(
            connection,
            f"""
            SELECT * FROM v_fraud_alert_report
            {where}
            ORDER BY detected_at DESC, alert_id DESC
            LIMIT %s OFFSET %s
            """,
            tuple(parameters + [limit, offset]),
        )
        total = _fetch_one(
            connection,
            f"SELECT COUNT(*) AS total FROM v_fraud_alert_report {where}",
            tuple(parameters),
        )
    return {"items": rows, "limit": limit, "offset": offset, "total": total["total"]}


@app.get("/api/v1/alerts/{alert_id}")
def get_alert(
    alert_id: int,
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    with db_connection() as connection:
        alert = _require_alert(connection, alert_id)
        _require_alert_access(alert, current_officer)
        alert["evidence"] = _fetch_all(
            connection,
            """
            SELECT evidence_id, evidence_type, evidence_data, created_at
            FROM fraud_alert_evidence
            WHERE alert_id = %s
            ORDER BY evidence_id
            """,
            (alert_id,),
        )
        for evidence in alert["evidence"]:
            if isinstance(evidence["evidence_data"], str):
                evidence["evidence_data"] = json.loads(evidence["evidence_data"])
        alert["review_history"] = _fetch_all(
            connection,
            """
            SELECT review_id, officer_id, action_type, previous_status,
                   new_status, note, created_at
            FROM fraud_alert_review_history
            WHERE alert_id = %s
            ORDER BY review_id
            """,
            (alert_id,),
        )
        return alert


@app.patch("/api/v1/alerts/{alert_id}")
def update_alert(
    alert_id: int,
    payload: AlertUpdate,
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    if payload.status is None and payload.assigned_officer_id is None and payload.resolution_notes is None:
        raise HTTPException(status_code=400, detail="At least one update is required")
    if payload.status is None and payload.assigned_officer_id is None:
        raise HTTPException(
            status_code=400,
            detail="Provide a status or assignment change; use the notes endpoint for notes",
        )
    with db_connection() as connection:
        current = _require_alert(connection, alert_id)
        _authorize_alert_update(current, payload, current_officer)
        if payload.assigned_officer_id is not None:
            _require_officer(connection, payload.assigned_officer_id)
        cursor = connection.cursor()
        try:
            fields: list[str] = []
            values: list[Any] = []
            if payload.status is not None:
                fields.append("status = %s")
                values.append(payload.status)
            if payload.assigned_officer_id is not None:
                fields.append("assigned_officer_id = %s")
                values.append(payload.assigned_officer_id)
            if payload.resolution_notes is not None:
                fields.append("resolution_notes = %s")
                values.append(payload.resolution_notes)
            if payload.status in {"CLEARED", "REPORTED"}:
                fields.append("resolved_at = CURRENT_TIMESTAMP(3)")
            elif payload.status == "OPEN":
                fields.append("resolved_at = NULL")
            cursor.execute(
                f"UPDATE fraud_alerts SET {', '.join(fields)} WHERE alert_id = %s",
                tuple(values + [alert_id]),
            )
            if payload.status is not None:
                cursor.execute(
                    """
                    INSERT INTO fraud_alert_review_history
                        (alert_id, officer_id, action_type, previous_status, new_status, note)
                    VALUES (%s, %s, 'STATUS_CHANGED', %s, %s, %s)
                    """,
                    (
                        alert_id,
                        current_officer["officer_id"],
                        current["alert_status"],
                        payload.status,
                        payload.resolution_notes,
                    ),
                )
            if payload.assigned_officer_id is not None:
                cursor.execute(
                    """
                    INSERT INTO fraud_alert_review_history
                        (alert_id, officer_id, action_type, previous_status, new_status)
                    VALUES (%s, %s, 'ASSIGNED', %s, %s)
                    """,
                    (
                        alert_id,
                        current_officer["officer_id"],
                        current["alert_status"],
                        payload.status or current["alert_status"],
                    ),
                )
            connection.commit()
        except HTTPException:
            connection.rollback()
            raise
        except mysql.connector.Error as error:
            connection.rollback()
            raise HTTPException(status_code=409, detail="Alert update failed") from error
        finally:
            cursor.close()
        return get_alert(alert_id, current_officer)


@app.post("/api/v1/alerts/{alert_id}/notes", status_code=201)
def add_alert_note(
    alert_id: int,
    payload: AlertNote,
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    with db_connection() as connection:
        current = _require_alert(connection, alert_id)
        _require_alert_access(current, current_officer)
        cursor = connection.cursor()
        try:
            cursor.execute(
                """
                INSERT INTO fraud_alert_review_history
                    (alert_id, officer_id, action_type, previous_status,
                     new_status, note)
                VALUES (%s, %s, 'NOTE_ADDED', %s, %s, %s)
                """,
                (
                    alert_id,
                    current_officer["officer_id"],
                    current["alert_status"],
                    current["alert_status"],
                    payload.note,
                ),
            )
            connection.commit()
            review_id = cursor.lastrowid
        finally:
            cursor.close()
        return {"alert_id": alert_id, "review_id": review_id}


@app.get("/api/v1/transactions")
def list_transactions(
    status: Literal["PENDING", "COMPLETED", "FAILED", "BLOCKED"] | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    _require_clearance(current_officer, "LEVEL_2", "ADMIN")
    where = "WHERE status = %s" if status else ""
    parameters: tuple[Any, ...] = (status,) if status else ()
    with db_connection() as connection:
        rows = _fetch_all(
            connection,
            f"""
            SELECT * FROM v_transaction_details {where}
            ORDER BY created_at DESC, transaction_id DESC
            LIMIT %s OFFSET %s
            """,
            parameters + (limit, offset),
        )
        total = _fetch_one(
            connection,
            f"SELECT COUNT(*) AS total FROM v_transaction_details {where}",
            parameters,
        )
    return {"items": rows, "limit": limit, "offset": offset, "total": total["total"]}


@app.post("/api/v1/transactions/generate", status_code=202)
def request_transaction_generation(
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    _require_clearance(current_officer, "LEVEL_2", "ADMIN")
    with db_connection() as connection:
        cursor = connection.cursor()
        try:
            cursor.execute(
                """
                INSERT INTO transaction_generation_jobs (requested_by)
                VALUES (%s)
                """,
                (current_officer["officer_id"],),
            )
            job_id = cursor.lastrowid
            connection.commit()
        except mysql.connector.IntegrityError as error:
            connection.rollback()
            raise HTTPException(
                status_code=409,
                detail="A 1,000-transaction generation job is already queued or running",
            ) from error
        finally:
            cursor.close()
    return {
        "job_id": job_id,
        "status": "QUEUED",
        "requested_count": 1000,
        "generated_count": 0,
    }


@app.get("/api/v1/transactions/generation/latest")
def latest_generation_job(
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any] | None:
    _require_clearance(current_officer, "LEVEL_2", "ADMIN")
    with db_connection() as connection:
        return _fetch_one(
            connection,
            """
            SELECT job_id, status, requested_count, generated_count,
                   requested_at, started_at, finished_at, error_message
            FROM transaction_generation_jobs
            ORDER BY job_id DESC
            LIMIT 1
            """,
        )


@app.get("/api/v1/transactions/generation/{job_id}")
def get_generation_job(
    job_id: int,
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    _require_clearance(current_officer, "LEVEL_2", "ADMIN")
    with db_connection() as connection:
        job = _fetch_one(
            connection,
            """
            SELECT job_id, status, requested_count, generated_count,
                   requested_at, started_at, finished_at, error_message
            FROM transaction_generation_jobs
            WHERE job_id = %s
            """,
            (job_id,),
        )
    if job is None:
        raise HTTPException(status_code=404, detail="Generation job not found")
    return job


@app.get("/api/v1/rules", dependencies=[Depends(get_current_officer)])
def list_rules() -> list[dict[str, Any]]:
    with db_connection() as connection:
        return _fetch_all(
            connection,
            """
            SELECT rule_id, rule_code, description, base_penalty_score
            FROM fraud_rules ORDER BY rule_id
            """,
        )


@app.get("/api/v1/metrics")
def metrics(
    current_officer: dict[str, Any] = Depends(get_current_officer),
) -> dict[str, Any]:
    assigned_only = current_officer["clearance_level"] == "LEVEL_1"
    assigned_filter = "WHERE assigned_officer_id = %s" if assigned_only else ""
    parameters = (current_officer["officer_id"],) if assigned_only else ()
    with db_connection() as connection:
        row = _fetch_one(
            connection,
            f"""
            SELECT
                COUNT(*) AS total_alerts,
                SUM(status IN ('OPEN', 'INVESTIGATING', 'ESCALATED')) AS active_alerts,
                SUM(status = 'CLEARED') AS cleared_alerts,
                SUM(status = 'REPORTED') AS reported_alerts
            FROM fraud_alerts {assigned_filter}
            """,
            parameters,
        )
        return row or {}


app.mount(
    "/",
    StaticFiles(directory=Path(__file__).resolve().parent.parent / "web", html=True),
    name="dashboard",
)
