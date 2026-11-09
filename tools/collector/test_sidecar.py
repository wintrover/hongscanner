#!/usr/bin/env python3
"""sidecar contract tests (tools/collector/README.md §0-§8).

The real sidecar state machine (sidecar.py) runs in-process against a
fake core pipe (queue-backed stdin, captured stdout) and a fake
websockets module: no live API call, no real network, no credential
value ever printed. The token path is exercised through the real
TokenStore with a seeded local token cache and a fake `kiwoomcli`
executable on PATH, so the subprocess boundary is the real one and only
the credential values are fixtures. The token_source="env" path
(README §5.1) runs against a real local HTTP server on 127.0.0.1 (an
ephemeral port) with the endpoint injected through the provider
constructor — likewise no live API call.

Run: bash tools/collector/test_sidecar.sh — it resolves a Python 3.13
interpreter, bootstraps tools/collector/.venv with requirements.txt,
and runs this module through unittest.
"""

import asyncio
import hashlib
import json
import os
import queue
import sys
import tempfile
import threading
import time
import time
import types
import unittest
import urllib.error
from datetime import datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sidecar  # noqa: E402

TOKEN = "SECRET-TOKEN-VALUE"
FRESH_TOKEN = "REFRESHED-TOKEN"
TOKEN_TYPE = "Bearer"
# The token_source="env" fixtures (README §5.1). Fake values; the suite
# runner greps its own output for every fixture secret below and fails
# if any of them ever reaches it. The *_REAL pair is the real
# environment's separate credential set — never substituted for the demo
# pair and vice versa.
ENV_APP_KEY = "FAKE-ENV-APPKEY-VALUE"
ENV_APP_SECRET = "FAKE-ENV-SECRET-VALUE"
ENV_APP_KEY_REAL = "FAKE-REAL-APPKEY-VALUE"
ENV_APP_SECRET_REAL = "FAKE-REAL-SECRET-VALUE"
ENV_TOKEN = "FAKE-ENV-TOKEN-1"
ENV_TOKEN_2 = "FAKE-ENV-TOKEN-2"
ENV_TOKEN_3 = "FAKE-ENV-TOKEN-3"
ENV_SECRET_FIXTURES = ("TOKEN", "FRESH_TOKEN", "ENV_APP_KEY",
                       "ENV_APP_SECRET", "ENV_APP_KEY_REAL",
                       "ENV_APP_SECRET_REAL", "ENV_TOKEN", "ENV_TOKEN_2",
                       "ENV_TOKEN_3")


def patch_environ(testcase, key, value):
    """Set an env var for the test and restore it afterwards."""
    old = os.environ.get(key)
    os.environ[key] = value

    def restore():
        if old is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = old

    testcase.addCleanup(restore)


def kst_now():
    return datetime.now(sidecar.KST)


def approved_cfg(environment="demo"):
    """The exact PH-1 approved configuration (README §2.1); tests may
    only shrink the timers through the Sidecar constructor, never these
    pinned values. The environment selects the pinned endpoints: "demo"
    or "real"."""
    cfg = {
        "protocol": 1,
        "environment": environment,
        "rest_domain": sidecar.environment_rest_domain(environment),
        "ws_endpoint": sidecar.environment_ws_endpoint(environment),
        "api_id": "ka10027",
        "page_cap": 10,
        "repoll_seconds": 300,
        "drain_seconds": 10,
        "ack_timeout_seconds": 10,
        "watchdog": "15:40:00+09:00",
        "profile": "test-profile",
        "rest_params": {key: "1" for key in sidecar.REST_PARAMS_FIELDS},
    }
    if environment not in sidecar.ENVIRONMENTS:
        raise AssertionError("approved_cfg only builds demo or real")
    return cfg


def token_cache_path(cache_dir, profile="test-profile"):
    digest = hashlib.sha256(profile.encode("utf-8")).hexdigest()[:16]
    return os.path.join(cache_dir, "kiwoom", "profiles",
                        "profile-%s-token.json" % digest)


def seed_token_cache(cache_dir, token=TOKEN, expires_in=3600.0):
    path = token_cache_path(cache_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"access_token": token, "token_type": TOKEN_TYPE,
                   "expires_at": time.time() + expires_in}, f)
    return path


def install_fake_kiwoomcli(bin_dir, cache_dir, exit_code=0):
    """A fake `kiwoomcli auth refresh` that rewrites the cache like the
    official client would (and only that — it receives no secrets)."""
    path = token_cache_path(cache_dir)
    os.makedirs(bin_dir, exist_ok=True)
    script = os.path.join(bin_dir, "kiwoomcli")
    with open(script, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\n")
        f.write("cat > '%s' <<'EOF'\n" % path)
        f.write(json.dumps({"access_token": FRESH_TOKEN,
                            "token_type": TOKEN_TYPE,
                            "expires_at": time.time() + 3600.0}) + "\n")
        f.write("EOF\n")
        f.write("exit %d\n" % exit_code)
    os.chmod(script, 0o755)
    return script


class FakeTokenServer:
    """A real local HTTP server on 127.0.0.1 (ephemeral port) scripted to
    answer the OAuth token path (README §5.1 tests). Deterministic: each
    scripted entry is either a dict (HTTP 200 with that JSON body) or a
    (status, bytes) tuple; when the script is exhausted the server serves
    a plain return_code!=0 JSON so a test can never pass on an unscripted
    response. Requests are recorded (method, path, headers, parsed body);
    the socket never leaves loopback and no live host is contacted."""

    def __init__(self, testcase, script):
        from http.server import BaseHTTPRequestHandler, HTTPServer
        self.recorded = []
        scripted = list(script)
        recorded = self.recorded

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # keep the suite output clean
                pass

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or "0")
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    body = None
                recorded.append({
                    "method": self.command,
                    "path": self.path,
                    "content_type": self.headers.get("Content-Type") or "",
                    "authorization": self.headers.get("Authorization"),
                    "body": body,
                })
                entry = scripted.pop(0) if scripted else \
                    {"return_code": 1, "return_msg": "script exhausted"}
                if isinstance(entry, tuple):
                    status, payload = entry
                else:
                    status, payload = 200, \
                        json.dumps(entry).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type",
                                 "application/json;charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.endpoint = "http://127.0.0.1:%d%s" % (self.port,
                                                   sidecar.OAUTH_TOKEN_PATH)
        testcase.addCleanup(self._stop)
        self._thread = threading.Thread(target=self.server.serve_forever,
                                        daemon=True)
        self._thread.start()

    def _stop(self):
        self.server.shutdown()
        self.server.server_close()


def env_expires_dt(epoch):
    """An official expires_dt string for an epoch second (KST absolute,
    "YYYYMMDDHHMMSS")."""
    return datetime.fromtimestamp(epoch, sidecar.KST).strftime(
        "%Y%m%d%H%M%S")


class FakeStdin:
    """The core's side of the pipe: queue-backed, iteration for the
    command loop, readline() for the init line."""

    def __init__(self):
        self.q = queue.Queue()

    def readline(self):
        line = self.q.get()
        return "" if line is None else line

    def __iter__(self):
        return self

    def __next__(self):
        line = self.q.get()
        if line is None:
            raise StopIteration
        return line

    def send(self, line):
        self.q.put(line)

    def close(self):
        self.q.put(None)


class Capture:
    """Captured stdout, one JSON line per emit."""

    def __init__(self):
        self.lines = []
        self._buf = ""

    def write(self, s):
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            self.lines.append(line)
        return len(s)

    def flush(self):
        pass

    def events(self):
        return [json.loads(line) for line in self.lines]


class FakeFrame:
    def __init__(self, code, reason):
        self.code = code
        self.reason = reason


class FakeConnectionClosed(Exception):
    def __init__(self, rcvd=None):
        super().__init__("connection closed")
        self.rcvd = rcvd


_CLOSE = object()


class FakeWS:
    """One fake wire: records sends, delivers scripted bytes."""

    def __init__(self):
        self.sent = []
        self.inbox = asyncio.Queue()
        self.close_code = None

    def deliver(self, msg):
        self.inbox.put_nowait(msg)

    async def send(self, text):
        self.sent.append(text)

    async def recv(self):
        # The real websockets client API: recv() takes no decode argument
        # (removed in websockets 8.0) and returns str for a text frame,
        # bytes for a binary frame. The fake mirrors exactly that shape —
        # a fake more permissive than the real client would hide kwarg
        # mismatches from the suite (the 2026-11-09 live-session defect
        # this signature now locks out).
        item = await self.inbox.get()
        if item is _CLOSE:
            raise FakeConnectionClosed(FakeFrame(self.close_code or 1000,
                                                 "test close"))
        return item

    async def close(self, code=1000):
        self.close_code = code
        self.inbox.put_nowait(_CLOSE)


def quiet_count(evs):
    return sum(1 for e in evs if e.get("ev") == "timer"
               and e.get("kind") == "quiet")


class Harness:
    """One live Sidecar wired to the fake pipe; the test drives commands
    and a fake wire, and asserts on the emitted event lines."""

    def __init__(self, testcase, ack_timeout=0.5, drain=0.2, repoll=3600,
                 watchdog="23:59:59+09:00", token=TOKEN,
                 rest_min_interval=0.0, token_source=None,
                 token_endpoint=None):
        self.testcase = testcase
        self.stdin = FakeStdin()
        self.stdout = Capture()
        self.saved = (sys.stdin, sys.stdout)
        sys.stdin, sys.stdout = self.stdin, self.stdout
        cfg = approved_cfg()
        cfg["watchdog"] = watchdog
        if token_source is not None:
            cfg["token_source"] = token_source
        self.cfg = cfg
        self.sc = sidecar.Sidecar(cfg, repoll=repoll, drain=drain,
                                  ack_timeout=ack_timeout,
                                  rest_min_interval=rest_min_interval,
                                  token_endpoint=token_endpoint)
        # The default pre-set token is the kiwoomcli path's shortcut; the
        # env path (token=None) must go through the real provider.
        if token is not None:
            self.sc.token = token
            self.sc.token_type = TOKEN_TYPE
        self.task = None
        self.fake_ws = None
        self.connect_calls = []
        self.saved_ws_mod = None

    def close(self):
        sys.stdin, sys.stdout = self.saved

    def send(self, **cmd):
        self.stdin.send(json.dumps(cmd, ensure_ascii=False))

    def events(self):
        return self.stdout.events()

    async def wait_for(self, pred, desc, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            evs = self.stdout.events()
            if pred(evs):
                return evs
            await asyncio.sleep(0.005)
        raise AssertionError("timeout waiting for: %s\nseen:\n%s"
                             % (desc, "\n".join(self.stdout.lines)))

    async def start(self):
        self.task = asyncio.create_task(self.sc.run())
        await self.wait_for(lambda evs: bool(evs) and
                            evs[0].get("ev") == "ready", "the ready event")
        return self

    def attach_fake_websockets(self):
        self.fake_ws = FakeWS()
        mod = types.ModuleType("websockets")
        mod.ConnectionClosed = FakeConnectionClosed

        async def connect(url, ping_interval=None):
            self.connect_calls.append((url, ping_interval))
            return self.fake_ws

        mod.connect = connect
        self.saved_ws_mod = sys.modules.get("websockets")
        sys.modules["websockets"] = mod

    async def login(self):
        """connect + LOGIN ack -> an open connection, generation 1."""
        self.send(type="connect")
        await self.wait_for(lambda evs: bool(self.fake_ws.sent),
                            "the LOGIN frame on the wire")
        self.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 0}))
        await self.wait_for(
            lambda evs: any(e.get("ev") == "conn" and e.get("state") == "open"
                            for e in evs),
            "the conn open event")

    async def stop_and_join(self):
        """`stop` -> the documented clean exit code."""
        self.send(type="stop")
        try:
            await self.task
            raise AssertionError("the sidecar did not exit on stop")
        except sidecar.SidecarExit as exc:
            return exc.code


class SidecarContract(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.tmp = tmp
        self.addCleanup(tmp.cleanup)
        self.cache_dir = os.path.join(tmp.name, "cache")
        self.bin_dir = os.path.join(tmp.name, "bin")
        self._patchenv("XDG_CACHE_HOME", self.cache_dir)
        self._saved_path = os.environ.get("PATH")
        self._saved_ws = sys.modules.get("websockets")

    def tearDown(self):
        if self._saved_path is None:
            os.environ.pop("PATH", None)
        else:
            os.environ["PATH"] = self._saved_path
        if self._saved_ws is None:
            sys.modules.pop("websockets", None)
        else:
            sys.modules["websockets"] = self._saved_ws

    async def tearDownAsync(self):
        # Cancel whatever the sidecar still runs (connect loop, timers) so
        # a failed test leaves no destroyed-pending-task noise behind.
        tasks = [t for t in asyncio.all_tasks()
                 if t is not asyncio.current_task()]
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    def _patchenv(self, key, value):
        old = os.environ.get(key)
        os.environ[key] = value

        def restore():
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old

        self.addCleanup(restore)

    def harness(self, **kwargs):
        h = Harness(self, **kwargs)
        self.addCleanup(h.close)
        return h

    # ------------------------------------------------------------- init

    def test_init_accepts_the_approved_configuration(self):
        cfg = sidecar.parse_init(json.dumps(approved_cfg()))
        self.assertEqual(cfg["profile"], "test-profile")
        self.assertEqual(cfg["api_id"], "ka10027")
        self.assertEqual(sorted(cfg["rest_params"]),
                         sorted(sidecar.REST_PARAMS_FIELDS))
        self.assertEqual(cfg["environment"], "demo")
        self.assertEqual(cfg["rest_domain"], sidecar.DEMO_REST_DOMAIN)
        self.assertEqual(cfg["ws_endpoint"], sidecar.DEMO_WS_ENDPOINT)

    def test_init_accepts_the_real_environment_with_its_own_domains(self):
        # "real" is the operational split (official server-split
        # document): every endpoint is environment-derived and no mock
        # value survives.
        cfg = sidecar.parse_init(json.dumps(approved_cfg("real")))
        self.assertEqual(cfg["environment"], "real")
        self.assertEqual(cfg["rest_domain"], "https://api.kiwoom.com")
        self.assertEqual(
            cfg["ws_endpoint"],
            "wss://api.kiwoom.com:10000/api/dostk/websocket")

    def test_init_refuses_cross_environment_mixes(self):
        # Fail-closed: the domains must match the environment's own
        # pinned values — a demo session on real endpoints (or the
        # reverse) is a refused configuration, never a silently-run mix.
        def mix(environment, rest_domain, ws_endpoint):
            cfg = approved_cfg(environment)
            cfg["rest_domain"] = rest_domain
            cfg["ws_endpoint"] = ws_endpoint
            return json.dumps(cfg)

        cases = [
            ("demo environment with the real rest_domain",
             mix("demo", sidecar.REAL_REST_DOMAIN,
                 sidecar.DEMO_WS_ENDPOINT)),
            ("demo environment with the real ws_endpoint",
             mix("demo", sidecar.DEMO_REST_DOMAIN,
                 sidecar.REAL_WS_ENDPOINT)),
            ("real environment with the demo rest_domain",
             mix("real", sidecar.DEMO_REST_DOMAIN,
                 sidecar.REAL_WS_ENDPOINT)),
            ("real environment with the demo ws_endpoint",
             mix("real", sidecar.REAL_REST_DOMAIN,
                 sidecar.DEMO_WS_ENDPOINT)),
            ("real environment with a foreign domain",
             mix("real", "https://evil.example", sidecar.REAL_WS_ENDPOINT)),
        ]
        for name, line in cases:
            with self.assertRaises(sidecar.SidecarExit) as cm:
                sidecar.parse_init(line)
            self.assertEqual(cm.exception.code, 4, name)

    def test_init_token_source_is_optional_and_pinned(self):
        # Absent: the kiwoomcli default — no behavior may change for an
        # init line that does not carry the field (README §5.1).
        cfg = sidecar.parse_init(json.dumps(approved_cfg()))
        self.assertEqual(cfg.get("token_source", "kiwoomcli"), "kiwoomcli")
        self.assertIsInstance(sidecar.Sidecar(cfg).store, sidecar.TokenStore)
        # Explicit "kiwoomcli" selects the same store; "env" selects the
        # env provider with the pinned demo endpoint when none is injected.
        cfg = approved_cfg()
        cfg["token_source"] = "kiwoomcli"
        self.assertIsInstance(sidecar.Sidecar(cfg).store,
                              sidecar.TokenStore)
        cfg["token_source"] = "env"
        sc = sidecar.Sidecar(cfg)
        self.assertIsInstance(sc.store, sidecar.EnvTokenProvider)
        self.assertEqual(sc.store.endpoint,
                         sidecar.DEMO_REST_DOMAIN +
                         sidecar.OAUTH_TOKEN_PATH)
        # The real environment derives the real OAuth endpoint from the
        # same one selection — never the demo domain.
        cfg = approved_cfg("real")
        cfg["token_source"] = "env"
        sc = sidecar.Sidecar(cfg)
        self.assertIsInstance(sc.store, sidecar.EnvTokenProvider)
        self.assertEqual(sc.store.environment, "real")
        self.assertEqual(sc.store.endpoint,
                         sidecar.REAL_REST_DOMAIN +
                         sidecar.OAUTH_TOKEN_PATH)
        # Every other value (including a non-string) is refused.
        for bad in ("native", "", None, 3):
            line = approved_cfg()
            line["token_source"] = bad
            with self.assertRaises(sidecar.SidecarExit) as cm:
                sidecar.parse_init(json.dumps(line))
            self.assertEqual(cm.exception.code, 4)

    def test_init_rejects_every_unapproved_value(self):
        def mutate(**changes):
            cfg = approved_cfg()
            for key, value in changes.items():
                if value is None:
                    cfg.pop(key, None)
                else:
                    cfg[key] = value
            return json.dumps(cfg)

        bad_lines = [
            ("protocol", mutate(protocol=2)),
            ("environment", mutate(environment="prod")),
            ("environment absent", mutate(environment=None)),
            ("environment non-string", mutate(environment=3)),
            ("rest_domain", mutate(rest_domain="https://evil.example")),
            ("ws_endpoint", mutate(ws_endpoint="wss://evil.example:10000")),
            ("api_id", mutate(api_id="ka10099")),
            ("page_cap", mutate(page_cap=11)),
            ("repoll_seconds", mutate(repoll_seconds=299)),
            ("drain_seconds", mutate(drain_seconds=11)),
            ("ack_timeout_seconds", mutate(ack_timeout_seconds=9)),
            ("watchdog format", mutate(watchdog="15:40:00")),
            ("watchdog offset", mutate(watchdog="15:40:00+09:30")),
            ("profile empty", mutate(profile="")),
            ("profile spaces", mutate(profile="a b")),
            ("profile too long", mutate(profile="a" * 65)),
            ("api_id absent", mutate(api_id=None)),
            ("rest_params type", mutate(rest_params="x")),
            ("rest_params key",
             mutate(rest_params={k: "1" for k in sidecar.REST_PARAMS_FIELDS
                                 if k != "stex_tp"})),
            ("rest_params value type",
             mutate(rest_params={k: "1" for k in sidecar.REST_PARAMS_FIELDS}
                    | {"mrkt_tp": 0})),
        ]
        for name, line in bad_lines:
            with self.assertRaises(sidecar.SidecarExit) as cm:
                sidecar.parse_init(line)
            self.assertEqual(cm.exception.code, 4, name)
        for bad in ["", "not json", "[1,2]"]:
            with self.assertRaises(sidecar.SidecarExit) as cm:
                sidecar.parse_init(bad)
            self.assertEqual(cm.exception.code, 4)

    def test_watchdog_parse_rejects_malformed_times(self):
        for bad in ["", "15:40", "15:40:00", "15:40:00Z", "154000+09:00",
                    "25:40:00+09:00", "15:61:00+09:00"]:
            with self.assertRaises(sidecar.SidecarExit):
                sidecar.parse_watchdog_seconds(bad)

    # ------------------------------------------------ ready/stop/exit 4

    async def test_ready_then_stop_exits_zero(self):
        h = self.harness()
        await h.start()
        self.assertEqual(h.events()[0]["ev"], "ready")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_unknown_command_exits_four(self):
        h = self.harness()
        await h.start()
        h.send(type="wat")
        try:
            await h.task
            self.fail("an unknown command must exit, not be ignored")
        except sidecar.SidecarExit as exc:
            self.assertEqual(exc.code, 4)

    async def test_stdin_eof_exits_four(self):
        h = self.harness()
        await h.start()
        h.stdin.close()
        try:
            await h.task
            self.fail("EOF before stop is a broken pipe")
        except sidecar.SidecarExit as exc:
            self.assertEqual(exc.code, 4)

    async def test_reg_without_a_connection_exits_four(self):
        h = self.harness()
        await h.start()
        h.send(type="reg", gen=1, data=[])
        try:
            await h.task
            self.fail("reg with no open connection must exit 4")
        except sidecar.SidecarExit as exc:
            self.assertEqual(exc.code, 4)

    # --------------------------------------------------- connect/LOGIN

    async def test_connect_login_and_ping_echo(self):
        h = self.harness()
        h.attach_fake_websockets()
        await h.start()
        await h.login()
        self.assertEqual(h.connect_calls,
                         [(sidecar.DEMO_WS_ENDPOINT, None)])
        login = json.loads(h.fake_ws.sent[0])
        self.assertEqual(login["trnm"], "LOGIN")
        self.assertEqual(login["token"], TOKEN)

        h.fake_ws.deliver(b"PING")
        evs = await h.wait_for(
            lambda evs: any(e.get("ev") == "ws" and
                            e.get("payload_hex") == b"PING".hex()
                            for e in evs),
            "the PING bytes forwarded as a ws event")
        ws_ev = [e for e in evs if e.get("ev") == "ws"][-1]
        self.assertEqual(ws_ev["conn"], 1)
        self.assertIn("PING", h.fake_ws.sent[-1],
                      "PING echoes verbatim")

        payload = json.dumps(
            {"trnm": "REAL", "data": [{"item": "005930", "type": "0B",
                                       "values": {"10": "10000"}}]}
        ).encode("utf-8")
        h.fake_ws.deliver(payload)
        await h.wait_for(
            lambda evs: any(e.get("ev") == "ws" and
                            e.get("payload_hex") == payload.hex() for e in evs),
            "the 0B payload forwarded byte-exact")

        # A text frame (str) — the actual Kiwoom wire shape — must forward
        # as the same opaque bytes: recv() without decode returns str for
        # text frames (websockets >= 8.0), the regression the 2026-11-09
        # live session measured.
        text_frame = payload.decode("utf-8")
        h.fake_ws.deliver(text_frame)
        await h.wait_for(
            lambda evs: sum(1 for e in evs if e.get("ev") == "ws" and
                            e.get("payload_hex") == payload.hex()) >= 2,
            "the str text frame forwarded as the same opaque bytes")

        ping_doc = b'{"trnm":"PING","x":1}'
        h.fake_ws.deliver(ping_doc)
        await h.wait_for(
            lambda evs: any(e.get("ev") == "ws" and
                            e.get("payload_hex") == ping_doc.hex()
                            for e in evs),
            "the PING document forwarded")
        self.assertIn(ping_doc.decode(), h.fake_ws.sent[-1],
                      "a PING object echoes verbatim")

        garbage = b"\xff\xfe not json"
        h.fake_ws.deliver(garbage)
        await h.wait_for(
            lambda evs: any(e.get("ev") == "ws" and
                            e.get("payload_hex") == garbage.hex()
                            for e in evs),
            "non-JSON bytes still forwarded opaque")

        self.assertEqual(await h.stop_and_join(), 0)
        self.assertEqual(h.fake_ws.close_code, 1000)

    async def test_login_auth_code_refreshes_once_and_retries(self):
        h = self.harness(ack_timeout=0.3)
        seed_token_cache(self.cache_dir, token=TOKEN, expires_in=-10.0)
        install_fake_kiwoomcli(self.bin_dir, self.cache_dir)
        os.environ["PATH"] = self.bin_dir + os.pathsep + \
            (self._saved_path or "")
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 8005}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "token" for e in evs),
            "the token event after the refresh")
        await h.wait_for(lambda evs: len(h.fake_ws.sent) >= 2,
                         "the retried LOGIN")
        self.assertNotIn(TOKEN, h.fake_ws.sent[1])
        self.assertIn(FRESH_TOKEN, h.fake_ws.sent[1])
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 0}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "open" for e in evs),
            "conn open after the retry")

    async def test_login_ack_numeric_string_opens(self):
        h = self.harness(ack_timeout=0.3)
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        # The spec schema types return_code as a String while its examples
        # send a number; the official SDK normalizes both forms.
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": "0"}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "open" for e in evs),
            "conn open on the numeric-string ack")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_login_auth_code_embedded_in_return_msg_retries(self):
        h = self.harness(ack_timeout=0.3)
        seed_token_cache(self.cache_dir, token=TOKEN, expires_in=-10.0)
        install_fake_kiwoomcli(self.bin_dir, self.cache_dir)
        os.environ["PATH"] = self.bin_dir + os.pathsep + \
            (self._saved_path or "")
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        # A generic top-level code with the specific one embedded in
        # return_msg — the pattern the official SDK documents and matches.
        h.fake_ws.deliver(json.dumps({
            "trnm": "LOGIN", "return_code": "3",
            "return_msg": "CODE=8005:Token invalid"}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "token" for e in evs),
            "the token event after the refresh")
        await h.wait_for(lambda evs: len(h.fake_ws.sent) >= 2,
                         "the retried LOGIN")
        self.assertNotIn(TOKEN, h.fake_ws.sent[1])
        self.assertIn(FRESH_TOKEN, h.fake_ws.sent[1])
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 0}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "open" for e in evs),
            "conn open after the retry")

    async def test_login_ack_non_numeric_code_fails_closed(self):
        h = self.harness(ack_timeout=0.2)
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": "OK"}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "closed_error" and
                            "return_code='OK'" in e.get("reason", "")
                            for e in evs),
            "a non-numeric code is a closed_error, never a success")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_login_failure_reports_closed_error(self):
        h = self.harness(ack_timeout=0.2)
        h.attach_fake_websockets()
        await h.start()
        h.send(type="connect")
        await h.wait_for(lambda evs: bool(h.fake_ws.sent), "LOGIN sent")
        h.fake_ws.deliver(json.dumps({"trnm": "LOGIN", "return_code": 1}))
        await h.wait_for(
            lambda evs: any(e.get("ev") == "conn" and
                            e.get("state") == "closed_error" and
                            "return_code=1" in e.get("reason", "")
                            for e in evs),
            "the login failure as conn closed_error")
        self.assertEqual(h.fake_ws.close_code, 1000)
        self.assertEqual(await h.stop_and_join(), 0)

    # --------------------------------------------------- reg/remove/quiet

    async def test_reg_envelope_and_quiet_disarm_cycle(self):
        h = self.harness(ack_timeout=0.15)
        h.attach_fake_websockets()
        await h.start()
        await h.login()

        # Received traffic alone never arms the window: the quiet timer is
        # the REG/REMOVE ack expectation (README §2.3).
        await asyncio.sleep(0.25)
        self.assertEqual(quiet_count(h.events()), 0)

        data = [{"item": ["005930", "000660"], "type": ["0B"]}]
        h.send(type="reg", gen=1, data=data)
        await h.wait_for(lambda evs: quiet_count(evs) >= 1,
                         "the quiet window the reg armed")
        envelope = json.loads(h.fake_ws.sent[-1])
        self.assertEqual(envelope, {"trnm": "REG", "grp_no": "1",
                                    "refresh": "1", "data": data})

        # A second reg re-arms; disarm cancels it before it can fire.
        h.send(type="reg", gen=2, data=data)
        h.send(type="disarm")
        await asyncio.sleep(0.35)
        self.assertEqual(quiet_count(h.events()), 1,
                         "disarm cancels the quiet window")

        self.assertEqual(await h.stop_and_join(), 0)

    async def test_remove_envelope_has_no_refresh(self):
        h = self.harness()
        h.attach_fake_websockets()
        await h.start()
        await h.login()
        data = [{"item": ["005930"], "type": ["0B"]}]
        h.send(type="remove", gen=2, data=data)
        await h.wait_for(lambda evs: len(h.fake_ws.sent) >= 2,
                         "the REMOVE frame on the wire")
        envelope = json.loads(h.fake_ws.sent[-1])
        self.assertEqual(envelope, {"trnm": "REMOVE", "grp_no": "1",
                                    "data": data})
        self.assertEqual(await h.stop_and_join(), 0)

    # ---------------------------------------------------------------- rest

    async def test_rest_req_reports_the_raw_response(self):
        h = self.harness()
        await h.start()
        captured = {}

        class FakeResp:
            status = 200

            def __init__(self):
                self.headers = {"cont-yn": "Y", "next-key": "abc123"}

            def read(self):
                return b'{"pred_pre_flu_rt_upper":[],"return_code":0}'

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req, timeout=None):
            captured["req"] = req
            captured["timeout"] = timeout
            return FakeResp()

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="up", page=1,
                   cont_yn="", next_key="")
            evs = await h.wait_for(
                lambda evs: any(e.get("ev") == "rest" for e in evs),
                "the rest event")

        rest = [e for e in evs if e.get("ev") == "rest"][-1]
        self.assertEqual(rest["direction"], "up")
        self.assertEqual(rest["page"], 1)
        self.assertEqual(rest["status"], 200)
        self.assertEqual(rest["cont_yn"], "Y")
        self.assertEqual(rest["next_key"], "abc123")
        self.assertEqual(rest["body_hex"],
                         b'{"pred_pre_flu_rt_upper":[],"return_code":0}'
                         .hex())

        req = captured["req"]
        self.assertEqual(req.full_url,
                         sidecar.DEMO_REST_DOMAIN + sidecar.REST_PATH)
        self.assertEqual(req.headers.get("Api-id"), "ka10027")
        self.assertEqual(req.headers.get("Authorization"),
                         "Bearer " + TOKEN)
        body = json.loads(req.data.decode("utf-8"))
        self.assertEqual(body["sort_tp"], "1")
        self.assertEqual(captured["timeout"], 30)
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_rest_req_down_uses_sort_tp_3(self):
        h = self.harness()
        await h.start()
        captured = {}

        class FakeResp:
            status = 200
            headers = {}

            def read(self):
                return b"{}"

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req, timeout=None):
            captured["req"] = req
            return FakeResp()

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="down", page=2,
                   cont_yn="Y", next_key="k1")
            await h.wait_for(
                lambda evs: any(e.get("ev") == "rest" for e in evs),
                "the rest event")

        body = json.loads(captured["req"].data.decode("utf-8"))
        self.assertEqual(body["sort_tp"], "3")
        self.assertEqual(captured["req"].headers.get("Cont-yn"), "Y")
        self.assertEqual(captured["req"].headers.get("Next-key"), "k1")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_rest_requests_are_spaced_by_the_vendor_limit(self):
        """README §2.4: consecutive REST sends are spaced by
        rest_min_interval — the mock vendor's one-TR-per-second limit
        (observed live 2026-11-02: back-to-back page 2 -> 429)."""
        h = self.harness(rest_min_interval=0.25)
        await h.start()
        stamps = []

        class FakeResp:
            status = 200
            headers = {}

            def read(self):
                return b"{}"

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req, timeout=None):
            stamps.append(time.monotonic())
            return FakeResp()

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="up", page=1,
                   cont_yn="", next_key="")
            await h.wait_for(
                lambda evs: any(e.get("ev") == "rest" for e in evs),
                "the first rest event")
            h.send(type="rest_req", direction="up", page=2,
                   cont_yn="Y", next_key="k1")
            await h.wait_for(
                lambda evs: len([e for e in evs
                                 if e.get("ev") == "rest"]) >= 2,
                "the second rest event")

        self.assertEqual(len(stamps), 2)
        self.assertGreaterEqual(stamps[1] - stamps[0], 0.23,
                                "page 2 raced page 1 inside the vendor's "
                                "one-request-per-second limit")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_rest_http_error_is_still_a_response(self):
        h = self.harness()
        await h.start()

        def fake_urlopen(req, timeout=None):
            raise urllib.error.HTTPError("http://test", 401, "unauthorized",
                                         {"cont-yn": "", "next-key": ""},
                                         None)

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="up", page=1)
            evs = await h.wait_for(
                lambda evs: any(e.get("ev") == "rest" for e in evs),
                "the 401 as a rest event, not an error")
        rest = [e for e in evs if e.get("ev") == "rest"][-1]
        self.assertEqual(rest["status"], 401)
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_rest_transport_failure_is_an_error_event(self):
        h = self.harness()
        await h.start()

        def fake_urlopen(req, timeout=None):
            raise ConnectionRefusedError("no route")

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="up", page=1)
            evs = await h.wait_for(
                lambda evs: any(e.get("ev") == "error" and
                                e.get("what") == "rest" for e in evs),
                "the transport failure as error what=rest")
        err = [e for e in evs if e.get("ev") == "error"][-1]
        self.assertTrue(err["detail"].startswith("transport failed"))
        self.assertEqual(await h.stop_and_join(), 0)

    # ------------------------------------------------------ chart (ka10080)

    async def test_chart_req_reports_the_raw_response(self):
        """README §2.7: one ka10080 page, raw response, params verbatim."""
        h = self.harness()
        await h.start()
        captured = {}

        class FakeResp:
            status = 200

            def __init__(self):
                self.headers = {"cont-yn": "Y", "next-key": "pg2"}

            def read(self):
                return b'{"stk_min_pole_chart_qry":[],"return_code":0}'

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req, timeout=None):
            captured["req"] = req
            captured["timeout"] = timeout
            return FakeResp()

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="chart_req", api_id="ka10080", page=1,
                   params={"stk_cd": "005930", "tic_scope": "3",
                           "upd_stkpc_tp": "0", "base_dt": ""},
                   cont_yn="", next_key="")
            evs = await h.wait_for(
                lambda evs: any(e.get("ev") == "rest_chart" for e in evs),
                "the rest_chart event")

        ev = [e for e in evs if e.get("ev") == "rest_chart"][-1]
        self.assertEqual(ev["api_id"], "ka10080")
        self.assertEqual(ev["page"], 1)
        self.assertEqual(ev["status"], 200)
        self.assertEqual(ev["cont_yn"], "Y")
        self.assertEqual(ev["next_key"], "pg2")
        self.assertEqual(ev["body_hex"],
                         b'{"stk_min_pole_chart_qry":[],"return_code":0}'
                         .hex())
        self.assertNotIn("direction", ev)

        req = captured["req"]
        self.assertEqual(req.full_url,
                         sidecar.DEMO_REST_DOMAIN + sidecar.CHART_REST_PATH)
        self.assertEqual(req.headers.get("Api-id"), "ka10080")
        self.assertEqual(req.headers.get("Authorization"),
                         "Bearer " + TOKEN)
        body = json.loads(req.data.decode("utf-8"))
        # base_dt is OPTIONAL: empty means omitted from the request body.
        self.assertEqual(body, {"stk_cd": "005930", "tic_scope": "3",
                                "upd_stkpc_tp": "0"})
        self.assertEqual(captured["timeout"], 30)
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_chart_req_sends_base_dt_when_declared(self):
        h = self.harness()
        await h.start()
        captured = {}

        class FakeResp:
            status = 200
            headers = {}

            def read(self):
                return b"{}"

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req, timeout=None):
            captured["req"] = req
            return FakeResp()

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="chart_req", api_id="ka10080", page=1,
                   params={"stk_cd": "005930", "tic_scope": "3",
                           "upd_stkpc_tp": "1",
                           "base_dt": "20261105"})
            await h.wait_for(
                lambda evs: any(e.get("ev") == "rest_chart" for e in evs),
                "the rest_chart event")

        body = json.loads(captured["req"].data.decode("utf-8"))
        self.assertEqual(body, {"stk_cd": "005930", "tic_scope": "3",
                                "upd_stkpc_tp": "1",
                                "base_dt": "20261105"})
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_chart_req_continuation_headers(self):
        h = self.harness()
        await h.start()
        captured = {}

        class FakeResp:
            status = 200
            headers = {}

            def read(self):
                return b"{}"

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req, timeout=None):
            captured["req"] = req
            return FakeResp()

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="chart_req", api_id="ka10080", page=2,
                   params={"stk_cd": "005930", "tic_scope": "3",
                           "upd_stkpc_tp": "0"},
                   cont_yn="Y", next_key="pg2")
            await h.wait_for(
                lambda evs: any(e.get("ev") == "rest_chart" for e in evs),
                "the rest_chart event")

        self.assertEqual(captured["req"].headers.get("Cont-yn"), "Y")
        self.assertEqual(captured["req"].headers.get("Next-key"), "pg2")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_chart_requests_share_the_rest_pacing(self):
        """README §2.4/§2.7: the vendor's one-TR-per-second limit is one
        pacing lock for ALL REST traffic — a chart page after a rkinfo page
        is spaced the same way."""
        h = self.harness(rest_min_interval=0.25)
        await h.start()
        stamps = []

        class FakeResp:
            status = 200
            headers = {}

            def read(self):
                return b"{}"

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req, timeout=None):
            stamps.append(time.monotonic())
            return FakeResp()

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="rest_req", direction="up", page=1,
                   cont_yn="", next_key="")
            await h.wait_for(
                lambda evs: any(e.get("ev") == "rest" for e in evs),
                "the rest event")
            h.send(type="chart_req", api_id="ka10080", page=1,
                   params={"stk_cd": "005930", "tic_scope": "3",
                           "upd_stkpc_tp": "0"})
            await h.wait_for(
                lambda evs: any(e.get("ev") == "rest_chart" for e in evs),
                "the rest_chart event")

        self.assertEqual(len(stamps), 2)
        self.assertGreaterEqual(stamps[1] - stamps[0], 0.23,
                                "the chart page raced the rkinfo page " +
                                "inside the vendor's one-request-per-second " +
                                "limit")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_chart_http_error_is_still_a_response(self):
        h = self.harness()
        await h.start()

        def fake_urlopen(req, timeout=None):
            raise urllib.error.HTTPError("http://test", 401, "unauthorized",
                                         {"cont-yn": "", "next-key": ""},
                                         None)

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="chart_req", api_id="ka10080", page=1,
                   params={"stk_cd": "005930", "tic_scope": "3",
                           "upd_stkpc_tp": "0"})
            evs = await h.wait_for(
                lambda evs: any(e.get("ev") == "rest_chart" for e in evs),
                "the 401 as a rest_chart event, not an error")
        ev = [e for e in evs if e.get("ev") == "rest_chart"][-1]
        self.assertEqual(ev["status"], 401)
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_chart_transport_failure_is_an_error_event(self):
        h = self.harness()
        await h.start()

        def fake_urlopen(req, timeout=None):
            raise ConnectionRefusedError("no route")

        with mock.patch("urllib.request.urlopen", fake_urlopen):
            h.send(type="chart_req", api_id="ka10080", page=1,
                   params={"stk_cd": "005930", "tic_scope": "3",
                           "upd_stkpc_tp": "0"})
            evs = await h.wait_for(
                lambda evs: any(e.get("ev") == "error" and
                                e.get("what") == "rest" for e in evs),
                "the chart transport failure as error what=rest")
        err = [e for e in evs if e.get("ev") == "error"][-1]
        self.assertTrue(err["detail"].startswith("transport failed"))
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_chart_command_shape_is_refused_fail_closed(self):
        """README §2.7: the approved chart api-id, the three documented
        required params and page >= 1 are transport-shape law — anything
        else is exit 4, never a guessed request."""
        cases = [
            {"api_id": "ka11080",
             "params": {"stk_cd": "005930", "tic_scope": "3",
                        "upd_stkpc_tp": "0"}, "page": 1},
            {"api_id": "ka10080",
             "params": {"tic_scope": "3", "upd_stkpc_tp": "0"}, "page": 1},
            {"api_id": "ka10080",
             "params": {"stk_cd": "", "tic_scope": "3",
                        "upd_stkpc_tp": "0"}, "page": 1},
            {"api_id": "ka10080",
             "params": {"stk_cd": "005930", "upd_stkpc_tp": "0"}, "page": 1},
            {"api_id": "ka10080",
             "params": {"stk_cd": "005930", "tic_scope": 3,
                        "upd_stkpc_tp": "0"}, "page": 1},
            {"api_id": "ka10080",
             "params": {"stk_cd": "005930", "tic_scope": "3",
                        "upd_stkpc_tp": "0", "base_dt": 20261105}, "page": 1},
            {"api_id": "ka10080",
             "params": {"stk_cd": "005930", "tic_scope": "3",
                        "upd_stkpc_tp": "0"}, "page": 0},
            {"api_id": "ka10080",
             "params": {"stk_cd": "005930", "tic_scope": "3",
                        "upd_stkpc_tp": "0"}, "page": "1"},
        ]
        for cmd in cases:
            h = self.harness()
            await h.start()
            with self.assertRaises(sidecar.SidecarExit) as raised:
                await h.sc.handle(cmd)
            self.assertEqual(raised.exception.code, 4, str(cmd))
            h.close()

    # --------------------------------------------------------- drain etc.

    async def test_wait_drain_reports_drain_done(self):
        h = self.harness(drain=0.2)
        await h.start()
        h.send(type="wait_drain")
        await h.wait_for(
            lambda evs: any(e.get("ev") == "drain_done" for e in evs),
            "the drain_done event")
        self.assertEqual(await h.stop_and_join(), 0)

    async def test_watchdog_in_the_past_fires_immediately(self):
        now = kst_now()
        past = now - timedelta(hours=1)
        if past.date() != now.date():
            # Before 01:00 KST "one hour ago" lands on yesterday, which
            # parse_watchdog_seconds reads as a time later TODAY; midnight
            # today is always <= now, so it still fires immediately.
            past = now.replace(hour=0, minute=0, second=0, microsecond=0)
        h = self.harness(watchdog=past.strftime("%H:%M:%S+09:00"))
        await h.start()
        await h.wait_for(
            lambda evs: any(e.get("ev") == "timer" and
                            e.get("kind") == "watchdog" for e in evs),
            "the watchdog event")

    # ------------------------------------------------------------- token

    def test_token_cache_hit_needs_no_subprocess(self):
        seed_token_cache(self.cache_dir, token=TOKEN)
        os.environ["PATH"] = "/nonexistent"
        store = sidecar.TokenStore("test-profile")
        self.assertEqual(store.get(), (TOKEN, TOKEN_TYPE))

    def test_token_expired_cache_refreshes_through_the_client(self):
        seed_token_cache(self.cache_dir, token=TOKEN, expires_in=-10.0)
        install_fake_kiwoomcli(self.bin_dir, self.cache_dir)
        os.environ["PATH"] = self.bin_dir + os.pathsep + \
            (self._saved_path or "")
        store = sidecar.TokenStore("test-profile")
        self.assertEqual(store.get(), (FRESH_TOKEN, TOKEN_TYPE))

    def test_token_refresh_failure_raises_without_leaking_values(self):
        seed_token_cache(self.cache_dir, token=TOKEN, expires_in=-10.0)
        install_fake_kiwoomcli(self.bin_dir, self.cache_dir, exit_code=3)
        os.environ["PATH"] = self.bin_dir + os.pathsep + \
            (self._saved_path or "")
        store = sidecar.TokenStore("test-profile")
        with self.assertRaises(sidecar.TokenError) as cm:
            store.get()
        self.assertNotIn(TOKEN, str(cm.exception))
        self.assertNotIn(FRESH_TOKEN, str(cm.exception))

    def test_token_without_cache_or_client_fails_closed(self):
        os.environ["PATH"] = "/nonexistent"
        store = sidecar.TokenStore("test-profile")
        with self.assertRaises(sidecar.TokenError):
            store.get()

    def test_main_exits_three_when_the_token_path_fails(self):
        h = self.harness()
        os.environ["PATH"] = "/nonexistent"
        h.send(**approved_cfg())  # the init line
        result = {}

        def run_main():
            result["code"] = sidecar.main()

        thread = threading.Thread(target=run_main)
        thread.start()
        thread.join(timeout=10)
        self.assertFalse(thread.is_alive(), "main did not return")
        self.assertEqual(result["code"], 3)
        evs = h.events()
        self.assertTrue(any(e.get("ev") == "error" and
                            e.get("what") == "token" for e in evs))

    # ------------------------------------------------ token_source="env"

    def test_main_env_missing_credentials_refuse_to_start(self):
        # Fail-closed (README §5.1): no env credentials, no start — and
        # no HTTP request at all.
        server = FakeTokenServer(self, [])
        h = self.harness()
        cfg = approved_cfg()
        cfg["token_source"] = "env"
        h.send(**cfg)
        result = {}

        def run_main():
            result["code"] = sidecar.main(token_endpoint=server.endpoint)

        thread = threading.Thread(target=run_main)
        thread.start()
        thread.join(timeout=10)
        self.assertFalse(thread.is_alive(), "main did not return")
        self.assertEqual(result["code"], 3)
        evs = h.events()
        err = [e for e in evs if e.get("ev") == "error"][-1]
        self.assertEqual(err["what"], "token")
        self.assertEqual(err["detail"],
                         "APP_KEY_MOCK missing or empty in environment")
        self.assertEqual(len(server.recorded), 0,
                         "no issuance request without credentials")

    def test_main_env_return_code_failure_retries_once_then_exits_three(self):
        server = FakeTokenServer(self, [
            {"return_code": 1, "return_msg": "credential not valid"},
            {"return_code": 1, "return_msg": "credential not valid"},
        ])
        h = self.harness()
        patch_environ(self, "APP_KEY_MOCK", ENV_APP_KEY)
        patch_environ(self, "APP_SECRET_MOCK", ENV_APP_SECRET)
        cfg = approved_cfg()
        cfg["token_source"] = "env"
        h.send(**cfg)
        result = {}

        def run_main():
            result["code"] = sidecar.main(token_endpoint=server.endpoint)

        thread = threading.Thread(target=run_main)
        thread.start()
        thread.join(timeout=10)
        self.assertFalse(thread.is_alive(), "main did not return")
        self.assertEqual(result["code"], 3)
        evs = h.events()
        err = [e for e in evs if e.get("ev") == "error"][-1]
        self.assertEqual(err["what"], "token")
        self.assertEqual(err["detail"],
                         "token endpoint returned return_code=1")
        self.assertEqual(len(server.recorded), 2,
                         "exactly one retry before the failure")
        # The failure report carries the failure class only.
        joined = "\n".join(h.stdout.lines)
        for secret in (ENV_APP_KEY, ENV_APP_SECRET, ENV_TOKEN):
            self.assertNotIn(secret, joined)
        self.assertNotIn("credential not valid", joined)

    async def test_env_source_acquires_via_the_provider_and_never_leaks(self):
        server = FakeTokenServer(self, [
            {"token": ENV_TOKEN, "token_type": "bearer",
             "expires_dt": env_expires_dt(float(int(time.time())) + 3600.0),
             "return_code": 0, "return_msg": ""},
            {"token": ENV_TOKEN_2, "token_type": "bearer",
             "expires_dt": env_expires_dt(float(int(time.time())) + 3600.0),
             "return_code": 0, "return_msg": ""},
        ])
        patch_environ(self, "APP_KEY_MOCK", ENV_APP_KEY)
        patch_environ(self, "APP_SECRET_MOCK", ENV_APP_SECRET)
        # token=None: the env path must go through the real provider,
        # never the kiwoomcli shortcut.
        h = self.harness(token=None, token_source="env",
                         token_endpoint=server.endpoint)
        h.attach_fake_websockets()
        await h.start()
        # The startup acquisition is a real env round trip.
        h.sc.acquire_token()
        self.assertEqual(h.sc.token, ENV_TOKEN)
        self.assertEqual(h.sc.token_type, "bearer")
        self.assertEqual(len(server.recorded), 1)
        await h.login()
        login = json.loads(h.fake_ws.sent[0])
        self.assertEqual(login["token"], ENV_TOKEN)
        # Forced rotation (refresh_token, README §2.5): one more issuance.
        h.send(type="refresh_token")
        await h.wait_for(
            lambda evs: any(e.get("ev") == "token" for e in evs),
            "the token event after the forced reissue")
        self.assertEqual(h.sc.token, ENV_TOKEN_2)
        self.assertEqual(len(server.recorded), 2)
        h.fake_ws.deliver(b"PING")
        await h.wait_for(
            lambda evs: any(e.get("payload_hex") == b"PING".hex()
                            for e in evs), "a forwarded payload")
        self.assertEqual(await h.stop_and_join(), 0)
        # No secret anywhere in the sidecar's emitted lines.
        joined = "\n".join(h.stdout.lines)
        for secret in (ENV_APP_KEY, ENV_APP_SECRET, ENV_TOKEN, ENV_TOKEN_2):
            self.assertNotIn(secret, joined)
        self.assertNotIn("authorization", joined.lower())
        # ... and no token file on disk: the env path writes nothing.
        self.assertFalse(os.path.exists(token_cache_path(self.cache_dir)),
                         "env mode must not write a token cache")

    # ---------------------------------------------------------- privacy

    async def test_no_token_value_ever_reaches_the_pipe(self):
        h = self.harness()
        h.attach_fake_websockets()
        await h.start()
        await h.login()
        h.fake_ws.deliver(b"PING")
        await h.wait_for(
            lambda evs: any(e.get("payload_hex") == b"PING".hex()
                            for e in evs), "a forwarded payload")
        h.send(type="reg", gen=1,
               data=[{"item": ["005930"], "type": ["0B"]}])
        await h.wait_for(lambda evs: len(h.fake_ws.sent) >= 2,
                         "the REG frame")

        def refused(req, timeout=None):
            raise ConnectionRefusedError("offline by construction")

        with mock.patch("urllib.request.urlopen", refused):
            h.send(type="rest_req", direction="up", page=1)
            await h.wait_for(
                lambda evs: any(e.get("ev") == "error" and
                                e.get("what") == "rest" for e in evs),
                "the refused rest attempt reported as an error event")
        self.assertEqual(await h.stop_and_join(), 0)
        joined = "\n".join(h.stdout.lines)
        self.assertNotIn(TOKEN, joined)
        self.assertNotIn(FRESH_TOKEN, joined)
        self.assertNotIn("Bearer", joined)


class EnvTokenProviderContract(unittest.TestCase):
    """README §5.1: the token_source="env" provider against a real local
    fake HTTP server on 127.0.0.1 — the official request shape, response
    parsing, the 600 s renewal trigger, and the fail-closed paths. The
    endpoint is injected; no live host is ever contacted."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.tmp = tmp
        self.addCleanup(tmp.cleanup)
        patch_environ(self, "APP_KEY_MOCK", ENV_APP_KEY)
        patch_environ(self, "APP_SECRET_MOCK", ENV_APP_SECRET)

    def test_env_issuance_parses_the_official_response(self):
        expires = float(int(time.time())) + 3600.0
        server = FakeTokenServer(self, [{
            "token": ENV_TOKEN, "token_type": "bearer",
            "expires_dt": env_expires_dt(expires),
            "return_code": "0", "return_msg": ""}])
        provider = sidecar.EnvTokenProvider(server.endpoint)
        self.assertEqual(provider.get(), (ENV_TOKEN, "bearer"))
        self.assertEqual(len(server.recorded), 1,
                         "au10001: one issuance, the token is reused")
        req = server.recorded[0]
        self.assertEqual(req["method"], "POST")
        self.assertEqual(req["path"], sidecar.OAUTH_TOKEN_PATH)
        self.assertEqual(req["content_type"].split(";")[0],
                         "application/json")
        self.assertIsNone(req["authorization"],
                          "the issuance request carries no Authorization")
        self.assertEqual(req["body"],
                         {"grant_type": "client_credentials",
                          "appkey": ENV_APP_KEY,
                          "secretkey": ENV_APP_SECRET})
        # expires_dt is the only expiry evidence: parsed as a KST absolute.
        self.assertEqual(provider._expires_epoch, expires)
        # The cached issuance serves later gets without a new request.
        self.assertEqual(provider.get(), (ENV_TOKEN, "bearer"))
        self.assertEqual(len(server.recorded), 1)

    def test_env_reissue_triggers_only_inside_the_600s_buffer(self):
        t0 = 1_000_000.0
        clock = {"now": t0}
        server = FakeTokenServer(self, [
            {"token": ENV_TOKEN, "token_type": "bearer",
             "expires_dt": env_expires_dt(t0 + 3600.0),
             "return_code": 0, "return_msg": ""},
            {"token": ENV_TOKEN_2, "token_type": "bearer",
             "expires_dt": env_expires_dt(t0 + 10000.0),
             "return_code": 0, "return_msg": ""},
            {"token": ENV_TOKEN_3, "token_type": "bearer",
             "expires_dt": env_expires_dt(t0 + 20000.0),
             "return_code": 0, "return_msg": ""},
        ])
        provider = sidecar.EnvTokenProvider(server.endpoint,
                                            clock=lambda: clock["now"])
        self.assertEqual(provider.get(), (ENV_TOKEN, "bearer"))
        self.assertEqual(len(server.recorded), 1)
        clock["now"] = t0 + 2999.0   # remaining 601 s: outside the buffer
        self.assertEqual(provider.get(), (ENV_TOKEN, "bearer"))
        self.assertEqual(len(server.recorded), 1,
                         "no reissue while the buffer is not reached")
        clock["now"] = t0 + 3001.0   # remaining 599 s: inside the buffer
        self.assertEqual(provider.get(), (ENV_TOKEN_2, "bearer"))
        self.assertEqual(len(server.recorded), 2,
                         "the buffer crossing triggered one reissue")
        clock["now"] = t0 + 1001.0   # far from expiry again
        self.assertEqual(provider.get(force=True), (ENV_TOKEN_3, "bearer"))
        self.assertEqual(len(server.recorded), 3,
                         "force reissues even with a usable cache")

    def test_env_missing_or_empty_credentials_refuse(self):
        server = FakeTokenServer(self, [])
        for missing in ("APP_KEY_MOCK", "APP_SECRET_MOCK"):
            for key, value in (("APP_KEY_MOCK", ENV_APP_KEY),
                               ("APP_SECRET_MOCK", ENV_APP_SECRET)):
                if key != missing:
                    os.environ[key] = value
            os.environ.pop(missing, None)
            provider = sidecar.EnvTokenProvider(server.endpoint)
            with self.assertRaises(sidecar.TokenError) as cm:
                provider.get()
            self.assertIn(missing, str(cm.exception))
            self.assertNotIn(ENV_APP_KEY, str(cm.exception))
            self.assertNotIn(ENV_APP_SECRET, str(cm.exception))
            self.assertEqual(len(server.recorded), 0,
                             "no request without both credentials")
        # An empty string value is the same refusal as a missing one.
        os.environ["APP_KEY_MOCK"] = ENV_APP_KEY
        os.environ["APP_SECRET_MOCK"] = ""
        provider = sidecar.EnvTokenProvider(server.endpoint)
        with self.assertRaises(sidecar.TokenError) as cm:
            provider.get()
        self.assertIn("APP_SECRET_MOCK", str(cm.exception))
        self.assertEqual(len(server.recorded), 0)

    def test_env_real_issuance_uses_the_real_variable_pair(self):
        # The real environment reads APP_KEY_REAL/APP_SECRET_REAL — the
        # pair is separate by design (official guide: 실제 투자와 모의투자
        # App Key는 별도 관리). The demo pair is entirely absent here.
        patch_environ(self, "APP_KEY_REAL", ENV_APP_KEY_REAL)
        patch_environ(self, "APP_SECRET_REAL", ENV_APP_SECRET_REAL)
        os.environ.pop("APP_KEY_MOCK", None)
        os.environ.pop("APP_SECRET_MOCK", None)
        expires = float(int(time.time())) + 3600.0
        server = FakeTokenServer(self, [{
            "token": ENV_TOKEN, "token_type": "bearer",
            "expires_dt": env_expires_dt(expires),
            "return_code": 0, "return_msg": ""}])
        provider = sidecar.EnvTokenProvider(server.endpoint,
                                            environment="real")
        self.assertEqual(provider.get(), (ENV_TOKEN, "bearer"))
        self.assertEqual(len(server.recorded), 1)
        self.assertEqual(server.recorded[0]["body"],
                         {"grant_type": "client_credentials",
                          "appkey": ENV_APP_KEY_REAL,
                          "secretkey": ENV_APP_SECRET_REAL})

    def test_env_real_missing_credentials_never_substitute_the_demo_pair(self):
        # Combination mismatch is fail-closed: a real session with only
        # the demo variables present refuses (naming the real variable),
        # and a demo session with only the real variables present refuses
        # (naming the demo variable). No request is ever sent — the other
        # environment's credentials are never borrowed.
        server = FakeTokenServer(self, [])
        # real session, demo pair present, real pair absent.
        os.environ.pop("APP_KEY_REAL", None)
        os.environ.pop("APP_SECRET_REAL", None)
        provider = sidecar.EnvTokenProvider(server.endpoint,
                                            environment="real")
        with self.assertRaises(sidecar.TokenError) as cm:
            provider.get()
        self.assertIn("APP_KEY_REAL", str(cm.exception))
        self.assertNotIn("APP_KEY_MOCK", str(cm.exception))
        self.assertEqual(len(server.recorded), 0)
        # demo session, real pair present, demo pair absent.
        patch_environ(self, "APP_KEY_REAL", ENV_APP_KEY_REAL)
        patch_environ(self, "APP_SECRET_REAL", ENV_APP_SECRET_REAL)
        os.environ.pop("APP_KEY_MOCK", None)
        os.environ.pop("APP_SECRET_MOCK", None)
        provider = sidecar.EnvTokenProvider(server.endpoint)
        with self.assertRaises(sidecar.TokenError) as cm:
            provider.get()
        self.assertIn("APP_KEY_MOCK", str(cm.exception))
        self.assertNotIn("APP_KEY_REAL", str(cm.exception))
        self.assertNotIn(ENV_APP_KEY_REAL, str(cm.exception))
        self.assertEqual(len(server.recorded), 0)

    def test_env_unknown_environment_is_refused_at_construction(self):
        # "prod" is a retired name: no provider is built for it at all.
        for bad in ("prod", "staging", "", None):
            with self.assertRaises(ValueError):
                sidecar.EnvTokenProvider("http://127.0.0.1:1/token",
                                         environment=bad)

    def test_env_return_code_failure_retries_once_then_raises(self):
        server = FakeTokenServer(self, [
            {"return_code": 1, "return_msg": "credential not valid"},
            {"return_code": 1, "return_msg": "credential not valid"},
        ])
        provider = sidecar.EnvTokenProvider(server.endpoint)
        with self.assertRaises(sidecar.TokenError) as cm:
            provider.get()
        self.assertEqual(str(cm.exception),
                         "token endpoint returned return_code=1")
        self.assertNotIn("credential not valid", str(cm.exception))
        self.assertEqual(len(server.recorded), 2,
                         "one failure retry, then the error")

    def test_env_retry_recovers_a_transient_failure(self):
        server = FakeTokenServer(self, [
            {"return_code": 1, "return_msg": "transient"},
            {"token": ENV_TOKEN, "token_type": "bearer",
             "expires_dt": env_expires_dt(float(int(time.time())) + 3600.0),
             "return_code": 0, "return_msg": ""},
        ])
        provider = sidecar.EnvTokenProvider(server.endpoint)
        self.assertEqual(provider.get(), (ENV_TOKEN, "bearer"))
        self.assertEqual(len(server.recorded), 2)

    def test_env_non_json_response_fails_closed(self):
        server = FakeTokenServer(self, [(200, b"<html>not json</html>"),
                                        (200, b"<html>not json</html>")])
        provider = sidecar.EnvTokenProvider(server.endpoint)
        with self.assertRaises(sidecar.TokenError) as cm:
            provider.get()
        self.assertEqual(str(cm.exception),
                         "token endpoint returned non-JSON")
        self.assertNotIn(ENV_APP_KEY, str(cm.exception))
        self.assertNotIn(ENV_APP_SECRET, str(cm.exception))
        self.assertEqual(len(server.recorded), 2)

    def test_env_http_error_status_fails_closed(self):
        server = FakeTokenServer(self, [(500, b"{}"), (500, b"{}")])
        provider = sidecar.EnvTokenProvider(server.endpoint)
        with self.assertRaises(sidecar.TokenError) as cm:
            provider.get()
        self.assertEqual(str(cm.exception),
                         "token endpoint request failed: HTTPError")
        self.assertEqual(len(server.recorded), 2)

    def test_env_issuance_inside_the_buffer_is_refused(self):
        server = FakeTokenServer(self, [{
            "token": ENV_TOKEN, "token_type": "bearer",
            "expires_dt": env_expires_dt(float(int(time.time())) + 300.0),
            "return_code": 0, "return_msg": ""}])
        provider = sidecar.EnvTokenProvider(server.endpoint)
        with self.assertRaises(sidecar.TokenError) as cm:
            provider.get()
        self.assertEqual(
            str(cm.exception),
            "issued token expires_dt is inside the renewal buffer")
        self.assertEqual(len(server.recorded), 1,
                         "no retry on an unusable expiry")

    def test_env_unusable_fields_fail_closed(self):
        good_expires = env_expires_dt(float(int(time.time())) + 3600.0)
        cases = [
            ({"token_type": "bearer", "expires_dt": good_expires,
              "return_code": 0},
             "token endpoint response has no usable token field"),
            ({"token": "", "token_type": "bearer",
              "expires_dt": good_expires, "return_code": 0},
             "token endpoint response has no usable token field"),
            ({"token": ENV_TOKEN, "token_type": "bearer",
              "return_code": 0},
             "token endpoint response has no usable expires_dt"),
            ({"token": ENV_TOKEN, "token_type": "bearer",
              "expires_dt": "2026-99-99", "return_code": 0},
             "token endpoint response has no usable expires_dt"),
            ({"token": ENV_TOKEN, "token_type": "bearer",
              "expires_dt": good_expires},
             "token endpoint response has no usable return_code"),
            ({"token": ENV_TOKEN, "token_type": "bearer",
              "expires_dt": good_expires, "return_code": "OK"},
             "token endpoint response has no usable return_code"),
            ([], "token endpoint response is not a JSON object"),
        ]
        for doc, message in cases:
            server = FakeTokenServer(
                self, [(200, json.dumps(doc).encode("utf-8"))] * 2)
            provider = sidecar.EnvTokenProvider(server.endpoint)
            with self.assertRaises(sidecar.TokenError) as cm:
                provider.get()
            self.assertEqual(str(cm.exception), message, doc)
            self.assertNotIn(ENV_APP_KEY, str(cm.exception))
            self.assertNotIn(ENV_APP_SECRET, str(cm.exception))


if __name__ == "__main__":
    unittest.main()
