#!/usr/bin/env python3
"""tools/attest_notifications.py 계약 테스트 — 동결 픽스처만 사용한다.

네트워크·실기기·실제 원장을 쓰지 않는다. 모든 입력은 임시 디렉터리에
만든 JSONL/JSON 픽스처다. 검사 대상은 판정 축이다: provenance 일치,
관측 완전성(heartbeat 연속성·observer_end), 기대/관측 태그 커버리지,
미분류 ACCEPTED 전달의 fail-closed, 그리고 입력 무쓰기.

실행: python3 tests/test_attest_notifications.py
"""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL_PATH = REPO_ROOT / "tools" / "attest_notifications.py"
sys.path.insert(0, str(REPO_ROOT / "tools" / "notify"))
sys.dont_write_bytecode = True

from group_tag import group_tag  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "attest_notifications", TOOL_PATH)
att = importlib.util.module_from_spec(_spec)
sys.modules["attest_notifications"] = att
_spec.loader.exec_module(att)

DATE = "2026-11-19"
OPEN_RAW = "09:00:00+09:00"
PEAK_OPEN = "2026-11-19T09:00:00+09:00"
PEAK_END = "2026-11-19T09:30:00+09:00"
WINDOW_START = "2026-11-19T08:58:00+09:00"
WINDOW_END = "2026-11-19T09:30:00+09:00"
DEVICE = "wuyoni-sm-g977n"
COMMIT = "1" * 40
LAUNCHER_SHA = "2" * 64

EVENT_A = hashlib.sha256(b"event-a").hexdigest()
EVENT_B = hashlib.sha256(b"event-b").hexdigest()
EVENT_PRE = hashlib.sha256(b"event-pre").hexdigest()
AT_A = "2026-11-19T09:05:00+09:00"
AT_B = "2026-11-19T09:10:00+09:00"
AT_PRE = "2026-11-19T08:50:00+09:00"
TAG_A = group_tag(AT_A, DEVICE)
TAG_B = group_tag(AT_B, DEVICE)
TAG_PRE = group_tag(AT_PRE, DEVICE)

_MISSING = object()


def times(start, end, step_sec=30):
    current = datetime.fromisoformat(start)
    stop = datetime.fromisoformat(end)
    while current <= stop:
        yield current.isoformat()
        current += timedelta(seconds=step_sec)


def write_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def event(event_id, observed_at):
    return {"event_id": event_id, "observed_at": observed_at,
            "session_id": DATE}


def delivery(event_id, message_kind="single", state="ACCEPTED",
             device=DEVICE, updated_at="2026-11-19T09:05:01+09:00"):
    record = {"attempts": 1, "device_id": device, "event_id": event_id,
              "state": state, "updated_at": updated_at}
    if message_kind is not _MISSING:
        record["message_kind"] = message_kind
    return record


def notification(tag, captured_at):
    return {"tag": tag, "captured_at": captured_at,
            "snapshot_status": "OBSERVED_ACTIVE",
            "device_serial": "FAKE123",
            "package": "com.hongscanner.hongscanner"}


def heartbeat(captured_at):
    return {"kind": "heartbeat", "captured_at": captured_at}


def default_heartbeats():
    return [heartbeat(stamp) for stamp in times(WINDOW_START, WINDOW_END)]


def observer_end(polls=None):
    return {"kind": "observer_end",
            "started_at": WINDOW_START,
            "ended_at": WINDOW_END,
            "window_start": WINDOW_START,
            "window_end": WINDOW_END,
            "polls": 65 if polls is None else polls,
            "exit": "ok"}


def provenance_line(**overrides):
    fields = {"run_id": "2026-11-19", "session_date": DATE,
              "git_commit": COMMIT, "launcher_sha256": LAUNCHER_SHA,
              "git_dirty": "0", "started_at": "2026-11-19T08:50:00+09:00"}
    fields.update(overrides)
    return "RUN_PROVENANCE " + " ".join(
        "%s=%s" % (key, value) for key, value in fields.items())


def default_events():
    return [event(EVENT_A, AT_A), event(EVENT_B, AT_B)]


def default_deliveries():
    return [delivery(EVENT_A, "single"), delivery(EVENT_B, "summary")]


def default_observer():
    return (default_heartbeats() +
            [notification(TAG_A, "2026-11-19T09:05:30+09:00"),
             notification(TAG_B, "2026-11-19T09:10:30+09:00")] +
            [observer_end()])


def default_calendar():
    return {"schema": "hong-scanner-calendar/1", "market": "KRX",
            "tz": "Asia/Seoul",
            "days": {DATE: {"open": OPEN_RAW, "close": "15:30:00+09:00"}}}


class Case:
    def __init__(self, root):
        self.root = Path(root)
        self.run_dir = self.root / "run"
        self.delivery = self.root / "delivery.hcj.jsonl"
        self.observed = self.root / "observed.hcj.jsonl"
        self.calendar = self.root / "calendar.json"
        self.launcher = self.root / "launcher.log"
        self.session_observer = self.root / "session-observer.hcj.jsonl"
        self.session_records = [
            {"at": "2026-11-19T09:05:00+09:00", "checkpoint": "09:05",
             "top10_observed_max": "2026-11-19T09:00:19+09:00"},
            {"at": "2026-11-19T09:15:00+09:00", "checkpoint": "09:15",
             "top10_observed_max": "2026-11-19T09:10:19+09:00"},
            {"at": "2026-11-19T09:25:00+09:00", "checkpoint": "09:25",
             "top10_observed_max": "2026-11-19T09:20:19+09:00"},
        ]
        self.out = self.root / "attestation.json"
        self.events = default_events()
        self.deliveries = default_deliveries()
        self.observer = default_observer()
        self.calendar_data = default_calendar()
        self.provenance_lines = [
            "=== run_session start 2026-11-19T08:50:00+09:00",
            provenance_line(),
        ]
        self.approved_commit = COMMIT
        self.approved_launcher_sha256 = LAUNCHER_SHA
        self.extra_args = []

    @property
    def events_path(self):
        return self.run_dir / "events.hcj.jsonl"

    def write(self):
        self.run_dir.mkdir(parents=True, exist_ok=True)
        write_jsonl(self.events_path, self.events)
        write_jsonl(self.delivery, self.deliveries)
        write_jsonl(self.observed, self.observer)
        write_jsonl(self.session_observer, self.session_records)
        self.calendar.write_text(
            json.dumps(self.calendar_data, ensure_ascii=False),
            encoding="utf-8")
        self.launcher.write_text(
            "\n".join(self.provenance_lines) + "\n", encoding="utf-8")

    def argv(self, include_out=False):
        argv = [
            "--date", DATE,
            "--run-dir", str(self.run_dir),
            "--delivery", str(self.delivery),
            "--observed", str(self.observed),
            "--session-observer", str(self.session_observer),
            "--calendar", str(self.calendar),
            "--launcher-log", str(self.launcher),
            "--approved-commit", self.approved_commit,
            "--approved-launcher-sha256", self.approved_launcher_sha256,
        ]
        if include_out:
            argv += ["--out", str(self.out)]
        return argv + self.extra_args

    def run(self, include_out=False, write=True):
        if write:
            self.write()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), \
                contextlib.redirect_stderr(io.StringIO()):
            code = att.main(self.argv(include_out))
        return code, json.loads(buf.getvalue())


class AttestationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.case = Case(self._tmp.name)

    def test_clean_window_is_accepted(self):
        code, report = self.case.run(include_out=True)
        self.assertEqual(code, 0)
        self.assertEqual(report["verdict"], "ACCEPTED")
        self.assertEqual(report["coverage"], 1.0)
        self.assertEqual(report["expected_count"], 2)
        self.assertEqual(report["observed_count"], 2)
        self.assertEqual(report["missing"], [])
        self.assertEqual(report["unaccounted"], [])
        self.assertEqual(report["unclassified_accepted"], [])
        self.assertTrue(report["completeness"]["ok"])
        self.assertEqual(report["completeness"]["window_start"], WINDOW_START)
        self.assertEqual(report["completeness"]["window_end"], WINDOW_END)
        self.assertEqual(report["completeness"]["max_gap_seconds"], 30.0)
        self.assertEqual(report["peak"], {"open": PEAK_OPEN, "end": PEAK_END})
        self.assertEqual(report["tool"]["sha256"],
                         hashlib.sha256(TOOL_PATH.read_bytes()).hexdigest())
        written = json.loads(self.case.out.read_text(encoding="utf-8"))
        self.assertEqual(written, report)

    def test_every_input_is_hashed_into_the_report(self):
        code, report = self.case.run()
        self.assertEqual(code, 0)
        expected_paths = {
            "events": self.case.events_path,
            "delivery": self.case.delivery,
            "observed": self.case.observed,
            "session_observer": self.case.session_observer,
            "calendar": self.case.calendar,
            "launcher_log": self.case.launcher,
        }
        for name, path in expected_paths.items():
            with self.subTest(name=name):
                self.assertEqual(report["inputs"][name]["path"], str(path))
                self.assertEqual(
                    report["inputs"][name]["sha256"],
                    hashlib.sha256(path.read_bytes()).hexdigest())

    def test_missing_notification_is_coverage_incomplete(self):
        self.case.observer = [record for record in self.case.observer
                              if record.get("tag") != TAG_B]
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "COVERAGE_INCOMPLETE")
        self.assertEqual(report["missing"], [TAG_B])
        self.assertEqual(report["unaccounted"], [])
        self.assertEqual(report["coverage"], 0.5)

    def test_unaccounted_observed_tag_is_coverage_incomplete(self):
        unaccounted_tag = group_tag("2026-11-19T09:15:00+09:00", DEVICE)
        self.case.observer.insert(
            -1, notification(unaccounted_tag, "2026-11-19T09:15:30+09:00"))
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "COVERAGE_INCOMPLETE")
        self.assertEqual(report["missing"], [])
        self.assertEqual(report["unaccounted"], [unaccounted_tag])
        self.assertEqual(report["coverage"], 1.0)

    def test_git_commit_mismatch_is_provenance_mismatch(self):
        self.case.provenance_lines[1] = provenance_line(git_commit="0" * 40)
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "PROVENANCE_MISMATCH")

    def test_launcher_sha256_mismatch_is_provenance_mismatch(self):
        self.case.provenance_lines[1] = provenance_line(
            launcher_sha256="f" * 64)
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "PROVENANCE_MISMATCH")

    def test_dirty_working_tree_is_provenance_mismatch(self):
        self.case.provenance_lines[1] = provenance_line(git_dirty="1")
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "PROVENANCE_MISMATCH")

    def test_late_first_heartbeat_is_observation_incomplete(self):
        self.case.observer = (
            [heartbeat(stamp)
             for stamp in times("2026-11-19T09:10:00+09:00", WINDOW_END)] +
            [notification(TAG_A, "2026-11-19T09:10:30+09:00"),
             notification(TAG_B, "2026-11-19T09:11:00+09:00"),
             observer_end(polls=41)])
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "OBSERVATION_INCOMPLETE")
        self.assertFalse(report["completeness"]["start_ok"])
        self.assertEqual(report["completeness"]["first_sample_at"],
                         "2026-11-19T09:10:00+09:00")

    def test_heartbeat_gap_over_limit_is_observation_incomplete(self):
        heartbeats = (
            [heartbeat(stamp)
             for stamp in times("2026-11-19T08:58:00+09:00",
                               "2026-11-19T09:00:00+09:00")] +
            [heartbeat(stamp)
             for stamp in times("2026-11-19T09:02:00+09:00", WINDOW_END)])
        self.case.observer = heartbeats + [
            notification(TAG_A, "2026-11-19T09:05:30+09:00"),
            notification(TAG_B, "2026-11-19T09:10:30+09:00"),
            observer_end(),
        ]
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "OBSERVATION_INCOMPLETE")
        self.assertFalse(report["completeness"]["gap_ok"])
        self.assertGreater(report["completeness"]["max_gap_seconds"], 90)

    def test_error_record_in_window_is_observation_incomplete(self):
        self.case.observer.insert(-1, {
            "captured_at": "2026-11-19T09:12:00+09:00",
            "error": "observer python failed rc=1",
            "errors": {"observer": "python failed rc=1"},
        })
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "OBSERVATION_INCOMPLETE")
        self.assertFalse(report["completeness"]["no_errors"])
        self.assertEqual(report["completeness"]["error_records_in_window"], 1)

    def test_missing_observer_end_is_observation_incomplete(self):
        self.case.observer = [record for record in self.case.observer
                              if record.get("kind") != "observer_end"]
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "OBSERVATION_INCOMPLETE")
        self.assertEqual(report["completeness"]["observer_end_count"], 0)
        self.assertEqual(report["completeness"]["window_source"], "records")
        self.assertEqual(report["completeness"]["window_start"], WINDOW_START)
        self.assertEqual(report["completeness"]["window_end"], WINDOW_END)

    def test_accepted_row_without_message_kind_is_unclassified(self):
        self.case.deliveries[0] = delivery(EVENT_A, message_kind=_MISSING)
        self.case.observer = [record for record in self.case.observer
                              if record.get("tag") != TAG_A]
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "COVERAGE_INCOMPLETE")
        self.assertEqual(report["unclassified_accepted"], [EVENT_A])
        self.assertEqual(report["coverage"], 1.0)
        self.assertEqual(report["missing"], [])
        self.assertEqual(report["unaccounted"], [])

    def test_pre_open_delivery_before_open_is_accounted_not_unaccounted(self):
        # 개장 전 관측이 개장 전에 발송된 경우: 피크 그룹도 아니고 기기 tag도
        # 미계상이 아니므로 수용에 영향을 주지 않는다.
        self.case.events.append(event(EVENT_PRE, AT_PRE))
        self.case.deliveries.append(
            delivery(EVENT_PRE, "single",
                     updated_at="2026-11-19T08:52:00+09:00"))
        self.case.observer.insert(
            -1, notification(TAG_PRE, "2026-11-19T08:52:30+09:00"))
        code, report = self.case.run()
        self.assertEqual(code, 0)
        self.assertEqual(report["verdict"], "ACCEPTED")
        self.assertEqual(report["expected_count"], 2)
        self.assertEqual(report["observed_count"], 2)
        self.assertEqual(report["missing"], [])
        self.assertEqual(report["unaccounted"], [])
        self.assertEqual(report["preopen_delivered"], [])

    def test_pre_open_event_delivered_in_peak_is_contamination(self):
        # 개장 전 관측으로 만든 알림이 피크 중에 발송되면 그 소리는 개장 전
        # 정보에 대한 것이다 — 수용 실패로 기록한다(2026-11-19 실측 사례).
        self.case.events.append(event(EVENT_PRE, AT_PRE))
        self.case.deliveries.append(delivery(EVENT_PRE, "single"))
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "PREOPEN_CONTAMINATION")
        self.assertEqual(len(report["preopen_delivered"]), 1)
        self.assertEqual(report["preopen_delivered"][0]["event_id"], EVENT_PRE)
        self.assertFalse(report["contamination"]["ok"])

    def test_peak_group_delivered_after_window_is_late(self):
        # 서버가 주장한 피크 그룹이 관측 창 밖에서 발송되면 관측자가 증명할
        # 수 없다 — 분모에서 조용히 빼지 않고 실패로 남긴다.
        self.case.deliveries = [
            delivery(EVENT_A, "single",
                     updated_at="2026-11-19T10:00:00+09:00"),
            delivery(EVENT_B, "summary",
                     updated_at="2026-11-19T10:00:00+09:00")]
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "COVERAGE_INCOMPLETE")
        self.assertEqual(report["expected_count"], 0)
        self.assertEqual(sorted(report["late"]), sorted([TAG_A, TAG_B]))
        self.assertTrue(report["vacuous"])
        self.assertIsNone(report["coverage"])

    def test_no_peak_groups_is_vacuous_acceptance(self):
        # 시장이 실제로 그룹을 만들지 않은 날은 소리가 0번 나는 것이 정상이다.
        # 다만 vacuous=true로 드러내 조용한 통과를 숨기지 않는다.
        self.case.deliveries = []
        self.case.observer = default_heartbeats() + [observer_end()]
        code, report = self.case.run()
        self.assertEqual(code, 0)
        self.assertEqual(report["verdict"], "ACCEPTED")
        self.assertEqual(report["expected_count"], 0)
        self.assertIsNone(report["coverage"])
        self.assertTrue(report["vacuous"])

    def test_missing_calendar_open_is_unknown_input(self):
        self.case.calendar_data = {
            "days": {DATE: {"close": "15:30:00+09:00"}}}
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "UNKNOWN_INPUT")
        self.assertEqual(report["peak"], {"open": None, "end": None})

    def test_inputs_are_never_written_and_out_is_the_only_write(self):
        self.case.write()
        paths = [self.case.events_path, self.case.delivery,
                 self.case.observed, self.case.session_observer,
                 self.case.calendar, self.case.launcher]
        before = {str(path): path.read_bytes() for path in paths}
        run_dir_before = sorted(p.name for p in self.case.run_dir.iterdir())
        self.assertFalse(self.case.out.exists())
        code, report = self.case.run(include_out=True, write=False)
        after = {str(path): path.read_bytes() for path in paths}
        run_dir_after = sorted(p.name for p in self.case.run_dir.iterdir())
        self.assertEqual(code, 0)
        self.assertEqual(before, after)
        self.assertEqual(run_dir_before, run_dir_after)
        self.assertTrue(self.case.out.exists())
        self.assertEqual(
            json.loads(self.case.out.read_text(encoding="utf-8")), report)


    def test_clean_peak_checkpoints_report_contamination_ok(self):
        code, report = self.case.run()
        self.assertEqual(code, 0)
        self.assertTrue(report["contamination"]["ok"])
        self.assertTrue(report["contamination"]["checked"])
        self.assertEqual(len(report["contamination"]["checkpoints"]), 3)
        self.assertEqual(report["contamination"]["preopen"], [])
        self.assertEqual(report["contamination"]["unproven"], [])
        self.assertEqual(report["contamination"]["source"],
                         str(self.case.session_observer))

    def test_preopen_ranking_in_peak_is_preopen_contamination(self):
        self.case.session_records[0]["top10_observed_max"] = (
            "2026-11-19T08:59:57+09:00")
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "PREOPEN_CONTAMINATION")
        self.assertFalse(report["contamination"]["ok"])
        self.assertEqual(len(report["contamination"]["preopen"]), 1)
        self.assertEqual(report["coverage"], 1.0)

    def test_peak_without_checkpoint_is_unproven(self):
        self.case.session_records = [
            {"at": "2026-11-19T09:55:00+09:00", "checkpoint": "09:55",
             "top10_observed_max": "2026-11-19T09:50:19+09:00"}]
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "PREOPEN_CONTAMINATION")
        self.assertFalse(report["contamination"]["checked"])
        self.assertEqual(report["contamination"]["checkpoints"], [])

    def test_null_ranking_in_peak_is_unproven(self):
        self.case.session_records[1]["top10_observed_max"] = None
        code, report = self.case.run()
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "PREOPEN_CONTAMINATION")
        self.assertTrue(report["contamination"]["checked"])
        self.assertEqual(len(report["contamination"]["unproven"]), 1)

    def test_ranking_exactly_at_open_is_clean(self):
        self.case.session_records[0]["top10_observed_max"] = (
            "2026-11-19T09:00:00+09:00")
        code, report = self.case.run()
        self.assertEqual(code, 0)
        self.assertTrue(report["contamination"]["ok"])
        self.assertEqual(report["contamination"]["preopen"], [])

    def test_malformed_session_observer_is_unknown_input(self):
        self.case.write()
        self.case.session_observer.write_text("{not json\n", encoding="utf-8")
        code, report = self.case.run(write=False)
        self.assertEqual(code, 1)
        self.assertEqual(report["verdict"], "UNKNOWN_INPUT")


if __name__ == "__main__":
    unittest.main(verbosity=2)