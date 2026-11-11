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
sums — recorded values in, tags out, never a market judgment.

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


def fold_market_projection(path, session_date):
    """The §3.7 market fold of one input.hcj.jsonl — one streaming scan,
    three pure derivations of recorded bytes: the ka10027 name
    dictionary, the ka10027 chain-pair price snapshots and the ka10081
    MA20 close sums. Returns (names, snapshots, ma20): names is symbol
    -> stock name (file order, last record wins); snapshots is the list
    of {symbol: price} maps, one per completed ka10027 chain-pair in
    file order; ma20 is symbol -> the integer sum of the last
    MARKET_MA20_DAYS completed daily closes, absent for symbols with
    fewer than twenty completed recorded rows.

    Line discipline is the committed-lines rule: a trailing line
    without LF is not committed and stops the walk; a malformed
    committed line is a DataFault. A rest_resp envelope the recorder
    itself guarantees (raw object, string api_id, hex body_hex)
    faulting that guarantee is corruption, also a DataFault. The body
    content is NOT guaranteed (the recorder preserves every response
    verbatim, successful or not): a body that does not decode to a
    JSON object carrying its list key simply contributes nothing — a
    recorded non-success response carries no ranking and no bars.
    Rows and query fields the folds depend on are the dependent
    recorded shape: a ka10027 ranking row must be an object with
    string stk_cd, string stk_nm and a SIGNED_PRICE_RE cur_prc; a
    ka10027 query must carry the recorded sort_tp (MARKET_SORT_RISING
    or MARKET_SORT_FALLING), an integer page >= 1 and a string
    cont_yn; a ka10081 row must be an object with a BAR_DT_RE dt and a
    DAY_CLOSE_RE cur_prc; a ka10081 query must carry a string stk_cd.
    Violations are DataFaults — the event fold's symbol/rank
    discipline.

    The chain-pair rule (rest_resp records carry no timestamp: record
    order is time order): ka10027 records group into chains — a chain
    ends when cont_yn leaves "Y", and a new chain starts on a sort_tp
    change or a page-1 record (an interrupted chain is dropped, its
    prices never enter a snapshot). Chains pair rising -> falling in
    file order: a completed falling chain closes the pair and appends
    the union of both chains' prices (falling rows win a same-symbol
    collision) as one snapshot; a falling chain completing with no
    pending rising chain contributes its own prices alone. A pair whose
    price union is empty contributes no snapshot: a pre-open poll whose
    response affirms success with no ranking rows still closes a pair,
    but an empty snapshot can satisfy no correspondence subset and holds
    no price to project — counting it would drift the snapshot index
    against the event fold's candidate groups (non-candidate groups
    open no group index) and break the opening mode's same-index
    coupling. The snapshot list counts price-bearing pairs only. The ka10081
    fold keeps, per symbol, the first MARKET_MA20_DAYS distinct rows
    with dt < session_date in file order (rows are dt-descending, the
    session's in-progress bar carries dt == session_date and is never
    summed); the session_date is the selected run's own recorded
    config value, validated here before any row is folded."""
    names = {}
    snapshots = []
    ma20 = {}
    if not isinstance(session_date, str) \
            or SESSION_DATE_RE.match(session_date) is None:
        raise DataFault("%s MA20 fold session_date is not the recorded "
                        "YYYY-MM-DD shape" % INPUT_JSONL)
    session_digits = session_date.replace("-", "")
    chain = None         # [sort_tp, prices] of the chain being read
    pair_rising = None   # the completed rising chain's prices
    bars = {}            # symbol -> [dts seen, close sum, row count]
    try:
        f = open(path, "rb")
    except FileNotFoundError:
        return names, snapshots, ma20
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
    for symbol, entry in bars.items():
        if entry[2] >= MARKET_MA20_DAYS:
            ma20[symbol] = entry[1]
    return names, snapshots, ma20


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
        return "core", [], []
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
        return "core", [], []
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
    return "opening_ma20", rising, falling


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
        try:
            before = os.stat(path)
        except FileNotFoundError:
            return {}, [], {}
        except OSError as exc:
            raise DataFault("%s unreadable: %s"
                            % (os.path.basename(path), _reason(exc)))
        with self._fold_lock:
            entry = self._fold_entry
        if entry is not None and entry[:3] == (path, before.st_size,
                                               before.st_mtime_ns):
            return entry[3], entry[4], entry[5]
        names, snapshots, ma20 = fold_market_projection(path, session_date)
        try:
            after = os.stat(path)
        except OSError:
            return names, snapshots, ma20
        if (after.st_size, after.st_mtime_ns) \
                == (before.st_size, before.st_mtime_ns):
            with self._fold_lock:
                self._fold_entry = (path, before.st_size,
                                    before.st_mtime_ns, names, snapshots,
                                    ma20)
        return names, snapshots, ma20

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

    def market_view(self):
        """GET /mobile/market-view (README §3.7): the bounded,
        deterministic, read-only projection of the latest ELIGIBLE
        market-collection run. No judgment happens here: ranks are
        recorded facts, and this method only folds them, orders by a
        recorded field, selects, counts, and classifies TOP10 changes
        by the contract's state-comparison projection — recorded
        snapshots are compared, so every value in a change record is a
        recorded value and the classification follows the §3.7
        vocabulary. The VS-2 opening MA20 mode is one more recorded
        projection on the same fold: when the reference group's
        recorded observed_at falls in the opening window, the top10
        lists are reconstituted by opening_market_top10 from recorded
        prices against recorded close sums (§3.7). The runs root is
        listed once per request and every identity is read from
        recorded bytes (the committed config record), never the wall
        clock. The event fold and the response stay per-request
        locals; the one cached object is the derived market fold
        (§3.7, _market_projection)."""
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
                    "mode": "core", "run": None, "rising_top10": [],
                    "falling_top10": [], "runs_present": bool(names),
                    "status": None}
        # Selection (README §3.7): max session_date, then max last
        # committed observed_at (None ranks last), then max dirname.
        session, environment, session_date, run_id, _ = max(
            eligible, key=lambda run: (run[2], run[4] or "", run[0]))
        run_dir = os.path.join(self.runs_root, session)
        stock_names, snapshots, ma20 = self._market_projection(
            os.path.join(run_dir, INPUT_JSONL), session_date)
        events, _ = read_committed_lines(
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

        def confirm_group():
            """The §3.7 state-comparison projection: derive the TOP10
            change records of the just-closed observation group by
            comparing the previous confirmed snapshot with the live
            state. The classification follows MARKET_CHANGE_TYPES; every
            projected value is recorded. The first group (no snapshot)
            is the baseline and records zero changes. The group is also
            captured as the opening mode's reference candidate: its
            per-symbol candidate state (deduplicated over UP/DOWN — the
            item whose upsert holds the greatest ledger position
            represents a dual-direction symbol) and the symbols its
            batch upserted."""
            nonlocal prev_snapshot, confirmed
            per_symbol = {}
            for entry in live.values():
                current = per_symbol.get(entry["symbol"])
                if current is None or entry["pos"] > current["pos"]:
                    per_symbol[entry["symbol"]] = entry
            confirmed = (group_index, group_stamp, per_symbol,
                         set(group_upserts))
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
        mode, opening_rising, opening_falling = opening_market_top10(
            confirmed, snapshots, ma20)
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
