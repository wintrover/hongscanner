#!/usr/bin/env bash
## Launcher ops-alert contract: fire the REAL tools/run_session.sh failure
## branches so the alert path is proven non-vacuous (S1 evidence).
##
## Why this exists: the 2026-11-19 production logs showed 0 OPS_ALERT
## lines only because no failure event happened — that zero proves
## nothing (docs/GATES.md, S1 "vacuous evidence"). PR #124's measurement
## was a manual, function-level check; this script pins the same contract
## in CI by forcing the actual failure branches.
##
## Alert sites exercised (tools/run_session.sh, read-only here):
##   - collector non-zero exit -> COLLECTOR_FAILED + send_ops_alert
##     (run_session.sh:341-346)
##   - storage preflight failure -> STORAGE_PREFLIGHT_FAILED + send_ops_alert
##     (run_session.sh:162-170; before any worker/systemd call)
##
## Scenarios:
##   (a) HS_NOTIFY_CMD unset: exactly 1 OPS_ALERT + 1
##       OPS_ALERT_SUPPRESSED reason=consumer_push_removed, and the
##       external alert-command marker stays empty.
##   (b) HS_NOTIFY_CMD set: exactly 1 invocation, title and body arrive
##       as positional arguments.
##   (c) the alert does not lead to a consumer-device path: fake
##       adb/curl/wget and any python run of notify_dispatcher.py /
##       notify_fcm.py / ops_alert.py leave zero markers; the worker
##       systemd lifecycle is byte-identical between alert and no-alert
##       runs (the alert adds no invocation); the preflight alert run
##       starts no systemd unit at all (literal zero).
##   (d) a normal (exit 0) run logs 0 OPS_ALERT lines.
##
## All fakes live in one private mktemp(1) sandbox. No real systemd unit,
## no real ~/.local/share/hongscanner, no network, no FCM send.
##
## Exit-status notes (GNU Bash manual): `-u` makes an expansion of an
## unset variable an error and a non-interactive shell exits; `exit n`
## returns n to the parent and "Any trap on `EXIT` is executed before the
## shell terminates." The launcher relies on both: it reads the
## collector's status right after `wait`, keeps ${HS_NOTIFY_CMD:-}
## default-safe under `set -u`, and exits with COLLECTOR_RC after its
## EXIT trap (stop_worker) runs. The assertions below prove the
## collector's 0/4 status survives that path.
##
## Run: bash tests/test_launcher_ops_alert.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SESSION="$REPO_ROOT/tools/run_session.sh"

PASS=0
FAILED=0

ok() { echo "ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}

assert_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    ok "$1"
  else
    bad "$1: [$3] not found"
  fi
}

count_lines() { # file -> line count (0 when the marker never appeared)
  if [ -f "$1" ]; then wc -l < "$1"; else echo 0; fi
}

count_matching() { # extended-regex file -> matching line count
  if [ -f "$2" ]; then grep -cE -- "$1" "$2" || true; else echo 0; fi
}

assert_count_eq() { # desc expected pattern file
  assert_eq "$1" "$2" "$(count_matching "$3" "$4")"
}

assert_marker_zero() { # desc marker file
  assert_eq "$1" 0 "$(count_lines "$2")"
}

assert_nonzero() { # desc marker file
  local n
  n="$(count_lines "$2")"
  if [ "$n" -gt 0 ]; then ok "$1 (n=$n)"; else bad "$1: marker is empty"; fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hs-launcher-alert.XXXXXX")"
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

STUB_BIN="$SANDBOX/bin"
MARKERS="$SANDBOX/markers"
RUNS="$SANDBOX/runs"
mkdir -p "$STUB_BIN" "$MARKERS" "$RUNS"
printf '{}\n' > "$SANDBOX/notify_config.json"

SYSTEMD_MARKER="$MARKERS/systemd.log"
CONSUMER_MARKER="$MARKERS/consumer.log"
PY_MARKER="$MARKERS/python.log"
NOTIFY_MARKER="$MARKERS/notify.log"
COLLECTOR_MARKER="$MARKERS/collector.log"
export SYSTEMD_MARKER CONSUMER_MARKER PY_MARKER NOTIFY_MARKER COLLECTOR_MARKER

reset_markers() {
  : > "$SYSTEMD_MARKER"
  : > "$CONSUMER_MARKER"
  : > "$PY_MARKER"
  : > "$NOTIFY_MARKER"
  : > "$COLLECTOR_MARKER"
}
reset_markers

# ---------------------------------------------------------------- fakes
# systemd-run: records the worker unit start; never executes the worker
# (the launcher's alert path is what this test isolates). Any FCM/push
# looking argument is a consumer-path tripwire.
cat > "$STUB_BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
unit=""
for a in "$@"; do
  case "$a" in --unit=*) unit="${a#--unit=}" ;; esac
done
printf 'systemd-run unit=%s\n' "$unit" >> "$SYSTEMD_MARKER"
case " $* " in
  *notify_fcm*|*fcm*|*FCM*|*push*)
    printf 'systemd-run %s\n' "$*" >> "$CONSUMER_MARKER" ;;
esac
exit 0
EOF

# systemctl: answers the launcher's lifecycle queries as an inactive,
# non-failed unit. Records every call so two runs can be compared.
cat > "$STUB_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$SYSTEMD_MARKER"
case " $* " in
  *notify_fcm*|*fcm*|*FCM*|*push*)
    printf 'systemctl %s\n' "$*" >> "$CONSUMER_MARKER" ;;
esac
case " $* " in
  *" is-active "*) exit 3 ;;
  *" is-failed "*) exit 1 ;;
  *" show "*) printf 'ActiveState=inactive\nExecMainStatus=0\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF

# Consumer-device / network tripwires. The launcher must never touch
# these on an alert; any call lands in the consumer marker.
cat > "$STUB_BIN/adb" <<'EOF'
#!/usr/bin/env bash
printf 'adb %s\n' "$*" >> "$CONSUMER_MARKER"
exit 0
EOF
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$CONSUMER_MARKER"
exit 0
EOF
cat > "$STUB_BIN/wget" <<'EOF'
#!/usr/bin/env bash
printf 'wget %s\n' "$*" >> "$CONSUMER_MARKER"
exit 0
EOF

# Interpreter spy: -c is run_session's _mono_stamp, delegated to the real
# python3; any attempt to run the dispatcher/FCM/ops_alert through it is
# a consumer-path tripwire.
cat > "$STUB_BIN/fake-python" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PY_MARKER"
for a in "$@"; do
  case "$a" in
    *notify_dispatcher.py*|*notify_fcm.py*|*ops_alert.py*)
      printf 'python %s\n' "$*" >> "$CONSUMER_MARKER"
      exit 0
      ;;
  esac
done
if [ "${1:-}" = "-c" ]; then exec python3 "$@"; fi
exit 0
EOF

cat > "$STUB_BIN/notify-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "$NOTIFY_MARKER"
exit 0
EOF

# The run dir belongs to the collector (O_EXCL, tools/run_session.sh
# wait_for_run_dir), and the launcher now starts the worker only after it
# exists. A fake collector that never creates it would make every run take
# the WORKER_SKIPPED path and hide the worker lifecycle this suite compares,
# so both fakes behave like the real one: create --out= first, then work.
cat > "$SANDBOX/collector-fail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COLLECTOR_MARKER"
for a in "$@"; do
  case "$a" in --out=*) mkdir -p "${a#--out=}" ;; esac
done
echo "fake collector: crashing on purpose" >&2
exit 4
EOF

cat > "$SANDBOX/collector-ok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COLLECTOR_MARKER"
for a in "$@"; do
  case "$a" in --out=*) mkdir -p "${a#--out=}" ;; esac
done
echo "fake collector: clean session end"
exit 0
EOF

chmod +x "$STUB_BIN"/* "$SANDBOX/collector-fail" "$SANDBOX/collector-ok"

# run_launcher OUT COLLECTOR [env args...]
#   Extra args go through `env` after the common fake environment, so a
#   scenario can pass HS_NOTIFY_CMD=... or -u HS_NOTIFY_CMD explicitly.
run_launcher() {
  local out="$1" collector="$2"
  shift 2
  local rc=0
  PATH="$STUB_BIN:$PATH" \
    HSNOTIFY_CONFIG="$SANDBOX/notify_config.json" \
    HSCOLLECTOR_BIN="$collector" \
    HSCOLLECTOR_PYTHON="$STUB_BIN/fake-python" \
    HS_WATCHDOG_INTERVAL=0 \
    HS_PREFLIGHT_MIN_AVAIL=0 \
    env "$@" bash "$RUN_SESSION" --out="$out" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# ------------------------------------------------------- (a) no override
echo "--- (a) HS_NOTIFY_CMD unset: record-only, no external alert command"
reset_markers
OUT_A="$RUNS/a/sess"
LOG_A="$OUT_A.launcher.log"
RC=0
run_launcher "$OUT_A" "$SANDBOX/collector-fail" -u HS_NOTIFY_CMD || RC=$?

assert_eq "(a) collector's exit 4 propagates through the launcher" 4 "$RC"
assert_contains "(a) failure event is in the log" "$(cat "$LOG_A")" \
  "COLLECTOR_FAILED exit=4 t0_observed=1"
assert_count_eq "(a) exactly 1 OPS_ALERT line" 1 '^OPS_ALERT ' "$LOG_A"
assert_count_eq "(a) exactly 1 OPS_ALERT_SUPPRESSED line" 1 \
  '^OPS_ALERT_SUPPRESSED reason=consumer_push_removed' "$LOG_A"
assert_marker_zero "(a) external alert command never ran" "$NOTIFY_MARKER"
assert_eq "(a) collector ran exactly once" 1 "$(count_lines "$COLLECTOR_MARKER")"
assert_marker_zero "(a) no consumer-device path" "$CONSUMER_MARKER"
cp "$SYSTEMD_MARKER" "$SANDBOX/systemd-a.log"
cp "$CONSUMER_MARKER" "$SANDBOX/consumer-a.log"
cp "$PY_MARKER" "$SANDBOX/python-a.log"

# --------------------------------------------------------- (b) override
echo "--- (b) HS_NOTIFY_CMD set: exactly one run, title/body arguments"
reset_markers
OUT_B="$RUNS/b/sess"
LOG_B="$OUT_B.launcher.log"
RC=0
run_launcher "$OUT_B" "$SANDBOX/collector-fail" \
  "HS_NOTIFY_CMD=$STUB_BIN/notify-stub" || RC=$?

assert_eq "(b) collector's exit 4 propagates" 4 "$RC"
assert_eq "(b) notify override ran exactly once" 1 "$(count_lines "$NOTIFY_MARKER")"
assert_eq "(b) title argument is the session-failure alert" \
  "홍스캐너 세션 장애 (sess)" "$(cut -f1 "$NOTIFY_MARKER")"
BODY_B="$(cut -f2 "$NOTIFY_MARKER")"
assert_contains "(b) body argument names the collector failure" \
  "$BODY_B" "수집기 비정상 종료 (exit=4"
assert_contains "(b) body argument carries the launcher log path" \
  "$BODY_B" "$LOG_B"
assert_count_eq "(b) the alert is still recorded once" 1 '^OPS_ALERT ' "$LOG_B"
assert_count_eq "(b) suppression is recorded once" 1 \
  '^OPS_ALERT_SUPPRESSED reason=consumer_push_removed' "$LOG_B"
assert_marker_zero "(b) no consumer-device path" "$CONSUMER_MARKER"
cp "$SYSTEMD_MARKER" "$SANDBOX/systemd-b.log"
cp "$CONSUMER_MARKER" "$SANDBOX/consumer-b.log"
cp "$PY_MARKER" "$SANDBOX/python-b.log"

# ------------------------------------------------------- (d) normal run
echo "--- (d) collector exit 0: the log distinguishes alert from no alert"
reset_markers
OUT_D="$RUNS/d/sess"
LOG_D="$OUT_D.launcher.log"
RC=0
run_launcher "$OUT_D" "$SANDBOX/collector-ok" -u HS_NOTIFY_CMD || RC=$?

assert_eq "(d) normal collector exit 0 propagates" 0 "$RC"
assert_count_eq "(d) 0 OPS_ALERT lines without a failure" 0 \
  '^OPS_ALERT ' "$LOG_D"
assert_count_eq "(d) 0 OPS_ALERT_SUPPRESSED lines without a failure" 0 \
  '^OPS_ALERT_SUPPRESSED' "$LOG_D"
assert_count_eq "(d) COLLECTOR_EXIT=0 recorded" 1 '^COLLECTOR_EXIT=0$' "$LOG_D"
assert_marker_zero "(d) external alert command never ran" "$NOTIFY_MARKER"
assert_marker_zero "(d) no consumer-device path" "$CONSUMER_MARKER"
cp "$SYSTEMD_MARKER" "$SANDBOX/systemd-d.log"
cp "$CONSUMER_MARKER" "$SANDBOX/consumer-d.log"
cp "$PY_MARKER" "$SANDBOX/python-d.log"

# ------------------------------------- (c) alert is not a consumer path
echo "--- (c) alert does not reach a consumer-device / FCM path"
assert_marker_zero "(c) alert run: no adb/curl/wget/notify-python call" \
  "$SANDBOX/consumer-a.log"
assert_marker_zero "(c) override run: no adb/curl/wget/notify-python call" \
  "$SANDBOX/consumer-b.log"
assert_marker_zero "(c) normal run: no adb/curl/wget/notify-python call" \
  "$SANDBOX/consumer-d.log"
assert_count_eq "(c) alert run: fake python never ran the dispatch/FCM tools" 0 \
  'notify_dispatcher\.py|notify_fcm\.py|ops_alert\.py' "$SANDBOX/python-a.log"
assert_count_eq "(c) override run: fake python never ran the dispatch/FCM tools" 0 \
  'notify_dispatcher\.py|notify_fcm\.py|ops_alert\.py' "$SANDBOX/python-b.log"
assert_count_eq "(c) no systemctl/systemd-run argument references FCM/push" 0 \
  'fcm|FCM|push' "$SANDBOX/systemd-a.log"

# The probe must be live (a worker unit really was started), and the
# alert run must not add any systemd invocation relative to the no-alert
# run — a push attempt would appear here as an extra call.
assert_nonzero "(c) worker lifecycle probe is live in the alert run" \
  "$SANDBOX/systemd-a.log"
assert_nonzero "(c) worker lifecycle probe is live in the normal run" \
  "$SANDBOX/systemd-d.log"
if cmp -s "$SANDBOX/systemd-a.log" "$SANDBOX/systemd-d.log"; then
  ok "(c) alert adds zero systemctl/systemd-run invocations (identical lifecycle)"
else
  bad "(c) alert and normal runs differ in systemd invocations"
  diff -u "$SANDBOX/systemd-d.log" "$SANDBOX/systemd-a.log" || true
fi
if cmp -s "$SANDBOX/systemd-a.log" "$SANDBOX/systemd-b.log"; then
  ok "(c) override alert adds zero systemctl/systemd-run invocations"
else
  bad "(c) override alert and no-alert runs differ in systemd invocations"
  diff -u "$SANDBOX/systemd-a.log" "$SANDBOX/systemd-b.log" || true
fi

# ------------------- (e) preflight alert starts nothing (literal zero)
echo "--- (e) preflight alert: no systemd unit is ever started"
reset_markers
OUT_E="$RUNS/e/sess-pf"
LOG_E="$OUT_E.launcher.log"
RC=0
run_launcher "$OUT_E" "$SANDBOX/collector-ok" -u HS_NOTIFY_CMD \
  HS_PREFLIGHT_MIN_AVAIL=9000000000000000000 || RC=$?

assert_eq "(e) failed preflight exits 2" 2 "$RC"
assert_contains "(e) STORAGE_PREFLIGHT_FAILED recorded" "$(cat "$LOG_E")" \
  "STORAGE_PREFLIGHT_FAILED"
assert_count_eq "(e) exactly 1 OPS_ALERT line" 1 '^OPS_ALERT ' "$LOG_E"
assert_count_eq "(e) exactly 1 OPS_ALERT_SUPPRESSED line" 1 \
  '^OPS_ALERT_SUPPRESSED reason=consumer_push_removed' "$LOG_E"
assert_marker_zero "(e) zero systemctl/systemd-run calls" "$SYSTEMD_MARKER"
assert_marker_zero "(e) external alert command never ran" "$NOTIFY_MARKER"
assert_marker_zero "(e) no consumer-device path" "$CONSUMER_MARKER"
assert_eq "(e) collector never started" 0 "$(count_lines "$COLLECTOR_MARKER")"

# ---------------------------------------------------------------- summary
echo ""
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]