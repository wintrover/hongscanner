#!/usr/bin/env bash
## Independent notification-posting observer — one JSON evidence line per
## NotificationRecord of this package seen in the current tray.
##
## WHY THIS EXISTS: the shade keeps only the newest cards and the system
## archive is a small system-wide ring buffer, so "one message per group was
## actually posted" cannot be proven after the fact from a single dumpsys
## (2026-11-19: 12 FCM sends 10:00-10:31, only the newest cards survived to
## 10:41). This poller samples the tray while the cards are still there.
##
## READ-ONLY: it never dismisses, taps, cancels or posts anything. adb is used
## only for `devices` and `shell dumpsys notification --noredact`. Its only
## write is one appended line to
## ~/.local/share/hongscanner/observe/notifications-<KST date>.hcj.jsonl.
##
## SCOPE: only the `Notification List:` section (current tray) is parsed, and
## only records whose header says pkg=com.hongscanner.hongscanner. The archive
## (`mArchive`) and `Enqueued Notification List:` are not posted evidence and
## are ignored.
##
## SAMPLING, NOT CONTINUITY: a card posted and replaced between two polls is
## never observed. Dedupe key is (tag, when_ms) — the same slot identity the
## shade uses (FCM tags are per message; the digest slot is replaced in place,
## so a new `when` marks a new post). The file is append-only.
##
## WINDOW COVERAGE: with --window START/END the observer has to prove that the
## whole acceptance window was sampled, not merely that some notifications were
## seen. It refuses to start outside the window (exit 2, one error line), emits
## a heartbeat for every 60 s of loop time, and closes with one observer_end
## when it reaches END. A laptop that wakes at 09:10 therefore cannot produce a
## clean-looking 09:10-09:35 run: the missing heartbeats and observer_end make
## the gap visible. Heartbeats and observer_end are coverage metadata, never
## notification evidence.
##
## FAILURE POLICY: adb absence, a missing device or an unrecognized dump
## records one line with an `error` field and the script still exits 0 — an
## observer with no target must not kill the caller (same policy as
## observe_session.sh). In loop mode a failing poll is one error line and the
## loop continues. A bad invocation (unknown option, interval < 5, --window
## without --interval) and a start outside the window exit 2.
set -u

export TZ=Asia/Seoul

HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
OUT_DIR="${HOME}/.local/share/hongscanner/observe"
INTERVAL=0
SERIAL=""
ADB="${ADB:-adb}"
WINDOW=""
PACKAGE="com.hongscanner.hongscanner"

# Provenance travels with every line so a record can be traced to the observer
# that wrote it. Both values may be "unknown" (not a git checkout, no
# sha256sum); recording that is better than refusing to observe.
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
OBSERVER_GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"
OBSERVER_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1)"
[ -n "$OBSERVER_GIT_COMMIT" ] || OBSERVER_GIT_COMMIT="unknown"
[ -n "$OBSERVER_SHA256" ] || OBSERVER_SHA256="unknown"

usage() {
  cat <<'EOF'
usage: observe_notifications.sh [--once] [--interval SECONDS] [--serial SERIAL]
                                [--window START/END] [--out-dir DIR] [--adb PATH]

  --once              capture one dump and exit (default)
  --interval N        capture every N seconds (N >= 5) until SIGTERM or window END
  --serial SERIAL     adb -s SERIAL; default: first device in `adb devices`
  --window START/END  only run inside the ISO-8601 window, e.g.
                      2026-11-20T08:58:00+09:00/2026-11-20T09:35:00+09:00
                      (requires --interval; a single snapshot cannot cover a window)
  --out-dir DIR       output directory (default ~/.local/share/hongscanner/observe)
  --adb PATH          adb executable (default: adb on PATH)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --once)
      INTERVAL=0
      shift
      ;;
    --interval)
      if [ "$#" -lt 2 ]; then
        echo "observe_notifications: --interval needs a value" >&2
        exit 2
      fi
      case "$2" in
        ''|*[!0-9]*)
          echo "observe_notifications: --interval must be an integer >= 5" >&2
          exit 2
          ;;
      esac
      if [ "$2" -lt 5 ]; then
        echo "observe_notifications: --interval must be >= 5 seconds" >&2
        exit 2
      fi
      INTERVAL="$2"
      shift 2
      ;;
    --serial)
      if [ "$#" -lt 2 ]; then
        echo "observe_notifications: --serial needs a value" >&2
        exit 2
      fi
      SERIAL="$2"
      shift 2
      ;;
    --window)
      if [ "$#" -lt 2 ]; then
        echo "observe_notifications: --window needs a value" >&2
        exit 2
      fi
      WINDOW="$2"
      shift 2
      ;;
    --out-dir)
      if [ "$#" -lt 2 ]; then
        echo "observe_notifications: --out-dir needs a value" >&2
        exit 2
      fi
      OUT_DIR="$2"
      shift 2
      ;;
    --adb)
      if [ "$#" -lt 2 ]; then
        echo "observe_notifications: --adb needs a value" >&2
        exit 2
      fi
      ADB="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "observe_notifications: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$INTERVAL" in
  ''|*[!0-9]*)
    echo "observe_notifications: --interval must be an integer >= 5" >&2
    exit 2
    ;;
esac

if [ -n "$WINDOW" ]; then
  if [ "$INTERVAL" -eq 0 ]; then
    echo "observe_notifications: --window requires --interval (a single snapshot cannot cover a window)" >&2
    exit 2
  fi
  case "$WINDOW" in
    */*) ;;
    *)
      echo "observe_notifications: --window must be START/END" >&2
      exit 2
      ;;
  esac
  WINDOW_START="${WINDOW%%/*}"
  WINDOW_END="${WINDOW#*/}"
  START_EPOCH=""
  END_EPOCH=""
  if [ -n "$WINDOW_START" ] && [ -n "$WINDOW_END" ]; then
    START_EPOCH="$(date -d "$WINDOW_START" +%s 2>/dev/null)"
    END_EPOCH="$(date -d "$WINDOW_END" +%s 2>/dev/null)"
  fi
  case "${START_EPOCH}:${END_EPOCH}" in
    :*|*:|*[!0-9:]*)
      echo "observe_notifications: --window needs two ISO-8601 timestamps with offset" >&2
      exit 2
      ;;
  esac
  if [ "$START_EPOCH" -ge "$END_EPOCH" ]; then
    echo "observe_notifications: --window START must be before END" >&2
    exit 2
  fi
fi

mkdir -p "$OUT_DIR" 2>/dev/null || true

# Resolve the serial once so every evidence line names the device. Without
# --serial, `adb devices` is the only read-only probe; if it yields nothing
# the dumpsys call below fails and that failure is recorded honestly.
if [ -z "$SERIAL" ]; then
  DEVICES_OUT="$("$ADB" devices 2>/dev/null)" || DEVICES_OUT=""
  SERIAL="$(printf '%s\n' "$DEVICES_OUT" |
    awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi

capture_once() {
  NOW_ISO="$(date +%Y-%m-%dT%H:%M:%S%:z)"
  NOW_KST="$(date '+%Y-%m-%d %H:%M:%S KST')"
  OUT_FILE="${OUT_DIR}/notifications-$(date +%F).hcj.jsonl"
  DUMP_FILE="$(mktemp "${TMPDIR:-/tmp}/hs-observe-notifications.XXXXXX")" || DUMP_FILE=""
  ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/hs-observe-notifications-err.XXXXXX")" || ERR_FILE=""

  if [ -z "$DUMP_FILE" ] || [ -z "$ERR_FILE" ]; then
    printf '%s\n' "{\"captured_at\":\"${NOW_ISO}\",\"device_serial\":null,\"error\":\"mktemp failed\",\"errors\":{\"observer\":\"mktemp failed\"},\"kst\":\"${NOW_KST}\",\"observer_git_commit\":\"${OBSERVER_GIT_COMMIT}\",\"observer_sha256\":\"${OBSERVER_SHA256}\",\"package\":\"${PACKAGE}\"}" >> "$OUT_FILE" 2>/dev/null || true
    return 0
  fi

  if [ -n "$SERIAL" ]; then
    "$ADB" -s "$SERIAL" shell dumpsys notification --noredact \
      > "$DUMP_FILE" 2> "$ERR_FILE"
  else
    "$ADB" shell dumpsys notification --noredact \
      > "$DUMP_FILE" 2> "$ERR_FILE"
  fi
  ADB_RC=$?

  python3 - "$OUT_FILE" "$NOW_ISO" "$NOW_KST" "$SERIAL" "$ADB_RC" \
    "$DUMP_FILE" "$ERR_FILE" "$OBSERVER_GIT_COMMIT" "$OBSERVER_SHA256" <<'PY'
import datetime as dt
import json
import os
import re
import sys

PACKAGE = "com.hongscanner.hongscanner"
KST = dt.timezone(dt.timedelta(hours=9))

(out_file, at, kst, serial, adb_rc, dump_path, err_path,
 git_commit, script_sha256) = sys.argv[1:10]
adb_rc = int(adb_rc)


def append(record):
    payload = (json.dumps(record, ensure_ascii=False, sort_keys=True,
                          separators=(",", ":")) + "\n").encode("utf-8")
    os.makedirs(os.path.dirname(out_file), exist_ok=True)
    fd = os.open(out_file, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        # A crash can leave a partial trailing line. Append-only forbids
        # repairing its bytes, so isolate it: start the new record on a new
        # line instead of concatenating two records into one.
        size = os.lseek(fd, 0, os.SEEK_END)
        if size > 0:
            os.lseek(fd, size - 1, os.SEEK_SET)
            if os.read(fd, 1) != b"\n":
                os.write(fd, b"\n")
        os.write(fd, payload)
        os.fsync(fd)
    finally:
        os.close(fd)


def error_line(message):
    message = " ".join(str(message).split())[:300]
    append({
        "captured_at": at,
        "device_serial": serial or None,
        "error": message,
        "errors": {"adb": message},
        "kst": kst,
        "observer_git_commit": git_commit,
        "observer_sha256": script_sha256,
        "package": PACKAGE,
    })


if adb_rc != 0:
    with open(err_path, "r", encoding="utf-8", errors="replace") as handle:
        stderr = handle.read().strip()
    error_line("adb shell dumpsys notification failed rc=%d%s"
               % (adb_rc, (": " + stderr) if stderr else ""))
    sys.exit(0)

with open(dump_path, "r", encoding="utf-8", errors="replace") as handle:
    text = handle.read()

if "Notification Manager state" not in text:
    error_line("unrecognized dumpsys output: no Notification Manager state "
               "header (%d bytes)" % len(text.encode("utf-8")))
    sys.exit(0)

# Only the current tray is posted evidence. `Notification List:` holds
# NotificationRecord blocks; `mArchive` prints StatusBarNotification lines and
# `Enqueued Notification List:` holds records not yet posted.
RECORD_RE = re.compile(r"^\s*NotificationRecord\(")
LIST_RE = re.compile(r"^  Notification List:\s*$")
SECTION_RE = re.compile(r"^  \S")

blocks = []
block = None
in_list = False
for line in text.splitlines():
    if LIST_RE.match(line):
        if block is not None:
            blocks.append(block)
            block = None
        in_list = True
        continue
    if not in_list:
        continue
    if SECTION_RE.match(line):
        if block is not None:
            blocks.append(block)
            block = None
        in_list = False
        continue
    if RECORD_RE.match(line):
        if block is not None:
            blocks.append(block)
        block = [line]
    elif block is not None:
        block.append(line)
if block is not None:
    blocks.append(block)


def first(pattern, lines, flags=0):
    for line in lines:
        match = re.search(pattern, line, flags)
        if match:
            return match.group(1)
    return None


def string_extra(name, lines):
    value = first(r"\bandroid\." + name + r"=String \((.*)\)\s*$", lines)
    return value


def parse_block(lines):
    header = lines[0]
    if first(r"\bpkg=([^\s]+)", [header]) != PACKAGE:
        return None
    tag = first(r"\btag=([^\s]+)", [header])
    if tag == "null":
        tag = None
    channel = first(r"\bchannel=([^\s)]+)", [header])
    if channel == "null":
        channel = None
    if channel is None:
        channel = first(r"\bmId='([^']*)'", lines)
    importance = first(r"\bimportance=(-?\d+)", [header])
    if importance is None:
        importance = first(r"\bmImportance=(-?\d+)\b", lines)
    when = first(r"^\s*when=(-?\d+)\s*$", lines)
    title = string_extra("title", lines)
    text_value = string_extra("bigText", lines)
    if text_value is None:
        text_value = string_extra("text", lines)
    when_ms = int(when) if when is not None else None
    return {
        "captured_at": at,
        "device_serial": serial or None,
        "tag": tag,
        "channel": channel,
        "importance": int(importance) if importance is not None else None,
        "when_ms": when_ms,
        "when_kst": (dt.datetime.fromtimestamp(when_ms / 1000.0, KST)
                     .isoformat(timespec="seconds")
                     if when_ms is not None else None),
        "title": title,
        "text": text_value,
        "package": PACKAGE,
        "snapshot_status": "OBSERVED_ACTIVE",
        "observer_git_commit": git_commit,
        "observer_sha256": script_sha256,
    }


seen = set()
try:
    with open(out_file, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict) and "tag" in rec and "when_ms" in rec:
                seen.add((rec.get("tag"), rec.get("when_ms")))
except FileNotFoundError:
    pass

for block in blocks:
    record = parse_block(block)
    if record is None:
        continue
    key = (record["tag"], record["when_ms"])
    if key in seen:
        continue
    seen.add(key)
    append(record)
PY
  PY_RC=$?

  if [ "$PY_RC" -ne 0 ]; then
    # Last resort: the observer itself failed. Record that honestly and
    # keep the timer/caller alive.
    printf '%s\n' "{\"captured_at\":\"${NOW_ISO}\",\"device_serial\":null,\"error\":\"observer python failed rc=${PY_RC}\",\"errors\":{\"observer\":\"python failed rc=${PY_RC}\"},\"kst\":\"${NOW_KST}\",\"observer_git_commit\":\"${OBSERVER_GIT_COMMIT}\",\"observer_sha256\":\"${OBSERVER_SHA256}\",\"package\":\"${PACKAGE}\"}" >> "$OUT_FILE" 2>/dev/null || true
  fi

  rm -f "$DUMP_FILE" "$ERR_FILE" 2>/dev/null || true
}

append_line() {
  LINE_FILE="${OUT_DIR}/notifications-$(date +%F).hcj.jsonl"
  if [ -s "$LINE_FILE" ] && [ -n "$(tail -c 1 "$LINE_FILE" 2>/dev/null)" ]; then
    printf '\n' >> "$LINE_FILE"
  fi
  printf '%s\n' "$1" >> "$LINE_FILE"
}

json_string_or_null() {
  if [ -z "$1" ]; then
    printf 'null'
  else
    printf '"%s"' "$1"
  fi
}

append_heartbeat() {
  append_line "{\"kind\":\"heartbeat\",\"captured_at\":\"$(date +%Y-%m-%dT%H:%M:%S%:z)\",\"device_serial\":$(json_string_or_null "$SERIAL"),\"polls\":${POLLS},\"package\":\"${PACKAGE}\",\"observer_git_commit\":\"${OBSERVER_GIT_COMMIT}\",\"observer_sha256\":\"${OBSERVER_SHA256}\"}"
  LAST_HEARTBEAT_EPOCH="$(date +%s)"
}

# Chunked so a long --interval still yields a heartbeat every 60 s of loop
# time; the total sleep is unchanged, so the poll cadence is not.
sleep_with_heartbeats() {
  SLEEP_LEFT="$1"
  while [ "$SLEEP_LEFT" -gt 0 ]; do
    SLEEP_CHUNK=60
    if [ "$SLEEP_LEFT" -lt "$SLEEP_CHUNK" ]; then
      SLEEP_CHUNK="$SLEEP_LEFT"
    fi
    sleep "$SLEEP_CHUNK" &
    wait $!
    SLEEP_LEFT=$((SLEEP_LEFT - SLEEP_CHUNK))
    NOW_EPOCH="$(date +%s)"
    if [ $((NOW_EPOCH - LAST_HEARTBEAT_EPOCH)) -ge 60 ]; then
      append_heartbeat
    fi
  done
}

trap 'exit 0' TERM INT

if [ "$INTERVAL" -eq 0 ]; then
  capture_once
  exit 0
fi

if [ -z "$WINDOW" ]; then
  while :; do
    capture_once
    sleep "$INTERVAL" &
    wait $!
  done
fi

NOW_EPOCH="$(date +%s)"
NOW_ISO="$(date +%Y-%m-%dT%H:%M:%S%:z)"
NOW_KST="$(date '+%Y-%m-%d %H:%M:%S KST')"
if [ "$NOW_EPOCH" -lt "$START_EPOCH" ] || [ "$NOW_EPOCH" -gt "$END_EPOCH" ]; then
  WINDOW_ERROR="observer started outside window: ${NOW_ISO}"
  append_line "{\"captured_at\":\"${NOW_ISO}\",\"device_serial\":$(json_string_or_null "$SERIAL"),\"error\":\"${WINDOW_ERROR}\",\"errors\":{\"window\":\"${WINDOW_ERROR}\"},\"kst\":\"${NOW_KST}\",\"observer_git_commit\":\"${OBSERVER_GIT_COMMIT}\",\"observer_sha256\":\"${OBSERVER_SHA256}\",\"package\":\"${PACKAGE}\"}"
  exit 2
fi

STARTED_AT="$(date +%Y-%m-%dT%H:%M:%S%:z)"
LAST_HEARTBEAT_EPOCH="$(date +%s)"
POLLS=0

while :; do
  NOW_EPOCH="$(date +%s)"
  if [ "$NOW_EPOCH" -ge "$END_EPOCH" ]; then
    break
  fi
  capture_once
  POLLS=$((POLLS + 1))
  NOW_EPOCH="$(date +%s)"
  if [ $((NOW_EPOCH - LAST_HEARTBEAT_EPOCH)) -ge 60 ]; then
    append_heartbeat
  fi
  SLEEP_FOR="$INTERVAL"
  REMAINING=$((END_EPOCH - NOW_EPOCH))
  if [ "$REMAINING" -lt "$SLEEP_FOR" ]; then
    SLEEP_FOR="$REMAINING"
  fi
  sleep_with_heartbeats "$SLEEP_FOR"
done

append_line "{\"kind\":\"observer_end\",\"started_at\":\"${STARTED_AT}\",\"ended_at\":\"$(date +%Y-%m-%dT%H:%M:%S%:z)\",\"window_start\":\"${WINDOW_START}\",\"window_end\":\"${WINDOW_END}\",\"polls\":${POLLS},\"exit\":\"ok\",\"device_serial\":$(json_string_or_null "$SERIAL"),\"package\":\"${PACKAGE}\",\"observer_git_commit\":\"${OBSERVER_GIT_COMMIT}\",\"observer_sha256\":\"${OBSERVER_SHA256}\"}"
exit 0