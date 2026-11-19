#!/usr/bin/env bash
## Launcher worker-start ordering contract tests (tools/run_session.sh).
##
## Regression guard for the 2026-11-19 incident: the launcher started the
## notification worker BEFORE the collector, so the worker's transient
## systemd unit was created while the collector's run dir (the collector
## creates it with O_EXCL) did not exist yet. notify_dispatcher.py refused
## the start ("--run-dir is not a directory"), systemd-run failed, the
## launcher fell back to a background worker, and the failed transient
## unit's Restart=on-failure kept restarting it (NRestarts=2738 over 96
## minutes of single-writer lock collisions). The leftover hsnotify-* unit
## also kept tools/runs_retention.sh grading the run ACTIVE forever.
##
## Every scenario drives the REAL tools/run_session.sh inside a private
## mktemp(1) sandbox: fake systemctl / systemd-run / df on PATH, a fake
## collector, and a fake worker interpreter. No real systemd, no real
## session run dir and no real notify config is ever touched.
##
## Scenarios:
##   (a) the run dir appears 1s after the collector starts -> the worker
##       starts AFTER it exists, as WORKER_START systemd (not fallback);
##       the fake systemd-run records the call time and that the run dir
##       was already present.
##   (b) systemd-run fails -> WORKER_START background FALLBACK, and the
##       fake systemctl observed stop of the failed unit (crash-loop
##       cleanup before the fallback, plus the fallback stop_worker pass
##       while the unit is still live).
##   (c) HS_WORKER_RUN_DIR_WAIT_SECONDS=1 with a collector that never
##       creates the dir -> WORKER_SKIPPED run_dir_missing seconds=1, no
##       unit is started, and the session still ends with the collector's
##       exit code.
##   (d) the run dir already exists -> no wait, the worker starts at once
##       even with a 0s wait bound.
##   (e) the collector dies before creating the dir -> the wait aborts
##       around the collector's death instead of running the full bound.
##
## Every scenario also asserts the launcher's RUN_PROVENANCE line — the
## launcher's own execution identity (session date, repo HEAD, launcher
## sha256, dirty flag, start time). Scenario (a) passes
## --session-date=2026-11-20; the others assert session_date=unknown.
##
## Run: bash tests/test_launcher_worker_order.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAILED=0

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: expected [$2] got [$3]"; FAILED=$((FAILED + 1))
  fi
}

assert_lt() { # desc a b  (numeric, a < b)
  if [ -n "$2" ] && [ -n "$3" ] && [ "$2" -lt "$3" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: expected [$2] < [$3]"; FAILED=$((FAILED + 1))
  fi
}

assert_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: [$2] does not contain [$3]"; FAILED=$((FAILED + 1))
  fi
}

assert_not_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "FAIL $1: [$3] unexpectedly present"; FAILED=$((FAILED + 1))
  else
    echo "ok   $1"; PASS=$((PASS + 1))
  fi
}

assert_file() { # desc path
  if [ -e "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: $2 is gone"; FAILED=$((FAILED + 1))
  fi
}

assert_no_file() { # desc path
  if [ ! -e "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: $2 still exists"; FAILED=$((FAILED + 1))
  fi
}

assert_nonempty() { # desc value
  if [ -n "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: value is empty"; FAILED=$((FAILED + 1))
  fi
}

assert_match() { # desc value extended-regex
  if printf '%s' "$2" | grep -Eq -- "$3"; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: [$2] does not match [$3]"; FAILED=$((FAILED + 1))
  fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hs-launcher-order.XXXXXX")"
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

RUN_SESSION="$REPO_ROOT/tools/run_session.sh"

file_text() { cat "$1" 2>/dev/null || true; }

# field_value <line> <key> — the value of key= in a space-separated line.
field_value() {
  local kv
  for kv in $1; do
    case "$kv" in
      "$2="*) printf '%s' "${kv#"$2="}" ;;
    esac
  done
}

# assert_provenance <scenario> <log> [expected session_date]
assert_provenance() {
  local desc="$1" log="$2" want_date="${3:-}"
  local line count key
  count="$(printf '%s\n' "$log" | grep -c '^RUN_PROVENANCE ' || true)"
  assert_eq "$desc: exactly one RUN_PROVENANCE line" 1 "$count"
  line="$(printf '%s\n' "$log" | grep '^RUN_PROVENANCE ' | head -n 1 || true)"
  for key in run_id session_date git_commit launcher_sha256 git_dirty started_at; do
    assert_nonempty "$desc: RUN_PROVENANCE $key" "$(field_value "$line" "$key")"
  done
  assert_eq "$desc: git_commit is the repo HEAD" \
    "$(git -C "$REPO_ROOT" rev-parse HEAD)" \
    "$(field_value "$line" git_commit)"
  assert_eq "$desc: launcher_sha256 is the launcher file's hash" \
    "$(sha256sum "$REPO_ROOT/tools/run_session.sh" | cut -d' ' -f1)" \
    "$(field_value "$line" launcher_sha256)"
  assert_match "$desc: git_dirty is 0 or 1" \
    "$(field_value "$line" git_dirty)" '^[01]$'
  assert_match "$desc: started_at is ISO-8601 with a local offset" \
    "$(field_value "$line" started_at)" \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$'
  if [ -n "$want_date" ]; then
    assert_eq "$desc: session_date is the passed --session-date" \
      "$want_date" "$(field_value "$line" session_date)"
  else
    assert_eq "$desc: session_date is unknown without --session-date" \
      "unknown" "$(field_value "$line" session_date)"
  fi
}

# new_env <name> — fresh fake bin/ + notify config + collectors under
# $W. Nothing outside the sandbox is read or written.
new_env() {
  W="$SANDBOX/$1"
  mkdir -p "$W/bin" "$W/out"
  printf '{}\n' > "$W/notify-config.json"

  # The launcher's storage preflight must pass without asking the real df.
  cat > "$W/bin/df" <<'EOF'
#!/usr/bin/env bash
echo 32212254720
EOF

  # Fake systemctl: never talks to a real manager. is-active says inactive
  # (the launcher's "another session?" pre-check), is-failed follows
  # STUB_IS_FAILED, stop/reset-failed are recorded and succeed.
  cat > "$W/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$SYSTEMCTL_LOG"
case " $* " in
  *" is-active "*) exit 3 ;;
  *" is-failed "*)
    if [ "${STUB_IS_FAILED:-0}" = "1" ]; then exit 0; else exit 1; fi
    ;;
  *" show "*) printf 'ActiveState=inactive\nExecMainStatus=0\n' ;;
esac
exit 0
EOF

  # Fake systemd-run: records invocation time, whether the run dir already
  # existed, and its arguments; fails when STUB_SYSTEMD_RUN_RC is non-zero.
  cat > "$W/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd_run nanos=%s dir=%s args=%s\n' \
  "$(date +%s%N)" \
  "$([ -d "$FAKE_RUN_DIR" ] && printf present || printf absent)" \
  "$*" >> "$SYSTEMD_RUN_LOG"
exit "${STUB_SYSTEMD_RUN_RC:-0}"
EOF

  # Fake worker interpreter: logs its arguments; -c (the launcher's
  # _mono_stamp) runs the real python3, the watch loop becomes a sleeper
  # the launcher can stop.
  cat > "$W/py" <<'EOF'
#!/usr/bin/env bash
printf 'python %s\n' "$*" >> "$PY_LOG"
if [ "$1" = "-c" ]; then exec python3 "$@"; fi
exec sleep 300
EOF

  # Collector that creates the run dir only after STUB_DIR_DELAY seconds.
  cat > "$W/collector-late" <<'EOF'
#!/usr/bin/env bash
sleep "${STUB_DIR_DELAY:-1}"
mkdir -p "$FAKE_RUN_DIR"
touch "$FAKE_RUN_DIR/events.hcj.jsonl"
printf 'dir_created nanos=%s\n' "$(date +%s%N)" > "$DIR_CREATED_LOG"
sleep "${STUB_COLLECTOR_TAIL:-1}"
exit 0
EOF

  # Collector that creates the run dir immediately (the normal case).
  cat > "$W/collector-now" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$FAKE_RUN_DIR"
touch "$FAKE_RUN_DIR/events.hcj.jsonl"
sleep "${STUB_COLLECTOR_TAIL:-1}"
exit 0
EOF

  # Collector that never creates the run dir, then exits cleanly.
  cat > "$W/collector-nodir" <<'EOF'
#!/usr/bin/env bash
sleep "${STUB_COLLECTOR_TAIL:-2}"
exit 0
EOF

  # Collector that dies immediately without creating the run dir.
  cat > "$W/collector-dead" <<'EOF'
#!/usr/bin/env bash
exit 4
EOF

  chmod +x "$W/bin/df" "$W/bin/systemctl" "$W/bin/systemd-run" \
    "$W/py" "$W/collector-late" "$W/collector-now" \
    "$W/collector-nodir" "$W/collector-dead"
}

# run_launcher <session> <collector> [--session-date=DATE] [VAR=VAL...]
# — sets RC. A leading --session-date= goes to the launcher itself; every
# remaining extra argument goes through env.
run_launcher() {
  local name="$1" collector="$2"
  shift 2
  local date_arg=""
  case "${1:-}" in
    --session-date=*) date_arg="$1"; shift ;;
  esac
  RC=0
  env PATH="$W/bin:$PATH" \
    HSNOTIFY_CONFIG="$W/notify-config.json" \
    HSCOLLECTOR_BIN="$W/$collector" \
    HSCOLLECTOR_PYTHON="$W/py" \
    HS_WATCHDOG_INTERVAL=0 \
    FAKE_RUN_DIR="$W/out/$name" \
    SYSTEMCTL_LOG="$W/systemctl.log" \
    SYSTEMD_RUN_LOG="$W/systemd-run.log" \
    DIR_CREATED_LOG="$W/dir-created.log" \
    PY_LOG="$W/py.log" \
    "$@" \
    bash "$RUN_SESSION" --out="$W/out/$name" ${date_arg:+"$date_arg"} \
    >/dev/null 2>&1 || RC=$?
}

# ============================================ (a) run dir appears late

echo "--- (a) run dir created 1s after the collector starts"
new_env a
run_launcher sess-a collector-late --session-date=2026-11-20
LOG_A="$(file_text "$W/out/sess-a.launcher.log")"
assert_provenance "a" "$LOG_A" 2026-11-20
assert_eq "a: session exits with the collector's exit code" 0 "$RC"
assert_contains "a: worker start is the systemd one" "$LOG_A" \
  "WORKER_START systemd unit=hsnotify-sess-a"
assert_not_contains "a: no development-mode fallback" "$LOG_A" \
  "WORKER_START background FALLBACK"
assert_not_contains "a: no WORKER_SKIPPED line" "$LOG_A" "WORKER_SKIPPED"
assert_file "a: fake systemd-run was invoked" "$W/systemd-run.log"
assert_contains "a: the run dir existed when the worker started" \
  "$(file_text "$W/systemd-run.log")" "dir=present"
DIR_NS="$(sed -n 's/^dir_created nanos=\([0-9][0-9]*\)$/\1/p' \
  "$W/dir-created.log" 2>/dev/null || true)"
RUN_NS="$(sed -n 's/^systemd_run nanos=\([0-9][0-9]*\) dir=.*$/\1/p' \
  "$W/systemd-run.log" 2>/dev/null || true)"
assert_lt "a: worker start followed the run dir creation" \
  "$DIR_NS" "$RUN_NS"
assert_contains "a: the worker was pointed at the events file" \
  "$(file_text "$W/systemd-run.log")" \
  "--watch $W/out/sess-a/events.hcj.jsonl"

# ============================================ (b) systemd-run failure

echo "--- (b) systemd-run fails: fallback after stopping the failed unit"
new_env b
run_launcher sess-b collector-now STUB_SYSTEMD_RUN_RC=1 STUB_IS_FAILED=1
LOG_B="$(file_text "$W/out/sess-b.launcher.log")"
SYSCTL_B="$(file_text "$W/systemctl.log")"
assert_provenance "b" "$LOG_B"
assert_eq "b: session exits with the collector's exit code" 0 "$RC"
assert_contains "b: fallback line recorded" "$LOG_B" \
  "WORKER_START background FALLBACK"
assert_not_contains "b: no systemd worker start line" "$LOG_B" \
  "WORKER_START systemd"
assert_contains "b: the failed unit was stopped for this run" \
  "$SYSCTL_B" "stop hsnotify-sess-b"
assert_contains "b: reset-failed was issued for the unit" \
  "$SYSCTL_B" "reset-failed hsnotify-sess-b"
assert_contains "b: the fallback stop_worker pass recorded its cleanup" \
  "$LOG_B" "WORKER_UNIT_STOPPED unit=hsnotify-sess-b mode=background"
assert_contains "b: background worker exit still recorded" "$LOG_B" \
  "WORKER_BACKGROUND_EXIT="
assert_contains "b: the fallback dispatcher was started" \
  "$(file_text "$W/py.log")" "notify_dispatcher.py"

# ============================== (c) run dir never appears (timeout)

echo "--- (c) run dir never appears: bounded wait, worker skipped"
new_env c
run_launcher sess-c collector-nodir HS_WORKER_RUN_DIR_WAIT_SECONDS=1
LOG_C="$(file_text "$W/out/sess-c.launcher.log")"
assert_provenance "c" "$LOG_C"
assert_eq "c: session still exits with the collector's exit code" 0 "$RC"
assert_contains "c: the skip line records the bound" "$LOG_C" \
  "WORKER_SKIPPED run_dir_missing seconds=1"
assert_not_contains "c: no worker start line" "$LOG_C" "WORKER_START"
assert_no_file "c: systemd-run was never invoked" "$W/systemd-run.log"
assert_contains "c: the session still ended normally" "$LOG_C" \
  "=== run_session end"
assert_contains "c: collector exit still recorded" "$LOG_C" \
  "COLLECTOR_EXIT=0"

# ================================== (d) run dir already present

echo "--- (d) run dir already present: no wait"
new_env d
mkdir -p "$W/out/sess-d"
run_launcher sess-d collector-now HS_WORKER_RUN_DIR_WAIT_SECONDS=0
LOG_D="$(file_text "$W/out/sess-d.launcher.log")"
assert_provenance "d" "$LOG_D"
assert_eq "d: session exits with the collector's exit code" 0 "$RC"
assert_contains "d: worker started via systemd" "$LOG_D" \
  "WORKER_START systemd unit=hsnotify-sess-d"
assert_not_contains "d: no WORKER_SKIPPED line" "$LOG_D" "WORKER_SKIPPED"
assert_contains "d: the run dir was present at worker start" \
  "$(file_text "$W/systemd-run.log")" "dir=present"

# ============================ (e) collector dies before the dir exists

echo "--- (e) collector dies before creating the dir: wait aborts"
new_env e
T0="$(date +%s)"
run_launcher sess-e collector-dead
T1="$(date +%s)"
LOG_E="$(file_text "$W/out/sess-e.launcher.log")"
assert_provenance "e" "$LOG_E"
assert_eq "e: session exits with the collector's 4" 4 "$RC"
assert_contains "e: the skip line records the dead collector" "$LOG_E" \
  "WORKER_SKIPPED run_dir_missing seconds=0 collector_dead=1"
assert_not_contains "e: no worker start line" "$LOG_E" "WORKER_START"
assert_no_file "e: systemd-run was never invoked" "$W/systemd-run.log"
assert_lt "e: the wait did not run the full 60s bound" "$((T1 - T0))" 15

# ---------------------------------------------------------------- summary
echo ""
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]