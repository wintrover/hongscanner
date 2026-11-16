#!/usr/bin/env bash
## Runs retention — the runs/ disk-retention executor (docs/RETENTION.md).
##
## One trading day leaves runs/<name>/ + the sibling runs/<name>.launcher.log
## on the operational server; unbounded growth eventually fills the disk
## mid-session and the scanner stops while nobody is looking. This script
## grades every run (docs/RETENTION.md 판정표 v2, precedence top-down:
## ACTIVE > FAILED > SERVICE_DEPENDENCY > GATES_REFERENCED > RECENT_RAW >
## UNKNOWN > ARCHIVE_ELIGIBLE) and archives ONLY the sealed-and-cleanly-
## ended intersection: commit marker VALID (schema + full input.hcj.jsonl
## sha256 recompute) + launcher log + COLLECTOR_EXIT=0 + run_session end
## line + outside the recent trading-day window. Every other run keeps its
## original bytes — failed runs and their evidence are never deleted or
## overwritten (AGENTS.md §2.1); reproduction always happens in a NEW
## directory, so an archived run never re-enters runs/.
##
## Modes: no argument = DRY RUN (prints grades/reasons/sizes/actions, the
## per-grade summary, df avail and the quota state; touches nothing — not
## even retention-log.jsonl). --apply = the real work. Any other argument
## is a usage error.
##
## Concurrency: exclusive non-blocking flock on $HS_STATE_DIR/retention.lock;
## a second concurrent run exits 0 "already running".
##
## Active-session defense: while hongscanner-session.service is
## active/activating the whole pass is SKIPPED (stdout
## SKIPPED_ACTIVE_SESSION, logged in --apply) before runs/ is touched — a
## session mid-write outranks any classification.
##
## The KRX calendar (installed copy, INDEX sha256 verified) decides the
## recent-trading-day window. A missing calendar file, an index mismatch,
## today outside the calendar span, or a window that cannot be established
## makes the calendar UNUSABLE: every run is protected (fail-closed).
##
## Quota: soft quota on du(runs) + du(runs-archive). Over quota: delete the
## OLDEST verified archives first (each deletion logged BEFORE the removal).
## With nothing deletable left the script records RETENTION_BLOCKED, sends
## one FCM ops alert and exits 0 — an honest report, not an operational
## stop. Normal runs send NO notification.
##
## The archive round-trip: df avail >= 2x run bytes -> SHA-256 manifest of
## every original file -> tar+zstd to the state tmp -> zstd -t -> restore
## to a fresh temp dir -> sha256sum -c the manifest (byte identity) ->
## only then move to runs-archive/<name>.tar.zst, log the ARCHIVE record,
## and remove the original. Any failed step keeps the original and cleans
## only the temp artifacts.
##
## Notify: $HS_NOTIFY_CMD (when set) is called as
##   $HS_NOTIFY_CMD "<title>" "<body>"
## and its exit code is recorded. When unset the built-in default sender
## runs: a one-shot python3 program that reuses the tools/notify library
## directly (notify_config.load_config "dispatch" — config path
## $HSNOTIFY_CONFIG, default ~/.local/share/hongscanner/notify/
## notify_config.json; OAuth token via TokenSource: service-account JSON or
## token_command; devices from the registry; one notification+data message
## per active device via notify_fcm.send_message, explicit android.priority
## and the market_rank_changes channel). Exit codes: 0 every send accepted,
## 2 usage/config (incl. payload over the 4096-byte vendor limit), 3
## credential failure or any non-accepted send. Ops alerts are not event
## facts: the dispatcher admission gate never sees them, so no delivery
## ledger record is written (accepted != delivered is recorded as an exit
## code + stdout result line, nothing more).
##
## Usage: tools/runs_retention.sh [--apply]
## Env (every path overridable; the contract tests stub them):
##   HS_RUNS_DIR             (default <repo>/runs)
##   HS_ARCHIVE_DIR          (default <repo>/runs-archive)
##   HS_STATE_DIR            (default <repo>/runs-retention; lock, log, tmp)
##   HS_CALENDAR_DIR         (default ~/.local/share/hongscanner/calendars)
##   HS_CALENDAR_INDEX       (default <repo>/calendars/CALENDAR_INDEX.sha256)
##   HS_GATES_FILE           (default <repo>/docs/GATES.md)
##   HS_START_SCRIPTS_DIR    (default ~/.local/bin)
##   HS_SYSTEMCTL            (default "systemctl --user")
##   HS_ZSTD_LEVEL           (default 3; VS-0 measurement pending)
##   HS_QUOTA_BYTES          (default 107374182400 = 100 GiB, runs+archive)
##   HS_RECENT_TRADING_DAYS  (default 20)
##   HS_NOTIFY_CMD           (default: the built-in python3 sender above)
## Exit: 0 — report completed, including SKIPPED_ACTIVE_SESSION,
##       CALENDAR_UNUSABLE (all protected), deferred/failed archives and
##       RETENTION_BLOCKED (an honest report is not an operational stop);
##       2 — usage error. Fail-closed: an undecided run is protected.
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

APPLY=0
case "${1:-}" in
  "") APPLY=0 ;;
  --apply) APPLY=1 ;;
  *)
    echo "usage: tools/runs_retention.sh [--apply]" >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "usage: tools/runs_retention.sh [--apply]" >&2
  exit 2
fi

HS_RUNS_DIR="${HS_RUNS_DIR:-$REPO/runs}"
HS_ARCHIVE_DIR="${HS_ARCHIVE_DIR:-$REPO/runs-archive}"
HS_STATE_DIR="${HS_STATE_DIR:-$REPO/runs-retention}"
HS_CALENDAR_DIR="${HS_CALENDAR_DIR:-$HOME/.local/share/hongscanner/calendars}"
HS_CALENDAR_INDEX="${HS_CALENDAR_INDEX:-$REPO/calendars/CALENDAR_INDEX.sha256}"
HS_GATES_FILE="${HS_GATES_FILE:-$REPO/docs/GATES.md}"
HS_START_SCRIPTS_DIR="${HS_START_SCRIPTS_DIR:-$HOME/.local/bin}"
HS_SYSTEMCTL="${HS_SYSTEMCTL:-systemctl --user}"
HS_ZSTD_LEVEL="${HS_ZSTD_LEVEL:-3}"
HS_QUOTA_BYTES="${HS_QUOTA_BYTES:-107374182400}"
HS_RECENT_TRADING_DAYS="${HS_RECENT_TRADING_DAYS:-20}"
HS_NOTIFY_CMD="${HS_NOTIFY_CMD:-}"

for guard_var in HS_RUNS_DIR HS_ARCHIVE_DIR HS_STATE_DIR; do
  case "${!guard_var}" in
    ""|"/")
      echo "retention: refusing an empty or root $guard_var" >&2
      exit 2
      ;;
  esac
done

LOCK_FILE="$HS_STATE_DIR/retention.lock"
LOG_FILE="$HS_STATE_DIR/retention-log.jsonl"
TMP_DIR="$HS_STATE_DIR/tmp"
ACTIVE_MTIME_SECONDS=$(( 26 * 3600 ))

# The built-in one-shot ops-alert sender (HS_NOTIFY_CMD unset): the
# tools/notify library reused directly — config load, OAuth token, device
# registry, FCM HTTP v1 send. No single quotes (the program is embedded in
# a single-quoted bash string).
OPS_ALERT_PY='
import json, os, sys
sys.path.insert(0, sys.argv[1])
import notify_config, notify_fcm, notify_ledger
title, body = sys.argv[2], sys.argv[3]
config_path = (os.environ.get("HSNOTIFY_CONFIG") or
               os.path.expanduser("~/.local/share/hongscanner/notify/notify_config.json"))

def err(line):
    print(line, file=sys.stderr, flush=True)

try:
    cfg = notify_config.load_config(config_path, "dispatch")
except notify_config.ConfigError as exc:
    err("ops_alert: config refused: %s" % exc)
    sys.exit(2)

def message(token):
    return {"message": {
        "token": token,
        "notification": {"title": title, "body": body},
        "android": {"priority": "high",
                    "notification": {"channel_id": "market_rank_changes"}},
        "data": {"kind": "ops_alert", "title": title, "body": body}}}

registry = notify_ledger.Registry(cfg["registry_path"], lock=False)
try:
    devices = registry.devices()
finally:
    registry.close()
if not devices:
    err("ops_alert: no active devices in the registry")
    sys.exit(3)
try:
    tokens = notify_fcm.TokenSource(cfg)
    code = 0
    for device_id in sorted(devices):
        payload = message(devices[device_id])
        size = len(json.dumps(payload, ensure_ascii=False,
                              separators=(",", ":")).encode("utf-8"))
        if size > notify_fcm.PAYLOAD_LIMIT_BYTES:
            err("ops_alert: payload %d bytes is over the vendor limit" % size)
            sys.exit(2)
        outcome = notify_fcm.send_message(cfg["project_id"], tokens.get(), payload)
        print("ops_alert device=%s result=%s status=%s error=%s" % (
            device_id, outcome.kind, outcome.http_status, outcome.error_code),
            flush=True)
        if outcome.kind != "accepted":
            code = 3
    sys.exit(code)
except notify_fcm.FcmError as exc:
    err("ops_alert: credential failure: %s" % exc)
    sys.exit(3)
'

send_notify() { # $1 title, $2 body
  if [ -n "$HS_NOTIFY_CMD" ]; then
    # shellcheck disable=SC2086 # the override command may carry arguments
    $HS_NOTIFY_CMD "$1" "$2"
    return $?
  fi
  python3 -c "$OPS_ALERT_PY" "$REPO/tools/notify" "$1" "$2"
}

log_event() { # $1 action, rest KEY=VALUE — appends one JSON line (apply only)
  [ "$APPLY" = 1 ] || return 0
  python3 - "$LOG_FILE" "$@" <<'PY'
import datetime, json, sys
path, action, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
record = {"t": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
          "action": action}
for kv in pairs:
    key, _, value = kv.partition("=")
    if value.isdigit():
        value = int(value)
    record[key] = value
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
PY
}

now_epoch() { date +%s; }

df_avail() { # $1 path -> avail bytes ("" when df fails)
  df -B1 --output=avail "$1" 2>/dev/null | tail -n 1 | tr -d ' ' || true
}

dir_bytes() { # $1 dir -> du -sb apparent bytes, 0 when absent
  local bytes
  bytes="$(du -sb "$1" 2>/dev/null | cut -f1 || true)"
  echo "${bytes:-0}"
}

run_bytes() { # $1 run name -> apparent bytes of the run dir + sibling log
  local total log
  total="$(dir_bytes "$HS_RUNS_DIR/$1")"
  log="$HS_RUNS_DIR/$1.launcher.log"
  if [ -f "$log" ]; then
    total=$(( total + $(stat -c %s "$log" 2>/dev/null || echo 0) ))
  fi
  echo "$total"
}

acquire_lock() { # -> 1 when another retention run holds the lock
  if [ "$APPLY" = 1 ]; then
    mkdir -p "$HS_STATE_DIR"
    rm -rf "$TMP_DIR"   # stale temp artifacts from a crashed run (lock held)
    mkdir -p "$TMP_DIR"
    exec 9>>"$LOCK_FILE"
    flock -n 9 || return 1
  elif [ -f "$LOCK_FILE" ]; then
    exec 9>>"$LOCK_FILE"
    flock -n 9 || return 1
  fi
  return 0
}

session_active() {
  local state
  state="$($HS_SYSTEMCTL is-active hongscanner-session.service 2>/dev/null || true)"
  state="${state%%$'\n'*}"
  state="${state%%[[:space:]]*}"
  [ "$state" = "active" ] || [ "$state" = "activating" ]
}

# ------------------------------------------------------------- calendar

CALENDAR_STATUS="UNREAD"
RECENT_DAYS=""

load_calendar() {
  local out
  out="$(python3 - "$HS_CALENDAR_DIR" "$HS_CALENDAR_INDEX" \
    "$HS_RECENT_TRADING_DAYS" <<'PY'
import datetime, hashlib, json, os, sys
cal_dir, index_path, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
today = datetime.date.today().isoformat()

def unusable(reason):
    print("UNUSABLE " + reason)
    raise SystemExit(0)

try:
    with open(index_path, encoding="utf-8") as f:
        lines = [ln.split() for ln in f if ln.strip()]
except OSError:
    unusable("MISSING_INDEX")
days = {}
for parts in lines:
    if len(parts) != 2:
        unusable("BAD_INDEX_LINE")
    sha, rel = parts
    name = os.path.basename(rel)
    path = os.path.join(cal_dir, name)
    if not os.path.isfile(path):
        unusable("MISSING_FILE")
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
    except OSError:
        unusable("MISSING_FILE")
    if digest.hexdigest() != sha:
        unusable("MISMATCH")
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
        table = doc["days"]
    except (OSError, ValueError, KeyError, TypeError):
        unusable("BAD_JSON")
    if not isinstance(table, dict):
        unusable("BAD_JSON")
    for key, info in table.items():
        if isinstance(info, dict) and info.get("open") is not None:
            days[key] = True
        else:
            days.setdefault(key, False)
if not days:
    unusable("EMPTY")
keys = sorted(days)
if today < keys[0] or today > keys[-1]:
    unusable("TODAY_OUT_OF_SPAN")
recent = [k for k in keys if days[k] and k <= today]
if len(recent) < want:
    unusable("COVERAGE")
print("OK " + " ".join(recent[-want:]))
PY
  )" || CALENDAR_STATUS="PYTHON_ERROR"
  case "$out" in
    "UNUSABLE "*)
      CALENDAR_STATUS="${out#UNUSABLE }"
      ;;
    "OK "*)
      CALENDAR_STATUS="OK"
      RECENT_DAYS="${out#OK }"
      ;;
    "")
      [ "$CALENDAR_STATUS" = "UNREAD" ] && CALENDAR_STATUS="PYTHON_ERROR"
      ;;
    *)
      CALENDAR_STATUS="PYTHON_ERROR"
      ;;
  esac
}

# ------------------------------------------------------------ markers

marker_state() { # $1 run dir -> VALID | INVALID (marker file must exist)
  python3 - "$1" <<'PY'
import hashlib, json, sys
run = sys.argv[1]
try:
    with open(run + "/input.hcj.jsonl.committed", encoding="utf-8") as f:
        marker = json.load(f)
except (OSError, ValueError):
    print("INVALID")
    raise SystemExit(0)
if not isinstance(marker, dict) or \
        marker.get("schema") != "hong-scanner-commit/1":
    print("INVALID")
    raise SystemExit(0)
sha = marker.get("sha256")
if not isinstance(sha, str) or len(sha) != 64:
    print("INVALID")
    raise SystemExit(0)
digest = hashlib.sha256()
try:
    with open(run + "/input.hcj.jsonl", "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
except OSError:
    print("INVALID")
    raise SystemExit(0)
print("VALID" if digest.hexdigest() == sha else "INVALID")
PY
}

launcher_exit() { # $1 log path -> the last COLLECTOR_EXIT value or ""
  grep -o 'COLLECTOR_EXIT=[0-9]\+' "$1" 2>/dev/null | tail -n 1 \
    | cut -d= -f2 || true
}

has_end_line() { # $1 log path
  grep -qF '=== run_session end' "$1" 2>/dev/null
}

# ---------------------------------------------------------- grading

GRADE=""
REASON=""
MARKER_VALID=0

classify_run() { # $1 run name -> sets GRADE, REASON (판정표 v2, top-down)
  local name="$1" dir="$HS_RUNS_DIR/$name" log="$HS_RUNS_DIR/$name.launcher.log"
  GRADE=""; REASON=""; MARKER_VALID=0

  # 1. ACTIVE — the notify worker unit is up, or any file is younger than 26h
  if $HS_SYSTEMCTL is-active --quiet "hsnotify-$name" >/dev/null 2>&1; then
    GRADE=ACTIVE; REASON="hsnotify-$name unit active"
    return
  fi
  local cutoff newest
  cutoff=$(( $(now_epoch) - ACTIVE_MTIME_SECONDS ))
  newest="$(find "$dir" -type f -printf '%T@\n' 2>/dev/null | sort -rn \
    | head -n 1 || true)"
  if [ -n "$newest" ] && \
     awk -v n="$newest" -v c="$cutoff" 'BEGIN { exit !(n >= c) }'; then
    GRADE=ACTIVE; REASON="file mtime within 26h"
    return
  fi

  # 2. FAILED — honest INCOMPLETE (4) and real failures keep their evidence
  local exit_code=""
  if [ -f "$log" ]; then
    exit_code="$(launcher_exit "$log")"
  fi
  if [ -n "$exit_code" ] && [ "$exit_code" != "0" ]; then
    GRADE=FAILED; REASON="COLLECTOR_EXIT=$exit_code"
    return
  fi
  if [ -f "$dir/input.hcj.jsonl.committed" ]; then
    local state
    state="$(marker_state "$dir" 2>/dev/null || echo INVALID)"
    if [ "$state" != "VALID" ]; then
      GRADE=FAILED; REASON="commit marker INVALID (sha256 mismatch or schema)"
      return
    fi
    MARKER_VALID=1
  fi

  # 3. SERVICE_DEPENDENCY — git-external start scripts still reference it
  local script
  for script in "$HS_START_SCRIPTS_DIR"/hongscanner-*-start.sh; do
    if [ -f "$script" ] && grep -qF -- "$name" "$script" 2>/dev/null; then
      GRADE=SERVICE_DEPENDENCY; REASON="referenced by $(basename "$script")"
      return
    fi
  done

  # 4. GATES_REFERENCED — named in the evidence log (missing file: protect)
  if [ ! -f "$HS_GATES_FILE" ]; then
    GRADE=GATES_REFERENCED; REASON="gates file missing — every run protected"
    return
  fi
  if grep -qF -- "$name" "$HS_GATES_FILE" 2>/dev/null; then
    GRADE=GATES_REFERENCED; REASON="referenced in $(basename "$HS_GATES_FILE")"
    return
  fi

  # 5. RECENT_RAW — inside the calendar's recent trading-day window
  local run_date=""
  if [[ "$name" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    run_date="${BASH_REMATCH[1]}"
  fi
  if [ -z "$run_date" ]; then
    GRADE=UNKNOWN; REASON="no YYYY-MM-DD in run name"
    return
  fi
  if [ "$CALENDAR_STATUS" != "OK" ]; then
    GRADE=UNKNOWN; REASON="calendar unusable ($CALENDAR_STATUS) — protected"
    return
  fi
  if case " $RECENT_DAYS " in *" $run_date "*) true ;; *) false ;; esac; then
    GRADE=RECENT_RAW
    REASON="run date within the recent $HS_RECENT_TRADING_DAYS trading days"
    return
  fi

  # 6. UNKNOWN — missing evidence is never archivable
  if [ ! -f "$log" ]; then
    GRADE=UNKNOWN; REASON="no launcher log"
    return
  fi
  if ! has_end_line "$log"; then
    GRADE=UNKNOWN; REASON="launcher log has no run_session end line"
    return
  fi
  if [ "$MARKER_VALID" != "1" ]; then
    GRADE=UNKNOWN; REASON="no commit marker (smoke/replay-style run)"
    return
  fi

  # 7. ARCHIVE_ELIGIBLE — the sealed-COMMITTED and cleanly-ended intersection
  if [ "$exit_code" = "0" ]; then
    GRADE=ARCHIVE_ELIGIBLE; REASON="sealed COMMITTED marker VALID"
    return
  fi
  GRADE=UNKNOWN; REASON="unmet archive preconditions"
}

# ---------------------------------------------------------- archiving

archive_cleanup() { # $1 run name — temp artifacts only, never the original
  rm -f "$TMP_DIR/$1.manifest" "$TMP_DIR/$1.tar.zst"
  rm -rf "$TMP_DIR/$1.verify"
}

archive_run() { # $1 run name -> 0 archived, 1 deferred/failed (original kept)
  local name="$1" dir="$HS_RUNS_DIR/$name" log="$HS_RUNS_DIR/$name.launcher.log"
  local manifest="$TMP_DIR/$name.manifest" tgt="$TMP_DIR/$name.tar.zst"
  local vdir="$TMP_DIR/$name.verify"
  local bytes_before avail

  bytes_before="$(run_bytes "$name")"

  # a. df headroom: never fill the disk while making room (the compressed
  #    copy and the verification restore both land on the same partition)
  avail="$(df_avail "$HS_STATE_DIR")"
  if ! printf '%s' "$avail" | grep -Eq '^[0-9]+$' || \
     [ "$avail" -lt $(( bytes_before * 2 )) ]; then
    log_event ARCHIVE_DEFERRED run="$name" \
      reason="df avail ${avail:-unavailable} below 2x run bytes ($bytes_before)"
    echo "  DEFERRED $name: df avail ${avail:-unavailable} < 2x $bytes_before"
    return 1
  fi

  # b. SHA-256 manifest of every original file (run dir + sibling log)
  if ! (
    cd "$HS_RUNS_DIR"
    find "$name" -type f -print0 | sort -z | xargs -0 -r sha256sum
    if [ -f "$name.launcher.log" ]; then
      sha256sum "$name.launcher.log"
    fi
  ) > "$manifest"; then
    log_event ARCHIVE_FAILED run="$name" reason="manifest generation failed"
    echo "  FAILED $name: manifest generation (original kept)"
    archive_cleanup "$name"
    return 1
  fi

  # c. tar + zstd to the state tmp
  local members=("$name")
  if [ -f "$log" ]; then
    members+=("$name.launcher.log")
  fi
  if ! tar -C "$HS_RUNS_DIR" -c "${members[@]}" \
        | zstd -q -f -"$HS_ZSTD_LEVEL" -o "$tgt"; then
    log_event ARCHIVE_FAILED run="$name" reason="tar|zstd pipeline failed"
    echo "  FAILED $name: tar|zstd pipeline (original kept)"
    archive_cleanup "$name"
    return 1
  fi

  # d. integrity test of the compressed artifact
  if ! zstd -q -t "$tgt"; then
    log_event ARCHIVE_FAILED run="$name" reason="zstd -t failed"
    echo "  FAILED $name: zstd -t (original kept)"
    archive_cleanup "$name"
    return 1
  fi

  # e. restore to a fresh temp dir and prove byte identity
  rm -rf "$vdir"
  mkdir -p "$vdir"
  if ! tar --zstd -xf "$tgt" -C "$vdir"; then
    log_event ARCHIVE_FAILED run="$name" reason="verification restore failed"
    echo "  FAILED $name: verification restore (original kept)"
    archive_cleanup "$name"
    return 1
  fi
  if ! (cd "$vdir" && sha256sum --quiet -c "$manifest"); then
    log_event ARCHIVE_FAILED run="$name" reason="sha256 verification mismatch"
    echo "  FAILED $name: sha256 verification (original kept)"
    archive_cleanup "$name"
    return 1
  fi
  local count_orig count_rest
  count_orig="$(find "$dir" -type f | wc -l)"
  if [ -f "$log" ]; then
    count_orig=$(( count_orig + 1 ))
  fi
  count_rest="$(find "$vdir/$name" -type f | wc -l)"
  if [ -f "$vdir/$name.launcher.log" ]; then
    count_rest=$(( count_rest + 1 ))
  fi
  if [ "$count_orig" -ne "$count_rest" ]; then
    log_event ARCHIVE_FAILED run="$name" \
      reason="restored file count $count_rest != original $count_orig"
    echo "  FAILED $name: restored file count (original kept)"
    archive_cleanup "$name"
    return 1
  fi

  # f. move into the archive and record — never overwrite existing evidence
  if [ -e "$HS_ARCHIVE_DIR/$name.tar.zst" ]; then
    log_event ARCHIVE_DEFERRED run="$name" \
      reason="archive already exists — refusing to overwrite"
    echo "  DEFERRED $name: $HS_ARCHIVE_DIR/$name.tar.zst already exists"
    archive_cleanup "$name"
    return 1
  fi
  mkdir -p "$HS_ARCHIVE_DIR"
  local archive_sha bytes_after
  archive_sha="$(sha256sum "$tgt" | cut -d' ' -f1)"
  bytes_after="$(stat -c %s "$tgt")"
  mv "$tgt" "$HS_ARCHIVE_DIR/$name.tar.zst"
  log_event ARCHIVE run="$name" bytes_before="$bytes_before" \
    bytes_after="$bytes_after" archive_sha256="$archive_sha" \
    reason="sealed COMMITTED marker VALID"

  # g. only now remove the original (archive + log record are durable)
  rm -rf "$dir"
  rm -f "$log"
  archive_cleanup "$name"
  echo "  archived $name bytes_before=$bytes_before bytes_after=$bytes_after"
  return 0
}

# -------------------------------------------------------------- quota

archived_runs_from_log() { # names with a completed ARCHIVE record
  [ -f "$LOG_FILE" ] || return 0
  python3 - "$LOG_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get("action") == "ARCHIVE" and record.get("run"):
                print(record["run"])
except OSError:
    pass
PY
}

RETENTION_BLOCKED=0

quota_phase() {
  local usage quota="$HS_QUOTA_BYTES"
  usage=$(( $(dir_bytes "$HS_RUNS_DIR") + $(dir_bytes "$HS_ARCHIVE_DIR") ))
  if [ "$usage" -le "$quota" ]; then
    echo "quota usage=$usage quota=$quota status=OK"
    return 0
  fi

  local archived=() line path name
  while IFS= read -r line; do
    [ -n "$line" ] && archived+=("$line")
  done < <(archived_runs_from_log)

  if [ "$APPLY" = 0 ]; then
    local deletable=0
    while IFS= read -r path; do
      name="$(basename "$path" .tar.zst)"
      local known=0 entry
      for entry in "${archived[@]}"; do
        if [ "$entry" = "$name" ]; then
          known=1
          break
        fi
      done
      if [ "$known" = "1" ]; then
        deletable=$(( deletable + 1 ))
      fi
    done < <(find "$HS_ARCHIVE_DIR" -maxdepth 1 -name '*.tar.zst' \
               -type f -printf '%p\n' 2>/dev/null | sort)
    echo "quota usage=$usage quota=$quota status=OVER (dry-run: " \
         "$deletable verified archives deletable, oldest first)"
    return 0
  fi

  while [ "$usage" -gt "$quota" ]; do
    local victim="" victim_bytes=0
    while IFS= read -r line; do
      path="${line#* }"   # strip the %T@ mtime sort key
      name="$(basename "$path" .tar.zst)"
      local known=0 entry
      for entry in "${archived[@]}"; do
        if [ "$entry" = "$name" ]; then
          known=1
          break
        fi
      done
      if [ "$known" = "1" ]; then
        victim="$path"
        victim_bytes="$(stat -c %s "$path")"
        break
      fi
    done < <(find "$HS_ARCHIVE_DIR" -maxdepth 1 -name '*.tar.zst' \
               -type f -printf '%T@ %p\n' 2>/dev/null | sort -n)
    if [ -z "$victim" ]; then
      break
    fi
    log_event DELETE archive="$name" bytes="$victim_bytes" \
      reason="quota $quota exceeded — oldest verified archive first"
    rm -f "$victim"
    usage=$(( usage - victim_bytes ))
  done

  if [ "$usage" -gt "$quota" ]; then
    RETENTION_BLOCKED=1
    log_event RETENTION_BLOCKED usage="$usage" quota="$quota" \
      reason="over quota with no deletable verified archives left"
    echo "quota usage=$usage quota=$quota status=RETENTION_BLOCKED"
    local rc=0
    send_notify "홍스캐너 RETENTION_BLOCKED" \
      "runs+archive 사용량 ${usage}바이트가 쿼터 ${quota}바이트를 초과하고 제거 가능한 검증 아카이브가 없습니다. 수동 확인이 필요합니다." \
      || rc=$?
    log_event NOTIFY reason="RETENTION_BLOCKED" exit="$rc"
  else
    echo "quota usage=$usage quota=$quota status=OVER (oldest archives deleted)"
  fi
}

# ---------------------------------------------------------------- main

MODE="dry-run"
[ "$APPLY" = 1 ] && MODE="apply"
echo "retention mode=$MODE runs_dir=$HS_RUNS_DIR archive_dir=$HS_ARCHIVE_DIR"

if ! acquire_lock; then
  echo "retention: already running (lock held: $LOCK_FILE), exiting"
  exit 0
fi

if session_active; then
  echo "SKIPPED_ACTIVE_SESSION hongscanner-session.service is active/activating"
  log_event SKIPPED_ACTIVE_SESSION \
    reason="hongscanner-session.service active/activating — whole pass skipped"
  exit 0
fi

load_calendar
if [ "$CALENDAR_STATUS" != "OK" ]; then
  echo "calendar CALENDAR_UNUSABLE reason=$CALENDAR_STATUS — every run protected"
  log_event CALENDAR_UNUSABLE reason="$CALENDAR_STATUS"
else
  echo "calendar OK recent_trading_days=$HS_RECENT_TRADING_DAYS" \
       "window=$(printf '%s\n' "$RECENT_DAYS" | awk '{print $1".."$NF}')"
fi

C_ACTIVE=0; C_FAILED=0; C_SERVICE_DEPENDENCY=0; C_GATES_REFERENCED=0
C_RECENT_RAW=0; C_UNKNOWN=0; C_ARCHIVE_ELIGIBLE=0; C_TOTAL=0

echo "--- runs"
if [ -d "$HS_RUNS_DIR" ]; then
  shopt -s nullglob
  for dir in "$HS_RUNS_DIR"/*/; do
    name="$(basename "$dir")"
    classify_run "$name"
    C_TOTAL=$(( C_TOTAL + 1 ))
    case "$GRADE" in
      ACTIVE) C_ACTIVE=$(( C_ACTIVE + 1 )) ;;
      FAILED) C_FAILED=$(( C_FAILED + 1 )) ;;
      SERVICE_DEPENDENCY) C_SERVICE_DEPENDENCY=$(( C_SERVICE_DEPENDENCY + 1 )) ;;
      GATES_REFERENCED) C_GATES_REFERENCED=$(( C_GATES_REFERENCED + 1 )) ;;
      RECENT_RAW) C_RECENT_RAW=$(( C_RECENT_RAW + 1 )) ;;
      UNKNOWN) C_UNKNOWN=$(( C_UNKNOWN + 1 )) ;;
      ARCHIVE_ELIGIBLE) C_ARCHIVE_ELIGIBLE=$(( C_ARCHIVE_ELIGIBLE + 1 )) ;;
    esac
    action="keep"
    if [ "$GRADE" = "ARCHIVE_ELIGIBLE" ]; then
      action="archive"
    fi
    echo "run $name grade=$GRADE reason=$REASON bytes=$(run_bytes "$name") action=$action"
    if [ "$APPLY" = 1 ] && [ "$GRADE" = "ARCHIVE_ELIGIBLE" ]; then
      archive_run "$name" || true
    fi
  done
  shopt -u nullglob
fi

echo "summary total=$C_TOTAL active=$C_ACTIVE failed=$C_FAILED" \
     "service_dependency=$C_SERVICE_DEPENDENCY" \
     "gates_referenced=$C_GATES_REFERENCED recent_raw=$C_RECENT_RAW" \
     "unknown=$C_UNKNOWN archive_eligible=$C_ARCHIVE_ELIGIBLE"

avail="$(df_avail "$HS_RUNS_DIR")"
echo "df avail=${avail:-unavailable} path=$HS_RUNS_DIR"

quota_phase

exit 0
