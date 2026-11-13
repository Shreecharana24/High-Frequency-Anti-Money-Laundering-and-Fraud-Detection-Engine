import sys
import unittest
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import detector


class ClickHouseDetectorTests(unittest.TestCase):
    def test_rule_queries_read_the_clickhouse_transaction_mirror(self) -> None:
        queries = detector._rule_queries()

        self.assertEqual(len(queries), 6)
        for query, _, _ in queries.values():
            self.assertIn("aml_detection.transactions", query)

    def test_query_rows_maps_result_columns_to_dictionary_keys(self) -> None:
        clickhouse = Mock()
        clickhouse.query.return_value = SimpleNamespace(
            column_names=["transaction_id", "risk_level"],
            result_rows=[(42, "HIGH")],
        )

        rows = detector._query_rows(clickhouse, "SELECT transaction_id, risk_level")

        self.assertEqual(rows, [{"transaction_id": 42, "risk_level": "HIGH"}])

    def test_mirror_includes_currency_and_sender_risk_for_analytics(self) -> None:
        created_at = datetime(2026, 11, 13, 12, 0)
        row = {
            "transaction_id": 42,
            "sender_account_id": 7,
            "receiver_account_id": 9,
            "amount": Decimal("125.00"),
            "currency": "USD",
            "created_at": created_at,
            "status": "COMPLETED",
            "sender_risk_level": "HIGH",
        }
        mysql_cursor = Mock()
        mysql_cursor.fetchall.return_value = [row]
        mysql = Mock()
        mysql.cursor.return_value = mysql_cursor
        clickhouse = Mock()
        clickhouse.query.return_value.result_rows = [(0,)]

        mirrored = detector._mirror_transactions(mysql, clickhouse)

        self.assertEqual(mirrored, 1)
        self.assertEqual(
            clickhouse.insert.call_args.args[1],
            [(42, 7, 9, Decimal("125.00"), "USD", created_at, "COMPLETED", "HIGH")],
        )
        self.assertIn("u.risk_level AS sender_risk_level", mysql_cursor.execute.call_args.args[0])

    def test_detector_executes_each_rule_query_on_clickhouse(self) -> None:
        rule_rows = [
            {"rule_id": index, "rule_code": rule_code}
            for index, rule_code in enumerate(detector._rule_queries(), start=1)
        ]
        mysql_cursor = Mock()
        mysql_cursor.fetchall.return_value = rule_rows
        mysql = Mock()
        mysql.cursor.return_value = mysql_cursor
        clickhouse = Mock()
        clickhouse.query.return_value = SimpleNamespace(column_names=[], result_rows=[])

        with patch("detector._create_alert", return_value=False):
            created = detector._process_rules(mysql, clickhouse)

        self.assertEqual(created, 0)
        self.assertEqual(clickhouse.query.call_count, 6)
        executed_mysql_queries = [
            call.args[0] for call in mysql_cursor.execute.call_args_list
        ]
        self.assertFalse(any("aml_detection.transactions" in query for query in executed_mysql_queries))


if __name__ == "__main__":
    unittest.main()
