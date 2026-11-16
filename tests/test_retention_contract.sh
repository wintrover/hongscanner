#!/usr/bin/env bash
## Retention + storage-preflight contract tests (docs/RETENTION.md).
##
## Drives the REAL tools/runs_retention.sh and the REAL storage preflight
## inside tools/run_session.sh against fully synthetic workspaces: fake
## runs (dummy input.hcj.jsonl + conditional .committed marker +
## conditional launcher log), a synthetic KRX calendar (recent trading-day
## window including today), stub systemctl (HS_SYSTEMCTL), stub notify
## (HS_NOTIFY_CMD), a failing fake zstd, and a fake df. No live FCM, no
## systemd, no real runs/ directory is ever touched — every workspace is a
## private mktemp sandbox the script removes itself.
##
## Coverage — the docs/RETENTION.md test table, all 14 rows:
##   1  ACTIVE (recent mtime)             -> protected, original kept
##   2  COLLECTOR_EXIT=4 (honest INCOMPLETE) -> FAILED, protected
##   3  GATES-referenced run              -> protected
##   4  start-script-referenced run       -> SERVICE_DEPENDENCY, protected
##   5  inside the recent 20 trading days -> RECENT_RAW, protected
##   6  no launcher log                   -> UNKNOWN, protected
##   7  launcher log without end line     -> UNKNOWN, protected
##   8  INVALID marker (sha256 mismatch)  -> FAILED, protected
##   9  sealed+clean+outside window       -> dry-run ARCHIVE_ELIGIBLE;
##      --apply archives (.tar.zst exists, original removed, JSONL ARCHIVE
##      record, tar --zstd restore proves byte identity)
##   10 compress failure (fake zstd)      -> original kept
##   11 quota exceeded                    -> oldest verified archives
##      deleted first (logged), then RETENTION_BLOCKED + notify observed
##   12 active session                    -> SKIPPED_ACTIVE_SESSION,
##      runs/ untouched
##   13 dry-run default                   -> zero filesystem change
##   14 storage preflight                 -> (a) enough avail: exit 0 +
##      PREFLIGHT_OK, (b) not enough / df fails: exit 2 +
##      STORAGE_PREFLIGHT_FAILED + notify observed
##
## Run: bash tests/test_retention_contract.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAILED=0

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: expected [$2] got [$3]"; FAILED=$((FAILED + 1))
  fi
}

assert_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: [$3] not found"; FAILED=$((FAILED + 1))
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

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hs-retention-test.XXXXXX")"
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

RETENTION="$REPO_ROOT/tools/runs_retention.sh"
RUN_SESSION="$REPO_ROOT/tools/run_session.sh"

# ------------------------------------------------------------ stub tools

make_systemctl_stub() { # $1 dir — HS_SYSTEMCTL target
  cat > "$1/systemctl-stub" <<'EOF'
#!/usr/bin/env bash
# HS_SYSTEMCTL stub (docs/RETENTION.md tests): fixed states from env
# knobs. STUB_SESSION_STATE: what "is-active hongscanner-session.service"
# reports; STUB_HSNOTIFY_ACTIVE: space-separated active hsnotify units.
case " $* " in
  *" is-active "*)
    quiet=0
    for arg in "$@"; do
      [ "$arg" = "--quiet" ] && quiet=1
    done
    for arg in "$@"; do
      case "$arg" in
        hongscanner-session.service)
          echo "${STUB_SESSION_STATE:-inactive}"
          case "${STUB_SESSION_STATE:-inactive}" in
            active|activating) exit 0 ;;
            *) exit 3 ;;
          esac
          ;;
        hsnotify-*)
          case " ${STUB_HSNOTIFY_ACTIVE:-} " in
            *" $arg "*)
              [ "$quiet" = 1 ] || echo active
              exit 0
              ;;
          esac
          [ "$quiet" = 1 ] || echo inactive
          exit 3
          ;;
      esac
    done
    echo inactive
    exit 3
    ;;
esac
exit 0
EOF
  chmod +x "$1/systemctl-stub"
}

make_notify_stub() { # $1 dir $2 record file
  cat > "$1/notify-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2"
exit 0
EOF
  chmod +x "$1/notify-stub"
}

# ------------------------------------------------------- workspace builder

# make_calendar <dir> — synthetic KRX calendar: 60 days back .. +7, every
# day a key (weekends/holidays open=null), weekdays open. Prints
# "<window_start> <old_date>" for run naming (window_start = the oldest of
# the recent 20 trading days, old_date = today-45d, well outside it).
make_calendar() { # $1 calendar dir — writes krx-test.json + INDEX
  python3 - "$1" <<'PY'
import datetime, hashlib, json, os, sys
cal_dir = sys.argv[1]
today = datetime.date.today()
days = {}
for i in range(-60, 8):
    day = today + datetime.timedelta(days=i)
    days[day.isoformat()] = (
        {"open": "09:00:00+09:00", "close": "15:30:00+09:00"}
        if day.weekday() < 5 else {"open": None})
name = "krx-test.json"
path = os.path.join(cal_dir, name)
with open(path, "w", encoding="utf-8") as f:
    json.dump({"days": days, "version": "CAL-TEST"}, f, sort_keys=True,
              separators=(",", ":"))
sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
with open(os.path.join(cal_dir, "CALENDAR_INDEX.sha256"), "w",
          encoding="utf-8") as f:
    f.write("%s  calendars/%s\n" % (sha, name))
recent = sorted(k for k, v in days.items()
                if v.get("open") and k <= today.isoformat())
print("%s %s" % (recent[-20], (today - datetime.timedelta(days=45)).isoformat()))
PY
}

# make_run <name> <marker: valid|invalid|none> <exit: n|none>
#          <end: yes|no|none> <age_days>
make_run() {
  local name="$1" marker="$2" exitv="$3" end="$4" age="$5"
  local runs_dir="$RUNS_DIR" dir="$RUNS_DIR/$name"
  mkdir -p "$dir"
  printf '{"kind":"config","seq":1}\n{"kind":"session_end","seq":2}\n' \
    > "$dir/input.hcj.jsonl"
  printf '{"kind":"event","seq":3}\n' > "$dir/events.hcj.jsonl"
  if [ "$marker" = "valid" ]; then
    local sha
    sha="$(sha256sum "$dir/input.hcj.jsonl" | cut -d' ' -f1)"
    printf '{"run_id":"%s","schema":"hong-scanner-commit/1","seq":2,"sha256":"%s","t":"2026-10-29T15:30:00+09:00"}\n' \
      "$name" "$sha" > "$dir/input.hcj.jsonl.committed"
  elif [ "$marker" = "invalid" ]; then
    printf '{"run_id":"%s","schema":"hong-scanner-commit/1","seq":2,"sha256":"%s","t":"2026-10-29T15:30:00+09:00"}\n' \
      "$name" "$(printf '%0*d' 64 0)" > "$dir/input.hcj.jsonl.committed"
  fi
  if [ "$exitv" != "none" ]; then
    {
      echo "=== run_session start 2026-10-29T08:50:00+09:00"
      echo "collector=$RUNS_DIR/../fake-collector"
      echo "COLLECTOR_EXIT=$exitv"
      if [ "$end" = "yes" ]; then
        echo "=== run_session end 2026-10-29T15:35:00+09:00 exit=$exitv"
      fi
    } > "$runs_dir/$name.launcher.log"
  fi
  find "$dir" -type f -exec touch -d "$age days ago" {} +
  if [ -f "$runs_dir/$name.launcher.log" ]; then
    touch -d "$age days ago" "$runs_dir/$name.launcher.log"
  fi
}

# new_workspace <name> — fresh runs/archive/state/gates/scripts/stubs
new_workspace() {
  W="$SANDBOX/$1"
  mkdir -p "$W/runs" "$W/calendars" "$W/archive" "$W/bin" \
           "$W/scripts" "$W/gates-excerpt"
  RUNS_DIR="$W/runs"
  ARCHIVE_DIR="$W/archive"
  STATE_DIR="$W/state"
  GATES_FILE="$W/gates-excerpt/GATES.md"
  printf 'Hong Scanner — Gates (excerpt)\nno runs referenced by default\n' \
    > "$GATES_FILE"
  make_systemctl_stub "$W/bin"
  RETENTION_ENV=(
    HS_RUNS_DIR="$RUNS_DIR"
    HS_ARCHIVE_DIR="$ARCHIVE_DIR"
    HS_STATE_DIR="$STATE_DIR"
    HS_CALENDAR_DIR="$W/calendars"
    HS_CALENDAR_INDEX="$W/calendars/CALENDAR_INDEX.sha256"
    HS_GATES_FILE="$GATES_FILE"
    HS_START_SCRIPTS_DIR="$W/scripts"
    HS_SYSTEMCTL="$W/bin/systemctl-stub"
  )
}

# =========================================== scenarios 1-9 + 13 (main)

echo "--- main workspace: grading, dry-run purity, apply, round-trip"
new_workspace main
read -r WINDOW_START OLD_DATE _ <<< "$(make_calendar "$W/calendars")"
assert_file "calendar index written" "$W/calendars/CALENDAR_INDEX.sha256"

make_run "session-$OLD_DATE-act"       valid   0     yes  0    # 1 ACTIVE
make_run "session-$OLD_DATE-f4"        valid   4     yes  30   # 2 FAILED
make_run "session-$OLD_DATE-gatesref"  valid   0     yes  30   # 3 GATES
make_run "session-$OLD_DATE-svc"       valid   0     yes  30   # 4 SERVICE
make_run "session-$WINDOW_START-rec"   valid   0     yes  30   # 5 RECENT_RAW
make_run "session-$OLD_DATE-nolog"     valid   none  none 30   # 6 UNKNOWN
make_run "session-$OLD_DATE-noend"     valid   0     no   30   # 7 UNKNOWN
make_run "session-$OLD_DATE-badmarker" invalid 0     yes  30   # 8 FAILED
make_run "session-$OLD_DATE-arch"      valid   0     yes  30   # 9 ARCHIVE

printf 'evidence: runs/session-%s-gatesref VERDICT MATCH\n' "$OLD_DATE" \
  >> "$GATES_FILE"
printf '#!/bin/sh\nexec bash ~/hongscanner/tools/run_session.sh "$@"\n# watches runs/session-%s-svc\n' \
  "$OLD_DATE" > "$W/scripts/hongscanner-session-start.sh"
chmod +x "$W/scripts/hongscanner-session-start.sh"

# --- 13: dry-run default = zero filesystem change
SNAP_BEFORE="$(cd "$RUNS_DIR" && find . -type f | sort | xargs sha256sum)"
RC=0; OUT="$(env "${RETENTION_ENV[@]}" bash "$RETENTION")" || RC=$?
assert_eq "dry-run exits 0" 0 "$RC"
assert_contains "dry-run reports ACTIVE (mtime)" "$OUT" \
  "run session-$OLD_DATE-act grade=ACTIVE"
assert_contains "dry-run reports FAILED (exit 4)" "$OUT" \
  "run session-$OLD_DATE-f4 grade=FAILED reason=COLLECTOR_EXIT=4"
assert_contains "dry-run reports GATES_REFERENCED" "$OUT" \
  "run session-$OLD_DATE-gatesref grade=GATES_REFERENCED"
assert_contains "dry-run reports SERVICE_DEPENDENCY" "$OUT" \
  "run session-$OLD_DATE-svc grade=SERVICE_DEPENDENCY"
assert_contains "dry-run reports RECENT_RAW (window boundary)" "$OUT" \
  "run session-$WINDOW_START-rec grade=RECENT_RAW"
assert_contains "dry-run reports UNKNOWN (no launcher log)" "$OUT" \
  "run session-$OLD_DATE-nolog grade=UNKNOWN reason=no launcher log"
assert_contains "dry-run reports UNKNOWN (no end line)" "$OUT" \
  "run session-$OLD_DATE-noend grade=UNKNOWN reason=launcher log has no run_session end line"
assert_contains "dry-run reports FAILED (INVALID marker)" "$OUT" \
  "run session-$OLD_DATE-badmarker grade=FAILED reason=commit marker INVALID"
assert_contains "dry-run reports ARCHIVE_ELIGIBLE" "$OUT" \
  "run session-$OLD_DATE-arch grade=ARCHIVE_ELIGIBLE reason=sealed COMMITTED marker VALID"
assert_contains "dry-run marks the eligible run action=archive" "$OUT" \
  "run session-$OLD_DATE-arch grade=ARCHIVE_ELIGIBLE reason=sealed COMMITTED marker VALID bytes="
assert_contains "dry-run prints the grade summary" "$OUT" "summary total=9"
assert_contains "dry-run prints df avail" "$OUT" "df avail="
assert_contains "dry-run prints quota state" "$OUT" "quota usage="
SNAP_AFTER="$(cd "$RUNS_DIR" && find . -type f | sort | xargs sha256sum)"
assert_eq "dry-run leaves runs/ byte-identical" "$SNAP_BEFORE" "$SNAP_AFTER"
assert_no_file "dry-run writes no retention log" "$STATE_DIR/retention-log.jsonl"
assert_no_file "dry-run creates no archive" "$ARCHIVE_DIR/session-$OLD_DATE-arch.tar.zst"

# --- 9: --apply archives exactly the ARCHIVE_ELIGIBLE run
MANIFEST_BEFORE="$SANDBOX/main/manifest.before"
( cd "$RUNS_DIR" && find "session-$OLD_DATE-arch" -type f | sort \
    | xargs sha256sum && sha256sum "session-$OLD_DATE-arch.launcher.log" ) \
  > "$MANIFEST_BEFORE"
RC=0; OUT="$(env "${RETENTION_ENV[@]}" bash "$RETENTION" --apply)" || RC=$?
assert_eq "apply exits 0" 0 "$RC"
assert_contains "apply logs the ARCHIVE record" \
  "$(cat "$STATE_DIR/retention-log.jsonl")" '"action": "ARCHIVE"'
assert_contains "ARCHIVE record carries the reason" \
  "$(cat "$STATE_DIR/retention-log.jsonl")" \
  '"reason": "sealed COMMITTED marker VALID"'
assert_file "archive file exists" \
  "$ARCHIVE_DIR/session-$OLD_DATE-arch.tar.zst"
assert_no_file "original run dir removed after archive" \
  "$RUNS_DIR/session-$OLD_DATE-arch"
assert_no_file "original launcher log removed after archive" \
  "$RUNS_DIR/session-$OLD_DATE-arch.launcher.log"

# 1-8 originals all survive the apply
assert_file "ACTIVE run kept" "$RUNS_DIR/session-$OLD_DATE-act"
assert_file "ACTIVE run log kept" "$RUNS_DIR/session-$OLD_DATE-act.launcher.log"
assert_file "FAILED (exit 4) run kept" "$RUNS_DIR/session-$OLD_DATE-f4"
assert_file "GATES-referenced run kept" "$RUNS_DIR/session-$OLD_DATE-gatesref"
assert_file "SERVICE_DEPENDENCY run kept" "$RUNS_DIR/session-$OLD_DATE-svc"
assert_file "RECENT_RAW run kept" "$RUNS_DIR/session-$WINDOW_START-rec"
assert_file "UNKNOWN (no log) run kept" "$RUNS_DIR/session-$OLD_DATE-nolog"
assert_file "UNKNOWN (no end) run kept" "$RUNS_DIR/session-$OLD_DATE-noend"
assert_file "FAILED (INVALID marker) run kept" "$RUNS_DIR/session-$OLD_DATE-badmarker"

# restore with tar --zstd and prove byte identity against the pre-apply
# manifest (paths are runs/-relative, the restore reproduces the layout)
VERIFY="$SANDBOX/main/verify"
mkdir -p "$VERIFY"
tar --zstd -xf "$ARCHIVE_DIR/session-$OLD_DATE-arch.tar.zst" -C "$VERIFY"
RC=0; (cd "$VERIFY" && sha256sum --quiet -c "$MANIFEST_BEFORE") || RC=$?
assert_eq "restored archive is byte-identical (sha256sum -c)" 0 "$RC"

# =========================================== scenario 10 (compress failure)

echo "--- 10: failing zstd keeps the original"
new_workspace zfail
make_calendar "$W/calendars" > /dev/null
make_run "session-2026-10-02-old" valid 0 yes 30
mkdir -p "$W/fakebin"
cat > "$W/fakebin/zstd" <<'EOF'
#!/usr/bin/env bash
echo "fake-zstd: refusing (contract test)" >&2
exit 1
EOF
chmod +x "$W/fakebin/zstd"
RC=0; OUT="$(env "${RETENTION_ENV[@]}" PATH="$W/fakebin:$PATH" \
  bash "$RETENTION" --apply)" || RC=$?
assert_eq "apply with failing zstd still exits 0" 0 "$RC"
assert_contains "failing zstd is reported" "$OUT" "FAILED session-2026-10-02-old"
assert_file "original kept on compress failure" "$RUNS_DIR/session-2026-10-02-old"
assert_file "original log kept on compress failure" \
  "$RUNS_DIR/session-2026-10-02-old.launcher.log"
assert_no_file "no archive on compress failure" \
  "$ARCHIVE_DIR/session-2026-10-02-old.tar.zst"
assert_contains "ARCHIVE_FAILED logged" \
  "$(cat "$STATE_DIR/retention-log.jsonl")" '"action": "ARCHIVE_FAILED"'
assert_no_file "no temp artifacts left behind" "$STATE_DIR/tmp/session-2026-10-02-old.tar.zst"

# =========================================== scenario 11 (quota + blocked)

echo "--- 11: quota deletes oldest verified archives, then blocks"
new_workspace quota
make_run "session-2026-10-02-kept" valid none none 30  # UNKNOWN, protected
mkdir -p "$ARCHIVE_DIR" "$STATE_DIR"
printf 'dummy-old\n' > "$SANDBOX/quota/old.txt"
printf 'dummy-new\n' > "$SANDBOX/quota/new.txt"
tar -C "$SANDBOX/quota" -cf - old.txt | zstd -q -3 \
  -o "$ARCHIVE_DIR/quota-old.tar.zst"
tar -C "$SANDBOX/quota" -cf - new.txt | zstd -q -3 \
  -o "$ARCHIVE_DIR/quota-new.tar.zst"
touch -d "20 days ago" "$ARCHIVE_DIR/quota-old.tar.zst"
touch -d "5 days ago" "$ARCHIVE_DIR/quota-new.tar.zst"
cat > "$STATE_DIR/retention-log.jsonl" <<EOF
{"action": "ARCHIVE", "bytes_after": 1, "reason": "sealed COMMITTED marker VALID", "run": "quota-old", "t": "2026-11-01T12:00:00+09:00"}
{"action": "ARCHIVE", "bytes_after": 1, "reason": "sealed COMMITTED marker VALID", "run": "quota-new", "t": "2026-11-10T12:00:00+09:00"}
EOF
make_calendar "$W/calendars" > /dev/null
make_notify_stub "$W/bin" "$W/notify.log"
RC=0; OUT="$(env "${RETENTION_ENV[@]}" \
  HS_NOTIFY_CMD="$W/bin/notify-stub" HS_QUOTA_BYTES=1 \
  bash "$RETENTION" --apply)" || RC=$?
assert_eq "quota-blocked apply still exits 0" 0 "$RC"
DELETES="$(grep -F '"action": "DELETE"' "$STATE_DIR/retention-log.jsonl" \
  | grep -o '"archive": "[^"]*"' | tr '\n' ' ')"
assert_eq "oldest verified archive deleted first" \
  '"archive": "quota-old" "archive": "quota-new" ' "$DELETES"
assert_no_file "quota-old archive deleted" "$ARCHIVE_DIR/quota-old.tar.zst"
assert_no_file "quota-new archive deleted" "$ARCHIVE_DIR/quota-new.tar.zst"
assert_contains "RETENTION_BLOCKED logged" \
  "$(cat "$STATE_DIR/retention-log.jsonl")" '"action": "RETENTION_BLOCKED"'
assert_contains "RETENTION_BLOCKED surfaced on stdout" "$OUT" "RETENTION_BLOCKED"
assert_contains "notify observed RETENTION_BLOCKED" \
  "$(cat "$W/notify.log")" "RETENTION_BLOCKED"
assert_file "protected run survives the quota pass" \
  "$RUNS_DIR/session-2026-10-02-kept"

# =========================================== scenario 12 (active session)

echo "--- 12: active session skips the whole pass"
new_workspace active
make_calendar "$W/calendars" > /dev/null
make_run "session-2026-10-02-skipme" valid 0 yes 30
RC=0; OUT="$(env "${RETENTION_ENV[@]}" STUB_SESSION_STATE=active \
  bash "$RETENTION" --apply)" || RC=$?
assert_eq "active-session apply exits 0" 0 "$RC"
assert_contains "SKIPPED_ACTIVE_SESSION on stdout" "$OUT" "SKIPPED_ACTIVE_SESSION"
assert_file "run untouched under active session" \
  "$RUNS_DIR/session-2026-10-02-skipme"
assert_file "run log untouched under active session" \
  "$RUNS_DIR/session-2026-10-02-skipme.launcher.log"
assert_no_file "no archive under active session" \
  "$ARCHIVE_DIR/session-2026-10-02-skipme.tar.zst"
assert_contains "skip recorded in the retention log" \
  "$(cat "$STATE_DIR/retention-log.jsonl")" \
  '"action": "SKIPPED_ACTIVE_SESSION"'

# =========================================== scenario 14 (preflight)

echo "--- 14: storage preflight in run_session.sh"
PF="$SANDBOX/preflight"
mkdir -p "$PF/bin" "$PF/out"
cat > "$PF/bin/df" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-B1" ] && shift
[ "${1:-}" = "--output=avail" ] && shift
echo "$DF_AVAIL_STUB"
EOF
cat > "$PF/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$PF/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" is-active "*) exit 3 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$PF/bin/df" "$PF/bin/systemd-run" "$PF/bin/systemctl"
printf '{}\n' > "$PF/notify-config.json"
cat > "$PF/collector-echo" <<'EOF'
#!/usr/bin/env bash
echo "fake-collector $*"
exit 0
EOF
chmod +x "$PF/collector-echo"
make_notify_stub "$PF/bin" "$PF/notify.log"

# (a) enough avail -> exit 0 + PREFLIGHT_OK
RC=0
PATH="$PF/bin:$PATH" DF_AVAIL_STUB=32212254720 \
  HSNOTIFY_CONFIG="$PF/notify-config.json" \
  HSCOLLECTOR_BIN="$PF/collector-echo" \
  HSCOLLECTOR_PYTHON=/bin/true \
  HS_NOTIFY_CMD="$PF/bin/notify-stub" \
  bash "$RUN_SESSION" --out="$PF/out/sess-a" >/dev/null 2>&1 || RC=$?
assert_eq "preflight pass: session exits 0" 0 "$RC"
assert_contains "PREFLIGHT_OK recorded in the launcher log" \
  "$(cat "$PF/out/sess-a.launcher.log")" "PREFLIGHT_OK avail=32212254720"
assert_contains "collector ran after the preflight" \
  "$(cat "$PF/out/sess-a.launcher.log")" "COLLECTOR_EXIT=0"

# (b) not enough avail -> exit 2 + STORAGE_PREFLIGHT_FAILED + notify
: > "$PF/notify.log"
RC=0
PATH="$PF/bin:$PATH" DF_AVAIL_STUB=10737418240 \
  HSNOTIFY_CONFIG="$PF/notify-config.json" \
  HSCOLLECTOR_BIN="$PF/collector-echo" \
  HSCOLLECTOR_PYTHON=/bin/true \
  HS_NOTIFY_CMD="$PF/bin/notify-stub" \
  bash "$RUN_SESSION" --out="$PF/out/sess-b" >/dev/null 2>&1 || RC=$?
assert_eq "preflight fail: session exits 2" 2 "$RC"
assert_contains "STORAGE_PREFLIGHT_FAILED recorded" \
  "$(cat "$PF/out/sess-b.launcher.log")" \
  "STORAGE_PREFLIGHT_FAILED: avail=10737418240 required=21474836480"
assert_contains "notify observed STORAGE_PREFLIGHT_FAILED" \
  "$(cat "$PF/notify.log")" "STORAGE_PREFLIGHT_FAILED"
if grep -qF "COLLECTOR_EXIT=" "$PF/out/sess-b.launcher.log"; then
  echo "FAIL preflight failure must not run the collector"
  FAILED=$((FAILED + 1))
else
  echo "ok   preflight failure starts no collector"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------- summary
echo ""
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
