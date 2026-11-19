#!/usr/bin/env python3
"""개장 피크 알림 게시 증명(읽기 전용, 동결 입력만 사용).

서버가 주장한 알림(전달 원장의 ACCEPTED single/summary)이 수용 창
[개장, 개장+30분) 동안 대상 기기 트레이에 실제로 게시됐는지를 관측
파일과 대조해 판정한다. 판정 입력은 전부 CLI로 받은 동결 파일이며, 도구는
입력을 절대 쓰지 않는다. 유일한 쓰기는 --out 이다.

--observed-second 와 --device-id-second 를 함께 주면 두 기기를 각각
판정한 뒤, 두 기기가 받은 논리 그룹 집합이 서로 같고 서버가 주장한
집합과도 같은지를 별도로 검사한다. 기기 tag 에는 device_id 가 들어가므로
비교는 tag 문자열이 아니라 device_id 를 뗀 (observed_at) 그룹으로 한다.

판정(우선순위, 모두 exit 1):
  PROVENANCE_MISMATCH   RUN_PROVENANCE 1줄이 승인값과 다르다
  UNKNOWN_INPUT         캘린더 개장·입력 JSONL을 읽거나 해석할 수 없다
  OBSERVATION_INCOMPLETE 관측이 수용 창을 연속으로 덮었다는 증거가 없다
  COVERAGE_INCOMPLETE   기대 그룹 태그와 관측 태그가 다르거나 미분류 전달이 있다
  CROSS_DEVICE_MISMATCH 두 기기의 논리 그룹/슬롯 집합이 다르다
  PREOPEN_CONTAMINATION 피크 체크포인트의 최신 랭킹이 개장 이전이거나 증명 불가
  ACCEPTED              모든 검사 통과(exit 0)

범위·한계:
- 기대 태그는 (observed_at, device_id) 그룹의 트레이 슬롯 이름
  (tools/notify/group_tag.py)이다. message_kind가 없거나 원장 enum 밖이면
  미분류로 기록해 fail-closed 한다.
- digest 전달은 소리 그룹 주장이 아니지만 트레이에는 고정 슬롯
  (notify_fcm.DIGEST_TAG)으로 남는다. 수용된 digest 전달이 있는 기기의
  관측에서 그 슬롯 하나만 면제하고, 전달 주장 없이 관측되면 미계상으로
  실패한다. aggregation_started 는 슬롯 계약이 없으므로 면제하지 않는다.
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
    --approved-launcher-sha256 HEX [--out FILE] \
    [--device-id ID] [--observed-second FILE --device-id-second ID]
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
from group_tag import group_tag, parse_group_tag  # noqa: E402
from notify_ledger import MESSAGE_KINDS  # noqa: E402
from notify_fcm import DIGEST_TAG  # noqa: E402

DEFAULT_DEVICE_ID = "wuyoni-sm-g977n"
AUDIBLE_KINDS = frozenset(("single", "summary"))
SILENT_SLOT_KINDS = {"digest": DIGEST_TAG}
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


def _delivery_facts(delivery_path, events, peak, device_id, window):
    """서버가 주장한 발송을 증명 가능성에 따라 나눈다.

    expected: 피크에 속한 그룹이면서 관측 창 안에서 발송된 tag. coverage
      분모이자, 전부 관측되어야 하는 집합.
    accounted: 세션 원장이 주장하는 모든 가청 발송 tag. 기기에만 보이는
      미계상 tag를 가려내는 기준 — 피크 밖 그룹은 여기 속할 뿐 실패가 아니다.
    late: 피크 그룹인데 ACCEPTED 발송이 관측 창 밖인 tag. 관측자가 증명할 수
      없는 구간이므로 성공으로 접지 않는다(fail-closed).
    undelivered: 피크 그룹인데 ACCEPTED 발송이 하나도 없는 tag. FCM 실패·미완료
      그룹이 분모에서 조용히 빠지는 fail-open을 막는다.
    preopen: 개장 전 관측 이벤트가 피크 중에 가청 발송된 증거.
    unclassified: 종류를 알 수 없는 ACCEPTED 발송. 가청 여부를 판정할 수
      없으므로 fail-closed.
    silent_slots: 이 기기에 ACCEPTED 로 전달된 무음 슬롯(현재는 digest
      고정 tag). 트레이에 남지만 소리 그룹 주장이 아니므로 미계상에서
      면제한다. 전달 주장이 없으면 면제하지 않는다(fail-closed).
    """
    peak_tags = set()
    dispatched_peak = set()
    expected = set()
    accounted = set()
    silent_slots = set()
    preopen = []
    seen_preopen = set()
    unclassified = set()
    for record in _read_jsonl(delivery_path):
        if record.get("device_id") != device_id:
            continue
        event_id = record.get("event_id")
        event = events.get(event_id) if isinstance(event_id, str) else None
        if event is None:
            continue
        kind = record.get("message_kind")
        accepted = record.get("state") == "ACCEPTED"
        if not _known_kind(kind):
            if accepted:
                unclassified.add(event_id)
            continue
        if kind not in AUDIBLE_KINDS:
            if accepted and kind in SILENT_SLOT_KINDS:
                silent_slots.add(SILENT_SLOT_KINDS[kind])
            continue
        tag = group_tag(event["observed_at"], device_id)
        in_peak = peak["open"] <= event["at"] < peak["end"]
        if in_peak:
            peak_tags.add(tag)
            if accepted:
                dispatched_peak.add(tag)
        if not accepted:
            continue
        emitted = _moment(record.get("updated_at"))
        if emitted is None:
            raise InputError("%s: delivery %s has no aware updated_at"
                             % (delivery_path, event_id))
        accounted.add(tag)
        if in_peak:
            if window["start"] is not None and window["end"] is not None and \
                    window["start"] <= emitted <= window["end"]:
                expected.add(tag)
        if not in_peak and event["at"] < peak["open"] and \
                peak["open"] <= emitted < peak["end"]:
            key = (event_id, record.get("updated_at"))
            if key not in seen_preopen:
                seen_preopen.add(key)
                preopen.append({"event_id": event_id,
                                "observed_at": event["observed_at"],
                                "delivered_at": record.get("updated_at"),
                                "tag": tag})
    return {"expected": expected,
            "accounted": accounted,
            "silent_slots": silent_slots,
            "late": dispatched_peak - expected,
            "undelivered": peak_tags - dispatched_peak,
            "preopen": preopen,
            "unclassified": unclassified}


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
                      max_gap_sec, window_override=None):
    records = _read_jsonl(observed_path)
    ends = [record for record in records
            if record.get("kind") == "observer_end"]
    observer_end = ends[0] if ends else None
    declared = _observer_window(observer_end, records)
    window = declared
    window_matches = True
    if window_override is not None:
        # 두 번째 기기의 관측은 첫 기기가 확정한 동일 창에서만 센다.
        # 자기 창을 다르게 선언했다면 그 자체가 설정 불일치다.
        window_matches = (
            declared["ok"] and
            declared["start"] == window_override["start"] and
            declared["end"] == window_override["end"])
        window = dict(window_override)

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
        "window_matches": window_matches,
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
        observer_end_ok, polls_ok, window["ok"], window_matches, start_ok,
        end_ok, gap_ok, no_errors, timestamps_ok,
    ))
    return observed, completeness, window


def _logical_groups(tags, device_id):
    """기기 tag 집합을 device_id를 뗀 논리 그룹/외부/미분류로 나눈다.

    S10과 S25의 트레이 tag 문자열은 device_id 때문에 다르다. 비교 대상은
    그룹(observed_at)이지 tag가 아니다. parse되지 않는 tag(digest 같은
    고정 슬롯)는 unparsed로, 다른 기기 소유 tag는 foreign으로 분리한다.
    """
    groups = set()
    foreign = set()
    unparsed = set()
    for tag in tags:
        try:
            observed_at, owner = parse_group_tag(tag)
        except ValueError:
            unparsed.add(tag)
            continue
        if owner != device_id:
            foreign.add(tag)
            continue
        groups.add(observed_at)
    return groups, foreign, unparsed


def _device_pass(args, device_id, observed_path, events, peak,
                 window_override=None):
    """한 기기의 판정 입력을 모은다. 판정은 attest()가 조립한다."""
    observed, completeness, window = _analyse_observer(
        observed_path, args.start_tolerance_sec, args.end_tolerance_sec,
        args.max_gap_sec, window_override)
    facts = _delivery_facts(args.delivery, events, peak, device_id, window)
    claimed = facts["accounted"] | facts["silent_slots"]
    missing = sorted(facts["expected"] - observed)
    unaccounted = sorted(observed - claimed)
    coverage = len(facts["expected"] & observed) / len(facts["expected"]) \
        if facts["expected"] else None
    ok = not (facts["unclassified"] or missing or unaccounted or
              facts["late"] or facts["undelivered"])
    return {
        "device_id": device_id,
        "observed": observed,
        "window": window,
        "completeness": completeness,
        "facts": facts,
        "missing": missing,
        "unaccounted": unaccounted,
        "late": sorted(facts["late"]),
        "coverage": coverage,
        "coverage_ok": ok,
    }


def _device_summary(pass_result):
    facts = pass_result["facts"]
    return {
        "device_id": pass_result["device_id"],
        "coverage": pass_result["coverage"],
        "expected_count": len(facts["expected"]),
        "observed_count": len(pass_result["observed"]),
        "accounted_count": len(facts["accounted"]),
        "silent_slots": sorted(facts["silent_slots"]),
        "unclassified_accepted": sorted(facts["unclassified"]),
        "missing": pass_result["missing"],
        "unaccounted": pass_result["unaccounted"],
        "late": pass_result["late"],
        "undelivered": sorted(facts["undelivered"]),
        "completeness_ok": pass_result["completeness"]["ok"],
        "coverage_ok": pass_result["coverage_ok"],
    }


def _cross_device(first, second):
    """두 기기가 같은 논리 그룹·슬롯을 받았는지 비교한다.

    각자의 ACCEPTED 두 개로는 전체 동등성을 증명할 수 없다. 관측 집합과
    서버 주장(expected) 집합을 모두 device_id 없는 그룹 단위로 비교한다.
    """
    groups_a, foreign_a, unparsed_a = _logical_groups(
        first["observed"], first["device_id"])
    groups_b, foreign_b, unparsed_b = _logical_groups(
        second["observed"], second["device_id"])
    expected_a, _, _ = _logical_groups(
        first["facts"]["expected"], first["device_id"])
    expected_b, _, _ = _logical_groups(
        second["facts"]["expected"], second["device_id"])
    only_a = sorted(groups_a - groups_b)
    only_b = sorted(groups_b - groups_a)
    slot_only_a = sorted(unparsed_a - unparsed_b)
    slot_only_b = sorted(unparsed_b - unparsed_a)
    expected_only_a = sorted(expected_a - expected_b)
    expected_only_b = sorted(expected_b - expected_a)
    ok = not (only_a or only_b or slot_only_a or slot_only_b or
              foreign_a or foreign_b or expected_only_a or expected_only_b)
    return {
        "ok": ok,
        "devices": [first["device_id"], second["device_id"]],
        "groups": sorted(groups_a | groups_b),
        "group_count": len(groups_a | groups_b),
        "only_a": only_a,
        "only_b": only_b,
        "slots_only_a": slot_only_a,
        "slots_only_b": slot_only_b,
        "foreign_tags_a": sorted(foreign_a),
        "foreign_tags_b": sorted(foreign_b),
        "expected_only_a": expected_only_a,
        "expected_only_b": expected_only_b,
    }


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
        "device_id": None,
        "coverage": None,
        "vacuous": False,
        "expected_count": 0,
        "observed_count": 0,
        "accounted_count": 0,
        "silent_slots": [],
        "missing": [],
        "unaccounted": [],
        "late": [],
        "undelivered": [],
        "preopen_delivered": [],
        "unclassified_accepted": [],
        "completeness": {},
        "contamination": {},
        "devices": [],
        "cross_device": None,
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
    if getattr(args, "observed_second", None):
        inputs["observed_second"] = _input_entry(args.observed_second)
    report = _empty_report(inputs, _tool_info())
    report["device_id"] = args.device_id
    peer_id = getattr(args, "device_id_second", None)

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
        first = _device_pass(args, args.device_id, args.observed, events, peak)
        second = None
        if peer_id is not None:
            second = _device_pass(args, peer_id, args.observed_second, events,
                                  peak, window_override=first["window"])
        contamination = _analyse_contamination(args.session_observer, peak)
    except InputError as exc:
        report["verdict"] = "UNKNOWN_INPUT"
        print("attest: %s" % exc, file=sys.stderr)
        return report, EXIT_FAIL

    facts = first["facts"]
    contamination["delivered_preopen"] = facts["preopen"]
    contamination["ok"] = contamination["ok"] and not facts["preopen"]

    report.update({
        "coverage": first["coverage"],
        "vacuous": not facts["expected"],
        "expected_count": len(facts["expected"]),
        "observed_count": len(first["observed"]),
        "accounted_count": len(facts["accounted"]),
        "silent_slots": sorted(facts["silent_slots"]),
        "missing": first["missing"],
        "unaccounted": first["unaccounted"],
        "late": first["late"],
        "undelivered": sorted(facts["undelivered"]),
        "preopen_delivered": facts["preopen"],
        "unclassified_accepted": sorted(facts["unclassified"]),
        "completeness": first["completeness"],
        "contamination": contamination,
        "devices": [_device_summary(first)],
    })
    if second is not None:
        report["devices"].append(_device_summary(second))
        report["peer"] = _device_summary(second)
        report["cross_device"] = _cross_device(first, second)

    if not first["completeness"]["ok"]:
        report["verdict"] = "OBSERVATION_INCOMPLETE"
        return report, EXIT_FAIL
    if second is not None and not second["completeness"]["ok"]:
        report["verdict"] = "OBSERVATION_INCOMPLETE"
        return report, EXIT_FAIL
    if not first["coverage_ok"]:
        report["verdict"] = "COVERAGE_INCOMPLETE"
        return report, EXIT_FAIL
    if second is not None and not second["coverage_ok"]:
        report["verdict"] = "COVERAGE_INCOMPLETE"
        return report, EXIT_FAIL
    if second is not None and not report["cross_device"]["ok"]:
        report["verdict"] = "CROSS_DEVICE_MISMATCH"
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
    parser.add_argument("--observed-second")
    parser.add_argument("--device-id-second")
    parser.add_argument("--start-tolerance-sec", type=_tolerance_arg,
                        default=120)
    parser.add_argument("--end-tolerance-sec", type=_tolerance_arg,
                        default=120)
    parser.add_argument("--max-gap-sec", type=_tolerance_arg, default=90)
    parser.add_argument("--out")
    return parser


def main(argv=None):
    parser = _parser()
    args = parser.parse_args(argv)
    if bool(args.observed_second) != bool(args.device_id_second):
        parser.error("--observed-second and --device-id-second must be "
                     "given together")
    if args.device_id_second is not None and \
            args.device_id_second == args.device_id:
        parser.error("--device-id-second must differ from --device-id")
    report, code = attest(args)
    text = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    sys.stdout.write(text + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())