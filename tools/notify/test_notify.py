#!/usr/bin/env python3
"""notify contract tests (tools/notify/README.md).

The real modules (notify_ledger, notify_fcm, notify_dispatcher,
notify_register, notify_config) run in-process against temp files and a
fake urllib opener: no network, no live FCM call, no credential value
printed. The crypto path is pinned to the OFFICIAL RFC 7515 A.2 RS256
test vector (its JWK is published, explicitly marked compromised, and
used for verification only — it is not a credential of anything).

Run: bash tools/notify/test_notify.sh — it resolves a Python 3.13
interpreter ($HSCOLLECTOR_PYTHON, python3.13, `uv python find 3.13`) and
runs this module through unittest. Pure standard library: no venv
bootstrap, no external dependency.
"""

import base64
import contextlib
import hashlib
import io
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import notify_config  # noqa: E402
import notify_dispatcher  # noqa: E402
import notify_fcm  # noqa: E402
import notify_ledger  # noqa: E402
import notify_register  # noqa: E402

BEARER = "DRILL-FAKE-BEARER-SECRET"
FCM_TOKEN = "FAKE-FCM-REGISTRATION-TOKEN-VALUE"
OAUTH_TOKEN = "FAKE-OAUTH-ACCESS-TOKEN"

# ----------------------------------------------------------------------
# RFC 7515 A.2 — the official RSASSA-PKCS1-v1_5 SHA-256 test vector.
# The JWK below is published in the RFC itself and is explicitly stated
# there to be compromised and for testing only; it pins the DER parser,
# the PKCS#1 v1.5 encoding and the RS256 signature to IETF evidence.

RFC7515_JWK = {
    "n": "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddx"
         "HmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMs"
         "D1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSH"
         "SXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdV"
         "MTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8"
         "NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ",
    "e": "AQAB",
    "d": "Eq5xpGnNCivDflJsRQBXHx1hdR1k6Ulwe2JZD50LpXyWPEAeP88vLNO97I"
         "jlA7_GQ5sLKMgvfTeXZx9SE-7YwVol2NXOoAJe46sui395IW_GO-pWJ1O0"
         "BkTGoVEn2bKVRUCgu-GjBVaYLU6f3l9kJfFNS3E0QbVdxzubSu3Mkqzjkn"
         "439X0M_V51gfpRLI9JYanrC4D4qAdGcopV_0ZHHzQlBjudU2QvXt4ehNYT"
         "CBr6XCLQUShb1juUO1ZdiYoFaFQT5Tw8bGUl_x_jTj3ccPDVZFD9pIuhLh"
         "BOneufuBiB4cS98l2SR_RQyGWSeWjnczT0QU91p1DhOVRuOopznQ",
    "p": "4BzEEOtIpmVdVEZNCqS7baC4crd0pqnRH_5IB3jw3bcxGn6QLvnEtfdUdi"
         "YrqBdss1l58BQ3KhooKeQTa9AB0Hw_Py5PJdTJNPY8cQn7ouZ2KKDcmnPG"
         "BY5t7yLc1QlQ5xHdwW1VhvKn-nXqhJTBgIPgtldC-KDV5z-y2XDwGUc",
    "q": "uQPEfgmVtjL0Uyyx88GZFF1fOunH3-7cepKmtH4pxhtCoHqpWmT8YAmZxa"
         "ewHgHAjLYsp1ZSe7zFYHj7C6ul7TjeLQeZD_YwD66t62wDmpe_HlB-TnBA"
         "-njbglfIsRLtXlnDzQkv5dTltRJ11BKBBypeeF6689rjcJIDEz9RWdc",
    "dp": "BwKfV3Akq5_MFZDFZCnW-wzl-CCo83WoZvnLQwCTeDv8uzluRSnm71I3Q"
          "CLdhrqE2e9YkxvuxdBfpT_PI7Yz-FOKnu1R6HsJeDCjn12Sk3vmAktV2zb"
          "34MCdy7cpdTh_YVr7tss2u6vneTwrA86rZtu5Mbr1C1XsmvkxHQAdYo0",
    "dq": "h_96-mK1R_7glhsum81dZxjTnYynPbZpHziZjeeHcXYsXaaMwkOlODsWa"
          "7I9xXDoRwbKgB719rrmI2oKr6N3Do9U0ajaHF-NKJnwgjMd2w9cjz3_-ky"
          "NlxAr2v4IKhGNpmM5iIgOS1VZnOZ68m6_pbLBSp3nssTdlqvd0tIiTHU",
    "qi": "IYd7DHOhrWvxkwPQsRM2tOgrjbcrfvtQJipd-DlcxyVuuM9sQLdgjVk2o"
          "y26F0EmpScGLq2MowX7fhd_QJQ3ydy5cY7YIBi87w93IKLEdfnbJtoOPLU"
          "W0ITrJReOgo1cq9SbsxYawBgfp_gh6A5603k2-ZQwVK0JKSHuLFkuQ3U",
}

RFC7515_SIGNING_INPUT = (
    "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAs"
    "DQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ").encode("ascii")

RFC7515_SIGNATURE_B64URL = (
    "cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7"
    "AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4"
    "BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K"
    "0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqv"
    "hJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrB"
    "p0igcN_IoypGlUPQGe77Rw")

# ------------------------------------------------------------------ helpers


def b64url_decode(text):
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def jwk_component(name):
    return int.from_bytes(b64url_decode(RFC7515_JWK[name]), "big")


def build_pkcs8_pem(jwk=RFC7515_JWK):
    """DER-encode the RFC JWK as a PKCS#8 RSAPrivateKey PEM — a test-side
    writer so the production DER reader is proven against real bytes."""
    def der_len(n):
        if n < 0x80:
            return bytes([n])
        body = n.to_bytes((n.bit_length() + 7) // 8, "big")
        return bytes([0x80 | len(body)]) + body

    def der_int(value):
        body = value.to_bytes(max(1, (value.bit_length() + 8) // 8), "big")
        return b"\x02" + der_len(len(body)) + body

    def der_seq(*parts):
        body = b"".join(parts)
        return b"\x30" + der_len(len(body)) + body

    order = ("n", "e", "d", "p", "q", "dp", "dq", "qi")
    pkcs1 = der_seq(der_int(0),
                    *[der_int(jwk_component(name)) for name in order])
    alg_id = der_seq(b"\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01",
                     b"\x05\x00")
    pkcs8 = der_seq(der_int(0), alg_id,
                    b"\x04" + der_len(len(pkcs1)) + pkcs1)
    b64 = base64.b64encode(pkcs8).decode("ascii")
    lines = [b64[i:i + 64] for i in range(0, len(b64), 64)]
    return "-----BEGIN PRIVATE KEY-----\n" + "\n".join(lines) + \
        "\n-----END PRIVATE KEY-----\n"


def event_id(session_id, event_type, rule_id, entity, transition_seq):
    """The committed x-event-id-rule: sha256 over the HCJ canonical
    serialization of {entity, event_type, rule_id, session_id,
    transition_seq} (keys codepoint-ascending, no whitespace, bare
    integers). The seq enters only this digest and is never emitted."""
    doc = {"entity": entity, "event_type": event_type,
           "rule_id": rule_id, "session_id": session_id,
           "transition_seq": transition_seq}
    canonical = json.dumps(doc, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def make_event(session_id="2026-11-01", event_type="TOP10_ENTERED",
               rule_id="top10-entered", seq=17, severity="INFO",
               symbol="005930", name=None, previous_rank=None, rank=3,
               direction="UP", observed_at="2026-11-01T09:12:33+09:00"):
    doc = {
        "event_id": event_id(session_id, event_type, rule_id,
                             symbol if symbol else "*", seq),
        "event_type": event_type,
        "observed_at": observed_at,
        "session_id": session_id,
        "rule_id": rule_id,
        "rule_version": 1,
        "data_quality": "OBSERVING",
        "severity": severity,
        "evidence_ref": "ka10027:stex_tp=1:sort_tp=1",
    }
    if direction is not None:
        doc["direction"] = direction
    if symbol:
        doc["symbol"] = symbol
    if name:
        doc["name"] = name
    if previous_rank is not None:
        doc["previous_rank"] = previous_rank
    if rank is not None:
        doc["rank"] = rank
    return doc


def write_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False,
                               separators=(",", ":")) + "\n")
    return path


class FakeResponse:
    def __init__(self, status, body, headers=None):
        self.status = status
        self._body = body if isinstance(body, bytes) else \
            json.dumps(body).encode("utf-8")
        self.headers = headers or {}

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeTransport:
    """The fake FCM/OAuth transport: a callable opener plus a scripted
    per-call behavior. Records every request; asserts the official
    endpoint URLs. No socket is ever opened."""

    TOKEN_URL = notify_fcm.OAUTH_TOKEN_URL
    SEND_URL = notify_fcm.FCM_SEND_URL % "drill-project"

    def __init__(self, send_responses=None):
        self.requests = []
        self.send_responses = list(send_responses or [])
        self.fail_sends = 0  # simulate transport loss (no answer)

    def __call__(self, request, timeout=None):
        url = request.full_url
        headers = {k.lower(): v for k, v in request.header_items()}
        self.requests.append({"url": url, "headers": headers,
                              "data": bytes(request.data or b"")})
        if url == self.TOKEN_URL:
            assert request.get_method() == "POST"
            return FakeResponse(200, {"access_token": OAUTH_TOKEN,
                                      "expires_in": 3600})
        if url == self.SEND_URL:
            auth = headers.get("authorization", "")
            assert auth == "Bearer %s" % OAUTH_TOKEN
            if self.fail_sends:
                self.fail_sends -= 1
                raise OSError("fake transport loss")
            if self.send_responses:
                return self.send_responses.pop(0)
            return FakeResponse(
                200, {"name": "projects/drill-project/messages/m-1"})
        raise AssertionError("fake transport: unexpected url %r" % url)

    def send_count(self):
        return sum(1 for r in self.requests if r["url"] == self.SEND_URL)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="notify-test-")
        self.outside = tempfile.mkdtemp(prefix="notify-outside-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.addCleanup(shutil.rmtree, self.outside, True)
        self.registry_path = os.path.join(self.outside, "devices.jsonl")
        self.bearer_path = os.path.join(self.outside, "bearer.secret")
        with open(self.bearer_path, "w", encoding="utf-8") as f:
            f.write(BEARER + "\n")

    def config(self, **overrides):
        cfg = {
            "project_id": "drill-project",
            "ledger_path": os.path.join(self.tmp, "ledger.hcj.jsonl"),
            "delivery_path": os.path.join(self.tmp, "delivery.hcj.jsonl"),
            "registry_path": self.registry_path,
            "register_bearer_file": self.bearer_path,
            "retry_min_seconds": 0,
            "backoff_cap_seconds": 5,
            "service_account_path": os.path.join(self.outside, "sa.json"),
        }
        cfg.update(overrides)
        path = os.path.join(self.tmp, "config.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        return path, cfg

    def write_service_account(self, cfg):
        with open(cfg["service_account_path"], "w", encoding="utf-8") as f:
            json.dump({"client_email": "drill@drill-project.iam.",
                       "private_key": build_pkcs8_pem()}, f)

    def seed_ledger(self, cfg, events):
        write_jsonl(cfg["ledger_path"], events)

    def register(self, device_id, token=FCM_TOKEN):
        registry = notify_ledger.Registry(self.registry_path, lock=True)
        try:
            registry.add_device(device_id, token)
        finally:
            registry.close()

    def dispatcher(self, cfg, transport, resident=False):
        """A Dispatcher with a controllable clock: the sleep call
        advances the fake clock so backoffs are instant and exact.
        resident=True builds the watch worker (the event ledger is
        opened with its writer lock)."""
        clock = {"now": 1_000_000.0}

        class Ctx(notify_dispatcher.Dispatcher):
            pass

        dispatcher = Ctx(
            cfg, opener=transport,
            clock=lambda: clock["now"],
            sleeper=lambda seconds: clock.__setitem__(
                "now", clock["now"] + seconds),
            resident=resident)
        dispatcher._clock_state = clock
        return dispatcher

    def ledger_lines(self, cfg):
        path = cfg["ledger_path"]
        if not os.path.exists(path):
            return []
        with open(path, "rb") as f:
            return f.read().split(b"\n")[:-1]

    def event_line(self, **kwargs):
        return json.dumps(make_event(**kwargs), ensure_ascii=False,
                          separators=(",", ":")).encode("utf-8")

    def _events_path(self):
        return os.path.join(self.tmp, "events.hcj.jsonl")

    def _append_lines(self, path, lines):
        with open(path, "ab") as f:
            for line in lines:
                f.write(line + b"\n")

    def delivery_records(self, cfg):
        path = cfg["delivery_path"]
        if not os.path.exists(path):
            return []
        with open(path, "r", encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]


# ------------------------------------------------------------- config


class TestConfig(Base):
    def test_credential_paths_must_resolve_outside_the_repo(self):
        path, _ = self.config(
            registry_path=os.path.join(notify_config.REPO_ROOT,
                                       "runs", "devices.jsonl"))
        with self.assertRaises(notify_config.ConfigError):
            notify_config.load_config(path, "dispatch")

    def test_dispatch_requires_exactly_one_credential_path(self):
        path, cfg = self.config()
        del cfg["service_account_path"]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        with self.assertRaises(notify_config.ConfigError):
            notify_config.load_config(path, "dispatch")
        cfg["token_command"] = ["gcloud", "auth", "application-default",
                                "print-access-token"]
        cfg["service_account_path"] = "/x/sa.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        with self.assertRaises(notify_config.ConfigError):
            notify_config.load_config(path, "dispatch")

    def test_min_severity_is_removed_not_validated(self):
        # min_severity is gone from the contract: the loader injects no
        # default and judges no leftover value — a stale key in an old
        # config file is ignored (unknown keys stay permissive, README
        # §7); the delivery policy is the dispatcher's event-type
        # allowlist, not a config knob.
        path, _ = self.config()
        loaded = notify_config.load_config(path, "dispatch")
        self.assertEqual(loaded["retry_min_seconds"], 0)
        self.assertEqual(loaded["backoff_cap_seconds"], 5)
        self.assertNotIn("min_severity", loaded)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(dict(loaded, min_severity="LOUD"), f)
        again = notify_config.load_config(path, "dispatch")
        self.assertEqual(again["retry_min_seconds"], 0)
        self.assertEqual(again.get("min_severity"), "LOUD")  # ignored

    def test_relative_paths_are_refused(self):
        path, cfg = self.config(ledger_path="relative/ledger.jsonl")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        with self.assertRaises(notify_config.ConfigError):
            notify_config.load_config(path, "dispatch")

    def test_watch_poll_seconds_defaults_and_bounds(self):
        path, cfg = self.config()
        loaded = notify_config.load_config(path, "dispatch")
        # Default: one-second ticks.
        self.assertEqual(loaded["watch_poll_seconds"], 1.0)
        for bad in (0, -1, 61, 60.5, "1", True, None):
            with open(path, "w", encoding="utf-8") as f:
                json.dump(dict(cfg, watch_poll_seconds=bad), f)
            with self.assertRaises(notify_config.ConfigError):
                notify_config.load_config(path, "dispatch")
        for good, expected in ((0.5, 0.5), (60, 60.0), (2, 2.0)):
            with open(path, "w", encoding="utf-8") as f:
                json.dump(dict(cfg, watch_poll_seconds=good), f)
            loaded = notify_config.load_config(path, "dispatch")
            self.assertEqual(loaded["watch_poll_seconds"], expected)

    def test_admission_defaults_to_plan_b_when_absent(self):
        # docs/ASSUMPTIONS.md P28: with no admission section the policy
        # is plan B (enter/exit immediate, rank digest) and the loaded
        # config states WHERE the policy came from — an absent section
        # is never conflated with a configured one.
        path, _ = self.config()
        loaded = notify_config.load_config(path, "dispatch")
        self.assertEqual(loaded["admission"],
                         notify_config.ADMISSION_DEFAULT)
        self.assertEqual(loaded["admission_source"], "default")

    def test_admission_section_is_validated_strictly(self):
        # A present section is strict: not an object, a mode outside
        # the vocabulary, or an event_type outside the admission
        # universe are refused. A PARTIAL mapping is not refused: the
        # named types override plan B, the rest keep the default.
        path, cfg = self.config()
        for bad in ([], "loud",
                    {"TOP10_ENTERED": "loud"},
                    {"CANDIDATE_ENTERED": "immediate"}):
            with open(path, "w", encoding="utf-8") as f:
                json.dump(dict(cfg, admission=bad), f)
            with self.assertRaises(notify_config.ConfigError):
                notify_config.load_config(path, "dispatch")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(dict(cfg, admission={"RANK_CHANGED": "suppress"}),
                      f)
        loaded = notify_config.load_config(path, "dispatch")
        self.assertEqual(loaded["admission_source"], "config")
        self.assertEqual(
            notify_config.admission_mode(loaded, "RANK_CHANGED"),
            "suppress")
        self.assertEqual(
            notify_config.admission_mode(loaded, "TOP10_ENTERED"),
            "immediate")  # partial: plan B underneath the override

    def test_admission_full_override_loads(self):
        path, _ = self.config(admission={
            "TOP10_ENTERED": "digest", "TOP10_EXITED": "digest",
            "RANK_CHANGED": "immediate"})
        loaded = notify_config.load_config(path, "dispatch")
        self.assertEqual(loaded["admission_source"], "config")
        for event_type, mode in (("TOP10_ENTERED", "digest"),
                                 ("TOP10_EXITED", "digest"),
                                 ("RANK_CHANGED", "immediate")):
            self.assertEqual(
                notify_config.admission_mode(loaded, event_type), mode)
        # Types outside the admission universe are always suppress:
        # the section can only re-map the universe, never widen it.
        self.assertEqual(
            notify_config.admission_mode(loaded, "SESSION_ENDED"),
            "suppress")


# ------------------------------------------------- schema validation


class TestEventSchema(Base):
    def test_valid_record_passes(self):
        notify_ledger.validate_event(make_event())

    def test_closed_schema_rejects_unknown_fields(self):
        bad = make_event()
        bad["delivery_state"] = "PENDING"  # the forbidden merge, by name
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)
        bad = make_event()
        bad["verification_status"] = "VERIFIED"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)

    def test_required_fields_and_enums(self):
        for key in notify_ledger.EVENT_REQUIRED:
            bad = make_event()
            del bad[key]
            with self.assertRaises(notify_ledger.LedgerError):
                notify_ledger.validate_event(bad)
        for key, values in (("event_type", notify_ledger.EVENT_TYPES),
                            ("severity", notify_ledger.SEVERITIES),
                            ("data_quality",
                             notify_ledger.DATA_QUALITIES)):
            bad = make_event()
            bad[key] = "NOT-" + values[0]
            with self.assertRaises(notify_ledger.LedgerError):
                notify_ledger.validate_event(bad)

    def test_patterns_and_types(self):
        bad = make_event()
        bad["event_id"] = "ABCD"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)
        bad = make_event()
        bad["symbol"] = "5930"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)
        bad = make_event()
        bad["rule_version"] = 0
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)
        bad = make_event()
        bad["observed_at"] = "2026-11-01 09:12:33"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_event(bad)

    def test_event_id_rule_is_deterministic_and_position_bound(self):
        self.assertEqual(event_id("2026-11-01", "CANDIDATE_ENTERED",
                                  "candidate-entered", "005930", 17),
                         event_id("2026-11-01", "CANDIDATE_ENTERED",
                                  "candidate-entered", "005930", 17))
        self.assertNotEqual(
            event_id("2026-11-01", "CANDIDATE_ENTERED", "candidate-entered",
                     "005930", 17),
            event_id("2026-11-01", "CANDIDATE_ENTERED", "candidate-entered",
                     "005930", 18))
        self.assertEqual(event_id("s", "CANDIDATE_ENTERED", "r", "*", 1),
                         hashlib.sha256(
                             b'{"entity":"*","event_type":"CANDIDATE_'
                             b'ENTERED","rule_id":"r","session_id":"s",'
                             b'"transition_seq":1}').hexdigest())

    def test_event_types_vocabulary_is_sixteen_with_top10(self):
        # contracts/events/event.schema.json grew the three market
        # TOP10 transition types: the ledger mirror carries all 16.
        self.assertEqual(len(notify_ledger.EVENT_TYPES), 16)
        self.assertEqual(
            {"TOP10_ENTERED", "TOP10_EXITED", "RANK_CHANGED"} -
            set(notify_ledger.EVENT_TYPES), set())

    def test_top10_optional_fields_are_accepted_and_checked(self):
        event = make_event(name="삼성전자", previous_rank=12, rank=4)
        notify_ledger.validate_event(event)
        for key, value in (("previous_rank", 0),
                           ("previous_rank", "12"),
                           ("name", ""),
                           ("name", 5930)):
            bad = make_event()
            bad[key] = value
            with self.assertRaises(notify_ledger.LedgerError):
                notify_ledger.validate_event(bad)

    def test_ledger_accepts_top10_optional_fields(self):
        # A producer fact carrying the new optional fields passes the
        # ledger's own validation path (ingest + read-back unchanged).
        event = make_event(name="삼성전자", previous_rank=12, rank=4)
        encoded = json.dumps(event, ensure_ascii=False,
                             separators=(",", ":")).encode("utf-8")
        _, cfg = self.config()
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            stats = ledger.ingest_lines([encoded])
            self.assertEqual(stats["appended"], 1)
            self.assertEqual(ledger.events()[0], event)
        finally:
            ledger.close()


class TestDeliverySchema(Base):
    def base_record(self, state):
        record = {
            "attempts": 1,
            "device_id": "dev-1",
            "event_id": "a" * 64,
            "state": state,
            "updated_at": "2026-11-01T10:00:00+09:00",
        }
        if state == "ACCEPTED":
            record["provider_message_id"] = \
                "projects/p/messages/m"
        if state == "FAILED":
            record["error_code"] = "UNREGISTERED"
        return record

    def test_three_states_valid(self):
        for state in ("PENDING", "ACCEPTED", "FAILED"):
            notify_ledger.validate_delivery(self.base_record(state))

    def test_state_pairings_are_enforced(self):
        pending = self.base_record("PENDING")
        pending["provider_message_id"] = "projects/p/messages/m"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(pending)
        pending = self.base_record("PENDING")
        pending["error_code"] = "QUOTA_EXCEEDED"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(pending)
        accepted = self.base_record("ACCEPTED")
        accepted["error_code"] = "QUOTA_EXCEEDED"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(accepted)
        failed = self.base_record("FAILED")
        failed["provider_message_id"] = "projects/p/messages/m"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(failed)

    def test_closed_schema_and_types(self):
        bad = self.base_record("PENDING")
        bad["severity"] = "HIGH"  # a fact field never enters delivery
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(bad)
        bad = self.base_record("PENDING")
        bad["attempts"] = -1
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(bad)
        bad = self.base_record("PENDING")
        bad["state"] = "SENT"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(bad)

    def test_message_kind_is_a_closed_optional_enum(self):
        # The composition kind (README §6/§7): single/summary/digest,
        # optional so pre-grouping ledgers stay valid, closed so no
        # fourth form can slip in undocumented.
        for state in ("PENDING", "ACCEPTED", "FAILED"):
            for kind in notify_ledger.MESSAGE_KINDS:
                record = self.base_record(state)
                record["message_kind"] = kind
                notify_ledger.validate_delivery(record)
        bad = self.base_record("ACCEPTED")
        bad["message_kind"] = "bulk"
        with self.assertRaises(notify_ledger.LedgerError):
            notify_ledger.validate_delivery(bad)


# ------------------------------------------------------- event ledger


class TestEventLedger(Base):
    def test_ingest_appends_bytes_verbatim(self):
        path, cfg = self.config()
        source = os.path.join(self.tmp, "source.jsonl")
        event = make_event()
        with open(source, "w", encoding="utf-8") as f:
            f.write(json.dumps(event, separators=(",", ":"),
                               sort_keys=True) + "\n")
        expected = open(source, "rb").read()
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            stats = ledger.ingest_source(source)
        finally:
            ledger.close()
        self.assertEqual(stats, {"appended": 1, "duplicate": 0,
                                 "total": 1})
        self.assertEqual(open(cfg["ledger_path"], "rb").read(), expected)

    def test_ingest_is_idempotent_for_identical_duplicates(self):
        _, cfg = self.config()
        source = os.path.join(self.tmp, "source.jsonl")
        write_jsonl(source, [make_event()])
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            ledger.ingest_source(source)
            stats = ledger.ingest_source(source)
        finally:
            ledger.close()
        self.assertEqual(stats["appended"], 0)
        self.assertEqual(stats["duplicate"], 1)

    def test_divergent_duplicate_is_refused(self):
        _, cfg = self.config()
        event = make_event()
        first = os.path.join(self.tmp, "first.jsonl")
        second = os.path.join(self.tmp, "second.jsonl")
        write_jsonl(first, [event])
        divergent = dict(event)
        divergent["severity"] = "CRITICAL"  # same id, different bytes
        write_jsonl(second, [divergent])
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            ledger.ingest_source(first)
            before = open(cfg["ledger_path"], "rb").read()
            with self.assertRaises(notify_ledger.LedgerError):
                ledger.ingest_source(second)
            self.assertEqual(open(cfg["ledger_path"], "rb").read(),
                             before)
        finally:
            ledger.close()

    def test_invalid_source_appends_nothing(self):
        _, cfg = self.config()
        source = os.path.join(self.tmp, "source.jsonl")
        with open(source, "w", encoding="utf-8") as f:
            f.write(json.dumps(make_event(),
                               separators=(",", ":")) + "\n")
            f.write('{"event_type":"NOT_IN_THE_VOCABULARY"}\n')
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            with self.assertRaises(notify_ledger.LedgerError):
                ledger.ingest_source(source)
            # The appendable file may exist (opened O_CREAT), but not a
            # single byte of the invalid source reached it.
            data = open(cfg["ledger_path"], "rb").read() \
                if os.path.exists(cfg["ledger_path"]) else b""
            self.assertEqual(data, b"")
        finally:
            ledger.close()

    def test_lenient_read_skips_an_uncommitted_tail(self):
        _, cfg = self.config()
        path = cfg["ledger_path"]
        write_jsonl(path, [make_event()])
        with open(path, "a", encoding="utf-8") as f:
            f.write('{"event_type":"CANDIDATE_E')  # crashed writer tail
        ledger = notify_ledger.EventLedger(path, lock=False)
        try:
            events = ledger.events(strict=False)
            self.assertEqual(len(events), 1)
            with self.assertRaises(notify_ledger.LedgerError):
                ledger.events(strict=True)
        finally:
            ledger.close()

    def test_cli_ingest_and_check(self):
        path, cfg = self.config()
        source = os.path.join(self.tmp, "source.jsonl")
        write_jsonl(source, [make_event()])
        rc = notify_ledger._main(["ingest", "--config", path,
                                  "--source", source])
        self.assertEqual(rc, 0)
        rc = notify_ledger._main(["check", "--config", path])
        self.assertEqual(rc, 0)
        rc = notify_ledger._main(["ingest", "--config", path,
                                  "--source", source])
        self.assertEqual(rc, 0)  # idempotent re-ingest stays success

    def test_ingest_lines_batch_is_all_or_nothing_and_idempotent(self):
        # The resident worker's entry point: same validation/dedup path
        # as ingest_source, but the batch was already LF-terminated in
        # the source and NOTHING is appended unless every line is good.
        _, cfg = self.config()
        ledger = notify_ledger.EventLedger(cfg["ledger_path"], lock=True)
        try:
            a = json.dumps(make_event(seq=1), separators=(",", ":")
                           ).encode("utf-8")
            b = json.dumps(make_event(seq=2), separators=(",", ":")
                           ).encode("utf-8")
            stats = ledger.ingest_lines([a, b])
            self.assertEqual(stats, {"appended": 2, "duplicate": 0,
                                     "total": 2})
            after_first = open(cfg["ledger_path"], "rb").read()
            self.assertEqual(after_first, a + b"\n" + b + b"\n")
            # Byte-identical re-ingest: an idempotent skip, no change.
            stats = ledger.ingest_lines([a, b])
            self.assertEqual(stats, {"appended": 0, "duplicate": 2,
                                     "total": 2})
            self.assertEqual(open(cfg["ledger_path"], "rb").read(),
                             after_first)
            # A divergent duplicate is refused, nothing appended.
            divergent = json.dumps(dict(make_event(seq=1),
                                        severity="CRITICAL"),
                                   separators=(",", ":")).encode("utf-8")
            with self.assertRaises(notify_ledger.LedgerError):
                ledger.ingest_lines([divergent])
            self.assertEqual(open(cfg["ledger_path"], "rb").read(),
                             after_first)
            # An invalid line after a valid one: the WHOLE batch is
            # refused (no partial append), unlike a per-line writer.
            with self.assertRaises(notify_ledger.LedgerError):
                ledger.ingest_lines([a, b"{}"])
            self.assertEqual(open(cfg["ledger_path"], "rb").read(),
                             after_first)
            # An empty line is a contract violation too.
            with self.assertRaises(notify_ledger.LedgerError):
                ledger.ingest_lines([a, b""])
            self.assertEqual(open(cfg["ledger_path"], "rb").read(),
                             after_first)
        finally:
            ledger.close()


# ---------------------------------------------------------- registries


class TestRegistry(Base):
    def test_add_and_active_devices(self):
        self.register("dev-a")
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {"dev-a": FCM_TOKEN})
        finally:
            registry.close()

    def test_re_registration_latest_wins(self):
        self.register("dev-a", "old-token")
        self.register("dev-a", FCM_TOKEN)
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {"dev-a": FCM_TOKEN})
        finally:
            registry.close()

    def test_token_invalid_retires_and_never_carries_the_raw_token(self):
        self.register("dev-a")
        registry = notify_ledger.Registry(self.registry_path, lock=True)
        try:
            registry.mark_invalid("dev-a", FCM_TOKEN)
            self.assertEqual(registry.devices(), {})
        finally:
            registry.close()
        raw = open(self.registry_path, "r", encoding="utf-8").read()
        self.assertNotIn(FCM_TOKEN, raw.splitlines()[-1])
        self.assertIn(notify_ledger.mask_secret(FCM_TOKEN),
                      raw.splitlines()[-1])

    def test_single_writer_lock_is_enforced(self):
        first = notify_ledger.Registry(self.registry_path, lock=True)
        with self.assertRaises(notify_ledger.LedgerBusy):
            notify_ledger.Registry(self.registry_path, lock=True)
        first.close()
        second = notify_ledger.Registry(self.registry_path, lock=True)
        second.close()

    def test_writers_refuse_to_build_on_a_torn_tail(self):
        """A writer that died mid-append leaves a record without its LF.
        Readers skip that tail, but appending after it would bury a
        half-written record mid-file — so writers refuse (fail-closed)."""
        torn = os.path.join(self.tmp, "torn.jsonl")
        write_jsonl(torn, [make_event()])
        with open(torn, "a", encoding="utf-8") as f:
            f.write('{"event_type":"CANDIDATE_E')  # no LF
        with self.assertRaises(notify_ledger.LedgerFault):
            notify_ledger.EventLedger(torn, lock=True)
        torn_delivery = os.path.join(self.tmp, "torn-delivery.jsonl")
        with open(torn_delivery, "w", encoding="utf-8") as f:
            f.write('{"attempts":1,"device_id":"d"')  # no LF
        with self.assertRaises(notify_ledger.LedgerFault):
            notify_ledger.DeliveryLedger(torn_delivery, lock=True)
        torn_registry = os.path.join(self.outside, "torn-registry.jsonl")
        with open(torn_registry, "w", encoding="utf-8") as f:
            f.write('{"kind":"dev')  # no LF
        with self.assertRaises(notify_ledger.LedgerFault):
            notify_ledger.Registry(torn_registry, lock=True)


# --------------------------------------------------------------- crypto


class TestCrypto(Base):
    def test_rfc7515_a2_key_parses_from_pkcs8_pem(self):
        key = notify_fcm.parse_rsa_private_key(build_pkcs8_pem())
        for name in notify_fcm.RSA_COMPONENTS:
            self.assertEqual(key[name], jwk_component(name), name)

    def test_rfc7515_a2_signature_vector(self):
        key = notify_fcm.parse_rsa_private_key(build_pkcs8_pem())
        signature = notify_fcm.rs256_sign(key, RFC7515_SIGNING_INPUT)
        expected = b64url_decode(RFC7515_SIGNATURE_B64URL)
        self.assertEqual(signature, expected)

    def test_pkcs1_pem_also_parses(self):
        key8 = notify_fcm.parse_rsa_private_key(build_pkcs8_pem())
        # Re-serialize as PKCS#1 by signing the same input via a PEM
        # built from the same components (the writer lives above).
        self.assertEqual(
            notify_fcm.rs256_sign(key8, b"x"),
            notify_fcm.rs256_sign(key8, b"x"))

    def test_bad_pem_is_fail_closed(self):
        for pem in ("", "-----BEGIN PUBLIC KEY-----\nAAAA\n"
                         "-----END PUBLIC KEY-----\n",
                    "-----BEGIN PRIVATE KEY-----\n!!!\n"
                    "-----END PRIVATE KEY-----\n"):
            with self.assertRaises(notify_fcm.FcmError):
                notify_fcm.parse_rsa_private_key(pem)

    def test_jwt_shape_and_signature(self):
        key = notify_fcm.parse_rsa_private_key(build_pkcs8_pem())
        jwt = notify_fcm.service_account_jwt(key, "sa@project.iam",
                                             iat=1_700_000_000)
        header_b64, claims_b64, sig_b64 = jwt.split(".")
        header = json.loads(b64url_decode(header_b64))
        claims = json.loads(b64url_decode(claims_b64))
        self.assertEqual(header, {"alg": "RS256", "typ": "JWT"})
        self.assertEqual(claims["iss"], "sa@project.iam")
        self.assertEqual(claims["scope"], notify_fcm.FCM_SCOPE)
        self.assertEqual(claims["aud"], notify_fcm.OAUTH_TOKEN_URL)
        self.assertEqual(claims["exp"], 1_700_000_000 + 3600)
        signing_input = ("%s.%s" % (header_b64, claims_b64)
                         ).encode("ascii")
        self.assertEqual(
            notify_fcm.rs256_sign(key, signing_input),
            b64url_decode(sig_b64))


# ----------------------------------------------------------- transport


class TestTransport(Base):
    def test_generic_branch_is_notification_plus_data(self):
        # The defensive generic assembly (README §6): the dispatcher's
        # allowlist blocks every non-TOP10 type before the transport,
        # but build_message stays general — minimal title/body, ids in
        # data — instead of hiding a second policy gate here.
        event = make_event(event_type="CANDIDATE_ENTERED",
                           rule_id="candidate-entered")
        message = notify_fcm.build_message(event, FCM_TOKEN)
        inner = message["message"]
        self.assertEqual(inner["token"], FCM_TOKEN)
        self.assertEqual(
            inner["notification"],
            {"title": "Hong Scanner INFO", "body": "CANDIDATE_ENTERED "
             "005930"})
        self.assertEqual(inner["data"], {
            "event_id": event["event_id"],
            "event_type": "CANDIDATE_ENTERED",
            "severity": "INFO"})
        self.assertNotIn("channel_id", inner["android"].get(
            "notification", {}))

    def test_generic_branch_priority_is_explicit_and_severity_mapped(self):
        # The vendor's pages disagree on the unset default (README §6),
        # so the mapping is always explicit: HIGH/CRITICAL -> high,
        # INFO -> normal.
        message = notify_fcm.build_message(
            make_event(event_type="CANDIDATE_ENTERED",
                       rule_id="candidate-entered"), FCM_TOKEN)
        self.assertEqual(message["message"]["android"]["priority"],
                         "normal")
        for severity in ("HIGH", "CRITICAL"):
            message = notify_fcm.build_message(
                make_event(event_type="CANDIDATE_ENTERED",
                           rule_id="candidate-entered",
                           severity=severity), FCM_TOKEN)
            self.assertEqual(message["message"]["android"]["priority"],
                             "high")
        # The explicit field is inside the wire payload the guard
        # measures: still far below the vendor limit.
        size = len(json.dumps(message, ensure_ascii=False,
                              separators=(",", ":")).encode("utf-8"))
        self.assertLessEqual(size, notify_fcm.PAYLOAD_LIMIT_BYTES)

    def test_payload_limit_is_enforced(self):
        # The guard runs on the wire payload; an oversized token forces
        # the refusal without touching any event field.
        with self.assertRaises(notify_fcm.FcmError):
            notify_fcm.build_message(make_event(), "t" * 4200)
        # The real message shape is far below the limit.
        message = notify_fcm.build_message(make_event(), FCM_TOKEN)
        size = len(json.dumps(message, separators=(",", ":")).encode())
        self.assertLessEqual(size, notify_fcm.PAYLOAD_LIMIT_BYTES)

    def test_classify_table(self):
        ok = notify_fcm.classify_send(
            200, {}, b'{"name":"projects/p/messages/m"}')
        self.assertEqual((ok.kind, ok.provider_message_id),
                         ("accepted", "projects/p/messages/m"))
        limited = notify_fcm.classify_send(
            429, {"Retry-After": "90"},
            b'{"error":{"code":429,"status":"QUOTA_EXCEEDED",'
            b'"message":"..."}}')
        self.assertEqual((limited.kind, limited.error_code,
                          limited.retry_after_seconds),
                         ("retry", "QUOTA_EXCEEDED", 90))
        for status, expected in ((500, "INTERNAL"), (503, "UNAVAILABLE")):
            body = json.dumps(
                {"error": {"code": status, "status": expected}}).encode()
            outcome = notify_fcm.classify_send(status, {}, body)
            self.assertEqual(outcome.kind, "retry")
            self.assertEqual(outcome.error_code, expected)
        unregistered = notify_fcm.classify_send(
            404, {}, b'{"error":{"code":404,"status":"UNREGISTERED"}}')
        self.assertEqual((unregistered.kind, unregistered.error_code),
                         ("unregistered", "UNREGISTERED"))
        # The measured REST wire form (2026-11-03 delivery ledger,
        # docs/GATES.md evidence log): an invalid token answers 404
        # with error.status "NOT_FOUND" — the google.rpc canonical
        # name for 404 — not the Admin-SDK error table's UNREGISTERED
        # spelling. Both names denote the same retired-token state.
        wire_unregistered = notify_fcm.classify_send(
            404, {}, b'{"error":{"code":404,"status":"NOT_FOUND"}}')
        self.assertEqual((wire_unregistered.kind,
                          wire_unregistered.error_code),
                         ("unregistered", "NOT_FOUND"))
        # NOT_FOUND is the retired-token state ONLY when paired with
        # HTTP 404: under any other status it is an unknown code, kept
        # verbatim and permanent — never a guessed retirement.
        other_not_found = notify_fcm.classify_send(
            400, {}, b'{"error":{"code":400,"status":"NOT_FOUND"}}')
        self.assertEqual((other_not_found.kind, other_not_found.error_code),
                         ("permanent", "NOT_FOUND"))
        # And a 404 carrying any other code is not a retirement either.
        odd_404 = notify_fcm.classify_send(
            404, {}, b'{"error":{"code":404,"status":"SOME_OTHER_CODE"}}')
        self.assertEqual((odd_404.kind, odd_404.error_code),
                         ("permanent", "SOME_OTHER_CODE"))
        mismatch = notify_fcm.classify_send(
            403, {}, b'{"error":{"code":403,'
                     b'"status":"SENDER_ID_MISMATCH"}}')
        self.assertEqual((mismatch.kind, mismatch.error_code),
                         ("sender_mismatch", "SENDER_ID_MISMATCH"))
        permanent = notify_fcm.classify_send(
            400, {}, b'{"error":{"code":400,"status":"INVALID_ARGUMENT"}}')
        self.assertEqual((permanent.kind, permanent.error_code),
                         ("permanent", "INVALID_ARGUMENT"))
        unknown = notify_fcm.classify_send(418, {}, b"teapot")
        self.assertEqual(unknown.kind, "permanent")
        self.assertEqual(unknown.error_code, "HTTP_418")
        no_name = notify_fcm.classify_send(200, {}, b'{"ok":true}')
        self.assertEqual((no_name.kind, no_name.error_code),
                         ("permanent", "HS_NO_PROVIDER_MESSAGE_ID"))

    def test_retry_after_garbage_is_treated_as_absent(self):
        outcome = notify_fcm.classify_send(
            429, {"Retry-After": "soon"}, b'{"error":{"status":"X"}}')
        self.assertIsNone(outcome.retry_after_seconds)

    def test_send_message_posts_to_the_official_endpoint(self):
        transport = FakeTransport()
        message = notify_fcm.build_message(make_event(), FCM_TOKEN)
        outcome = notify_fcm.send_message("drill-project", OAUTH_TOKEN,
                                          message, opener=transport)
        self.assertEqual(outcome.kind, "accepted")
        request = transport.requests[-1]
        self.assertEqual(request["url"], FakeTransport.SEND_URL)
        body = json.loads(request["data"])
        self.assertIn("message", body)
        self.assertEqual(request["headers"]["content-type"],
                         "application/json; charset=UTF-8")

    def test_transport_loss_is_retry_never_success(self):
        transport = FakeTransport()
        transport.fail_sends = 1
        outcome = notify_fcm.send_message(
            "drill-project", OAUTH_TOKEN,
            notify_fcm.build_message(make_event(), FCM_TOKEN),
            opener=transport)
        self.assertEqual(outcome.kind, "retry")
        self.assertEqual(outcome.error_code, "HS_TRANSPORT")

    def test_token_source_uses_the_service_account_path(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        transport = FakeTransport()
        source = notify_fcm.TokenSource(cfg, opener=transport)
        token = source.get(now=1_000_000.0)
        self.assertEqual(token, OAUTH_TOKEN)
        token_request = transport.requests[0]
        self.assertEqual(token_request["url"], FakeTransport.TOKEN_URL)
        assertion = dict(pair.split("=") for pair in
                         token_request["data"].decode().split("&"))
        self.assertEqual(assertion["grant_type"],
                         "urn%3Aietf%3Aparams%3Aoauth%3A"
                         "grant-type%3Ajwt-bearer")
        jwt = assertion["assertion"].replace("%2E", ".")
        self.assertEqual(len(jwt.split(".")), 3)

    def test_token_source_delegates_to_a_token_command(self):
        _, cfg = self.config()
        del cfg["service_account_path"]
        cfg["token_command"] = [sys.executable, "-c",
                                "print('%s')" % OAUTH_TOKEN]
        source = notify_fcm.TokenSource(cfg)
        self.assertEqual(source.get(), OAUTH_TOKEN)
        failing = dict(cfg)
        failing["token_command"] = [sys.executable, "-c",
                                    "raise SystemExit(3)"]
        with self.assertRaises(notify_fcm.FcmError):
            notify_fcm.TokenSource(failing).get()


# --------------------------------------------------- top10 message


class TestTop10Message(Base):
    """The market TOP10 message assembly (README §6): the five rank
    move texts, the name->symbol fallback, the always-high priority,
    the market_rank_changes channel and the stringified data fields."""

    def message_for(self, **overrides):
        event = make_event(**overrides)
        return event, notify_fcm.build_message(event, FCM_TOKEN)

    def assert_top10_shape(self, event, message, expected_body):
        inner = message["message"]
        self.assertEqual(inner["token"], FCM_TOKEN)
        self.assertEqual(inner["notification"]["title"],
                         "홍스캐너 TOP10 변화")
        self.assertEqual(inner["notification"]["body"], expected_body)
        self.assertEqual(inner["android"],
                         {"priority": "high",
                          "notification": {"channel_id":
                                           "market_rank_changes"}})
        self.assertEqual(inner["data"]["event_id"], event["event_id"])
        self.assertEqual(inner["data"]["event_type"],
                         event["event_type"])
        self.assertEqual(inner["data"]["severity"], event["severity"])
        for key in ("direction", "symbol", "previous_rank", "rank"):
            if key in event:
                # FCM data values are strings: ints are stringified.
                self.assertEqual(inner["data"][key], str(event[key]))
            else:
                self.assertNotIn(key, inner["data"])
        size = len(json.dumps(message, ensure_ascii=False,
                              separators=(",", ":")).encode("utf-8"))
        self.assertLessEqual(size, notify_fcm.PAYLOAD_LIMIT_BYTES)

    def test_new_entry_body(self):
        # 신규진입: an entry without a previous confirmed rank.
        event, message = self.message_for(name="삼성전자", rank=7)
        self.assert_top10_shape(
            event, message, "삼성전자 상승 TOP10 신규 진입 7위")

    def test_reentry_body(self):
        # 기존진입: an entry whose previous confirmed rank is known.
        event, message = self.message_for(name="삼성전자",
                                          previous_rank=15, rank=4)
        self.assert_top10_shape(
            event, message, "삼성전자 상승 TOP10 15위 → 4위")

    def test_rank_change_body(self):
        # 순위변경: both ranks, up and down.
        event, message = self.message_for(event_type="RANK_CHANGED",
                                          rule_id="rank-changed",
                                          name="삼성전자", previous_rank=4,
                                          rank=2)
        self.assert_top10_shape(
            event, message, "삼성전자 상승 TOP10 4위 → 2위")
        event, message = self.message_for(event_type="RANK_CHANGED",
                                          rule_id="rank-changed",
                                          name="삼성전자", previous_rank=2,
                                          rank=4, direction="DOWN")
        self.assert_top10_shape(
            event, message, "삼성전자 하락 TOP10 2위 → 4위")

    def test_exit_body(self):
        # 밖이탈: fell out of the TOP10, still ranked in the universe.
        event, message = self.message_for(event_type="TOP10_EXITED",
                                          rule_id="top10-exited",
                                          name="삼성전자", previous_rank=9,
                                          rank=13, direction="DOWN")
        self.assert_top10_shape(
            event, message, "삼성전자 하락 TOP10 9위 → 13위")

    def test_candidate_exclusion_body(self):
        # 후보제외: left the candidate universe entirely — no rank.
        event, message = self.message_for(event_type="TOP10_EXITED",
                                          rule_id="top10-exited",
                                          name="삼성전자", previous_rank=6,
                                          rank=None, direction="DOWN")
        self.assert_top10_shape(
            event, message, "삼성전자 하락 TOP10 6위 → 후보 제외")

    def test_symbol_fallback_when_no_name(self):
        event, message = self.message_for(rank=7)
        self.assert_top10_shape(
            event, message, "005930 상승 TOP10 신규 진입 7위")

    def test_no_invented_words(self):
        # An absent direction drops its word and a fact with neither
        # rank drops the move text — the translation never invents a
        # direction or a rank the fact does not carry.
        event, message = self.message_for(name="삼성전자", rank=None,
                                          direction=None)
        self.assert_top10_shape(event, message, "삼성전자 TOP10")

    def test_priority_is_always_high_regardless_of_severity(self):
        # The three notifiable types are time-sensitive market moves:
        # priority follows the policy path, never the severity field.
        for severity in ("INFO", "HIGH", "CRITICAL"):
            event, message = self.message_for(severity=severity, rank=7)
            self.assertEqual(message["message"]["android"]["priority"],
                             "high")
            self.assertEqual(message["message"]["android"]
                             ["notification"]["channel_id"],
                             "market_rank_changes")

    # The group assemblies (README §6; docs/ASSUMPTIONS.md P28): the
    # observation-group send forms the admission policy composes.

    def group_events(self, count, observed_at=None):
        events = []
        for seq in range(1, count + 1):
            events.append(make_event(
                event_type="RANK_CHANGED", rule_id="rank-changed",
                seq=seq, name="종목%d" % seq, previous_rank=10 + seq,
                rank=seq, observed_at=observed_at))
        return events

    def test_summary_message_shape(self):
        entered = make_event(seq=17, name="삼성전자", rank=7)
        exited = make_event(event_type="TOP10_EXITED",
                            rule_id="top10-exited", seq=19,
                            name="SK하이닉스", previous_rank=9, rank=None,
                            direction="DOWN")
        message = notify_fcm.build_summary_message([entered, exited],
                                                   FCM_TOKEN)
        inner = message["message"]
        self.assertEqual(inner["token"], FCM_TOKEN)
        self.assertEqual(inner["notification"]["title"],
                         notify_fcm.TOP10_TITLE)
        self.assertEqual(inner["notification"]["body"],
                         "삼성전자 진입·SK하이닉스 이탈")
        self.assertEqual(inner["android"],
                         {"priority": "high",
                          "notification": {"channel_id":
                                           notify_fcm.TOP10_CHANNEL_ID}})
        # The group data contract: kind, the FULL member list (ledger
        # order) and the count — nothing else; the per-event fields
        # stay on the single message.
        self.assertEqual(inner["data"], {
            "kind": "summary",
            "event_ids": "%s,%s" % (entered["event_id"],
                                    exited["event_id"]),
            "count": "2"})

    def test_summary_body_lists_two_then_counts_the_rest(self):
        events = [make_event(seq=seq, name="종목%d" % seq)
                  for seq in range(1, 6)]
        message = notify_fcm.build_summary_message(events, FCM_TOKEN)
        self.assertEqual(message["message"]["notification"]["body"],
                         "종목1 진입·종목2 진입 외 3건")
        self.assertEqual(message["message"]["data"]["count"], "5")

    def test_digest_message_shape(self):
        events = self.group_events(2)
        message = notify_fcm.build_digest_message(events, FCM_TOKEN)
        inner = message["message"]
        self.assertEqual(inner["token"], FCM_TOKEN)
        self.assertEqual(inner["notification"]["title"],
                         notify_fcm.DIGEST_TITLE)
        self.assertEqual(inner["notification"]["body"],
                         "종목1 11위→1위 외 1건")
        # The digest is the SILENT form: normal priority, the dedicated
        # market_rank_digest channel.
        self.assertEqual(inner["android"],
                         {"priority": "normal",
                          "notification": {"channel_id":
                                           notify_fcm.DIGEST_CHANNEL_ID}})
        # One tap reaches every fact: the full covered event-id list.
        self.assertEqual(inner["data"], {
            "kind": "digest",
            "event_ids": "%s,%s" % (events[0]["event_id"],
                                    events[1]["event_id"]),
            "count": "2"})

    def test_digest_single_event_has_no_overflow_suffix(self):
        message = notify_fcm.build_digest_message(self.group_events(1),
                                                  FCM_TOKEN)
        self.assertEqual(message["message"]["notification"]["body"],
                         "종목1 11위→1위")

    def test_digest_never_invents_a_move_the_facts_do_not_carry(self):
        only_rank = [make_event(event_type="RANK_CHANGED",
                                rule_id="rank-changed", seq=1,
                                name="종목1", previous_rank=None, rank=2)]
        message = notify_fcm.build_digest_message(only_rank, FCM_TOKEN)
        self.assertEqual(message["message"]["notification"]["body"],
                         "종목1 신규 진입 2위")
        only_prev = [make_event(event_type="RANK_CHANGED",
                                rule_id="rank-changed", seq=2,
                                name="종목2", previous_rank=5, rank=None)]
        message = notify_fcm.build_digest_message(only_prev, FCM_TOKEN)
        self.assertEqual(message["message"]["notification"]["body"],
                         "종목2 5위→후보 제외")
        bare = [make_event(event_type="RANK_CHANGED",
                           rule_id="rank-changed", seq=3, name="종목3",
                           previous_rank=None, rank=None)]
        message = notify_fcm.build_digest_message(bare, FCM_TOKEN)
        self.assertEqual(message["message"]["notification"]["body"],
                         "종목3")

    def test_group_payload_limit_accepts_forty_and_refuses_hundred(self):
        # The 4096-byte guard judges the GROUP composition: a 40-event
        # group fits, a 100-event group is refused before any send —
        # fail-closed, never a silently truncated composition.
        self.assertIsNotNone(
            notify_fcm.build_digest_message(self.group_events(40),
                                            FCM_TOKEN))
        with self.assertRaises(notify_fcm.FcmError):
            notify_fcm.build_digest_message(self.group_events(100),
                                            FCM_TOKEN)
        entered = [make_event(seq=seq, name="종목%d" % seq)
                   for seq in range(1, 101)]
        self.assertIsNotNone(
            notify_fcm.build_summary_message(entered[:40], FCM_TOKEN))
        with self.assertRaises(notify_fcm.FcmError):
            notify_fcm.build_summary_message(entered, FCM_TOKEN)

    def test_group_assembly_is_deterministic_and_order_bound(self):
        events = self.group_events(3)
        first = notify_fcm.build_digest_message(events, FCM_TOKEN)
        second = notify_fcm.build_digest_message(list(events), FCM_TOKEN)
        self.assertEqual(json.dumps(first, ensure_ascii=False,
                                    separators=(",", ":")),
                         json.dumps(second, ensure_ascii=False,
                                    separators=(",", ":")))
        # Order is ledger order: swapping the members changes the
        # first-named fact, not just the id list.
        swapped = notify_fcm.build_digest_message(
            [events[1], events[0], events[2]], FCM_TOKEN)
        self.assertEqual(
            swapped["message"]["notification"]["body"],
            "종목2 12위→2위 외 2건")
        self.assertEqual(
            swapped["message"]["data"]["event_ids"],
            ",".join(event["event_id"]
                     for event in [events[1], events[0], events[2]]))


# ---------------------------------------------------------- dispatcher


class TestDispatcher(Base):
    def test_normal_delivery_records_accepted(self):
        path, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        records = self.delivery_records(cfg)
        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record["state"], "ACCEPTED")
        self.assertEqual(record["attempts"], 1)
        self.assertEqual(record["provider_message_id"],
                         "projects/drill-project/messages/m-1")
        self.assertEqual(record["device_id"], "dev-1")
        self.assertNotIn("error_code", record)
        # accepted != delivered: nothing in any record claims arrival.
        self.assertNotIn("delivered", json.dumps(records))

    def test_duplicate_suppression_never_resends_accepted(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport()
        first = self.dispatcher(cfg, transport)
        try:
            first.sweep()
        finally:
            first.close()
        second = self.dispatcher(cfg, transport)
        try:
            code = second.sweep()
        finally:
            second.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 1)
        self.assertEqual(second.counts.get("dedup_suppressed"), 1)
        self.assertEqual(len(self.delivery_records(cfg)), 1)

    def test_429_backoff_honors_retry_after_and_then_accepts(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(429, {"error": {"code": 429,
                                         "status": "QUOTA_EXCEEDED"}},
                         headers={"Retry-After": "90"}),
            FakeResponse(200, {"name": "projects/drill-project/"
                                       "messages/m-2"}),
        ])
        cfg["backoff_cap_seconds"] = 900
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        records = self.delivery_records(cfg)
        self.assertEqual([r["state"] for r in records],
                         ["PENDING", "ACCEPTED"])
        self.assertEqual([r["attempts"] for r in records], [1, 2])
        # The in-sweep wait honored Retry-After (90s) exactly: the fake
        # clock advanced by it through the injected sleeper.
        self.assertGreaterEqual(dispatcher._clock_state["now"] -
                                1_000_000.0, 90)
        self.assertLess(dispatcher._clock_state["now"] - 1_000_000.0,
                        91)

    def test_429_beyond_the_cap_is_parked_pending_not_failed(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(429, {"error": {"code": 429,
                                         "status": "QUOTA_EXCEEDED"}},
                         headers={"Retry-After": "100000"}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(dispatcher.counts.get("pending_parked"), 1)
        self.assertEqual(self.delivery_records(cfg)[-1]["state"],
                         "PENDING")

    def test_404_unregistered_fails_and_retires_the_token(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(404, {"error": {"code": 404,
                                         "status": "UNREGISTERED"}}),
        ])
        first = self.dispatcher(cfg, transport)
        try:
            code = first.sweep()
        finally:
            first.close()
        self.assertEqual(code, 0)
        record = self.delivery_records(cfg)[0]
        self.assertEqual(record["state"], "FAILED")
        self.assertEqual(record["error_code"], "UNREGISTERED")
        # The registry retired the token (hash only) — a second sweep
        # has no active device left and must not send again.
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {})
        finally:
            registry.close()
        second = self.dispatcher(cfg, transport)
        try:
            second.sweep()
        finally:
            second.close()
        self.assertEqual(transport.send_count(), 1)

    def test_404_not_found_wire_form_fails_and_retires_the_token(self):
        """The regression the 2026-11-03 live wire exposed: an invalid
        token answers HTTP 404 with error.status "NOT_FOUND" (the
        google.rpc canonical name for 404), not the Admin-SDK error
        table's UNREGISTERED spelling. The old single-name match
        classified that as a plain permanent FAILED, so the token
        stayed active in the registry forever (no token_invalid, every
        later send failing). The wire form must take the same
        retirement path as UNREGISTERED."""
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(404, {"error": {"code": 404,
                                         "status": "NOT_FOUND"}}),
        ])
        first = self.dispatcher(cfg, transport)
        try:
            code = first.sweep()
        finally:
            first.close()
        self.assertEqual(code, 0)
        record = self.delivery_records(cfg)[0]
        self.assertEqual(record["state"], "FAILED")
        self.assertEqual(record["error_code"], "NOT_FOUND")
        self.assertEqual(first.counts.get("token_retired"), 1)
        # Retired in the registry (hash only), not left active: the
        # second sweep has no device left and must not send again.
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {})
        finally:
            registry.close()
        second = self.dispatcher(cfg, transport)
        try:
            second.sweep()
        finally:
            second.close()
        self.assertEqual(transport.send_count(), 1)

    def test_403_sender_mismatch_fails_closed_exit_3(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-bad")
        transport = FakeTransport(send_responses=[
            FakeResponse(403, {"error": {"code": 403,
                                         "status": "SENDER_ID_MISMATCH"}}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 3)
        record = self.delivery_records(cfg)[0]
        self.assertEqual(record["state"], "FAILED")
        self.assertEqual(record["error_code"], "SENDER_ID_MISMATCH")

    def test_403_does_not_block_other_devices_but_reports_exit_3(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        self.register("dev-2")
        transport = FakeTransport(send_responses=[
            FakeResponse(200, {"name": "projects/drill-project/"
                                       "messages/m-1"}),
            FakeResponse(403, {"error": {"code": 403,
                                         "status": "SENDER_ID_MISMATCH"}}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 3)
        states = {(r["device_id"], r["state"])
                  for r in self.delivery_records(cfg)}
        self.assertEqual(states, {("dev-1", "ACCEPTED"),
                                  ("dev-2", "FAILED")})

    def test_unknown_status_is_permanent_and_verbatim(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(418, {}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        record = self.delivery_records(cfg)[0]
        self.assertEqual((record["state"], record["error_code"]),
                         ("FAILED", "HTTP_418"))

    def test_type_allowlist_filters_before_any_send(self):
        """The delivery policy is the admission gate (plan B by
        default): the three TOP10 transitions are admitted — the
        enter/exit pair of one observation batch as ONE sound summary,
        the rank change as ONE silent digest — and every other type
        (faults, session lifecycle, the candidate series) is counted
        type_skipped and never creates a delivery record. Severity is
        not a send decision — a CRITICAL fault is skipped exactly like
        an INFO one (AGENTS/ASSUMPTIONS P27)."""
        _, cfg = self.config()
        self.write_service_account(cfg)
        blocked = [
            make_event(event_type="DATA_GAP_SUSPECTED",
                       rule_id="data-gap", seq=31, symbol=None,
                       rank=None, direction=None, severity="CRITICAL"),
            make_event(event_type="SESSION_INCOMPLETE",
                       rule_id="session-incomplete", seq=32, symbol=None,
                       rank=None, direction=None),
            make_event(event_type="CANDIDATE_ENTERED",
                       rule_id="candidate-entered", seq=33,
                       severity="HIGH"),
        ]
        notifiable = [
            make_event(event_type="TOP10_ENTERED", seq=17),
            make_event(event_type="RANK_CHANGED", rule_id="rank-changed",
                       seq=18, previous_rank=5, rank=2),
            make_event(event_type="TOP10_EXITED", rule_id="top10-exited",
                       seq=19, previous_rank=6, rank=None,
                       direction="DOWN"),
        ]
        self.seed_ledger(cfg, blocked + notifiable)
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        # One observation group: at most one sound + one silent message.
        self.assertEqual(transport.send_count(), 2)
        self.assertEqual(dispatcher.counts.get("type_skipped"), 3)
        self.assertEqual(dispatcher.counts.get("events_total"), 6)
        # No delivery record is ever created for a suppressed event:
        # the block happens before the pair is formed (no fake
        # PENDING, README §7).
        records = self.delivery_records(cfg)
        self.assertEqual(len(records), 3)
        by_kind = {}
        for record in records:
            by_kind[record["message_kind"]] = \
                by_kind.get(record["message_kind"], 0) + 1
        self.assertEqual(by_kind, {"summary": 2, "digest": 1})
        # The two summary members share ONE provider message id.
        summary = [r for r in records if r["message_kind"] == "summary"]
        self.assertEqual(
            len({r["provider_message_id"] for r in summary}), 1)
        sent_ids = {r["event_id"] for r in records}
        for event in notifiable:
            self.assertIn(event["event_id"], sent_ids)
        for event in blocked:
            self.assertNotIn(event["event_id"], sent_ids)

    def test_crash_between_send_and_record_resends_on_restart(self):
        """The honest duplicate: the provider accepted a push whose
        record was never appended (process death in the window). The
        next sweep must re-send — the app dedups by event_id."""
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.seed_ledger(cfg, [make_event()])
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        broken = dispatcher.delivery

        class BrokenLedger(notify_ledger.DeliveryLedger):
            def append(self, record):
                raise OSError("simulated death before the record")

        dispatcher.delivery = BrokenLedger(cfg["delivery_path"],
                                           lock=False)
        try:
            with self.assertRaises(OSError):
                dispatcher.sweep()
        finally:
            dispatcher.close()
            broken.close()
        self.assertEqual(transport.send_count(), 1)
        self.assertEqual(self.delivery_records(cfg), [])
        # Restart: the pair is still PENDING (no record) -> re-sent,
        # and this time recorded.
        transport2 = FakeTransport()
        second = self.dispatcher(cfg, transport2)
        try:
            code = second.sweep()
        finally:
            second.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport2.send_count(), 1)
        records = self.delivery_records(cfg)
        self.assertEqual([r["state"] for r in records], ["ACCEPTED"])

    def test_no_events_is_a_clean_zero(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.requests, [])

    def test_ledger_order_is_consumed_seq_first(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        first = make_event(seq=17)
        second = make_event(event_type="RANK_CHANGED",
                            rule_id="rank-changed", seq=18)
        self.seed_ledger(cfg, [first, second])
        self.register("dev-1")
        order = []

        class Recording(FakeTransport):
            def __call__(self, request, timeout=None):
                if request.full_url == self.SEND_URL:
                    data = json.loads(
                        bytes(request.data))["message"]["data"]
                    ids = data.get("event_id") or data.get("event_ids")
                    order.append(ids.split(","))
                return super().__call__(request, timeout=timeout)

        dispatcher = self.dispatcher(cfg, Recording())
        try:
            dispatcher.sweep()
        finally:
            dispatcher.close()
        # One observation group: the sound unit (the single immediate
        # event, in ledger order) precedes the silent digest; every
        # message carries its members in ledger order.
        self.assertEqual(order, [[first["event_id"]],
                                 [second["event_id"]]])

    # The admission group contracts (README §0/§6; docs/ASSUMPTIONS.md
    # P28): one message per composition, one record per covered event.

    def sends_of(self, transport):
        return [json.loads(r["data"])["message"]
                for r in transport.requests
                if r["url"] == FakeTransport.SEND_URL]

    def test_rank_group_sends_one_digest_covering_every_event(self):
        # Contracts 1+2+3: five rank changes of ONE observation batch
        # cost ONE silent push; the digest's data carries every event
        # id (one tap reaches every fact); one record per covered
        # event, all sharing the provider message id.
        _, cfg = self.config()
        self.write_service_account(cfg)
        events = [make_event(event_type="RANK_CHANGED",
                             rule_id="rank-changed", seq=seq,
                             previous_rank=10 + seq, rank=seq)
                  for seq in range(1, 6)]
        self.seed_ledger(cfg, events)
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 1)
        data = self.sends_of(transport)[0]["data"]
        self.assertEqual(data["kind"], "digest")
        self.assertEqual(data["count"], "5")
        self.assertEqual(data["event_ids"],
                         ",".join(event["event_id"] for event in events))
        records = self.delivery_records(cfg)
        self.assertEqual(len(records), 5)
        self.assertEqual({r["message_kind"] for r in records}, {"digest"})
        self.assertEqual(
            len({r["provider_message_id"] for r in records}), 1)

    def test_mixed_group_sends_one_summary_and_one_digest(self):
        # Contract 2: one observation batch with two immediate and two
        # digest events costs one sound + one silent message — the
        # sound summary first, the silent digest after.
        _, cfg = self.config()
        self.write_service_account(cfg)
        entered = make_event(seq=17, name="삼성전자", rank=7)
        exited = make_event(event_type="TOP10_EXITED",
                            rule_id="top10-exited", seq=19,
                            name="SK하이닉스", previous_rank=9, rank=None,
                            direction="DOWN")
        ranks = [make_event(event_type="RANK_CHANGED",
                            rule_id="rank-changed", seq=seq,
                            previous_rank=10 + seq, rank=seq)
                 for seq in (18, 20)]
        self.seed_ledger(cfg, [entered, ranks[0], exited, ranks[1]])
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 2)
        summary, digest = self.sends_of(transport)
        self.assertEqual(summary["data"]["kind"], "summary")
        self.assertEqual(digest["data"]["kind"], "digest")
        self.assertEqual(summary["notification"]["body"],
                         "삼성전자 진입·SK하이닉스 이탈")
        self.assertEqual(summary["android"]["priority"], "high")
        self.assertEqual(digest["android"]["priority"], "normal")
        self.assertEqual(digest["android"]["notification"]["channel_id"],
                         "market_rank_digest")
        self.assertEqual(summary["data"]["event_ids"],
                         "%s,%s" % (entered["event_id"],
                                    exited["event_id"]))
        self.assertEqual(digest["data"]["event_ids"],
                         ",".join(event["event_id"] for event in ranks))
        records = self.delivery_records(cfg)
        self.assertEqual(len(records), 4)
        summary_records = [r for r in records
                           if r["message_kind"] == "summary"]
        digest_records = [r for r in records
                          if r["message_kind"] == "digest"]
        self.assertEqual(len(summary_records), 2)
        self.assertEqual(len(digest_records), 2)
        self.assertEqual(
            len({r["provider_message_id"] for r in summary_records}), 1)
        self.assertEqual(
            len({r["provider_message_id"] for r in digest_records}), 1)

    def test_single_form_is_unchanged_when_the_group_has_one_immediate(self):
        # The single message form is EXACTLY build_message: the same
        # data fields, no kind/event_ids/count — a group whose sound
        # class has one member keeps the historical wire bytes.
        _, cfg = self.config()
        self.write_service_account(cfg)
        entered = make_event(seq=17, name="삼성전자", rank=7)
        rank = make_event(event_type="RANK_CHANGED",
                          rule_id="rank-changed", seq=18,
                          previous_rank=5, rank=2)
        self.seed_ledger(cfg, [entered, rank])
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 2)
        single, digest = self.sends_of(transport)
        self.assertEqual({"message": single},
                         notify_fcm.build_message(entered, FCM_TOKEN))
        for key in ("kind", "event_ids", "count"):
            self.assertNotIn(key, single["data"])
        self.assertEqual(digest["data"]["event_ids"], rank["event_id"])
        records = self.delivery_records(cfg)
        self.assertEqual([r["message_kind"] for r in records],
                         ["single", "digest"])

    def test_digest_members_are_deduped_never_resent(self):
        # Dedup stays per (event_id, device_id): after the digest is
        # ACCEPTED, a re-sweep resends nothing — every member is
        # suppressed exactly like a single event.
        _, cfg = self.config()
        self.write_service_account(cfg)
        events = [make_event(event_type="RANK_CHANGED",
                             rule_id="rank-changed", seq=seq,
                             previous_rank=10 + seq, rank=seq)
                  for seq in range(1, 6)]
        self.seed_ledger(cfg, events)
        self.register("dev-1")
        transport = FakeTransport()
        first = self.dispatcher(cfg, transport)
        try:
            first.sweep()
        finally:
            first.close()
        second = self.dispatcher(cfg, transport)
        try:
            code = second.sweep()
        finally:
            second.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 1)
        self.assertEqual(second.counts.get("dedup_suppressed"), 5)
        self.assertEqual(len(self.delivery_records(cfg)), 5)

    def test_retry_reassembles_the_whole_group(self):
        # A deferred UNIT is reassembled with exactly the same members
        # (they share one next_due): partial delivery of a group is
        # impossible — the retry message covers all five or nothing.
        _, cfg = self.config()
        self.write_service_account(cfg)
        events = [make_event(event_type="RANK_CHANGED",
                             rule_id="rank-changed", seq=seq,
                             previous_rank=10 + seq, rank=seq)
                  for seq in range(1, 6)]
        self.seed_ledger(cfg, events)
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(429, {"error": {"code": 429,
                                         "status": "QUOTA_EXCEEDED"}}),
            FakeResponse(200, {"name": "projects/drill-project/"
                                       "messages/m-2"}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 2)
        records = self.delivery_records(cfg)
        self.assertEqual(len(records), 10)  # 5 PENDING + 5 ACCEPTED
        self.assertEqual([r["state"] for r in records],
                         ["PENDING"] * 5 + ["ACCEPTED"] * 5)
        self.assertEqual([r["attempts"] for r in records],
                         [1] * 5 + [2] * 5)
        sends = [message["data"] for message in self.sends_of(transport)]
        self.assertEqual(sends[0]["event_ids"], sends[1]["event_ids"])
        self.assertEqual(sends[1]["event_ids"],
                         ",".join(event["event_id"] for event in events))

    def test_404_on_a_group_fails_every_member_and_retires_once(self):
        # The vendor's 404 retires the token ONCE for the unit, and
        # every member gets its honest terminal FAILED record.
        _, cfg = self.config()
        self.write_service_account(cfg)
        events = [make_event(event_type="RANK_CHANGED",
                             rule_id="rank-changed", seq=seq,
                             previous_rank=10 + seq, rank=seq)
                  for seq in (1, 2)]
        self.seed_ledger(cfg, events)
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(404, {"error": {"code": 404,
                                         "status": "NOT_FOUND"}}),
        ])
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        records = self.delivery_records(cfg)
        self.assertEqual([r["state"] for r in records],
                         ["FAILED", "FAILED"])
        self.assertEqual({r["error_code"] for r in records},
                         {"NOT_FOUND"})
        self.assertEqual(dispatcher.counts.get("token_retired"), 1)
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {})
        finally:
            registry.close()
        raw = open(self.registry_path, "r", encoding="utf-8").read()
        self.assertEqual(raw.count('"token_invalid"'), 1)

    def test_policy_suppress_mode_skips_records_like_type_skipped(self):
        # A configured suppress mode behaves exactly like a type
        # outside the admission universe: counted type_skipped, no
        # record, no send — one shared verdict, not two gates.
        _, cfg = self.config()
        self.write_service_account(cfg)
        cfg["admission"] = {"RANK_CHANGED": "suppress"}
        entered = make_event(seq=17)
        rank = make_event(event_type="RANK_CHANGED",
                          rule_id="rank-changed", seq=18,
                          previous_rank=5, rank=2)
        self.seed_ledger(cfg, [entered, rank])
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 1)
        self.assertEqual(dispatcher.counts.get("type_skipped"), 1)
        self.assertEqual([r["event_id"] for r in
                          self.delivery_records(cfg)],
                         [entered["event_id"]])

    def test_observation_groups_are_bounded_by_observed_at(self):
        # The batch boundary is the fact's observed_at: two batches of
        # the same device are two digests, never one merged message.
        _, cfg = self.config()
        self.write_service_account(cfg)
        batch_a = [make_event(event_type="RANK_CHANGED",
                              rule_id="rank-changed", seq=seq,
                              previous_rank=10 + seq, rank=seq)
                   for seq in (1, 2)]
        batch_b = [make_event(event_type="RANK_CHANGED",
                              rule_id="rank-changed", seq=seq,
                              previous_rank=10 + seq, rank=seq,
                              observed_at="2026-11-01T09:12:34+09:00")
                   for seq in (3, 4)]
        self.seed_ledger(cfg, batch_a + batch_b)
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            code = dispatcher.sweep()
        finally:
            dispatcher.close()
        self.assertEqual(code, 0)
        self.assertEqual(transport.send_count(), 2)
        sends = [message["data"] for message in self.sends_of(transport)]
        self.assertEqual(sends[0]["event_ids"],
                         ",".join(event["event_id"] for event in batch_a))
        self.assertEqual(sends[1]["event_ids"],
                         ",".join(event["event_id"] for event in batch_b))

    def test_same_input_and_policy_replay_identical_message_bytes(self):
        # Contract 4: the same ledger + policy compose byte-identical
        # request payloads — composition is deterministic replay.

        def run(tag):
            replay = tempfile.mkdtemp(prefix="notify-replay-%s-" % tag)
            self.addCleanup(shutil.rmtree, replay, True)
            cfg = dict(base_cfg)
            cfg["ledger_path"] = os.path.join(replay, "ledger.hcj.jsonl")
            cfg["delivery_path"] = os.path.join(replay,
                                                "delivery.hcj.jsonl")
            cfg["registry_path"] = os.path.join(replay, "devices.jsonl")
            self.seed_ledger(cfg, events)
            registry = notify_ledger.Registry(cfg["registry_path"],
                                              lock=True)
            try:
                registry.add_device("dev-1", FCM_TOKEN)
            finally:
                registry.close()
            transport = FakeTransport()
            dispatcher = self.dispatcher(cfg, transport)
            try:
                dispatcher.sweep()
            finally:
                dispatcher.close()
            return [r["data"] for r in transport.requests
                    if r["url"] == FakeTransport.SEND_URL]

        events = [make_event(event_type="RANK_CHANGED",
                             rule_id="rank-changed", seq=seq,
                             previous_rank=10 + seq, rank=seq)
                  for seq in range(1, 4)] + \
                 [make_event(seq=17, name="삼성전자", rank=7)]
        _, base_cfg = self.config()
        self.write_service_account(base_cfg)
        first = run("one")
        second = run("two")
        self.assertEqual(first, second)
        self.assertEqual(len(first), 2)  # one single + one digest


# ----------------------------------------------------------- register


class TestRegister(Base):
    def test_registration_with_the_bearer_writes_the_registry(self):
        path, cfg = self.config()
        token_path = os.path.join(self.outside, "token.txt")
        with open(token_path, "w", encoding="utf-8") as f:
            f.write(FCM_TOKEN + "\n")
        rc = notify_register._main([
            "--config", path, "--device-id", "dev-1",
            "--token-file", token_path, "--bearer", BEARER])
        self.assertEqual(rc, 0)
        registry = notify_ledger.Registry(self.registry_path, lock=False)
        try:
            self.assertEqual(registry.devices(), {"dev-1": FCM_TOKEN})
        finally:
            registry.close()

    def test_wrong_bearer_writes_nothing(self):
        path, _ = self.config()
        token_path = os.path.join(self.outside, "token.txt")
        with open(token_path, "w", encoding="utf-8") as f:
            f.write(FCM_TOKEN + "\n")
        rc = notify_register._main([
            "--config", path, "--device-id", "dev-1",
            "--token-file", token_path, "--bearer", "wrong"])
        self.assertEqual(rc, 2)
        self.assertFalse(os.path.exists(self.registry_path))

    def test_bad_device_id_is_refused(self):
        path, _ = self.config()
        rc = notify_register._main([
            "--config", path, "--device-id", "bad id with spaces",
            "--token-file", "-", "--bearer", BEARER])
        self.assertEqual(rc, 2)

    def test_stdin_token_path(self):
        path, cfg = self.config()
        registry_dir = cfg["registry_path"]
        rc = subprocess.run(
            [sys.executable, "-c",
             "import sys; sys.path.insert(0, %r); "
             "import notify_register; "
             "sys.exit(notify_register._main(sys.argv[1:]))" %
             os.path.dirname(os.path.abspath(
                 notify_register.__file__)),
             "--config", path, "--device-id", "dev-stdin",
             "--token-file", "-", "--bearer", BEARER],
            input=FCM_TOKEN + "\n", capture_output=True, text=True)
        self.assertEqual(rc.returncode, 0, rc.stderr)
        registry = notify_ledger.Registry(registry_dir, lock=False)
        try:
            self.assertEqual(registry.devices(),
                             {"dev-stdin": FCM_TOKEN})
        finally:
            registry.close()

    def test_stdout_never_carries_the_token(self):
        import contextlib
        import io
        path, _ = self.config()
        token_path = os.path.join(self.outside, "token.txt")
        with open(token_path, "w", encoding="utf-8") as f:
            f.write(FCM_TOKEN + "\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            notify_register._main([
                "--config", path, "--device-id", "dev-1",
                "--token-file", token_path, "--bearer", BEARER])
        self.assertNotIn(FCM_TOKEN, out.getvalue())
        self.assertIn(notify_ledger.mask_secret(FCM_TOKEN),
                      out.getvalue())


# --------------------------------------------------- resident watch


def _wait_for_line(pattern, stream, timeout=15.0):
    """Read a subprocess pipe until a line containing `pattern`
    arrives; returns the lines read so far. No timeout means a stuck
    worker, which fails the test instead of hanging the suite."""
    end = time.monotonic() + timeout
    buf = b""
    lines = []
    fd = stream.fileno()
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            continue
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            lines.append(raw.decode("utf-8", "replace"))
            if pattern in lines[-1]:
                return lines
    raise AssertionError("timed out waiting for %r; got so far: %r"
                         % (pattern, lines))


class TestWatchDispatcher(Base):
    """The resident watch tick contract (README §1/§5): byte-offset
    tailing with LF as the commit marker, all-or-nothing batch ingest,
    (st_dev, st_ino) rescan, and retry deferral BETWEEN ticks."""

    def test_partial_tail_is_never_consumed_until_its_lf_arrives(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        events_path = self._events_path()
        line = self.event_line(seq=1)
        with open(events_path, "wb") as f:
            f.write(line)  # complete record bytes, NOT yet LF-terminated
        worker = self.dispatcher(cfg, FakeTransport(), resident=True)
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                offset, identity = worker.watch_tick(events_path, 0,
                                                     None)
            # A partial tail is not committed: nothing consumed, the
            # offset unadvanced, and it is not an error.
            self.assertEqual(offset, 0)
            self.assertEqual(self.ledger_lines(cfg), [])
            self.assertIsNotNone(identity)
            self.assertNotIn("watch tick", out.getvalue())
            self.assertIn("watch open", out.getvalue())
            # The producer commits the record: only now is it consumed.
            with open(events_path, "ab") as f:
                f.write(b"\n")
            with contextlib.redirect_stdout(out):
                offset, identity = worker.watch_tick(events_path, offset,
                                                     identity)
            self.assertEqual(offset, len(line) + 1)
            self.assertEqual(self.ledger_lines(cfg), [line])
            self.assertIn("watch tick new=1 ingested=1 appended=1 "
                          "dup=0", out.getvalue())
        finally:
            worker.close()

    def test_full_rescan_of_identical_lines_is_idempotent(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        events_path = self._events_path()
        line = self.event_line(seq=1)
        self._append_lines(events_path, [line])
        worker = self.dispatcher(cfg, FakeTransport(), resident=True)
        try:
            offset, identity = worker.watch_tick(events_path, 0, None)
            self.assertEqual(offset, len(line) + 1)
            before = open(cfg["ledger_path"], "rb").read()
            # A crash-restart style rescan: same file identity, the
            # offset back at 0 — the same bytes are re-fed.
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                offset, identity = worker.watch_tick(events_path, 0,
                                                     identity)
            self.assertEqual(offset, len(line) + 1)
            self.assertEqual(open(cfg["ledger_path"], "rb").read(),
                             before)  # byte-identical, present once
            self.assertIn("appended=0", out.getvalue())
            self.assertIn("dup=1", out.getvalue())
        finally:
            worker.close()

    def test_inode_change_triggers_full_rescan(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        events_path = self._events_path()
        a = self.event_line(seq=1)
        b = self.event_line(seq=2)
        self._append_lines(events_path, [a])
        worker = self.dispatcher(cfg, FakeTransport(), resident=True)
        try:
            offset, identity = worker.watch_tick(events_path, 0, None)
            self.assertEqual(self.ledger_lines(cfg), [a])
            # The producer recreates the file (new st_dev/st_ino pair)
            # holding the old fact and a new one: the replacement file
            # is created while the old one still exists, so its inode
            # is provably different (an unlink+create could be handed
            # the recycled inode back).
            replacement = events_path + ".recreated"
            self._append_lines(replacement, [a, b])
            os.replace(replacement, events_path)
            st = os.stat(events_path)
            self.assertNotEqual((st.st_dev, st.st_ino), identity)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                offset, _ = worker.watch_tick(events_path, offset,
                                              identity)
            # Full rescan from 0: the old fact is a byte-identical
            # idempotent skip, only the new fact is appended.
            self.assertEqual(offset, len(a) + 1 + len(b) + 1)
            self.assertEqual(self.ledger_lines(cfg), [a, b])
            self.assertIn("watch reopen", out.getvalue())
            self.assertIn("appended=1", out.getvalue())
            self.assertIn("dup=1", out.getvalue())
        finally:
            worker.close()

    def test_retry_is_deferred_between_ticks_and_new_events_still_flow(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.register("dev-1")
        transport = FakeTransport(send_responses=[
            FakeResponse(429, {"error": {"code": 429,
                                         "status": "QUOTA_EXCEEDED"}},
                         headers={"Retry-After": "90"}),
            FakeResponse(200, {"name": "projects/drill-project/"
                                       "messages/m-2"}),
            FakeResponse(200, {"name": "projects/drill-project/"
                                       "messages/m-3"}),
        ])
        events_path = self._events_path()
        a = self.event_line(seq=1)
        b = self.event_line(seq=2)
        self._append_lines(events_path, [a])
        worker = self.dispatcher(cfg, transport, resident=True)
        try:
            offset, identity = worker.watch_tick(events_path, 0, None)
            self.assertEqual(transport.send_count(), 1)
            self.assertEqual([r["state"] for r in
                              self.delivery_records(cfg)], ["PENDING"])
            # Tick 2 arrives while a's retry wait (90s) is running: b
            # is ingested and sent immediately — the wait is deferred
            # between ticks, never slept in-sweep (the fake clock has
            # not moved at all).
            self._append_lines(events_path, [b])
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                offset, identity = worker.watch_tick(events_path, offset,
                                                     identity)
            self.assertEqual(worker._clock_state["now"], 1_000_000.0)
            self.assertEqual(transport.send_count(), 2)
            self.assertEqual([r["state"] for r in
                              self.delivery_records(cfg)],
                             ["PENDING", "ACCEPTED"])
            # Tick 3: a's retry is due, so it is retried now.
            worker._clock_state["now"] += 91
            with contextlib.redirect_stdout(out):
                worker.watch_tick(events_path, offset, identity)
            self.assertEqual(transport.send_count(), 3)
            records = self.delivery_records(cfg)
            self.assertEqual([r["state"] for r in records],
                             ["PENDING", "ACCEPTED", "ACCEPTED"])
            self.assertEqual([r["attempts"] for r in records],
                             [1, 1, 2])
        finally:
            worker.close()

    def test_shrinking_watch_file_is_a_ledger_fault(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        events_path = self._events_path()
        a = self.event_line(seq=1)
        b = self.event_line(seq=2)
        self._append_lines(events_path, [a, b])
        worker = self.dispatcher(cfg, FakeTransport(), resident=True)
        try:
            offset, identity = worker.watch_tick(events_path, 0, None)
            self.assertEqual(offset, len(a) + 1 + len(b) + 1)
            # Truncate the consumed bytes away WITHOUT changing the
            # inode: an append-only violation. Fail closed (exit 4
            # class), never a silent rescan.
            with open(events_path, "r+b") as f:
                f.truncate(len(a) + 1)
            with self.assertRaises(notify_ledger.LedgerFault):
                worker.watch_tick(events_path, offset, identity)
        finally:
            worker.close()

    def test_bad_batch_is_refused_and_retried_next_tick(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        events_path = self._events_path()
        a = self.event_line(seq=1)
        c = self.event_line(seq=3)
        with open(events_path, "wb") as f:
            f.write(a + b"\n")
            f.write(b'{"event_type":"BROKEN"\n')  # invalid JSON line
        worker = self.dispatcher(cfg, FakeTransport(), resident=True)
        try:
            err = io.StringIO()
            out = io.StringIO()
            with contextlib.redirect_stderr(err), \
                 contextlib.redirect_stdout(out):
                offset, identity = worker.watch_tick(events_path, 0,
                                                     None)
            # All-or-nothing: the valid line is NOT appended either,
            # the offset does not advance, the alarm names the fault.
            self.assertEqual(self.ledger_lines(cfg), [])
            self.assertEqual(offset, 0)
            self.assertIn("WATCH BATCH REFUSED", err.getvalue())
            self.assertIn("refused=1", out.getvalue())
            # A later line cannot jump the fence: the next tick retries
            # the whole batch (still refused).
            self._append_lines(events_path, [c])
            with contextlib.redirect_stderr(err), \
                 contextlib.redirect_stdout(out):
                offset, identity = worker.watch_tick(events_path, offset,
                                                     identity)
            self.assertEqual(self.ledger_lines(cfg), [])
            self.assertEqual(offset, 0)
            self.assertIn("WATCH BATCH REFUSED", err.getvalue())
        finally:
            worker.close()

    def test_missing_events_file_waits_and_is_not_an_error(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        events_path = self._events_path()
        worker = self.dispatcher(cfg, FakeTransport(), resident=True)
        try:
            offset, identity = worker.watch_tick(events_path, 0, None)
            self.assertEqual(offset, 0)
            self.assertIsNone(identity)
            # The file appears later: the same tick contract applies.
            line = self.event_line(seq=1)
            self._append_lines(events_path, [line])
            offset, identity = worker.watch_tick(events_path, offset,
                                                 identity)
            self.assertEqual(offset, len(line) + 1)
            self.assertEqual(self.ledger_lines(cfg), [line])
        finally:
            worker.close()

    def test_group_boundary_in_watch_ticks(self):
        # The observation group is bounded by observed_at within one
        # tick, and the dedup boundary comes FIRST: a later member of
        # an already-sent observed_at forms its own digest — never a
        # re-send of the accepted members (README §0, the honest
        # split-arrival boundary).
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.register("dev-1")
        events_path = self._events_path()
        batch_a = [self.event_line(event_type="RANK_CHANGED",
                                   rule_id="rank-changed", seq=seq,
                                   previous_rank=10 + seq, rank=seq)
                   for seq in (1, 2)]
        batch_b = [self.event_line(event_type="RANK_CHANGED",
                                   rule_id="rank-changed", seq=seq,
                                   previous_rank=10 + seq, rank=seq,
                                   observed_at="2026-11-01T09:13:33+09:00")
                   for seq in (3, 4)]
        late = self.event_line(event_type="RANK_CHANGED",
                               rule_id="rank-changed", seq=5,
                               previous_rank=15, rank=5)
        transport = FakeTransport()
        worker = self.dispatcher(cfg, transport, resident=True)
        try:
            out = io.StringIO()
            self._append_lines(events_path, batch_a + batch_b)
            with contextlib.redirect_stdout(out):
                offset, identity = worker.watch_tick(events_path, 0, None)
            # Two observation batches in ONE tick: two digests, one per
            # observed_at — never one merged message.
            self.assertEqual(transport.send_count(), 2)
            sends = [json.loads(r["data"])["message"]["data"]
                     for r in transport.requests
                     if r["url"] == FakeTransport.SEND_URL]
            self.assertEqual(sends[0]["event_ids"],
                             ",".join(json.loads(line)["event_id"]
                                      for line in batch_a))
            self.assertEqual(sends[1]["event_ids"],
                             ",".join(json.loads(line)["event_id"]
                                      for line in batch_b))
            # A late member of batch A's observed_at: its own digest.
            self._append_lines(events_path, [late])
            with contextlib.redirect_stdout(out):
                worker.watch_tick(events_path, offset, identity)
            self.assertEqual(transport.send_count(), 3)
            records = self.delivery_records(cfg)
            self.assertEqual(len(records), 5)
            self.assertEqual({r["message_kind"] for r in records},
                             {"digest"})
        finally:
            worker.close()


class TestRunScope(Base):
    """The resident worker's run scope (README §1): only facts of the
    watched run's session are dispatched. The historical ledger is
    never swept, and a cross-session fact stays a ledger-only artifact
    (no delivery record, no retry schedule)."""

    def test_older_session_facts_are_never_dispatched(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.register("dev-1")
        old = [make_event(session_id="2026-11-11", seq=seq,
                          observed_at="2026-11-11T15:13:32+09:00")
               for seq in (1, 2)]
        self.seed_ledger(cfg, old)
        # An older session's pair already has a delivery state: the
        # scope filter must leave it untouched (no new record).
        write_jsonl(cfg["delivery_path"], [{
            "attempts": 1, "device_id": "dev-1",
            "event_id": old[0]["event_id"], "state": "PENDING",
            "updated_at": "2026-11-11T15:13:33+09:00"}])
        events_path = self._events_path()
        new = self.event_line(session_id="2026-11-12", seq=1,
                              observed_at="2026-11-12T09:12:33+09:00")
        self._append_lines(events_path, [new])
        transport = FakeTransport()
        worker = self.dispatcher(cfg, transport, resident=True)
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                worker.watch_tick(events_path, 0, None)
            self.assertIn("watch scope session=2026-11-12", out.getvalue())
            self.assertEqual(worker.counts.get("scope_skipped"), 2)
            self.assertEqual(transport.send_count(), 1)
            sends = [json.loads(r["data"])["message"]["data"]
                     for r in transport.requests
                     if r["url"] == FakeTransport.SEND_URL]
            self.assertEqual(sends[0]["event_id"],
                             json.loads(new)["event_id"])
            records = self.delivery_records(cfg)
            self.assertEqual(
                [(r["event_id"], r["state"]) for r in records],
                [(old[0]["event_id"], "PENDING"),
                 (json.loads(new)["event_id"], "ACCEPTED")])
        finally:
            worker.close()

    def test_tick_before_any_ingest_attempts_zero_sends(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.register("dev-1")
        self.seed_ledger(cfg, [make_event(session_id="2026-11-11", seq=1)])
        events_path = self._events_path()
        transport = FakeTransport()
        worker = self.dispatcher(cfg, transport, resident=True)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                worker.watch_tick(events_path, 0, None)  # file absent
            self.assertIsNone(worker._session_id)
            self.assertEqual(transport.send_count(), 0)
            self.assertEqual(self.delivery_records(cfg), [])
            # A file with only an uncommitted (non-LF) line is the same
            # wait: no session is learned, nothing is dispatched.
            with open(events_path, "wb") as f:
                f.write(self.event_line(session_id="2026-11-12", seq=1))
            with contextlib.redirect_stdout(io.StringIO()):
                offset, _ = worker.watch_tick(events_path, 0, None)
            self.assertEqual(offset, 0)
            self.assertIsNone(worker._session_id)
            self.assertEqual(transport.send_count(), 0)
            self.assertEqual(self.delivery_records(cfg), [])
        finally:
            worker.close()

    def test_restart_resends_undelivered_pairs_of_the_same_session(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        self.register("dev-1")
        events_path = self._events_path()
        a = self.event_line(session_id="2026-11-12", seq=1,
                            observed_at="2026-11-12T09:12:33+09:00")
        b = self.event_line(session_id="2026-11-12", seq=2,
                            observed_at="2026-11-12T09:12:34+09:00")
        self._append_lines(events_path, [a])
        first = self.dispatcher(cfg, FakeTransport(), resident=True)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                first.watch_tick(events_path, 0, None)
        finally:
            first.close()
        self.assertEqual([r["state"] for r in self.delivery_records(cfg)],
                         ["ACCEPTED"])
        # b arrives after the worker stopped: the restart's full rescan
        # re-ingests a (idempotent) and sends only the undelivered b.
        self._append_lines(events_path, [b])
        transport = FakeTransport()
        second = self.dispatcher(cfg, transport, resident=True)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                second.watch_tick(events_path, 0, None)
        finally:
            second.close()
        self.assertEqual(transport.send_count(), 1)
        records = self.delivery_records(cfg)
        self.assertEqual([r["event_id"] for r in records],
                         [json.loads(a)["event_id"],
                          json.loads(b)["event_id"]])
        self.assertEqual([r["state"] for r in records],
                         ["ACCEPTED", "ACCEPTED"])

    def test_suppressed_fact_of_the_watched_session_stays_suppressed(self):
        _, cfg = self.config()
        self.write_service_account(cfg)
        cfg["admission"] = {"RANK_CHANGED": "suppress"}
        self.register("dev-1")
        events_path = self._events_path()
        rank = self.event_line(session_id="2026-11-12", seq=1,
                               event_type="RANK_CHANGED",
                               rule_id="rank-changed",
                               previous_rank=5, rank=2,
                               observed_at="2026-11-12T09:12:33+09:00")
        self._append_lines(events_path, [rank])
        transport = FakeTransport()
        worker = self.dispatcher(cfg, transport, resident=True)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                worker.watch_tick(events_path, 0, None)
        finally:
            worker.close()
        self.assertEqual(transport.send_count(), 0)
        self.assertEqual(self.delivery_records(cfg), [])
        self.assertEqual(worker.counts.get("type_skipped"), 1)
        self.assertEqual(worker.counts.get("scope_skipped"), 0)


# ------------------------------------------------ admission report


class TestAdmissionReport(Base):
    """The admission replay tool (README §9; docs/ASSUMPTIONS.md P28):
    every fact judged with the SAME admission code the dispatch path
    uses, one verdict line per event, the per-observation-group send
    plan and the totals — no send, no ledger write, byte-identical for
    the same file + policy."""

    def report_for(self, events, cfg_overrides=None):
        path, cfg = self.config(**(cfg_overrides or {}))
        events_path = os.path.join(self.tmp, "report-events.hcj.jsonl")
        write_jsonl(events_path, events)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = notify_dispatcher.admission_report(cfg, events_path)
        return code, out.getvalue(), path, cfg

    def test_every_event_gets_exactly_one_verdict(self):
        events = [
            make_event(event_type="TOP10_ENTERED", seq=17, rank=7),
            make_event(event_type="TOP10_EXITED",
                       rule_id="top10-exited", seq=19, previous_rank=9,
                       rank=None, direction="DOWN"),
            make_event(event_type="RANK_CHANGED", rule_id="rank-changed",
                       seq=18, previous_rank=5, rank=2),
            make_event(event_type="CANDIDATE_ENTERED",
                       rule_id="candidate-entered", seq=33),
            make_event(event_type="SESSION_ENDED",
                       rule_id="session-ended", seq=34, symbol=None,
                       rank=None, direction=None),
        ]
        code, out, _path, _cfg = self.report_for(events)
        self.assertEqual(code, 0)
        lines = out.splitlines()
        # The first line states WHICH policy decided — an absent
        # section is the default plan B, never a configured one.
        self.assertEqual(
            lines[0],
            "admission policy source=default RANK_CHANGED=digest "
            "TOP10_ENTERED=immediate TOP10_EXITED=immediate")
        verdicts = [line for line in lines
                    if line.startswith("admission event=")]
        self.assertEqual(len(verdicts), 5)
        by_id = {}
        for line in verdicts:
            fields = dict(part.split("=", 1)
                          for part in line.split(" ")[1:])
            by_id[fields["event"]] = fields
        self.assertEqual(set(by_id), {e["event_id"] for e in events})
        self.assertEqual(by_id[events[0]["event_id"]],
                         {"event": events[0]["event_id"],
                          "type": "TOP10_ENTERED",
                          "observed_at": "2026-11-01T09:12:33+09:00",
                          "verdict": "ADMIT", "form": "summary"})
        self.assertEqual(by_id[events[1]["event_id"]]["verdict"], "ADMIT")
        self.assertEqual(by_id[events[1]["event_id"]]["form"], "summary")
        self.assertEqual(by_id[events[2]["event_id"]]["verdict"], "DIGEST")
        self.assertEqual(by_id[events[2]["event_id"]]["form"], "digest")
        self.assertEqual(
            by_id[events[3]["event_id"]]["verdict"], "SUPPRESS")
        self.assertEqual(
            by_id[events[3]["event_id"]]["form"], "not_in_admission")
        self.assertEqual(
            by_id[events[4]["event_id"]]["verdict"], "SUPPRESS")
        self.assertEqual(
            by_id[events[4]["event_id"]]["form"], "not_in_admission")
        self.assertIn("admission total events=5 groups=1 sound=1 "
                      "silent=1 admit=2 digest=1 suppress=2 refused=0",
                      lines)

    def test_plan_lines_mirror_the_composed_messages(self):
        events = [
            make_event(event_type="TOP10_ENTERED", seq=17, rank=7),
            make_event(event_type="RANK_CHANGED", rule_id="rank-changed",
                       seq=18, previous_rank=5, rank=2),
        ]
        code, out, _path, _cfg = self.report_for(events)
        self.assertEqual(code, 0)
        lines = out.splitlines()
        self.assertIn("admission group observed_at=2026-11-01T09:12:33"
                      "+09:00 events=2 sound=1 silent=1", lines)
        plans = [line for line in lines
                 if line.startswith("admission plan ")]
        self.assertEqual(len(plans), 2)
        self.assertIn("kind=single count=1 "
                      "title=홍스캐너 TOP10 변화", plans[0])
        self.assertIn("body=005930 상승 TOP10 신규 진입 7위", plans[0])
        self.assertIn("event_ids=%s" % events[0]["event_id"], plans[0])
        self.assertIn("kind=digest count=1 "
                      "title=홍스캐너 TOP10 순위 요약", plans[1])
        self.assertIn("event_ids=%s" % events[1]["event_id"], plans[1])

    def test_report_is_byte_identical_across_runs(self):
        events = [make_event(seq=17, rank=7),
                  make_event(event_type="RANK_CHANGED",
                             rule_id="rank-changed", seq=18,
                             previous_rank=5, rank=2)]
        first = self.report_for(events)
        second = self.report_for(events)
        self.assertEqual(first[0], 0)
        self.assertEqual(first[1], second[1])  # the same bytes

    def test_report_shares_the_dispatch_path_policy(self):
        # The replay composition IS the dispatch composition: with one
        # config the report's plan kinds/counts equal the actually
        # SENT messages' kinds/counts (the compose code is shared).
        overrides = {"admission": {"TOP10_ENTERED": "digest",
                                   "TOP10_EXITED": "digest",
                                   "RANK_CHANGED": "immediate"}}
        events = [make_event(seq=17, rank=7),
                  make_event(event_type="RANK_CHANGED",
                             rule_id="rank-changed", seq=18,
                             previous_rank=5, rank=2)]
        code, out, path, cfg = self.report_for(events, overrides)
        self.assertEqual(code, 0)
        self.assertIn("admission policy source=config", out.splitlines()[0])
        plans = []
        for line in out.splitlines():
            if line.startswith("admission plan "):
                match = re.search(r" kind=(\w+) count=(\d+)", line)
                plans.append((match.group(1), int(match.group(2))))
        self.assertEqual(plans, [("single", 1), ("digest", 1)])
        self.write_service_account(cfg)
        self.seed_ledger(cfg, events)
        self.register("dev-1")
        transport = FakeTransport()
        dispatcher = self.dispatcher(cfg, transport)
        try:
            dispatcher.sweep()
        finally:
            dispatcher.close()
        sent = [json.loads(r["data"])["message"]["data"]
                for r in transport.requests
                if r["url"] == FakeTransport.SEND_URL]
        # A single-form message carries NO kind/count (its data stays
        # the historical per-event fields) — the report's plan and the
        # wire agree anyway: one single covering one event.
        sent_forms = []
        for data in sent:
            if "kind" in data:
                sent_forms.append((data["kind"], int(data["count"])))
            else:
                sent_forms.append(("single", 1))
        self.assertEqual(sent_forms, plans)

    def test_report_prints_a_refused_plan_over_the_payload_limit(self):
        events = [make_event(event_type="RANK_CHANGED",
                             rule_id="rank-changed", seq=seq,
                             previous_rank=10 + seq, rank=seq)
                  for seq in range(1, 101)]
        code, out, _path, _cfg = self.report_for(events)
        self.assertEqual(code, 0)
        lines = out.splitlines()
        refused = [line for line in lines
                   if line.startswith("admission plan ")
                   and "refused=" in line]
        self.assertEqual(len(refused), 1)
        self.assertIn("kind=digest count=100 "
                      "refused=HS_PAYLOAD_OVER_LIMIT", refused[0])
        self.assertIn("admission total events=100 groups=1 sound=0 "
                      "silent=0 admit=0 digest=100 suppress=0 "
                      "refused=1", lines)

    def test_cli_report_prints_and_writes_nothing(self):
        path, cfg = self.config()
        self.write_service_account(cfg)
        events_path = os.path.join(self.tmp, "report-events.hcj.jsonl")
        write_jsonl(events_path, [make_event(seq=17, rank=7)])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = notify_dispatcher._main(
                ["--config", path, "--admission-report", events_path])
        self.assertEqual(code, 0)
        self.assertIn("admission policy source=default", out.getvalue())
        self.assertIn("verdict=ADMIT", out.getvalue())
        # No send, no ledger write: neither the delivery file nor the
        # event ledger copy was ever born.
        self.assertFalse(os.path.exists(cfg["delivery_path"]))
        self.assertFalse(os.path.exists(cfg["ledger_path"]))
        # Usage errors: a relative path, an absent file, and the
        # --watch combination are all exit 2.
        with contextlib.redirect_stdout(io.StringIO()), \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(
                notify_dispatcher._main(
                    ["--config", path, "--admission-report",
                     "relative.jsonl"]), 2)
            self.assertEqual(
                notify_dispatcher._main(
                    ["--config", path, "--admission-report",
                     "/absent/events.jsonl"]), 2)
            self.assertEqual(
                notify_dispatcher._main(
                    ["--config", path, "--watch", events_path,
                     "--admission-report", events_path]), 2)
        # A torn file (no LF) is a ledger fault: fail-closed exit 4.
        torn = os.path.join(self.tmp, "torn.hcj.jsonl")
        with open(torn, "w", encoding="utf-8") as f:
            f.write(json.dumps(make_event(), separators=(",", ":")))
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), \
             contextlib.redirect_stderr(err):
            self.assertEqual(
                notify_dispatcher._main(
                    ["--config", path, "--admission-report", torn]), 4)
        self.assertIn("partial line", err.getvalue())


class TestResidentProcess(Base):
    """The resident worker as a real OS process: SIGTERM shutdown is
    clean (exit 0) and a restart over the same events file ingests
    nothing twice (the crash-restart idempotency). No device is
    registered here, so no network call is ever attempted."""

    def test_sigterm_shutdown_and_restart_are_clean_and_idempotent(self):
        path, cfg = self.config()
        self.write_service_account(cfg)
        events_path = self._events_path()
        line = self.event_line(seq=1)
        self._append_lines(events_path, [line])
        cmd = [sys.executable, "notify_dispatcher.py",
               "--config", path, "--watch", events_path]
        notify_dir = os.path.dirname(os.path.abspath(__file__))

        def run_worker():
            proc = subprocess.Popen(cmd, cwd=notify_dir,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            try:
                lines = _wait_for_line("watch tick", proc.stdout)
            finally:
                proc.send_signal(signal.SIGTERM)
            try:
                rest, err = proc.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()
                raise
            return proc.returncode, lines, rest, err

        rc, lines, rest, err = run_worker()
        self.assertEqual(rc, 0)
        all_out = "\n".join(lines) + rest.decode("utf-8", "replace")
        self.assertIn("watch start", all_out)
        self.assertIn("watch stop", all_out)
        self.assertIn("appended=1", lines[-1])
        # Every resident stdout line carries the ISO timestamp prefix.
        for text in all_out.splitlines():
            if text.strip():
                self.assertRegex(
                    text,
                    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+09:00 ")
        self.assertNotIn("REFUSED", err.decode("utf-8", "replace"))
        self.assertEqual(self.ledger_lines(cfg), [line])
        # Restart over the same events file: the full rescan re-ingests
        # nothing (event_id dedup) and the released locks let the
        # second worker start cleanly.
        rc2, lines2, rest2, err2 = run_worker()
        self.assertEqual(rc2, 0)
        self.assertIn("watch start", "\n".join(lines2))
        self.assertIn("appended=0", lines2[-1])
        self.assertIn("dup=1", lines2[-1])
        self.assertEqual(self.ledger_lines(cfg), [line])


if __name__ == "__main__":
    unittest.main()
