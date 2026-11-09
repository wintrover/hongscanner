#!/usr/bin/env python3
"""Hong Scanner read-only API (VS-3 PR-6).

Contract: tools/api/README.md. The API serves RECORDED facts only —
the run directories (--runs) and the append-only event ledger
(--ledger), plus the optional delivery ledger (--delivery). It judges
nothing, replays nothing, recomputes no verdict: every response is a
projection of recorded bytes plus the cheap rederivations the contract
names (sha256 comparison against a recorded CHECKSUMS.sha256, presence
of recorded markers and operator-recorded verify output). Running the
Nim verify binary is outside this process's scope, always.

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

Python 3.13, standard library only (http.server). No new dependencies.
"""

import argparse
import hashlib
import ipaddress
import json
import os
import re
import signal
import sys
import threading
from collections import Counter
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
# The stock-name dictionary (README §3.7): the only folded vendor body
# values are the ka10027 ranking rows' stk_nm, keyed by stk_cd.
MARKET_NAME_API = "ka10027"
MARKET_NAME_LIST_KEY = "pred_pre_flu_rt_upper"
# The §3.7 item whitelist: the projection is field-bounded so the
# response size is mechanically capped (at most 120 items).
MARKET_ITEM_FIELDS = ("data_quality", "direction", "event_id",
                      "event_type", "name", "observed_at", "rank",
                      "symbol")


class DataFault(Exception):
    """A recorded file is unreadable or violates its recorded shape.
    Fail-closed: the endpoint answers HTTP 500, it never silently skips
    a corrupted record. Messages carry file basenames only — never
    absolute paths."""


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


def fold_market_names(path):
    """symbol -> stock name from the ka10027 rest_resp bodies recorded in
    one input.hcj.jsonl (README §3.7). File order, last record wins.
    This is the one documented whole-input scan: unlike the config head
    (16 KiB) it walks every committed line, so callers memoize it (the
    Projector's (path, size, mtime_ns) cache) and the walk streams one
    line at a time — a market-day input is gigabytes, never one read.
    Line discipline is the committed-lines rule: a trailing line without
    LF is not committed and stops the walk; a malformed committed line
    is a DataFault. A rest_resp envelope the recorder itself guarantees
    (raw object, string api_id, hex body_hex) faulting that guarantee is
    corruption, also a DataFault. The body content is NOT guaranteed
    (the recorder preserves every response verbatim, successful or not):
    a body that does not decode to a JSON object carrying the ranking
    list simply contributes no names — a recorded non-success response
    carries no ranking to fold. Rows inside a decoded list are the
    fold's dependent shape: every row must be an object with string
    stk_cd and stk_nm, or it is a DataFault."""
    names = {}
    try:
        f = open(path, "rb")
    except FileNotFoundError:
        return names
    except OSError as exc:
        raise DataFault("%s unreadable: %s"
                        % (os.path.basename(path), _reason(exc)))
    name = os.path.basename(path)
    with f:
        for i, raw in enumerate(f, start=1):
            if not raw.endswith(b"\n"):
                break  # torn tail: a concurrent append, not committed yet
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
            if api_id != MARKET_NAME_API:
                continue
            body_hex = rec.get("body_hex")
            if not isinstance(body_hex, str):
                raise DataFault("%s line %d rest_resp has no body_hex"
                                % (name, i))
            try:
                body = bytes.fromhex(body_hex)
            except ValueError:
                raise DataFault("%s line %d body_hex is not hex" % (name, i))
            try:
                doc = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                continue
            if not isinstance(doc, dict):
                continue
            rows = doc.get(MARKET_NAME_LIST_KEY)
            if not isinstance(rows, list):
                continue
            for row in rows:
                if not isinstance(row, dict) \
                        or not isinstance(row.get("stk_cd"), str) \
                        or not isinstance(row.get("stk_nm"), str):
                    raise DataFault("%s line %d ranking row has no stk_cd "
                                    "or stk_nm" % (name, i))
                names[row["stk_cd"]] = row["stk_nm"]
    return names


class Projector:
    """Read-only projection of the recorded sources. Every method
    returns plain JSON-safe data (strings, integers, booleans, null,
    arrays, objects — no floats)."""

    def __init__(self, runs_root, ledger_path, delivery_path=None):
        self.runs_root = runs_root
        self.ledger_path = ledger_path
        self.delivery_path = delivery_path
        self._runs_real = os.path.realpath(runs_root)
        # The §3.7 name-dictionary memoization: one entry, the last
        # published (path, size, mtime_ns) -> names fold. ThreadingHTTPServer
        # serves concurrent requests, so the slot is guarded by one lock.
        self._names_lock = threading.Lock()
        self._names_entry = None

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
        events, ledger_present = self._ledger_events()
        if ledger_present:
            # A present-but-empty ledger (its single writer opened the
            # file with O_CREAT before the first committed record) is an
            # honest zero-count projection, never an IndexError (§3).
            last = events[-1] if events else None
            events_block = {
                "ledger_present": True,
                "count": len(events),
                "by_type": dict(sorted(Counter(
                    ev["event_type"] for ev in events).items())),
                "by_severity": dict(sorted(Counter(
                    ev["severity"] for ev in events).items())),
                "latest_session_id": last["session_id"] if last else None,
                "latest_event": ({k: last[k]
                                  for k in ("event_id", "event_type",
                                            "observed_at")
                                  if k in last} if last else None),
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
        return {"sessions": {"count": len(names), "latest": latest_summary},
                "events": events_block,
                "delivery": delivery_block}

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

    def event(self, event_id):
        """The one event fact and its delivery records, or None when the
        id is not in the ledger (the handler answers 404)."""
        events, ledger_present = self._ledger_events()
        latest_deliveries, _, present = self._delivery_latest()
        for ev in events:
            if ev["event_id"] == event_id:
                delivery = self._delivery_for(latest_deliveries, event_id) \
                    if ledger_present and present else []
                return {"event": ev, "delivery": delivery}
        return None

    # ---- mobile market view (README §3.7) ---------------------------------

    def _market_names(self, path):
        """The memoized symbol -> name dictionary for one input.hcj.jsonl:
        a pure derivation of recorded bytes, so unlike the per-request
        event fold it is cached in-process. The key is the practical
        invalidation triple (path, size, mtime_ns) — not a cryptographic
        fingerprint: a rewrite restoring the same size and mtime_ns would
        be served stale. A scan is published only when the file's stat
        matches before and after the read (a file changing mid-scan is
        served as its consistent prefix, never cached). A DataFault is
        never cached — a corrupt file faults on every request until it
        is fixed. The slot holds one entry: a different selected run
        rescans."""
        try:
            before = os.stat(path)
        except FileNotFoundError:
            return {}
        except OSError as exc:
            raise DataFault("%s unreadable: %s"
                            % (os.path.basename(path), _reason(exc)))
        with self._names_lock:
            entry = self._names_entry
        if entry is not None and entry[:3] == (path, before.st_size,
                                               before.st_mtime_ns):
            return entry[3]
        names = fold_market_names(path)
        try:
            after = os.stat(path)
        except OSError:
            return names
        if (after.st_size, after.st_mtime_ns) \
                == (before.st_size, before.st_mtime_ns):
            with self._names_lock:
                self._names_entry = (path, before.st_size,
                                     before.st_mtime_ns, names)
        return names

    @staticmethod
    def _market_item(ev, rank, names, pos=None):
        """The whitelisted README §3.7 item: eight fields, seven recorded
        plus `name` — the recorded ka10027 stock name for the fact's
        symbol, null when the recorded bodies never named it (honest
        absence, the app falls back to the symbol). rank is null on
        CANDIDATE_EXITED. `pos` rides along in fold state as the
        ledger-order position for the documented malformed-rank
        tie-break; it is never projected."""
        item = {"data_quality": ev["data_quality"],
                "direction": ev["direction"],
                "event_id": ev["event_id"],
                "event_type": ev["event_type"],
                "name": names.get(ev["symbol"]),
                "observed_at": ev["observed_at"],
                "rank": rank,
                "symbol": ev["symbol"]}
        if pos is not None:
            item["pos"] = pos
        return item

    def market_view(self):
        """GET /mobile/market-view (README §3.7): the bounded,
        deterministic, read-only projection of the latest ELIGIBLE
        market-collection run. No judgment happens here: ranks are
        recorded facts, and this method only folds them, orders by a
        recorded field, selects and counts. The runs root is listed once
        per request and every identity is read from recorded bytes (the
        committed config record), never the wall clock. The event fold
        and the response stay per-request locals; the one cached object
        is the derived name dictionary (§3.7, _market_names)."""
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
                             read_last_observed_at(events_path)))
        if not eligible:
            return {"as_of": None, "history": [], "latest": None,
                    "run": None, "rising_top10": [], "falling_top10": [],
                    "runs_present": bool(names), "status": None}
        # Selection (README §3.7): max session_date, then max last
        # committed observed_at (None ranks last), then max dirname.
        session, environment, session_date, run_id, _ = max(
            eligible, key=lambda run: (run[2], run[4] or "", run[0]))
        stock_names = self._market_names(
            os.path.join(self.runs_root, session, INPUT_JSONL))
        events, _ = read_committed_lines(
            os.path.join(self.runs_root, session, EVENTS_JSONL))
        live = {}      # (symbol, direction) -> item + ledger position
        history = []   # the last MARKET_HISTORY_N candidate items
        quality = Counter()
        for pos, ev in enumerate(events, start=1):
            for field in ("event_id", "event_type", "observed_at",
                          "data_quality"):
                if not isinstance(ev.get(field), str):
                    raise DataFault("%s record %d has no %s"
                                    % (EVENTS_JSONL, pos, field))
            event_type = ev["event_type"]
            quality[ev["data_quality"]] += 1
            if not event_type.startswith(CANDIDATE_PREFIX):
                continue
            if not isinstance(ev.get("symbol"), str) \
                    or not isinstance(ev.get("direction"), str):
                raise DataFault("%s record %d has no symbol or direction"
                                % (EVENTS_JSONL, pos))
            if ev["direction"] not in ("UP", "DOWN"):
                raise DataFault("%s record %d direction is not UP or DOWN"
                                % (EVENTS_JSONL, pos))
            key = (ev["symbol"], ev["direction"])
            if event_type == "CANDIDATE_EXITED":
                live.pop(key, None)
                rank = None
            else:
                rank = ev.get("rank")
                if not isinstance(rank, int) or isinstance(rank, bool) \
                        or rank < 1:
                    raise DataFault("%s record %d has no rank >= 1"
                                    % (EVENTS_JSONL, pos))
                live[key] = self._market_item(ev, rank, stock_names, pos)
            history.append(self._market_item(ev, rank, stock_names))
            if len(history) > MARKET_HISTORY_N:
                del history[0]
        rising, falling = [], []
        for direction, target in (("UP", rising), ("DOWN", falling)):
            rows = [entry for entry in live.values()
                    if entry["direction"] == direction]
            # Ascending recorded rank. A dense 1..N ranking has no ties;
            # if a malformed recorded tie ever appears, the ledger-order
            # position of the record that last upserted the state breaks
            # it (README §3.7 — the only documented tie rule).
            rows.sort(key=lambda entry: (entry["rank"], entry["pos"]))
            for entry in rows[:MARKET_TOP_N]:
                target.append({field: entry[field]
                               for field in MARKET_ITEM_FIELDS})
        last = events[-1] if events else None
        return {
            "as_of": last["observed_at"] if last else None,
            "history": history,
            "latest": ({field: last[field] for field in
                        ("data_quality", "event_id", "event_type",
                         "observed_at")} if last else None),
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

    def _send_json(self, code, obj, extra_headers=()):
        body = canonical_bytes(obj) + b"\n"
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for key, value in extra_headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)
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


def main(argv=None):
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

    projector = Projector(args.runs, args.ledger, args.delivery)
    Handler.projector = projector
    try:
        server = ThreadingHTTPServer((bind, args.port), Handler)
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
