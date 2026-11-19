#!/usr/bin/env bash
## Contract tests for tools/observe_notifications.sh.
##
## A fake adb feeds dumpsys text fixtures; nothing here talks to a real
## device. The tests pin the evidence contract: field extraction, append-only
## dedupe by (tag, when_ms), foreign-package filtering, one-line JSON, and
## exit 0 with an `error` line when adb fails or is absent.
##
## Window coverage: --window is loop-only, a start outside the window is one
## error line and exit 2, and a completed window closes with one observer_end
## whose polls count proves the sampling reached END.
##
## Timeout: a hung adb is bounded by ADB_TIMEOUT_SEC, the timeout is one
## error line, and the loop keeps polling.
##
## Run: bash tests/test_observe_notifications.sh
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$REPO_ROOT/tools/observe_notifications.sh"
TOOL_SHA256="$(sha256sum "$TOOL" 2>/dev/null | cut -d' ' -f1)"
[ -n "$TOOL_SHA256" ] || TOOL_SHA256="unknown"
TOOL_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"
[ -n "$TOOL_COMMIT" ] || TOOL_COMMIT="unknown"

PASS=0
FAILED=0

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: expected [$2] got [$3]"; FAILED=$((FAILED + 1))
  fi
}

assert_python() { # desc check-script [args...]
  local desc="$1"; shift
  if python3 "$@" > "${TMP}/py.out" 2>&1; then
    echo "ok   $desc"; PASS=$((PASS + 1))
  else
    echo "FAIL $desc"; sed 's/^/     /' "${TMP}/py.out"
    FAILED=$((FAILED + 1))
  fi
}

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

OUT_DIR="${TMP}/out"
FAIL_DIR="${TMP}/out-fail"
MISSING_DIR="${TMP}/out-missing"
TODAY="$(TZ=Asia/Seoul date +%F)"
EVIDENCE="${OUT_DIR}/notifications-${TODAY}.hcj.jsonl"

# --------------------------------------------------------------- fake adb
FAKE_ADB="${TMP}/fake-adb"
cat > "$FAKE_ADB" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_ADB_HANG:-}" ]; then
  exec sleep "${FAKE_ADB_HANG}"
fi
if [ "${1:-}" = "devices" ]; then
  if [ -n "${FAKE_ADB_FAIL:-}" ]; then
    echo "error: no devices/emulators found" >&2
    exit 1
  fi
  printf 'List of devices attached\nFAKE123\tdevice\n\n'
  exit 0
fi
if [ "${1:-}" = "-s" ]; then
  shift 2
fi
if [ "${1:-}" = "shell" ] && [ "${2:-}" = "dumpsys" ]; then
  if [ -n "${FAKE_ADB_FAIL:-}" ]; then
    echo "error: no devices/emulators found" >&2
    exit 1
  fi
  cat "$FAKE_DUMP"
  exit 0
fi
echo "fake-adb: unsupported arguments: $*" >&2
exit 1
SH
chmod +x "$FAKE_ADB"

# --------------------------------------------------------------- fixtures
# Field layout follows Android 12 NotificationRecord.dump() as observed on
# SM-G977N (2026-11-19): header has pkg/id/tag/importance, the body prints
# when=<epoch ms> and the extras map prints android.title/android.text/
# android.bigText as `String (...)`.
FIXTURE_ONE="${TMP}/dump-one.txt"
cat > "$FIXTURE_ONE" <<'EOF'
Current Notification Manager state:
  Notification List:
    NotificationRecord(0x0d17d68a: pkg=com.hongscanner.hongscanner user=UserHandle{0} id=6446973662 tag=FCM-Notification:6446973662 importance=4 key=0|com.hongscanner.hongscanner|6446973662|FCM-Notification:6446973662|10716: Notification(channel=market_rank_changes shortcut=null contentView=null vibrate=null sound=content://settings/system/notification_sound defaults=0x0 flags=0x10 color=0x00000000 vis=PRIVATE semFlags=0x0 semPriority=0 semMissedCount=0))
      uid=10716 userId=0
      opPkg=com.hongscanner.hongscanner
      icon=Icon(typ=RESOURCE pkg=com.hongscanner.hongscanner id=0x7f0c0000)
      flags=0x10
      pri=0
      key=0|com.hongscanner.hongscanner|6446973662|FCM-Notification:6446973662|10716
      seen=false
      groupKey=0|com.hongscanner.hongscanner|6446973662|FCM-Notification:6446973662|10716
      notification=
            fullscreenIntent=null
            contentIntent=null
            deleteIntent=null
            number=0
            groupAlertBehavior=0
            when=1795050000000
            tickerText=null
            contentView=null
            bigContentView=null
            color=0x00000000
            extras={
                android.title=String (홍스캐너 TOP10 알림)
                android.reduced.images=Boolean (true)
                android.subText=null
                android.text=String (넥슨게임즈 11위→10위)
                android.showWhen=Boolean (true)
                android.bigText=String (넥슨게임즈 11위→10위)
            }
      publicNotification=
            None
      stats=SingleNotificationStats{posttimeElapsedMs=0}
      mImportance=HIGH
      mRankingTimeMs=1795050000000(2026-11-19 10:00:00.000+0900)
      mCreationTimeMs=1795050000035(2026-11-19 10:00:00.035+0900)
      mSound= content://settings/system/notification_sound
      effectiveNotificationChannel=NotificationChannel{mId='market_rank_changes', mName=시장 순위 알림, mImportance=4, mSound=content://settings/system/notification_sound}
    NotificationRecord(0x0d17d68b: pkg=com.hongscanner.hongscanner user=UserHandle{0} id=0 tag=market_rank_digest importance=2 key=0|com.hongscanner.hongscanner|0|market_rank_digest|10716: Notification(channel=market_rank_digest shortcut=null contentView=null vibrate=null sound=null defaults=0x0 flags=0x10 color=0x00000000 vis=PRIVATE semFlags=0x0 semPriority=0 semMissedCount=0))
      uid=10716 userId=0
      opPkg=com.hongscanner.hongscanner
      icon=Icon(typ=RESOURCE pkg=com.hongscanner.hongscanner id=0x7f0c0000)
      flags=0x10
      pri=0
      key=0|com.hongscanner.hongscanner|0|market_rank_digest|10716
      seen=true
      groupKey=0|com.hongscanner.hongscanner|0|market_rank_digest|10716
      notification=
            fullscreenIntent=null
            contentIntent=null
            number=0
            when=1795050330000
            tickerText=null
            contentView=null
            bigContentView=null
            color=0x00000000
            extras={
                android.title=String (홍스캐너 TOP10 순위 요약)
                android.reduced.images=Boolean (true)
                android.subText=null
                android.text=String (에스제이그룹 4위→3위 외 7건)
                android.showWhen=Boolean (true)
                android.bigText=String (에스제이그룹 4위→3위 외 7건)
            }
      publicNotification=
            None
      stats=SingleNotificationStats{posttimeElapsedMs=0}
      mImportance=LOW
      mRankingTimeMs=1795050330000(2026-11-19 10:05:30.000+0900)
      mCreationTimeMs=1795050330027(2026-11-19 10:05:30.027+0900)
      mSound= null
      effectiveNotificationChannel=NotificationChannel{mId='market_rank_digest', mName=시장 순위 요약, mImportance=2, mSound=null}
    NotificationRecord(0x0f00aa11: pkg=com.example.app user=UserHandle{0} id=1 tag=null importance=3 key=0|com.example.app|1|null|10123: Notification(channel=misc shortcut=null contentView=null vibrate=null sound=null defaults=0x0 flags=0x0 color=0x00000000 vis=PRIVATE semFlags=0x0 semPriority=0 semMissedCount=0))
      uid=10123 userId=0
      opPkg=com.example.app
      notification=
            when=1795051900000
            extras={
                android.title=String (Other app)
                android.text=String (must not be recorded)
            }
      mImportance=DEFAULT
  TimeoutPendingIntent:
EOF

# (c) fixture: the same two target records plus one new FCM tag.
FIXTURE_NEW="${TMP}/dump-new.txt"
python3 - "$FIXTURE_ONE" "$FIXTURE_NEW" <<'PY'
import sys

source, target = sys.argv[1:3]
with open(source, "r", encoding="utf-8") as handle:
    text = handle.read()
new_record = """    NotificationRecord(0x0d17d68c: pkg=com.hongscanner.hongscanner user=UserHandle{0} id=6446973744 tag=FCM-Notification:6446973744 importance=2 key=0|com.hongscanner.hongscanner|6446973744|FCM-Notification:6446973744|10716: Notification(channel=market_rank_digest shortcut=null contentView=null vibrate=null sound=null defaults=0x0 flags=0x10 color=0x00000000 vis=PRIVATE semFlags=0x0 semPriority=0 semMissedCount=0))
      uid=10716 userId=0
      opPkg=com.hongscanner.hongscanner
      notification=
            when=1795051900000
            extras={
                android.title=String (홍스캐너 TOP10 순위 요약)
                android.bigText=String (한진칼 8위→9위 외 2건)
            }
"""
marker = "  TimeoutPendingIntent:"
assert marker in text
with open(target, "w", encoding="utf-8") as handle:
    handle.write(text.replace(marker, new_record + marker))
PY

# ------------------------------------------------------------- checks (a)
echo "--- (a) parse two records, ignore foreign package"
FAKE_DUMP="$FIXTURE_ONE" bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 \
  --out-dir "$OUT_DIR" --once > "${TMP}/run-a.out" 2>&1
RC=$?
assert_eq "single-shot exits 0" 0 "$RC"
if [ -f "$EVIDENCE" ]; then
  echo "ok   evidence file created"; PASS=$((PASS + 1))
else
  echo "FAIL evidence file missing: $EVIDENCE"; FAILED=$((FAILED + 1))
fi

cat > "${TMP}/check-a.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
sha_expected, commit_expected = sys.argv[2], sys.argv[3]
assert len(lines) == 2, "expected 2 records, got %d" % len(lines)
by_tag = {record["tag"]: record for record in lines}

expected_keys = {"captured_at", "device_serial", "tag", "channel",
                 "importance", "when_ms", "when_kst", "title", "text",
                 "package", "snapshot_status", "observer_git_commit",
                 "observer_sha256"}
for record in lines:
    assert set(record) == expected_keys, sorted(record)
    assert record["package"] == "com.hongscanner.hongscanner"
    assert record["device_serial"] == "FAKE123"
    assert record["captured_at"].endswith("+09:00"), record["captured_at"]
    assert record["snapshot_status"] == "OBSERVED_ACTIVE", record
    assert record["observer_sha256"] == sha_expected, record
    assert record["observer_git_commit"] == commit_expected, record
    if sha_expected != "unknown":
        assert len(record["observer_sha256"]) == 64, record
    if commit_expected != "unknown":
        assert len(record["observer_git_commit"]) == 40, record

fcm = by_tag["FCM-Notification:6446973662"]
assert fcm["channel"] == "market_rank_changes", fcm
assert fcm["importance"] == 4, fcm
assert fcm["when_ms"] == 1795050000000, fcm
assert fcm["when_kst"] == "2026-11-19T10:00:00+09:00", fcm
assert fcm["title"] == "홍스캐너 TOP10 알림", fcm
assert fcm["text"] == "넥슨게임즈 11위→10위", fcm

digest = by_tag["market_rank_digest"]
assert digest["channel"] == "market_rank_digest", digest
assert digest["importance"] == 2, digest
assert digest["when_ms"] == 1795050330000, digest
assert digest["when_kst"] == "2026-11-19T10:05:30+09:00", digest
assert digest["title"] == "홍스캐너 TOP10 순위 요약", digest
assert digest["text"] == "에스제이그룹 4위→3위 외 7건", digest

assert "com.example.app" not in {record["package"] for record in lines}
assert "Other app" not in {record["title"] for record in lines}
PY
assert_python "tag/channel/importance/when/title/text are exact" \
  "${TMP}/check-a.py" "$EVIDENCE" "$TOOL_SHA256" "$TOOL_COMMIT"

# ------------------------------------------------------------- checks (b)
echo "--- (b) re-running the same dump adds nothing"
SHA_BEFORE="$(sha256sum "$EVIDENCE" | cut -d' ' -f1)"
cp "$EVIDENCE" "${TMP}/snapshot.jsonl"
FAKE_DUMP="$FIXTURE_ONE" bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 \
  --out-dir "$OUT_DIR" --once > "${TMP}/run-b.out" 2>&1
RC=$?
assert_eq "second run exits 0" 0 "$RC"
assert_eq "second run appends 0 lines" 2 \
  "$(wc -l < "$EVIDENCE" | tr -d ' ')"
assert_eq "evidence file is byte-identical" "$SHA_BEFORE" \
  "$(sha256sum "$EVIDENCE" | cut -d' ' -f1)"
if cmp -s "${TMP}/snapshot.jsonl" "$EVIDENCE"; then
  echo "ok   append-only file unchanged"; PASS=$((PASS + 1))
else
  echo "FAIL append-only file changed"; FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------- checks (c)
echo "--- (c) a new tag adds exactly one record"
FAKE_DUMP="$FIXTURE_NEW" bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 \
  --out-dir "$OUT_DIR" --once > "${TMP}/run-c.out" 2>&1
RC=$?
assert_eq "third run exits 0" 0 "$RC"
assert_eq "third run adds exactly 1 line" 3 \
  "$(wc -l < "$EVIDENCE" | tr -d ' ')"

cat > "${TMP}/check-c.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
assert len(lines) == 3, "expected 3 records, got %d" % len(lines)
old = [json.loads(line) for line in
       open(sys.argv[2], "r", encoding="utf-8") if line.strip()]
assert lines[:2] == old, "existing lines were rewritten"
new = lines[2]
assert new["tag"] == "FCM-Notification:6446973744", new
assert new["when_ms"] == 1795051900000, new
assert new["channel"] == "market_rank_digest", new
assert new["importance"] == 2, new
assert new["title"] == "홍스캐너 TOP10 순위 요약", new
assert new["text"] == "한진칼 8위→9위 외 2건", new
PY
assert_python "only the new (tag, when_ms) is appended" \
  "${TMP}/check-c.py" "$EVIDENCE" "${TMP}/snapshot.jsonl"

# ------------------------------------------------------------- checks (d)
echo "--- (d) adb failure and missing adb are recorded, exit 0"
FAKE_DUMP="$FIXTURE_ONE" FAKE_ADB_FAIL=1 bash "$TOOL" --adb "$FAKE_ADB" \
  --serial FAILSERIAL --out-dir "$FAIL_DIR" --once \
  > "${TMP}/run-d.out" 2>&1
RC=$?
assert_eq "failing adb exits 0" 0 "$RC"
FAIL_FILE="${FAIL_DIR}/notifications-${TODAY}.hcj.jsonl"
if [ -f "$FAIL_FILE" ]; then
  echo "ok   failure evidence file created"; PASS=$((PASS + 1))
else
  echo "FAIL failure evidence file missing: $FAIL_FILE"; FAILED=$((FAILED + 1))
fi
assert_eq "failing adb writes one line" 1 \
  "$(wc -l < "$FAIL_FILE" 2>/dev/null | tr -d ' ')"

cat > "${TMP}/check-d.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
assert len(lines) == 1, "expected 1 error line, got %d" % len(lines)
record = lines[0]
assert "error" in record and record["error"], record
assert "rc=1" in record["error"], record
assert "no devices" in record["error"], record
assert record["errors"]["adb"] == record["error"], record
assert record["device_serial"] == "FAILSERIAL", record
assert record["package"] == "com.hongscanner.hongscanner", record
assert "tag" not in record, record
assert record["observer_sha256"] == sys.argv[2], record
assert record["observer_git_commit"] == sys.argv[3], record
PY
assert_python "failed adb produces one error record" \
  "${TMP}/check-d.py" "$FAIL_FILE" "$TOOL_SHA256" "$TOOL_COMMIT"

bash "$TOOL" --adb "${TMP}/does-not-exist" --serial MISSING \
  --out-dir "$MISSING_DIR" --once > "${TMP}/run-d2.out" 2>&1
RC=$?
assert_eq "missing adb binary exits 0" 0 "$RC"
MISSING_FILE="${MISSING_DIR}/notifications-${TODAY}.hcj.jsonl"
assert_eq "missing adb writes one line" 1 \
  "$(wc -l < "$MISSING_FILE" 2>/dev/null | tr -d ' ')"

cat > "${TMP}/check-d2.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
assert len(lines) == 1, "expected 1 error line, got %d" % len(lines)
record = lines[0]
assert record["error"], record
assert "rc=127" in record["error"], record
assert record["device_serial"] == "MISSING", record
PY
assert_python "missing adb is an error line, not a crash" \
  "${TMP}/check-d2.py" "$MISSING_FILE"

# ------------------------------------------------------------- checks (e)
echo "--- (e) one JSON object per line, all parseable"
if python3 -c 'import json,sys; [json.loads(line) for line in sys.stdin if line.strip()]' \
    < "$EVIDENCE"; then
  echo "ok   every evidence line parses with python3 -c json.loads"
  PASS=$((PASS + 1))
else
  echo "FAIL a line is not valid JSON"; FAILED=$((FAILED + 1))
fi

if python3 - "$EVIDENCE" <<'PY'
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = handle.read()
assert data.endswith("\n"), "file does not end with a newline"
lines = data.splitlines()
assert all(line.strip() for line in lines), "blank line in evidence file"
assert len(lines) == 3, len(lines)
PY
then
  echo "ok   file is newline-terminated with no blank lines"; PASS=$((PASS + 1))
else
  echo "FAIL line layout is not one-object-per-line"; FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------- checks (f)
echo "--- (f) only the current tray is evidence"
FIXTURE_SCOPE="${TMP}/dump-scope.txt"
cat > "$FIXTURE_SCOPE" <<'EOF'
Current Notification Manager state:
  Notification List:
    NotificationRecord(0x0d17d68d: pkg=com.hongscanner.hongscanner user=UserHandle{0} id=6446973900 tag=FCM-Notification:6446973900 importance=4 key=0|com.hongscanner.hongscanner|6446973900|FCM-Notification:6446973900|10716: Notification(channel=market_rank_changes shortcut=null contentView=null vibrate=null sound=null defaults=0x0 flags=0x10 color=0x00000000 vis=PRIVATE semFlags=0x0 semPriority=0 semMissedCount=0))
      uid=10716 userId=0
      opPkg=com.hongscanner.hongscanner
      notification=
            when=1795051200000
            extras={
                android.title=String (홍스캐너 TOP10 알림)
                android.text=String (tray record)
            }
  mArchive=Archive (2 notifications)
    StatusBarNotification(pkg=com.hongscanner.hongscanner user=UserHandle{0} id=1 tag=FCM-Notification:1 key=0|com.hongscanner.hongscanner|1|FCM-Notification:1|10716: Notification(channel=market_rank_changes))
    StatusBarNotification(pkg=com.hongscanner.hongscanner user=UserHandle{0} id=2 tag=FCM-Notification:2 key=0|com.hongscanner.hongscanner|2|FCM-Notification:2|10716: Notification(channel=market_rank_changes))
  Enqueued Notification List:
    NotificationRecord(0x0d17d68e: pkg=com.hongscanner.hongscanner user=UserHandle{0} id=6446973901 tag=FCM-Notification:6446973901 importance=4 key=0|com.hongscanner.hongscanner|6446973901|FCM-Notification:6446973901|10716: Notification(channel=market_rank_changes shortcut=null contentView=null vibrate=null sound=null defaults=0x0 flags=0x10 color=0x00000000 vis=PRIVATE semFlags=0x0 semPriority=0 semMissedCount=0))
      uid=10716 userId=0
      notification=
            when=1795051300000
            extras={
                android.title=String (홍스캐너 TOP10 알림)
                android.text=String (enqueued record)
            }
  TimeoutPendingIntent:
EOF
SCOPE_DIR="${TMP}/out-scope"
FAKE_DUMP="$FIXTURE_SCOPE" bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 \
  --out-dir "$SCOPE_DIR" --once > "${TMP}/run-f.out" 2>&1
RC=$?
assert_eq "scoped dump exits 0" 0 "$RC"
SCOPE_FILE="${SCOPE_DIR}/notifications-${TODAY}.hcj.jsonl"
assert_eq "archive and enqueued records are not written" 1 \
  "$(wc -l < "$SCOPE_FILE" 2>/dev/null | tr -d ' ')"
cat > "${TMP}/check-f.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
assert len(lines) == 1, "expected only the tray record, got %d" % len(lines)
record = lines[0]
assert record["tag"] == "FCM-Notification:6446973900", record
assert record["text"] == "tray record", record
PY
assert_python "tray record only; archive/enqueued ignored" \
  "${TMP}/check-f.py" "$SCOPE_FILE"

# ------------------------------------------------------------- checks (g)
echo "--- (g) serial resolution and option validation"
NO_SERIAL_DIR="${TMP}/out-noserial"
FAKE_DUMP="$FIXTURE_ONE" bash "$TOOL" --adb "$FAKE_ADB" \
  --out-dir "$NO_SERIAL_DIR" --once > "${TMP}/run-g.out" 2>&1
RC=$?
assert_eq "run without --serial exits 0" 0 "$RC"
NO_SERIAL_FILE="${NO_SERIAL_DIR}/notifications-${TODAY}.hcj.jsonl"
cat > "${TMP}/check-g.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
assert len(lines) == 2, len(lines)
assert {record["device_serial"] for record in lines} == {"FAKE123"}, lines
PY
assert_python "adb devices supplies the serial" "${TMP}/check-g.py" \
  "$NO_SERIAL_FILE"

bash "$TOOL" --adb "$FAKE_ADB" --interval 3 --out-dir "${TMP}/bad" \
  > /dev/null 2>&1
assert_eq "--interval below 5 exits 2" 2 "$?"
bash "$TOOL" --adb "$FAKE_ADB" --interval abc --out-dir "${TMP}/bad" \
  > /dev/null 2>&1
assert_eq "non-numeric --interval exits 2" 2 "$?"
bash "$TOOL" --adb "$FAKE_ADB" --no-such-option > /dev/null 2>&1
assert_eq "unknown option exits 2" 2 "$?"

# ------------------------------------------------------------- checks (h)
echo "--- (h) --window is loop-only"
FUTURE_WINDOW="2099-01-01T00:00:00+09:00/2099-01-01T00:10:00+09:00"
bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 --out-dir "${TMP}/bad" \
  --once --window "$FUTURE_WINDOW" > /dev/null 2>&1
assert_eq "--once with --window exits 2" 2 "$?"
bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 --out-dir "${TMP}/bad" \
  --window "$FUTURE_WINDOW" --once > /dev/null 2>&1
assert_eq "--window then --once exits 2" 2 "$?"
bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 --out-dir "${TMP}/bad" \
  --window "$FUTURE_WINDOW" > /dev/null 2>&1
assert_eq "--window without --interval exits 2" 2 "$?"
bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 --out-dir "${TMP}/bad" \
  --interval 5 --window "not-a-window" > /dev/null 2>&1
assert_eq "malformed --window exits 2" 2 "$?"
bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 --out-dir "${TMP}/bad" \
  --interval 5 --window "2099-01-01T00:10:00+09:00/2099-01-01T00:00:00+09:00" \
  > /dev/null 2>&1
assert_eq "--window with START after END exits 2" 2 "$?"

# ------------------------------------------------------------- checks (i)
echo "--- (i) a start outside the window is one error line, no sampling"
cat > "${TMP}/check-window.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
assert len(lines) == 1, "expected 1 error line, got %d" % len(lines)
record = lines[0]
assert record["error"].startswith("observer started outside window: "), record
assert record["errors"]["window"] == record["error"], record
assert "tag" not in record and "when_ms" not in record, record
assert "snapshot_status" not in record, record
assert record["device_serial"] == "FAKE123", record
assert record["observer_sha256"] == sys.argv[2], record
assert record["observer_git_commit"] == sys.argv[3], record
PY

PAST_DIR="${TMP}/out-window-past"
PAST_FILE="${PAST_DIR}/notifications-${TODAY}.hcj.jsonl"
PAST_WINDOW="2020-01-01T00:00:00+09:00/2020-01-01T00:10:00+09:00"
FAKE_DUMP="$FIXTURE_ONE" bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 \
  --out-dir "$PAST_DIR" --interval 5 --window "$PAST_WINDOW" \
  > "${TMP}/run-past.out" 2>&1
assert_eq "window entirely before now exits 2" 2 "$?"
assert_eq "window entirely before now writes exactly one line" 1 \
  "$(wc -l < "$PAST_FILE" 2>/dev/null | tr -d ' ')"
assert_python "start after END is one non-evidence error record" \
  "${TMP}/check-window.py" "$PAST_FILE" "$TOOL_SHA256" "$TOOL_COMMIT"

FUTURE_DIR="${TMP}/out-window-future"
FUTURE_FILE="${FUTURE_DIR}/notifications-${TODAY}.hcj.jsonl"
FAKE_DUMP="$FIXTURE_ONE" bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 \
  --out-dir "$FUTURE_DIR" --interval 5 --window "$FUTURE_WINDOW" \
  > "${TMP}/run-future.out" 2>&1
assert_eq "window entirely after now exits 2" 2 "$?"
assert_eq "window entirely after now writes exactly one line" 1 \
  "$(wc -l < "$FUTURE_FILE" 2>/dev/null | tr -d ' ')"
assert_python "start before START is one non-evidence error record" \
  "${TMP}/check-window.py" "$FUTURE_FILE" "$TOOL_SHA256" "$TOOL_COMMIT"

LATE_DIR="${TMP}/out-window-late"
LATE_FILE="${LATE_DIR}/notifications-${TODAY}.hcj.jsonl"
LATE_START="$(TZ=Asia/Seoul date -d '-300 seconds' +%Y-%m-%dT%H:%M:%S%:z)"
LATE_END="$(TZ=Asia/Seoul date -d '+30 seconds' +%Y-%m-%dT%H:%M:%S%:z)"
FAKE_DUMP="$FIXTURE_ONE" bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 \
  --out-dir "$LATE_DIR" --interval 5 --window "${LATE_START}/${LATE_END}" \
  > "${TMP}/run-late.out" 2>&1
assert_eq "start later than the tolerance exits 2" 2 "$?"
assert_eq "late start writes exactly one line" 1 \
  "$(wc -l < "$LATE_FILE" 2>/dev/null | tr -d ' ')"
cat > "${TMP}/check-late.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
assert len(lines) == 1, "expected 1 error line, got %d" % len(lines)
record = lines[0]
assert record["error"].startswith("observer started late: "), record
assert "start tolerance 90s" in record["error"], record
assert record["errors"]["window"] == record["error"], record
assert "tag" not in record and "when_ms" not in record, record
assert "snapshot_status" not in record, record
assert record["device_serial"] == "FAKE123", record
PY
assert_python "late start is one non-evidence error record" \
  "${TMP}/check-late.py" "$LATE_FILE"

# ------------------------------------------------------------- checks (j)
echo "--- (j) loop mode inside a short window closes with one observer_end"
LOOP_DIR="${TMP}/out-window-loop"
LOOP_FILE="${LOOP_DIR}/notifications-${TODAY}.hcj.jsonl"
LOOP_WINDOW_START="$(TZ=Asia/Seoul date -d '-1 second' +%Y-%m-%dT%H:%M:%S%:z)"
LOOP_WINDOW_END="$(TZ=Asia/Seoul date -d '+6 seconds' +%Y-%m-%dT%H:%M:%S%:z)"
LOOP_STARTED="$(date +%s)"
FAKE_DUMP="$FIXTURE_ONE" bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 \
  --out-dir "$LOOP_DIR" --interval 5 \
  --window "${LOOP_WINDOW_START}/${LOOP_WINDOW_END}" \
  > "${TMP}/run-loop.out" 2>&1
LOOP_RC=$?
LOOP_ELAPSED=$(( $(date +%s) - LOOP_STARTED ))
assert_eq "loop inside the window exits 0" 0 "$LOOP_RC"
if [ "$LOOP_ELAPSED" -le 9 ]; then
  echo "ok   loop stops at END without sleeping past it (${LOOP_ELAPSED}s)"
  PASS=$((PASS + 1))
else
  echo "FAIL loop slept past END (${LOOP_ELAPSED}s)"
  FAILED=$((FAILED + 1))
fi
cat > "${TMP}/check-loop.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
ends = [record for record in lines if record.get("kind") == "observer_end"]
assert len(ends) == 1, "expected exactly one observer_end, got %d" % len(ends)
end = ends[0]
assert set(end) == {"kind", "started_at", "ended_at", "window_start",
                    "window_end", "polls", "exit", "device_serial",
                    "package", "observer_git_commit", "observer_sha256"}, end
assert end["exit"] == "ok", end
assert end["window_start"] == sys.argv[2], end
assert end["window_end"] == sys.argv[3], end
assert end["ended_at"] >= end["window_end"], end
assert end["polls"] >= 1, end
assert end["device_serial"] == "FAKE123", end
assert end["package"] == "com.hongscanner.hongscanner", end
assert end["observer_sha256"] == sys.argv[4], end
assert end["observer_git_commit"] == sys.argv[5], end

notifications = [record for record in lines if "tag" in record]
assert notifications, "the window sampled no notification records"
assert not [record for record in lines if record.get("kind") == "heartbeat"]
PY
assert_python "observer_end closes the sampled window" \
  "${TMP}/check-loop.py" "$LOOP_FILE" "$LOOP_WINDOW_START" "$LOOP_WINDOW_END" \
  "$TOOL_SHA256" "$TOOL_COMMIT"

# ------------------------------------------------------------- checks (k)
echo "--- (k) a hanging adb is bounded and recorded, not waited on"
HANG_DIR="${TMP}/out-hang"
HANG_FILE="${HANG_DIR}/notifications-${TODAY}.hcj.jsonl"
HANG_STARTED="$(date +%s)"
FAKE_ADB_HANG=30 FAKE_DUMP="$FIXTURE_ONE" ADB_TIMEOUT_SEC=2 \
  bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 --out-dir "$HANG_DIR" --once \
  > "${TMP}/run-hang.out" 2>&1
HANG_RC=$?
HANG_ELAPSED=$(( $(date +%s) - HANG_STARTED ))
assert_eq "hanging adb exits 0" 0 "$HANG_RC"
assert_eq "hanging adb writes one line" 1 \
  "$(wc -l < "$HANG_FILE" 2>/dev/null | tr -d ' ')"
if [ "$HANG_ELAPSED" -le 10 ]; then
  echo "ok   --once returns after the timeout (${HANG_ELAPSED}s)"
  PASS=$((PASS + 1))
else
  echo "FAIL --once waited for the hung adb (${HANG_ELAPSED}s)"
  FAILED=$((FAILED + 1))
fi

cat > "${TMP}/check-k.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
assert len(lines) == 1, "expected 1 error line, got %d" % len(lines)
record = lines[0]
assert record["error"] == "adb shell dumpsys notification timed out after 2s", record
assert record["errors"]["adb"] == record["error"], record
assert record["device_serial"] == "FAKE123", record
assert record["package"] == "com.hongscanner.hongscanner", record
assert "tag" not in record and "when_ms" not in record, record
assert "snapshot_status" not in record, record
assert record["observer_sha256"] == sys.argv[2], record
assert record["observer_git_commit"] == sys.argv[3], record
PY
assert_python "hung adb is one timeout error record" \
  "${TMP}/check-k.py" "$HANG_FILE" "$TOOL_SHA256" "$TOOL_COMMIT"

HANG_NOSERIAL_DIR="${TMP}/out-hang-noserial"
HANG_NOSERIAL_FILE="${HANG_NOSERIAL_DIR}/notifications-${TODAY}.hcj.jsonl"
HANG_NOSERIAL_STARTED="$(date +%s)"
FAKE_ADB_HANG=30 FAKE_DUMP="$FIXTURE_ONE" ADB_TIMEOUT_SEC=1 \
  bash "$TOOL" --adb "$FAKE_ADB" --out-dir "$HANG_NOSERIAL_DIR" --once \
  > "${TMP}/run-hang-noserial.out" 2>&1
HANG_NOSERIAL_RC=$?
HANG_NOSERIAL_ELAPSED=$(( $(date +%s) - HANG_NOSERIAL_STARTED ))
assert_eq "hanging adb devices exits 0" 0 "$HANG_NOSERIAL_RC"
assert_eq "hanging adb devices writes one line" 1 \
  "$(wc -l < "$HANG_NOSERIAL_FILE" 2>/dev/null | tr -d ' ')"
if [ "$HANG_NOSERIAL_ELAPSED" -le 10 ]; then
  echo "ok   serial resolution times out, dump timeout is still recorded (${HANG_NOSERIAL_ELAPSED}s)"
  PASS=$((PASS + 1))
else
  echo "FAIL serial resolution waited for the hung adb (${HANG_NOSERIAL_ELAPSED}s)"
  FAILED=$((FAILED + 1))
fi

cat > "${TMP}/check-k2.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
assert len(lines) == 1, "expected 1 error line, got %d" % len(lines)
record = lines[0]
assert record["error"] == "adb shell dumpsys notification timed out after 1s", record
assert record["device_serial"] is None, record
PY
assert_python "devices timeout yields no serial, dump timeout is the record" \
  "${TMP}/check-k2.py" "$HANG_NOSERIAL_FILE"

HANG_LOOP_DIR="${TMP}/out-hang-loop"
HANG_LOOP_FILE="${HANG_LOOP_DIR}/notifications-${TODAY}.hcj.jsonl"
HANG_LOOP_START="$(TZ=Asia/Seoul date -d '-1 second' +%Y-%m-%dT%H:%M:%S%:z)"
HANG_LOOP_END="$(TZ=Asia/Seoul date -d '+11 seconds' +%Y-%m-%dT%H:%M:%S%:z)"
FAKE_ADB_HANG=30 FAKE_DUMP="$FIXTURE_ONE" ADB_TIMEOUT_SEC=1 \
  bash "$TOOL" --adb "$FAKE_ADB" --serial FAKE123 --out-dir "$HANG_LOOP_DIR" \
  --interval 5 --window "${HANG_LOOP_START}/${HANG_LOOP_END}" \
  > "${TMP}/run-hang-loop.out" 2>&1
HANG_LOOP_RC=$?
assert_eq "loop with a hanging adb exits 0" 0 "$HANG_LOOP_RC"
cat > "${TMP}/check-k3.py" <<'PY'
import json
import sys

lines = [json.loads(line) for line in
         open(sys.argv[1], "r", encoding="utf-8") if line.strip()]
ends = [record for record in lines if record.get("kind") == "observer_end"]
assert len(ends) == 1, "expected one observer_end, got %d" % len(ends)
errors = [record for record in lines if record.get("error")]
assert ends[0]["polls"] >= 2, ends[0]
assert len(errors) == ends[0]["polls"], (len(errors), ends[0])
for record in errors:
    assert "timed out after" in record["error"], record
assert not [record for record in lines if "tag" in record]
PY
assert_python "every hung poll is one timeout line and the loop continues" \
  "${TMP}/check-k3.py" "$HANG_LOOP_FILE"

# ------------------------------------------------------------- summary
echo
if [ "$FAILED" -eq 0 ]; then
  echo "OBSERVE NOTIFICATIONS TESTS PASSED (${PASS} checks)"
  exit 0
fi
echo "OBSERVE NOTIFICATIONS TESTS FAILED (${FAILED} of $((PASS + FAILED)) checks)"
exit 1