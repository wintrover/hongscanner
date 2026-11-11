#!/usr/bin/env bash
## Fake-FCM process-pair drill: the REAL notify CLIs (notify_ledger.py,
## notify_register.py, notify_dispatcher.py) as separate OS processes
## against a simulated FCM backend — no network, no live FCM call, no
## real credential (tools/notify/README.md §10).
##
## Fakes (tools/notify/drill/fakesite/ + fakebin/):
##   - sitecustomize.py = the FCM backend, patched into
##     urllib.request.urlopen ONLY while HSDRILL=1 (stdlib urllib cannot
##     be shadowed via PYTHONPATH; inert everywhere else). It enforces
##     the official endpoint shape, scripts per-device responses
##     (200 / 429+Retry-After / 404 NOT_FOUND+UNREGISTERED / 403
##     SENDER_ID_MISMATCH), and logs token HASHES only;
##   - fakebin/fcm-token-cmd = the platform-delegation token command
##     (the collector's fake kiwoomcli precedent);
##   - a seeded bearer secret + token files live in a mktemp sandbox
##     OUTSIDE the repository (the config loader refuses credential
##     paths under the repo root — scenario D asserts that guard live).
##
## Scenarios:
##   A  normal delivery: ingest (byte-verbatim) -> register (bearer) ->
##      dispatch (PENDING->ACCEPTED records) -> second dispatch with
##      zero resends (ACCEPTED dedup) -> ledger bytes never changed;
##   B  SIGKILL the dispatcher inside the provider-accepted-but-
##      unrecorded window -> restart -> the PENDING fact is re-sent
##      (the device may have received the push twice — that is FCM
##      reality, honestly recorded, and the app dedups by event_id);
##   C  per-device error table: 429 with Retry-After honored in-sweep
##      (>=1s gap), 404 retires the token under BOTH wire spellings —
##      NOT_FOUND (the measured 2026-11-03 REST wire form for an
##      invalid token: google.rpc canonical code name for HTTP 404)
##      and UNREGISTERED (the Admin-SDK error table's name) — one
##      device each, registry token_invalid, no further sends; 403
##      SENDER_ID_MISMATCH
##      fails closed (FAILED record, other devices still served, exit
##      3 — a config error is never a clean success); a rerun sends
##      nothing (terminal states stay terminal);
##   D  credential guards: a registry path inside the repository is
##      refused (exit 2); a wrong bearer registers nothing.
##
## Wall-clock constraint: none (no watchdog in the notify tools; waits
## are the scripted Retry-After and the kill-window delay only).
##
## Usage: bash tools/notify/drill/drill_fcm.sh
## Evidence: runs/drill-fcm-<ts>/ (gitignored): wire logs, dispatcher
## stdout/stderr, delivery + event ledgers, masked registry projection.
## Credential VALUES are never copied there; the drill greps the whole
## evidence tree for them and fails if one leaks.
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
check_not_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    bad "$1: [$3] must be absent"; else ok "$1"; fi
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

OUT="runs/drill-fcm-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "=== fake-FCM drill (evidence: $OUT)"

NOTIFY="$PWD/tools/notify"
BEARER="DRILL-BEARER-SECRET"

drill_env() { # $1 = script dir, $2 = send delay
  export HSDRILL=1
  export HSDRILL_WIRELOG="$1/wire.log"
  export HSDRILL_FCM_SCRIPT="$1/fcm_script.json"
  export HSDRILL_SEND_DELAY="$2"
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
# No bytecode anywhere: the drill (and its fixture helpers) must not
# leave __pycache__ trees in the repository.
export PYTHONDONTWRITEBYTECODE=1

new_sandbox() { # -> echoes the sandbox path; $1 = scenario letter
  local sb
  sb="$(mktemp -d "/tmp/hsnotify-drill-$1.XXXXXX")"
  printf '%s\n' "$sb"
}

write_config() { # $1 = sandbox, $2 = registry path (D: inside the repo)
  cat > "$1/config.json" <<EOF
{
  "project_id": "drill-project",
  "ledger_path": "$1/ledger.hcj.jsonl",
  "delivery_path": "$1/delivery.hcj.jsonl",
  "registry_path": "$2",
  "register_bearer_file": "$1/bearer.secret",
  "retry_min_seconds": 1,
  "backoff_cap_seconds": 30,
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

ingest_source() { # $1 = sandbox, $2 = events source
  env -u HSDRILL -u PYTHONPATH "$PY" "$NOTIFY/notify_ledger.py" \
    ingest --config "$1/config.json" --source "$2" > "$1/ingest.out"
}

run_dispatcher() { # $1 = sandbox, $2 = send delay; -> exit code
  local rc=0
  drill_env "$1" "$2"
  "$PY" "$NOTIFY/notify_dispatcher.py" --config "$1/config.json" \
    > "$1/dispatch.out" 2> "$1/dispatch.err" || rc=$?
  clear_drill_env
  return "$rc"
}

fcm_script() { # $1 = sandbox, $2 = devices json, $3 = responses json
  "$PY" - "$1/fcm_script.json" "$2" "$3" <<'PYEOF'
import json, sys
out, devices_path, responses_path = sys.argv[1:4]
devices = json.load(open(devices_path))
responses = json.load(open(responses_path))
doc = {"project_id": "drill-project",
       "oauth_token": "DRILL-FAKE-OAUTH-TOKEN",
       "devices": devices, "responses": responses}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=1)
PYEOF
}

masked_projection() { # $1 = sandbox -> masked registry lines
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
  for f in wire.log dispatch.out dispatch-1.out dispatch.err \
           dispatch-1.err delivery.hcj.jsonl ledger.hcj.jsonl \
           registry.masked.jsonl ingest.out; do
    [ -f "$1/$f" ] && cp "$1/$f" "$dir/" || true
  done
  cp "$1/config.json" "$dir/config.json"
  local rc=0
  if grep -rqE "DRILL-FAKE-OAUTH-TOKEN|FAKE-FCM-TOKEN|DRILL-BEARER-SECRET" \
       "$OUT"; then
    bad "evidence leak: a credential value reached $OUT"; rc=1
  else
    ok "evidence carries no credential value (token/bearer/oauth)"
  fi
  return "$rc"
}

wirelog_sends() { # $1 = wirelog, $2 = device -> SEND count
  grep -c "SEND [0-9a-f]* $2 " "$1" 2>/dev/null || true
}

# ------------------------------------------------------------------ A
echo "--- scenario A: normal delivery + ACCEPTED dedup"
SB_A="$(new_sandbox a)"
write_config "$SB_A" "$SB_A/devices.jsonl"
SRC_A="$SB_A/events-src.jsonl"
env -u HSDRILL -u PYTHONPATH "$PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import fcm_fixtures as fx
fx.write_source(sys.argv[2], fx.events_source())' \
  "$FAKESITE" "$SRC_A"
seed_device "$SB_A" "dev-1" "FAKE-FCM-TOKEN-DEV1"
ingest_source "$SB_A" "$SRC_A"
check_contains "A ingest appended 2 facts" \
  "$(cat "$SB_A/ingest.out")" "appended=2 duplicate=0 total=2"
LEDGER_SHA_BEFORE="$(sha256sum "$SB_A/ledger.hcj.jsonl" | cut -d" " -f1)"
fcm_script "$SB_A" \
  <(echo '{"dev-1": "FAKE-FCM-TOKEN-DEV1"}') \
  <(echo '{"dev-1": [{"status": 200, "name": "projects/drill-project/messages/m-a1"}]}')
RC_A=0; run_dispatcher "$SB_A" 0 || RC_A=$?
check_eq "A first dispatch exit 0" 0 "$RC_A"
check_eq "A wirelog has exactly 2 sends" 2 \
  "$(grep -c " SEND " "$SB_A/wire.log")"
check_not_contains "A no anomalies on the wire" \
  "$(cat "$SB_A/wire.log")" "ANOMALY"

"$PY" - "$SB_A" <<'PYEOF'
import json, sys
sb = sys.argv[1]
records = [json.loads(l) for l in open(sb + "/delivery.hcj.jsonl")]
fails = []
def ck(name, cond):
    print(("ok   " if cond else "FAIL ") + "A " + name)
    if not cond: fails.append(name)
ck("two delivery records", len(records) == 2)
ck("all ACCEPTED with provider_message_id",
   all(r["state"] == "ACCEPTED" and r.get("provider_message_id")
       for r in records))
ck("all attempts=1 (one recorded send each)",
   all(r["attempts"] == 1 for r in records))
ck("no error_code anywhere",
   all("error_code" not in r for r in records))
ck("no PENDING left",
   not any(r["state"] == "PENDING" for r in records))
ck("accepted != delivered: no arrival claims",
   not any("delivered" in json.dumps(r) for r in records))
ck("delivery covers both event ids",
   len({r["event_id"] for r in records}) == 2)
sys.exit(1 if fails else 0)
PYEOF
check_eq "A delivery records contract" 0 $?

# The dedup: a second dispatch must not resend anything.
RC_A2=0; run_dispatcher "$SB_A" 0 || RC_A2=$?
check_eq "A second dispatch exit 0" 0 "$RC_A2"
check_eq "A dedup: still exactly 2 sends" 2 \
  "$(grep -c " SEND " "$SB_A/wire.log")"
check_contains "A dedup counted" \
  "$(cat "$SB_A/dispatch.out")" '"dedup_suppressed":2'
LEDGER_SHA_AFTER="$(sha256sum "$SB_A/ledger.hcj.jsonl" | cut -d" " -f1)"
check_eq "A ledger bytes unchanged by dispatching" \
  "$LEDGER_SHA_BEFORE" "$LEDGER_SHA_AFTER"
masked_projection "$SB_A"
collect_evidence "$SB_A" a || true

# ------------------------------------------------------------------ B
echo "--- scenario B: SIGKILL mid-send, restart recovery"
SB_B="$(new_sandbox b)"
write_config "$SB_B" "$SB_B/devices.jsonl"
SRC_B="$SB_B/events-src.jsonl"
env -u HSDRILL -u PYTHONPATH "$PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import fcm_fixtures as fx
fx.write_source(sys.argv[2], fx.single_event())' \
  "$FAKESITE" "$SRC_B"
seed_device "$SB_B" "dev-1" "FAKE-FCM-TOKEN-DEV1"
ingest_source "$SB_B" "$SRC_B"
fcm_script "$SB_B" \
  <(echo '{"dev-1": "FAKE-FCM-TOKEN-DEV1"}') \
  <(echo '{"dev-1": [{"status": 200, "name": "projects/drill-project/messages/m-b1"}]}')

drill_env "$SB_B" 2.0   # the fake answers 2s after the SEND marker
"$PY" "$NOTIFY/notify_dispatcher.py" --config "$SB_B/config.json" \
  > "$SB_B/dispatch.out" 2> "$SB_B/dispatch.err" &
DPID=$!
KILLED=0
for _ in $(seq 1 100); do
  if grep -q " SEND " "$SB_B/wire.log" 2>/dev/null; then
    kill -9 "$DPID" 2>/dev/null || true
    KILLED=1
    break
  fi
  sleep 0.2
done
clear_drill_env
wait "$DPID" 2>/dev/null || true
check_eq "B dispatcher was killed inside the send window" 1 "$KILLED"
check_eq "B wirelog recorded the send before the kill" 1 \
  "$(wirelog_sends "$SB_B/wire.log" dev-1)"
check_eq "B no delivery record exists yet (crash before the record)" 0 \
  "$(grep -c . "$SB_B/delivery.hcj.jsonl" 2>/dev/null || true)"

# Restart: the ledger still names the fact, the delivery ledger has no
# record -> the pair is re-sent (possible duplicate at the device —
# honest FCM reality; the app dedups by event_id).
RC_B=0; run_dispatcher "$SB_B" 0 || RC_B=$?
check_eq "B restart dispatch exit 0" 0 "$RC_B"
check_eq "B the fact was re-sent after the crash" 2 \
  "$(wirelog_sends "$SB_B/wire.log" dev-1)"
"$PY" - "$SB_B" <<'PYEOF'
import json, sys
sb = sys.argv[1]
records = [json.loads(l) for l in open(sb + "/delivery.hcj.jsonl")]
fails = []
def ck(name, cond):
    print(("ok   " if cond else "FAIL ") + "B " + name)
    if not cond: fails.append(name)
ck("exactly one delivery record after recovery", len(records) == 1)
ck("final state ACCEPTED",
   records and records[0]["state"] == "ACCEPTED")
ck("attempts counts recorded sends (1)",
   records and records[0]["attempts"] == 1)
sys.exit(1 if fails else 0)
PYEOF
check_eq "B recovery record contract" 0 $?
masked_projection "$SB_B"
collect_evidence "$SB_B" b || true

# ------------------------------------------------------------------ C
echo "--- scenario C: 429 backoff / 404 retire / 403 fail-closed"
SB_C="$(new_sandbox c)"
write_config "$SB_C" "$SB_C/devices.jsonl"
SRC_C="$SB_C/events-src.jsonl"
env -u HSDRILL -u PYTHONPATH "$PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import fcm_fixtures as fx
fx.write_source(sys.argv[2], fx.single_event())' \
  "$FAKESITE" "$SRC_C"
ingest_source "$SB_C" "$SRC_C"
seed_device "$SB_C" "dev-ok"  "FAKE-FCM-TOKEN-OK"
seed_device "$SB_C" "dev-429" "FAKE-FCM-TOKEN-429"
seed_device "$SB_C" "dev-404" "FAKE-FCM-TOKEN-404"
seed_device "$SB_C" "dev-404u" "FAKE-FCM-TOKEN-404U"
seed_device "$SB_C" "dev-403" "FAKE-FCM-TOKEN-403"
fcm_script "$SB_C" \
  <(echo '{"dev-ok": "FAKE-FCM-TOKEN-OK", "dev-429": "FAKE-FCM-TOKEN-429", "dev-404": "FAKE-FCM-TOKEN-404", "dev-404u": "FAKE-FCM-TOKEN-404U", "dev-403": "FAKE-FCM-TOKEN-403"}') \
  <(echo '{"dev-ok": [{"status": 200, "name": "projects/drill-project/messages/m-ok"}],
           "dev-429": [{"status": 429, "retry_after": 1, "error_status": "QUOTA_EXCEEDED"},
                       {"status": 200, "name": "projects/drill-project/messages/m-429"}],
           "dev-404": [{"status": 404, "error_status": "NOT_FOUND"}],
           "dev-404u": [{"status": 404, "error_status": "UNREGISTERED"}],
           "dev-403": [{"status": 403, "error_status": "SENDER_ID_MISMATCH"}]}')

RC_C=0; run_dispatcher "$SB_C" 0 || RC_C=$?
check_eq "C sender mismatch keeps exit 3 (never a clean success)" 3 "$RC_C"
check_contains "C fail-closed error names the mismatch" \
  "$(cat "$SB_C/dispatch.err")" "SENDER_ID_MISMATCH"
check_eq "C dev-429 sent twice (backoff retry)" 2 \
  "$(wirelog_sends "$SB_C/wire.log" dev-429)"

"$PY" - "$SB_C" <<'PYEOF'
import json, sys
from datetime import datetime
sb = sys.argv[1]
records = [json.loads(l) for l in open(sb + "/delivery.hcj.jsonl")]
by_dev = {}
for r in records:
    by_dev.setdefault(r["device_id"], []).append(r)
sends = {}
for line in open(sb + "/wire.log"):
    if " SEND " not in line:
        continue
    ts, rest = line.split(" ", 1)
    parts = rest.split(" ")          # SEND <event16> <device> <hash>
    sends.setdefault(parts[2], []).append(ts)
fails = []
def ck(name, cond):
    print(("ok   " if cond else "FAIL ") + "C " + name)
    if not cond: fails.append(name)

dev_ok = by_dev.get("dev-ok", [])
ck("dev-ok ACCEPTED once",
   len(dev_ok) == 1 and dev_ok[0]["state"] == "ACCEPTED")
dev_429 = by_dev.get("dev-429", [])
ck("dev-429 PENDING then ACCEPTED",
   [r["state"] for r in dev_429] == ["PENDING", "ACCEPTED"])
ck("dev-429 attempts 1 then 2",
   [r["attempts"] for r in dev_429] == [1, 2])
ck("dev-429 records carry no error_code while PENDING",
   "error_code" not in dev_429[0])
if len(sends.get("dev-429", [])) == 2:
    a = datetime.fromisoformat(sends["dev-429"][0])
    b = datetime.fromisoformat(sends["dev-429"][1])
    ck("dev-429 retry honored Retry-After (>=1s gap)",
       (b - a).total_seconds() >= 1.0)
else:
    ck("dev-429 has two send markers", False)
dev_404 = by_dev.get("dev-404", [])
ck("dev-404 FAILED NOT_FOUND (the measured wire form)",
   len(dev_404) == 1 and dev_404[0]["state"] == "FAILED" and
   dev_404[0]["error_code"] == "NOT_FOUND")
dev_404u = by_dev.get("dev-404u", [])
ck("dev-404u FAILED UNREGISTERED (the error-table form)",
   len(dev_404u) == 1 and dev_404u[0]["state"] == "FAILED" and
   dev_404u[0]["error_code"] == "UNREGISTERED")
dev_403 = by_dev.get("dev-403", [])
ck("dev-403 FAILED SENDER_ID_MISMATCH",
   len(dev_403) == 1 and dev_403[0]["state"] == "FAILED" and
   dev_403[0]["error_code"] == "SENDER_ID_MISMATCH")
ck("all five devices served (403 did not block the sweep)",
   set(by_dev) == {"dev-ok", "dev-429", "dev-404", "dev-404u",
                   "dev-403"})
sys.exit(1 if fails else 0)
PYEOF
check_eq "C per-device outcome contract" 0 $?
masked_projection "$SB_C"
check_contains "C registry retired the 404 tokens (hash only)" \
  "$(cat "$SB_C/registry.masked.jsonl")" "token_invalid"
check_eq "C registry retired BOTH 404 code names (NOT_FOUND + UNREGISTERED)" 2 \
  "$(grep -c "token_invalid" "$SB_C/registry.masked.jsonl")"
check_not_contains "C registry projection has no raw token" \
  "$(cat "$SB_C/registry.masked.jsonl")" "FAKE-FCM-TOKEN"

# Keep the exit-3 sweep's own evidence before the rerun overwrites it.
mv "$SB_C/dispatch.out" "$SB_C/dispatch-1.out"
mv "$SB_C/dispatch.err" "$SB_C/dispatch-1.err"

# Rerun: terminal states stay terminal; nothing is sent again.
RC_C2=0; run_dispatcher "$SB_C" 0 || RC_C2=$?
check_eq "C rerun exit 0 (all pairs terminal)" 0 "$RC_C2"
SENDS_C_BEFORE="$(grep -c " SEND " "$SB_C/wire.log" || true)"
check_eq "C rerun sends nothing (6 sends total)" 6 "$SENDS_C_BEFORE"
collect_evidence "$SB_C" c || true

# ------------------------------------------------------------------ D
echo "--- scenario D: credential guards"
SB_D="$(new_sandbox d)"
INSIDE_REGISTRY="$PWD/runs/hsnotify-drill-guard-devices.jsonl"
write_config "$SB_D" "$INSIDE_REGISTRY"
RC_D=0; run_dispatcher "$SB_D" 0 || RC_D=$?
check_eq "D registry inside the repo is refused (exit 2)" 2 "$RC_D"
check_contains "D refusal names the rule" \
  "$(cat "$SB_D/dispatch.err")" "inside the repository"
rm -f "$INSIDE_REGISTRY"

BAD_BEARER_SB="$(new_sandbox d2)"
write_config "$BAD_BEARER_SB" "$BAD_BEARER_SB/devices.jsonl"
printf '%s\n' "ANOTHER-SECRET" > "$BAD_BEARER_SB/bearer.secret"
printf '%s\n' "FAKE-FCM-TOKEN-DEV1" > "$BAD_BEARER_SB/token-dev.txt"
RC_D2=0
env -u HSDRILL -u PYTHONPATH "$PY" "$NOTIFY/notify_register.py" \
  --config "$BAD_BEARER_SB/config.json" --device-id "dev-x" \
  --token-file "$BAD_BEARER_SB/token-dev.txt" --bearer "WRONG" \
  > "$BAD_BEARER_SB/register.out" 2> "$BAD_BEARER_SB/register.err" \
  || RC_D2=$?
check_eq "D wrong bearer refused (exit 2)" 2 "$RC_D2"
check_eq "D wrong bearer wrote no registry" 0 \
  "$(grep -c . "$BAD_BEARER_SB/devices.jsonl" 2>/dev/null || echo 0)"
collect_evidence "$SB_D" d || true

# ---------------------------------------------------------------- end
clear_drill_env
echo "=== fake-FCM drill: $PASS passed, $FAIL failed"
echo "=== evidence: $OUT (credential values must be absent)"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "FAKE-FCM DRILL PASSED"
