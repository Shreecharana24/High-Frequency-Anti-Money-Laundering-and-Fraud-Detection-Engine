import unittest

from fastapi import HTTPException

from scripts.api import (
    AlertUpdate,
    _authorize_alert_update,
    _hash_password,
    _require_alert_access,
    _require_clearance,
    _token_hash,
    _verify_password,
)


class AuthenticationHelpersTests(unittest.TestCase):
    def test_password_hash_verifies_only_matching_password(self) -> None:
        password_hash = _hash_password("correct horse battery staple")

        self.assertTrue(_verify_password("correct horse battery staple", password_hash))
        self.assertFalse(_verify_password("wrong password", password_hash))

    def test_password_hash_uses_a_unique_salt(self) -> None:
        first_hash = _hash_password("correct horse battery staple")
        second_hash = _hash_password("correct horse battery staple")

        self.assertNotEqual(first_hash, second_hash)

    def test_session_token_is_stored_as_a_one_way_hash(self) -> None:
        token = "example-session-token"

        self.assertNotEqual(_token_hash(token), token)
        self.assertEqual(_token_hash(token), _token_hash(token))

    def test_level_one_cannot_view_an_unassigned_alert(self) -> None:
        with self.assertRaises(HTTPException) as raised:
            _require_alert_access(
                {"assigned_officer_id": 12},
                {"officer_id": 7, "clearance_level": "LEVEL_1"},
            )

        self.assertEqual(raised.exception.status_code, 404)

    def test_level_one_can_view_an_assigned_alert(self) -> None:
        _require_alert_access(
            {"assigned_officer_id": 7},
            {"officer_id": 7, "clearance_level": "LEVEL_1"},
        )

    def test_level_one_can_move_assigned_alert_to_investigating(self) -> None:
        _authorize_alert_update(
            {"alert_status": "OPEN", "assigned_officer_id": 7},
            AlertUpdate(status="INVESTIGATING"),
            {"officer_id": 7, "clearance_level": "LEVEL_1"},
        )

    def test_level_one_cannot_clear_an_assigned_alert(self) -> None:
        with self.assertRaises(HTTPException) as raised:
            _authorize_alert_update(
                {"alert_status": "INVESTIGATING", "assigned_officer_id": 7},
                AlertUpdate(status="CLEARED"),
                {"officer_id": 7, "clearance_level": "LEVEL_1"},
            )

        self.assertEqual(raised.exception.status_code, 403)

    def test_level_two_can_clear_an_investigated_alert(self) -> None:
        _authorize_alert_update(
            {"alert_status": "INVESTIGATING", "assigned_officer_id": 7},
            AlertUpdate(status="CLEARED"),
            {"officer_id": 12, "clearance_level": "LEVEL_2"},
        )

    def test_only_admin_passes_admin_clearance_check(self) -> None:
        with self.assertRaises(HTTPException) as raised:
            _require_clearance(
                {"clearance_level": "LEVEL_2"},
                "ADMIN",
            )

        self.assertEqual(raised.exception.status_code, 403)


if __name__ == "__main__":
    unittest.main()
