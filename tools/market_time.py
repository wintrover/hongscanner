#!/usr/bin/env python3
"""market_time — the single session-time authority (P30, docs/ASSUMPTIONS.md).

The opening window has exactly one owner: the recorded calendar
snapshot's session opening for the run's session_date. Both consumers —
the API's §3.7 mode decision (tools/api/serve.py) and the notification
peak budget (tools/notify/notify_dispatcher.py) — call the functions
below. Neither keeps its own copy of the window arithmetic and neither
keeps its own 09:00 constant.

Contract:
  * the window is [open, open + span) in Asia/Seoul — start inclusive,
    end exclusive; span is PEAK_WINDOW (30 minutes, P30);
  * a moment whose KST date differs from the run's session_date is
    never in the window (a previous run's projection never becomes
    today's);
  * UNKNOWN is not 09:00. A missing or unparseable calendar record, an
    absent day, a holiday (open null), a naive datetime and a
    non-canonical timestamp all yield None/False, and the caller then
    grants NO privilege (mode "core", no peak audible budget). The
    legacy 09:00 constant is never applied implicitly: a caller that
    wants it must name it (tests pass it explicitly).

Pure functions only: no clock read. read_session_open is the single
reader of the recorded snapshot.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, time, timedelta, timezone
from typing import Any, Mapping, Optional

KST = timezone(timedelta(hours=9), "KST")
PEAK_WINDOW = timedelta(minutes=30)

_OFFSET_SUFFIX = "+09:00"
_INPUT_NAME = "input.hcj.jsonl"


def parse_open_time(value: Any) -> Optional[time]:
    """A recorded calendar `open` ('HH:MM:SS+09:00') as a wall time.

    Strict by design: the record's own shape is the evidence, so an
    empty string, a None (holiday), a bare 'HH:MM:SS' without the
    recorded KST offset, or an out-of-range clock all mean UNKNOWN and
    return None — never a substituted default.
    """
    if not isinstance(value, str) or not value.endswith(_OFFSET_SUFFIX):
        return None
    clock = value[: -len(_OFFSET_SUFFIX)]
    parts = clock.split(":")
    if len(parts) != 3 or any(len(p) != 2 or not p.isdigit() for p in parts):
        return None
    hour, minute, second = (int(p) for p in parts)
    if not (0 <= hour <= 23 and 0 <= minute <= 59 and 0 <= second <= 59):
        return None
    return time(hour, minute, second)


def session_open_of(record: Any, session_date: Any) -> Optional[time]:
    """The session opening recorded for `session_date`, or None.

    `record` is one decoded input.hcj.jsonl line: {kind: "calendar",
    raw: {days: {<date>: {open: ...}}}}. Every deviation — another
    kind, no raw/days mapping, an absent date, a holiday — is UNKNOWN.
    """
    if not isinstance(record, Mapping) or record.get("kind") != "calendar":
        return None
    raw = record.get("raw")
    if not isinstance(raw, Mapping):
        return None
    days = raw.get("days")
    if not isinstance(days, Mapping) or not isinstance(session_date, str):
        return None
    day = days.get(session_date)
    if not isinstance(day, Mapping):
        return None
    return parse_open_time(day.get("open"))


def read_session_open(run_dir: Any, session_date: Any) -> Optional[time]:
    """The session opening recorded in <run_dir>/input.hcj.jsonl.

    The calendar snapshot is the first record of the run's input
    (REPLAY_CONTRACT). Any read/parse failure returns None (UNKNOWN);
    the caller must not substitute a default.
    """
    path = os.path.join(str(run_dir), _INPUT_NAME)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            line = handle.readline()
        record = json.loads(line)
    except (OSError, ValueError):
        return None
    return session_open_of(record, session_date)


def in_window(at: Any, session_date: Any, open_time: Any,
              span: timedelta = PEAK_WINDOW) -> bool:
    """True iff `at` falls in [open, open + span) on `session_date`.

    `at` is any aware datetime — the API passes its decision moment
    (as_of), the dispatcher passes an event's observed_at; the window
    arithmetic is identical for both. A naive datetime, a non-time
    open_time, or a date mismatch is False (fail-closed).
    """
    if not isinstance(at, datetime) or at.tzinfo is None or \
            at.utcoffset() is None:
        return False
    if not isinstance(open_time, time):
        return False
    moment = at.astimezone(KST)
    if not isinstance(session_date, str) or \
            moment.date().isoformat() != session_date:
        return False
    clock_seconds = moment.hour * 3600 + moment.minute * 60 + moment.second
    open_seconds = open_time.hour * 3600 + open_time.minute * 60 + \
        open_time.second
    return 0 <= clock_seconds - open_seconds < int(span.total_seconds())


def mode_for(as_of: Any, session_date: Any, open_time: Any) -> str:
    """The §3.7 mode: "opening_ma20" inside the window, else "core"."""
    return "opening_ma20" if in_window(as_of, session_date, open_time) \
        else "core"