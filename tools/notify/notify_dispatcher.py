#!/usr/bin/env python3
"""notify_dispatcher: the VS-3 notification dispatcher (PR-5).

Contract: tools/notify/README.md; delivery.schema.json; docs/
REPLAY_CONTRACT.md §13. The dispatcher is transport only: it filters,
orders and translates events for delivery (§13.1) — it never judges,
upgrades or rewrites a fact.

Two modes (README §0/§1/§11):

One-shot sweep (default; the backward-compatible form):
  1. read the event ledger (read-only; a concurrently-appending tail is
     skipped, never half-consumed);
  2. apply the notification policy — the event-type allowlist
     (NOTIFIABLE_EVENT_TYPES: the market TOP10 rank transitions
     TOP10_ENTERED / TOP10_EXITED / RANK_CHANGED). A fact's severity
     is its operational importance, never a send decision: every
     other event type (faults, replay, session lifecycle included)
     is recorded in the ledgers and never pushed;
  3. suppress duplicates: an ACCEPTED (event_id, device_id) pair is
     never sent again; a FAILED pair is terminal (UNREGISTERED token,
     SENDER_ID_MISMATCH config error, unknown permanent codes);
  4. send one FCM HTTP v1 notification+data message per remaining pair;
  5. append one delivery record per outcome (PENDING on retryable
     failures, ACCEPTED / FAILED otherwise) — append-only, fsynced, so
     a crash between send and record replays the send on restart:
     the device may receive a duplicate push. That is FCM reality, not
     a bug, and the app identifies duplicates by event_id (README §6).
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

SIGTERM/SIGINT request a clean stop: the current tick finishes, the
single-writer locks are released and the process exits 0. All stdout
lines of the resident mode carry an ISO timestamp prefix.

Retry classes (vendor table, tools/notify/README.md §5):
  429 QUOTA_EXCEEDED / 500 INTERNAL / 503 UNAVAILABLE / transport
  failure -> stay PENDING, backoff >= max(retry_min_seconds, Retry-After):
  the one-shot sweep retries in-sweep while the wait is within
  backoff_cap_seconds and parks PENDING otherwise (external scheduler
  resumes); the resident watch defers the pair and keeps serving;
  404 UNREGISTERED (the REST wire spells it NOT_FOUND — google.rpc
  canonical name for 404; classify_send retires on either) -> FAILED,
  token retired in the registry, no retry;
  403 SENDER_ID_MISMATCH -> FAILED (config error, fail-closed, no
  retry), the sweep keeps serving the other devices and the process
  exits 3 — a config error is never a clean success;
  everything else -> FAILED with the provider's status kept verbatim.

Exit codes (README §9): 0 sweep completed / clean shutdown, 2
usage/config violation, 3 credential failure or fail-closed sender
mismatch, 4 single-writer conflict / internal fault / ledger contract
violation (watched file shrank).
"""

import json
import os
import signal
import sys
import time

import notify_config
import notify_fcm
import notify_ledger

# The delivery policy's event-type allowlist (README §0/§6): only the
# market TOP10 rank transitions are pushed. Severity is a fact field —
# operational importance — and never gates delivery. The set is
# notify_fcm's TOP10_EVENT_TYPES so the policy and the message
# assembly share one truth: a fourth notifiable type changes both
# together or neither.
NOTIFIABLE_EVENT_TYPES = notify_fcm.TOP10_EVENT_TYPES


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
        # SIGTERM/SIGINT set this between-ticks stop request.
        self._stop = False

    def close(self):
        for resource in (self.ledger, self.registry, self.delivery):
            try:
                resource.close()
            except notify_ledger.LedgerBusy:
                pass

    # ------------------------------------------------------ selection

    def _candidates(self, events, state, devices):
        """The worklist in deterministic order (ledger order, then
        sorted device id), after the policy filter and dedup. Counters
        record what the policy and the suppression removed."""
        notifyable = 0
        pairs = []
        for event in events:
            if event["event_type"] not in NOTIFIABLE_EVENT_TYPES:
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
        self.counts["events_total"] = len(events)
        self.counts["type_skipped"] = len(events) - notifyable
        self.counts["devices_active"] = len(devices)
        return pairs

    # ------------------------------------------------------- delivery

    def _record(self, event, device_id, state, attempts, error_code=None,
                provider_message_id=None):
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
        self.delivery.append(record)  # validates before it writes
        return record

    def _attempt(self, event, device_id, token, attempts, state):
        """One send + one honest record. The appended record becomes the
        pair's current state in `state` (append-only: the last record
        per pair IS the state). Returns (kind, next_wait)."""
        pair = (event["event_id"], device_id)
        try:
            message = notify_fcm.build_message(event, token)
        except notify_fcm.FcmError:
            # Refused before send (payload limit): a permanent scanner
            # refusal, recorded honestly (HS_ codes are synthetic).
            state[pair] = self._record(event, device_id, "FAILED",
                                       attempts + 1,
                                       error_code="HS_PAYLOAD_OVER_LIMIT")
            self.counts["failed_permanent"] = \
                self.counts.get("failed_permanent", 0) + 1
            self._log("dispatch result=permanent event=%s device=%s "
                      "attempts=%d status=- error=HS_PAYLOAD_OVER_LIMIT"
                      % (event["event_id"], device_id, attempts + 1))
            return "permanent", None

        if self._resident:
            # Post-observability: one timestamped line when the POST is
            # initiated, so start/answer times are measurable from the
            # log (the result line format below is unchanged).
            self._log("dispatch attempt_start event=%s device=%s "
                      "attempts=%d" % (event["event_id"], device_id,
                                       attempts + 1))
        outcome = notify_fcm.send_message(self.project_id,
                                          self.tokens.get(self._clock()),
                                          message, opener=self.opener)
        attempts += 1

        if outcome.kind == "accepted":
            state[pair] = self._record(
                event, device_id, "ACCEPTED", attempts,
                provider_message_id=outcome.provider_message_id)
            self.counts["accepted"] = self.counts.get("accepted", 0) + 1
            self._log("dispatch result=accepted event=%s device=%s "
                      "attempts=%d status=200 message=%s" %
                      (event["event_id"], device_id, attempts,
                       outcome.provider_message_id))
            return "accepted", None

        if outcome.kind == "unregistered":
            # The vendor's answer: remove this token from the server and
            # stop sending to it — the delivery is terminal FAILED and
            # the token is retired (hash only) in the registry.
            state[pair] = self._record(event, device_id, "FAILED",
                                       attempts,
                                       error_code=outcome.error_code)
            self.registry.mark_invalid(device_id, token)
            self.counts["token_retired"] = \
                self.counts.get("token_retired", 0) + 1
            self._log("dispatch result=unregistered event=%s device=%s "
                      "attempts=%d status=%d error=%s token=%s" %
                      (event["event_id"], device_id, attempts,
                       outcome.http_status, outcome.error_code,
                       notify_ledger.mask_secret(token)))
            return "unregistered", None

        if outcome.kind == "sender_mismatch":
            # Fail-closed: a configuration error (the authenticated
            # sender is not a sender of this token). No retry, an honest
            # FAILED record, and exit 3 — never a clean success.
            state[pair] = self._record(event, device_id, "FAILED",
                                       attempts,
                                       error_code=outcome.error_code)
            self.mismatch_seen = True
            self.counts["sender_mismatch"] = \
                self.counts.get("sender_mismatch", 0) + 1
            print("dispatcher: SENDER_ID_MISMATCH for device=%s "
                  "(token=%s): the configured sender cannot send to this "
                  "token; fix the project/sender configuration, no "
                  "retry (fail-closed)" %
                  (device_id, notify_ledger.mask_secret(token)),
                  file=sys.stderr)
            self._log("dispatch result=sender_mismatch event=%s "
                      "device=%s attempts=%d status=%d error=%s" %
                      (event["event_id"], device_id, attempts,
                       outcome.http_status, outcome.error_code))
            return "sender_mismatch", None

        if outcome.kind == "retry":
            state[pair] = self._record(event, device_id, "PENDING",
                                       attempts)
            self.counts["retried_pending"] = \
                self.counts.get("retried_pending", 0) + 1
            wait = max(self.retry_min, outcome.retry_after_seconds or 0)
            self._log("dispatch result=retry event=%s device=%s "
                      "attempts=%d status=%s error=%s wait=%ds" %
                      (event["event_id"], device_id, attempts,
                       outcome.http_status, outcome.error_code, wait))
            return "retry", wait

        # permanent: any other provider answer, kept verbatim.
        state[pair] = self._record(event, device_id, "FAILED", attempts,
                                   error_code=outcome.error_code)
        self.counts["failed_permanent"] = \
            self.counts.get("failed_permanent", 0) + 1
        self._log("dispatch result=permanent event=%s device=%s "
                  "attempts=%d status=%s error=%s" %
                  (event["event_id"], device_id, attempts,
                   outcome.http_status, outcome.error_code))
        return "permanent", None

    def _log(self, line):
        # The resident mode timestamps every stdout line (README §1);
        # the one-shot output is byte-identical to the old contract.
        prefix = notify_ledger.now_iso() + " " if self._resident else ""
        print(prefix + line, flush=True)

    # ---------------------------------------------------------- sweep

    def sweep_pass(self, pairs, state, token_by_device, next_due,
                   park_beyond_cap=True):
        """One pass over the worklist: send every pair whose retry is
        due at the current clock reading, in worklist order; returns
        the number of attempts made. A retryable outcome defers its
        pair: next_due = now + wait. With park_beyond_cap (the one-shot
        scheduler resume) a wait beyond backoff_cap_seconds parks the
        pair (next_due None, the record stays PENDING) instead; the
        resident worker passes False — it is its own resume, nothing
        is parked."""
        now = self._clock()
        sent = 0
        for event, device_id, _attempts in pairs:
            pair = (event["event_id"], device_id)
            due_at = next_due.get(pair)
            if due_at is None or due_at > now:
                continue
            record = state.get(pair)
            base = record["attempts"] if record else 0
            kind, wait = self._attempt(event, device_id,
                                       token_by_device[device_id],
                                       base, state)
            sent += 1
            if kind == "retry" and wait is not None and \
               (not park_beyond_cap or wait <= self.backoff_cap):
                next_due[pair] = self._clock() + wait
                continue
            if kind == "retry":
                # Beyond the cap (one-shot): parked for external resume.
                self.counts["pending_parked"] = \
                    self.counts.get("pending_parked", 0) + 1
            next_due[pair] = None
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
            self._log("watch tick new=%d ingested=%d appended=%d "
                      "dup=%d offset=%d"
                      % (stats["total"], stats["total"],
                         stats["appended"], stats["duplicate"],
                         new_offset))
            offset = new_offset
        self.dispatch_tick()
        return offset, ident

    def dispatch_tick(self):
        """One resident dispatch pass (README §5): re-read the small
        state files, extend the schedule with the pairs not seen
        before, and send what is due now. A retryable answer defers
        its pair (next_due = now + wait) — the wait is spent BETWEEN
        ticks, never in-sweep, so a 429 Retry-After wait never delays
        a new event; nothing is parked: the resident worker resumes
        its own pairs. Returns the number of attempts made."""
        state = self.delivery.read_state()
        events = self.ledger.events(strict=False)
        devices = self.registry.devices()
        pairs = self._candidates(events, state, devices)
        next_due = self._next_due
        for event, device_id, _attempts in pairs:
            pair = (event["event_id"], device_id)
            if pair not in next_due:
                next_due[pair] = 0.0
        sent = self.sweep_pass(pairs, state, dict(devices), next_due,
                               park_beyond_cap=False)
        self.counts["pairs_sent"] = self.counts.get("pairs_sent", 0) + sent
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
    args = parser.parse_args(argv)

    if args.watch and not os.path.isabs(args.watch):
        print("dispatcher: --watch needs an absolute path (got %r)"
              % args.watch, file=sys.stderr)
        return 2

    try:
        cfg = notify_config.load_config(args.config, "dispatch")
    except notify_config.ConfigError as exc:
        print("dispatcher: config refused: %s" % exc, file=sys.stderr)
        return 2

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
