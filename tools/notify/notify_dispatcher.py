#!/usr/bin/env python3
"""notify_dispatcher: the VS-3 notification dispatcher (PR-5).

Contract: tools/notify/README.md; delivery.schema.json; docs/
REPLAY_CONTRACT.md §13; docs/ASSUMPTIONS.md P28 (admission). The
dispatcher is transport only: it filters, orders and translates events
for delivery (§13.1) — it never judges, upgrades or rewrites a fact.
The admission gate decides only the DELIVERY policy of a fact (which
channel, batched or alone, or never); the fact itself is always the
Core's authoritative output, unchanged.

Two modes (README §0/§1/§11):

One-shot sweep (default; the backward-compatible form):
  1. read the event ledger (read-only; a concurrently-appending tail is
     skipped, never half-consumed);
  2. apply the notification policy — the admission gate
     (notify_config.admission_mode, plan B by default):
     TOP10_ENTERED / TOP10_EXITED -> "immediate" (sound channel),
     RANK_CHANGED -> "digest" (silent channel), every other event
     type (faults, replay, session lifecycle included) -> "suppress"
     — recorded in the ledgers and never pushed (the old type_skipped
     meaning, same counter). Severity is a fact field, never a send
     decision;
  3. suppress duplicates: an ACCEPTED (event_id, device_id) pair is
     never sent again; a FAILED pair is terminal (UNREGISTERED token,
     SENDER_ID_MISMATCH config error, unknown permanent codes);
  4. compose the send units per observation group ((observed_at,
     device_id); README §0/§6): the group's immediate events share ONE
     sound message — kind "single" when alone (the exact per-event
     message form), kind "summary" when two or more — and the group's
     digest events ONE silent message (kind "digest"): a group never
     costs more than one sound + one silent push;
  5. append one delivery record per covered event and outcome
     (PENDING on retryable failures, ACCEPTED / FAILED otherwise;
     every record carries message_kind, digest members share the
     provider_message_id) — append-only, fsynced, so a crash between
     send and record replays the send on restart: the device may
     receive a duplicate push. That is FCM reality, not a bug, and the
     app identifies duplicates by event_id (README §6).
     accepted != delivered: HTTP 200 proves provider acceptance only.

Resident watch (--watch <abs events file>): the process stays alive and
owns BOTH ledgers as their single writer (one exclusive flock per file;
the event ledger is opened with the writer lock). Each tick
(watch_poll_seconds, default 1.0):
  a. stat the watched file — a missing file is a wait, not an error;
  b. a changed (st_dev, st_ino) means the producer recreated the file:
     reopen from offset 0 (full rescan — the ledger's event_id dedup
     makes the rescan idempotent);
  c. st_size < offset is an append-only violation: LedgerFault (exit 4),
     never a silent rescan;
  d. read from the byte offset and take only LF-terminated lines — LF
     is the commit marker; a partial tail is never consumed and the
     offset stays at the byte after the last LF;
  e. ingest the batch all-or-nothing (notify_ledger.EventLedger.
     ingest_lines): an invalid batch is not appended, the offset does
     not advance, a stderr alarm names the fault, and the same batch is
     retried next tick;
  f. run ONE dispatch pass over the pairs whose retry is due now. The
     retry wait is deferred between ticks (next_due = now + wait, no
     in-sweep sleep): a 429 Retry-After wait never delays a new event.
     Nothing is parked — the resident worker resumes its own pairs.

Run scope (README §1): the resident worker dispatches only facts of
the run it watches. The scope is the session_id learned from the
watched file's own ingested bytes (every fact carries it; the file is
one session) and the first validated batch pins it for the process.
Until it is known — file absent, empty or without a committed line
yet — the worklist is EMPTY: the historical ledger is never swept.
A fact of another session is counted scope_skipped and never forms a
pair: no delivery record, no retry schedule (it is a ledger-only
artifact of another run). A stale market fact is not actionable, so
the cross-session grace window is 0 by default; widening it is a user
policy decision, not a dispatcher default. The one-shot sweep and
--admission-report stay unscoped (backward compatibility; the report
replays exactly the file it is given).

Admission report (--admission-report <abs events file>): the replay
tool (README §9) — no send, no ledger write. The first line states the
policy source (the config admission section or the default plan B —
an absent section is never conflated with a configured one) and the
full mapping; then every fact of the file judged with THE SAME
admission code the dispatch path uses, one verdict line per event, the
per-observation-group send plan and the totals. The same file + policy
always print the same bytes.

SIGTERM/SIGINT request a clean stop: the current tick finishes, the
single-writer locks are released and the process exits 0. All stdout
lines of the resident mode carry an ISO timestamp prefix.

Retry classes (vendor table, tools/notify/README.md §5):
  429 QUOTA_EXCEEDED / 500 INTERNAL / 503 UNAVAILABLE / transport
  failure -> stay PENDING, backoff >= max(retry_min_seconds, Retry-After):
  the one-shot sweep retries in-sweep while the wait is within
  backoff_cap_seconds and parks PENDING otherwise (external scheduler
  resumes); the resident watch defers the pair and keeps serving. A
  deferred UNIT is reassembled with exactly the same members on the
  next pass (all members share one next_due — partial delivery of a
  group is impossible: one message covers the whole unit or nothing);
  404 UNREGISTERED (the REST wire spells it NOT_FOUND — google.rpc
  canonical name for 404; classify_send retires on either) -> FAILED,
  token retired in the registry, no retry;
  403 SENDER_ID_MISMATCH -> FAILED (config error, fail-closed, no
  retry), the sweep keeps serving the other devices and the process
  exits 3 — a config error is never a clean success;
  everything else -> FAILED with the provider's status kept verbatim.

Exit codes (README §9): 0 sweep completed / clean shutdown / report
printed, 2 usage/config violation, 3 credential failure or fail-closed
sender mismatch, 4 single-writer conflict / internal fault / ledger
contract violation (watched file shrank, torn report input).
"""

import json
import os
import signal
import sys
import time

import notify_config
import notify_fcm
import notify_ledger

# The delivery policy's event-type universe (README §0/§6): only the
# market TOP10 rank transitions can be admitted (immediate/digest);
# every other type is suppress. The set is notify_fcm's
# TOP10_EVENT_TYPES so the policy, the message assembly and
# notify_config's admission validation share one truth: a fourth
# notifiable type changes all of them together or neither.
NOTIFIABLE_EVENT_TYPES = notify_fcm.TOP10_EVENT_TYPES


def compose_admission_units(events, cfg):
    """The admission send plan for ONE observation group (same
    observed_at, same device; README §0): the events the policy judges
    "immediate" become ONE sound unit — kind "single" when the event is
    alone, "summary" when two or more — and the "digest" events ONE
    silent unit (kind "digest"); a group never yields more than one
    sound + one silent unit. Ledger order is preserved inside each unit
    and the sound unit precedes the silent one. THE SAME function plans
    the dispatcher's sends and the admission report's output: replay
    composes exactly what production composes."""
    immediate = []
    digest = []
    for event in events:
        mode = notify_config.admission_mode(cfg, event["event_type"])
        if mode == "immediate":
            immediate.append(event)
        elif mode == "digest":
            digest.append(event)
    units = []
    if immediate:
        units.append(("single" if len(immediate) == 1 else "summary",
                      immediate))
    if digest:
        units.append(("digest", digest))
    return units


class Dispatcher:
    """One dispatch sweep over the event ledger, or a resident watch
    worker. The transport (`opener`) and the clock/sleep pair are
    injectable so the contract tests and the fake-FCM drill drive the
    real state machine. With resident=True the worker is the single
    WRITER of both the event ledger and the delivery ledger (one
    exclusive flock per file, held for the process lifetime); the
    one-shot sweep stays a read-only consumer of the event ledger."""

    def __init__(self, cfg, opener=None, clock=time.time,
                 sleeper=time.sleep, resident=False):
        self.cfg = cfg
        self._clock = clock
        self._sleep = sleeper
        self._resident = resident
        self.delivery = notify_ledger.DeliveryLedger(cfg["delivery_path"],
                                                     lock=True)
        self.registry = notify_ledger.Registry(cfg["registry_path"],
                                               lock=True)
        self.ledger = notify_ledger.EventLedger(cfg["ledger_path"],
                                                lock=resident)
        self.tokens = notify_fcm.TokenSource(cfg, opener=opener)
        self.project_id = cfg["project_id"]
        self.retry_min = cfg["retry_min_seconds"]
        self.backoff_cap = cfg["backoff_cap_seconds"]
        self.opener = opener or notify_fcm.urllib.request.urlopen
        self.mismatch_seen = False
        self.counts = {}
        # The resident retry schedule, keyed (event_id, device_id):
        # the epoch second a pair becomes due again. Persists across
        # ticks; a one-shot sweep builds its own local map.
        self._next_due = {}
        # The resident run scope (README §1): the session_id of the
        # watched run, learned from the watched file's own ingested
        # bytes and pinned by the first validated batch. None until
        # then — the resident worklist is empty (fail-closed): the
        # historical ledger is never swept.
        self._session_id = None
        # SIGTERM/SIGINT set this between-ticks stop request.
        self._stop = False

    def close(self):
        for resource in (self.ledger, self.registry, self.delivery):
            try:
                resource.close()
            except notify_ledger.LedgerBusy:
                pass

    # ------------------------------------------------------ selection

    def _candidates(self, events, state, devices, session_id=None,
                    run_scoped=False):
        """The worklist in deterministic order (ledger order, then
        sorted device id), after the run scope, the admission filter
        and dedup. With run_scoped (the resident worker) only facts of
        the watched run's session are candidates: the scope is the
        session_id learned from the watched file's own ingested bytes
        (README §1). While it is unknown (file absent, empty or
        without a committed line yet) the worklist is EMPTY —
        fail-closed, the historical ledger is never swept. A fact of
        another session is counted scope_skipped and never forms a
        pair: it gets no delivery record and no retry schedule (it is
        a ledger-only artifact of another run). Counters record what
        the scope and the policy removed: type_skipped counts every
        in-scope fact the policy judges suppress — types outside the
        admission universe and types the config maps to suppress alike
        (the old type filter's meaning, same counter)."""
        self.counts["events_total"] = len(events)
        self.counts["devices_active"] = len(devices)
        if run_scoped and session_id is None:
            self.counts["scope_skipped"] = 0
            self.counts["type_skipped"] = 0
            return []
        scope_skipped = 0
        in_scope = []
        for event in events:
            if run_scoped and event["session_id"] != session_id:
                scope_skipped += 1
                continue
            in_scope.append(event)
        if run_scoped:
            self.counts["scope_skipped"] = scope_skipped
        notifyable = 0
        pairs = []
        for event in in_scope:
            if notify_config.admission_mode(self.cfg,
                                            event["event_type"]) == \
                    "suppress":
                continue
            notifyable += 1
            for device_id in sorted(devices):
                record = state.get((event["event_id"], device_id))
                if record is not None and record["state"] == "ACCEPTED":
                    self.counts["dedup_suppressed"] = \
                        self.counts.get("dedup_suppressed", 0) + 1
                    continue
                if record is not None and record["state"] == "FAILED":
                    # Terminal: permanent error, retired token or the
                    # fail-closed sender mismatch — none is retried.
                    self.counts["terminal_skipped"] = \
                        self.counts.get("terminal_skipped", 0) + 1
                    continue
                pairs.append((event, device_id,
                              record["attempts"] if record else 0))
        self.counts["type_skipped"] = len(in_scope) - notifyable
        return pairs

    # ------------------------------------------------------- delivery

    def _record(self, event, device_id, state, attempts, error_code=None,
                provider_message_id=None, message_kind=None):
        record = {
            "attempts": attempts,
            "device_id": device_id,
            "event_id": event["event_id"],
            "state": state,
            "updated_at": notify_ledger.now_iso(),
        }
        if error_code is not None:
            record["error_code"] = error_code
        if provider_message_id is not None:
            record["provider_message_id"] = provider_message_id
        if message_kind is not None:
            record["message_kind"] = message_kind
        self.delivery.append(record)  # validates before it writes
        return record

    def _attempt_unit(self, unit, token, state):
        """One send + honest records for every covered event. The unit
        (README §0/§6) is the delivery granularity: one FCM message
        covers ALL its events, so every outcome is recorded once per
        member event — a group's members share the provider message
        id — and a retryable failure defers every member together
        (partial delivery of a group is impossible: the message covers
        the whole unit or nothing). Returns (outcome_kind, next_wait).
        """
        msg_kind = unit["kind"]
        events = unit["events"]
        device_id = unit["device_id"]
        bases = []
        for event in events:
            record = state.get((event["event_id"], device_id))
            bases.append(record["attempts"] if record else 0)

        def tag():
            # The single unit keeps the historical log line shape
            # (event/attempts); group units identify themselves.
            if msg_kind == "single":
                return "event=%s device=%s" % (events[0]["event_id"],
                                               device_id)
            return "kind=%s count=%d first=%s device=%s" % (
                msg_kind, len(events), events[0]["event_id"], device_id)

        def record_all(delivery_state, error_code=None,
                       provider_message_id=None):
            for event, base in zip(events, bases):
                state[(event["event_id"], device_id)] = self._record(
                    event, device_id, delivery_state, base + 1,
                    error_code=error_code,
                    provider_message_id=provider_message_id,
                    message_kind=msg_kind)

        try:
            if msg_kind == "single":
                message = notify_fcm.build_message(events[0], token)
            elif msg_kind == "summary":
                message = notify_fcm.build_summary_message(events, token)
            else:
                message = notify_fcm.build_digest_message(events, token)
        except notify_fcm.FcmError:
            # Refused before send (payload limit): a permanent scanner
            # refusal, recorded honestly for every covered event
            # (HS_ codes are synthetic).
            record_all("FAILED", error_code="HS_PAYLOAD_OVER_LIMIT")
            self.counts["failed_permanent"] = \
                self.counts.get("failed_permanent", 0) + len(events)
            self._log("dispatch result=permanent %s status=- "
                      "error=HS_PAYLOAD_OVER_LIMIT" % tag())
            return "permanent", None

        if self._resident:
            # Post-observability: one timestamped line when the POST is
            # initiated, so start/answer times are measurable from the
            # log (the result line format below is unchanged).
            if msg_kind == "single":
                self._log("dispatch attempt_start %s attempts=%d"
                          % (tag(), bases[0] + 1))
            else:
                self._log("dispatch attempt_start %s" % tag())
        outcome = notify_fcm.send_message(self.project_id,
                                          self.tokens.get(self._clock()),
                                          message, opener=self.opener)

        if outcome.kind == "accepted":
            record_all("ACCEPTED",
                       provider_message_id=outcome.provider_message_id)
            self.counts["accepted"] = \
                self.counts.get("accepted", 0) + len(events)
            if msg_kind == "single":
                self._log("dispatch result=accepted %s attempts=%d "
                          "status=200 message=%s" %
                          (tag(), bases[0] + 1,
                           outcome.provider_message_id))
            else:
                self._log("dispatch result=accepted %s status=200 "
                          "message=%s" % (tag(),
                                          outcome.provider_message_id))
            return "accepted", None

        if outcome.kind == "unregistered":
            # The vendor's answer: remove this token from the server and
            # stop sending to it — the delivery is terminal FAILED for
            # every covered event and the token is retired (hash only)
            # in the registry, once for the unit.
            record_all("FAILED", error_code=outcome.error_code)
            self.registry.mark_invalid(device_id, token)
            self.counts["token_retired"] = \
                self.counts.get("token_retired", 0) + 1
            if msg_kind == "single":
                self._log("dispatch result=unregistered %s attempts=%d "
                          "status=%d error=%s token=%s" %
                          (tag(), bases[0] + 1, outcome.http_status,
                           outcome.error_code,
                           notify_ledger.mask_secret(token)))
            else:
                self._log("dispatch result=unregistered %s status=%d "
                          "error=%s token=%s" %
                          (tag(), outcome.http_status, outcome.error_code,
                           notify_ledger.mask_secret(token)))
            return "unregistered", None

        if outcome.kind == "sender_mismatch":
            # Fail-closed: a configuration error (the authenticated
            # sender is not a sender of this token). No retry, honest
            # FAILED records for every covered event, and exit 3 —
            # never a clean success.
            record_all("FAILED", error_code=outcome.error_code)
            self.mismatch_seen = True
            self.counts["sender_mismatch"] = \
                self.counts.get("sender_mismatch", 0) + 1
            print("dispatcher: SENDER_ID_MISMATCH for device=%s "
                  "(token=%s): the configured sender cannot send to this "
                  "token; fix the project/sender configuration, no "
                  "retry (fail-closed)" %
                  (device_id, notify_ledger.mask_secret(token)),
                  file=sys.stderr)
            if msg_kind == "single":
                self._log("dispatch result=sender_mismatch %s attempts=%d "
                          "status=%d error=%s" %
                          (tag(), bases[0] + 1, outcome.http_status,
                           outcome.error_code))
            else:
                self._log("dispatch result=sender_mismatch %s status=%d "
                          "error=%s" % (tag(), outcome.http_status,
                                        outcome.error_code))
            return "sender_mismatch", None

        if outcome.kind == "retry":
            record_all("PENDING")
            self.counts["retried_pending"] = \
                self.counts.get("retried_pending", 0) + len(events)
            wait = max(self.retry_min, outcome.retry_after_seconds or 0)
            if msg_kind == "single":
                self._log("dispatch result=retry %s attempts=%d status=%s "
                          "error=%s wait=%ds" %
                          (tag(), bases[0] + 1, outcome.http_status,
                           outcome.error_code, wait))
            else:
                self._log("dispatch result=retry %s status=%s error=%s "
                          "wait=%ds" % (tag(), outcome.http_status,
                                        outcome.error_code, wait))
            return "retry", wait

        # permanent: any other provider answer, kept verbatim.
        record_all("FAILED", error_code=outcome.error_code)
        self.counts["failed_permanent"] = \
            self.counts.get("failed_permanent", 0) + len(events)
        if msg_kind == "single":
            self._log("dispatch result=permanent %s attempts=%d status=%s "
                      "error=%s" % (tag(), bases[0] + 1,
                                    outcome.http_status,
                                    outcome.error_code))
        else:
            self._log("dispatch result=permanent %s status=%s error=%s"
                      % (tag(), outcome.http_status, outcome.error_code))
        return "permanent", None

    def _log(self, line):
        # The resident mode timestamps every stdout line (README §1);
        # the one-shot output is byte-identical to the old contract.
        prefix = notify_ledger.now_iso() + " " if self._resident else ""
        print(prefix + line, flush=True)

    # ---------------------------------------------------------- sweep

    def _plan_units(self, due):
        """The send units for the due pairs, deterministically: group
        by (observed_at, device_id) in ledger first-appearance order,
        then compose_admission_units per group (sound before silent
        within a group). The grouping is derived from the ledger on
        every pass, so a deferred unit is reassembled with exactly the
        same members (members of one group share one next_due and can
        never drift into different passes)."""
        groups = {}
        order = []
        for event, device_id in due:
            key = (event["observed_at"], device_id)
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append(event)
        units = []
        for key in order:
            for msg_kind, events in compose_admission_units(
                    groups[key], self.cfg):
                units.append({"kind": msg_kind, "device_id": key[1],
                              "events": events})
        return units

    def sweep_pass(self, pairs, state, token_by_device, next_due,
                   park_beyond_cap=True):
        """One pass over the worklist: the due pairs are composed into
        observation-group send units (README §0/§6) and every unit is
        sent; returns the number of MESSAGES attempted (a unit is one
        message). A retryable outcome defers EVERY member of the unit
        to the same next_due (one clock reading) — partial delivery of
        a group is impossible. With park_beyond_cap (the one-shot
        scheduler resume) a wait beyond backoff_cap_seconds parks the
        unit (next_due None, the records stay PENDING) instead; the
        resident worker passes False — it is its own resume, nothing
        is parked."""
        now = self._clock()
        due = []
        for event, device_id, _attempts in pairs:
            pair = (event["event_id"], device_id)
            due_at = next_due.get(pair)
            if due_at is None or due_at > now:
                continue
            due.append((event, device_id))
        sent = 0
        for unit in self._plan_units(due):
            device_id = unit["device_id"]
            kind, wait = self._attempt_unit(unit,
                                            token_by_device[device_id],
                                            state)
            sent += 1
            if kind == "retry" and wait is not None and \
               (not park_beyond_cap or wait <= self.backoff_cap):
                due_again = self._clock() + wait
                for event in unit["events"]:
                    next_due[(event["event_id"], device_id)] = due_again
                continue
            if kind == "retry":
                # Beyond the cap (one-shot): parked for external resume.
                self.counts["pending_parked"] = \
                    self.counts.get("pending_parked", 0) + \
                    len(unit["events"])
            for event in unit["events"]:
                next_due[(event["event_id"], device_id)] = None
        return sent

    def sweep(self):
        """The full one-shot sweep. Returns the process exit code: 0, or
        3 when a sender mismatch occurred (other work still completes).
        The pass loop is sweep_pass with park_beyond_cap=True: the only
        sleeping happens between passes, on the (single) retry wait."""
        state = self.delivery.read_state()
        events = self.ledger.events(strict=False)
        devices = self.registry.devices()
        pairs = self._candidates(events, state, devices)
        self.counts["pairs_to_send"] = len(pairs)

        next_due = {}
        for event, device_id, _attempts in pairs:
            next_due[(event["event_id"], device_id)] = 0.0

        token_by_device = dict(devices)
        while True:
            if self.sweep_pass(pairs, state, token_by_device, next_due):
                continue
            pending = [due_at for due_at in next_due.values()
                       if due_at is not None]
            if not pending:
                break
            wait = min(pending) - self._clock()
            if wait > self.backoff_cap:
                # Parked: the records stay PENDING for the external
                # scheduler; nothing is marked delivered here.
                self.counts["pending_parked"] = len(pending)
                break
            self._sleep(max(wait, 0.0))
        return 3 if self.mismatch_seen else 0

    # ---------------------------------------------------------- watch

    def watch(self, events_path):
        """The resident loop (README §1/§11): tail the producer's
        events file, ingest each batch of complete lines
        (all-or-nothing) and run one dispatch pass per tick, until
        SIGTERM/SIGINT. Returns the process exit code: 0 on clean
        shutdown. Contract/I-O violations raise (LedgerFault -> exit
        4); a refused batch is a stderr alarm and a next-tick retry,
        never a skipped line."""
        poll = self.cfg["watch_poll_seconds"]
        offset = 0
        identity = None
        self._log("watch start events=%s poll_seconds=%g pid=%d"
                  % (events_path, poll, os.getpid()))
        while not self._stop:
            offset, identity = self.watch_tick(events_path, offset,
                                               identity)
            self.counts["watch_ticks"] = \
                self.counts.get("watch_ticks", 0) + 1
            if not self._stop:
                self._sleep(poll)
        self.counts["exit"] = 0
        self._log("watch stop " + json.dumps(self.counts,
                                             ensure_ascii=False,
                                             separators=(",", ":")))
        return 0

    def watch_tick(self, path, offset, identity):
        """One resident tick: tail the watched file at the byte offset,
        ingest the new LF-terminated lines (all-or-nothing: the offset
        advances only over a batch that fully validated and appended),
        then one dispatch pass over the due pairs. Returns the
        (offset, identity) for the next tick."""
        try:
            st = os.stat(path)
        except FileNotFoundError:
            # The producer has not created the file yet: waiting is not
            # an error (README §1). The offset and identity are kept;
            # a re-appearing file with a different inode rescans.
            self.dispatch_tick()
            return offset, identity
        except OSError as exc:
            raise notify_ledger.LedgerFault("watch stat %s: %s"
                                            % (path, exc))
        ident = (st.st_dev, st.st_ino)
        if identity is not None and ident != identity:
            # Recreated/replaced file: rescan from byte 0. The ledger's
            # event_id dedup (same id, same bytes -> idempotent skip)
            # is what makes the full rescan safe (README §1).
            self._log("watch reopen dev=%d ino=%d rescan offset=0"
                      % ident)
            offset = 0
        if st.st_size < offset:
            # Append-only violation: consumed bytes are gone. Fail
            # closed — a silent rescan would pretend the loss away.
            raise notify_ledger.LedgerFault(
                "watch %s shrank: st_size=%d < offset=%d (append-only "
                "violation, README §1)" % (path, st.st_size, offset))
        if identity is None:
            self._log("watch open dev=%d ino=%d" % ident)
        try:
            with open(path, "rb") as f:
                f.seek(offset)
                data = f.read()
        except OSError as exc:
            raise notify_ledger.LedgerFault("watch read %s: %s"
                                            % (path, exc))
        nl = data.rfind(b"\n")
        if nl < 0:
            # No LF yet: the partial tail is not committed (LF is the
            # commit marker); nothing is consumed, the offset stays.
            self.dispatch_tick()
            return offset, ident
        new_offset = offset + nl + 1
        lines = data[:nl + 1].split(b"\n")[:-1]
        stats = None
        try:
            stats = self.ledger.ingest_lines(lines, origin=path)
        except notify_ledger.LedgerError as exc:
            # Fail-closed, never a quiet skip: nothing appended, the
            # offset unadvanced, this batch's delivery stopped; the
            # same batch is retried next tick until it is fixed.
            print("dispatcher: WATCH BATCH REFUSED (%s): %s; nothing "
                  "appended, offset kept at %d, retrying next tick "
                  "(fail-closed)" % (path, exc, offset), file=sys.stderr)
        if stats is None:
            self._log("watch tick new=%d ingested=0 appended=0 dup=0 "
                      "refused=1 offset=%d" % (len(lines), offset))
            # The offset stays: the refused batch is re-read next tick.
        else:
            self._learn_session(lines, path)
            self._log("watch tick new=%d ingested=%d appended=%d "
                      "dup=%d offset=%d"
                      % (stats["total"], stats["total"],
                         stats["appended"], stats["duplicate"],
                         new_offset))
            offset = new_offset
        self.dispatch_tick()
        return offset, ident

    def _learn_session(self, lines, path):
        """Learn the run scope from the watched file's own ingested
        bytes (README §1): every fact carries session_id and the file
        is one session, so the first validated batch pins the scope for
        this process. A batch carrying several session ids is a
        contract violation: the scope is not learned (fail-closed, no
        dispatch) and a stderr alarm names it. Once pinned, a later
        batch of another session never widens the scope — its facts
        stay ledger-only and are counted scope_skipped."""
        session_ids = set()
        for line in lines:
            session_ids.add(json.loads(line.decode("utf-8"))["session_id"])
        if len(session_ids) != 1:
            # The watched file is one session (contract): a mixed batch
            # cannot teach the run scope. With no scope yet the worker
            # stays fail-closed (empty worklist); a pinned scope keeps
            # deciding and the other-session facts are scope_skipped.
            if self._session_id is None:
                print("dispatcher: WATCH SCOPE AMBIGUOUS (%s): a batch "
                      "carries %d session ids; the watched file is one "
                      "session, so the run scope is not learned and the "
                      "resident worklist stays empty (fail-closed)"
                      % (path, len(session_ids)), file=sys.stderr)
            return
        session_id = session_ids.pop()
        if self._session_id is None:
            self._session_id = session_id
            self._log("watch scope session=%s" % session_id)

    def dispatch_tick(self):
        """One resident dispatch pass (README §5): re-read the small
        state files, extend the schedule with the pairs not seen
        before, and send what is due now — the due pairs composed into
        observation-group send units (one message per unit; a
        retryable answer defers every member of the unit to the same
        next_due = now + wait, one clock reading). The wait is spent
        BETWEEN ticks, never in-sweep, so a 429 Retry-After wait never
        delays a new event; nothing is parked: the resident worker
        resumes its own pairs. Returns the number of MESSAGES
        attempted."""
        state = self.delivery.read_state()
        events = self.ledger.events(strict=False)
        devices = self.registry.devices()
        pairs = self._candidates(events, state, devices,
                                 session_id=self._session_id,
                                 run_scoped=True)
        next_due = self._next_due
        for event, device_id, _attempts in pairs:
            pair = (event["event_id"], device_id)
            if pair not in next_due:
                next_due[pair] = 0.0
        sent = self.sweep_pass(pairs, state, dict(devices), next_due,
                               park_beyond_cap=False)
        self.counts["messages_sent"] = \
            self.counts.get("messages_sent", 0) + sent
        return sent


def _install_signal_handlers(dispatcher):
    """SIGTERM/SIGINT request a clean stop (README §9): the handler
    only sets the flag the watch loop checks between ticks, so the
    current tick finishes (no half-batch, no half-send), the
    single-writer locks are released and the process exits 0 — which
    systemd Restart=on-failure does not restart. Main thread only."""
    def _request_stop(_signum, _frame):
        dispatcher._stop = True

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _request_stop)


# ----------------------------------------------------- admission report


def admission_report(cfg, events_path):
    """The admission replay tool (README §9; docs/ASSUMPTIONS.md P28):
    read an events file, judge EVERY fact with the same admission code
    the dispatch path uses (notify_config.admission_mode,
    compose_admission_units), and print — the policy source FIRST (the
    config admission section or the default plan B, stated as such: an
    absent section is never conflated with a configured one), one
    verdict line per fact (file order), then per observation group the
    send summary and the composed message plan (title/body/event_ids —
    the exact composition the dispatcher would send), then the totals.
    No send, no ledger write, no clock: the same file + policy always
    prints the same bytes. A plan whose composed payload would exceed
    the vendor limit is printed as refused (the same
    HS_PAYLOAD_OVER_LIMIT refusal the dispatcher records) — never a
    silently truncated composition. Returns 0."""
    ledger = notify_ledger.EventLedger(events_path, lock=False)
    try:
        events = ledger.events(strict=True)
    finally:
        ledger.close()

    groups = {}
    order = []
    for event in events:
        key = event["observed_at"]
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(event)

    plans = []
    forms = {}
    for key in order:
        group_plans = []
        for msg_kind, unit_events in compose_admission_units(
                groups[key], cfg):
            plan = {"kind": msg_kind, "count": len(unit_events),
                    "event_ids": [event["event_id"]
                                  for event in unit_events]}
            for event in unit_events:
                forms[event["event_id"]] = msg_kind
            try:
                if msg_kind == "single":
                    message = notify_fcm.build_message(unit_events[0], "")
                elif msg_kind == "summary":
                    message = notify_fcm.build_summary_message(
                        unit_events, "")
                else:
                    message = notify_fcm.build_digest_message(
                        unit_events, "")
                plan["title"] = \
                    message["message"]["notification"]["title"]
                plan["body"] = message["message"]["notification"]["body"]
            except notify_fcm.FcmError:
                # The same refusal class the dispatcher records for an
                # oversized composition: fail-closed, never truncated.
                plan["refused"] = "HS_PAYLOAD_OVER_LIMIT"
            group_plans.append(plan)
        plans.append((key, group_plans))

    verdicts = {"ADMIT": 0, "DIGEST": 0, "SUPPRESS": 0}
    lines = []
    for event in events:
        event_type = event["event_type"]
        mode = notify_config.admission_mode(cfg, event_type)
        if mode == "immediate":
            verdict = "ADMIT"
            form = forms.get(event["event_id"], "single")
        elif mode == "digest":
            verdict = "DIGEST"
            form = "digest"
        else:
            verdict = "SUPPRESS"
            form = "not_in_admission" if event_type not in \
                notify_fcm.TOP10_EVENT_TYPES else "suppress"
        verdicts[verdict] += 1
        lines.append("admission event=%s type=%s observed_at=%s "
                     "verdict=%s form=%s" %
                     (event["event_id"], event_type,
                      event["observed_at"], verdict, form))

    sound_total = 0
    silent_total = 0
    refused_total = 0
    for key, group_plans in plans:
        sound = sum(1 for plan in group_plans
                    if plan["kind"] in ("single", "summary")
                    and "refused" not in plan)
        silent = sum(1 for plan in group_plans
                     if plan["kind"] == "digest"
                     and "refused" not in plan)
        sound_total += sound
        silent_total += silent
        lines.append("admission group observed_at=%s events=%d sound=%d "
                     "silent=%d" % (key, len(groups[key]), sound, silent))
        for plan in group_plans:
            if "refused" in plan:
                refused_total += 1
                lines.append("admission plan observed_at=%s kind=%s "
                             "count=%d refused=%s event_ids=%s" %
                             (key, plan["kind"], plan["count"],
                              plan["refused"],
                              ",".join(plan["event_ids"])))
            else:
                lines.append("admission plan observed_at=%s kind=%s "
                             "count=%d title=%s body=%s event_ids=%s" %
                             (key, plan["kind"], plan["count"],
                              plan["title"], plan["body"],
                              ",".join(plan["event_ids"])))
    lines.append("admission total events=%d groups=%d sound=%d silent=%d "
                 "admit=%d digest=%d suppress=%d refused=%d" %
                 (len(events), len(order), sound_total, silent_total,
                  verdicts["ADMIT"], verdicts["DIGEST"],
                  verdicts["SUPPRESS"], refused_total))
    # The first line states WHICH policy decided — the config admission
    # section or the default plan B — and the full mapping, so an
    # absent section is never mistaken for a configured one.
    source = cfg.get("admission_source",
                     "config" if "admission" in cfg else "default")
    mapping = notify_config.effective_admission(cfg)
    lines.insert(0, "admission policy source=%s %s" % (source, " ".join(
        "%s=%s" % (et, mapping[et]) for et in sorted(mapping))))
    for line in lines:
        print(line, flush=True)
    return 0


def _main(argv):
    import argparse

    parser = argparse.ArgumentParser(
        description="notification dispatcher: ledger -> policy -> "
                    "dedup -> FCM HTTP v1 -> delivery records "
                    "(tools/notify/README.md)")
    parser.add_argument("--config",
                        default=os.environ.get("HSNOTIFY_CONFIG", ""))
    parser.add_argument("--watch", metavar="EVENTS_FILE", default=None,
                        help="resident mode: tail this producer events "
                             "file (absolute path), ingest each batch of "
                             "complete lines into the event ledger and "
                             "run one dispatch pass per tick until "
                             "SIGTERM/SIGINT (README §1/§11)")
    parser.add_argument("--admission-report", metavar="EVENTS_FILE",
                        default=None,
                        help="replay tool: judge every fact of this "
                             "events file (absolute path) with the SAME "
                             "admission code the dispatch path uses and "
                             "print the verdicts, the per-observation-"
                             "group send plan and the totals — no send, "
                             "no ledger write; byte-identical for the "
                             "same file + policy (README §0/§9)")
    args = parser.parse_args(argv)

    if args.watch and not os.path.isabs(args.watch):
        print("dispatcher: --watch needs an absolute path (got %r)"
              % args.watch, file=sys.stderr)
        return 2
    if args.admission_report:
        if args.watch:
            print("dispatcher: --admission-report replays a file; it "
                  "cannot run together with --watch", file=sys.stderr)
            return 2
        if not os.path.isabs(args.admission_report):
            print("dispatcher: --admission-report needs an absolute "
                  "path (got %r)" % args.admission_report, file=sys.stderr)
            return 2

    try:
        cfg = notify_config.load_config(args.config, "dispatch")
    except notify_config.ConfigError as exc:
        print("dispatcher: config refused: %s" % exc, file=sys.stderr)
        return 2

    if args.admission_report:
        # No Dispatcher is constructed: the report sends nothing and
        # writes no ledger — it only needs the validated policy.
        if not os.path.isfile(args.admission_report):
            print("dispatcher: --admission-report file not found: %s"
                  % args.admission_report, file=sys.stderr)
            return 2
        try:
            return admission_report(cfg, args.admission_report)
        except (notify_ledger.LedgerBusy, notify_ledger.LedgerFault,
                notify_ledger.LedgerError) as exc:
            print("dispatcher: %s" % exc, file=sys.stderr)
            return 4

    dispatcher = None
    try:
        dispatcher = Dispatcher(cfg, resident=bool(args.watch))
        if args.watch:
            _install_signal_handlers(dispatcher)
            code = dispatcher.watch(args.watch)
            dispatcher.counts["exit"] = code
        else:
            code = dispatcher.sweep()
            dispatcher.counts["exit"] = code
            print("sweep " + json.dumps(dispatcher.counts,
                                        ensure_ascii=False,
                                        separators=(",", ":")), flush=True)
        return code
    except notify_config.ConfigError as exc:
        print("dispatcher: config refused: %s" % exc, file=sys.stderr)
        return 2
    except notify_fcm.FcmError as exc:
        print("dispatcher: credential failure: %s" % exc, file=sys.stderr)
        return 3
    except (notify_ledger.LedgerBusy, notify_ledger.LedgerFault,
            notify_ledger.LedgerError) as exc:
        print("dispatcher: %s" % exc, file=sys.stderr)
        return 4
    finally:
        if dispatcher is not None:
            dispatcher.close()


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
