#!/usr/bin/env python3
"""market_time contract tests (P30 session-time authority).

The window is a pure function of (recorded calendar snapshot,
session_date, moment). These tests fix the boundaries, the UNKNOWN
cases and the fail-closed direction: an unproven session opening grants
no privilege and never falls back to 09:00 implicitly.
"""
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, time, timedelta, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "tools"))

import market_time  # noqa: E402

KST = timezone(timedelta(hours=9), "KST")
UTC = timezone.utc


def moment(text):
    """'2026-11-19T09:10:00+09:00' -> aware datetime."""
    return datetime.fromisoformat(text)


def calendar_record(days):
    return {"kind": "calendar", "seq": 1,
            "raw": {"schema": "hong-scanner-calendar/1", "market": "KRX",
                    "tz": "Asia/Seoul", "version": "CAL-TEST", "days": days}}


def day(open_text, close_text="15:30:00+09:00"):
    return {"open": open_text, "close": close_text,
            "half_day": False, "reason": None}


class ParseOpenTimeTest(unittest.TestCase):
    def test_canonical_offsets(self):
        self.assertEqual(market_time.parse_open_time("09:00:00+09:00"),
                         time(9, 0))
        self.assertEqual(market_time.parse_open_time("10:00:00+09:00"),
                         time(10, 0))
        self.assertEqual(market_time.parse_open_time("10:30:15+09:00"),
                         time(10, 30, 15))

    def test_unknown_forms_are_none(self):
        for value in (None, "", "09:00:00", "09:00:00Z", "09:00+09:00",
                      "9:00:00+09:00", "24:00:00+09:00", "09:60:00+09:00",
                      "09:00:00+09:30", "09:00:00 +09:00", 90000, True):
            with self.subTest(value=value):
                self.assertIsNone(market_time.parse_open_time(value))


class SessionOpenOfTest(unittest.TestCase):
    def test_recorded_day(self):
        record = calendar_record({"2026-11-19": day("09:00:00+09:00")})
        self.assertEqual(market_time.session_open_of(record, "2026-11-19"),
                         time(9, 0))

    def test_holiday_open_null_is_unknown(self):
        record = calendar_record({
            "2026-11-19": {"open": None, "close": None, "half_day": False,
                           "reason": "holiday"}})
        self.assertIsNone(market_time.session_open_of(record, "2026-11-19"))

    def test_absent_day_is_unknown(self):
        record = calendar_record({"2026-11-18": day("09:00:00+09:00")})
        self.assertIsNone(market_time.session_open_of(record, "2026-11-19"))

    def test_wrong_kind_and_shape_are_unknown(self):
        for record in ({"kind": "bars", "raw": {"days": {}}},
                       {"kind": "calendar"},
                       {"kind": "calendar", "raw": {"days": []}},
                       {"kind": "calendar", "raw": None},
                       [], "calendar", None):
            with self.subTest(record=record):
                self.assertIsNone(
                    market_time.session_open_of(record, "2026-11-19"))


class ReadSessionOpenTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write_input(self, lines):
        with open(os.path.join(self.tmp.name, "input.hcj.jsonl"), "w",
                  encoding="utf-8") as handle:
            for line in lines:
                handle.write(json.dumps(line, ensure_ascii=False) + "\n")

    def test_first_record_is_the_calendar_snapshot(self):
        self.write_input([
            calendar_record({"2026-11-19": day("10:00:00+09:00")}),
            {"kind": "bars", "raw": {"rows": []}},
        ])
        self.assertEqual(
            market_time.read_session_open(self.tmp.name, "2026-11-19"),
            time(10, 0))

    def test_missing_file_is_unknown(self):
        self.assertIsNone(
            market_time.read_session_open(self.tmp.name, "2026-11-19"))

    def test_malformed_first_line_is_unknown(self):
        path = os.path.join(self.tmp.name, "input.hcj.jsonl")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("{not json\n")
        self.assertIsNone(
            market_time.read_session_open(self.tmp.name, "2026-11-19"))

    def test_first_record_not_calendar_is_unknown(self):
        self.write_input([{"kind": "bars", "raw": {"rows": []}},
                          calendar_record({"2026-11-19":
                                           day("09:00:00+09:00")})])
        self.assertIsNone(
            market_time.read_session_open(self.tmp.name, "2026-11-19"))


class InWindowTest(unittest.TestCase):
    def test_regular_session_boundaries(self):
        table = [
            ("2026-11-19T08:59:59+09:00", False),
            ("2026-11-19T09:00:00+09:00", True),
            ("2026-11-19T09:29:59+09:00", True),
            ("2026-11-19T09:29:59.999+09:00", True),
            ("2026-11-19T09:30:00+09:00", False),
            ("2026-11-19T09:30:01+09:00", False),
            ("2026-11-19T15:00:00+09:00", False),
        ]
        for text, expected in table:
            with self.subTest(text=text):
                self.assertIs(
                    market_time.in_window(moment(text), "2026-11-19",
                                          time(9, 0)), expected)

    def test_special_session_opening_shifts_the_window(self):
        """The 2026-11-19 claim: if the exchange announces 10:00, the
        peak is 10:00-10:30 and 09:00-09:30 grants nothing."""
        table = [
            ("2026-11-19T09:00:00+09:00", False),
            ("2026-11-19T09:30:00+09:00", False),
            ("2026-11-19T09:59:59+09:00", False),
            ("2026-11-19T10:00:00+09:00", True),
            ("2026-11-19T10:29:59+09:00", True),
            ("2026-11-19T10:30:00+09:00", False),
        ]
        for text, expected in table:
            with self.subTest(text=text):
                self.assertIs(
                    market_time.in_window(moment(text), "2026-11-19",
                                          time(10, 0)), expected)

    def test_date_mismatch_never_matches(self):
        # Same wall clock, a previous session_date: a stale run's
        # projection must never become today's window.
        self.assertFalse(market_time.in_window(
            moment("2026-11-18T09:10:00+09:00"), "2026-11-19", time(9, 0)))

    def test_offset_equivalent_input(self):
        # 00:10Z == 09:10 KST: the instant is what counts.
        self.assertTrue(market_time.in_window(
            datetime(2026, 11, 19, 0, 10, tzinfo=UTC), "2026-11-19",
            time(9, 0)))

    def test_naive_and_unknown_open_are_fail_closed(self):
        self.assertFalse(market_time.in_window(
            datetime(2026, 11, 19, 9, 10), "2026-11-19", time(9, 0)))
        self.assertFalse(market_time.in_window(
            moment("2026-11-19T09:10:00+09:00"), "2026-11-19", None))
        self.assertFalse(market_time.in_window(
            moment("2026-11-19T09:10:00+09:00"), None, time(9, 0)))
        self.assertFalse(market_time.in_window(
            "2026-11-19T09:10:00+09:00", "2026-11-19", time(9, 0)))


class ModeForTest(unittest.TestCase):
    def test_mode_boundaries(self):
        self.assertEqual(
            market_time.mode_for(moment("2026-11-19T09:00:00+09:00"),
                                 "2026-11-19", time(9, 0)), "opening_ma20")
        self.assertEqual(
            market_time.mode_for(moment("2026-11-19T09:30:00+09:00"),
                                 "2026-11-19", time(9, 0)), "core")
        self.assertEqual(
            market_time.mode_for(moment("2026-11-19T08:59:59+09:00"),
                                 "2026-11-19", time(9, 0)), "core")
        self.assertEqual(
            market_time.mode_for(moment("2026-11-19T10:10:00+09:00"),
                                 "2026-11-19", time(10, 0)), "opening_ma20")


if __name__ == "__main__":
    unittest.main(verbosity=2)