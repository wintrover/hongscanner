#!/usr/bin/env bash
## Watch-worker process-pair drill: the REAL resident dispatcher
## (notify_dispatcher.py --watch) as one OS process tailing a producer
## events file, against the simulated FCM backend (drill_fcm.sh's
## fakesite — no network, no live FCM call, no real credential; the
## same HSDRILL=1 scope guard).
##
## Scenarios (the resident contract, tools/notify/README.md §1/§5/§9):
##   W1  incremental tail: a full LF line is picked up within N ticks
##       and sent; a HALF line (no LF) is never consumed — no send, the
##       ledger count unchanged — until its LF arrives, then it is
##       delivered; a 5-event burst in one write is delivered as ONE
##       digest message covering all five (one silent push per
##       observation group, README §0), and a mixed group (an entry,
##       an exit and two rank changes, same observed_at) as ONE
##       summary + ONE digest;
##   W2  SIGKILL the worker after ACCEPTED sends, restart it: the full
##       rescan is idempotent (no duplicate send, appended=0 dup=2) and
##       the restarted worker still tails NEW events;
##   W3  a 429 with Retry-After=3s defers its pair between ticks (no
##       in-sweep sleep): a NEW event appended right after the 429 is
##       sent promptly while the deferred pair waits, and the retry
##       still fires on schedule;
##   W4  a shrinking watched file (st_size < offset) is a LedgerFault:
##       the worker exits 4 — never a silent rescan.
##
## The systemd unit lifecycle (tools/run_session.sh) is deliberately
## NOT here: this drill pins the worker's own process contract; the
## launcher/systemd path is live-session evidence (README §12).
##
## Usage: bash tools/notify/drill/drill_watch.sh
## Evidence: runs/drill-watch-<ts>/ (gitignored): wire logs, worker
## stdout/stderr, delivery + event ledgers, masked registry
## projection. Credential VALUES are never copied there; the drill
## greps the whole evidence tree for them and fails if one leaks.
set -euo pipefail
cd "$(dirname "$0")/../../.."

PASS=0
FAIL=0
ok()  { echo "ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

check_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1: expected [$2] got [$3]"; fi
}
check_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else
    bad "$1: [$3] not found"; fi
}

# ---------------------------------------------------------- 1. interpreter
PY=""
if [ -n "${HSCOLLECTOR_PYTHON:-}" ]; then
  PY="$HSCOLLECTOR_PYTHON"
elif command -v python3.13 >/dev/null 2>&1; then
  PY="python3.13"
elif command -v uv >/dev/null 2>&1; then
  PY="$(uv python find 3.13)"
fi
if [ -z "$PY" ]; then
  echo "drill: no Python 3.13 interpreter found (tried" \
       "\$HSCOLLECTOR_PYTHON, python3.13, 'uv python find 3.13')" >&2
  exit 1
fi

FAKESITE="$PWD/tools/notify/drill/fakesite"
FAKEBIN="$PWD/tools/notify/drill/fakebin"
chmod +x "$FAKEBIN/fcm-token-cmd" 2>/dev/null || true

# The fake must shadow urlopen under HSDRILL=1 and be inert without it.
SHADOWED="$(HSDRILL=1 PYTHONPATH="$FAKESITE" PYTHONDONTWRITEBYTECODE=1 \
  "$PY" -c 'import urllib.request; print(urllib.request.urlopen.__name__)')"
case "$SHADOWED" in
  _drill_urlopen) ok "fake FCM backend shadows urlopen under HSDRILL=1" ;;
  *) echo "drill: fake backend not installed (got $SHADOWED)" >&2; exit 1 ;;
esac
INERT="$(env -u HSDRILL PYTHONPATH="$FAKESITE" PYTHONDONTWRITEBYTECODE=1 \
  "$PY" -c 'import urllib.request; print(urllib.request.urlopen.__module__)')"
case "$INERT" in
  urllib.request) ok "fakesite inert without HSDRILL (real urlopen)" ;;
  *) echo "drill: fakesite leaked without HSDRILL (urlopen from" \
     "$INERT)" >&2; exit 1 ;;
esac

OUT="runs/drill-watch-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "=== watch-worker drill (evidence: $OUT)"

NOTIFY="$PWD/tools/notify"
BEARER="DRILL-BEARER-SECRET"
WPID=0

drill_env() { # $1 = sandbox
  export HSDRILL=1
  export HSDRILL_WIRELOG="$1/wire.log"
  export HSDRILL_FCM_SCRIPT="$1/fcm_script.json"
  export HSDRILL_SEND_DELAY=0
  export PYTHONPATH="$FAKESITE"
  export PATH="$FAKEBIN:$PATH"
  export PYTHONDONTWRITEBYTECODE=1
}
clear_drill_env() {
  unset HSDRILL HSDRILL_WIRELOG HSDRILL_FCM_SCRIPT HSDRILL_SEND_DELAY \
        PYTHONPATH PYTHONDONTWRITEBYTECODE
  export PATH="${ORIG_PATH:-$PATH}"
}
ORIG_PATH="$PATH"

new_sandbox() { # $1 = scenario label
  mktemp -d "/tmp/hsnotify-watch-$1.XXXXXX"
}

write_config() { # $1 = sandbox, $2 = watch_poll_seconds
  cat > "$1/config.json" <<EOF
{
  "project_id": "drill-project",
  "ledger_path": "$1/ledger.hcj.jsonl",
  "delivery_path": "$1/delivery.hcj.jsonl",
  "registry_path": "$1/devices.jsonl",
  "register_bearer_file": "$1/bearer.secret",
  "retry_min_seconds": 1,
  "backoff_cap_seconds": 30,
  "watch_poll_seconds": $2,
  "token_command": ["fcm-token-cmd"]
}
EOF
}

seed_device() { # $1 = sandbox, $2 = device id, $3 = fake fcm token
  printf '%s\n' "$BEARER" > "$1/bearer.secret"
  printf '%s\n' "$3" > "$1/token-$2.txt"
  env -u HSDRILL -u PYTHONPATH "$PY" "$NOTIFY/notify_register.py" \
    --config "$1/config.json" --device-id "$2" \
    --token-file "$1/token-$2.txt" --bearer "$BEARER" \
    > "$1/register-$2.out"
}

fcm_script_ok() { # $1 = sandbox, $2 = response count (all 200)
  env -u HSDRILL -u PYTHONPATH "$PY" - "$1/fcm_script.json" "$2" <<'PYEOF'
import json, sys
out, n = sys.argv[1], int(sys.argv[2])
resp = [{"status": 200, "name": "projects/drill-project/messages/m-%d" % i}
        for i in range(n)]
doc = {"project_id": "drill-project",
       "oauth_token": "DRILL-FAKE-OAUTH-TOKEN",
       "devices": {"dev-1": "FAKE-FCM-TOKEN-DEV1"},
       "responses": {"dev-1": resp}}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=1)
PYEOF
}

fcm_script_defer() { # $1 = sandbox: 429(3s) then 200, 200
  env -u HSDRILL -u PYTHONPATH "$PY" - "$1/fcm_script.json" <<'PYEOF'
import json, sys
doc = {"project_id": "drill-project",
       "oauth_token": "DRILL-FAKE-OAUTH-TOKEN",
       "devices": {"dev-1": "FAKE-FCM-TOKEN-DEV1"},
       "responses": {"dev-1": [
           {"status": 429, "retry_after": 3, "error_status": "QUOTA_EXCEEDED"},
           {"status": 200, "name": "projects/drill-project/messages/m-new"},
           {"status": 200, "name": "projects/drill-project/messages/m-retry"}]}}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=1)
PYEOF
}

append_events() { # $1 = sandbox, $2 = first seq, $3 = count
  env -u HSDRILL -u PYTHONPATH "$PY" - "$1/events-src.jsonl" "$2" "$3" \
    "$FAKESITE" <<'PYEOF'
import json, sys
path, first, count, fixtures = sys.argv[1:5]
sys.path.insert(0, fixtures)
import fcm_fixtures as fx
with open(path, "a", encoding="utf-8") as f:
    for seq in range(int(first), int(first) + int(count)):
        ev = fx.make_event(seq=seq)
        f.write(json.dumps(ev, ensure_ascii=False,
                           separators=(",", ":")) + "\n")
PYEOF
}

append_events_spec() { # $1 = sandbox, $2 = JSON array of make_event kwargs
  env -u HSDRILL -u PYTHONPATH "$PY" - "$1/events-src.jsonl" "$2" \
    "$FAKESITE" <<'PYEOF'
import json, sys
path, spec, fixtures = sys.argv[1:4]
sys.path.insert(0, fixtures)
import fcm_fixtures as fx
with open(path, "a", encoding="utf-8") as f:
    for kwargs in json.loads(spec):
        ev = fx.make_event(**kwargs)
        f.write(json.dumps(ev, ensure_ascii=False,
                           separators=(",", ":")) + "\n")
PYEOF
}

half_event() { # $1 = sandbox, $2 = seq, $3 = half|rest
  env -u HSDRILL -u PYTHONPATH "$PY" - "$1/events-src.jsonl" "$2" "$3" \
    "$FAKESITE" <<'PYEOF'
import json, sys
path, seq, mode, fixtures = sys.argv[1:5]
sys.path.insert(0, fixtures)
import fcm_fixtures as fx
ev = fx.make_event(seq=int(seq))
line = (json.dumps(ev, ensure_ascii=False,
                   separators=(",", ":")) + "\n").encode("utf-8")
half = len(line) // 2
with open(path, "ab") as f:
    f.write(line[:half] if mode == "half" else line[half:])
PYEOF
}

start_worker() { # $1 = sandbox, $2 = tag -> $WPID (child of this shell)
  drill_env "$1"
  "$PY" "$NOTIFY/notify_dispatcher.py" --config "$1/config.json" \
    --watch "$1/events-src.jsonl" \
    > "$1/worker-$2.out" 2> "$1/worker-$2.err" &
  WPID=$!
}

count_sends() { # $1 = wirelog -> send count (0 when absent)
  local n
  n="$(grep -c " SEND " "$1" 2>/dev/null)"
  echo "${n:-0}"
}

count_lines() { # $1 = file -> line count (0 when absent)
  local n
  n="$(grep -c . "$1" 2>/dev/null)"
  echo "${n:-0}"
}

wait_sends() { # $1 = wirelog, $2 = expected count, $3 = seconds
  for _ in $(seq 1 $(( $3 * 5 ))); do
    if [ "$(count_sends "$1")" -ge "$2" ]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

wait_worker_dead() { # $1 = pid, $2 = seconds
  for _ in $(seq 1 $(( $2 * 5 ))); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}

stop_worker() { # $1 = tag -> WORKER_RC (SIGTERM, clean exit expected)
  WORKER_RC=0
  kill -TERM "$WPID" 2>/dev/null || WORKER_RC=255
  if [ "$WORKER_RC" -ne 255 ]; then
    if ! wait_worker_dead "$WPID" 10; then
      kill -9 "$WPID" 2>/dev/null || true
      bad "worker $1 did not stop within 10s (SIGKILLed)"
    fi
    wait "$WPID" 2>/dev/null || WORKER_RC=$?
  fi
  clear_drill_env
}

masked_projection() { # $1 = sandbox
  env -u HSDRILL -u PYTHONPATH "$PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import fcm_fixtures as fx
print("\n".join(fx.registry_projection(sys.argv[2])))' \
    "$FAKESITE" "$1/devices.jsonl" > "$1/registry.masked.jsonl" || true
}

collect_evidence() { # $1 = sandbox, $2 = scenario label
  local dir="$OUT/$2"
  mkdir -p "$dir"
  for f in wire.log worker-*.out worker-*.err delivery.hcj.jsonl \
           ledger.hcj.jsonl registry.masked.jsonl; do
    for src in "$1"/$f; do
      [ -f "$src" ] && cp "$src" "$dir/" || true
    done
  done
  cp "$1/config.json" "$dir/config.json"
  if grep -rqE "DRILL-FAKE-OAUTH-TOKEN|FAKE-FCM-TOKEN|DRILL-BEARER-SECRET" \
       "$OUT"; then
    bad "evidence leak: a credential value reached $OUT"
  else
    ok "evidence carries no credential value (token/bearer/oauth)"
  fi
}

# ------------------------------------------------------------------ W1
echo "--- scenario W1: incremental tail, half line, burst"
SB="$(new_sandbox w1)"
write_config "$SB" 0.2
: > "$SB/events-src.jsonl"
seed_device "$SB" "dev-1" "FAKE-FCM-TOKEN-DEV1"
fcm_script_ok "$SB" 10

start_worker "$SB" w1
append_events "$SB" 1 1
if wait_sends "$SB/wire.log" 1 15; then
  ok "W1 full line delivered within N ticks"
else
  bad "W1 full line was not delivered in 15s"
fi
check_eq "W1 exactly one send after one line" 1 \
  "$(count_sends "$SB/wire.log")"

half_event "$SB" 2 half
sleep 1.2
check_eq "W1 half line (no LF) never consumed" 1 \
  "$(count_sends "$SB/wire.log")"
check_eq "W1 ledger count unchanged by the half line" 1 \
  "$(count_lines "$SB/ledger.hcj.jsonl")"

half_event "$SB" 2 rest
if wait_sends "$SB/wire.log" 2 15; then
  ok "W1 completed line delivered after its LF arrived"
else
  bad "W1 completed line was not delivered in 15s"
fi
check_eq "W1 ledger count follows the completed line" 2 \
  "$(count_lines "$SB/ledger.hcj.jsonl")"

append_events_spec "$SB" '[
  {"seq": 10, "event_type": "RANK_CHANGED", "rule_id": "rank-changed",
   "previous_rank": 15, "rank": 10},
  {"seq": 11, "event_type": "RANK_CHANGED", "rule_id": "rank-changed",
   "previous_rank": 14, "rank": 9},
  {"seq": 12, "event_type": "RANK_CHANGED", "rule_id": "rank-changed",
   "previous_rank": 13, "rank": 8},
  {"seq": 13, "event_type": "RANK_CHANGED", "rule_id": "rank-changed",
   "previous_rank": 12, "rank": 7},
  {"seq": 14, "event_type": "RANK_CHANGED", "rule_id": "rank-changed",
   "previous_rank": 11, "rank": 6}
]'
if wait_sends "$SB/wire.log" 3 15; then
  ok "W1 five-event burst delivered as one digest message"
else
  bad "W1 burst was not delivered in 15s"
fi
check_eq "W1 burst is ONE message (3 sends so far)" 3 \
  "$(count_sends "$SB/wire.log")"
check_contains "W1 the burst wirelog line covers all five" \
  "$(cat "$SB/wire.log")" "SEND digest count=5 first="
check_eq "W1 ledger holds all 7 events" 7 \
  "$(count_lines "$SB/ledger.hcj.jsonl")"

append_events_spec "$SB" '[
  {"seq": 20, "name": "삼성전자"},
  {"seq": 21, "event_type": "TOP10_EXITED", "rule_id": "top10-exited",
   "previous_rank": 9, "rank": null, "direction": "DOWN",
   "name": "SK하이닉스"},
  {"seq": 22, "event_type": "RANK_CHANGED", "rule_id": "rank-changed",
   "previous_rank": 12, "rank": 2},
  {"seq": 23, "event_type": "RANK_CHANGED", "rule_id": "rank-changed",
   "previous_rank": 11, "rank": 1}
]'
if wait_sends "$SB/wire.log" 5 15; then
  ok "W1 a mixed observation group is one summary + one digest"
else
  bad "W1 mixed group was not delivered in 15s"
fi
check_contains "W1 the immediate pair is one summary" \
  "$(cat "$SB/wire.log")" "SEND summary count=2 first="
check_contains "W1 the rank pair is one digest" \
  "$(cat "$SB/wire.log")" "SEND digest count=2 first="
check_eq "W1 five messages total for 11 events" 5 \
  "$(count_sends "$SB/wire.log")"
check_eq "W1 ledger holds all 11 events" 11 \
  "$(count_lines "$SB/ledger.hcj.jsonl")"

"$PY" - "$SB" "$FAKESITE" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[2])
import fcm_fixtures as fx
records = fx.delivery_summary(sys.argv[1] + "/delivery.hcj.jsonl")
fails = []
def ck(name, cond):
    print(("ok   " if cond else "FAIL ") + "W1 " + name)
    if not cond:
        fails.append(name)
kinds = {}
by_mid = {}
for r in records:
    kinds[r.get("message_kind")] = kinds.get(r.get("message_kind"), 0) + 1
    by_mid.setdefault(r["provider_message_id"], []).append(r)
ck("eleven delivery records cover the eleven events once each",
   len(records) == 11)
ck("kinds split single 2 / summary 2 / digest 7",
   kinds == {"single": 2, "summary": 2, "digest": 7})
ck("every record is ACCEPTED",
   all(r["state"] == "ACCEPTED" for r in records))
ck("five messages: group sizes 1,1,2,2,5",
   sorted(len(v) for v in by_mid.values()) == [1, 1, 2, 2, 5])
ck("members of one message share its provider id",
   all(len({r["provider_message_id"] for r in v}) == 1
       for v in by_mid.values()))
sys.exit(1 if fails else 0)
PYEOF
check_eq "W1 group delivery records contract" 0 $?

stop_worker w1
check_eq "W1 SIGTERM is a clean exit 0" 0 "$WORKER_RC"
masked_projection "$SB"
collect_evidence "$SB" w1

# ------------------------------------------------------------------ W2
echo "--- scenario W2: SIGKILL, restart, idempotent rescan"
SB="$(new_sandbox w2)"
write_config "$SB" 0.2
: > "$SB/events-src.jsonl"
seed_device "$SB" "dev-1" "FAKE-FCM-TOKEN-DEV1"
fcm_script_ok "$SB" 5

start_worker "$SB" w2
append_events "$SB" 1 2
if wait_sends "$SB/wire.log" 1 15; then
  ok "W2 two same-batch events delivered as one summary before the kill"
else
  bad "W2 events were not delivered in 15s"
fi

kill -9 "$WPID" 2>/dev/null || true
KRC=0; wait "$WPID" 2>/dev/null || KRC=$?
check_eq "W2 worker was SIGKILLed" 137 "$KRC"

start_worker "$SB" w2b
sleep 1.5   # a full rescan at 0.2s poll is several ticks by now
check_eq "W2 restart resends nothing (ACCEPTED dedup)" 1 \
  "$(count_sends "$SB/wire.log")"
check_contains "W2 restart rescan is idempotent (appended=0 dup=2)" \
  "$(cat "$SB/worker-w2b.out")" "appended=0 dup=2"
check_eq "W2 ledger unchanged by the rescan" 2 \
  "$(count_lines "$SB/ledger.hcj.jsonl")"

append_events "$SB" 100 1
if wait_sends "$SB/wire.log" 2 15; then
  ok "W2 restarted worker still tails new events"
else
  bad "W2 restarted worker did not pick up the new event"
fi
check_eq "W2 one new send only (2 total)" 2 \
  "$(count_sends "$SB/wire.log")"

stop_worker w2b
check_eq "W2 second worker SIGTERM exit 0" 0 "$WORKER_RC"
masked_projection "$SB"
collect_evidence "$SB" w2

# ------------------------------------------------------------------ W3
echo "--- scenario W3: 429 deferral is non-blocking for new events"
SB="$(new_sandbox w3)"
write_config "$SB" 0.2
: > "$SB/events-src.jsonl"
seed_device "$SB" "dev-1" "FAKE-FCM-TOKEN-DEV1"
fcm_script_defer "$SB"

start_worker "$SB" w3
append_events "$SB" 1 1   # event X: first send -> 429 (Retry-After 3s)
if wait_sends "$SB/wire.log" 1 15; then
  ok "W3 deferred pair sent (got the 429)"
else
  bad "W3 first send did not happen in 15s"
fi
append_events "$SB" 100 1  # event Y: must NOT wait for X's backoff
if wait_sends "$SB/wire.log" 2 15 && wait_sends "$SB/wire.log" 3 15; then
  ok "W3 new event and the deferred retry both completed"
else
  bad "W3 sends did not complete in 15s"
fi

"$PY" - "$SB" "$FAKESITE" <<'PYEOF'
import sys
from datetime import datetime
sb = sys.argv[1]
sys.path.insert(0, sys.argv[2])
import fcm_fixtures as fx
sends = []
for line in open(sb + "/wire.log"):
    if " SEND " not in line:
        continue
    ts, rest = line.split(" ", 1)
    parts = rest.split(" ")          # SEND <event16> <device> <hash>
    sends.append((datetime.fromisoformat(ts), parts[1]))
fails = []
def ck(name, cond):
    print(("ok   " if cond else "FAIL ") + "W3 " + name)
    if not cond: fails.append(name)
if len(sends) == 3:
    t1, t2, t3 = sends[0][0], sends[1][0], sends[2][0]
    ck("the new event was sent while the 429 pair waited (<1.5s)",
       (t2 - t1).total_seconds() < 1.5)
    ck("the deferred retry honored its wait (>=2.0s)",
       (t3 - t1).total_seconds() >= 2.0)
    ck("the retry fired after the new event",
       (t3 - t2).total_seconds() > 0)
else:
    ck("exactly three sends (429, new, retry)", len(sends) == 3)
records = fx.delivery_summary(sb + "/delivery.hcj.jsonl")
by_event = {}
for r in records:
    by_event.setdefault(r["event_id"], []).append(r)
two_state_events = [v for v in by_event.values() if len(v) == 2]
if len(two_state_events) == 1:
    pair = two_state_events[0]
    ck("deferred pair: PENDING then ACCEPTED",
       [r["state"] for r in pair] == ["PENDING", "ACCEPTED"])
    ck("deferred pair attempts 1 then 2",
       [r["attempts"] for r in pair] == [1, 2])
else:
    ck("one two-record pair exists", False)
ck("the new event has exactly one ACCEPTED record",
   any(len(v) == 1 and v[0]["state"] == "ACCEPTED"
       for v in by_event.values()))
sys.exit(1 if fails else 0)
PYEOF
check_eq "W3 deferral timing and records contract" 0 $?

stop_worker w3
check_eq "W3 worker SIGTERM exit 0" 0 "$WORKER_RC"
masked_projection "$SB"
collect_evidence "$SB" w3

# ------------------------------------------------------------------ W4
echo "--- scenario W4: a shrinking watched file fails closed"
SB="$(new_sandbox w4)"
write_config "$SB" 0.2
: > "$SB/events-src.jsonl"
seed_device "$SB" "dev-1" "FAKE-FCM-TOKEN-DEV1"
fcm_script_ok "$SB" 5

start_worker "$SB" w4
append_events "$SB" 1 2
if wait_sends "$SB/wire.log" 1 15; then
  ok "W4 two same-batch events delivered as one summary before the shrink"
else
  bad "W4 events were not delivered in 15s"
fi

: > "$SB/events-src.jsonl"   # st_size=0 < offset: append-only violation
if wait_worker_dead "$WPID" 15; then
  ok "W4 the worker exited on the shrink"
else
  bad "W4 worker kept running after the shrink"
  kill -9 "$WPID" 2>/dev/null || true
fi
WORKER_RC=0; wait "$WPID" 2>/dev/null || WORKER_RC=$?
clear_drill_env
check_eq "W4 shrink exit code is 4 (LedgerFault)" 4 "$WORKER_RC"
check_contains "W4 the fault names the shrink" \
  "$(cat "$SB/worker-w4.err")" "shrank"
check_eq "W4 nothing was resent by the failure" 1 \
  "$(count_sends "$SB/wire.log")"
collect_evidence "$SB" w4

# ---------------------------------------------------------------- end
clear_drill_env
echo "=== watch-worker drill: $PASS passed, $FAIL failed"
echo "=== evidence: $OUT (credential values must be absent)"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "WATCH DRILL PASSED"
