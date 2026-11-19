#!/usr/bin/env python3
"""개장 피크 알림 게시 증명(읽기 전용, 동결 입력만 사용).

서버가 주장한 알림(전달 원장의 ACCEPTED single/summary)이 수용 창
[개장, 개장+30분) 동안 S10 트레이에 실제로 게시됐는지를 관측 파일과
대조해 판정한다. 판정 입력은 전부 CLI로 받은 동결 파일이며, 도구는
입력을 절대 쓰지 않는다. 유일한 쓰기는 --out 이다.

판정(우선순위, 모두 exit 1):
  PROVENANCE_MISMATCH   RUN_PROVENANCE 1줄이 승인값과 다르다
  UNKNOWN_INPUT         캘린더 개장·입력 JSONL을 읽거나 해석할 수 없다
  OBSERVATION_INCOMPLETE 관측이 수용 창을 연속으로 덮었다는 증거가 없다
  COVERAGE_INCOMPLETE   기대 그룹 태그와 관측 태그가 다르거나 미분류 전달이 있다
  PREOPEN_CONTAMINATION 피크 체크포인트의 최신 랭킹이 개장 이전이거나 증명 불가
  ACCEPTED              모든 검사 통과(exit 0)

범위·한계:
- 기대 태그는 (observed_at, device_id) 그룹의 트레이 슬롯 이름
  (tools/notify/group_tag.py)이다. digest/aggregation_started 전달은
  피크 그룹 주장이 아니므로 무시하고, message_kind가 없거나 원장 enum
  밖이면 미분류로 기록해 fail-closed 한다.
- 관측 태그는 OBSERVED_ACTIVE 스냅샷만 센다. 관측되지 않은 게시는
  "없었다"가 아니라 "이 증거로는 증명되지 않는다"이다.
- peak 계산은 market_time 의 개장 파서와 30분 창을 그대로 쓴다.
- 오염 검사는 세션 관측자의 market-view 요약(top10 observed_at)을 읽기
  전용 대리 지표로 쓴다. 피크 안 체크포인트가 하나도 없거나 최신 랭킹을
  읽을 수 없으면 "깨끗함"이 아니라 "증명 불가"로 실패한다.

사용:
  python3 tools/attest_notifications.py --date YYYY-MM-DD --run-dir DIR \
    --delivery FILE --observed FILE --session-observer FILE --calendar FILE \
    --launcher-log FILE --approved-commit SHA \
    --approved-launcher-sha256 HEX [--out FILE]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta

sys.dont_write_bytecode = True

_TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
_NOTIFY_DIR = os.path.join(_TOOLS_DIR, "notify")
for _path in (_TOOLS_DIR, _NOTIFY_DIR):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import market_time  # noqa: E402
from group_tag import group_tag  # noqa: E402
from notify_ledger import MESSAGE_KINDS  # noqa: E402

DEFAULT_DEVICE_ID = "wuyoni-sm-g977n"
AUDIBLE_KINDS = frozenset(("single", "summary"))
EVENTS_FILE = "events.hcj.jsonl"
PROVENANCE_PREFIX = "RUN_PROVENANCE"
EXIT_OK = 0
EXIT_FAIL = 1


class InputError(Exception):
    """입력 파일의 부재·형식 위반. fail-closed(UNKNOWN_INPUT)."""


def _sha256_file(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def _read_jsonl(path):
    try:
        handle = open(path, "r", encoding="utf-8")
    except OSError as exc:
        raise InputError("%s: %s" % (path, exc))
    records = []
    with handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except ValueError as exc:
                raise InputError("%s:%d: invalid JSON (%s)"
                                 % (path, number, exc))
            if not isinstance(record, dict):
                raise InputError("%s:%d: record is not an object"
                                 % (path, number))
            records.append(record)
    return records


def _moment(value):
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value)
    except ValueError:
        return None
    if moment.tzinfo is None or moment.utcoffset() is None:
        return None
    return moment


def _read_provenance(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = [line.strip() for line in handle
                     if line.strip().split(" ", 1)[0] == PROVENANCE_PREFIX]
    except OSError as exc:
        return None, "launcher log unreadable: %s" % exc
    if len(lines) != 1:
        return None, ("expected exactly one RUN_PROVENANCE line, found %d"
                      % len(lines))
    fields = {}
    for token in lines[0].split()[1:]:
        if "=" not in token:
            return None, "malformed RUN_PROVENANCE token %r" % token
        key, value = token.split("=", 1)
        fields[key] = value
    return fields, None


def _provenance_mismatches(fields, args):
    checks = (
        ("git_commit", args.approved_commit),
        ("launcher_sha256", args.approved_launcher_sha256),
        ("git_dirty", "0"),
        ("session_date", args.date),
    )
    return [key for key, expected in checks if fields.get(key) != expected]


def _peak_window(calendar_path, session_date):
    try:
        with open(calendar_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        raise InputError("%s: %s" % (calendar_path, exc))
    days = data.get("days") if isinstance(data, dict) else None
    day = days.get(session_date) if isinstance(days, dict) else None
    open_value = day.get("open") if isinstance(day, dict) else None
    open_time = market_time.parse_open_time(open_value)
    if open_time is None:
        return None
    day_date = datetime.strptime(session_date, "%Y-%m-%d").date()
    start = datetime.combine(day_date, open_time, tzinfo=market_time.KST)
    return {"open": start, "end": start + market_time.PEAK_WINDOW}


def _load_events(path):
    events = {}
    for record in _read_jsonl(path):
        event_id = record.get("event_id")
        observed_at = record.get("observed_at")
        moment = _moment(observed_at)
        if not isinstance(event_id, str) or not event_id:
            raise InputError("%s: event without event_id" % path)
        if moment is None:
            raise InputError("%s: event %s has no aware observed_at"
                             % (path, event_id))
        previous = events.get(event_id)
        if previous is not None and previous["observed_at"] != observed_at:
            raise InputError("%s: event %s has conflicting observed_at"
                             % (path, event_id))
        events[event_id] = {"observed_at": observed_at, "at": moment}
    return events


def _known_kind(kind):
    return isinstance(kind, str) and kind in MESSAGE_KINDS


def _expected_groups(delivery_path, events, peak, device_id):
    expected = set()
    unclassified = set()
    for record in _read_jsonl(delivery_path):
        if record.get("state") != "ACCEPTED":
            continue
        if record.get("device_id") != device_id:
            continue
        event_id = record.get("event_id")
        event = events.get(event_id) if isinstance(event_id, str) else None
        if event is None:
            continue
        if not (peak["open"] <= event["at"] < peak["end"]):
            continue
        kind = record.get("message_kind")
        if isinstance(kind, str) and kind in AUDIBLE_KINDS:
            expected.add(group_tag(event["observed_at"], device_id))
        elif not _known_kind(kind):
            unclassified.add(event_id)
    return expected, unclassified


def _observer_window(observer_end, records):
    if observer_end is not None:
        start_raw = observer_end.get("window_start")
        end_raw = observer_end.get("window_end")
        start = _moment(start_raw)
        end = _moment(end_raw)
        if start is not None and end is not None and start <= end:
            return {"start": start, "end": end, "start_raw": start_raw,
                    "end_raw": end_raw, "source": "observer_end", "ok": True}
    captured = []
    for record in records:
        if record.get("kind") == "observer_end":
            continue
        moment = _moment(record.get("captured_at"))
        if moment is not None:
            captured.append(moment)
    if captured:
        start = min(captured)
        end = max(captured)
        return {"start": start, "end": end,
                "start_raw": start.isoformat(), "end_raw": end.isoformat(),
                "source": "records", "ok": False}
    return {"start": None, "end": None, "start_raw": None, "end_raw": None,
            "source": None, "ok": False}


def _analyse_observer(observed_path, start_tolerance_sec, end_tolerance_sec,
                      max_gap_sec):
    records = _read_jsonl(observed_path)
    ends = [record for record in records
            if record.get("kind") == "observer_end"]
    observer_end = ends[0] if ends else None
    window = _observer_window(observer_end, records)

    heartbeats = []
    notifications = []
    error_records = []
    timestamps_ok = True
    for record in records:
        if record.get("kind") == "observer_end":
            continue
        captured = _moment(record.get("captured_at"))
        if "captured_at" in record and captured is None:
            timestamps_ok = False
        if record.get("error"):
            if window["start"] is None or window["end"] is None or \
                    captured is None or \
                    window["start"] <= captured <= window["end"]:
                error_records.append(record)
            continue
        if record.get("kind") == "heartbeat":
            if captured is not None:
                heartbeats.append(captured)
            continue
        tag = record.get("tag")
        if isinstance(tag, str) and \
                record.get("snapshot_status") == "OBSERVED_ACTIVE" and \
                captured is not None:
            notifications.append((captured, tag))

    observed = set()
    if window["start"] is not None and window["end"] is not None:
        for captured, tag in notifications:
            if window["start"] <= captured <= window["end"]:
                observed.add(tag)

    heartbeats.sort()
    first_source = None
    first_sample = heartbeats[0] if heartbeats else None
    if first_sample is not None:
        first_source = "heartbeat"
    else:
        samples = []
        for record in records:
            if record.get("kind") == "observer_end":
                continue
            moment = _moment(record.get("captured_at"))
            if moment is not None:
                samples.append(moment)
        if samples:
            first_sample = min(samples)
            first_source = "record"

    start_ok = first_sample is not None and window["start"] is not None and \
        first_sample <= window["start"] + \
        timedelta(seconds=start_tolerance_sec)

    ended_raw = observer_end.get("ended_at") if observer_end else None
    ended_at = _moment(ended_raw)
    end_ok = ended_at is not None and window["end"] is not None and \
        ended_at >= window["end"] - timedelta(seconds=end_tolerance_sec)

    if window["start"] is not None and window["end"] is not None:
        gap_points = [moment for moment in heartbeats
                      if window["start"] <= moment <= window["end"]]
    else:
        gap_points = list(heartbeats)
    if len(gap_points) >= 2:
        max_gap = max((later - earlier).total_seconds()
                      for earlier, later in zip(gap_points, gap_points[1:]))
        gap_ok = max_gap <= max_gap_sec
    else:
        max_gap = None
        gap_ok = False

    polls = observer_end.get("polls") if observer_end else None
    polls_ok = isinstance(polls, int) and not isinstance(polls, bool) and \
        polls > 0
    exit_ok = observer_end is not None and observer_end.get("exit") == "ok"
    observer_end_ok = len(ends) == 1 and exit_ok
    no_errors = not error_records

    completeness = {
        "observer_end": observer_end_ok,
        "observer_end_count": len(ends),
        "observer_exit": observer_end.get("exit") if observer_end else None,
        "polls": polls,
        "polls_ok": polls_ok,
        "window_source": window["source"],
        "window_ok": window["ok"],
        "window_start": window["start_raw"],
        "window_end": window["end_raw"],
        "first_sample_at": first_sample.isoformat()
        if first_sample is not None else None,
        "first_sample_source": first_source,
        "heartbeat_count": len(heartbeats),
        "ended_at": ended_raw,
        "max_gap_seconds": max_gap,
        "error_records_in_window": len(error_records),
        "start_ok": start_ok,
        "end_ok": end_ok,
        "gap_ok": gap_ok,
        "no_errors": no_errors,
        "timestamps_ok": timestamps_ok,
    }
    completeness["ok"] = all((
        observer_end_ok, polls_ok, window["ok"], start_ok, end_ok, gap_ok,
        no_errors, timestamps_ok,
    ))
    return observed, completeness


def _analyse_contamination(path, peak):
    """피크 체크포인트의 최신 랭킹 시각이 개장 이후인지 읽기 전용으로 본다."""
    checkpoints = []
    preopen = []
    unproven = []
    for record in _read_jsonl(path):
        at = _moment(record.get("at"))
        if at is None or not (peak["open"] <= at < peak["end"]):
            continue
        raw = record.get("top10_observed_max")
        entry = {"at": record.get("at"),
                 "checkpoint": record.get("checkpoint"),
                 "top10_observed_max": raw}
        checkpoints.append(entry)
        observed = _moment(raw)
        if observed is None:
            unproven.append(entry)
        elif observed < peak["open"]:
            preopen.append(entry)
    return {
        "checked": bool(checkpoints),
        "ok": bool(checkpoints) and not preopen and not unproven,
        "checkpoints": checkpoints,
        "preopen": preopen,
        "unproven": unproven,
        "source": path,
    }


def _git_head():
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=os.path.dirname(_TOOLS_DIR),
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.strip() or None


def _tool_info():
    return {"git_commit": _git_head(),
            "sha256": _sha256_file(os.path.abspath(__file__))}


def _input_entry(path):
    return {"path": path, "sha256": _sha256_file(path)}


def _empty_report(inputs, tool):
    return {
        "verdict": None,
        "coverage": 0.0,
        "expected_count": 0,
        "observed_count": 0,
        "missing": [],
        "extra": [],
        "unclassified_accepted": [],
        "completeness": {},
        "contamination": {},
        "peak": {"open": None, "end": None},
        "inputs": inputs,
        "tool": tool,
    }


def attest(args):
    events_path = os.path.join(args.run_dir, EVENTS_FILE)
    inputs = {
        "events": _input_entry(events_path),
        "delivery": _input_entry(args.delivery),
        "observed": _input_entry(args.observed),
        "session_observer": _input_entry(args.session_observer),
        "calendar": _input_entry(args.calendar),
        "launcher_log": _input_entry(args.launcher_log),
    }
    report = _empty_report(inputs, _tool_info())

    fields, provenance_error = _read_provenance(args.launcher_log)
    if provenance_error is not None or _provenance_mismatches(fields, args):
        report["verdict"] = "PROVENANCE_MISMATCH"
        return report, EXIT_FAIL

    try:
        peak = _peak_window(args.calendar, args.date)
        if peak is None:
            report["verdict"] = "UNKNOWN_INPUT"
            return report, EXIT_FAIL
        report["peak"] = {"open": peak["open"].isoformat(),
                          "end": peak["end"].isoformat()}
        events = _load_events(events_path)
        expected, unclassified = _expected_groups(
            args.delivery, events, peak, args.device_id)
        observed, completeness = _analyse_observer(
            args.observed, args.start_tolerance_sec, args.end_tolerance_sec,
            args.max_gap_sec)
        contamination = _analyse_contamination(args.session_observer, peak)
    except InputError as exc:
        report["verdict"] = "UNKNOWN_INPUT"
        print("attest: %s" % exc, file=sys.stderr)
        return report, EXIT_FAIL

    missing = sorted(expected - observed)
    extra = sorted(observed - expected)
    coverage = len(expected & observed) / len(expected) if expected else 0.0

    report.update({
        "coverage": coverage,
        "expected_count": len(expected),
        "observed_count": len(observed),
        "missing": missing,
        "extra": extra,
        "unclassified_accepted": sorted(unclassified),
        "completeness": completeness,
        "contamination": contamination,
    })
    if not completeness["ok"]:
        report["verdict"] = "OBSERVATION_INCOMPLETE"
        return report, EXIT_FAIL
    if unclassified or missing or extra or coverage < 1.0:
        report["verdict"] = "COVERAGE_INCOMPLETE"
        return report, EXIT_FAIL
    if not contamination["ok"]:
        report["verdict"] = "PREOPEN_CONTAMINATION"
        return report, EXIT_FAIL
    report["verdict"] = "ACCEPTED"
    return report, EXIT_OK


def _date_arg(value):
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        raise argparse.ArgumentTypeError(
            "expected YYYY-MM-DD, got %r" % value)
    return value


def _tolerance_arg(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("expected an integer, got %r" % value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be >= 0, got %d" % number)
    return number


def _parser():
    parser = argparse.ArgumentParser(
        description="read-only post attestation: did the server's claimed "
                    "notifications actually reach the S10 tray during the "
                    "opening peak?")
    parser.add_argument("--date", required=True, type=_date_arg,
                        metavar="YYYY-MM-DD")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--delivery", required=True)
    parser.add_argument("--observed", required=True)
    parser.add_argument("--session-observer", required=True)
    parser.add_argument("--calendar", required=True)
    parser.add_argument("--launcher-log", required=True)
    parser.add_argument("--approved-commit", required=True)
    parser.add_argument("--approved-launcher-sha256", required=True)
    parser.add_argument("--device-id", default=DEFAULT_DEVICE_ID)
    parser.add_argument("--start-tolerance-sec", type=_tolerance_arg,
                        default=120)
    parser.add_argument("--end-tolerance-sec", type=_tolerance_arg,
                        default=120)
    parser.add_argument("--max-gap-sec", type=_tolerance_arg, default=90)
    parser.add_argument("--out")
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    report, code = attest(args)
    text = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    sys.stdout.write(text + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())