#!/usr/bin/env python3
"""notify_ledger: the VS-3 event ledger and delivery ledger (PR-5).

Contract: tools/notify/README.md, the committed schemas
contracts/events/event.schema.json (immutable event fact) and
contracts/events/delivery.schema.json (operational delivery record),
docs/REPLAY_CONTRACT.md section 13.

Three states, three homes, never one field for two of them (schema
x-separation-rule):
  - importance/trust are fields of the event fact and are never mutated;
  - delivery state (PENDING/ACCEPTED/FAILED) lives only in the delivery
    ledger, a separate append-only file written by a separate process
    from the recorder and from the event ledger;
  - the FCM registration token is a credential: it lives only in the
    device registry (outside the repository), never in a delivery
    record and never in any log (sha256 prefixes only).

Discipline:
  - append-only JSONL, one object per line, LF-terminated, UTF-8,
    HCJ-safe values (strings and integers only);
  - one writer per file, enforced with an exclusive non-blocking flock
    held for the process lifetime — a second writer refuses to start;
  - event facts are appended byte-verbatim: the ledger never rewrites,
    reorders or enriches a fact (mutated fact bytes would break replay
    byte-identity, REPLAY_CONTRACT §13.4);
  - every record is validated against the committed schema before it is
    written; an invalid record aborts (fail-closed: no silent skip, no
    partial append of an invalid source file).
"""

import argparse
import errno
import fcntl
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

import notify_config

KST = timezone(timedelta(hours=9))

EVENT_TYPES = (
    "CANDIDATE_ENTERED", "CANDIDATE_UPDATED", "CANDIDATE_EXITED",
    "TOP10_ENTERED", "TOP10_EXITED", "RANK_CHANGED",
    "FEED_DISCONNECTED", "DATA_GAP_SUSPECTED", "REST_TRUNCATED",
    "SUBSCRIPTION_TRUNCATED", "MARKET_STATE_UNKNOWN", "REPLAY_MATCH",
    "REPLAY_MISMATCH", "SESSION_ENDED", "SESSION_INCOMPLETE",
    "SESSION_APPROVED")
SEVERITIES = ("INFO", "HIGH", "CRITICAL")
DATA_QUALITIES = ("OBSERVING", "INCOMPLETE", "UNKNOWN")
DIRECTIONS = ("UP", "DOWN")
DELIVERY_STATES = ("PENDING", "ACCEPTED", "FAILED")

EVENT_REQUIRED = ("event_id", "event_type", "observed_at", "session_id",
                  "rule_id", "rule_version", "data_quality", "severity",
                  "evidence_ref")
EVENT_OPTIONAL = ("direction", "name", "previous_rank", "rank", "symbol")

DELIVERY_REQUIRED = ("attempts", "device_id", "event_id", "state",
                     "updated_at")
DELIVERY_OPTIONAL = ("error_code", "provider_message_id")

ID_RE = re.compile(r"^[0-9a-f]{64}$")
TS_RE = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$")
SYMBOL_RE = re.compile(r"^[0-9]{6}$")
DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")


class LedgerError(Exception):
    """A record or file violates the committed schema. Fail-closed."""


class LedgerBusy(Exception):
    """Another process holds the single-writer lock for this file."""


class LedgerFault(Exception):
    """An I/O or internal fault while appending (exit 4 class)."""


def now_iso():
    """The notify tools' clock: ISO 8601 with the numeric KST offset."""
    return datetime.now(KST).strftime("%Y-%m-%dT%H:%M:%S+09:00")


def mask_secret(value):
    """A log-safe identity of a credential value: sha256 prefix only.
    The value itself never reaches any log, record or stdout."""
    return "sha256:" + hashlib.sha256(
        value.encode("utf-8")).hexdigest()[:16]


def _check_str(obj, key, pattern=None, min_len=1):
    value = obj.get(key)
    if not isinstance(value, str):
        raise LedgerError("%s must be a string" % key)
    if len(value) < min_len:
        raise LedgerError("%s must be at least %d chars" % (key, min_len))
    if pattern is not None and not pattern.match(value):
        raise LedgerError("%s does not match the schema pattern" % key)
    return value


def _check_enum(obj, key, values):
    value = obj.get(key)
    if value not in values:
        raise LedgerError("%s must be one of %s" % (key, ", ".join(values)))
    return value


def _check_int(obj, key, minimum):
    value = obj.get(key)
    if not isinstance(value, int) or isinstance(value, bool):
        raise LedgerError("%s must be an integer" % key)
    if value < minimum:
        raise LedgerError("%s must be >= %d" % (key, minimum))
    return value


def validate_event(obj):
    """Structural mirror of contracts/events/event.schema.json
    (additionalProperties false, all invariants). Returns the object."""
    if not isinstance(obj, dict):
        raise LedgerError("event record is not a JSON object")
    unknown = set(obj) - set(EVENT_REQUIRED) - set(EVENT_OPTIONAL)
    if unknown:
        raise LedgerError("event has fields outside the closed schema: %s"
                          % ", ".join(sorted(unknown)))
    for key in EVENT_REQUIRED:
        if key not in obj:
            raise LedgerError("event is missing required field %s" % key)
    _check_str(obj, "event_id", ID_RE)
    _check_enum(obj, "event_type", EVENT_TYPES)
    _check_str(obj, "observed_at", TS_RE)
    _check_str(obj, "session_id")
    _check_str(obj, "rule_id")
    _check_int(obj, "rule_version", 1)
    _check_enum(obj, "data_quality", DATA_QUALITIES)
    _check_enum(obj, "severity", SEVERITIES)
    _check_str(obj, "evidence_ref")
    if "direction" in obj:
        _check_enum(obj, "direction", DIRECTIONS)
    if "name" in obj:
        _check_str(obj, "name")
    if "previous_rank" in obj:
        _check_int(obj, "previous_rank", 1)
    if "rank" in obj:
        _check_int(obj, "rank", 1)
    if "symbol" in obj:
        _check_str(obj, "symbol", SYMBOL_RE)
    return obj


def validate_delivery(obj):
    """Structural mirror of contracts/events/delivery.schema.json plus
    the documented state pairings: provider_message_id only after an
    ACCEPTED attempt, error_code only after a FAILED attempt, neither
    while PENDING. Returns the object."""
    if not isinstance(obj, dict):
        raise LedgerError("delivery record is not a JSON object")
    unknown = set(obj) - set(DELIVERY_REQUIRED) - set(DELIVERY_OPTIONAL)
    if unknown:
        raise LedgerError("delivery has fields outside the closed schema: "
                          "%s" % ", ".join(sorted(unknown)))
    for key in DELIVERY_REQUIRED:
        if key not in obj:
            raise LedgerError("delivery is missing required field %s" % key)
    _check_int(obj, "attempts", 0)
    _check_str(obj, "device_id")
    _check_str(obj, "event_id", ID_RE)
    state = _check_enum(obj, "state", DELIVERY_STATES)
    _check_str(obj, "updated_at", TS_RE)
    if state == "ACCEPTED":
        if "error_code" in obj:
            raise LedgerError("delivery ACCEPTED must not carry error_code")
        _check_str(obj, "provider_message_id")
    elif state == "FAILED":
        if "provider_message_id" in obj:
            raise LedgerError("delivery FAILED must not carry "
                              "provider_message_id")
        _check_str(obj, "error_code")
    else:  # PENDING
        for key in ("error_code", "provider_message_id"):
            if key in obj:
                raise LedgerError("delivery PENDING must not carry %s"
                                  % key)
    return obj


def parse_line(line_bytes, validator, path="<memory>", lineno=0):
    """One JSONL line -> (object, compact re-encoded bytes). The object
    must be a JSON object and must pass `validator` (fail-closed)."""
    try:
        obj = json.loads(line_bytes.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise LedgerError("%s line %d is not valid JSON: %s"
                          % (path, lineno, exc))
    validator(obj)
    return obj


def encode_line(obj):
    """Canonical wire encoding for a record this process creates: UTF-8,
    compact separators, LF added by the caller's appender."""
    return json.dumps(obj, ensure_ascii=False,
                      separators=(",", ":")).encode("utf-8")


class FileLock:
    """The single-writer lock: an exclusive non-blocking flock on
    `<path>.lock`, held for the process lifetime. A second writer gets
    LedgerBusy instead of silently corrupting the append order."""

    def __init__(self, path):
        lock_path = path + ".lock"
        try:
            self.fd = os.open(lock_path,
                              os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
        except OSError as exc:
            raise LedgerFault("cannot open lock %s: %s" % (lock_path, exc))
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(self.fd)
            if exc.errno in (errno.EACCES, errno.EAGAIN):
                raise LedgerBusy(
                    "another process holds the single-writer lock for %s"
                    % path)
            raise LedgerFault("cannot lock %s: %s" % (lock_path, exc))

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None


class Appender:
    """An O_APPEND writer with fsync: bytes appended here survive a
    crash of this process (short of the machine losing power), which is
    what the restart-recovery contract relies on."""

    def __init__(self, path):
        self.path = path
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        try:
            self.fd = os.open(path,
                              os.O_WRONLY | os.O_CREAT | os.O_APPEND |
                              os.O_CLOEXEC, 0o600)
        except OSError as exc:
            raise LedgerFault("cannot open %s for append: %s" % (path, exc))
        if not self._tail_committed():
            os.close(self.fd)
            self.fd = None
            raise LedgerFault(
                "%s ends in an uncommitted partial line (no LF); "
                "refusing to append — a new append would bury a "
                "half-written record mid-file" % path)

    def _tail_committed(self):
        """A non-empty file that does not end in LF carries a torn
        record (a writer died mid-append). Readers may skip such a
        tail, but a writer must refuse to build on it. The check reads
        through a separate read-only handle (the append fd is O_WRONLY)."""
        size = os.fstat(self.fd).st_size
        if not size:
            return True
        try:
            with open(self.path, "rb") as f:
                f.seek(size - 1)
                return f.read(1) == b"\n"
        except OSError as exc:
            raise LedgerFault("cannot inspect the tail of %s: %s"
                              % (self.path, exc))

    def append(self, line_bytes):
        """Append exact bytes (caller supplies the trailing LF) and
        fsync. Partial writes raise LedgerFault — never silence."""
        if not line_bytes.endswith(b"\n"):
            raise LedgerFault("append refused: line is not LF-terminated")
        view = memoryview(line_bytes)
        while view:
            try:
                written = os.write(self.fd, view)
            except OSError as exc:
                raise LedgerFault("append to %s failed: %s"
                                  % (self.path, exc))
            view = view[written:]
        os.fsync(self.fd)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class EventLedger:
    """The append-only event-fact ledger. Reader strictness: writers and
    `check` read strictly (any invalid line is a fault); the dispatcher
    reads leniently — a trailing line that is not yet LF-terminated is a
    concurrently-appending record and is skipped, never half-consumed."""

    def __init__(self, path, lock=False):
        self.path = path
        self._lock = FileLock(path) if lock else None
        if lock:
            self._appender = Appender(path)
        else:
            self._appender = None

    def close(self):
        if self._appender is not None:
            self._appender.close()
        if self._lock is not None:
            self._lock.release()

    def _read_raw_lines(self):
        try:
            with open(self.path, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            return b"", False
        except OSError as exc:
            raise LedgerFault("cannot read %s: %s" % (self.path, exc))
        complete = True
        if data and not data.endswith(b"\n"):
            complete = False
            data = data[:data.rfind(b"\n") + 1]
        return data, complete

    def read_records(self, validator=validate_event, strict=True):
        """All committed records in file order as (bytes, object) pairs.
        With strict=False a non-LF-terminated tail is reported as an
        uncommitted partial record (skipped) instead of a fault."""
        data, complete = self._read_raw_lines()
        if strict and not complete:
            raise LedgerError("ledger %s ends in a partial line "
                              "(committed files are LF-terminated)"
                              % self.path)
        records = []
        if data:
            for i, line in enumerate(data.split(b"\n")[:-1], start=1):
                if not line:
                    raise LedgerError("%s line %d is empty" %
                                      (self.path, i))
                obj = parse_line(line, validator, self.path, i)
                records.append((line, obj))
        return records, complete

    def ingest_source(self, source_path):
        """Append the facts of a producer's events file (PR-4 output)
        byte-verbatim. The whole source validates and diffs against
        the ledger BEFORE anything is appended (fail-closed, no
        partial append of an invalid or divergent source);
        byte-identical duplicates of an already-present event_id are
        an idempotent skip, and the same event_id with different bytes
        is refused: the fact is immutable, a divergent duplicate would
        be a mutation attempt. Returns counters."""
        try:
            with open(source_path, "rb") as f:
                source = f.read()
        except OSError as exc:
            raise LedgerFault("cannot read source %s: %s"
                              % (source_path, exc))
        lines = source.split(b"\n")
        trailing = lines.pop()  # "" when the file is LF-terminated
        if trailing:
            # A missing final LF is tolerated: the bytes are preserved,
            # the LF is added on append (README §3).
            lines.append(trailing)
        new_lines, duplicated = self._plan_ingest(lines, source_path)
        for line in new_lines:
            self._appender.append(line + b"\n")
        return {"appended": len(new_lines), "duplicate": duplicated,
                "total": len(lines)}

    def ingest_lines(self, lines, origin="<watch batch>"):
        """Batch ingest for the resident worker (README §1): raw line
        bytes whose LF termination in the source the caller has
        already confirmed (the tail extraction never hands over a
        partial line; the LF is added on append). The whole batch
        validates and diffs against the ledger BEFORE anything is
        appended — all-or-nothing: an invalid, empty or divergent line
        leaves the ledger untouched and the caller's byte offset
        unadvanced. Byte-identical duplicates of a present event_id
        are an idempotent skip; the same event_id with different bytes
        is refused (the fact is immutable). The validation and dedup
        path is the exact code of ingest_source (_plan_ingest).
        Returns the same counters."""
        new_lines, duplicated = self._plan_ingest(list(lines), origin)
        for line in new_lines:
            self._appender.append(line + b"\n")
        return {"appended": len(new_lines), "duplicate": duplicated,
                "total": len(lines)}

    def _plan_ingest(self, lines, origin):
        """The one validation/dedup path both ingest entries share:
        validate every line, diff the batch against the ledger, and
        return (new_lines, duplicated_count) WITHOUT appending
        anything. Raises LedgerError on an empty line, an invalid
        record, or an event_id that already exists with different
        bytes (against the ledger or within the batch)."""
        staged = []
        for i, line in enumerate(lines, start=1):
            if not line:
                raise LedgerError("%s line %d is empty" % (origin, i))
            obj = parse_line(line, validate_event, origin, i)
            staged.append((obj["event_id"], line))

        existing = {}
        for raw, obj in self.read_records(strict=False)[0]:
            existing[obj["event_id"]] = raw

        new_lines = []
        duplicated = 0
        for event_id, line in staged:
            if event_id in existing:
                if existing[event_id] != line:
                    raise LedgerError(
                        "event_id %s already exists with different "
                        "bytes; the fact is immutable (README §3)"
                        % event_id)
                duplicated += 1
                continue
            new_lines.append(line)
            existing[event_id] = line
        return new_lines, duplicated

    def events(self, strict=True):
        """The facts in ledger order, as objects only."""
        return [obj for _, obj in self.read_records(
            validate_event, strict=strict)[0]]


class DeliveryLedger:
    """The append-only operational delivery ledger. State of a pair
    (event_id, device_id) = its LAST record in file order; earlier
    records remain as history. Writer: the dispatcher process only."""

    def __init__(self, path, lock=True):
        self.path = path
        self._lock = FileLock(path) if lock else None
        self._appender = Appender(path) if lock else None

    def close(self):
        if self._appender is not None:
            self._appender.close()
        if self._lock is not None:
            self._lock.release()

    def read_state(self):
        """Latest validated record per (event_id, device_id) pair."""
        records, _ = self.read_records(strict=False)
        state = {}
        for _, obj in records:
            state[(obj["event_id"], obj["device_id"])] = obj
        return state

    def read_records(self, validator=validate_delivery, strict=True):
        data, complete = self._read_raw()
        if strict and not complete:
            raise LedgerError("delivery ledger %s ends in a partial line"
                              % self.path)
        records = []
        if data:
            for i, line in enumerate(data.split(b"\n")[:-1], start=1):
                if not line:
                    raise LedgerError("%s line %d is empty"
                                      % (self.path, i))
                obj = parse_line(line, validator, self.path, i)
                records.append((line, obj))
        return records, complete

    def _read_raw(self):
        try:
            with open(self.path, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            return b"", False
        except OSError as exc:
            raise LedgerFault("cannot read %s: %s" % (self.path, exc))
        complete = True
        if data and not data.endswith(b"\n"):
            complete = False
            data = data[:data.rfind(b"\n") + 1]
        return data, complete

    def append(self, record):
        """Validate against the committed schema, then append + fsync."""
        validate_delivery(record)
        self._appender.append(encode_line(record) + b"\n")


class Registry:
    """The device registry: append-only JSONL OUTSIDE the repository
    (it stores FCM registration tokens — credentials never enter the
    repo). Latest record per device wins; a token_invalid record retires
    the device's token. Records carry the token only here — never in a
    delivery record, never in a log (mask_secret only)."""

    def __init__(self, path, lock=True):
        self.path = path
        self._lock = FileLock(path) if lock else None
        self._appender = None
        if lock:
            directory = os.path.dirname(path)
            if directory:
                os.makedirs(directory, exist_ok=True)
            try:
                self._appender = os.open(
                    path, os.O_WRONLY | os.O_CREAT | os.O_APPEND |
                    os.O_CLOEXEC, 0o600)
            except OSError as exc:
                raise LedgerFault("cannot open registry %s: %s"
                                  % (path, exc))
            size = os.fstat(self._appender).st_size
            if size:
                try:
                    with open(path, "rb") as f:
                        f.seek(size - 1)
                        committed = f.read(1) == b"\n"
                except OSError as exc:
                    raise LedgerFault("cannot inspect the tail of "
                                      "registry %s: %s" % (path, exc))
                if not committed:
                    os.close(self._appender)
                    self._appender = None
                    raise LedgerFault(
                        "registry %s ends in an uncommitted partial "
                        "line; refusing to append" % path)

    def close(self):
        if self._appender is not None:
            os.close(self._appender)
            self._appender = None
        if self._lock is not None:
            self._lock.release()

    def _records(self):
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                text = f.read()
        except FileNotFoundError:
            return []
        except OSError as exc:
            raise LedgerFault("cannot read registry %s: %s"
                              % (self.path, exc))
        records = []
        for i, line in enumerate(text.splitlines(), start=1):
            if not line:
                continue
            records.append(parse_line(line.encode("utf-8"),
                                      self._validate, self.path, i))
        return records

    @staticmethod
    def _validate(obj):
        if not isinstance(obj, dict):
            raise LedgerError("registry record is not a JSON object")
        kind = obj.get("kind")
        if kind not in ("device", "token_invalid"):
            raise LedgerError("registry record kind must be device or "
                              "token_invalid")
        _check_str(obj, "device_id", DEVICE_ID_RE)
        _check_str(obj, "at", TS_RE)
        if kind == "device":
            token = obj.get("fcm_token")
            if not isinstance(token, str) or not token or \
               len(token) > 4096:
                raise LedgerError("registry device record needs an "
                                  "fcm_token (1..4096 chars)")
        else:
            _check_str(obj, "fcm_token_hash")
            if "fcm_token" in obj:
                raise LedgerError("token_invalid must not carry the raw "
                                  "fcm_token (credential: hash only)")
        return obj

    def devices(self):
        """Active devices as {device_id: fcm_token}: latest device
        record per id wins; a later token_invalid retires it."""
        active = {}
        for obj in self._records():
            device_id = obj["device_id"]
            if obj["kind"] == "device":
                active[device_id] = obj["fcm_token"]
            else:
                active.pop(device_id, None)
        return active

    def _append(self, obj):
        self._validate(obj)
        line = encode_line(obj) + b"\n"
        view = memoryview(line)
        while view:
            written = os.write(self._appender, view)
            view = view[written:]
        os.fsync(self._appender)

    def add_device(self, device_id, fcm_token):
        """Register (or re-register, e.g. a refreshed token) a device."""
        self._append({"kind": "device", "device_id": device_id,
                      "fcm_token": fcm_token, "at": now_iso()})

    def mark_invalid(self, device_id, fcm_token):
        """Retire a token the provider rejected (UNREGISTERED). The raw
        token value is never written here — the sha256 mask only."""
        self._append({"kind": "token_invalid", "device_id": device_id,
                      "fcm_token_hash": mask_secret(fcm_token),
                      "at": now_iso()})


# --------------------------------------------------------------- CLI
#
# Exit codes (README §9): 0 normal, 2 usage/contract violation,
# 4 single-writer conflict / internal fault. Failures never exit 0.

def _main(argv):
    parser = argparse.ArgumentParser(
        description="event ledger: ingest facts byte-verbatim / check "
                    "ledger integrity (tools/notify/README.md §3)")
    parser.add_argument("command", choices=("ingest", "check"))
    parser.add_argument("--config", default=os.environ.get("HSNOTIFY_CONFIG",
                                                           ""))
    parser.add_argument("--source",
                        help="ingest: the producer's events file (PR-4 "
                             "output); facts are appended byte-verbatim")
    args = parser.parse_args(argv)

    try:
        cfg = notify_config.load_config(args.config, args.command)
    except notify_config.ConfigError as exc:
        print("notify_ledger: config refused: %s" % exc, file=sys.stderr)
        return 2
    if args.command == "ingest" and not (args.source and
                                         os.path.isabs(args.source)):
        print("notify_ledger: ingest needs an absolute --source path",
              file=sys.stderr)
        return 2

    try:
        ledger = EventLedger(cfg["ledger_path"], lock=True)
        try:
            if args.command == "check":
                records, _ = ledger.read_records(strict=True)
                print("check ok records=%d ledger=%s" %
                      (len(records), cfg["ledger_path"]))
                return 0
            stats = ledger.ingest_source(args.source)
            print("ingest appended=%(appended)d duplicate=%(duplicate)d "
                  "total=%(total)d ledger=%(ledger)s source=%(source)s" %
                  dict(stats, ledger=cfg["ledger_path"],
                       source=args.source))
            return 0
        finally:
            ledger.close()
    except LedgerBusy as exc:
        print("notify_ledger: %s" % exc, file=sys.stderr)
        return 4
    except LedgerFault as exc:
        print("notify_ledger: fault: %s" % exc, file=sys.stderr)
        return 4
    except LedgerError as exc:
        print("notify_ledger: contract violation: %s" % exc,
              file=sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
