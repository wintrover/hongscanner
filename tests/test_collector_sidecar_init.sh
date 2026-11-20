#!/usr/bin/env bash
## Collector -> sidecar init seam contract.
##
## The REAL collector's init line must be accepted by the REAL
## sidecar.parse_init for every page cap the collector accepts, including
## the production declaration --page-cap=40.
##
## Why this exists (2026-11-20 09:40 restart): collector.nim declared
## page_cap 1..200 but sidecar.py pinned the single value 10. Each side's
## own suite stayed green (the collector contract test uses a stub
## sidecar; the sidecar test only fed 10), yet the production restart died
## before init with "sidecar pipe closed" and wrote zero market records.
## This test binds the two sources mechanically: the dumped init line is
## fed verbatim to the real parser.
##
## No network, no credentials, no live data: the stub sidecar next to the
## binary dumps its stdin init line and exits. Runs in a private mktemp
## sandbox. Run: bash tests/test_collector_sidecar_init.sh
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
    echo "FAIL $1: [$3] not found in [$2]"; FAILED=$((FAILED + 1))
  fi
}

PY=""
if [ -n "${HSCOLLECTOR_PYTHON:-}" ]; then
  PY="$HSCOLLECTOR_PYTHON"
elif [ -x tools/collector/.venv/bin/python ]; then
  PY="$REPO_ROOT/tools/collector/.venv/bin/python"
elif command -v python3.13 >/dev/null 2>&1; then
  PY="python3.13"
elif command -v uv >/dev/null 2>&1; then
  PY="$(uv python find 3.13)"
fi
if [ -z "$PY" ]; then
  echo "test_collector_sidecar_init.sh: no Python 3.13 interpreter" >&2
  exit 1
fi
if ! "$PY" -c 'import websockets' >/dev/null 2>&1; then
  echo "test_collector_sidecar_init.sh: $PY lacks websockets;" \
       "run bash tools/collector/test_sidecar.sh first" >&2
  exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hs-init-seam.XXXXXX")"
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

BIN="$SANDBOX/collector"
echo "compiling the collector from $REPO_ROOT/tools/collector"
(cd "$REPO_ROOT" && nim c -d:release --hints:off --warnings:off \
  --path:"$REPO_ROOT/src" --nimcache:"$SANDBOX/nimcache" \
  -o:"$BIN" tools/collector/collector.nim) > "$SANDBOX/compile.log" 2>&1 || {
    echo "FAIL collector does not compile:"; cat "$SANDBOX/compile.log"; exit 1; }
echo "ok   collector compiles"; PASS=$((PASS + 1))

cat > "$SANDBOX/cal.json" <<'EOF'
{"days":{"2026-10-30":{"close":"15:30:00+09:00","open":"09:00:00+09:00"}},
 "version":"CAL-TEST"}
EOF

# The stub replaces sidecar.py via sidecarScript()'s first candidate (a
# sidecar.py next to the binary): it dumps the collector's init line
# verbatim and exits without the termination protocol, so the collector
# closes honestly INCOMPLETE (exit 4) — enough to capture init.
cat > "$SANDBOX/sidecar.py" <<'EOF'
import sys

# The collector waits for its ready event before sending connect; emit it
# first (README §2.1), then dump the init line it sent.
sys.stdout.write('{"ev":"ready","t":"2026-10-30T09:00:00+09:00"}\n')
sys.stdout.flush()
init = sys.stdin.readline()
with open("initdump.json", "w", encoding="utf-8") as f:
    f.write(init)
sys.stdin.readline()  # connect
sys.exit(0)
EOF

run_cap() { # cap -> writes $SANDBOX/initdump.json from that run
  local cap="$1"
  local out="$SANDBOX/run-$cap"
  rm -f "$SANDBOX/initdump.json"
  local rc=0
  (cd "$SANDBOX" && HSCOLLECTOR_PYTHON=python3 PYTHONDONTWRITEBYTECODE=1 \
    "$BIN" --profile=init-seam --session-date=2026-10-30 \
    --calendar="$SANDBOX/cal.json" --page-cap="$cap" --out="$out" \
    > "$SANDBOX/collector-$cap.stdout" \
    2> "$SANDBOX/collector-$cap.stderr") || rc=$?
  assert_eq "collector --page-cap=$cap closes honestly INCOMPLETE" 4 "$rc"
  assert_present "collector --page-cap=$cap dumped its init line" \
    "$SANDBOX/initdump.json"
  local dump
  dump="$(cat "$SANDBOX/initdump.json")"
  assert_contains "collector --page-cap=$cap declares its cap" \
    "$dump" "\"page_cap\":$cap"
  local accepted
  accepted="$("$PY" - "$SANDBOX/initdump.json" <<'PYEOF'
import json, sys
sys.path.insert(0, "tools/collector")
import sidecar
cfg = sidecar.parse_init(open(sys.argv[1], encoding="utf-8").read())
print("INIT_ACCEPTED page_cap=%d" % cfg["page_cap"])
PYEOF
)" || accepted="INIT_REJECTED"
  assert_eq "real sidecar accepts collector --page-cap=$cap init" \
    "INIT_ACCEPTED page_cap=$cap" "$accepted"
}

assert_present() { # desc path
  if [ -f "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: $2 is missing"; FAILED=$((FAILED + 1))
  fi
}

run_cap 10
run_cap 40

echo "PASS=$PASS FAILED=$FAILED"
[ "$FAILED" -eq 0 ]