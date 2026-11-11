import json
import os
from contextlib import contextmanager
from datetime import datetime
from typing import Any, Iterator, Literal

import mysql.connector
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field

from .demo_common import mysql_connection

AlertStatus = Literal["OPEN", "INVESTIGATING", "CLEARED", "ESCALATED", "REPORTED"]
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


class AlertUpdate(BaseModel):
    status: AlertStatus | None = None
    assigned_officer_id: int | None = Field(default=None, ge=1)
    resolution_notes: str | None = Field(default=None, max_length=4000)


class AlertNote(BaseModel):
    officer_id: int = Field(ge=1)
    note: str = Field(min_length=1, max_length=4000)


@contextmanager
def db_connection() -> Iterator[mysql.connector.MySQLConnection]:
    connection = mysql_connection()
    try:
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
        "SELECT officer_id FROM compliance_officers WHERE officer_id = %s",
        (officer_id,),
    )
    if officer is None:
        raise HTTPException(status_code=404, detail="Compliance officer not found")


@app.get("/health")
def health() -> dict[str, str]:
    try:
        with db_connection() as connection:
            _fetch_one(connection, "SELECT 1 AS healthy")
        return {"status": "ok"}
    except mysql.connector.Error as error:
        raise HTTPException(status_code=503, detail="Database unavailable") from error


@app.get("/api/v1/alerts")
def list_alerts(
    status: AlertStatus | None = None,
    severity: Literal["LOW", "MEDIUM", "HIGH", "CRITICAL"] | None = None,
    rule_code: str | None = Query(default=None, max_length=50),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
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
def get_alert(alert_id: int) -> dict[str, Any]:
    with db_connection() as connection:
        alert = _require_alert(connection, alert_id)
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
def update_alert(alert_id: int, payload: AlertUpdate) -> dict[str, Any]:
    if payload.status is None and payload.assigned_officer_id is None and payload.resolution_notes is None:
        raise HTTPException(status_code=400, detail="At least one update is required")
    with db_connection() as connection:
        current = _require_alert(connection, alert_id)
        if payload.assigned_officer_id is not None:
            _require_officer(connection, payload.assigned_officer_id)
        if payload.status is not None and payload.status not in ALLOWED_TRANSITIONS[current["alert_status"]]:
            raise HTTPException(
                status_code=409,
                detail=f"Invalid alert transition: {current['alert_status']} -> {payload.status}",
            )
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
            cursor.execute(
                f"UPDATE fraud_alerts SET {', '.join(fields)} WHERE alert_id = %s",
                tuple(values + [alert_id]),
            )
            officer_id = payload.assigned_officer_id or current["assigned_officer_id"]
            if officer_id is None:
                raise HTTPException(status_code=400, detail="An officer must be assigned")
            action = "STATUS_CHANGED" if payload.status else "ASSIGNED"
            cursor.execute(
                """
                INSERT INTO fraud_alert_review_history
                    (alert_id, officer_id, action_type, previous_status, new_status, note)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (
                    alert_id,
                    officer_id,
                    action,
                    current["alert_status"],
                    payload.status or current["alert_status"],
                    payload.resolution_notes,
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
        return get_alert(alert_id)


@app.post("/api/v1/alerts/{alert_id}/notes", status_code=201)
def add_alert_note(alert_id: int, payload: AlertNote) -> dict[str, Any]:
    with db_connection() as connection:
        current = _require_alert(connection, alert_id)
        _require_officer(connection, payload.officer_id)
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
                    payload.officer_id,
                    current["alert_status"],
                    current["alert_status"],
                    payload.note,
                ),
            )
            connection.commit()
        finally:
            cursor.close()
        return {"alert_id": alert_id, "review_id": cursor.lastrowid}


@app.get("/api/v1/transactions")
def list_transactions(
    status: Literal["PENDING", "COMPLETED", "FAILED", "BLOCKED"] | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> dict[str, Any]:
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


@app.get("/api/v1/rules")
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
def metrics() -> dict[str, Any]:
    with db_connection() as connection:
        row = _fetch_one(
            connection,
            """
            SELECT
                COUNT(*) AS total_alerts,
                SUM(status IN ('OPEN', 'INVESTIGATING', 'ESCALATED')) AS active_alerts,
                SUM(status = 'CLEARED') AS cleared_alerts,
                SUM(status = 'REPORTED') AS reported_alerts
            FROM fraud_alerts
            """,
        )
        return row or {}
