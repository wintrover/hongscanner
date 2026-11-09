#!/usr/bin/env python3
"""sidecar: the VS-2 live collector's communication process.

Contract: tools/collector/README.md (the committed pipe-protocol contract).
This process is COMMUNICATION ONLY: it owns the WebSocket connection, the
REST transport, its own clock (the events' "t"), the token lifetime and
nothing else. Channel discrimination (REG/REAL/0B/0s/...), REG/REMOVE ack
pairing, candidate derivation and the termination verdict are all the Nim
core's authority (README §0): every application payload is forwarded as
opaque bytes, every judgment is left to the core.

The three discriminations this process does make (README §4, all of them):
  1. Kiwoom PING — received bytes that trim to exactly "PING" or parse to
     {"trnm":"PING"} are echoed verbatim; every received message is still
     forwarded as a ws event.
  2. LOGIN — one handshake per connection; an auth-class ack
     ({8005, 8031, 8103}) triggers one token refresh and one retry, the
     same strategy as the official SDK.
  3. Token expiry — expires_dt/expires_at is the only expiry evidence;
     600 s buffer. Credentials come from `kiwoomcli auth refresh --profile
     <alias>` (token_source "kiwoomcli", the default), or — when the init
     line carries token_source "env" (README §5.1) — from a direct OAuth
     issuance with the environment's own credential variables:
     APP_KEY_MOCK/APP_SECRET_MOCK for the demo environment,
     APP_KEY_REAL/APP_SECRET_REAL for the real environment — never one
     for the other. Token values and credential values exist only in
     process memory: nothing prints them.

Wire discipline (README §1): line-delimited UTF-8 JSON over stdin/stdout,
one object per line. Every emitted line is HCJ-safe (string/int values
only). No float ever crosses the pipe. A broken stdout pipe is exit 4.

Exit codes (README §8): 0 normal (after `stop`), 3 token failure,
4 internal fault / broken pipe / unknown command.
"""

import asyncio
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

PROTOCOL = 1
KST = timezone(timedelta(hours=9))
DEMO_REST_DOMAIN = "https://mockapi.kiwoom.com"
DEMO_WS_ENDPOINT = "wss://mockapi.kiwoom.com:10000/api/dostk/websocket"
# The operational (real) split (official server-split document,
# ASSUMPTIONS "Vendor facts"): 운영 https://api.kiwoom.com / 모의
# https://mockapi.kiwoom.com; WS wss://api.kiwoom.com:10000 /
# wss://mockapi.kiwoom.com:10000 — same port, same official WS API path.
REAL_REST_DOMAIN = "https://api.kiwoom.com"
REAL_WS_ENDPOINT = "wss://api.kiwoom.com:10000/api/dostk/websocket"
# The only two environment names. "prod" is a retired name: nothing
# accepts it anywhere.
ENVIRONMENTS = ("demo", "real")


def environment_rest_domain(environment):
    """The REST domain derived from the environment. The live value is
    pinned per environment; there is no caller-supplied domain and no
    cross-environment fallback — an unknown name is a refusal."""
    if environment == "demo":
        return DEMO_REST_DOMAIN
    if environment == "real":
        return REAL_REST_DOMAIN
    raise SidecarExit(4, "environment must be demo or real: %r"
                      % (environment,))


def environment_ws_endpoint(environment):
    """The WS endpoint derived from the environment: the official base
    (mock or operational) plus the official WS API path
    /api/dostk/websocket — the same composition rule for both."""
    if environment == "demo":
        return DEMO_WS_ENDPOINT
    if environment == "real":
        return REAL_WS_ENDPOINT
    raise SidecarExit(4, "environment must be demo or real: %r"
                      % (environment,))


def env_credential_names(environment):
    """The OAuth env-variable pair for the environment (README §5.1):
    demo reads APP_KEY_MOCK/APP_SECRET_MOCK, real reads
    APP_KEY_REAL/APP_SECRET_REAL. The two pairs are separate by design
    ("키움증권은 실제 투자와 모의투자 App Key를 별도로 관리합니다.") and are
    never substituted for one another."""
    if environment == "demo":
        return ("APP_KEY_MOCK", "APP_SECRET_MOCK")
    if environment == "real":
        return ("APP_KEY_REAL", "APP_SECRET_REAL")
    raise SidecarExit(4, "environment must be demo or real: %r"
                      % (environment,))


# The official OAuth issuance path (README §5.1). Only the env token
# source uses it; the endpoint is derived from the environment's pinned
# domain — never from the wire.
OAUTH_TOKEN_PATH = "/oauth2/token"
REST_PATH = "/api/dostk/rkinfo"
# ka10080 주식분봉차트조회 (official document, 2026-11-06): one chart page
# per command; pagination judgment (cont-yn/next-key) stays with the core,
# exactly like the ka10027 path.
CHART_REST_PATH = "/api/dostk/chart"
CHART_API_ID = "ka10080"
CHART_PARAM_FIELDS = ["stk_cd", "tic_scope", "upd_stkpc_tp"]
# base_dt is the documented OPTIONAL request field: present (non-empty
# string) it is sent verbatim; absent or empty it is omitted from the body.
TOKEN_BUFFER_SECONDS = 600
# The auth-class LOGIN ack codes (README §2.2): one refresh + one retry.
LOGIN_RETRY_CODES = {8005, 8031, 8103}
# The official SDK's embedded-code rule (kiwoom/core/errors.py): Kiwoom
# often reports a generic top-level return_code and puts the specific code
# inside return_msg as "[8005:...]" (REST) or "CODE=8005" (WebSocket). The
# auth-class codes are matched in both places.
EMBEDDED_CODE_RE = re.compile(r"\[(\d{3,5}):|CODE=(\d{3,5})")
SORT_TP = {"up": "1", "down": "3"}
REST_PARAMS_FIELDS = [
    "mrkt_tp", "trde_qty_cnd", "stk_cnd", "crd_cnd", "updown_incls",
    "pric_cnd", "trde_prica_cnd", "stex_tp"]


def normalize_return_code(value):
    """The official SDK's rule (kiwoom/core/errors.py): the server emits
    return_code as an int or a numeric string ("0", "0000", "8005")
    depending on the endpoint. None/bool/blank/non-numeric mean no code."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    text = str(value).strip()
    if not text or not text.lstrip("-").isdigit():
        return None
    return int(text)


def embedded_return_code(return_msg):
    """The specific code embedded in a Kiwoom return_msg, if any."""
    match = EMBEDDED_CODE_RE.search(str(return_msg or ""))
    if match is None:
        return None
    return int(match.group(1) or match.group(2))


def ws_payload_bytes(raw):
    """One websockets recv() result as the opaque bytes the forwarding
    contract (README §3.3) requires. websockets has had no recv(decode=)
    argument since 8.0: a text frame arrives as str, a binary frame as
    bytes, and Kiwoom's wire is JSON text frames — so the str branch is
    the measured path (2026-11-09 live session: recv(decode=False) raised
    TypeError on both websockets 10.4 and 17.3, an UNVERIFIED §12 item
    that only the live wire could measure)."""
    if isinstance(raw, (bytes, bytearray)):
        return bytes(raw)
    if isinstance(raw, str):
        return raw.encode("utf-8")
    raise TypeError("ws recv() returned %s, expected str or bytes"
                    % type(raw).__name__)


class SidecarExit(Exception):
    """Clean shutdown with an exit code (0 normal, 3 token, 4 internal)."""

    def __init__(self, code, detail=""):
        super().__init__(detail or str(code))
        self.code = code
        self.detail = detail


class TokenError(Exception):
    """The token path failed. The detail never carries a token value."""


def now_iso():
    """The sidecar-owned clock: ISO 8601 with the numeric KST offset."""
    return datetime.now(KST).strftime("%Y-%m-%dT%H:%M:%S+09:00")


def parse_watchdog_seconds(text):
    """"HH:MM:SS+09:00" -> the epoch second of its next occurrence (KST).

    A moment already past today fires immediately: a session that starts
    after the watchdog must end INCOMPLETE, not run on to a silent close.
    """
    if len(text) != 14 or text[2] != ":" or text[5] != ":" or \
       text[8:] != "+09:00":
        raise SidecarExit(4, "watchdog is not HH:MM:SS+09:00: " + text)
    hh, mm, ss = int(text[0:2]), int(text[3:5]), int(text[6:8])
    if hh > 23 or mm > 59 or ss > 59:
        raise SidecarExit(4, "watchdog is outside plausible ranges: " + text)
    now = datetime.now(KST)
    target = now.replace(hour=hh, minute=mm, second=ss, microsecond=0)
    return target.timestamp()


def parse_init(line):
    """Validate the `init` instruction (README §2.1). Every field is
    required except the optional token_source (README §5.1); the approved
    PH-1 values are pinned here too — this sidecar refuses to run a
    configuration the contract does not approve. The environment is
    "demo" or "real" and every endpoint must match that environment's
    pinned value: a cross-environment mix is refused, never run."""
    try:
        cfg = json.loads(line)
    except ValueError:
        raise SidecarExit(4, "init line is not valid JSON")
    if not isinstance(cfg, dict):
        raise SidecarExit(4, "init line is not a JSON object")
    if cfg.get("protocol") != PROTOCOL:
        raise SidecarExit(4, "init protocol must be 1")
    environment = cfg.get("environment")
    if environment not in ENVIRONMENTS:
        # Fail-closed: an unknown name (including the retired "prod") is
        # never defaulted to another environment.
        raise SidecarExit(4, "init environment must be demo or real: %r"
                          % (environment,))
    if cfg.get("rest_domain") != environment_rest_domain(environment):
        raise SidecarExit(4, "rest_domain is not the official %s domain"
                          % environment)
    if cfg.get("ws_endpoint") != environment_ws_endpoint(environment):
        raise SidecarExit(4, "ws_endpoint is not the official %s endpoint"
                          % environment)
    if cfg.get("api_id") != "ka10027":
        raise SidecarExit(4, "api_id must be ka10027")
    for key, want in [("page_cap", 10), ("repoll_seconds", 300),
                      ("drain_seconds", 10), ("ack_timeout_seconds", 10)]:
        if cfg.get(key) != want:
            raise SidecarExit(4, "init %s must be the approved value %d"
                              % (key, want))
    if cfg.get("watchdog") != "15:40:00+09:00":
        raise SidecarExit(4, "init watchdog must be the approved 15:40 KST")
    profile = cfg.get("profile")
    if not isinstance(profile, str) or not 1 <= len(profile) <= 64 or \
       any(c.isspace() for c in profile):
        raise SidecarExit(4, "profile alias must be 1..64 non-space chars")
    # token_source is OPTIONAL (README §5.1): absent or "kiwoomcli" keeps
    # the kiwoomcli credential path exactly as it was — an init line that
    # does not carry the field must not change any behavior.
    source = cfg.get("token_source", "kiwoomcli")
    if source not in ("kiwoomcli", "env"):
        raise SidecarExit(4, "init token_source must be kiwoomcli or env")
    params = cfg.get("rest_params")
    if not isinstance(params, dict):
        raise SidecarExit(4, "init rest_params must be an object")
    for key in REST_PARAMS_FIELDS:
        if not isinstance(params.get(key), str):
            raise SidecarExit(4, "init rest_params.%s must be a string" % key)
    return cfg


class TokenStore:
    """The credential path (README §5): read the kiwoomcli token cache,
    refresh through `kiwoomcli auth refresh` as a subprocess, re-read.
    appkey/secretkey never enter this process; access_token never leaves
    process memory (no log, no stderr, no record, no exit report)."""

    def __init__(self, profile):
        self.profile = profile
        digest = hashlib.sha256(profile.encode("utf-8")).hexdigest()[:16]
        base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
        self.cache_path = os.path.join(
            base, "kiwoom", "profiles", "profile-%s-token.json" % digest)

    def _read(self):
        """Parse the cache file. Returns (access_token, token_type,
        expires_epoch) or None when unreadable/absent — the caller treats
        None as 'expired' (fail-closed), never as a usable token."""
        try:
            with open(self.cache_path, "r", encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, ValueError):
            return None
        if not isinstance(doc, dict):
            return None
        token = doc.get("access_token")
        if not isinstance(token, str) or not token:
            return None
        token_type = doc.get("token_type")
        if not isinstance(token_type, str):
            token_type = "Bearer"
        expires = doc.get("expires_at")
        if isinstance(expires, (int, float)) and not isinstance(expires, bool):
            expires_epoch = float(expires)
        elif isinstance(expires, str):
            try:
                expires_epoch = datetime.fromisoformat(expires).timestamp()
            except ValueError:
                return None
        else:
            return None
        return (token, token_type, expires_epoch)

    def _refresh(self):
        """Reissue through the official client. Its output is captured and
        discarded (it is not this process's evidence and might name the
        profile); only the exit code is interpreted."""
        try:
            proc = subprocess.run(
                ["kiwoomcli", "auth", "refresh", "--profile", self.profile],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            raise TokenError("token refresh subprocess failed")
        if proc.returncode != 0:
            raise TokenError("token refresh failed rc=%d" % proc.returncode)

    def get(self, force=False):
        """A token whose remaining life exceeds the 600 s buffer, refreshing
        once when not. Raises TokenError (no token value in any message)."""
        entry = self._read()
        if force or entry is None or \
           entry[2] - time.time() <= TOKEN_BUFFER_SECONDS:
            self._refresh()
            entry = self._read()
            if entry is None or \
               entry[2] - time.time() <= TOKEN_BUFFER_SECONDS:
                raise TokenError("token cache unusable after refresh")
        return entry[0], entry[1]


class EnvTokenProvider:
    """The env credential path (README §5.1, token_source="env"): read the
    environment's credential pair — APP_KEY_MOCK/APP_SECRET_MOCK for a
    demo session, APP_KEY_REAL/APP_SECRET_REAL for a real session — from
    the process environment and POST the official OAuth
    client_credentials request directly. The pairs are separate by
    design: a real session never falls back to the demo variables, and
    vice versa. The response's
    expires_dt ("YYYYMMDDHHMMSS", KST absolute) is the only expiry
    evidence — no fixed validity period is documented. The token lives in
    this process's memory: no log, no stderr, no record, no file, no exit
    report ever carries it, and neither do the exception messages (they
    name the failure class only).

    The endpoint is a constructor parameter so the contract tests can
    point it at a local fake server; the live sidecar derives it from the
    environment's pinned domain. The init-line rest_domain guard in
    parse_init is never relaxed by this path.
    """

    def __init__(self, endpoint, environment="demo", clock=time.time,
                 timeout=30, max_attempts=2):
        if environment not in ENVIRONMENTS:
            raise ValueError(
                "environment must be demo or real: %r" % (environment,))
        self.environment = environment
        self.endpoint = endpoint
        self.clock = clock
        self.timeout = timeout
        # au10001 allows roughly two issuances per second (README §5.1):
        # one issuance and at most one failure retry per get() — the
        # token is reused from memory until the 600 s buffer is reached,
        # never reissued per request.
        self.max_attempts = max_attempts
        self._token = None
        self._token_type = "Bearer"
        self._expires_epoch = 0.0

    def _credentials(self):
        """The env credentials of THIS session's environment. Missing or
        empty is a refusal that names the variable — there is no value to
        name and none is printed, and the other environment's variables
        are never substituted."""
        key_name, secret_name = env_credential_names(self.environment)
        appkey = os.environ.get(key_name, "")
        secretkey = os.environ.get(secret_name, "")
        if not appkey:
            raise TokenError(key_name + " missing or empty in environment")
        if not secretkey:
            raise TokenError(secret_name + " missing or empty in environment")
        return appkey, secretkey

    def _issue(self):
        """One OAuth issuance. Standard JSON parsing only (the official
        response is JSON — the doc example's missing comma is a typo, not
        a format). Every failure is a TokenError carrying the failure
        class only: no credential value, no token value, no vendor
        return_msg text, no request or response body ever echoed."""
        appkey, secretkey = self._credentials()
        body = json.dumps({
            "grant_type": "client_credentials",
            "appkey": appkey,
            "secretkey": secretkey,
        }, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        req = urllib.request.Request(
            self.endpoint, data=body, method="POST",
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except Exception as exc:
            # An HTTP error status is still no issuance: fail-closed with
            # the failure class only (the error response is never parsed).
            if isinstance(exc, urllib.error.HTTPError):
                exc.close()  # do not leak the error response's socket
            raise TokenError("token endpoint request failed: "
                             + type(exc).__name__)
        try:
            doc = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise TokenError("token endpoint returned non-JSON")
        if not isinstance(doc, dict):
            raise TokenError("token endpoint response is not a JSON object")
        code = normalize_return_code(doc.get("return_code"))
        if code is None:
            raise TokenError(
                "token endpoint response has no usable return_code")
        if code != 0:
            # Every issuance failure lands here (including the token-IP
            # binding error 8010, README §5.1). The numeric code is not a
            # secret; the return_msg text is never repeated into it.
            raise TokenError("token endpoint returned return_code=%d" % code)
        token = doc.get("token")
        if not isinstance(token, str) or not token:
            raise TokenError(
                "token endpoint response has no usable token field")
        token_type = doc.get("token_type")
        if not isinstance(token_type, str) or not token_type:
            token_type = "Bearer"
        expires_dt = doc.get("expires_dt")
        if not isinstance(expires_dt, str):
            raise TokenError(
                "token endpoint response has no usable expires_dt")
        try:
            expires_epoch = datetime.strptime(
                expires_dt, "%Y%m%d%H%M%S").replace(tzinfo=KST).timestamp()
        except ValueError:
            # Unparseable expiry is fail-closed: there is no documented
            # validity period to fall back to.
            raise TokenError(
                "token endpoint response has no usable expires_dt")
        return token, token_type, expires_epoch

    def get(self, force=False):
        """(token, token_type) whose remaining life exceeds the 600 s
        buffer: the cached issuance while it lasts, one reissue when the
        buffer is reached or force is set, at most max_attempts HTTP
        attempts, then TokenError (no token value in any message)."""
        if (not force and self._token is not None and
                self._expires_epoch - self.clock() > TOKEN_BUFFER_SECONDS):
            return self._token, self._token_type
        last = TokenError("token issue failed")
        for _ in range(self.max_attempts):
            try:
                token, token_type, expires_epoch = self._issue()
            except TokenError as exc:
                last = exc
                continue
            if expires_epoch - self.clock() <= TOKEN_BUFFER_SECONDS:
                # Never hand out a token the renewal window already
                # covers — the kiwoomcli path refuses the same case.
                raise TokenError(
                    "issued token expires_dt is inside the renewal buffer")
            self._token = token
            self._token_type = token_type
            self._expires_epoch = expires_epoch
            return token, token_type
        raise last


class Sidecar:
    """One collector session's communication state machine."""

    def __init__(self, cfg, repoll=300, drain=10, ack_timeout=10,
                 rest_min_interval=1.5, token_endpoint=None):
        self.cfg = cfg
        self.environment = cfg["environment"]
        self.ws_endpoint = cfg["ws_endpoint"]
        self.rest_domain = cfg["rest_domain"]
        self.api_id = cfg["api_id"]
        self.rest_params = cfg["rest_params"]
        source = cfg.get("token_source", "kiwoomcli")
        if source == "env":
            # README §5.1: the env path derives its endpoint from the
            # environment's pinned domain in production; the constructor
            # parameter exists only so the contract tests can point it at
            # a local fake server. The init-line rest_domain guard in
            # parse_init is never relaxed by this path.
            self.store = EnvTokenProvider(
                token_endpoint or environment_rest_domain(self.environment)
                + OAUTH_TOKEN_PATH, environment=self.environment)
        else:
            self.store = TokenStore(cfg["profile"])
        # Durations are constructor parameters so the contract tests can
        # shrink them; parse_init pins the approved live values.
        self.repoll = repoll
        self.drain = drain
        self.ack_timeout = ack_timeout
        # The mock vendor limit is one TR per second per account/token
        # (notice #49, ASSUMPTIONS "Vendor facts"; observed live
        # 2026-11-02: back-to-back page 2 -> HTTP 429 "허용된 요청
        # 개수를 초과하였습니다 ... 유량=1, API ID=ka10027" — and once
        # more at exactly 1.0 s client spacing, while a 7-page chain
        # paced the same way passed: arrival jitter can compress the
        # gap below the server's window). All REST traffic is spaced by
        # this much — 1.5 s (the documented 1 s ceiling plus jitter
        # margin) is the approved live value, tests may shrink it.
        self.rest_min_interval = rest_min_interval
        self._rest_pace_lock = threading.Lock()
        self._last_rest_monotonic = 0.0
        self.watchdog_text = cfg["watchdog"]
        self.token = None
        self.token_type = "Bearer"
        self.conn_gen = 0
        self.ws = None
        self.ws_task = None
        self.quiet_task = None
        self.draining = False
        self.stopping = False
        self.out_lock = threading.Lock()
        self.first_open = asyncio.Event()

    # ---------------------------------------------------------- wire out

    def emit(self, ev):
        """One HCJ-safe event line on stdout. Token values never enter ev.
        A broken pipe is the core dying first: exit 4 (README §2.6)."""
        ev["t"] = now_iso()
        line = json.dumps(ev, ensure_ascii=False, separators=(",", ":"))
        try:
            with self.out_lock:
                sys.stdout.write(line + "\n")
                sys.stdout.flush()
        except (BrokenPipeError, OSError):
            os._exit(4)

    # ------------------------------------------------------ token path

    def acquire_token(self, force=False):
        token, token_type = self.store.get(force=force)
        self.token = token
        self.token_type = token_type or "Bearer"

    # ----------------------------------------------------- ws connection

    async def connect_loop(self):
        """The single connection-maintenance loop (README §2.2): connect,
        LOGIN handshake, report `conn open` (generation 1 upward), serve
        until the wire closes, report `closed_*`, retry after
        ack_timeout_seconds — forever, until `stop`."""
        import websockets
        while not self.stopping:
            try:
                ws = await websockets.connect(
                    self.ws_endpoint, ping_interval=None)
            except Exception as exc:
                self.emit({
                    "ev": "conn", "state": "closed_error",
                    "conn": self.conn_gen + 1, "code": 1006,
                    "reason": "connect failed: " + type(exc).__name__})
                await asyncio.sleep(self.ack_timeout)
                continue
            opened = await self.handshake(ws)
            if not opened:
                try:
                    await ws.close(code=1000)
                except Exception:
                    pass
                await asyncio.sleep(self.ack_timeout)
                continue
            self.conn_gen += 1
            self.ws = ws
            self.first_open.set()
            self.emit({"ev": "conn", "state": "open",
                             "conn": self.conn_gen})
            code, reason = await self.serve(ws, self.conn_gen)
            self.ws = None
            state = "closed_ok" if code == 1000 else "closed_error"
            self.emit({"ev": "conn", "state": state,
                             "conn": self.conn_gen,
                             "code": code, "reason": reason})
            if self.stopping:
                return
            await asyncio.sleep(self.ack_timeout)

    async def handshake(self, ws):
        """LOGIN (README §2.2): one send, await the ack. An auth-class
        code triggers one refresh + one retry. Other received messages are
        forwarded untouched — nothing is dropped while waiting."""
        for attempt in (0, 1):
            try:
                await ws.send(json.dumps(
                    {"trnm": "LOGIN", "token": self.token},
                    ensure_ascii=False, separators=(",", ":")))
                while True:
                    raw = await asyncio.wait_for(
                        ws.recv(), timeout=self.ack_timeout)
                    data = ws_payload_bytes(raw)
                    await self.forward(data, self.conn_gen + 1)
                    try:
                        doc = json.loads(data.decode("utf-8"))
                    except (UnicodeDecodeError, ValueError):
                        continue
                    if not isinstance(doc, dict) or \
                       doc.get("trnm") != "LOGIN" or \
                       "return_code" not in doc:
                        continue
                    code = normalize_return_code(doc.get("return_code"))
                    if code is None:
                        # Present, but in no form the official sources
                        # document (int or canonical numeric string, the
                        # SDK's normalize_return_code rule): fail-closed,
                        # never a silent success.
                        self.emit({
                            "ev": "conn", "state": "closed_error",
                            "conn": self.conn_gen + 1, "code": 1000,
                            "reason": "login failed return_code=%r" %
                                      (doc.get("return_code"),)})
                        return False
                    if code == 0:
                        return True
                    if attempt == 0 and (code in LOGIN_RETRY_CODES or
                                         embedded_return_code(
                                             doc.get("return_msg"))
                                         in LOGIN_RETRY_CODES):
                        try:
                            self.acquire_token(force=True)
                            self.emit({"ev": "token"})
                        except TokenError as exc:
                            self.emit({
                                "ev": "error", "what": "token",
                                "detail": exc.args[0]})
                        break  # retry the handshake once
                    self.emit({
                        "ev": "conn", "state": "closed_error",
                        "conn": self.conn_gen + 1, "code": 1000,
                        "reason": "login failed return_code=%s" % code})
                    return False
            except (asyncio.TimeoutError, asyncio.IncompleteReadError,
                    Exception) as exc:
                # A wire failure during the handshake: report and retry.
                self.emit({
                    "ev": "conn", "state": "closed_error",
                    "conn": self.conn_gen + 1, "code": 1006,
                    "reason": "login handshake failed: " +
                              type(exc).__name__})
                return False
        self.emit({
            "ev": "conn", "state": "closed_error", "conn": self.conn_gen + 1,
            "code": 1000, "reason": "login failed after refresh+retry"})
        return False

    async def serve(self, ws, gen):
        """The receive loop of one opened connection: forward every
        application payload as opaque bytes, echo PING, keep the quiet
        timer honest. Returns the close (code, reason)."""
        import websockets
        try:
            while True:
                raw = await ws.recv()
                data = ws_payload_bytes(raw)
                await self.forward(data, gen)
                if data.strip() == b"PING":
                    self.send_text(ws, data.decode("utf-8"))
                    continue
                try:
                    doc = json.loads(data.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    doc = None
                if isinstance(doc, dict) and doc.get("trnm") == "PING":
                    self.send_text(ws, data.decode("utf-8"))
        except websockets.ConnectionClosed as e:
            frame = e.rcvd
            if frame is not None:
                return frame.code, frame.reason
            return 1006, "no close frame"
        except Exception as exc:
            return 1006, "recv failed: " + type(exc).__name__

    def send_text(self, ws, text):
        """Fire-and-forget text send on the running loop; a failure is
        reported as error what=send (README §3.6) and the connection
        machinery handles the dead wire."""
        async def _send():
            try:
                await ws.send(text)
            except Exception as exc:
                self.emit({"ev": "error", "what": "send",
                                 "detail": "send failed: " +
                                           type(exc).__name__})
        asyncio.get_running_loop().create_task(_send())

    async def forward(self, data, gen):
        """Every received application payload, byte-exact, opaque (README
        §3.3). Receipt also resets the quiet window (README §2.3)."""
        self.emit({"ev": "ws", "conn": gen,
                         "payload_hex": data.hex()})
        if self.quiet_task is not None:
            self.arm_quiet()

    # ------------------------------------------------------ quiet timer

    def arm_quiet(self):
        self.disarm_quiet()
        self.quiet_task = asyncio.get_running_loop().create_task(
            self._quiet_fire())

    def disarm_quiet(self):
        if self.quiet_task is not None:
            self.quiet_task.cancel()
            self.quiet_task = None

    async def _quiet_fire(self):
        await asyncio.sleep(self.ack_timeout)
        self.quiet_task = None
        self.emit({"ev": "timer", "kind": "quiet"})

    # ----------------------------------------------------- poll/watchdog

    async def poll_timer(self):
        """repoll_seconds after the first conn open, then on cadence
        (README §3.4) — the signal to start a re-poll, nothing more."""
        await self.first_open.wait()
        while not self.stopping:
            await asyncio.sleep(self.repoll)
            self.emit({"ev": "timer", "kind": "poll"})

    async def watchdog_timer(self):
        """One-shot at the watchdog wall-clock time (README §3.4)."""
        delay = parse_watchdog_seconds(self.watchdog_text) - time.time()
        if delay > 0:
            await asyncio.sleep(delay)
        if not self.stopping:
            self.emit({"ev": "timer", "kind": "watchdog"})

    # ------------------------------------------------------------ REST

    def _pace_rest(self):
        """Serialize and space REST requests by rest_min_interval (the
        vendor's one-TR-per-second limit) so consecutive pages never
        race into the 429. Runs on the executor thread, off the loop."""
        with self._rest_pace_lock:
            now = time.monotonic()
            wait = (self._last_rest_monotonic + self.rest_min_interval
                    - now)
            if wait > 0:
                time.sleep(wait)
            self._last_rest_monotonic = time.monotonic()

    def do_rest(self, direction, cont_yn, next_key):
        """One ka10027 page request on the caller's executor thread.
        The response is reported raw — status, response cont-yn/next-key
        headers, body bytes hex — whatever the status (README §2.4). A
        transport failure (no HTTP response at all) is error what=rest."""
        self._pace_rest()
        body = dict(self.rest_params)
        body["sort_tp"] = SORT_TP[direction]
        data = json.dumps(body, ensure_ascii=False,
                          separators=(",", ":")).encode("utf-8")
        headers = {
            "Content-Type": "application/json;charset=utf-8",
            "api-id": self.api_id,
            "authorization": ("%s %s" % (self.token_type, self.token)).strip(),
        }
        if cont_yn == "Y":
            headers["cont-yn"] = "Y"
        if next_key:
            headers["next-key"] = next_key
        req = urllib.request.Request(
            self.rest_domain + REST_PATH, data=data, headers=headers,
            method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return (resp.status, resp.headers.get("cont-yn") or "",
                        resp.headers.get("next-key") or "", resp.read())
        except urllib.error.HTTPError as e:
            # An HTTP response with an error status is still a response:
            # the core owns the verdict (401 included).
            try:
                body = e.read()
                cont = e.headers.get("cont-yn") or ""
                key = e.headers.get("next-key") or ""
            except Exception:
                body, cont, key = b"", "", ""
            return e.code, cont, key, body
        except Exception as exc:
            raise RestError("transport failed: " + type(exc).__name__)

    async def handle_rest(self, cmd):
        loop = asyncio.get_running_loop()
        try:
            status, cont, key, body = await loop.run_in_executor(
                None, self.do_rest, cmd["direction"],
                cmd.get("cont_yn", ""), cmd.get("next_key", ""))
        except RestError as exc:
            self.emit({"ev": "error", "what": "rest",
                             "detail": exc.args[0]})
            return
        self.emit({"ev": "rest", "direction": cmd["direction"],
                         "page": cmd["page"], "status": status,
                         "cont_yn": cont, "next_key": key,
                         "body_hex": body.hex()})

    # ---------------------------------------------------- ka10080 chart REST

    def do_chart(self, params, cont_yn, next_key):
        """One ka10080 chart page request on the caller's executor thread
        (README §2.7). The declared request scope (params) is sent verbatim —
        this process never judges a scope; the response is reported raw
        exactly like do_rest. Pacing is the shared vendor limit: every REST
        request, rkinfo or chart, is spaced by rest_min_interval."""
        self._pace_rest()
        data = json.dumps(params, ensure_ascii=False,
                          separators=(",", ":")).encode("utf-8")
        headers = {
            "Content-Type": "application/json;charset=utf-8",
            "api-id": CHART_API_ID,
            "authorization": ("%s %s" % (self.token_type, self.token)).strip(),
        }
        if cont_yn == "Y":
            headers["cont-yn"] = "Y"
        if next_key:
            headers["next-key"] = next_key
        req = urllib.request.Request(
            self.rest_domain + CHART_REST_PATH, data=data, headers=headers,
            method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return (resp.status, resp.headers.get("cont-yn") or "",
                        resp.headers.get("next-key") or "", resp.read())
        except urllib.error.HTTPError as e:
            # An HTTP response with an error status is still a response:
            # the core owns the verdict (401 included).
            try:
                body = e.read()
                cont = e.headers.get("cont-yn") or ""
                key = e.headers.get("next-key") or ""
            except Exception:
                body, cont, key = b"", "", ""
            return e.code, cont, key, body
        except Exception as exc:
            raise RestError("transport failed: " + type(exc).__name__)

    def _chart_params(self, cmd):
        """Validate the chart command's declared scope (transport shape
        only, README §2.7): api_id pinned to the approved chart API, the
        three documented required params as non-empty strings, base_dt an
        optional string (empty/absent = omitted from the request body).
        The scope's VALUE authority (enums, the declared 3-minute scope)
        is the Nim core's vendor_input layer, never this process."""
        if cmd.get("api_id") != CHART_API_ID:
            raise SidecarExit(4, "chart api_id must be " + CHART_API_ID)
        params = cmd.get("params")
        if not isinstance(params, dict):
            raise SidecarExit(4, "chart command needs a params object")
        for key in CHART_PARAM_FIELDS:
            value = params.get(key)
            if not isinstance(value, str) or not value:
                raise SidecarExit(
                    4, "chart params.%s must be a non-empty string" % key)
        base_dt = params.get("base_dt")
        if base_dt is not None and not isinstance(base_dt, str):
            raise SidecarExit(4, "chart params.base_dt must be a string")
        body = dict(params)
        if not body.get("base_dt"):
            body.pop("base_dt", None)
        return body

    async def handle_chart(self, cmd):
        params = self._chart_params(cmd)
        cont_yn = cmd.get("cont_yn", "")
        if cont_yn not in ("", "Y", "N"):
            raise SidecarExit(4, "chart cont_yn must be Y, N or empty")
        next_key = cmd.get("next_key", "")
        if not isinstance(next_key, str):
            raise SidecarExit(4, "chart next_key must be a string")
        if isinstance(cmd.get("page"), bool) or \
           not isinstance(cmd.get("page"), int) or cmd["page"] < 1:
            raise SidecarExit(4, "chart command needs page >= 1")
        loop = asyncio.get_running_loop()
        try:
            status, cont, key, body = await loop.run_in_executor(
                None, self.do_chart, params, cont_yn, next_key)
        except RestError as exc:
            self.emit({"ev": "error", "what": "rest",
                             "detail": exc.args[0]})
            return
        self.emit({"ev": "rest_chart", "api_id": CHART_API_ID,
                         "page": cmd["page"], "status": status,
                         "cont_yn": cont, "next_key": key,
                         "body_hex": body.hex()})

    # -------------------------------------------------------- commands

    async def handle(self, cmd):
        ctype = cmd.get("type")
        if ctype == "connect":
            if self.ws_task is None:
                self.ws_task = asyncio.get_running_loop().create_task(
                    self.connect_loop())
        elif ctype == "reg":
            data = cmd.get("data")
            if not isinstance(data, list) or not isinstance(cmd.get("gen"),
                                                            int) or \
               cmd["gen"] < 1:
                raise SidecarExit(4, "reg command needs gen>=1 and data")
            envelope = {"trnm": "REG", "grp_no": "1", "refresh": "1",
                        "data": data}
            if self.ws is None:
                raise SidecarExit(4, "reg command with no open connection")
            self.send_text(self.ws, json.dumps(
                envelope, ensure_ascii=False, separators=(",", ":")))
            self.arm_quiet()
        elif ctype == "remove":
            data = cmd.get("data")
            if not isinstance(data, list) or not isinstance(cmd.get("gen"),
                                                            int) or \
               cmd["gen"] < 1:
                raise SidecarExit(4, "remove command needs gen>=1 and data")
            envelope = {"trnm": "REMOVE", "grp_no": "1", "data": data}
            if self.ws is None:
                raise SidecarExit(4, "remove command with no open connection")
            self.send_text(self.ws, json.dumps(
                envelope, ensure_ascii=False, separators=(",", ":")))
            self.arm_quiet()
        elif ctype == "rest_req":
            await self.handle_rest(cmd)
        elif ctype == "chart_req":
            await self.handle_chart(cmd)
        elif ctype == "refresh_token":
            try:
                self.acquire_token(force=True)
                self.emit({"ev": "token"})
            except TokenError as exc:
                self.emit({"ev": "error", "what": "token",
                                 "detail": exc.args[0]})
        elif ctype == "disarm":
            self.disarm_quiet()
        elif ctype == "wait_drain":
            # A task, not an await: the command loop stays responsive to
            # `stop` while the drain window runs (README §2.6).
            asyncio.get_running_loop().create_task(self._drain())
        elif ctype == "stop":
            self.stopping = True
            self.disarm_quiet()
            if self.ws is not None:
                try:
                    await self.ws.close(code=1000)
                except Exception:
                    pass
            raise SidecarExit(0)
        else:
            # An unknown command is never ignored (README §1).
            raise SidecarExit(4, "unknown command type: %r" % (ctype,))

    async def _drain(self):
        await asyncio.sleep(self.drain)
        if not self.stopping:
            self.emit({"ev": "drain_done"})

    @staticmethod
    def _stdin_thread(loop, queue):
        try:
            for line in sys.stdin:
                line = line.strip()
                if line:
                    loop.call_soon_threadsafe(queue.put_nowait, line)
        except (OSError, ValueError):
            pass
        loop.call_soon_threadsafe(queue.put_nowait, None)

    async def run(self):
        """ready -> serve commands until stop / EOF / fault (README §3.1)."""
        loop = asyncio.get_running_loop()
        queue = asyncio.Queue()
        threading.Thread(target=self._stdin_thread, args=(loop, queue),
                         daemon=True).start()
        loop.create_task(self.poll_timer())
        loop.create_task(self.watchdog_timer())
        self.emit({"ev": "ready"})
        while True:
            line = await queue.get()
            if line is None:
                # stdin closed: the core is gone — a broken pipe (exit 4).
                raise SidecarExit(4, "stdin closed before stop")
            try:
                cmd = json.loads(line)
                if not isinstance(cmd, dict):
                    raise ValueError("command is not a JSON object")
            except ValueError as exc:
                raise SidecarExit(4, "command line is not valid JSON: %s"
                                  % exc)
            await self.handle(cmd)


class RestError(Exception):
    """A REST transport failure (no HTTP response at all)."""


def main(token_endpoint=None):
    line = sys.stdin.readline()
    if not line:
        raise SidecarExit(4, "stdin closed before init")
    cfg = parse_init(line)
    repoll = cfg["repoll_seconds"]
    drain = cfg["drain_seconds"]
    ack_timeout = cfg["ack_timeout_seconds"]
    sidecar = Sidecar(cfg, repoll=repoll, drain=drain,
                      ack_timeout=ack_timeout,
                      token_endpoint=token_endpoint)

    async def runner():
        try:
            sidecar.acquire_token()
        except TokenError as exc:
            sidecar.emit({"ev": "error", "what": "token",
                          "detail": exc.args[0]})
            return 3
        try:
            await sidecar.run()
        except SidecarExit as exc:
            return exc.code
        return 0

    try:
        code = asyncio.run(runner())
    except SidecarExit as exc:
        code = exc.code
    except KeyboardInterrupt:
        code = 4
    except Exception:
        # A sidecar internal fault is reported, never swallowed; the detail
        # names the exception class only (a traceback could carry data).
        try:
            sidecar.emit({"ev": "error", "what": "internal",
                          "detail": "internal fault"})
        except Exception:
            pass
        code = 4
    return code


if __name__ == "__main__":
    sys.exit(main())
