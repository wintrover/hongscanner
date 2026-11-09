#!/usr/bin/env python3
"""Read-only API contract suite (tools/api/README.md §6): unittest over
a real serve.py process on an EPHEMERAL port (0), loopback by default
plus one --bind case on 127.0.0.2, against synthetic fixture run
directories and ledgers built in a mktemp sandbox. Loopback network
only, no market data, no credentials, no live calls.

The suite starts and reaps every server process it spawns and asserts
each one exits cleanly (SIGTERM -> exit 0, no residue). A malformed
response byte, a leaked path/secret, or a surviving process fails the
suite. Fail-closed: no assertion reports a pass on absence of evidence.
"""

import hashlib
import json
import os
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import unittest

from urllib import request as urlrequest
from urllib.error import HTTPError

SERVE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "serve.py")
PY = sys.executable

# The module under unit test for the §3.7 name-dictionary fold (pure
# function + memoization behavior — endpoint bytes stay black-box).
sys.path.insert(0, os.path.dirname(SERVE))
import serve  # noqa: E402

SECRET = "SUPERSECRET-VALUE-NEVER-SERVE"
HIDDEN_HOST = "hidden-host-internal"
HIDDEN_EGRESS = "203.0.113.7"
HIDDEN_PID = 987654321


def canonical(obj):
    """The response wire encoding the contract pins: UTF-8, compact,
    keys in codepoint order, no floats."""
    return json.dumps(obj, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def event_id(tag):
    return sha(b"event-fixture-" + tag)


def event_fact(tag, event_type, session_id, observed_at, rule_id,
               severity="INFO", **extra):
    fact = {
        "data_quality": "OBSERVING",
        "event_id": event_id(tag),
        "event_type": event_type,
        "evidence_ref": sha(b"evidence-" + tag),
        "observed_at": observed_at,
        "rule_id": rule_id,
        "rule_version": 1,
        "session_id": session_id,
        "severity": severity,
    }
    fact.update(extra)
    return fact


EV1 = event_fact(b"1", "CANDIDATE_ENTERED", "2026-10-29",
                 "2026-10-29T09:12:33+09:00", "candidate-entered",
                 direction="UP", rank=1, symbol="005930")
EV2 = event_fact(b"2", "SESSION_ENDED", "2026-10-29",
                 "2026-10-29T15:30:00+09:00", "session-close-v1")
EV3 = event_fact(b"3", "CANDIDATE_ENTERED", "2026-10-30",
                 "2026-10-30T10:00:00+09:00", "candidate-entered",
                 severity="HIGH", direction="DOWN", rank=2, symbol="000660")
EV4 = event_fact(b"4", "CANDIDATE_EXITED", "2026-10-30",
                 "2026-10-30T11:00:00+09:00", "candidate-exited",
                 symbol="000660")

D1 = {"attempts": 0, "device_id": "dev-1", "event_id": EV1["event_id"],
      "state": "PENDING", "updated_at": "2026-11-01T09:00:00+09:00"}
D2 = {"attempts": 1, "device_id": "dev-1", "event_id": EV1["event_id"],
      "provider_message_id": "projects/drill-project/messages/m-1",
      "state": "ACCEPTED", "updated_at": "2026-11-01T09:01:00+09:00"}
D3 = {"attempts": 2, "device_id": "dev-1", "error_code": "UNREGISTERED",
      "event_id": EV3["event_id"], "state": "FAILED",
      "updated_at": "2026-11-01T09:02:00+09:00"}
D4 = {"attempts": 0, "device_id": "dev-2", "event_id": EV4["event_id"],
      "state": "PENDING", "updated_at": "2026-11-01T09:02:00+09:00"}

COMMIT_A = sha(b"code-commit-a")
COMMIT_B = sha(b"code-commit-b")
COMMIT_C = sha(b"code-commit-c")

RUN_JSON_A = {"bar_count": 2, "code_commit": COMMIT_A,
              "egress_ip": HIDDEN_EGRESS, "host": HIDDEN_HOST,
              "pid": HIDDEN_PID, "run_id": "run-a",
              "session_date": "2026-10-29", "signal_count": 1,
              "started_at": "2026-11-01T08:00:00+09:00"}
RUN_JSON_B = {"code_commit": COMMIT_B, "run_id": "run-b",
              "session_date": "2026-10-30",
              "started_at": "2026-11-01T09:00:00+09:00"}
RUN_JSON_C = {"code_commit": COMMIT_C, "run_id": "run-c",
              "session_date": "2026-10-31",
              "started_at": "2026-11-02T08:00:00+09:00"}

INPUT_A = [
    {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
    {"kind": "config", "raw": {"session_date": "2026-10-29"}, "seq": 2},
    {"kind": "ws_frame", "raw": {"price": 10000, "symbol": "005930"},
     "seq": 3},
    {"kind": "ws_frame", "raw": {"price": 10100, "symbol": "005930"},
     "seq": 4},
    {"kind": "session_end", "raw": None, "seq": 5},
]
INPUT_B = [
    {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
    {"kind": "config", "raw": {"session_date": "2026-10-30"}, "seq": 2},
]
BARS_LINE = {"bar_index": 0, "price": 10100, "symbol": "005930"}
SIGNALS_LINE = {"bar_index": 0, "reason": "first_after_sub",
                "signal": "SIGNAL_HELD", "symbol": "005930"}

# -- /mobile/market-view (README §3.7) fixtures --------------------------

MV_WINNER = "market-2026-11-09-b"

# The winning run's fold scenario (README §3.7): a multi-generation
# UP ranking (enter -> update -> re-rank -> exit -> re-enter), a DOWN
# ranking, and one INCOMPLETE non-candidate event that touches only
# by_data_quality — and, being last, latest/as_of.
MV_UP_ENTERED_1 = event_fact(b"mv-up-e1", "CANDIDATE_ENTERED", "2026-11-09",
                             "2026-11-09T10:00:01+09:00",
                             "candidate-transition-v1",
                             direction="UP", rank=1, symbol="005930")
MV_UP_UPDATED_1 = event_fact(b"mv-up-u1", "CANDIDATE_UPDATED", "2026-11-09",
                             "2026-11-09T10:00:02+09:00",
                             "candidate-transition-v1",
                             direction="UP", rank=9, symbol="005930")
MV_UP_ENTERED_2 = event_fact(b"mv-up-e2", "CANDIDATE_ENTERED", "2026-11-09",
                             "2026-11-09T10:00:03+09:00",
                             "candidate-transition-v1",
                             direction="UP", rank=2, symbol="006660")
MV_UP_EXITED_2 = event_fact(b"mv-up-x2", "CANDIDATE_EXITED", "2026-11-09",
                            "2026-11-09T10:00:04+09:00",
                            "candidate-transition-v1",
                            direction="UP", symbol="006660")
MV_UP_REENTERED_2 = event_fact(b"mv-up-r2", "CANDIDATE_ENTERED",
                               "2026-11-09",
                               "2026-11-09T10:00:05+09:00",
                               "candidate-transition-v1",
                               direction="UP", rank=3, symbol="006660")
MV_DOWN_ENTERED_1 = event_fact(b"mv-dn-e1", "CANDIDATE_ENTERED",
                               "2026-11-09",
                               "2026-11-09T10:00:06+09:00",
                               "candidate-transition-v1",
                               direction="DOWN", rank=1, symbol="000660")
MV_DOWN_UPDATED_1 = event_fact(b"mv-dn-u1", "CANDIDATE_UPDATED",
                               "2026-11-09",
                               "2026-11-09T10:00:07+09:00",
                               "candidate-transition-v1",
                               direction="DOWN", rank=2, symbol="000660")
MV_INCOMPLETE_SUB = event_fact(b"mv-sub", "SUBSCRIPTION_TRUNCATED",
                               "2026-11-09",
                               "2026-11-09T10:00:08+09:00",
                               "subscription-truncated-v1",
                               severity="HIGH", data_quality="INCOMPLETE",
                               direction="UP")

MV_WINNER_EVENTS = [MV_UP_ENTERED_1, MV_UP_UPDATED_1, MV_UP_ENTERED_2,
                    MV_UP_EXITED_2, MV_UP_REENTERED_2, MV_DOWN_ENTERED_1,
                    MV_DOWN_UPDATED_1, MV_INCOMPLETE_SUB]

# -- §3.7 name dictionary fixtures: ka10027 rest_resp records in the
# winner's input.hcj.jsonl, with the recorder's envelope shape. The
# recorded bodies exercise every fold rule: an error body without the
# ranking list (no names — absence served), a first page whose 006660
# name is later superseded (file order, last record wins), a ka10080
# record (scanned, never a name source), and a symbol (000660) no
# recorded body ever names (name null — the app falls back to the
# symbol).

MV_KA10027_QUERY = {"crd_cnd": "0", "mrkt_tp": "000", "pric_cnd": "0",
                    "sort_tp": "1", "stk_cnd": "16", "stex_tp": "1",
                    "trde_prica_cnd": "0", "trde_qty_cnd": "0000",
                    "updown_incls": "1"}


def rest_resp_record(seq, body_obj, api_id="ka10027", page=1, status=200):
    return {"kind": "rest_resp",
            "raw": {"api_id": api_id,
                    "body_hex": canonical(body_obj).hex(),
                    "cont_yn": "N", "next_key": "", "page": page,
                    "query": dict(MV_KA10027_QUERY), "status": status},
            "seq": seq}


def ka10027_body(rows):
    return {"pred_pre_flu_rt_upper": [{"stk_cd": cd, "stk_nm": nm}
                                       for cd, nm in rows],
            "return_code": 0, "return_msg": "정상처리 되었습니다."}


MV_ERROR_BODY = {"return_code": 5,
                 "return_msg": "허용된 요청 개수를 초과하였습니다"}
MV_KA10080_BODY = {"return_code": 0, "return_msg": "정상처리 되었습니다.",
                   "stk_min_pole_chart_qry": [{"cur_prc": "+1000",
                                               "trde_qty": "100"}]}

MV_WINNER_INPUT = [
    rest_resp_record(3, MV_ERROR_BODY, status=429),
    rest_resp_record(4, ka10027_body([("005930", "삼성전자"),
                                      ("006660", "구형이름")])),
    rest_resp_record(5, MV_KA10080_BODY, api_id="ka10080"),
    rest_resp_record(6, ka10027_body([("006660", "LG전자"),
                                      ("179530", "애드바이오텍")]), page=2),
    {"kind": "ws_frame", "raw": {"price": 10000, "symbol": "005930"},
     "seq": 7},
]

# The folded dictionary the winner's input must project: latest record
# wins for 006660, the error and ka10080 bodies contribute nothing, and
# 000660 is never named.
MV_NAME_MAP = {"005930": "삼성전자", "006660": "LG전자"}


def mv_item(ev, names=None):
    """The §3.7 item whitelist of a fixture fact: eight fields — seven
    recorded plus `name` from the fixture's folded ka10027 dictionary
    (None when no recorded body names the symbol — the fail-closed
    fallback), rank null when the fact records none
    (CANDIDATE_EXITED)."""
    item = {k: ev[k] for k in ("data_quality", "direction", "event_id",
                               "event_type", "observed_at", "symbol")}
    item["rank"] = ev.get("rank")
    item["name"] = (names or {}).get(ev["symbol"])
    return item


MV_EXPECTED = {
    "as_of": "2026-11-09T10:00:08+09:00",
    "falling_top10": [mv_item(MV_DOWN_UPDATED_1, MV_NAME_MAP)],
    "history": [mv_item(ev, MV_NAME_MAP) for ev in MV_WINNER_EVENTS
                if ev["event_type"].startswith("CANDIDATE_")],
    "latest": {"data_quality": "INCOMPLETE",
               "event_id": MV_INCOMPLETE_SUB["event_id"],
               "event_type": "SUBSCRIPTION_TRUNCATED",
               "observed_at": "2026-11-09T10:00:08+09:00"},
    "rising_top10": [mv_item(MV_UP_REENTERED_2, MV_NAME_MAP),
                     mv_item(MV_UP_UPDATED_1, MV_NAME_MAP)],
    "run": {"environment": "demo", "run_id": MV_WINNER,
            "session": MV_WINNER, "session_date": "2026-11-09"},
    "runs_present": True,
    "status": {"by_data_quality": {"INCOMPLETE": 1, "OBSERVING": 7}},
}


def jsonl(*objects):
    return b"".join(canonical(o) + b"\n" for o in objects)


class Sandbox:
    """mktemp fixture tree: runs root, ledger, delivery. Every file is
    canonical-JSON synthetic bytes; nothing here is real data."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="hs-api-contract-")
        self.runs = os.path.join(self.root, "runs")
        self.ledger = os.path.join(self.root, "ledger.hcj.jsonl")
        self.delivery = os.path.join(self.root, "delivery.hcj.jsonl")
        os.makedirs(self.runs)

    def session_dir(self, name):
        path = os.path.join(self.runs, name)
        os.makedirs(path, exist_ok=True)
        return path

    def write(self, path, data):
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    def write_session_files(self, name, with_session_end, with_marker):
        run_dir = self.session_dir(name)
        self.write(os.path.join(run_dir, "input.hcj.jsonl"),
                   jsonl(*(INPUT_A if with_session_end else INPUT_B)))
        self.write(os.path.join(run_dir, "bars.hcj.jsonl"),
                   canonical(BARS_LINE) + b"\n")
        self.write(os.path.join(run_dir, "signals.hcj.jsonl"),
                   canonical(SIGNALS_LINE) + b"\n")
        self.write(os.path.join(run_dir, "events.hcj.jsonl"),
                   canonical(EV2) + b"\n")
        return run_dir

    def write_checksums(self, run_dir, names):
        lines = []
        for name in names:
            with open(os.path.join(run_dir, name), "rb") as f:
                lines.append("%s  %s\n" % (sha(f.read()), name))
        self.write(os.path.join(run_dir, "CHECKSUMS.sha256"),
                   "".join(lines).encode("utf-8"))

    def cleanup(self):
        shutil.rmtree(self.root)


def build_main_sandbox():
    """The fixture contract of the main suite: four recorded sessions
    covering every projection branch, plus a 4-event ledger and a
    4-record delivery ledger."""
    box = Sandbox()

    # dir-20261031-plain: a bare run directory, no run.json, no
    # artifacts beyond one file — every absence branch of verification.
    box.write_session_files("dir-20261031-plain", with_session_end=False,
                            with_marker=False)
    os.remove(os.path.join(box.runs, "dir-20261031-plain",
                           "input.hcj.jsonl"))
    os.remove(os.path.join(box.runs, "dir-20261031-plain",
                           "signals.hcj.jsonl"))
    os.remove(os.path.join(box.runs, "dir-20261031-plain",
                           "events.hcj.jsonl"))

    # run-20261101-a: complete committed session, all checksums match,
    # session_end recorded, plus planted never-to-serve values.
    run_a = box.write_session_files("run-20261101-a", with_session_end=True,
                                    with_marker=False)
    box.write(os.path.join(run_a, "run.json"),
              canonical(RUN_JSON_A) + b"\n")
    box.write(os.path.join(run_a, "input.hcj.jsonl.committed"),
              canonical({"run_id": "run-a", "schema":
                         "hong-scanner-commit/1", "seq": 5,
                         "sha256": sha(b"input-a"),
                         "t": "2026-11-01T08:00:00+09:00"}) + b"\n")
    box.write_checksums(run_a, ["input.hcj.jsonl", "bars.hcj.jsonl",
                                "events.hcj.jsonl", "signals.hcj.jsonl"])
    box.write(os.path.join(run_a, "secret.txt"), (SECRET + "\n").encode())

    # run-20261101-b: checksums recorded, then bars.tcl tampered — the
    # recorded hash can no longer be confirmed. No committed marker, no
    # session_end: the session is recorded but incomplete.
    run_b = box.write_session_files("run-20261101-b", with_session_end=False,
                                    with_marker=False)
    box.write(os.path.join(run_b, "run.json"),
              canonical(RUN_JSON_B) + b"\n")
    box.write_checksums(run_b, ["input.hcj.jsonl", "bars.hcj.jsonl",
                                "events.hcj.jsonl", "signals.hcj.jsonl"])
    with open(os.path.join(run_b, "bars.hcj.jsonl"), "ab") as f:
        f.write(b"x")  # tampered after the checksum was recorded

    # run-20261102-c: operator-recorded verify output, no CHECKSUMS.
    run_c = box.session_dir("run-20261102-c")
    box.write(os.path.join(run_c, "run.json"),
              canonical(RUN_JSON_C) + b"\n")
    box.write(os.path.join(run_c, "verify.stdout"),
              ("VERDICT MATCH provenance=OK\n"
               "COMMIT=VALID\n"
               "EVENTS=%s\n" % sha(b"events-c")).encode("utf-8"))
    box.write(os.path.join(run_c, "events.hcj.jsonl"),
              canonical(EV2) + b"\n")

    box.write(box.ledger, jsonl(EV1, EV2, EV3, EV4))
    box.write(box.delivery, jsonl(D1, D2, D3, D4))
    return box


def build_market_view_sandbox():
    """The §3.7 fixture tree: the winning eligible run (multi-generation
    fold scenario, run_id recorded), an older same-date eligible run
    whose dirname sorts AFTER the winner (the observed_at tie-break must
    beat the dirname tie-break), an older-date eligible run with a NEWER
    last observed_at (session_date outranks observed_at), and the
    ineligible shapes: config without environment (smoke-like), config
    with a malformed session_date, and a directory holding only a
    subdirectory (drill-like)."""
    box = Sandbox()

    def write_market_run(name, config, events, input_extra=()):
        run_dir = box.session_dir(name)
        box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
            {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
            {"kind": "config", "raw": config, "seq": 2},
            *input_extra))
        box.write(os.path.join(run_dir, "events.hcj.jsonl"), jsonl(*events))

    write_market_run(MV_WINNER,
                     {"environment": "demo", "run_id": MV_WINNER,
                      "session_date": "2026-11-09"},
                     MV_WINNER_EVENTS, MV_WINNER_INPUT)
    write_market_run("market-2026-11-09-z",
                     {"environment": "demo", "session_date": "2026-11-09"},
                     [event_fact(b"mv-old-same", "CANDIDATE_ENTERED",
                                 "2026-11-09",
                                 "2026-11-09T09:00:00+09:00",
                                 "candidate-transition-v1",
                                 direction="UP", rank=1, symbol="005930")])
    write_market_run("market-2026-11-08-y",
                     {"environment": "demo", "run_id": "market-2026-11-08-y",
                      "session_date": "2026-11-08"},
                     [event_fact(b"mv-old-date", "CANDIDATE_ENTERED",
                                 "2026-11-08",
                                 "2026-11-09T23:59:00+09:00",
                                 "candidate-transition-v1",
                                 direction="UP", rank=1, symbol="005930")])
    # smoke-like: both files present, but the config record carries no
    # environment — the collector-only field — so it is ineligible
    write_market_run("smoke-like-2026-11-09",
                     {"page_cap": 10, "session_date": "2026-11-09"},
                     [MV_DOWN_ENTERED_1])
    # eligible files and environment, but session_date is not the
    # collector's own validation shape
    write_market_run("bad-date-like",
                     {"environment": "demo", "session_date": "2026-11-9"},
                     [MV_DOWN_ENTERED_1])
    # drill-like: only a subdirectory, no recorded files at all
    os.makedirs(os.path.join(box.runs, "drill-like-20261109", "sub"))
    return box


class ServerProc:
    """One serve.py subprocess on an ephemeral port. The SERVE line is
    the only startup evidence the suite accepts, and it must name the
    address the server was asked to bind."""

    def __init__(self, box, with_delivery=True, bind=None):
        host = bind if bind is not None else "127.0.0.1"
        args = [PY, SERVE, "--runs", box.runs, "--ledger", box.ledger,
                "--port", "0"]
        if with_delivery:
            args += ["--delivery", box.delivery]
        if bind is not None:
            args += ["--bind", bind]
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        ready = select.select([self.proc.stdout], [], [], 20)[0]
        if not ready:
            self.proc.kill()
            out, err = self.proc.communicate(timeout=10)
            raise AssertionError("serve.py did not print SERVE in 20s: "
                                 "stdout=%r stderr=%r" % (out, err))
        line = self.proc.stdout.readline().decode("utf-8").strip()
        if not line.startswith("SERVE %s:" % host):
            raise AssertionError("unexpected serve line: %r" % line)
        self.bind = host
        self.port = int(line.split(":")[1])
        self.base = "http://%s:%d" % (host, self.port)

    def get(self, path, method="GET"):
        req = urlrequest.Request(self.base + path, method=method)
        try:
            with urlrequest.urlopen(req, timeout=10) as resp:
                return resp.status, resp.read(), dict(resp.headers)
        except HTTPError as err:
            return err.code, err.read(), dict(err.headers)

    def get_json(self, path):
        status, body, headers = self.get(path)
        return status, json.loads(body.decode("utf-8")), body, headers

    def stop(self):
        """SIGTERM, then reap. Returns (returncode, stderr). The suite
        asserts exit code 0 and no residue."""
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
        out, err = self.proc.communicate(timeout=15)
        return self.proc.returncode, err.decode("utf-8", "replace")

    def assert_gone(self):
        assert self.proc.poll() is not None, \
            "serve.py process survived SIGTERM"
        with socket.socket() as probe:
            try:
                probe.connect((self.bind, self.port))
            except ConnectionRefusedError:
                return
            raise AssertionError("port %d still accepting: residue" %
                                 self.port)


class ApiContractSuite(unittest.TestCase):
    """Endpoint contract against the main fixture sandbox."""

    def setUp(self):
        self.box = build_main_sandbox()
        self.addCleanup(self.box.cleanup)
        self.server = ServerProc(self.box)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        self.server.assert_gone()

    # -- startup evidence --------------------------------------------------

    def test_serve_line_binds_loopback_ephemeral(self):
        self.assertGreater(self.server.port, 0)
        self.assertLess(self.server.port, 65536)
        status, _, body, headers = self.server.get_json("/status")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")
        self.assertTrue(body.endswith(b"\n"))

    # -- /status -----------------------------------------------------------

    def test_status_projects_recorded_summary(self):
        status, body, _, _ = self.server.get_json("/status")
        self.assertEqual(status, 200)
        self.assertEqual(body["sessions"]["count"], 4)
        latest = body["sessions"]["latest"]
        self.assertEqual(latest["session"], "run-20261102-c")
        self.assertEqual(latest["session_date"], "2026-10-31")
        self.assertEqual(latest["code_commit"], COMMIT_C)
        self.assertTrue(latest["run_json_present"])
        events = body["events"]
        self.assertTrue(events["ledger_present"])
        self.assertEqual(events["count"], 4)
        self.assertEqual(events["by_type"], {
            "CANDIDATE_ENTERED": 2, "CANDIDATE_EXITED": 1,
            "SESSION_ENDED": 1})
        self.assertEqual(events["by_severity"], {"HIGH": 1, "INFO": 3})
        self.assertEqual(events["latest_session_id"], "2026-10-30")
        self.assertEqual(events["latest_event"]["event_id"],
                         EV4["event_id"])
        delivery = body["delivery"]
        self.assertTrue(delivery["configured"])
        self.assertTrue(delivery["present"])
        self.assertEqual(delivery["by_state"],
                         {"ACCEPTED": 1, "FAILED": 1, "PENDING": 1})
        self.assertEqual(delivery["pairs"], 3)
        self.assertEqual(delivery["devices"], 2)

    # -- /candidates ---------------------------------------------------------

    def test_candidates_latest_session_byte_canonical(self):
        expected = {"count": 2, "events": [EV3, EV4],
                    "ledger_present": True, "session_id": "2026-10-30"}
        status, body, raw, headers = self.server.get_json("/candidates")
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        self.assertEqual(body["events"][0]["symbol"], "000660")
        self.assertTrue(all(e["event_type"].startswith("CANDIDATE_")
                            for e in body["events"]))
        self.assertNotIn(EV1["event_id"],
                         [e["event_id"] for e in body["events"]])
        self.assertNotIn(EV2["event_id"],
                         [e["event_id"] for e in body["events"]])
        # the whole body is canonical bytes: keys sorted, LF-terminated
        self.assertEqual(raw, canonical(expected) + b"\n")
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")

    # -- /events -------------------------------------------------------------

    def test_events_join_delivery_last_record_wins(self):
        status, body, _, _ = self.server.get_json("/events")
        self.assertEqual(status, 200)
        self.assertTrue(body["ledger_present"])
        self.assertEqual(body["count"], 4)
        self.assertEqual(body["events"], [EV1, EV2, EV3, EV4])
        self.assertEqual(sorted(body["delivery"]),
                         sorted([EV1["event_id"], EV3["event_id"],
                                 EV4["event_id"]]))
        self.assertEqual(body["delivery"][EV1["event_id"]], [{
            "attempts": 1, "device_id": "dev-1",
            "provider_message_id": "projects/drill-project/messages/m-1",
            "state": "ACCEPTED",
            "updated_at": "2026-11-01T09:01:00+09:00"}])
        self.assertEqual(body["delivery"][EV3["event_id"]], [{
            "attempts": 2, "device_id": "dev-1",
            "error_code": "UNREGISTERED", "state": "FAILED",
            "updated_at": "2026-11-01T09:02:00+09:00"}])
        self.assertEqual(body["delivery"][EV4["event_id"]], [{
            "attempts": 0, "device_id": "dev-2", "state": "PENDING",
            "updated_at": "2026-11-01T09:02:00+09:00"}])

    def test_events_session_filter_exact_match(self):
        status, body, _, _ = self.server.get_json(
            "/events?session_id=2026-10-29")
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 2)
        self.assertEqual(body["events"], [EV1, EV2])
        self.assertEqual(sorted(body["delivery"]), [EV1["event_id"]])
        status, body, _, _ = self.server.get_json(
            "/events?session_id=1999-01-01")
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 0)
        self.assertEqual(body["events"], [])
        self.assertEqual(body["delivery"], {})

    # -- present-but-empty ledger (README §3.1: the writer's O_CREAT
    # opens the file before the first record — a real day-one state) ---

    def truncate_event_ledger(self):
        # Zero committed records in an EXISTING file: the notify worker
        # opens the event ledger with O_CREAT when the session starts,
        # so "file present, nothing recorded yet" is an operational
        # state the projection must survive, never a 500.
        with open(self.box.ledger, "wb"):
            pass

    def test_status_empty_ledger_projects_zero_count(self):
        self.truncate_event_ledger()
        status, body, _, _ = self.server.get_json("/status")
        self.assertEqual(status, 200)
        events = body["events"]
        self.assertTrue(events["ledger_present"])
        self.assertEqual(events["count"], 0)
        self.assertEqual(events["by_type"], {})
        self.assertEqual(events["by_severity"], {})
        self.assertIsNone(events["latest_session_id"])
        self.assertIsNone(events["latest_event"])
        # run directories are independent of the ledger state
        self.assertEqual(body["sessions"]["count"], 4)

    def test_candidates_empty_ledger_has_no_latest_session(self):
        self.truncate_event_ledger()
        status, body, _, _ = self.server.get_json("/candidates")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"ledger_present": True,
                                "session_id": None,
                                "count": 0, "events": []})

    def test_events_empty_ledger_lists_nothing(self):
        self.truncate_event_ledger()
        status, body, _, _ = self.server.get_json("/events")
        self.assertEqual(status, 200)
        self.assertTrue(body["ledger_present"])
        self.assertEqual(body["count"], 0)
        self.assertEqual(body["events"], [])
        self.assertEqual(body["delivery"], {})

    # -- /events/{id} --------------------------------------------------------

    def test_event_detail_with_and_without_delivery(self):
        status, body, _, _ = self.server.get_json("/events/" + EV1["event_id"])
        self.assertEqual(status, 200)
        self.assertEqual(body["event"], EV1)
        self.assertEqual(len(body["delivery"]), 1)
        self.assertEqual(body["delivery"][0]["state"], "ACCEPTED")
        status, body, _, _ = self.server.get_json("/events/" + EV2["event_id"])
        self.assertEqual(status, 200)
        self.assertEqual(body["event"], EV2)
        self.assertEqual(body["delivery"], [])

    def test_event_unknown_and_malformed_ids_404(self):
        unknown = sha(b"no-such-event")
        for path in ("/events/" + unknown,      # valid hex, not recorded
                     "/events/zzz",              # not hex
                     "/events/" + EV1["event_id"] + "/",   # trailing slash
                     "/events/..",               # traversal
                     "/events/%2e%2e",           # encoded traversal
                     "/events/a%2fb",            # encoded separator
                     "/events/" + "x" * 64,      # wrong alphabet
                     "/events/" + EV1["event_id"] + "%20"):  # trailing space
            status, _, body, _ = self.server.get_json(path)
            self.assertEqual(status, 404, path)
            self.assertIn(b"not_found", body)
            self.assertNotIn(SECRET.encode(), body)
            self.assertNotIn(self.box.root.encode(), body)

    # -- /sessions -----------------------------------------------------------

    def test_sessions_lists_run_directories_with_whitelist(self):
        status, body, _, _ = self.server.get_json("/sessions")
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 4)
        names = [s["session"] for s in body["sessions"]]
        self.assertEqual(names, ["dir-20261031-plain", "run-20261101-a",
                                 "run-20261101-b", "run-20261102-c"])
        plain = body["sessions"][0]
        self.assertFalse(plain["run_json_present"])
        for field in ("session_date", "run_id", "started_at",
                      "code_commit"):
            self.assertIsNone(plain[field], field)
        a = body["sessions"][1]
        self.assertEqual(a["session_date"], "2026-10-29")
        self.assertEqual(a["run_id"], "run-a")
        self.assertEqual(a["started_at"], "2026-11-01T08:00:00+09:00")
        self.assertEqual(a["code_commit"], COMMIT_A)

    # -- /sessions/{id}/verification ------------------------------------------

    def test_verification_complete_session(self):
        status, body, raw, _ = self.server.get_json(
            "/sessions/run-20261101-a/verification")
        self.assertEqual(status, 200)
        self.assertEqual(body["session"], "run-20261101-a")
        self.assertTrue(body["run_json_present"])
        self.assertEqual(body["session_date"], "2026-10-29")
        self.assertEqual(body["code_commit"], COMMIT_A)
        self.assertTrue(body["committed_marker"]["present"])
        self.assertEqual(body["committed_marker"]["file"],
                         "input.hcj.jsonl.committed")
        self.assertTrue(body["session_end_recorded"])
        with open(os.path.join(self.box.runs, "run-20261101-a",
                               "events.hcj.jsonl"), "rb") as f:
            self.assertEqual(body["events_file"],
                             {"present": True, "sha256": sha(f.read())})
        checksums = body["checksums"]
        self.assertTrue(checksums["present"])
        self.assertEqual([a["file"] for a in checksums["artifacts"]],
                         ["input.hcj.jsonl", "bars.hcj.jsonl",
                          "events.hcj.jsonl", "signals.hcj.jsonl"])
        self.assertTrue(all(a["match"] for a in checksums["artifacts"]))
        self.assertTrue(all(a["computed_sha256"] == a["recorded_sha256"]
                            for a in checksums["artifacts"]))
        self.assertEqual(body["replay_verdict"], {"recorded": False})
        self.assertTrue(raw.endswith(b"\n"))

    def test_verification_checksum_mismatch_and_incomplete(self):
        status, body, _, _ = self.server.get_json(
            "/sessions/run-20261101-b/verification")
        self.assertEqual(status, 200)
        self.assertFalse(body["committed_marker"]["present"])
        self.assertFalse(body["session_end_recorded"])
        self.assertTrue(body["run_json_present"])
        self.assertEqual(body["session_date"], "2026-10-30")
        self.assertEqual(body["code_commit"], COMMIT_B)
        artifacts = {a["file"]: a for a in body["checksums"]["artifacts"]}
        self.assertFalse(artifacts["bars.hcj.jsonl"]["match"])
        self.assertNotEqual(artifacts["bars.hcj.jsonl"]["computed_sha256"],
                            artifacts["bars.hcj.jsonl"]["recorded_sha256"])
        self.assertTrue(artifacts["input.hcj.jsonl"]["match"])
        self.assertTrue(artifacts["events.hcj.jsonl"]["match"])
        self.assertEqual(body["replay_verdict"], {"recorded": False})

    def test_verification_quotes_recorded_verdict_only(self):
        status, body, _, _ = self.server.get_json(
            "/sessions/run-20261102-c/verification")
        self.assertEqual(status, 200)
        self.assertEqual(body["replay_verdict"],
                         {"recorded": True, "source": "verify.stdout",
                          "line": "VERDICT MATCH provenance=OK"})
        self.assertFalse(body["checksums"]["present"])
        self.assertEqual(body["checksums"]["artifacts"], [])
        self.assertTrue(body["events_file"]["present"])
        self.assertEqual(body["code_commit"], COMMIT_C)

    def test_verification_all_absent_is_served_honestly(self):
        status, body, _, _ = self.server.get_json(
            "/sessions/dir-20261031-plain/verification")
        self.assertEqual(status, 200)
        self.assertFalse(body["run_json_present"])
        self.assertIsNone(body["session_date"])
        self.assertIsNone(body["code_commit"])
        self.assertFalse(body["committed_marker"]["present"])
        self.assertFalse(body["session_end_recorded"])
        self.assertEqual(body["events_file"], {"present": False,
                                               "sha256": None})
        self.assertFalse(body["checksums"]["present"])
        self.assertEqual(body["checksums"]["artifacts"], [])
        self.assertEqual(body["replay_verdict"], {"recorded": False})

    def test_verification_traversal_and_unknown_sessions_404(self):
        for path in ("/sessions/nosuch-session/verification",
                     "/sessions/./verification",
                     "/sessions/../verification",
                     "/sessions/..%2fverification",
                     "/sessions/run-20261101-a%2f..%2f..%2fsecret"
                     "/verification",
                     "/sessions/run-20261101-a..ok/verification",
                     "/sessions/run-20261101-a/verification/x",
                     "/sessions/run-20261101-a",
                     "/sessions//verification"):
            status, _, body, _ = self.server.get_json(path)
            self.assertEqual(status, 404, path)
            self.assertNotIn(SECRET.encode(), body)
            self.assertNotIn(self.box.root.encode(), body)

    def test_verification_safe_name_guard_in_recorded_checksums(self):
        # a recorded checksum naming an unsafe artifact is refused
        # without opening it, not followed
        run_dir = self.box.session_dir("run-guard-fixture")
        self.box.write(os.path.join(run_dir, "CHECKSUMS.sha256"),
                       ("%s  ../secret.txt\n" % sha(b"x")).encode())
        status, body, _, _ = self.server.get_json(
            "/sessions/run-guard-fixture/verification")
        self.assertEqual(status, 200)
        artifacts = body["checksums"]["artifacts"]
        self.assertEqual(len(artifacts), 1)
        self.assertEqual(artifacts[0]["file"], "../secret.txt")
        self.assertFalse(artifacts[0]["match"])
        self.assertIsNone(artifacts[0]["computed_sha256"])
        self.assertIn("refused", artifacts[0]["note"])

    # -- method and path guards ------------------------------------------------

    def test_only_get_is_allowed(self):
        for method, path in (("POST", "/events"), ("PUT", "/status"),
                             ("DELETE", "/sessions"),
                             ("PATCH", "/candidates"),
                             ("HEAD", "/status"), ("OPTIONS", "/events")):
            status, body, headers = self.server.get(path, method=method)
            self.assertEqual(status, 405, (method, path))
            self.assertEqual(headers.get("Allow"), "GET")
            if method != "HEAD":
                # HEAD responses carry no body by HTTP semantics
                self.assertIn(b"method_not_allowed", body)
                self.assertNotIn(SECRET.encode(), body)

    def test_unknown_paths_are_json_404(self):
        for path in ("/", "/api/status", "/events/", "/status/",
                     "/status?x=1", "/sessions/", "/candidates/x",
                     "/verification", "/favicon.ico"):
            status, body, headers = self.server.get(path)
            expected = 200 if path == "/status?x=1" else 404
            self.assertEqual(status, expected, path)
            self.assertEqual(headers["Content-Type"],
                             "application/json; charset=utf-8")
            self.assertTrue(body.endswith(b"\n"), path)
            if expected == 404:
                self.assertNotIn(path.encode(), body)  # no reflection

    # -- honesty of the projection ----------------------------------------------

    def test_no_secrets_or_filesystem_paths_in_any_body(self):
        paths = ("/status", "/candidates", "/events",
                 "/events/" + EV1["event_id"], "/sessions",
                 "/sessions/run-20261101-a/verification",
                 "/sessions/run-20261101-b/verification",
                 "/sessions/run-20261102-c/verification",
                 "/sessions/dir-20261031-plain/verification",
                 "/mobile/market-view")
        bodies = b""
        for path in paths:
            _, body, _ = self.server.get(path)
            bodies += body
        for needle in (SECRET.encode(), HIDDEN_HOST.encode(),
                       HIDDEN_EGRESS.encode(), str(HIDDEN_PID).encode(),
                       self.box.root.encode(), b"secret.txt\x00",
                       b"/home/", b"password"):
            self.assertNotIn(needle, bodies, needle)


class MarketViewSuite(unittest.TestCase):
    """GET /mobile/market-view (README §3.7): the bounded fold
    projection of the latest eligible market-collection run — recorded
    facts only, ranks from the ledger, no judgment."""

    def setUp(self):
        self.box = build_market_view_sandbox()
        self.addCleanup(self.box.cleanup)
        self.server = ServerProc(self.box, with_delivery=False)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        self.server.assert_gone()

    def test_market_view_full_scenario_byte_canonical(self):
        # selection: session_date max beats the newer observed_at of the
        # 2026-11-08 run; the observed_at tie-break beats the winner's
        # smaller dirname; smoke/bad-date/drill dirs are ineligible
        status, body, raw, headers = self.server.get_json(
            "/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, MV_EXPECTED)
        # the whole body is canonical bytes: keys sorted, LF-terminated
        self.assertEqual(raw, canonical(MV_EXPECTED) + b"\n")
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")
        # the contract's mechanical size bound (README §3.7)
        self.assertLessEqual(len(raw), 65536)

    def test_market_view_history_exited_rank_is_null(self):
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        exited = [item for item in body["history"]
                  if item["event_type"] == "CANDIDATE_EXITED"]
        self.assertEqual(len(exited), 1)
        self.assertIsNone(exited[0]["rank"])  # honest absence, never 0
        self.assertEqual(exited[0]["symbol"], "006660")
        self.assertEqual(exited[0]["direction"], "UP")
        self.assertTrue(all(item["rank"] is not None
                            for item in body["history"]
                            if item["event_type"] != "CANDIDATE_EXITED"))

    # -- §3.7 name dictionary ----------------------------------------------

    def test_market_view_name_projection(self):
        # names come from the recorded ka10027 bodies of the selected
        # run only: latest record wins (006660 was renamed mid-run), an
        # error body without the ranking list contributes nothing, and
        # a ka10080 record is never a name source
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        names = {item["symbol"]: item["name"]
                 for item in body["rising_top10"] + body["falling_top10"]}
        self.assertEqual(names["005930"], "삼성전자")
        self.assertEqual(names["006660"], "LG전자")  # supersedes 구형이름
        self.assertNotIn("구형이름", json.dumps(body, ensure_ascii=False))
        history_names = {item["symbol"]: item["name"]
                         for item in body["history"]}
        self.assertEqual(history_names["005930"], "삼성전자")
        self.assertEqual(history_names["006660"], "LG전자")
        # the map entry for a symbol with no event is never projected
        self.assertNotIn("179530", history_names)

    def test_market_view_name_null_when_not_recorded(self):
        # 000660 appears in events but no recorded ka10027 body ever
        # names it: name stays null (honest absence — the app falls
        # back to the symbol), never "" or the symbol itself
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(body["falling_top10"][0]["symbol"], "000660")
        self.assertIsNone(body["falling_top10"][0]["name"])
        unnamed = [item for item in body["history"]
                   if item["symbol"] == "000660"]
        self.assertTrue(unnamed)
        self.assertTrue(all(item["name"] is None for item in unnamed))

    def test_market_view_input_torn_tail_not_folded(self):
        # a torn (non-LF) ka10027 tail naming 000660 is not committed:
        # folding it would flip the name null — the response stays the
        # committed one exactly
        torn = canonical(rest_resp_record(
            8, ka10027_body([("000660", "SK하이닉스")])))
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(torn[: len(torn) // 2])
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, MV_EXPECTED)

    def test_market_view_malformed_input_line_is_data_fault(self):
        # a committed but malformed input line is corruption, not a
        # skip — the name fold reads the same committed-lines rule
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(b"{not json}\n")
        status, _, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)

    def test_market_view_name_envelope_violation_is_data_fault(self):
        # body_hex is an envelope field the recorder itself guarantees
        # (hex): a committed record violating it is corruption
        record = rest_resp_record(8, ka10027_body([("000660", "SK하이닉스")]))
        record["raw"]["body_hex"] = "zz" + record["raw"]["body_hex"][2:]
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(canonical(record) + b"\n")
        status, _, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)

    def test_market_view_name_row_violation_is_data_fault(self):
        # a ranking row missing stk_nm violates the fold's dependent
        # recorded shape — same discipline as a candidate event
        # without rank
        record = rest_resp_record(8, {
            "pred_pre_flu_rt_upper": [{"stk_cd": "000660"}],
            "return_code": 0, "return_msg": "row without a name"})
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(canonical(record) + b"\n")
        status, _, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)

    def test_market_view_name_rescan_on_file_change(self):
        # the memoization key is (path, size, mtime_ns): appending a
        # committed ka10027 record changes the file, so the next
        # request — same server, no restart — rescans and serves the
        # newly recorded name; the request after that is stable
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertIsNone(body["falling_top10"][0]["name"])
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(canonical(rest_resp_record(
                8, ka10027_body([("000660", "SK하이닉스")]))) + b"\n")
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body["falling_top10"][0]["symbol"], "000660")
        self.assertEqual(body["falling_top10"][0]["name"], "SK하이닉스")
        status2, body2, raw2, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status2, 200)
        self.assertEqual(body2, body)
        self.assertEqual(raw2, self.server.get("/mobile/market-view")[1])

    def test_market_view_torn_tail_is_not_committed(self):
        # the concurrently-appending shape: a torn (non-LF) tail record
        # is not folded, not in history, and not the selection's last
        # observed_at — the response is exactly the committed one
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "events.hcj.jsonl"), "ab") as f:
            f.write(canonical(MV_DOWN_ENTERED_1)[:24])
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, MV_EXPECTED)

    def test_market_view_malformed_committed_line_is_data_fault(self):
        # a committed but malformed last line is corruption, not a skip
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "events.hcj.jsonl"), "ab") as f:
            f.write(b"{not json}\n")
        status, _, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)

    def test_market_view_exact_path_only(self):
        for path in ("/mobile", "/mobile/market-view/",
                     "/mobile/market-view/x"):
            status, _, body, _ = self.server.get_json(path)
            self.assertEqual(status, 404, path)
            self.assertIn(b"not_found", body)


class MarketViewEmptySuite(unittest.TestCase):
    """§3.7 empty states: a runs root with no directories, directories
    but none eligible, and a selected run with zero committed events."""

    def run_with(self, box):
        self.addCleanup(box.cleanup)
        self.server = ServerProc(box, with_delivery=False)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0)
        self.server.assert_gone()

    def test_no_directories_projects_absent(self):
        box = Sandbox()
        self.run_with(box)
        expected = {"as_of": None, "falling_top10": [], "history": [],
                    "latest": None, "rising_top10": [], "run": None,
                    "runs_present": False, "status": None}
        status, body, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        self.assertEqual(raw, canonical(expected) + b"\n")

    def test_directories_but_none_eligible(self):
        box = Sandbox()
        run_dir = box.session_dir("smoke-like-2026-11-09")
        box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
            {"kind": "calendar", "raw": {}, "seq": 1},
            {"kind": "config", "raw": {"session_date": "2026-11-09"},
             "seq": 2}))
        box.write(os.path.join(run_dir, "events.hcj.jsonl"),
                  jsonl(MV_DOWN_ENTERED_1))
        os.makedirs(os.path.join(box.runs, "drill-like", "sub"))
        self.run_with(box)
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"as_of": None, "falling_top10": [],
                                "history": [], "latest": None,
                                "rising_top10": [], "run": None,
                                "runs_present": True, "status": None})

    def test_selected_run_zero_committed_events(self):
        box = Sandbox()
        run_dir = box.session_dir("market-2026-11-09-empty")
        box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
            {"kind": "calendar", "raw": {}, "seq": 1},
            {"kind": "config", "raw": {"environment": "demo",
                                       "session_date": "2026-11-09"},
             "seq": 2}))
        box.write(os.path.join(run_dir, "events.hcj.jsonl"), b"")
        self.run_with(box)
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, {
            "as_of": None, "falling_top10": [], "history": [],
            "latest": None, "rising_top10": [],
            "run": {"environment": "demo", "run_id": None,
                    "session": "market-2026-11-09-empty",
                    "session_date": "2026-11-09"},
            "runs_present": True,
            "status": {"by_data_quality": {}}})


class MarketNameFoldSuite(unittest.TestCase):
    """Unit contract of the §3.7 name dictionary: fold_market_names
    (pure function over recorded bytes) and the Projector's
    (path, size, mtime_ns) memoization. These are function- and
    cache-behavior facts the endpoint bytes cannot observe directly
    (a rescan is byte-identical to a hit); endpoint projection stays
    black-box in MarketViewSuite."""

    def setUp(self):
        self.box = Sandbox()
        self.addCleanup(self.box.cleanup)
        self.runs = self.box.runs

    def write_input(self, *records, torn=b""):
        run_dir = self.box.session_dir("market-2026-11-09-n")
        self.box.write(os.path.join(run_dir, "input.hcj.jsonl"),
                       jsonl(*records) + torn)
        return os.path.join(run_dir, "input.hcj.jsonl")

    def test_fold_latest_wins_and_skips(self):
        path = self.write_input(
            {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
            rest_resp_record(2, MV_ERROR_BODY, status=429),
            rest_resp_record(3, ka10027_body([("005930", "삼성전자"),
                                              ("006660", "구형이름")])),
            rest_resp_record(4, MV_KA10080_BODY, api_id="ka10080"),
            rest_resp_record(5, ka10027_body([("006660", "LG전자")]),
                             page=2),
            {"kind": "ws_frame", "raw": {"price": 1}, "seq": 6},
            # a non-object body: recorded verbatim, no ranking to fold
            rest_resp_record(7, {"body": "not-a-ranking"}),
            torn=canonical(rest_resp_record(
                8, ka10027_body([("000660", "SK하이닉스")])))
                [:40])  # torn tail: not committed, never folded
        self.assertEqual(serve.fold_market_names(path),
                         {"005930": "삼성전자", "006660": "LG전자"})

    def test_fold_absent_and_empty_input(self):
        self.assertEqual(serve.fold_market_names(
            os.path.join(self.runs, "no-such-run", "input.hcj.jsonl")), {})
        path = self.write_input()
        self.assertEqual(serve.fold_market_names(path), {})

    def test_fold_non_json_body_contributes_nothing(self):
        # error bodies preserved verbatim (text, empty) are legitimately
        # recorded and carry no ranking: absence, never a fault
        raw_body = {"kind": "rest_resp",
                    "raw": {"api_id": "ka10027",
                            "body_hex": b"Bad Gateway".hex(),
                            "cont_yn": "", "next_key": "", "page": 1,
                            "query": dict(MV_KA10027_QUERY),
                            "status": 502}, "seq": 4}
        path = self.write_input(
            rest_resp_record(2, "plain 429 text", status=429),
            rest_resp_record(3, {"return_code": 5}, status=429),
            raw_body)
        self.assertEqual(serve.fold_market_names(path), {})

    def test_fold_malformed_committed_line_is_data_fault(self):
        path = self.write_input(
            rest_resp_record(2, ka10027_body([("005930", "삼성전자")])))
        with open(path, "ab") as f:
            f.write(b"{not json}\n")
        with self.assertRaises(serve.DataFault):
            serve.fold_market_names(path)

    def test_fold_envelope_violations_are_data_fault(self):
        bad_raw = rest_resp_record(2, ka10027_body([("005930", "삼성전자")]))
        bad_raw["raw"] = "not-an-object"
        bad_api = rest_resp_record(2, ka10027_body([("005930", "삼성전자")]))
        bad_api["raw"]["api_id"] = 10027
        bad_hex = rest_resp_record(2, ka10027_body([("005930", "삼성전자")]))
        bad_hex["raw"]["body_hex"] = "zz"
        no_hex = rest_resp_record(2, ka10027_body([("005930", "삼성전자")]))
        del no_hex["raw"]["body_hex"]
        for label, record in (("raw", bad_raw), ("api_id", bad_api),
                              ("hex", bad_hex), ("no body_hex", no_hex)):
            path = self.write_input(record)
            with self.assertRaises(serve.DataFault, msg=label):
                serve.fold_market_names(path)

    def test_fold_row_violation_is_data_fault(self):
        for label, rows in (("row not object", ["005930"]),
                            ("no stk_nm", [{"stk_cd": "005930"}]),
                            ("no stk_cd", [{"stk_nm": "삼성전자"}]),
                            ("non-string", [{"stk_cd": 59530,
                                             "stk_nm": "삼성전자"}])):
            path = self.write_input(rest_resp_record(2, {
                "pred_pre_flu_rt_upper": rows,
                "return_code": 0, "return_msg": label}))
            with self.assertRaises(serve.DataFault, msg=label):
                serve.fold_market_names(path)

    def test_names_cache_hit_and_invalidation(self):
        # same (path, size, mtime_ns) -> no rescan; a committed append
        # changes the stat -> rescan serves the new recorded name
        path = self.write_input(
            rest_resp_record(2, ka10027_body([("005930", "삼성전자")])))
        projector = serve.Projector(self.runs, self.box.ledger)
        calls = []
        real_fold = serve.fold_market_names

        def counting_fold(p):
            calls.append(p)
            return real_fold(p)
        serve.fold_market_names = counting_fold
        self.addCleanup(setattr, serve, "fold_market_names", real_fold)
        first = projector._market_names(path)
        self.assertEqual(first, {"005930": "삼성전자"})
        self.assertEqual(len(calls), 1)
        # identical stat: served from the cache, fold not re-entered
        self.assertEqual(projector._market_names(path), first)
        self.assertEqual(len(calls), 1)
        # a committed append changes size: rescan, new name served
        with open(path, "ab") as f:
            f.write(canonical(rest_resp_record(
                3, ka10027_body([("006660", "LG전자")]))) + b"\n")
        second = projector._market_names(path)
        self.assertEqual(second, {"005930": "삼성전자", "006660": "LG전자"})
        self.assertEqual(len(calls), 2)

    def test_names_cache_not_published_for_absent_file(self):
        # a vanished input folds to {} and publishes nothing: a later
        # re-created file must be scanned, not served stale
        path = self.write_input(
            rest_resp_record(2, ka10027_body([("005930", "삼성전자")])))
        projector = serve.Projector(self.runs, self.box.ledger)
        self.assertEqual(projector._market_names(path),
                         {"005930": "삼성전자"})
        os.remove(path)
        self.assertEqual(projector._market_names(path), {})
        self.write_input(rest_resp_record(
            2, ka10027_body([("006660", "LG전자")])))
        self.assertEqual(projector._market_names(path),
                         {"006660": "LG전자"})


class TornLedgerSuite(unittest.TestCase):
    """A ledger being appended concurrently: committed records are
    served, the non-LF-terminated tail is skipped, and delivery
    without --delivery is reported unconfigured."""

    def setUp(self):
        self.box = Sandbox()
        self.addCleanup(self.box.cleanup)
        committed = jsonl(EV1, EV2)
        torn = canonical(EV3)[:20]  # a torn record: no LF, not committed
        self.box.write(self.box.ledger, committed + torn)
        self.box.write_session_files("torn-session", with_session_end=False,
                                     with_marker=False)
        self.server = ServerProc(self.box, with_delivery=False)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0)
        self.server.assert_gone()

    def test_torn_tail_is_not_served_and_delivery_unconfigured(self):
        status, body, _, _ = self.server.get_json("/events")
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 2)
        self.assertEqual([e["event_id"] for e in body["events"]],
                         [EV1["event_id"], EV2["event_id"]])
        self.assertNotIn(EV3["event_id"], body["delivery"])
        self.assertEqual(body["delivery"], {})
        status, body, _, _ = self.server.get_json(
            "/events/" + EV3["event_id"])
        self.assertEqual(status, 404)  # the torn record is not committed
        status, body, _, _ = self.server.get_json("/status")
        self.assertEqual(body["delivery"],
                         {"by_state": None, "configured": False,
                          "devices": None, "pairs": None,
                          "present": None})
        self.assertEqual(body["events"]["count"], 2)


class StartupFailClosed(unittest.TestCase):
    """Refusals at startup: bad configuration never becomes a running
    server, and never a clean exit."""

    def run_serve(self, args):
        return subprocess.run([PY, SERVE] + args, capture_output=True,
                              timeout=15)

    def test_missing_runs_directory_refused(self):
        box = Sandbox()
        try:
            done = self.run_serve(["--runs", os.path.join(box.root, "nope"),
                                   "--ledger", box.ledger, "--port", "0"])
            self.assertNotEqual(done.returncode, 0)
            self.assertNotIn(b"SERVE", done.stdout)
        finally:
            box.cleanup()

    def test_port_out_of_range_refused(self):
        box = Sandbox()
        try:
            done = self.run_serve(["--runs", box.runs, "--ledger",
                                   box.ledger, "--port", "70000"])
            self.assertEqual(done.returncode, 2)
            self.assertNotIn(b"SERVE", done.stdout)
        finally:
            box.cleanup()

    def test_bind_refuses_multicast_broadcast_and_non_ipv4(self):
        # a bad --bind value dies on the argparse usage-error path
        # (exit 2, stderr names --bind) before any socket exists
        for value in ("224.0.0.1", "239.255.255.255",   # multicast 224/4
                      "255.255.255.255",                # broadcast
                      "240.0.0.1",                      # reserved 240/4
                      "0.0.0.1",                        # 0/8 beyond 0.0.0.0
                      "not-an-ip", "1.2.3", "999.0.0.1",
                      "::1"):
            box = Sandbox()
            try:
                done = self.run_serve(["--runs", box.runs, "--ledger",
                                       box.ledger, "--port", "0",
                                       "--bind", value])
                self.assertEqual(done.returncode, 2, value)
                self.assertIn(b"usage:", done.stderr, value)
                self.assertIn(b"error: --bind", done.stderr, value)
                self.assertNotIn(b"SERVE", done.stdout)
            finally:
                box.cleanup()

    def test_bind_zero_address_accepted_at_argument_level(self):
        # 0.0.0.0 passes --bind validation: the run proceeds past
        # argument parsing and dies later on the recorded --runs check
        # ("--runs is not an existing directory", not a bind error).
        # Asserted without opening any socket.
        box = Sandbox()
        try:
            done = self.run_serve(["--runs", os.path.join(box.root, "nope"),
                                   "--ledger", box.ledger, "--port", "0",
                                   "--bind", "0.0.0.0"])
            self.assertEqual(done.returncode, 2)
            self.assertNotIn(b"SERVE", done.stdout)
            stderr = done.stderr.decode("utf-8", "replace")
            self.assertIn("--runs is not an existing directory", stderr)
            self.assertNotIn("error: --bind", stderr)
        finally:
            box.cleanup()

    def test_missing_required_arguments_refused(self):
        box = Sandbox()
        try:
            done = self.run_serve(["--runs", box.runs, "--port", "0"])
            self.assertEqual(done.returncode, 2)
        finally:
            box.cleanup()


class BindAddressSuite(unittest.TestCase):
    """--bind with a concrete unicast address (README §1/§5): the SERVE
    line names the bound address, the socket really listens on it, and
    SIGTERM still ends the server cleanly with no residue."""

    def setUp(self):
        self.box = Sandbox()
        self.addCleanup(self.box.cleanup)
        self.server = ServerProc(self.box, bind="127.0.0.2")
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        self.server.assert_gone()

    def test_serve_line_and_listener_follow_bind_127_0_0_2(self):
        self.assertEqual(self.server.bind, "127.0.0.2")
        self.assertGreater(self.server.port, 0)
        self.assertLess(self.server.port, 65536)
        # a loopback GET through 127.0.0.2 proves the socket is bound
        # to the requested address, not merely announced
        status, body, raw, headers = self.server.get_json("/status")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")
        self.assertTrue(raw.endswith(b"\n"))
        self.assertEqual(body["sessions"]["count"], 0)


if __name__ == "__main__":
    unittest.main()
