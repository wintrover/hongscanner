#!/usr/bin/env bash
## Session launcher (tools/notify/README.md §11): ONE trading-day session
## = the collector (foreground, its args passed through verbatim) + the
## resident notification worker (notify_dispatcher.py --watch on the
## same run directory), started and stopped by THIS launcher, with the
## worker's process supervision delegated to systemd.
##
## Why a launcher: the worker must watch THIS session's
## <out>/events.hcj.jsonl, whose path only the session executor knows
## (a new file per trading day); no directory watcher, no global router.
##
## Process ownership (verified against systemd-run(1) and systemctl(1)):
##   - the worker runs as a TRANSIENT user unit (hsnotify-<session>) —
##     its parent is the service manager, NOT this launcher, so the
##     launcher MUST stop it explicitly (trap EXIT below). No --collect:
##     a failed unit keeps its exit status observable until reset-failed.
##   - Type=notify + WatchdogSec=30 + Restart=on-failure + RestartSec=2:
##     the worker signals sd_notify(3) READY=1 once its single-writer
##     locks are held and the watch loop begins, and WATCHDOG=1 on every
##     tick — so systemd restarts a crashed worker (full rescan +
##     event_id dedup = no duplicate push) AND a worker whose ticks
##     hang past the 30s watchdog. A worker that stops cleanly (SIGTERM
##     -> exit 0) is NOT restarted. StartLimit (10s/5) leaves a failed
##     unit for the session-end observation in the launcher log.
##   - the collector is this launcher's child and runs in the FOREGROUND
##     (via wait): when it exits — clean close, honest INCOMPLETE exit 4,
##     or a crash — the launcher stops the worker, records both exit
##     states and exits with the COLLECTOR's exit code.
##
## Evidence: runs/<session>.launcher.log (a SIBLING of the run dir, the
## drill convention — the run dir itself belongs to the collector's
## O_EXCL): collector stdout+stderr and final exit code (exit 4's reason
## text otherwise lives only on stderr), worker stdout+stderr (systemd
## StandardOutput=append), the unit's final ActiveState/ExecMainStatus.
##
## systemd is REQUIRED for operational status: if systemd-run --user is
## unavailable the launcher falls back to a plain background process and
## marks the run DEVELOPMENT MODE in the log — not an operational
## success (README §11).
##
## Usage:   tools/run_session.sh <collector args...>   (--out=DIR required)
## Env:     HSNOTIFY_CONFIG     notify config (default
##                              ~/.local/share/hongscanner/notify/notify_config.json)
##          HSCOLLECTOR_BIN     collector binary (default
##                              <repo>/tools/collector/collector)
##          HSCOLLECTOR_PYTHON  worker interpreter (default
##                              <repo>/tools/collector/.venv/bin/python)
##          HS_NOTIFY_CMD       preflight alert command override (the
##                              contract tests' stub; may carry
##                              arguments); unset = the ops side-channel
##                              default: ops_alert.py on the SAME Python
##                              3.13 interpreter as the worker
##          HS_PREFLIGHT_MIN_AVAIL  storage preflight threshold in bytes
##                              (default 21474836480 = 20 GiB)
## Exit:    the collector's exit code (0/4 per its README §8); 2 for
##          launcher usage errors or a failed storage preflight (nothing
##          started).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY_SCRIPT="$REPO/tools/notify/notify_dispatcher.py"
OPS_ALERT_SCRIPT="$REPO/tools/notify/ops_alert.py"

usage() {
  printf 'usage: tools/run_session.sh <collector args...>  (--out=DIR required)\n' >&2
}

# Same-boot monotonic stamp for alert lines (tools/notify/README.md §1
# "Time instrumentation"): mono_ns is comparable only within one boot_id,
# never across devices or boots. $PY is resolved (and validated) in the
# prerequisites section before any alert can be emitted.
_mono_stamp() {
  "$PY" -c 'import time; b=open("/proc/sys/kernel/random/boot_id").read().strip(); print("mono_ns=%d boot_id=%s" % (time.monotonic_ns(), b))'
}

# ------------------------------------------------------------- arguments
OUT=""
for arg in "$@"; do
  case "$arg" in
    --out=*) OUT="${arg#--out=}" ;;
  esac
done
if [ -z "$OUT" ] || [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

SESSION="$(basename "$OUT")"
case "$OUT" in
  /*) OUT_ABS="$OUT" ;;
  *)  OUT_ABS="$PWD/$OUT" ;;
esac
EVENTS_FILE="$OUT_ABS/events.hcj.jsonl"
LOG_DIR="$(dirname "$OUT_ABS")"
LAUNCHER_LOG="$LOG_DIR/$SESSION.launcher.log"
UNIT="hsnotify-$SESSION"

# ----------------------------------------------------------- prerequisites
NOTIFY_CONFIG="${HSNOTIFY_CONFIG:-$HOME/.local/share/hongscanner/notify/notify_config.json}"
COLLECTOR="${HSCOLLECTOR_BIN:-$REPO/tools/collector/collector}"
PY="${HSCOLLECTOR_PYTHON:-}"

if [ ! -f "$NOTIFY_CONFIG" ]; then
  echo "run_session: notify config not found: $NOTIFY_CONFIG" >&2
  exit 2
fi
if [ ! -x "$COLLECTOR" ]; then
  echo "run_session: collector not executable: $COLLECTOR" >&2
  exit 2
fi
if [ -z "$PY" ]; then
  if [ -x "$REPO/tools/collector/.venv/bin/python" ]; then
    PY="$REPO/tools/collector/.venv/bin/python"
  elif command -v python3.13 >/dev/null 2>&1; then
    PY="python3.13"
  elif command -v uv >/dev/null 2>&1; then
    PY="$(uv python find 3.13)" || PY=""
  fi
fi
if [ -z "$PY" ] || [ ! -x "$PY" ]; then
  echo "run_session: no Python 3.13 interpreter for the worker" >&2
  exit 2
fi

mkdir -p "$LOG_DIR"          # the run dir itself stays the collector's (O_EXCL)
touch "$LAUNCHER_LOG"

# ------------------------------------------------------------- ops alert
send_ops_alert() {
  local title="$1"
  local body="$2"
  local wall
  wall="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # T2 (the alert request), not T0: no t0_observed here.
  echo "OPS_ALERT title=$title body=$body $(_mono_stamp) wall=$wall" >> "$LAUNCHER_LOG"
  if [ -n "${HS_NOTIFY_CMD:-}" ]; then
    # shellcheck disable=SC2086 # the override command may carry arguments
    $HS_NOTIFY_CMD "$title" "$body" \
      >>"$LAUNCHER_LOG" 2>&1 || true
  else
    "$PY" "$OPS_ALERT_SCRIPT" --config "$NOTIFY_CONFIG" \
      "$title" "$body" >>"$LAUNCHER_LOG" 2>&1 || true
  fi
}

# ------------------------------------------------------ storage preflight
# docs/RETENTION.md (Storage Preflight): the session needs room for the
# day's raw input (observed ~4 GiB) plus sealed-copy/verify headroom
# (16 GiB) BEFORE the collector starts writing — a disk that fills
# mid-session is an unobserved outage. Fail-closed: avail below the
# threshold, or a df that cannot answer at all, stops the session with
# exit 2 before anything starts and alerts through the ops side-channel:
# $HS_NOTIFY_CMD when set (the contract tests' stub), else the default
# ops_alert.py below on the SAME Python 3.13 interpreter as the worker.
PREFLIGHT_MIN="${HS_PREFLIGHT_MIN_AVAIL:-21474836480}"
PREFLIGHT_AVAIL=""
PREFLIGHT_AVAIL="$(df -B1 --output=avail "$LOG_DIR" 2>/dev/null | tail -n 1 | tr -d ' ')" || true
if ! printf '%s' "$PREFLIGHT_AVAIL" | grep -Eq '^[0-9]+$' || \
   [ "$PREFLIGHT_AVAIL" -lt "$PREFLIGHT_MIN" ]; then
  {
    echo "STORAGE_PREFLIGHT_FAILED: avail=${PREFLIGHT_AVAIL:-unavailable} required=$PREFLIGHT_MIN"
  } >> "$LAUNCHER_LOG"
  echo "run_session: STORAGE_PREFLIGHT_FAILED: avail=${PREFLIGHT_AVAIL:-unavailable} required=$PREFLIGHT_MIN" >&2
  send_ops_alert "홍스캐너 STORAGE_PREFLIGHT_FAILED" \
    "세션 시작 저장공간 사전검증 실패: avail=${PREFLIGHT_AVAIL:-unavailable}바이트 required=$PREFLIGHT_MIN바이트"
  exit 2
fi
echo "PREFLIGHT_OK avail=$PREFLIGHT_AVAIL" >> "$LAUNCHER_LOG"

# --------------------------------------------------------- worker control
WORKER_MODE="none"
WORKER_PID=0
WORKER_STOPPED=0
WATCHDOG_PID=0
WATCHDOG_INTERVAL="${HS_WATCHDOG_INTERVAL:-15}"
STALL_TIMEOUT_SECONDS="${HS_STALL_TIMEOUT_SECONDS:-900}"

stop_watchdog() {
  if [ "$WATCHDOG_PID" != "0" ]; then
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=0
  fi
}

start_watchdog() {
  if ! printf '%s' "$WATCHDOG_INTERVAL" | grep -Eq '^[0-9]+$' || [ "$WATCHDOG_INTERVAL" -le 0 ]; then
    return 0
  fi
  (
    worker_alerted=0
    stall_alerted=0
    while true; do
      sleep "$WATCHDOG_INTERVAL" || break
      if [ "$WORKER_MODE" = "systemd" ] && [ "$worker_alerted" = "0" ]; then
        if systemctl --user is-failed --quiet "$UNIT" 2>/dev/null; then
          worker_alerted=1
          wall="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          echo "WORKER_UNIT_FAILED unit=$UNIT t0_observed=1 $(_mono_stamp) wall=$wall" >> "$LAUNCHER_LOG"
          send_ops_alert "홍스캐너 워커 장애 ($SESSION)" \
            "systemd 유닛 $UNIT 실패 감지 (로그: $LAUNCHER_LOG)"
        fi
      fi
      if printf '%s' "$STALL_TIMEOUT_SECONDS" | grep -Eq '^[0-9]+$' && \
         [ "$STALL_TIMEOUT_SECONDS" -gt 0 ] && [ "$stall_alerted" = "0" ]; then
        now_s="$(date +%s)"
        latest_s=0
        for p in "$LAUNCHER_LOG" "$OUT_ABS/input.hcj.jsonl" "$EVENTS_FILE"; do
          if [ -e "$p" ]; then
            m="$(stat -c %Y "$p" 2>/dev/null || echo 0)"
            if [ "$m" -gt "$latest_s" ]; then
              latest_s="$m"
            fi
          fi
        done
        if [ "$latest_s" -gt 0 ] && [ $((now_s - latest_s)) -ge "$STALL_TIMEOUT_SECONDS" ]; then
          stall_alerted=1
          idle_s=$((now_s - latest_s))
          wall="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          echo "SESSION_STALL_DETECTED idle_seconds=$idle_s threshold=$STALL_TIMEOUT_SECONDS t0_observed=1 $(_mono_stamp) wall=$wall" >> "$LAUNCHER_LOG"
          send_ops_alert "홍스캐너 세션 무응답 ($SESSION)" \
            "세션 $SESSION 에서 ${idle_s}초 동안 신규 기록이 없습니다"
        fi
      fi
    done
  ) &
  WATCHDOG_PID=$!
}

stop_worker() {
  stop_watchdog
  if [ "$WORKER_STOPPED" = "1" ]; then return 0; fi
  WORKER_STOPPED=1
  if [ "$WORKER_MODE" = "systemd" ]; then
    local pre_failed=0
    if systemctl --user is-failed --quiet "$UNIT" 2>/dev/null; then
      pre_failed=1
    fi
    systemctl --user stop "$UNIT" >>"$LAUNCHER_LOG" 2>&1 || true
    local state
    state="$(systemctl --user show "$UNIT" \
               --property=ActiveState --property=ExecMainStatus \
               2>/dev/null | tr '\n' ' ')"
    echo "WORKER_UNIT $UNIT ${state:-state=<unloaded>}" >>"$LAUNCHER_LOG"
    if [ "$pre_failed" = "1" ] && ! grep -qF "WORKER_UNIT_FAILED unit=$UNIT" "$LAUNCHER_LOG" 2>/dev/null; then
      local wall
      wall="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "WORKER_UNIT_FAILED unit=$UNIT t0_observed=1 $(_mono_stamp) wall=$wall" >> "$LAUNCHER_LOG"
      send_ops_alert "홍스캐너 워커 장애 ($SESSION)" \
        "systemd 유닛 $UNIT 실패 상태로 종료됨 ($state)"
    fi
    systemctl --user reset-failed "$UNIT" 2>/dev/null || true
  elif [ "$WORKER_PID" != "0" ]; then
    kill -TERM "$WORKER_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 100); do
      kill -0 "$WORKER_PID" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$WORKER_PID" 2>/dev/null; then
      kill -9 "$WORKER_PID" 2>/dev/null || true
      echo "WORKER_BACKGROUND fell back to SIGKILL after 10s" \
        >>"$LAUNCHER_LOG"
    fi
    wait "$WORKER_PID" 2>/dev/null
    echo "WORKER_BACKGROUND_EXIT=$?" >>"$LAUNCHER_LOG"
  fi
}
trap stop_worker EXIT

start_worker() {
  if command -v systemd-run >/dev/null 2>&1; then
    if systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
      echo "run_session: unit $UNIT is already active (another session" \
        "with the same run dir name?)" >&2
      echo "WORKER_REFUSED unit $UNIT already active" >>"$LAUNCHER_LOG"
      exit 2
    fi
  fi
  systemctl --user reset-failed "$UNIT" 2>>"$LAUNCHER_LOG" || true
  if command -v systemd-run >/dev/null 2>&1 && \
     systemd-run --user --unit="$UNIT" \
       --property=Type=notify \
       --property=WatchdogSec=30 \
       --property=Restart=on-failure \
       --property=RestartSec=2 \
       --property=StandardOutput=append:"$LAUNCHER_LOG" \
       --property=StandardError=append:"$LAUNCHER_LOG" \
       "$PY" "$NOTIFY_SCRIPT" --config "$NOTIFY_CONFIG" \
       --run-dir "$OUT_ABS" \
       --watch "$EVENTS_FILE" >>"$LAUNCHER_LOG" 2>&1; then
    WORKER_MODE="systemd"
    echo "WORKER_START systemd unit=$UNIT (Type=notify, WatchdogSec=30, Restart=on-failure)" \
      >>"$LAUNCHER_LOG"
  else
    # Development-mode fallback (README §11): loses the auto-restart.
    WORKER_MODE="background"
    echo "WORKER_START background FALLBACK (development mode — NOT an" \
      "operational run: no auto-restart, README §11)" >>"$LAUNCHER_LOG"
    "$PY" "$NOTIFY_SCRIPT" --config "$NOTIFY_CONFIG" \
      --run-dir "$OUT_ABS" \
      --watch "$EVENTS_FILE" >>"$LAUNCHER_LOG" 2>&1 &
    WORKER_PID=$!
  fi
}

# ------------------------------------------------------------------- run
{
  echo "=== run_session start $(date --iso-8601=seconds)"
  echo "collector=$COLLECTOR"
  echo "worker=$NOTIFY_SCRIPT --config $NOTIFY_CONFIG --run-dir $OUT_ABS --watch $EVENTS_FILE"
  echo "log=$LAUNCHER_LOG"
} >>"$LAUNCHER_LOG"

start_worker

"$COLLECTOR" "$@" >>"$LAUNCHER_LOG" 2>&1 &
COLLECTOR_PID=$!
start_watchdog
trap 'kill -TERM "$COLLECTOR_PID" 2>/dev/null || true' INT TERM

COLLECTOR_RC=0
while true; do
  wait "$COLLECTOR_PID"
  rc=$?
  if kill -0 "$COLLECTOR_PID" 2>/dev/null; then
    # The wait was interrupted by a signal (our trap ran and forwarded
    # TERM); the collector still lives — keep waiting for its real code.
    continue
  fi
  COLLECTOR_RC=$rc
  break
done

stop_watchdog
echo "COLLECTOR_EXIT=$COLLECTOR_RC" >>"$LAUNCHER_LOG"
if [ "$COLLECTOR_RC" -ne 0 ]; then
  wall="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "COLLECTOR_FAILED exit=$COLLECTOR_RC t0_observed=1 $(_mono_stamp) wall=$wall" >>"$LAUNCHER_LOG"
  send_ops_alert "홍스캐너 세션 장애 ($SESSION)" \
    "수집기 비정상 종료 (exit=$COLLECTOR_RC, 로그: $LAUNCHER_LOG)"
fi

# Bounded tail drain (best effort, NOT a delivery guarantee): events
# appended in the collector's final seconds — the close protocol's
# SESSION_ENDED / SESSION_INCOMPLETE among them — otherwise race the
# worker's next tick against this launcher's stop. A few seconds of
# ticks close that window; the events file remains the authority
# either way (the ledger is derivable evidence).
sleep 3
stop_worker
echo "=== run_session end $(date --iso-8601=seconds) exit=$COLLECTOR_RC" \
  >>"$LAUNCHER_LOG"
exit "$COLLECTOR_RC"
