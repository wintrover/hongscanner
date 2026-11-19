#!/usr/bin/env bash
## Independent session observer — one JSON evidence line per checkpoint.
##
## WHY THIS EXISTS: an observer that runs inside the session cannot observe
## the session. When the collector dies, the observer dies with it; at 08:45
## the 08:50 timer has not fired yet, and at 15:45 the session is already
## over. This script is started by its own systemd user timer
## (tools/systemd/hongscanner-observe.timer), so it survives whatever the
## session service does.
##
## READ-ONLY: it never touches the session, the ledger, the delivery log or
## the registry. Its only write is one appended line to
## ~/.local/share/hongscanner/observe/observe-<KST date>.hcj.jsonl.
##
## FAILURE POLICY: every check is independent. A failing check records
## null + an `errors` entry and the script still exits 0 — a red checkpoint
## must never kill the timer. The `error` field is the honest summary.
##
## --scheduled: the timer invocation. The checkpoint times come from the
## run's own calendar snapshot (tools/observe_schedule.py); a fire that
## is not a checkpoint exits without writing, before the ledger scan.
## Without the flag (manual run) a line is always recorded.
set -u

scheduled=0
for arg in "$@"; do
  case "$arg" in
    --scheduled) scheduled=1 ;;
    *)
      printf 'observe_session.sh: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

export TZ=Asia/Seoul

HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SESSION_DATE="$(date +%F)"
NOW_ISO="$(date +%Y-%m-%dT%H:%M:%S%:z)"
NOW_KST="$(date '+%Y-%m-%d %H:%M:%S KST')"
OUT_DIR="${HOME}/.local/share/hongscanner/observe"
OUT_FILE="${OUT_DIR}/observe-${SESSION_DATE}.hcj.jsonl"

mkdir -p "$OUT_DIR" 2>/dev/null || true

python3 - "$OUT_FILE" "$SESSION_DATE" "$NOW_ISO" "$NOW_KST" "$REPO_ROOT" "$scheduled" <<'PY'
import collections
import datetime as dt
import glob
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

(out_file, session_date, at, kst, repo_root, scheduled) = sys.argv[1:7]
scheduled = scheduled == "1"

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(repo_root, "tools"))
from observe_schedule import schedule  # noqa: E402

SESSION_UNIT = "hongscanner-session.service"
SESSION_TIMER = "hongscanner-session.timer"
OBSERVE_TIMER = "hongscanner-observe.timer"
API_BASE = "http://127.0.0.1:8080"
KST = dt.timezone(dt.timedelta(hours=9))
LEDGER_BUDGET_SECONDS = 10.0

errors = {}


def fail(field, message):
    errors[field] = str(message)


def kst_iso(usec):
    return dt.datetime.fromtimestamp(usec / 1_000_000,
                                     KST).isoformat(timespec="seconds")


def run_cmd(args, timeout=10):
    proc = subprocess.run(args, capture_output=True, text=True,
                          timeout=timeout)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def checkpoint_name(calendar_open):
    hm = at[11:16]
    names = schedule(calendar_open)
    if hm in names:
        return hm
    minutes = int(hm[:2]) * 60 + int(hm[3:])
    best = None
    for name in names:
        delta = abs(minutes - (int(name[:2]) * 60 + int(name[3:])))
        if delta <= 3 and (best is None or delta < best[0]):
            best = (delta, name)
    return best[1] if best else "manual-" + hm


def timers():
    """{unit: next-ISO} from the user manager's list-timers JSON."""
    rc, out, err = run_cmd(["systemctl", "--user", "list-timers", "--all",
                            "--no-pager", "--output=json"])
    if rc != 0:
        raise RuntimeError("list-timers rc=%d: %s" % (rc, err or out))
    rows = json.loads(out)
    result = {}
    for row in rows:
        unit = row.get("unit")
        nxt = row.get("next") or 0
        result[unit] = kst_iso(nxt) if nxt else None
    return result


def read_json_line(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.loads(handle.readline())


def load_run_dir():
    pattern = os.path.join(repo_root, "runs", "session-" + session_date + "*")
    dirs = [p for p in glob.glob(pattern) if os.path.isdir(p)]
    if not dirs:
        raise FileNotFoundError("no runs/session-%s* directory" % session_date)
    return max(dirs, key=os.path.getmtime)


record = {
    "at": at,
    "kst": kst,
    "checkpoint": None,
    "timer_next": None,
    "timer_unit": SESSION_TIMER,
    "observer_timer_next": None,
    "unit_active": None,
    "unit_result": None,
    "run_dir": None,
    "run_session_date": None,
    "run_session_date_source": None,
    "calendar_open": None,
    "mode": None,
    "mode_as_of": None,
    "data_as_of": None,
    "events_session_id": session_date,
    "events_total": None,
    "events_by_type": None,
    "events_skipped": False,
    "delivery_pairs": None,
    "devices_active": None,
    "top10_observed_min": None,
    "top10_observed_max": None,
}

# ---- user-manager timers -------------------------------------------------
try:
    timer_map = timers()
    if SESSION_TIMER in timer_map:
        record["timer_next"] = timer_map[SESSION_TIMER]
        if record["timer_next"] is None:
            fail("timer_next", "%s has no next elapse" % SESSION_TIMER)
    else:
        fail("timer_next", "%s not found in list-timers" % SESSION_TIMER)
    if OBSERVE_TIMER in timer_map:
        record["observer_timer_next"] = timer_map[OBSERVE_TIMER]
        if record["observer_timer_next"] is None:
            fail("observer_timer_next",
                 "%s has no next elapse" % OBSERVE_TIMER)
    else:
        fail("observer_timer_next",
             "%s not found in list-timers" % OBSERVE_TIMER)
except Exception as exc:  # noqa: BLE001 - every check is independent
    fail("timer_next", exc)
    fail("observer_timer_next", exc)

# ---- session unit state --------------------------------------------------
try:
    rc, out, err = run_cmd(["systemctl", "--user", "is-active",
                            SESSION_UNIT])
    if out:
        record["unit_active"] = out
    else:
        fail("unit_active", "is-active rc=%d: %s" % (rc, err or "no output"))
except Exception as exc:  # noqa: BLE001
    fail("unit_active", exc)

try:
    rc, out, err = run_cmd(["systemctl", "--user", "show", "-p", "Result",
                            "--value", SESSION_UNIT])
    if rc == 0 and out:
        record["unit_result"] = out
    else:
        fail("unit_result", "show rc=%d: %s" % (rc, err or out))
except Exception as exc:  # noqa: BLE001
    fail("unit_result", exc)

# ---- run directory and its recorded calendar ----------------------------
run_dir = None
try:
    run_dir = load_run_dir()
    record["run_dir"] = run_dir
except Exception as exc:  # noqa: BLE001
    fail("run_dir", exc)

if run_dir is not None:
    try:
        first = read_json_line(os.path.join(run_dir, "input.hcj.jsonl"))
        day = (first.get("raw") or {}).get("days", {}).get(session_date)
        if not isinstance(day, dict):
            raise KeyError("calendar has no entry for %s" % session_date)
        record["calendar_open"] = day.get("open")
        if record["calendar_open"] is None:
            fail("calendar_open",
                 "calendar entry for %s records open=null" % session_date)
    except Exception as exc:  # noqa: BLE001
        fail("calendar_open", exc)

# ---- checkpoint schedule from the recorded opening ----------------------
# The timer fires on a 5-minute grid; a fire that is not a checkpoint
# exits here, before the ledger scan, and writes nothing.
record["checkpoint"] = checkpoint_name(record["calendar_open"])
if scheduled and record["checkpoint"].startswith("manual-"):
    sys.exit(0)

if run_dir is not None:
    # run.json is the declared session identity; live collector runs do not
    # write it yet, so the input config record (seq 2) is the fallback the
    # API itself uses.
    try:
        run_json = os.path.join(run_dir, "run.json")
        if os.path.isfile(run_json):
            with open(run_json, "r", encoding="utf-8") as handle:
                value = json.load(handle).get("session_date")
            if not isinstance(value, str) or not value:
                raise ValueError("run.json session_date is not a string")
            record["run_session_date"] = value
            record["run_session_date_source"] = "run.json"
        else:
            with open(os.path.join(run_dir, "input.hcj.jsonl"), "r",
                      encoding="utf-8") as handle:
                handle.readline()
                second = json.loads(handle.readline())
            value = (second.get("raw") or {}).get("session_date")
            if not isinstance(value, str) or not value:
                raise ValueError("input record 2 has no session_date")
            record["run_session_date"] = value
            record["run_session_date_source"] = "input.hcj.jsonl seq 2"
    except Exception as exc:  # noqa: BLE001
        fail("run_session_date", exc)

# ---- local API (read-only GET) ------------------------------------------
api = None
try:
    with urllib.request.urlopen(API_BASE + "/mobile/market-view",
                                timeout=5) as response:
        api = json.load(response)
    record["mode"] = api.get("mode")
    record["mode_as_of"] = api.get("mode_as_of")
    record["data_as_of"] = api.get("data_as_of")
    for field in ("mode", "mode_as_of", "data_as_of"):
        if record[field] is None:
            fail(field, "market-view records %s=null" % field)
except urllib.error.HTTPError as exc:
    fail("mode", "market-view HTTP %d" % exc.code)
    fail("mode_as_of", "market-view HTTP %d" % exc.code)
    fail("data_as_of", "market-view HTTP %d" % exc.code)
except Exception as exc:  # noqa: BLE001
    fail("mode", exc)
    fail("mode_as_of", exc)
    fail("data_as_of", exc)

# ---- MA20 candidate pollution window (top10 observed_at spread) ---------
if api is not None:
    try:
        observed = []
        for side in ("rising_top10", "falling_top10"):
            for item in api.get(side) or []:
                value = item.get("observed_at")
                if isinstance(value, str):
                    observed.append(value)
        if observed:
            record["top10_observed_min"] = min(observed)
            record["top10_observed_max"] = max(observed)
        else:
            fail("top10_observed_min", "market-view has no top10 observed_at")
            fail("top10_observed_max", "market-view has no top10 observed_at")
    except Exception as exc:  # noqa: BLE001
        fail("top10_observed_min", exc)
        fail("top10_observed_max", exc)

# ---- notify ledger: session event counts --------------------------------
events_session_id = record["run_session_date"] or session_date
record["events_session_id"] = events_session_id
notify_dir = os.path.join(os.path.expanduser("~"), ".local", "share",
                          "hongscanner", "notify")
ledger_path = os.path.join(notify_dir, "ledger.hcj.jsonl")
delivery_path = os.path.join(notify_dir, "delivery.hcj.jsonl")
try:
    config_path = os.path.join(notify_dir, "notify_config.json")
    if os.path.isfile(config_path):
        with open(config_path, "r", encoding="utf-8") as handle:
            config = json.load(handle)
        ledger_path = config.get("ledger_path") or ledger_path
        delivery_path = config.get("delivery_path") or delivery_path
except Exception as exc:  # noqa: BLE001
    fail("ledger_path", exc)

session_event_ids = set()
try:
    needle = ('"session_id":"' + events_session_id + '"').encode("utf-8")
    by_type = collections.Counter()
    deadline = time.monotonic() + LEDGER_BUDGET_SECONDS
    started = time.monotonic()
    with open(ledger_path, "rb") as handle:
        for lineno, line in enumerate(handle, start=1):
            if lineno % 8192 == 0 and time.monotonic() > deadline:
                record["events_skipped"] = True
                raise TimeoutError(
                    "ledger scan exceeded %.0f s after %d lines"
                    % (LEDGER_BUDGET_SECONDS, lineno))
            if needle not in line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            session_event_ids.add(event["event_id"])
            by_type[event["event_type"]] += 1
    record["events_total"] = len(session_event_ids)
    record["events_by_type"] = dict(sorted(by_type.items()))
    record["events_scan_seconds"] = round(time.monotonic() - started, 3)
except Exception as exc:  # noqa: BLE001
    if not record["events_skipped"]:
        fail("events_total", exc)
        fail("events_by_type", exc)

# ---- delivery pairs for this session ------------------------------------
if record["events_skipped"]:
    fail("delivery_pairs", "skipped: ledger scan exceeded the budget")
else:
    try:
        latest = {}
        with open(delivery_path, "rb") as handle:
            for raw in handle:
                if not raw.endswith(b"\n"):
                    fail("delivery_pairs",
                         "uncommitted trailing delivery line ignored")
                    continue
                try:
                    rec = json.loads(raw)
                except ValueError:
                    continue
                latest[(rec["event_id"], rec["device_id"])] = rec
        record["delivery_pairs"] = sum(
            1 for event_id, _ in latest if event_id in session_event_ids)
    except Exception as exc:  # noqa: BLE001
        fail("delivery_pairs", exc)

# ---- active device count (no send, no token leaves this process) --------
try:
    registry_path = os.path.join(notify_dir, "devices.jsonl")
    disabled = []
    config_path = os.path.join(notify_dir, "notify_config.json")
    if os.path.isfile(config_path):
        with open(config_path, "r", encoding="utf-8") as handle:
            config = json.load(handle)
        registry_path = config.get("registry_path") or registry_path
        raw_disabled = config.get("disabled_devices")
        if raw_disabled is not None:
            if not isinstance(raw_disabled, list) or not all(
                    isinstance(item, str) for item in raw_disabled):
                raise ValueError("disabled_devices must be a list of strings")
            disabled = raw_disabled
    if not os.path.isfile(registry_path):
        raise FileNotFoundError("registry %s is absent" % registry_path)
    active = {}
    with open(registry_path, "r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec.get("kind") == "device":
                active[rec["device_id"]] = True
            elif rec.get("kind") == "token_invalid":
                active.pop(rec.get("device_id"), None)
    record["devices_active"] = len(
        [device for device in active if device not in disabled])
except Exception as exc:  # noqa: BLE001
    fail("devices_active", exc)

# ---- emit ----------------------------------------------------------------
if errors:
    record["error"] = "; ".join(
        "%s: %s" % (key, errors[key]) for key in sorted(errors))
    record["errors"] = {key: str(errors[key]) for key in sorted(errors)}
else:
    record["error"] = None
    record["errors"] = {}

payload = (json.dumps(record, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")) + "\n").encode("utf-8")
os.makedirs(os.path.dirname(out_file), exist_ok=True)
fd = os.open(out_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
try:
    os.write(fd, payload)
    os.fsync(fd)
finally:
    os.close(fd)
PY
rc=$?

if [ "$rc" -ne 0 ]; then
  # Last-resort line: the observer itself failed. Record that honestly and
  # keep the timer alive.
  printf '%s' "{\"at\":\"${NOW_ISO}\",\"calendar_open\":null,\"checkpoint\":null,\"data_as_of\":null,\"delivery_pairs\":null,\"devices_active\":null,\"error\":\"observer python failed rc=${rc}\",\"errors\":{\"observer\":\"python failed rc=${rc}\"},\"events_by_type\":null,\"events_session_id\":\"${SESSION_DATE}\",\"events_skipped\":false,\"events_total\":null,\"kst\":\"${NOW_KST}\",\"mode\":null,\"mode_as_of\":null,\"observer_timer_next\":null,\"run_dir\":null,\"run_session_date\":null,\"run_session_date_source\":null,\"timer_next\":null,\"timer_unit\":\"hongscanner-session.timer\",\"top10_observed_max\":null,\"top10_observed_min\":null,\"unit_active\":null,\"unit_result\":null}" >> "${OUT_FILE}" 2>/dev/null || true
  printf '\n' >> "${OUT_FILE}" 2>/dev/null || true
fi

exit 0