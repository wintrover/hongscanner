#!/usr/bin/env python3
"""Hong Scanner read-only API (VS-3 PR-6, VS-2 opening MA20 mode).

Contract: tools/api/README.md. The API serves RECORDED facts only —
the run directories (--runs) and the append-only event ledger
(--ledger), plus the optional delivery ledger (--delivery). It judges
nothing, replays nothing, recomputes no verdict: every response is a
projection of recorded bytes plus the cheap rederivations the contract
names (sha256 comparison against a recorded CHECKSUMS.sha256, presence
of recorded markers and operator-recorded verify output). Running the
Nim verify binary is outside this process's scope, always. The one
display classification beyond the fold is the §3.7 opening MA20 mode:
a time-window filter over a recorded observed_at plus an
integer-only comparison of recorded prices against recorded close
sums — recorded values in, tags out, never a market judgment. The
§3.7 change history is dual-path: pre-contract runs project the
state-comparison changes, runs whose config record declares
events_contract "top10-v1" translate the Core-confirmed TOP10 facts
already recorded in the journal field-for-field — a display
conversion, never a judgment either way.

Security boundaries (README §5):
  - binds 127.0.0.1 by default; --bind takes a concrete IPv4 unicast
    address or 0.0.0.0 (container behind the platform ingress only —
    README §1/§5); multicast, broadcast and every non-IPv4 string are
    refused before any socket exists;
  - GET only — every other method is a JSON 405;
  - identifiers are validated before any path is built (event ids must
    be 64 lowercase hex digits, session ids must name an existing run
    directory); "..", separators and percent-encoded traversals are
    rejected before lookup and the resolved path must stay inside the
    runs root;
  - responses never contain filesystem paths, credential values, or
    the non-projected run.json fields (host, pid, egress_ip, ...);
  - artifact names read from a recorded CHECKSUMS.sha256 are untrusted
    input: names outside the safe set are refused, never opened.

Cold-path readiness (README §1/§4): /mobile/market-view answers
503 {"error":{"code":"warming"}} with Retry-After: 5 from startup
until the background prewarm of the latest eligible run lands (READY
— normal serving); a prewarm that faults is FAILED for the process
lifetime and every market-view request answers 500 data_fault. Other
endpoints are unaffected by the readiness state. main() starts the
prewarm BEFORE constructing the server: the ThreadingHTTPServer
constructor binds and listens (socketserver server_activate ->
socket.listen), and the listening socket may exist only after WARMING
is set, so no client can be accepted before the 503 warming answer
is in force.

Ops observability (README §8): a prewarm that lands FAILED fires the
ops side-channel exactly once per process — one tools/notify/
ops_alert.py attempt (or the HS_OPS_ALERT_CMD command; an empty value
disables), reported ONLY as stderr journal lines (OPS_ALERT_SKIPPED /
OPS_ALERT_CALLED / OPS_ALERT_FAILED_ERROR), ledger-free, no retry,
delivery never guaranteed. /status also exposes the readiness state
machine, and main() prints one SERVE_PROVENANCE stdout line before the
SERVE line: the process's own git/blob/sha256 agreement — bounded
self-reported trust, never an attestation.

Python 3.13, standard library only (http.server). No new dependencies.
"""

import argparse
import hashlib
import ipaddress
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from functools import cmp_to_key
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

# --bind default: a no-option call binds loopback only, as before.
BIND_HOST = "127.0.0.1"

EVENT_ID_RE = re.compile(r"^[0-9a-f]{64}$")
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
# sha256sum line: "<64 lowercase hex>  <name>" (two-space text mode).
CHECKSUM_LINE_RE = re.compile(r"^([0-9a-f]{64})  (.+)$")
# Untrusted artifact names from a recorded CHECKSUMS.sha256: a single
# safe path component only. Anything else is refused, never opened.
SAFE_ARTIFACT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$")
# The event schema's own observed_at shape (numeric offset, KST form in
# every recorded stamp): the opening-mode window predicate parses the
# recorded stamp only, never the wall clock.
OBSERVED_AT_RE = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"[+-][0-9]{2}:[0-9]{2}$")
# The ka10027 cur_prc shape: a signed KRW integer (the sign is the
# day's move direction; the fold strips it).
SIGNED_PRICE_RE = re.compile(r"^[+-][0-9]+$")
# The ka10081 close shape: an unsigned integer string.
DAY_CLOSE_RE = re.compile(r"^[0-9]+$")
# The ka10081 daily-row dt shape: YYYYMMDD.
BAR_DT_RE = re.compile(r"^[0-9]{8}$")
# Korea Standard Time: the recorded observed_at stamps are converted to
# this zone for the window predicate — a pure string-to-moment
# conversion, the wall clock is never read.
KST = timezone(timedelta(hours=9))

RUN_JSON = "run.json"
INPUT_JSONL = "input.hcj.jsonl"
EVENTS_JSONL = "events.hcj.jsonl"
CHECKSUMS = "CHECKSUMS.sha256"
COMMITTED_MARKER = "input.hcj.jsonl.committed"
VERIFY_OUT = "verify.stdout"

# run.json fields the API projects. Everything else recorded in the
# file (host, pid, egress_ip, build details, ...) is deliberately not
# served: the projection serves what consumers need, not the file.
RUN_JSON_FIELDS = ("session_date", "run_id", "started_at", "code_commit")

CANDIDATE_PREFIX = "CANDIDATE_"

# The FAILED ops side-channel (README §8): exactly one alert attempt
# per process on the prewarm's FAILED transition, journal-only
# reporting, no retry.
OPS_ALERT_TITLE = "Hong Scanner API FAILED"
OPS_ALERT_BODY_MAX = 300
OPS_ALERT_CHILD_STDERR_MAX = 200
OPS_ALERT_TIMEOUT_S = 10

# /mobile/market-view (README §3.7): a market-collection run's identity
# is the committed config record the collector writes into
# input.hcj.jsonl (real collection runs have no run.json). environment
# is a collector-only field, so smoke/fixture/drill directories are
# ineligible by absence. The head/tail windows below bound how much of
# these all-day-growing files is ever read.
MARKET_ENVIRONMENTS = ("demo", "real")
SESSION_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MARKET_CONFIG_HEAD_BYTES = 16384
MARKET_EVENTS_TAIL_BYTES = 65536
MARKET_TOP_N = 10
MARKET_HISTORY_N = 100
# The stock-name dictionary (README §3.7): the folded vendor body
# values of the ka10027 ranking rows are the names, keyed by stk_cd —
# and the same rows' cur_prc values are the per-chain-pair prices.
MARKET_NAME_API = "ka10027"
MARKET_NAME_LIST_KEY = "pred_pre_flu_rt_upper"
# The ka10027 query sort_tp values (the collector's own request enum):
# "1" ranks the rising leg, "3" the falling leg — the chain-pair
# decomposition's recorded signal.
MARKET_SORT_RISING = "1"
MARKET_SORT_FALLING = "3"
# The MA20 source (README §3.7): the ka10081 daily-bar bodies recorded
# in the same input.hcj.jsonl. The fold's dependent row shape is dt
# (YYYYMMDD, descending) and cur_prc (an unsigned close integer); the
# symbol comes from the recorded query's stk_cd, the ka10080 chart
# scope's convention.
MARKET_MA20_API = "ka10081"
MARKET_MA20_LIST_KEY = "stk_dt_pole_chart_qry"
MARKET_MA20_DAYS = 20
# The VS-2 opening window (README §3.7): a half-open interval over the
# time-of-day of the reference group's RECORDED observed_at (KST) —
# [09:00:00, 09:30:00). Never the wall clock.
OPENING_WINDOW_START = "09:00:00"
OPENING_WINDOW_END = "09:30:00"
# The §3.7 item whitelist: the projection is field-bounded so the
# response size is mechanically capped (at most 120 items). ma20_tag is
# the opening mode's display classification ("ABOVE"/"BELOW" inside the
# window, null outside) — a recorded-value comparison, not a judgment.
MARKET_ITEM_FIELDS = ("data_quality", "direction", "event_id",
                      "event_type", "ma20_tag", "name", "observed_at",
                      "rank", "symbol")
# The §3.7 change-history vocabulary: the display-only classification
# of one TOP10 state change between CONFIRMED observation groups. Not
# event types — the ledger's event_type is projected verbatim only in
# top10 items, never in a change record.
MARKET_CHANGE_TYPES = ("CANDIDATE_EXITED", "RANK_CHANGED",
                        "TOP10_ENTERED", "TOP10_EXITED")
# The §3.7 change-record whitelist: nine fields — change_type (a
# MARKET_CHANGE_TYPES value) and prev_rank (the previous confirmed
# group's recorded rank) are the projection's own display values; every
# other value is recorded in the change's evidence event, name comes
# from the folded dictionary. Field-bounded like MARKET_ITEM_FIELDS.
MARKET_CHANGE_FIELDS = ("change_type", "data_quality", "direction",
                        "event_id", "name", "observed_at", "prev_rank",
                        "rank", "symbol")
# The §3.7 history dual-path discriminator (README §3.7): a config
# record raw carrying events_contract "top10-v1" marks a run whose
# events.hcj.jsonl already holds the Core-confirmed TOP10 change facts
# — history is their display translation (the fact path). A config
# without the key is a pre-contract run: the legacy state-comparison
# projection, unchanged. Any other recorded value is a contract this
# projection cannot consume — DataFault, never a guess.
MARKET_EVENTS_CONTRACT = "top10-v1"
# The TOP10 fact event types the fact path consumes (the Core journal
# event types of events_contract top10-v1): each translates one-to-one
# into a MARKET_CHANGE_TYPES change record. A TOP10_* event type
# outside this set is an unknown future fact — DataFault, fail-closed.
MARKET_FACT_TYPES = ("RANK_CHANGED", "TOP10_ENTERED", "TOP10_EXITED")
TOP10_PREFIX = "TOP10_"

# /events/{event_id} (README §3.4): after the committed-lines cursor
# validates the whole ledger, the one-event lookup scans backward in
# fixed byte blocks instead of materializing every event. 256 KiB keeps
# a block at a few hundred ledger lines while bounding the read size.
LEDGER_SCAN_BLOCK = 256 * 1024


class DataFault(Exception):
    """A recorded file is unreadable or violates its recorded shape.
    Fail-closed: the endpoint answers HTTP 500, it never silently skips
    a corrupted record. Messages carry file basenames only — never
    absolute paths."""


class ServiceWarming(Exception):
    """The §3.7 market projection's cold-path prewarm is still running.
    The market view answers HTTP 503 with Retry-After: 5 — a bounded
    "try again soon", never a blocking wait, never a partial fold."""


def canonical_bytes(obj):
    """Deterministic response encoding: UTF-8, compact separators, keys
    in codepoint-ascending order (the HCJ canonical discipline). The
    caller appends the single trailing LF."""
    return json.dumps(obj, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def _reason(exc):
    """A path-free reason string for error messages."""
    return getattr(exc, "strerror", None) or exc.__class__.__name__


def resolve_bind(value):
    """--bind validation (README §1/§5): a dotted-quad IPv4 unicast
    address, or 0.0.0.0 (all interfaces — a container behind the
    platform ingress only). Returns the address string, or None for a
    refusal: multicast (224.0.0.0/4), the broadcast address
    255.255.255.255, the reserved blocks (240.0.0.0/4 and 0.0.0.0/8
    beyond 0.0.0.0 itself), and anything that is not four decimal
    octets 0..255. The caller turns None into the argparse usage error
    (exit 2); a well-formed address the OS cannot bind stays on the
    existing bind-failure path (exit 4)."""
    try:
        addr = ipaddress.IPv4Address(value)
    except ValueError:  # AddressValueError: not four 0..255 octets
        return None
    if addr == ipaddress.IPv4Address("0.0.0.0"):
        return str(addr)
    broadcast = ipaddress.IPv4Address("255.255.255.255")
    if addr.is_multicast or addr == broadcast or addr.is_reserved \
            or int(addr) >> 24 == 0:
        return None
    return str(addr)


def sha256_file(path):
    """sha256 hex of the file bytes, or None when the file is absent.
    Any other read fault is a DataFault (fail-closed), never a silent
    mismatch."""
    try:
        with open(path, "rb") as f:
            digest = hashlib.sha256()
            for chunk in iter(lambda: f.read(65536), b""):
                digest.update(chunk)
            return digest.hexdigest()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))


def read_committed_lines(path):
    """JSONL records committed to `path` as parsed JSON objects, in
    file order. Same reading discipline as the notify ledgers: a
    trailing line without LF is a concurrently-appending record that
    has not been committed yet and is skipped, never half-consumed. A
    malformed COMMITTED line is a DataFault — corruption is not
    skipped. An existing file with zero committed lines (its single
    writer opened it with O_CREAT, no record yet) returns ([], True):
    callers must project that state, never crash on it. Returns
    (objects, file_present)."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return [], False
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))
    if data and not data.endswith(b"\n"):
        data = data[:data.rfind(b"\n") + 1]
    objects = []
    if data:
        for i, raw in enumerate(data.split(b"\n")[:-1], start=1):
            if not raw:
                raise DataFault("%s line %d is empty"
                                % (os.path.basename(path), i))
            try:
                obj = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError) as exc:
                raise DataFault("%s line %d is not valid UTF-8 JSON: %s"
                                % (os.path.basename(path), i, exc))
            if not isinstance(obj, dict):
                raise DataFault("%s line %d is not a JSON object"
                                % (os.path.basename(path), i))
            objects.append(obj)
    return objects, True


class _EventsLinesState:
    """Incremental state for the committed-lines cache of one
    events.hcj.jsonl: the byte offset of the last committed LF, the
    number of committed lines before it (DataFault line numbers) and
    the parsed objects themselves."""
    __slots__ = ("path", "st_dev", "st_ino", "offset", "line_no", "events")

    def __init__(self, path, st_dev=0, st_ino=0):
        self.path = path
        self.st_dev = st_dev
        self.st_ino = st_ino
        self.offset = 0
        self.line_no = 0
        self.events = []


def _read_committed_lines_inc(path, prev_state=None):
    """Incremental read_committed_lines (README §3.7: the market view's
    events.hcj.jsonl grows all day, so a per-request full rescan is the
    endpoint's hot path — the journal is read as only its new bytes).

    Resumes from prev_state.offset when (path, st_dev, st_ino) match and
    st_size >= prev_state.offset: st_size == offset returns the cached
    objects in O(1), a grown file reads only the bytes after offset. A
    smaller size (a truncate), an inode replacement, a path change or a
    missing file resets cleanly from byte 0. The reading discipline is
    read_committed_lines exactly: a torn trailing line (no LF) is never
    consumed and leaves offset at the last committed LF; a malformed
    committed line (empty, non-JSON, non-object) raises DataFault
    without mutating prev_state — the caller's cache keeps the last
    good prefix and the fault repeats on every call until the file is
    fixed (fail-closed, never cached). Returns (objects, file_present,
    state); state is None when the file is absent. The returned list is
    the new state's own — callers must treat it as read-only, never
    mutate it in place (an incremental call clones before appending)."""
    try:
        st = os.stat(path)
        f = open(path, "rb")
    except FileNotFoundError:
        return [], False, None
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))
    name = os.path.basename(path)
    with f:
        if prev_state is not None \
                and prev_state.path == path \
                and prev_state.st_dev == st.st_dev \
                and prev_state.st_ino == st.st_ino \
                and st.st_size >= prev_state.offset:
            if st.st_size == prev_state.offset:
                return prev_state.events, True, prev_state
            state = _EventsLinesState(path, st.st_dev, st.st_ino)
            state.offset = prev_state.offset
            state.line_no = prev_state.line_no
            state.events = list(prev_state.events)
            f.seek(state.offset)
        else:
            state = _EventsLinesState(path, st.st_dev, st.st_ino)
        events = state.events
        i = state.line_no
        committed_offset = state.offset
        while True:
            raw = f.readline()
            if not raw or not raw.endswith(b"\n"):
                break  # EOF, or a torn tail: not committed yet
            i += 1
            committed_offset = f.tell()
            raw = raw[:-1]
            if not raw:
                raise DataFault("%s line %d is empty" % (name, i))
            try:
                obj = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError) as exc:
                raise DataFault("%s line %d is not valid UTF-8 JSON: %s"
                                % (name, i, exc))
            if not isinstance(obj, dict):
                raise DataFault("%s line %d is not a JSON object" % (name, i))
            events.append(obj)
        state.offset = committed_offset
        state.line_no = i
        return events, True, state


class _LedgerTailState:
    """Incremental aggregate state for the notify ledger: the byte offset
    of the last committed LF, the number of committed lines before it
    (DataFault line numbers), and the projection counters the endpoints
    need — never the events themselves (constant memory over a ledger
    that grows every day)."""
    __slots__ = ("path", "st_dev", "st_ino", "offset", "line_no",
                 "count", "by_type", "by_severity", "last",
                 "last_session_id")

    def __init__(self, path, st_dev=0, st_ino=0):
        self.path = path
        self.st_dev = st_dev
        self.st_ino = st_ino
        self.offset = 0
        self.line_no = 0
        self.count = 0
        self.by_type = Counter()
        self.by_severity = Counter()
        self.last = None
        self.last_session_id = None


def _read_ledger_tail_inc(path, prev_state=None):
    """Incremental version of _ledger_events()' full-ledger scan: the
    notify ledger grows all day, so /status and the tail-first event
    lookup consume only bytes committed since the last call.

    Resumes from prev_state.offset when (path, st_dev, st_ino) match and
    st_size >= prev_state.offset: st_size == offset returns prev_state
    unchanged in O(1), a grown file reads only the bytes after offset. A
    smaller size (a truncate), an inode replacement, a path change or a
    missing file resets cleanly from byte 0. The reading discipline is
    read_committed_lines exactly: a torn trailing line (no LF) is never
    consumed and leaves offset at the last committed LF; a malformed
    committed line — empty, non-JSON, non-object, or missing a string
    event_id/event_type/session_id/severity — raises DataFault with the
    file-wide line number. prev_state is never mutated: the returned
    state is a new object built on a clone of the last good prefix, and
    a DataFault leaves the caller's slot untouched (fail-closed, never
    cached). Returns (state, file_present); state is None when the file
    is absent."""
    try:
        st = os.stat(path)
        f = open(path, "rb")
    except FileNotFoundError:
        return None, False
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))
    name = os.path.basename(path)
    with f:
        if prev_state is not None \
                and prev_state.path == path \
                and prev_state.st_dev == st.st_dev \
                and prev_state.st_ino == st.st_ino \
                and st.st_size >= prev_state.offset:
            if st.st_size == prev_state.offset:
                return prev_state, True
            state = _LedgerTailState(path, st.st_dev, st.st_ino)
            state.offset = prev_state.offset
            state.line_no = prev_state.line_no
            state.count = prev_state.count
            state.by_type = Counter(prev_state.by_type)
            state.by_severity = Counter(prev_state.by_severity)
            state.last = (dict(prev_state.last)
                          if prev_state.last is not None else None)
            state.last_session_id = prev_state.last_session_id
            f.seek(state.offset)
        else:
            state = _LedgerTailState(path, st.st_dev, st.st_ino)
        i = state.line_no
        committed_offset = state.offset
        while True:
            raw = f.readline()
            if not raw or not raw.endswith(b"\n"):
                break  # EOF, or a torn tail: not committed yet
            i += 1
            committed_offset = f.tell()
            raw = raw[:-1]
            if not raw:
                raise DataFault("%s line %d is empty" % (name, i))
            try:
                obj = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError) as exc:
                raise DataFault("%s line %d is not valid UTF-8 JSON: %s"
                                % (name, i, exc))
            if not isinstance(obj, dict):
                raise DataFault("%s line %d is not a JSON object" % (name, i))
            for field in ("event_id", "event_type", "session_id",
                          "severity"):
                if not isinstance(obj.get(field), str):
                    raise DataFault("%s line %d has no %s" % (name, i, field))
            state.count += 1
            state.by_type[obj["event_type"]] += 1
            state.by_severity[obj["severity"]] += 1
            state.last = {k: obj[k] for k in ("event_id", "event_type",
                                              "observed_at")
                          if k in obj}
            state.last_session_id = obj["session_id"]
        state.offset = committed_offset
        state.line_no = i
        return state, True


def read_head_config(path):
    """The committed config record near the head of an input.hcj.jsonl —
    the recorded identity of a real collection run. Bounded: only the
    first MARKET_CONFIG_HEAD_BYTES are read (the file grows all day) and
    parsing stops at the first kind:"config" record. A line counts only
    if LF-terminated (a non-LF tail is not committed yet); a malformed
    committed line before the config record is a DataFault — the same
    discipline as read_committed_lines. Returns the config record's
    `raw` object, or None when no committed config record is in the
    window (absence is served, never guessed)."""
    try:
        with open(path, "rb") as f:
            data = f.read(MARKET_CONFIG_HEAD_BYTES)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))
    if data and not data.endswith(b"\n"):
        data = data[:data.rfind(b"\n") + 1]
    if not data:
        return None
    name = os.path.basename(path)
    for i, raw in enumerate(data.split(b"\n")[:-1], start=1):
        if not raw:
            raise DataFault("%s line %d is empty" % (name, i))
        try:
            obj = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise DataFault("%s line %d is not valid UTF-8 JSON: %s"
                            % (name, i, exc))
        if not isinstance(obj, dict):
            raise DataFault("%s line %d is not a JSON object" % (name, i))
        if obj.get("kind") == "config":
            config = obj.get("raw")
            if not isinstance(config, dict):
                raise DataFault("%s line %d config raw is not a JSON "
                                "object" % (name, i))
            return config
    return None


def read_last_observed_at(path):
    """The observed_at of the LAST committed record of a JSONL file,
    read from a bounded tail window (MARKET_EVENTS_TAIL_BYTES from the
    end — the whole file is never read). A trailing line without LF is
    not committed and is skipped. A malformed committed last line is a
    DataFault. Returns None when the file is absent or has no committed
    line — the caller ranks such a run last, it never guesses."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - MARKET_EVENTS_TAIL_BYTES))
            data = f.read()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))
    if data and not data.endswith(b"\n"):
        data = data[:data.rfind(b"\n") + 1]
    if not data:
        return None
    name = os.path.basename(path)
    line = data.split(b"\n")[-2]
    if not line:
        raise DataFault("%s last committed line is empty" % name)
    try:
        obj = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise DataFault("%s last committed line is not valid UTF-8 "
                        "JSON: %s" % (name, exc))
    if not isinstance(obj, dict):
        raise DataFault("%s last committed line is not a JSON object"
                        % name)
    observed_at = obj.get("observed_at")
    if not isinstance(observed_at, str):
        raise DataFault("%s last committed line has no observed_at"
                        % name)
    return observed_at


class _MarketFoldState:
    """Incremental state for fold_market_projection (VS-C)."""
    __slots__ = (
        "path", "session_date", "st_dev", "st_ino", "offset", "line_no",
        "names", "snapshots", "chain", "pair_rising", "bars", "ma20",
    )

    def __init__(self, path, session_date, st_dev=0, st_ino=0):
        self.path = path
        self.session_date = session_date
        self.st_dev = st_dev
        self.st_ino = st_ino
        self.offset = 0
        self.line_no = 0
        self.names = {}
        self.snapshots = []
        self.chain = None
        self.pair_rising = None
        self.bars = {}
        self.ma20 = {}


def _clone_fold_state(src):
    dst = _MarketFoldState(src.path, src.session_date, src.st_dev, src.st_ino)
    dst.offset = src.offset
    dst.line_no = src.line_no
    dst.names = dict(src.names)
    dst.snapshots = list(src.snapshots)
    dst.chain = [src.chain[0], dict(src.chain[1])] \
        if src.chain is not None else None
    dst.pair_rising = dict(src.pair_rising) \
        if src.pair_rising is not None else None
    dst.bars = {k: [set(v[0]), v[1], v[2]] for k, v in src.bars.items()}
    dst.ma20 = dict(src.ma20)
    return dst


def _fold_market_projection_inc(path, session_date, prev_state=None):
    """Incremental §3.7 market fold over committed lines of input.hcj.jsonl.

    Resumes from prev_state.offset when (path, session_date, st_dev, st_ino)
    match and st_size >= prev_state.offset; otherwise starts fresh from 0.
    Torn trailing lines (no LF) are never consumed and leave offset at the
    last committed LF. Returns a new _MarketFoldState on success without
    mutating prev_state if a DataFault is raised.
    """
    if not isinstance(session_date, str) \
            or SESSION_DATE_RE.match(session_date) is None:
        raise DataFault("%s MA20 fold session_date is not the recorded "
                        "YYYY-MM-DD shape" % INPUT_JSONL)
    session_digits = session_date.replace("-", "")
    try:
        st = os.stat(path)
        f = open(path, "rb")
    except FileNotFoundError:
        return _MarketFoldState(path, session_date)
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))
    name = os.path.basename(path)
    with f:
        if prev_state is not None \
                and prev_state.path == path \
                and prev_state.session_date == session_date \
                and prev_state.st_dev == st.st_dev \
                and prev_state.st_ino == st.st_ino \
                and st.st_size >= prev_state.offset:
            if st.st_size == prev_state.offset:
                return prev_state
            state = _clone_fold_state(prev_state)
            f.seek(state.offset)
        else:
            state = _MarketFoldState(path, session_date, st.st_dev, st.st_ino)
        names = state.names
        snapshots = state.snapshots
        chain = state.chain
        pair_rising = state.pair_rising
        bars = state.bars
        ma20 = state.ma20
        i = state.line_no
        committed_offset = state.offset
        while True:
            raw = f.readline()
            if not raw:
                break
            if not raw.endswith(b"\n"):
                break  # torn tail: a concurrent append, not committed yet
            i += 1
            committed_offset = f.tell()
            raw = raw[:-1]
            if not raw:
                raise DataFault("%s line %d is empty" % (name, i))
            try:
                obj = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError) as exc:
                raise DataFault("%s line %d is not valid UTF-8 JSON: %s"
                                % (name, i, exc))
            if not isinstance(obj, dict):
                raise DataFault("%s line %d is not a JSON object" % (name, i))
            if obj.get("kind") != "rest_resp":
                continue
            rec = obj.get("raw")
            if not isinstance(rec, dict):
                raise DataFault("%s line %d rest_resp raw is not a JSON "
                                "object" % (name, i))
            api_id = rec.get("api_id")
            if not isinstance(api_id, str):
                raise DataFault("%s line %d rest_resp has no api_id"
                                % (name, i))
            if api_id == MARKET_NAME_API:
                query = rec.get("query")
                if not isinstance(query, dict):
                    raise DataFault("%s line %d rest_resp has no query"
                                    % (name, i))
                sort_tp = query.get("sort_tp")
                if sort_tp not in (MARKET_SORT_RISING, MARKET_SORT_FALLING):
                    raise DataFault("%s line %d ka10027 query sort_tp is not "
                                    "the recorded 1 or 3" % (name, i))
                page = rec.get("page")
                if not isinstance(page, int) or isinstance(page, bool) \
                        or page < 1:
                    raise DataFault("%s line %d rest_resp page is not >= 1"
                                    % (name, i))
                cont_yn = rec.get("cont_yn")
                if not isinstance(cont_yn, str):
                    raise DataFault("%s line %d rest_resp has no cont_yn"
                                    % (name, i))
                body_hex = rec.get("body_hex")
                if not isinstance(body_hex, str):
                    raise DataFault("%s line %d rest_resp has no body_hex"
                                    % (name, i))
                try:
                    body = bytes.fromhex(body_hex)
                except ValueError:
                    raise DataFault("%s line %d body_hex is not hex"
                                    % (name, i))
                prices = {}
                try:
                    doc = json.loads(body.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    doc = None
                if isinstance(doc, dict):
                    rows = doc.get(MARKET_NAME_LIST_KEY)
                    if isinstance(rows, list):
                        for row in rows:
                            if not isinstance(row, dict) \
                                    or not isinstance(row.get("stk_cd"), str) \
                                    or not isinstance(row.get("stk_nm"), str):
                                raise DataFault(
                                    "%s line %d ranking row has no stk_cd "
                                    "or stk_nm" % (name, i))
                            cur_prc = row.get("cur_prc")
                            if not isinstance(cur_prc, str) \
                                    or SIGNED_PRICE_RE.match(cur_prc) is None:
                                raise DataFault(
                                    "%s line %d ranking row cur_prc is not "
                                    "a signed integer price" % (name, i))
                            names[row["stk_cd"]] = row["stk_nm"]
                            prices[row["stk_cd"]] = int(cur_prc[1:])
                if chain is not None and (chain[0] != sort_tp or page == 1):
                    chain = None  # interrupted chain: dropped, never a
                                  # snapshot
                if chain is None:
                    chain = [sort_tp, {}]
                chain[1].update(prices)
                if cont_yn != "Y":
                    if chain[0] == MARKET_SORT_RISING:
                        pair_rising = chain[1]
                    else:
                        snapshot = dict(pair_rising) \
                            if pair_rising is not None else {}
                        snapshot.update(chain[1])
                        if snapshot:
                            snapshots.append(snapshot)
                        pair_rising = None
                    chain = None
            elif api_id == MARKET_MA20_API:
                query = rec.get("query")
                if not isinstance(query, dict):
                    raise DataFault("%s line %d rest_resp has no query"
                                    % (name, i))
                symbol = query.get("stk_cd")
                if not isinstance(symbol, str):
                    raise DataFault("%s line %d ka10081 query has no stk_cd"
                                    % (name, i))
                body_hex = rec.get("body_hex")
                if not isinstance(body_hex, str):
                    raise DataFault("%s line %d rest_resp has no body_hex"
                                    % (name, i))
                try:
                    body = bytes.fromhex(body_hex)
                except ValueError:
                    raise DataFault("%s line %d body_hex is not hex"
                                    % (name, i))
                try:
                    doc = json.loads(body.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    doc = None
                if isinstance(doc, dict):
                    rows = doc.get(MARKET_MA20_LIST_KEY)
                    if isinstance(rows, list):
                        entry = bars.get(symbol)
                        for row in rows:
                            if not isinstance(row, dict):
                                raise DataFault("%s line %d daily row is not "
                                                "a JSON object" % (name, i))
                            dt = row.get("dt")
                            if not isinstance(dt, str) \
                                    or BAR_DT_RE.match(dt) is None:
                                raise DataFault("%s line %d daily row dt is "
                                                "not YYYYMMDD" % (name, i))
                            cur_prc = row.get("cur_prc")
                            if not isinstance(cur_prc, str) \
                                    or DAY_CLOSE_RE.match(cur_prc) is None:
                                raise DataFault(
                                    "%s line %d daily row cur_prc is not an "
                                    "unsigned integer close" % (name, i))
                            if dt >= session_digits:
                                continue  # the session's in-progress bar
                            if entry is None:
                                entry = [set(), 0, 0]
                                bars[symbol] = entry
                            if dt in entry[0] or entry[2] >= MARKET_MA20_DAYS:
                                continue  # an older or already-counted day
                            entry[0].add(dt)
                            entry[1] += int(cur_prc)
                            entry[2] += 1
                        if entry is not None and entry[2] >= MARKET_MA20_DAYS:
                            ma20[symbol] = entry[1]
        state.offset = committed_offset
        state.line_no = i
        state.chain = chain
        state.pair_rising = pair_rising
        return state


def fold_market_projection(path, session_date):
    """The §3.7 market fold of one input.hcj.jsonl — one streaming scan,
    three pure derivations of recorded bytes."""
    state = _fold_market_projection_inc(path, session_date)
    return state.names, state.snapshots, state.ma20


def _ma20_distance_order(entries, above):
    """One MA20-mode list in its contract order: by the relative distance
    from MA20, G = 20·P/Σ − 1, compared as the integer cross product
    20·P₁·ΣC₂ vs 20·P₂·ΣC₁ — no float anywhere (Python integers are
    exact, the cross product never divides). Descending G for the
    above-list (furthest above MA20 first), ascending for the
    below-list (furthest below first); a tie breaks on the symbol's
    codepoint order. `entries` are (price, close_sum, symbol, item)."""
    def compare(left, right):
        cross_left = 20 * left[0] * right[1]
        cross_right = 20 * right[0] * left[1]
        if cross_left != cross_right:
            if above:
                return -1 if cross_left > cross_right else 1
            return -1 if cross_left < cross_right else 1
        if left[2] != right[2]:
            return -1 if left[2] < right[2] else 1
        return 0
    entries.sort(key=cmp_to_key(compare))
    return entries


def opening_market_top10(confirmed, snapshots, ma20):
    """The VS-2 opening MA20 projection (README §3.7): the top10 lists
    reconstituted from the recorded prices of the reference group's
    chain-pair against the recorded 20-day close sums — a display-only
    classification of recorded values (recorded price vs recorded
    average), never a market judgment. Returns ("core", [], []) when
    the projection does not apply — no confirmed observation group, or
    the reference group's recorded observed_at time-of-day (KST) is
    outside the half-open window [OPENING_WINDOW_START,
    OPENING_WINDOW_END); the recorded predicate only, never the wall
    clock — and ("opening_ma20", rising, falling) otherwise. A
    correspondence failure raises DataFault (fail-closed).

    `confirmed` is the event fold's capture of the last CONFIRMED
    observation group: (1-based group index, observed_at stamp, the
    per-symbol candidate state at the group's confirmation — the
    last-upserted item per symbol, deduplicated over UP/DOWN — and the
    symbols the group's batch upserted). The chain-pair
    correspondence: the group's upserted symbols must be a subset of
    one snapshot's symbols, the candidate mappings being snapshot
    index = group index + offset for offset 0, +1, -1 in that order
    (the same-index mapping is the measured correspondence; the
    subset check re-establishes the offset per run, fail-closed). An
    EXITED symbol is never part of the check — it left the chain-pair
    by definition. A state symbol missing from the mapped snapshot
    (no recorded price) or from the ma20 map (no twenty recorded
    closes) is honestly excluded from both lists, and so is a price
    exactly at the average — never a fallback to the core
    classification.

    Classification: 20·P vs ΣC (P = the recorded current price of the
    mapped snapshot, ΣC = the recorded 20-close sum): above → the
    rising list, below → the falling list. Each list is ordered by
    _ma20_distance_order and cut to MARKET_TOP_N. The projected items
    are the recorded candidate state verbatim — only the placement and
    the ma20_tag are the mode's."""
    if confirmed is None:
        return "core", [], [], None
    index, stamp, state, upserts = confirmed
    if OBSERVED_AT_RE.match(stamp) is None:
        raise DataFault("%s observed_at is not the canonical timestamp "
                        "shape" % EVENTS_JSONL)
    try:
        moment = datetime.fromisoformat(stamp)
    except ValueError:
        raise DataFault("%s observed_at is not a calendar moment"
                        % EVENTS_JSONL)
    clock = moment.astimezone(KST).strftime("%H:%M:%S")
    if not (OPENING_WINDOW_START <= clock < OPENING_WINDOW_END):
        return "core", [], [], None
    snapshot = None
    for offset in (0, 1, -1):
        candidate = index + offset - 1
        if 0 <= candidate < len(snapshots) \
                and upserts <= set(snapshots[candidate]):
            snapshot = snapshots[candidate]
            break
    if snapshot is None:
        raise DataFault("%s chain-pair correspondence failed: observation "
                        "group %d upsert symbols are in no chain-pair "
                        "snapshot (offsets 0/+1/-1)"
                        % (INPUT_JSONL, index))
    above, below = [], []
    for symbol, item in state.items():
        price = snapshot.get(symbol)
        close_sum = ma20.get(symbol)
        if price is None or close_sum is None:
            continue  # honest exclusion: no recorded price / closes
        if 20 * price > close_sum:
            above.append((price, close_sum, symbol, item))
        elif 20 * price < close_sum:
            below.append((price, close_sum, symbol, item))
    rising, falling = [], []
    for entries, is_above, target in ((above, True, rising),
                                      (below, False, falling)):
        for price, close_sum, symbol, item in \
                _ma20_distance_order(entries, is_above)[:MARKET_TOP_N]:
            item["ma20_tag"] = "ABOVE" if is_above else "BELOW"
            target.append({field: item[field]
                           for field in MARKET_ITEM_FIELDS})
    rising_complete = len(above) >= MARKET_TOP_N
    falling_complete = len(below) >= MARKET_TOP_N
    coverage = {
        "candidate_count": len(state),
        "computable_count": len(above) + len(below),
        "rising_count": len(above),
        "falling_count": len(below),
        "rising_complete": rising_complete,
        "falling_complete": falling_complete,
        "status": ("COMPLETE" if rising_complete and falling_complete
                   else "PARTIAL"),
    }
    return "opening_ma20", rising, falling, coverage


class Projector:
    """Read-only projection of the recorded sources. Every method
    returns plain JSON-safe data (strings, integers, booleans, null,
    arrays, objects — no floats)."""

    def __init__(self, runs_root, ledger_path, delivery_path=None):
        self.runs_root = runs_root
        self.ledger_path = ledger_path
        self.delivery_path = delivery_path
        self._runs_real = os.path.realpath(runs_root)
        # The §3.7 market-fold memoization: one entry, the last
        # published (path, size, mtime_ns) -> (names, snapshots, ma20)
        # fold. ThreadingHTTPServer serves concurrent requests, so the
        # slot is guarded by one lock.
        self._fold_lock = threading.Lock()
        self._fold_entry = None
        # The events.hcj.jsonl committed-lines memoization: one slot,
        # the last published incremental read (path, st_dev, st_ino,
        # offset, line_no, events) — the same single-entry discipline
        # as the fold slot (a different selected run rescans), guarded
        # by its own lock.
        self._events_lock = threading.Lock()
        self._events_entry = None
        # The notify ledger's aggregate cursor (README §3.1/§3.4): one
        # slot, the last published incremental read (path, st_dev,
        # st_ino, offset, line_no, counters, latest event) — never the
        # events themselves, so /status stays constant-memory while the
        # ledger grows. The same single-entry discipline as the slots
        # above, guarded by its own lock; a fault is never published.
        self._ledger_tail_lock = threading.Lock()
        self._ledger_tail_entry = None
        # The cold-path readiness contract (README §1/§4): WARMING from
        # the first prewarm_market_projection_async() call until the
        # background scan lands — READY on success, FAILED with the
        # recorded reason on any Exception, terminal for the process
        # (single-flight: no second prewarm). The default is READY so a
        # Projector constructed directly (the unit suites, no prewarm)
        # serves market_view() unchanged.
        self._readiness_lock = threading.Lock()
        self._readiness_state = "READY"
        self._readiness_error = None
        self._prewarm_started = False
        # The FAILED ops alert's exactly-once latch (README §8):
        # _mark_failed flips it under the readiness lock — one alert
        # attempt per process, on the single FAILED transition only.
        self._alert_sent = False

    def prewarm_market_projection_async(self):
        """Warm the latest eligible run's §3.7 market fold in the background
        so the first /mobile/market-view request hits the warm incremental
        path instead of paying the cold-start scan. main() calls this
        BEFORE constructing the server (the ThreadingHTTPServer
        constructor binds and listens): the call's synchronous part
        sets WARMING before any listening socket can accept a client.

        Cold-path readiness: single-flight — the first call wins and later
        calls return without starting a second thread (one prewarm per
        process). The call moves the projector to WARMING; the background
        scan's landing is terminal: READY on success, FAILED with the
        recorded reason on any Exception — a prewarm failure is surfaced to
        every market-view request as a DataFault, never swallowed."""
        with self._readiness_lock:
            if self._prewarm_started:
                return
            self._prewarm_started = True
            self._readiness_state = "WARMING"
            self._readiness_error = None

        def _warm():
            try:
                names = self._session_names()
                eligible = []
                for name in names:
                    run_dir = os.path.join(self.runs_root, name)
                    input_path = os.path.join(run_dir, INPUT_JSONL)
                    events_path = os.path.join(run_dir, EVENTS_JSONL)
                    if not (os.path.isfile(input_path)
                            and os.path.isfile(events_path)):
                        continue
                    config = read_head_config(input_path)
                    if config is None:
                        continue
                    if config.get("environment") not in MARKET_ENVIRONMENTS:
                        continue
                    session_date = config.get("session_date")
                    if not isinstance(session_date, str) \
                            or SESSION_DATE_RE.match(session_date) is None:
                        continue
                    eligible.append((name, session_date,
                                     read_last_observed_at(events_path)))
                if eligible:
                    session, session_date, _ = max(
                        eligible, key=lambda r: (r[1], r[2] or "", r[0]))
                    self._market_projection(
                        os.path.join(self.runs_root, session, INPUT_JSONL),
                        session_date)
                    self._events_committed_lines(
                        os.path.join(self.runs_root, session, EVENTS_JSONL))
            except Exception as exc:
                if self._mark_failed(exc):
                    self._notify_failed(exc)
                return
            with self._readiness_lock:
                self._readiness_state = "READY"
        threading.Thread(target=_warm, daemon=True).start()

    def _mark_failed(self, exc):
        """The FAILED transition under one lock: record the terminal
        state and its reason, and decide — atomically, exactly once per
        process — whether this caller owes the ops alert. The winner
        runs _notify_failed OUTSIDE the lock: the alert subprocess must
        never hold the readiness lock."""
        with self._readiness_lock:
            self._readiness_state = "FAILED"
            self._readiness_error = str(exc)
            should_alert = not self._alert_sent
            self._alert_sent = True
            return should_alert

    def _notify_failed(self, exc):
        """The FAILED ops alert side-channel (README §8): one
        tools/notify/ops_alert.py attempt per process, reported only as
        stderr journal lines — no ledger, no file writes, no retry; the
        child accepting is never delivery. HS_OPS_ALERT_CMD replaces
        the command wholesale (the test seam; its value is split with
        shlex and run as-is, no argument expansion); an empty or
        whitespace value disables the alert. Never raises: an alert
        fault is journaled, never propagated into the warming thread."""
        mono_ns = time.monotonic_ns()
        boot_id = _boot_id()
        wall = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        configured = os.environ.get("HS_OPS_ALERT_CMD")
        if configured is not None and not configured.strip():
            sys.stderr.write("OPS_ALERT_SKIPPED reason=disabled"
                             " mono_ns=%d boot_id=%s wall=%s\n"
                             % (mono_ns, boot_id, wall))
            return
        # One line, bounded, no env values or credentials: only the
        # failure's own reason text, newlines flattened.
        body = " ".join(str(exc).split())[:OPS_ALERT_BODY_MAX]
        try:
            if configured is None:
                cmd = [sys.executable,
                       os.path.join(_repo_root(), "tools", "notify",
                                    "ops_alert.py"),
                       OPS_ALERT_TITLE, body]
            else:
                cmd = shlex.split(configured)
            done = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=OPS_ALERT_TIMEOUT_S)
        except Exception as alert_exc:
            sys.stderr.write("OPS_ALERT_FAILED_ERROR reason=%s"
                             " mono_ns=%d boot_id=%s\n"
                             % (alert_exc.__class__.__name__, mono_ns,
                                boot_id))
            return
        result = "accepted" if done.returncode == 0 else "failed"
        sys.stderr.write("OPS_ALERT_CALLED result=%s rc=%d mono_ns=%d"
                         " boot_id=%s\n"
                         % (result, done.returncode, mono_ns, boot_id))
        if done.returncode != 0 and done.stderr:
            child = " ".join(done.stderr.split())[:OPS_ALERT_CHILD_STDERR_MAX]
            sys.stderr.write("OPS_ALERT_STDERR=%s\n" % child)

    # ---- run directories -------------------------------------------------

    def _session_names(self):
        try:
            names = os.listdir(self.runs_root)
        except OSError as exc:
            raise DataFault("runs directory unreadable: %s" % _reason(exc))
        return sorted(n for n in names
                      if os.path.isdir(os.path.join(self.runs_root, n)))

    def _run_dir(self, session):
        """The run directory for a validated session id, or None. The
        resolved path must stay inside the runs root (defense in depth
        behind the id validation)."""
        candidate = os.path.realpath(os.path.join(self.runs_root, session))
        if candidate != self._runs_real and \
                candidate.startswith(self._runs_real + os.sep) and \
                os.path.isdir(candidate):
            return candidate
        return None

    def _run_json(self, run_dir):
        path = os.path.join(run_dir, RUN_JSON)
        try:
            with open(path, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise DataFault("%s unreadable: %s" % (RUN_JSON, _reason(exc)))
        try:
            obj = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise DataFault("%s is not valid UTF-8 JSON: %s" % (RUN_JSON, exc))
        if not isinstance(obj, dict):
            raise DataFault("%s is not a JSON object" % RUN_JSON)
        return obj

    @staticmethod
    def _run_summary(name, run_json):
        """The whitelisted projection of one run.json. Absent or
        non-string fields are null — absence is served, not filled."""
        summary = {"session": name, "run_json_present": run_json is not None}
        for field in RUN_JSON_FIELDS:
            value = run_json.get(field) if isinstance(run_json, dict) else None
            summary[field] = value if isinstance(value, str) else None
        return summary

    def sessions(self):
        names = self._session_names()
        return {"count": len(names),
                "sessions": [self._run_summary(n, self._run_json(
                                 os.path.join(self.runs_root, n)))
                             for n in names]}

    # ---- event ledger ----------------------------------------------------

    def _ledger_events(self):
        """Committed ledger events in ledger order. Minimal shape
        validation for the fields this projection relies on; anything
        else in a record is served verbatim. Returns (events, present)."""
        events, present = read_committed_lines(self.ledger_path)
        if present:
            for i, ev in enumerate(events, start=1):
                for field in ("event_id", "event_type", "session_id",
                              "severity"):
                    if not isinstance(ev.get(field), str):
                        raise DataFault("ledger.hcj.jsonl line %d has no %s"
                                        % (i, field))
        return events, present

    def _ledger_tail(self):
        """The memoized aggregate cursor of the notify ledger (/status
        and the event tail scan): one slot holding the last published
        incremental read — path, identity, offset, line count, the
        by-type/by-severity counters and the latest event's fields.
        Constant memory regardless of ledger size. The lock serializes
        concurrent ThreadingHTTPServer requests around read-and-publish;
        a DataFault is never published — the slot keeps the last good
        prefix, so the fault repeats until the file is fixed. Returns
        (state, present) with _read_ledger_tail_inc's semantics."""
        with self._ledger_tail_lock:
            state, present = _read_ledger_tail_inc(
                self.ledger_path, self._ledger_tail_entry)
            self._ledger_tail_entry = state
            return state, present

    def _delivery_latest(self):
        """Latest delivery record per (event_id, device_id), the same
        last-record-wins rule the delivery ledger documents. Returns
        (map, configured, present) where map is {} when absent."""
        if self.delivery_path is None:
            return {}, False, None
        records, present = read_committed_lines(self.delivery_path)
        latest = {}
        if present:
            for i, rec in enumerate(records, start=1):
                if not isinstance(rec.get("device_id"), str) or \
                        not isinstance(rec.get("state"), str) or \
                        not isinstance(rec.get("attempts"), int) or \
                        isinstance(rec.get("attempts"), bool) or \
                        not isinstance(rec.get("event_id"), str):
                    raise DataFault("delivery.hcj.jsonl line %d violates "
                                    "the recorded shape" % i)
                latest[(rec["event_id"], rec["device_id"])] = rec
        return latest, True, present

    def _delivery_for(self, latest, event_id):
        """Per-device latest records for one event, sorted by device_id.
        The event_id itself is the map key, not repeated per record."""
        rows = [rec for (eid, _), rec in latest.items() if eid == event_id]
        return [{k: v for k, v in rec.items() if k != "event_id"}
                for rec in sorted(rows, key=lambda r: r["device_id"])]

    # ---- endpoints -------------------------------------------------------

    def status(self):
        names = self._session_names()
        latest_summary = None
        if names:
            latest_summary = self._run_summary(
                names[-1], self._run_json(os.path.join(self.runs_root,
                                                       names[-1])))
        tail, ledger_present = self._ledger_tail()
        if ledger_present:
            # A present-but-empty ledger (its single writer opened the
            # file with O_CREAT before the first committed record) is an
            # honest zero-count projection, never an IndexError (§3).
            # The incremental cursor serves the same bytes the old full
            # scan did, without materializing the event list.
            events_block = {
                "ledger_present": True,
                "count": tail.count,
                "by_type": dict(sorted(tail.by_type.items())),
                "by_severity": dict(sorted(tail.by_severity.items())),
                "latest_session_id": tail.last_session_id,
                "latest_event": (dict(tail.last)
                                 if tail.last is not None else None),
            }
        else:
            events_block = {"ledger_present": False, "count": None,
                            "by_type": None, "by_severity": None,
                            "latest_session_id": None, "latest_event": None}
        latest_deliveries, configured, present = self._delivery_latest()
        if not configured:
            delivery_block = {"configured": False, "present": None,
                              "by_state": None, "pairs": None,
                              "devices": None}
        elif not present:
            delivery_block = {"configured": True, "present": False,
                              "by_state": None, "pairs": None,
                              "devices": None}
        else:
            delivery_block = {
                "configured": True,
                "present": True,
                "by_state": dict(sorted(Counter(
                    rec["state"] for rec in latest_deliveries.values())
                    .items())),
                "pairs": len(latest_deliveries),
                "devices": len({rec["device_id"] for
                                rec in latest_deliveries.values()}),
            }
        # readiness: the §1/§8 cold-path state machine's current value,
        # read under its lock — an API-process fact only, never a data
        # freshness or composite health verdict.
        with self._readiness_lock:
            readiness = {"state": self._readiness_state,
                         "error": self._readiness_error}
        return {"sessions": {"count": len(names), "latest": latest_summary},
                "events": events_block,
                "delivery": delivery_block,
                "readiness": readiness}

    def candidates(self):
        events, ledger_present = self._ledger_events()
        if not ledger_present:
            return {"ledger_present": False, "session_id": None,
                    "count": None, "events": None}
        if not events:
            # Same empty-ledger discipline as status(): a zero-record
            # ledger projects an empty candidate list, never a crash.
            return {"ledger_present": True, "session_id": None,
                    "count": 0, "events": []}
        session_id = events[-1]["session_id"]
        chosen = [ev for ev in events
                  if ev["session_id"] == session_id
                  and ev["event_type"].startswith(CANDIDATE_PREFIX)]
        return {"ledger_present": True, "session_id": session_id,
                "count": len(chosen), "events": chosen}

    def events(self, session_filter=None):
        events, ledger_present = self._ledger_events()
        latest_deliveries, configured, present = self._delivery_latest()
        if not ledger_present:
            return {"ledger_present": False, "count": None, "events": None,
                    "delivery": None}
        if session_filter is not None:
            events = [ev for ev in events
                      if ev["session_id"] == session_filter]
        delivery = {}
        if configured and present:
            delivered_ids = {eid for eid, _ in latest_deliveries}
            delivery = {ev["event_id"]:
                        self._delivery_for(latest_deliveries,
                                           ev["event_id"])
                        for ev in events
                        if ev["event_id"] in delivered_ids}
        return {"ledger_present": True, "count": len(events),
                "events": events, "delivery": delivery}

    def _event_from_tail(self, event_id, state):
        """Backward block scan of the validated ledger prefix
        [0, state.offset) for one event fact.

        The caller has just advanced the committed-lines cursor to EOF,
        which validated every committed line from byte 0 — so corruption
        anywhere in the ledger has already faulted and this scan never
        skips it. Blocks are read from the end and reassembled across
        block boundaries before UTF-8 decoding, so a multi-byte character
        split by a block edge is never misread. A concurrent append past
        state.offset is not part of this answer.

        event_id is a content hash: repeated ledger lines carrying it are
        the same fact. The first match met while scanning backward (the
        newest occurrence) is returned."""
        name = os.path.basename(self.ledger_path)
        try:
            f = open(self.ledger_path, "rb")
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise DataFault("%s unreadable: %s" % (name, _reason(exc)))
        with f:
            pos = state.offset
            carry = b""
            while pos > 0:
                start = max(0, pos - LEDGER_SCAN_BLOCK)
                try:
                    f.seek(start)
                    chunk = f.read(pos - start)
                except OSError as exc:
                    raise DataFault("%s unreadable: %s"
                                    % (name, _reason(exc)))
                if len(chunk) != pos - start:
                    # The file shrank or was replaced after the cursor
                    # validated it: never serve a guessed prefix.
                    raise DataFault("%s changed while reading" % name)
                buf = chunk + carry
                pieces = buf.split(b"\n")
                if start > 0:
                    carry = pieces[0]
                    complete = pieces[1:]
                else:
                    carry = b""
                    complete = pieces
                for raw in reversed(complete):
                    if not raw:
                        continue
                    try:
                        obj = json.loads(raw.decode("utf-8"))
                    except (UnicodeDecodeError, ValueError) as exc:
                        raise DataFault("%s tail line is not valid UTF-8 "
                                        "JSON: %s" % (name, exc))
                    if not isinstance(obj, dict):
                        raise DataFault("%s tail line is not a JSON object"
                                        % name)
                    if obj.get("event_id") == event_id:
                        return obj
                pos = start
        return None

    def event(self, event_id):
        """The one event fact and its delivery records, or None when the
        id is not in the ledger (the handler answers 404).

        The committed-lines cursor advances to EOF first, validating
        every new committed ledger byte exactly like read_committed_lines
        — a corrupt committed line still answers 500, never a skipped
        tail. The lookup then scans the validated prefix backward and
        returns the first (newest) match, since event_id is a content
        hash and duplicate lines are the same fact."""
        state, ledger_present = self._ledger_tail()
        latest_deliveries, _, delivery_present = self._delivery_latest()
        if not ledger_present:
            return None
        ev = self._event_from_tail(event_id, state)
        if ev is None:
            return None
        delivery = self._delivery_for(latest_deliveries, event_id) \
            if delivery_present else []
        return {"event": ev, "delivery": delivery}

    # ---- mobile market view (README §3.7) ---------------------------------

    def _market_projection(self, path, session_date):
        """The memoized §3.7 market fold for one input.hcj.jsonl: a pure
        derivation of recorded bytes (the ka10027 names and prices, the
        ka10081 close sums), so unlike the per-request event fold it is
        cached in-process. The key is the practical invalidation triple
        (path, size, mtime_ns) — not a cryptographic fingerprint: a
        rewrite restoring the same size and mtime_ns would be served
        stale. The session_date of the fold is the selected run's own
        config value, a function of the same path, so the triple pins
        it too. A scan is published only when the file's stat matches
        before and after the read (a file changing mid-scan is served
        as its consistent prefix, never cached). A DataFault is never
        cached — a corrupt file faults on every request until it is
        fixed. The slot holds one entry: a different selected run
        rescans."""
        with self._fold_lock:
            state = _fold_market_projection_inc(path, session_date,
                                                self._fold_entry)
            self._fold_entry = state
            return state.names, state.snapshots, state.ma20

    def _events_committed_lines(self, path):
        """The memoized committed-lines read of one events.hcj.jsonl —
        the market view's event source (README §3.7: the journal grows
        all day, so the per-request read is incremental, never a full
        rescan of a 29MB+ file). The slot holds the last incremental
        read and resumes from its byte offset, O(1) while the file has
        not grown. A DataFault is never cached — a corrupt journal
        faults on every request until it is fixed; a vanished file
        resets the slot cleanly. Returns (events, present) with
        read_committed_lines' exact semantics; the events list is the
        slot's own and callers must never mutate it in place."""
        with self._events_lock:
            events, present, state = _read_committed_lines_inc(
                path, self._events_entry)
            self._events_entry = state
            return events, present

    @staticmethod
    def _market_item(ev, rank, names, pos=None):
        """The whitelisted README §3.7 item: nine fields — seven recorded,
        `name` (the recorded ka10027 stock name for the fact's symbol,
        null when the recorded bodies never named it — honest absence,
        the app falls back to the symbol) and `ma20_tag` (the opening
        mode's display classification, null until the mode sets it).
        rank is null on CANDIDATE_EXITED. `pos` rides along in fold
        state as the ledger-order position for the documented
        malformed-rank tie-break; it is never projected."""
        item = {"data_quality": ev["data_quality"],
                "direction": ev["direction"],
                "event_id": ev["event_id"],
                "event_type": ev["event_type"],
                "ma20_tag": None,
                "name": names.get(ev["symbol"]),
                "observed_at": ev["observed_at"],
                "rank": rank,
                "symbol": ev["symbol"]}
        if pos is not None:
            item["pos"] = pos
        return item

    @staticmethod
    def _market_change(change_type, item, prev_rank, names):
        """The §3.7 change record: nine whitelisted fields — a
        display-only classification of one TOP10 state change between
        CONFIRMED observation groups plus the recorded values of the
        change's evidence event (`item`, the whitelist item of the
        upsert that last recorded the state, or of the EXITED with rank
        null). `prev_rank` is the rank the previous confirmed group
        recorded (null when there was no previous state). Not an event:
        the classification follows MARKET_CHANGE_TYPES, the record mints
        no id of its own and never enters a journal — its event_id is
        the evidence event's, so the existing /events/{id} drilldown
        applies unchanged."""
        record = {"change_type": change_type,
                  "data_quality": item["data_quality"],
                  "direction": item["direction"],
                  "event_id": item["event_id"],
                  "name": names.get(item["symbol"]),
                  "observed_at": item["observed_at"],
                  "prev_rank": prev_rank,
                  "rank": item["rank"],
                  "symbol": item["symbol"]}
        return {field: record[field] for field in MARKET_CHANGE_FIELDS}

    @staticmethod
    def _market_fact_change(ev, names):
        """The §3.7 fact-path change record: the display translation of
        one Core-confirmed TOP10 fact (README §3.7's dual path). The
        same nine whitelisted fields as _market_change with no
        classification: change_type is the fact's event_type verbatim,
        direction, rank and prev_rank are the fact's own optional
        fields (null when the fact records none — TOP10_EXITED's
        candidate-disappearance case records no rank), name is the
        fact's recorded name with the folded ka10027 dictionary as the
        fallback (null when neither names the symbol). The fact is
        already the confirmed change — this method mints nothing."""
        name = ev.get("name")
        if not isinstance(name, str):
            name = names.get(ev["symbol"])
        record = {"change_type": ev["event_type"],
                  "data_quality": ev["data_quality"],
                  "direction": ev.get("direction"),
                  "event_id": ev["event_id"],
                  "name": name,
                  "observed_at": ev["observed_at"],
                  "prev_rank": ev.get("previous_rank"),
                  "rank": ev.get("rank"),
                  "symbol": ev["symbol"]}
        return {field: record[field] for field in MARKET_CHANGE_FIELDS}

    @staticmethod
    def _fact_history(facts, last_stamp_pos, sealed, names):
        """The top10-v1 fact-path history (README §3.7): every eligible
        TOP10 fact translated into a change record, journal order, the
        last MARKET_HISTORY_N kept (the oldest dropped first — the
        legacy ring rule). Eligibility is the fact-path equivalent of
        the legacy unsealed-tail rule: a fact enters history only when
        the run is sealed OR some journal event with a different
        observed_at follows it. Derivation: Core journals a group's
        boundary facts only when the next pair completes, and the
        emission order is [boundary TOP10 facts -> the new group's
        CANDIDATE_*], so a different-stamp event always follows a
        boundary fact — a fact in the journal is already confirmed.
        The exception is the kSessionEnd flush facts of the final
        group: nothing but the same-stamp SESSION_ENDED follows them,
        so the seal is their only confirmation and an unsealed tail is
        never served complete. Single pass: `last_stamp_pos` maps each
        stamp to its greatest ledger position (distinct positions, one
        per stamp), so the sorted entries yield the file's last stamp
        and the greatest position of any other stamp — the two values
        that decide every fact. `facts` is the pass's append order:
        ledger order by construction, never a dict iteration."""
        if not facts:
            return []
        entries = sorted(last_stamp_pos.items(), key=lambda kv: kv[1])
        last_stamp = entries[-1][0]
        # the greatest position of any stamp other than the file's last
        runner_up = entries[-2][1] if len(entries) > 1 else None
        records = []
        for pos, ev in facts:
            if not sealed:
                stamp = ev["observed_at"]
                if stamp == last_stamp:
                    if runner_up is None or runner_up <= pos:
                        continue  # the unsealed tail: not yet confirmed
                # a different stamp's event follows the fact: the
                # boundary that confirmed it is already in the journal
            records.append(Projector._market_fact_change(ev, names))
        return records[-MARKET_HISTORY_N:]

    def market_view(self):
        """GET /mobile/market-view (README §3.7): the bounded,
        deterministic, read-only projection of the latest ELIGIBLE
        market-collection run. No judgment happens here: ranks are
        recorded facts, and this method only folds them, orders by a
        recorded field, selects, counts, and projects TOP10 changes —
        on a pre-contract run by the contract's state-comparison
        projection (recorded snapshots compared, every value in a
        change record a recorded value, the classification following
        the §3.7 vocabulary), on an events_contract "top10-v1" run by
        the dual path's fact translation (the Core-confirmed TOP10
        facts already in the journal, translated field-for-field —
        still no judgment: the facts are the confirmed changes). The
        VS-2 opening MA20 mode is one more recorded projection on the
        same fold: when the reference group's recorded observed_at
        falls in the opening window, the top10 lists are reconstituted
        by opening_market_top10 from recorded prices against recorded
        close sums (§3.7) — orthogonal to the history path. The runs
        root is listed once per request and every identity is read
        from recorded bytes (the committed config record), never the
        wall clock. The event fold and the response stay per-request
        locals; the cached objects are the derived market fold
        (§3.7, _market_projection) and the journal's committed-lines
        cache (_events_committed_lines).

        Cold-path readiness: while the startup prewarm is WARMING the
        call raises ServiceWarming (the handler's 503 + Retry-After),
        and a FAILED prewarm raises DataFault — both before any lock or
        recorded byte is touched, so a warming server's answers never
        queue behind the scan's own _fold_lock hold."""
        with self._readiness_lock:
            if self._readiness_state == "WARMING":
                raise ServiceWarming("market projection is warming")
            if self._readiness_state == "FAILED":
                raise DataFault("market projection prewarm failed: %s"
                                % (self._readiness_error or "unknown error"))
        names = self._session_names()
        eligible = []
        for name in names:
            run_dir = os.path.join(self.runs_root, name)
            input_path = os.path.join(run_dir, INPUT_JSONL)
            events_path = os.path.join(run_dir, EVENTS_JSONL)
            if not (os.path.isfile(input_path)
                    and os.path.isfile(events_path)):
                continue
            config = read_head_config(input_path)
            if config is None:
                continue
            environment = config.get("environment")
            if environment not in MARKET_ENVIRONMENTS:
                continue
            session_date = config.get("session_date")
            if not isinstance(session_date, str) \
                    or SESSION_DATE_RE.match(session_date) is None:
                continue
            run_id = config.get("run_id")
            eligible.append((name, environment, session_date,
                             run_id if isinstance(run_id, str) else None,
                             read_last_observed_at(events_path),
                             config.get("events_contract")))
        if not eligible:
            return {"as_of": None, "coverage": None, "history": [],
                    "latest": None, "mode": "core", "run": None,
                    "rising_top10": [],
                    "falling_top10": [], "runs_present": bool(names),
                    "status": None}
        # Selection (README §3.7): max session_date, then max last
        # committed observed_at (None ranks last), then max dirname.
        session, environment, session_date, run_id, _, events_contract = \
            max(eligible, key=lambda run: (run[2], run[4] or "", run[0]))
        # The §3.7 history dual-path discriminator: the selected run's
        # own recorded config value. Absence is the pre-contract legacy
        # projection; "top10-v1" is the fact path. Any other value is a
        # contract this projection cannot consume — fail-closed, never
        # a guess at which history a run carries.
        if events_contract is not None \
                and events_contract != MARKET_EVENTS_CONTRACT:
            raise DataFault("%s config events_contract is not %s"
                            % (INPUT_JSONL, MARKET_EVENTS_CONTRACT))
        fact_path = events_contract == MARKET_EVENTS_CONTRACT
        run_dir = os.path.join(self.runs_root, session)
        stock_names, snapshots, ma20 = self._market_projection(
            os.path.join(run_dir, INPUT_JSONL), session_date)
        events, _ = self._events_committed_lines(
            os.path.join(run_dir, EVENTS_JSONL))
        # The seal (README §3.7): the recorder's finish() marker — the
        # same recorded fact the verification endpoint reads (§3.6),
        # checked once per request. Its absence means live or crashed:
        # the last observation group is unconfirmed and its changes are
        # never derived (a partial batch is not made to look complete).
        sealed = os.path.isfile(os.path.join(run_dir, COMMITTED_MARKER))
        live = {}       # (symbol, direction) -> item + ledger position
        changes = []    # the last MARKET_HISTORY_N change records
        quality = Counter()
        prev_snapshot = None  # (symbol, direction) -> rank at the end of
        #                       the last CONFIRMED observation group
        #                       (ranks beyond 10 included); None until
        #                       the first group is confirmed — that
        #                       group is only the comparison baseline
        group_exits = {}  # the current group's EXITED events, key ->
        #                   (event, ledger position): the evidence a
        #                   CANDIDATE_EXITED change record cites
        group_stamp = None  # observed_at of the current observation group
        group_index = 0     # 1-based ledger-order index of that group
        group_upserts = set()  # symbols the current group's batch
        #                       upserted (ENTERED/UPDATED) — the opening
        #                       mode's correspondence evidence
        confirmed = None  # (group_index, stamp, per-symbol state,
        #                  upserts) of the last CONFIRMED observation
        #                  group — the opening mode's reference group
        facts = []  # (ledger position, fact) of every TOP10 fact — the
        #             fact path's history source (top10-v1 runs only)
        last_stamp_pos = {}  # observed_at -> the greatest ledger
        #                      position carrying that stamp — the fact
        #                      path's single-pass eligibility input

        def confirm_group():
            """The §3.7 state-comparison projection: derive the TOP10
            change records of the just-closed observation group by
            comparing the previous confirmed snapshot with the live
            state — the pre-contract legacy path only; a top10-v1 run's
            history is the fact translation, so the derivation never
            runs there. The classification follows MARKET_CHANGE_TYPES;
            every projected value is recorded. The first group (no
            snapshot) is the baseline and records zero changes. The
            group is also captured as the opening mode's reference
            candidate in both paths: its per-symbol candidate state
            (deduplicated over UP/DOWN — the item whose upsert holds
            the greatest ledger position represents a dual-direction
            symbol) and the symbols its batch upserted."""
            nonlocal prev_snapshot, confirmed
            per_symbol = {}
            for entry in live.values():
                current = per_symbol.get(entry["symbol"])
                if current is None or entry["pos"] > current["pos"]:
                    per_symbol[entry["symbol"]] = entry
            confirmed = (group_index, group_stamp, per_symbol,
                         set(group_upserts))
            if fact_path:
                # Core already confirmed this group's changes as TOP10
                # facts in the journal — the reference-group capture
                # above still stands (the opening mode reads it exactly
                # as in the legacy path), the derivation below does not
                # run, and the snapshot state it feeds stays unused.
                return
            recorded = []  # (evidence position, change record)
            if prev_snapshot is not None:
                # The current TOP10 per direction: the same rule the
                # response top10 uses — ascending recorded rank, the
                # documented ledger-position tie-break, first ten.
                current_top10 = set()
                for direction in ("UP", "DOWN"):
                    rows = [entry for entry in live.values()
                            if entry["direction"] == direction]
                    rows.sort(key=lambda entry: (entry["rank"],
                                                 entry["pos"]))
                    for entry in rows[:MARKET_TOP_N]:
                        current_top10.add((entry["symbol"], direction))
                # The previous TOP10 members: what left or moved.
                for key, prev_rank in prev_snapshot.items():
                    if prev_rank > MARKET_TOP_N:
                        continue  # outside the previous TOP10: it can
                        #           only enter, handled below
                    entry = live.get(key)
                    if entry is None:
                        if key not in group_exits:
                            # A valid ledger cannot produce this: live
                            # state is removed only by an EXITED event,
                            # so a previous-TOP10 symbol missing from
                            # live must carry this group's evidence.
                            raise DataFault(
                                "%s TOP10 symbol %s (%s) left the live "
                                "state with no CANDIDATE_EXITED record "
                                "in its observation group"
                                % (EVENTS_JSONL, key[0], key[1]))
                        ev, ev_pos = group_exits[key]
                        recorded.append((ev_pos, self._market_change(
                            "CANDIDATE_EXITED",
                            self._market_item(ev, None, stock_names),
                            prev_rank, stock_names)))
                    elif entry["rank"] <= MARKET_TOP_N:
                        if entry["rank"] != prev_rank:
                            recorded.append((entry["pos"], self._market_change(
                                "RANK_CHANGED", entry, prev_rank,
                                stock_names)))
                    else:
                        recorded.append((entry["pos"], self._market_change(
                            "TOP10_EXITED", entry, prev_rank,
                            stock_names)))
                # The new TOP10 members: what entered.
                for key in current_top10:
                    prev_rank = prev_snapshot.get(key)
                    if prev_rank is not None \
                            and prev_rank <= MARKET_TOP_N:
                        continue  # already in the previous TOP10
                    entry = live[key]
                    if entry["rank"] > MARKET_TOP_N:
                        continue  # displayed only because the direction
                        #           shrank below ten members — entering
                        #           means reaching rank <= 10
                    recorded.append((entry["pos"], self._market_change(
                        "TOP10_ENTERED", entry, prev_rank, stock_names)))
            # Group order: the ledger position of the evidence event —
            # an explicit sort, never dict iteration order.
            recorded.sort(key=lambda pair: pair[0])
            for _, record in recorded:
                changes.append(record)
                if len(changes) > MARKET_HISTORY_N:
                    del changes[0]
            prev_snapshot = {key: item["rank"]
                             for key, item in live.items()}

        for pos, ev in enumerate(events, start=1):
            for field in ("event_id", "event_type", "observed_at",
                          "data_quality"):
                if not isinstance(ev.get(field), str):
                    raise DataFault("%s record %d has no %s"
                                    % (EVENTS_JSONL, pos, field))
            event_type = ev["event_type"]
            quality[ev["data_quality"]] += 1
            if fact_path:
                # The dual path's per-event bookkeeping: every event
                # feeds the eligibility map, and the TOP10 facts are
                # collected for the translation (their shape validated
                # like the candidate fold's own fields — an unknown
                # TOP10_* type is a future fact this projection cannot
                # consume, fail-closed).
                last_stamp_pos[ev["observed_at"]] = pos
                if event_type in MARKET_FACT_TYPES:
                    if not isinstance(ev.get("symbol"), str):
                        raise DataFault("%s record %d has no symbol"
                                        % (EVENTS_JSONL, pos))
                    fact_direction = ev.get("direction")
                    if fact_direction is not None \
                            and (not isinstance(fact_direction, str)
                                 or fact_direction not in ("UP", "DOWN")):
                        raise DataFault("%s record %d direction is not "
                                        "UP or DOWN" % (EVENTS_JSONL, pos))
                    for field in ("rank", "previous_rank"):
                        value = ev.get(field)
                        if value is not None \
                                and (not isinstance(value, int)
                                     or isinstance(value, bool)
                                     or value < 1):
                            raise DataFault("%s record %d %s is not >= 1"
                                            % (EVENTS_JSONL, pos, field))
                    if ev.get("name") is not None \
                            and not isinstance(ev.get("name"), str):
                        raise DataFault("%s record %d name is not a "
                                        "string" % (EVENTS_JSONL, pos))
                    facts.append((pos, ev))
                    continue  # a fact never touches live state or groups
                if event_type.startswith(TOP10_PREFIX):
                    raise DataFault("%s record %d is an unknown TOP10 "
                                    "fact type" % (EVENTS_JSONL, pos))
            if not event_type.startswith(CANDIDATE_PREFIX):
                continue  # non-candidate events never close a group
            if not isinstance(ev.get("symbol"), str) \
                    or not isinstance(ev.get("direction"), str):
                raise DataFault("%s record %d has no symbol or direction"
                                % (EVENTS_JSONL, pos))
            if ev["direction"] not in ("UP", "DOWN"):
                raise DataFault("%s record %d direction is not UP or DOWN"
                                % (EVENTS_JSONL, pos))
            key = (ev["symbol"], ev["direction"])
            if group_stamp is None or ev["observed_at"] != group_stamp:
                # A different observed_at opens the next observation
                # group, so the previous group's recorded batch is
                # complete: confirm it. Same-stamp consecutive batches
                # merge into one group (fail-safe: no false exits).
                if group_stamp is not None:
                    confirm_group()
                    group_exits = {}
                    group_upserts = set()
                group_index += 1
            group_stamp = ev["observed_at"]
            if event_type == "CANDIDATE_EXITED":
                group_exits[key] = (ev, pos)
                live.pop(key, None)
            else:
                rank = ev.get("rank")
                if not isinstance(rank, int) or isinstance(rank, bool) \
                        or rank < 1:
                    raise DataFault("%s record %d has no rank >= 1"
                                    % (EVENTS_JSONL, pos))
                live[key] = self._market_item(ev, rank, stock_names, pos)
                group_upserts.add(ev["symbol"])
        # End of file: only the seal confirms the final group — after
        # the seal the recorder appends no candidate event (the only
        # post-seal append is SESSION_ENDED, not a candidate), so the
        # group's batch can no longer be partial.
        if group_stamp is not None and sealed:
            confirm_group()
        if fact_path:
            # The dual path's history assembly (README §3.7): the
            # collected facts' translation replaces the state-
            # comparison records confirm_group never wrote.
            changes = self._fact_history(facts, last_stamp_pos, sealed,
                                         stock_names)
        (mode, opening_rising, opening_falling, coverage) = \
            opening_market_top10(confirmed, snapshots, ma20)
        if mode == "opening_ma20":
            rising, falling = opening_rising, opening_falling
        else:
            rising, falling = [], []
            for direction, target in (("UP", rising), ("DOWN", falling)):
                rows = [entry for entry in live.values()
                        if entry["direction"] == direction]
                # Ascending recorded rank. A dense 1..N ranking has no
                # ties; if a malformed recorded tie ever appears, the
                # ledger-order position of the record that last upserted
                # the state breaks it (README §3.7 — the only documented
                # tie rule).
                rows.sort(key=lambda entry: (entry["rank"], entry["pos"]))
                for entry in rows[:MARKET_TOP_N]:
                    target.append({field: entry[field]
                                   for field in MARKET_ITEM_FIELDS})
        last = events[-1] if events else None
        return {
            "as_of": last["observed_at"] if last else None,
            "coverage": coverage,
            "history": changes,
            "latest": ({field: last[field] for field in
                        ("data_quality", "event_id", "event_type",
                         "observed_at")} if last else None),
            "mode": mode,
            "run": {"environment": environment, "run_id": run_id,
                    "session": session, "session_date": session_date},
            "rising_top10": rising,
            "falling_top10": falling,
            "runs_present": bool(names),
            "status": {"by_data_quality": dict(sorted(quality.items()))},
        }

    # ---- session verification --------------------------------------------

    @staticmethod
    def _recorded_output_line(run_dir, filename, prefix):
        """The first recorded line starting with `prefix` in an
        operator-recorded output file, verbatim. The API quotes what an
        operator recorded; it never runs or interprets the tool."""
        path = os.path.join(run_dir, filename)
        if not os.path.isfile(path):
            return {"recorded": False}
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError as exc:
            return {"recorded": False,
                    "note": "%s unreadable: %s" % (filename, _reason(exc))}
        except UnicodeDecodeError:
            return {"recorded": False,
                    "note": "%s is not valid UTF-8" % filename}
        for line in text.splitlines():
            if line.startswith(prefix):
                return {"recorded": True, "source": filename, "line": line}
        return {"recorded": False,
                "note": "%s present but no %s line recorded"
                        % (filename, prefix)}

    def _checksums(self, run_dir):
        path = os.path.join(run_dir, CHECKSUMS)
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except FileNotFoundError:
            return {"present": False, "artifacts": []}
        except OSError as exc:
            raise DataFault("%s unreadable: %s" % (CHECKSUMS, _reason(exc)))
        except UnicodeDecodeError:
            raise DataFault("%s is not valid UTF-8" % CHECKSUMS)
        artifacts = []
        for i, line in enumerate(text.splitlines(), start=1):
            if not line:
                continue
            match = CHECKSUM_LINE_RE.match(line)
            if match is None:
                raise DataFault("%s line %d is not a sha256sum line"
                                % (CHECKSUMS, i))
            recorded, name = match.group(1), match.group(2)
            safe = SAFE_ARTIFACT_RE.match(name) is not None \
                and ".." not in name and "/" not in name and "\\" not in name
            if safe:
                computed = sha256_file(os.path.join(run_dir, name))
            else:
                computed = None  # untrusted name: refused, never opened
            entry = {"file": name,
                     "recorded_sha256": recorded,
                     "computed_sha256": computed,
                     "match": computed == recorded if computed else False}
            if not safe:
                entry["note"] = "unsafe artifact name refused"
            artifacts.append(entry)
        return {"present": True, "artifacts": artifacts}

    def verification(self, session):
        run_dir = self._run_dir(session)
        if run_dir is None:
            return None
        run_json = self._run_json(run_dir)
        input_events, _ = read_committed_lines(
            os.path.join(run_dir, INPUT_JSONL))
        events_sha = sha256_file(os.path.join(run_dir, EVENTS_JSONL))
        return {
            "session": session,
            "run_json_present": run_json is not None,
            "session_date": run_json.get("session_date")
            if isinstance(run_json, dict)
            and isinstance(run_json.get("session_date"), str) else None,
            "code_commit": run_json.get("code_commit")
            if isinstance(run_json, dict)
            and isinstance(run_json.get("code_commit"), str) else None,
            "committed_marker": {"file": COMMITTED_MARKER,
                                 "present": os.path.isfile(
                                     os.path.join(run_dir,
                                                  COMMITTED_MARKER))},
            "session_end_recorded": any(
                ev.get("kind") == "session_end" for ev in input_events),
            "events_file": {"present": events_sha is not None,
                            "sha256": events_sha},
            "checksums": self._checksums(run_dir),
            "replay_verdict": self._recorded_output_line(
                run_dir, VERIFY_OUT, "VERDICT"),
        }


class Handler(BaseHTTPRequestHandler):
    """GET-only JSON handler. Every response body — success or error —
    is canonical JSON bytes plus one trailing LF."""

    server_version = "HongScannerAPI/1"
    protocol_version = "HTTP/1.1"
    projector = None  # set by main() before the server starts

    # -- responses --

    def _send_json(self, code, obj, extra_headers=None):
        body = canonical_bytes(obj) + b"\n"
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if extra_headers:
            items = extra_headers.items() \
                if isinstance(extra_headers, dict) else extra_headers
            for key, value in items:
                self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError) as exc:
            # The client hung up mid-response (the mobile client's 5s
            # timeout is the common case): one journal line, no
            # traceback, and the connection is done. Other write faults
            # stay loud.
            sys.stderr.write("CLIENT_DISCONNECTED %s\n"
                             % exc.__class__.__name__)
            self.close_connection = True
            return
        self.close_connection = True

    def _not_found(self):
        # No reflection: the message never echoes the requested path.
        self._send_json(404, {"error": {"code": "not_found",
                                        "message": "no such resource"}})

    def _method_not_allowed(self):
        self._send_json(405, {"error": {"code": "method_not_allowed",
                                        "message": "GET only"}},
                        extra_headers=(("Allow", "GET"),))

    def send_error(self, code, message=None, explain=None):
        """http.server's internal errors (bad request line, unknown
        method, ...) as JSON, so no HTML body ever leaves the API."""
        self._send_json(code, {"error": {"code": "http_error",
                                         "message": message or "http error"}})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n"
                         % (self.address_string(), fmt % args))

    # -- methods --

    def do_GET(self):
        split = urlsplit(self.path)
        path = unquote(split.path)
        projector = self.projector
        try:
            if path == "/status":
                body = projector.status()
            elif path == "/candidates":
                body = projector.candidates()
            elif path == "/events":
                values = parse_qs(split.query).get("session_id")
                body = projector.events(values[0] if values else None)
            elif path.startswith("/events/"):
                event_id = path[len("/events/"):]
                if EVENT_ID_RE.match(event_id) is None:
                    return self._not_found()
                body = projector.event(event_id)
                if body is None:
                    return self._not_found()
            elif path == "/sessions":
                body = projector.sessions()
            elif path.startswith("/sessions/") and \
                    path.endswith("/verification"):
                session = path[len("/sessions/"):-len("/verification")]
                body = self._verification(projector, session)
                if body is None:
                    return self._not_found()
            elif path == "/mobile/market-view":
                body = projector.market_view()
            else:
                return self._not_found()
        except DataFault as exc:
            return self._send_json(500, {"error": {"code": "data_fault",
                                                   "message": str(exc)}})
        except ServiceWarming as exc:
            return self._send_json(
                503, {"error": {"code": "warming", "message": str(exc)}},
                extra_headers={"Retry-After": "5"})
        self._send_json(200, body)

    @staticmethod
    def _verification(projector, session):
        """Path-traversal guard for the session id: explicit refusal of
        separators, dot segments and any id outside the recorded run
        directory names, before and behind the projector's own
        containment check."""
        if session in ("", ".", "..") or ".." in session or \
                "/" in session or "\\" in session or \
                SESSION_ID_RE.match(session) is None:
            return None
        return projector.verification(session)

    def do_POST(self):
        self._method_not_allowed()

    def do_PUT(self):
        self._method_not_allowed()

    def do_DELETE(self):
        self._method_not_allowed()

    def do_PATCH(self):
        self._method_not_allowed()

    def do_HEAD(self):
        self._method_not_allowed()

    def do_OPTIONS(self):
        self._method_not_allowed()


class ServeHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer with one refinement: a client that hangs up
    mid-response (BrokenPipeError/ConnectionResetError, including the
    flush path outside _send_json) is journaled as one stderr line
    instead of a traceback. Every other handler fault goes to
    http.server's default traceback path — failures stay loud."""

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            sys.stderr.write("CLIENT_DISCONNECTED %s\n"
                             % exc.__class__.__name__)
            return
        super().handle_error(request, client_address)


def _boot_id():
    """The kernel's boot id (stripped), the per-boot correlation key of
    the ops journal lines. "unknown" when /proc is unreadable — the
    journal line still prints, this never raises."""
    try:
        with open("/proc/sys/kernel/random/boot_id", "rb") as f:
            return f.read().decode("ascii", "replace").strip()
    except OSError:
        return "unknown"


def _repo_root():
    """The repository root this serve.py belongs to: three dirnames up
    from <repo>/tools/api/serve.py."""
    return os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))


def serve_provenance(repo_root):
    """Startup provenance for main()'s SERVE_PROVENANCE line (README
    §8): the git facts of THIS serve.py — HEAD sha, branch, the HEAD
    blob of tools/api/serve.py, the git blob of the on-disk file, the
    file's sha256 — plus the self-reported agreement verdict.
    provenance=OK ONLY when every git command exits 0 with non-empty
    output, the disk blob equals the HEAD blob, the sha256 is 64
    lowercase hex, and the branch is main; anything else is UNKNOWN
    with a compact reason. Bounded self-reported trust, NOT an
    attestation (AGENTS.md §0.2): the process reporting its own
    metadata proves agreement, never build origin. Never raises."""
    info = {"git": None, "branch": None, "blob": None, "disk_blob": None,
            "sha256": None, "provenance": "UNKNOWN", "reason": None}
    serve_path = os.path.abspath(__file__)

    def git(*args):
        return subprocess.run(["git"] + list(args), cwd=repo_root,
                              capture_output=True, text=True, timeout=5)

    try:
        done = {"git": git("rev-parse", "HEAD"),
                "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
                "blob": git("rev-parse", "HEAD:tools/api/serve.py"),
                "disk_blob": git("hash-object", serve_path)}
    except Exception:
        info["reason"] = "git-unavailable"
        return info
    if any(proc.returncode != 0 or not proc.stdout.strip()
           for proc in done.values()):
        info["reason"] = "git-unavailable"
        return info
    for key, proc in done.items():
        info[key] = proc.stdout.strip()
    try:
        with open(serve_path, "rb") as f:
            info["sha256"] = hashlib.sha256(f.read()).hexdigest()
    except OSError:
        info["reason"] = "serve-unreadable"
        return info
    if info["branch"] != "main":
        info["reason"] = "branch=%s" % info["branch"]
        return info
    if info["disk_blob"] != info["blob"]:
        info["reason"] = "blob-mismatch"
        return info
    if re.fullmatch(r"[0-9a-f]{64}", info["sha256"]) is None:
        info["reason"] = "sha256-shape"
        return info
    info["provenance"] = "OK"
    return info


def main(argv=None, server_factory=ServeHTTPServer):
    parser = argparse.ArgumentParser(
        prog="serve.py",
        description="Hong Scanner read-only API — serves recorded facts "
                    "from a runs directory and an event ledger, bound "
                    "to 127.0.0.1 by default.")
    parser.add_argument("--runs", required=True, metavar="DIR",
                        help="runs root directory (read-only)")
    parser.add_argument("--ledger", required=True, metavar="FILE",
                        help="event ledger JSONL (read-only)")
    parser.add_argument("--delivery", default=None, metavar="FILE",
                        help="delivery ledger JSONL (read-only, optional)")
    parser.add_argument("--port", required=True, type=int, metavar="N",
                        help="TCP port (0 = ephemeral)")
    parser.add_argument("--bind", default=BIND_HOST, metavar="IP",
                        help="IPv4 address to bind (default: 127.0.0.1; "
                             "0.0.0.0 only for a container behind the "
                             "platform ingress)")
    args = parser.parse_args(argv)

    if not (0 <= args.port <= 65535):
        parser.error("--port must be between 0 and 65535")
    bind = resolve_bind(args.bind)
    if bind is None:
        parser.error("--bind must be a dotted-quad IPv4 unicast address "
                     "or 0.0.0.0 (multicast, broadcast, reserved blocks "
                     "and non-IPv4 strings are refused)")
    if not os.path.isdir(args.runs):
        sys.stderr.write("serve.py: --runs is not an existing directory\n")
        return 2

    # Startup provenance (README §8) precedes the prewarm and the
    # server: one stdout line, bounded self-reported trust (git/blob/
    # sha256 agreement of this serve.py), never an attestation.
    provenance = serve_provenance(_repo_root())
    print("SERVE_PROVENANCE provenance=%s git=%s branch=%s blob=%s"
          " disk_blob=%s sha256=%s reason=%s"
          % (provenance["provenance"], provenance["git"] or "-",
             provenance["branch"] or "-", provenance["blob"] or "-",
             provenance["disk_blob"] or "-",
             provenance["sha256"] or "-",
             provenance["reason"] or "-"), flush=True)

    projector = Projector(args.runs, args.ledger, args.delivery)
    Handler.projector = projector
    # Startup ordering invariant: the prewarm runs BEFORE the server
    # is constructed. The ThreadingHTTPServer constructor binds and
    # listens (socketserver's server_activate calls socket.listen),
    # so a socket constructed while the projector is still READY
    # could accept a fast client before WARMING is set — its
    # /mobile/market-view would pay the synchronous cold fold instead
    # of the contract's 503 warming. The prewarm's scan runs in a
    # daemon thread: if the bind below fails, main() still exits 4
    # promptly and the warming thread dies with the process.
    projector.prewarm_market_projection_async()
    try:
        server = server_factory((bind, args.port), Handler)
    except OSError as exc:
        sys.stderr.write("serve.py: cannot bind %s:%d: %s\n"
                         % (bind, args.port, _reason(exc)))
        return 4
    server.daemon_threads = True

    def _shutdown(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    print("SERVE %s:%d" % server.server_address, flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
