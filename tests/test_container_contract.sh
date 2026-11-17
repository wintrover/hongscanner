#!/usr/bin/env bash
## Container contract suite (tools/container/README.md): builds the
## single-container image through the documented STAGED build
## context and exercises it end to end — image layout, purpose label,
## supervisor ENTRYPOINT + env pins, fixture volumes, HTTP contract,
## SIGTERM shutdown, image removal.
##
## Fail-closed: without a working docker CLI/daemon this exits 1 with a
## clear message. tools/run_tests.sh includes this suite, so a
## docker-less environment FAILS the gate — that is the documented
## contract (README §6), not a limitation to route around.
##
## The image under test is a TEST artifact: it carries locally compiled
## binaries (the same nim c pattern as tests/test_cli_contract.sh for
## hongscanner and tests/test_collector_pipe_contract.sh for the
## collector) and therefore the org.hongscanner.image-purpose=ci-test
## not-for-deployment marker. The production image (PR-5: attested
## CI_BUILD_OUT binaries through the same staged context, no marker) is a
## separate artifact this suite never builds or uses.
##
## PR-5 image contents (tools/container/README.md §8): besides the
## hongscanner binary the staged context carries the collector binary,
## sidecar.py (colocated with it: collector.nim resolves the sidecar
## script next to its own binary), requirements.txt and the four notify
## modules; the in-image asserts cover the collector (exec bit, byte
## identity), the sidecar/notify layout, $HSCOLLECTOR_PYTHON=python3 and
## the one pinned sidecar dependency (websockets==17.3 importable).
##
## PR-4 runtime supervisor (tools/container/README.md §7): the staged
## context also carries tools/container/cloud_supervisor.py and the
## image ENTRYPOINT is the supervisor. The asserts cover the
## ENTRYPOINT, the supervisor env pins (exactly the code defaults), the
## 8081 probe port and the supervisor file itself. The fixture run
## below mounts no calendar volume, so the supervisor stays in
## initialization (/startup 503) and starts no session; the API child
## serves the SERVE line and /status regardless — that is the smoke's
## subject here.
##
## Calendars: the git-tracked calendars/CALENDAR_INDEX.sha256 is staged
## and asserted byte-identical in the image; the real calendars/*.json
## (gitignored user data) are never staged, mounted or asserted against.
##
## Everything runs inside one private mktemp sandbox; the container and
## the image are removed on every path (success, failure, trap). No
## path outside the sandbox is ever written or removed.
##
## Run: bash tests/test_container_contract.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LABEL_KEY="org.hongscanner.image-purpose"
LABEL_VALUE="ci-test"
IMAGE_TAG="hs-container-contract:test-$$"
CNAME="hs-container-contract-$$"

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
    echo "FAIL $1: [$2] does not contain [$3]"; FAILED=$((FAILED + 1))
  fi
}

# ----------------------------------------------------- docker, fail-closed
if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL test_container_contract.sh: docker CLI not found —" \
       "the container contract suite requires docker (fail-closed;" \
       "tools/run_tests.sh includes this suite, so a docker-less" \
       "environment fails the gate by contract, README §6)" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "FAIL test_container_contract.sh: docker daemon is not reachable" \
       "(docker info failed) — fail-closed" >&2
  exit 1
fi
echo "ok   docker daemon reachable"; PASS=$((PASS + 1))

# ------------------------------------------------ interpreter (same order
# as tools/api/test_api.sh §6): $HSCOLLECTOR_PYTHON, python3.13,
# `uv python find 3.13`. Used for the synthetic fixture bytes and the
# /status response validation. No interpreter, no suite: fail-closed.
PY=""
if [ -n "${HSCOLLECTOR_PYTHON:-}" ]; then
  PY="$HSCOLLECTOR_PYTHON"
elif command -v python3.13 >/dev/null 2>&1; then
  PY="python3.13"
elif command -v uv >/dev/null 2>&1; then
  PY="$(uv python find 3.13)"
fi
if [ -z "$PY" ]; then
  echo "FAIL test_container_contract.sh: no Python 3.13 interpreter" \
       "found (tried \$HSCOLLECTOR_PYTHON, python3.13, 'uv python find 3.13')" >&2
  exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hs-container-test.XXXXXX")"
cleanup() {
  if [ -n "${CNAME:-}" ]; then
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
  fi
  if [ -n "${IMAGE_TAG:-}" ]; then
    docker rmi "$IMAGE_TAG" "$IMAGE_TAG-probe" >/dev/null 2>&1 || true
  fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# ---------------------------------------------------- test binary (the
# tests/test_cli_contract.sh compile pattern: direct nim c into the
# sandbox, never tools/build.sh, never the repository root build).
BIN="$SANDBOX/hongscanner"
echo "compiling test binary from $REPO_ROOT/src"
(cd "$REPO_ROOT" && nim c --hints:off --warnings:off \
  --path:"$REPO_ROOT/src" --nimcache:"$SANDBOX/nimcache" \
  -o:"$BIN" src/hongscanner.nim) > "$SANDBOX/compile.log" 2>&1 || {
    echo "FAIL test binary does not compile:"; cat "$SANDBOX/compile.log"; exit 1; }
echo "ok   test binary compiles"; PASS=$((PASS + 1))

# ---------------------------------------------------- test collector (the
# tests/test_collector_pipe_contract.sh compile pattern: same -d:release
# nim c into the sandbox, its own nimcache, never the repo-root build).
CBIN="$SANDBOX/collector"
echo "compiling test collector from $REPO_ROOT/tools/collector"
(cd "$REPO_ROOT" && nim c -d:release --hints:off --warnings:off \
  --path:"$REPO_ROOT/src" --nimcache:"$SANDBOX/nimcache-collector" \
  -o:"$CBIN" tools/collector/collector.nim) > "$SANDBOX/compile-collector.log" 2>&1 || {
    echo "FAIL test collector does not compile:"; cat "$SANDBOX/compile-collector.log"; exit 1; }
echo "ok   test collector compiles"; PASS=$((PASS + 1))

# ---------------------------------------------------- staged build
# context (README §2): the builder copies the needed files into a fresh
# directory and builds THAT as the context — a Docker COPY can never
# reach outside the context. .dockerignore travels with the context.
CTX="$SANDBOX/context"
mkdir -p "$CTX/bin" "$CTX/tools/api" "$CTX/tools/collector" \
         "$CTX/tools/container" "$CTX/tools/notify" "$CTX/calendars"
cp "$REPO_ROOT/Dockerfile" "$CTX/Dockerfile"
cp "$REPO_ROOT/.dockerignore" "$CTX/.dockerignore"
cp "$REPO_ROOT/tools/api/serve.py" "$CTX/tools/api/serve.py"
cp "$REPO_ROOT/tools/container/cloud_supervisor.py" \
   "$CTX/tools/container/cloud_supervisor.py"
cp "$REPO_ROOT/calendars/CALENDAR_INDEX.sha256" \
   "$CTX/calendars/CALENDAR_INDEX.sha256"
cp "$BIN" "$CTX/bin/hongscanner"
cp "$CBIN" "$CTX/bin/collector"
cp "$REPO_ROOT/tools/collector/sidecar.py" "$CTX/tools/collector/sidecar.py"
cp "$REPO_ROOT/tools/collector/requirements.txt" \
   "$CTX/tools/collector/requirements.txt"
for f in notify_dispatcher.py notify_config.py notify_fcm.py \
         notify_ledger.py; do
  cp "$REPO_ROOT/tools/notify/$f" "$CTX/tools/notify/$f"
done
assert_file_in_context() { # desc path
  if [ -f "$2" ]; then
    echo "ok   $1"; PASS=$((PASS + 1))
  else
    echo "FAIL $1: $2 is missing"; FAILED=$((FAILED + 1))
  fi
}
assert_file_in_context "staged Dockerfile" "$CTX/Dockerfile"
assert_file_in_context "staged .dockerignore" "$CTX/.dockerignore"
assert_file_in_context "staged serve.py" "$CTX/tools/api/serve.py"
assert_file_in_context "staged cloud_supervisor.py" \
  "$CTX/tools/container/cloud_supervisor.py"
assert_file_in_context "staged CALENDAR_INDEX.sha256" \
  "$CTX/calendars/CALENDAR_INDEX.sha256"
assert_file_in_context "staged test binary" "$CTX/bin/hongscanner"
assert_file_in_context "staged test collector" "$CTX/bin/collector"
assert_file_in_context "staged sidecar.py" "$CTX/tools/collector/sidecar.py"
assert_file_in_context "staged requirements.txt" \
  "$CTX/tools/collector/requirements.txt"
for f in notify_dispatcher.py notify_config.py notify_fcm.py \
         notify_ledger.py; do
  assert_file_in_context "staged tools/notify/$f" "$CTX/tools/notify/$f"
done
assert_eq "no calendar json in the staged context" 0 \
  "$(find "$CTX/calendars" "$CTX" -maxdepth 1 -name '*.json' | wc -l)"

# ------------------------------- synthetic fixture (README §6; minimal
# composition in the tools/api/test_api.py style: canonical JSONL bytes,
# one run directory + one two-record ledger; nothing real).
FIX="$SANDBOX/fixture"
mkdir -p "$FIX/runs/container-smoke-run" "$FIX/notify"
"$PY" - "$FIX" <<'PY'
import hashlib, json, os, sys

def canonical(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")

def jsonl(*objs):
    return b"".join(canonical(o) + b"\n" for o in objs)

def event_id(tag):
    return hashlib.sha256(b"container-fixture-" + tag).hexdigest()

fix = sys.argv[1]
entered = {
    "data_quality": "OBSERVING",
    "event_id": event_id(b"entered"),
    "event_type": "CANDIDATE_ENTERED",
    "evidence_ref": hashlib.sha256(b"evidence-entered").hexdigest(),
    "observed_at": "2026-10-29T09:12:33+09:00",
    "rule_id": "candidate-entered",
    "rule_version": 1,
    "session_id": "2026-10-29",
    "severity": "INFO",
}
ended = {
    "data_quality": "OBSERVING",
    "event_id": event_id(b"ended"),
    "event_type": "SESSION_ENDED",
    "evidence_ref": hashlib.sha256(b"evidence-ended").hexdigest(),
    "observed_at": "2026-10-29T15:30:00+09:00",
    "rule_id": "session-close-v1",
    "rule_version": 1,
    "session_id": "2026-10-29",
    "severity": "INFO",
}
run = os.path.join(fix, "runs", "container-smoke-run")
with open(os.path.join(run, "run.json"), "wb") as f:
    f.write(canonical({
        "code_commit": hashlib.sha256(b"container-smoke").hexdigest(),
        "run_id": "container-smoke-run",
        "session_date": "2026-10-29",
        "started_at": "2026-10-29T08:00:00+09:00",
    }) + b"\n")
with open(os.path.join(run, "input.hcj.jsonl"), "wb") as f:
    f.write(jsonl({"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
                  {"kind": "config", "raw": {"session_date": "2026-10-29"},
                   "seq": 2},
                  {"kind": "session_end", "raw": None, "seq": 3}))
with open(os.path.join(run, "events.hcj.jsonl"), "wb") as f:
    f.write(jsonl(ended))
with open(os.path.join(fix, "notify", "ledger.hcj.jsonl"), "wb") as f:
    f.write(jsonl(entered, ended))
PY
chmod -R a+rX "$FIX"
echo "ok   synthetic fixture written"; PASS=$((PASS + 1))

# ------------------------------------------------------------- build
echo "--- image build (staged context)"
RC=0
docker build -t "$IMAGE_TAG" --label "$LABEL_KEY=$LABEL_VALUE" "$CTX" \
  > "$SANDBOX/build.log" 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "FAIL docker build failed (rc=$RC):"; tail -40 "$SANDBOX/build.log"
  exit 1
fi
echo "ok   image builds from the staged context"; PASS=$((PASS + 1))

LABEL_GOT="$(docker inspect --format \
  "{{index .Config.Labels \"$LABEL_KEY\"}}" "$IMAGE_TAG")"
assert_eq "image carries the ci-test not-for-deployment label" \
  "$LABEL_VALUE" "$LABEL_GOT"

USER_GOT="$(docker inspect --format '{{.Config.User}}' "$IMAGE_TAG")"
if [ -n "$USER_GOT" ] && [ "$USER_GOT" != "root" ] && [ "$USER_GOT" != "0" ]; then
  echo "ok   image declares a non-root user ($USER_GOT)"; PASS=$((PASS + 1))
else
  echo "FAIL image user is [$USER_GOT] — must be non-root"
  FAILED=$((FAILED + 1))
fi

EXPOSED="$(docker inspect --format '{{json .Config.ExposedPorts}}' "$IMAGE_TAG")"
assert_contains "image exposes 8080/tcp (API)" "$EXPOSED" "8080/tcp"
assert_contains "image exposes 8081/tcp (supervisor probes)" "$EXPOSED" \
  "8081/tcp"

CMD_JSON="$(docker inspect --format '{{json .Config.Cmd}}' "$IMAGE_TAG")"
ENTRYPOINT_JSON="$(docker inspect --format '{{json .Config.Entrypoint}}' \
  "$IMAGE_TAG")"
assert_contains "ENTRYPOINT is the cloud runtime supervisor (PR-4)" \
  "$ENTRYPOINT_JSON" '"/opt/hongscanner/cloud_supervisor.py"'
assert_eq "no leftover CMD — the supervisor is the whole container command" \
  "null" "$CMD_JSON"

ENV_JSON="$(docker inspect --format '{{json .Config.Env}}' "$IMAGE_TAG")"
assert_contains "ENV pins the API bind 0.0.0.0 (container-only, behind the ingress)" \
  "$ENV_JSON" '"HS_API_BIND=0.0.0.0"'
assert_contains "ENV pins the API port 8080" "$ENV_JSON" '"HS_API_PORT=8080"'
assert_contains "ENV pins the supervisor probe port 8081" "$ENV_JSON" \
  '"HS_SUPERVISOR_PROBE_PORT=8081"'
assert_contains "ENV pins the data root (runs + ledger derive from it)" \
  "$ENV_JSON" '"HS_DATA_ROOT=/var/lib/hongscanner"'
assert_contains "ENV pins the calendar dir (volume-supplied, never baked)" \
  "$ENV_JSON" '"HS_CALENDAR_DIR=/var/lib/hongscanner/calendars"'
assert_contains "ENV pins the calendar index (baked)" "$ENV_JSON" \
  '"HS_CALENDAR_INDEX=/opt/hongscanner/CALENDAR_INDEX.sha256"'

# .dockerignore effectiveness probe (README §2/§4): in a probe context
# with the same .dockerignore, a SYNTHETIC decoy calendar json must be
# UNREACHABLE to COPY. Exclusion is observed, not assumed — and the
# decoy is test-authored bytes, never a real calendar file.
PCTX="$SANDBOX/probe-context"
mkdir -p "$PCTX/calendars"
cp "$REPO_ROOT/.dockerignore" "$PCTX/.dockerignore"
echo '{"days":{},"version":"CAL-DECOY"}' > "$PCTX/calendars/krx-fake.json"
cat > "$SANDBOX/probe.Dockerfile" <<'EOF'
FROM python:3.13-slim
COPY calendars/krx-fake.json /probe
EOF
PRC=0
docker build -f "$SANDBOX/probe.Dockerfile" -t "$IMAGE_TAG-probe" \
  "$PCTX" > "$SANDBOX/probe.log" 2>&1 || PRC=$?
assert_eq ".dockerignore makes a calendar json unreachable to COPY" \
  1 "$PRC"
assert_contains "the probe COPY failure is the documented exclusion" \
  "$(cat "$SANDBOX/probe.log")" "not found"

# ---------------------------------------------------- in-image contract
RC=0
docker run --rm --entrypoint /bin/sh "$IMAGE_TAG" -c '
set -e
test -f /opt/hongscanner/serve.py
test -f /opt/hongscanner/cloud_supervisor.py
test -x /opt/hongscanner/bin/hongscanner
test -x /opt/hongscanner/bin/collector
test -f /opt/hongscanner/bin/sidecar.py
test -f /opt/hongscanner/tools/collector/requirements.txt
test -f /opt/hongscanner/tools/notify/notify_dispatcher.py
test -f /opt/hongscanner/tools/notify/notify_config.py
test -f /opt/hongscanner/tools/notify/notify_fcm.py
test -f /opt/hongscanner/tools/notify/notify_ledger.py
test -f /opt/hongscanner/CALENDAR_INDEX.sha256
test ! -e /var/lib/hongscanner/notify/ledger.hcj.jsonl
[ -z "$(find /opt/hongscanner -name "*.json")" ]
[ "$(id -u)" -ne 0 ]
[ "$(printenv HSCOLLECTOR_PYTHON)" = "python3" ]
' || RC=$?
assert_eq "in-image layout: serve.py + supervisor + executable binaries + collector-sidecar-notify files + baked INDEX, no baked ledger, no calendar json, non-root uid, HSCOLLECTOR_PYTHON=python3" \
  0 "$RC"
HOST_INDEX_SHA="$(sha256sum "$REPO_ROOT/calendars/CALENDAR_INDEX.sha256" \
  | cut -d' ' -f1)"
IMG_INDEX_SHA="$(docker run --rm --entrypoint /bin/sh "$IMAGE_TAG" \
  -c 'sha256sum /opt/hongscanner/CALENDAR_INDEX.sha256' | cut -d' ' -f1)"
assert_eq "baked CALENDAR_INDEX.sha256 is byte-identical to the tracked file" \
  "$HOST_INDEX_SHA" "$IMG_INDEX_SHA"
HOST_BIN_SHA="$(sha256sum "$CTX/bin/hongscanner" | cut -d' ' -f1)"
IMG_BIN_SHA="$(docker run --rm --entrypoint /bin/sh "$IMAGE_TAG" \
  -c 'sha256sum /opt/hongscanner/bin/hongscanner' | cut -d' ' -f1)"
assert_eq "the image carries exactly the staged test binary" \
  "$HOST_BIN_SHA" "$IMG_BIN_SHA"
HOST_COL_SHA="$(sha256sum "$CTX/bin/collector" | cut -d' ' -f1)"
IMG_COL_SHA="$(docker run --rm --entrypoint /bin/sh "$IMAGE_TAG" \
  -c 'sha256sum /opt/hongscanner/bin/collector' | cut -d' ' -f1)"
assert_eq "the image carries exactly the staged collector binary" \
  "$HOST_COL_SHA" "$IMG_COL_SHA"

# Sidecar dependency contract: python3 in the image imports
# websockets==17.3 — the only pip-installed package, the exact version
# whose wire behavior is the measured contract
# (tools/collector/requirements.txt).
RC=0
docker run --rm --entrypoint /bin/sh "$IMAGE_TAG" -c '
python3 -c "import websockets" || exit 1
python3 - <<PY
import importlib.metadata as m
v = m.version("websockets")
assert v == "17.3", v
print("websockets", v)
PY
' > "$SANDBOX/img-websockets.txt" 2>&1 || RC=$?
assert_eq "in-image python3 imports websockets==17.3 (the only sidecar dependency)" \
  0 "$RC"
assert_contains "the version check named 17.3 inside the image" \
  "$(cat "$SANDBOX/img-websockets.txt")" "websockets 17.3"

# Collector usage smoke (README §8 mirror of attest.yml): no args is a
# usage error by contract (collector exit codes: 2 = usage), which proves
# the binary executes in-image as the non-root user.
IMG_USAGE_RC="$(docker run --rm --entrypoint /bin/sh "$IMAGE_TAG" \
  -c '/opt/hongscanner/bin/collector >/dev/null 2>&1; echo $?')"
assert_eq "in-image collector no-args exits 2 (usage contract)" \
  2 "$IMG_USAGE_RC"

# ------------------------------------------------------------- run
echo "--- container run (fixture volumes, loopback-published port)"
RC=0
docker run -d --name "$CNAME" \
  -p 127.0.0.1::8080 \
  -v "$FIX/runs:/var/lib/hongscanner/runs" \
  -v "$FIX/notify:/var/lib/hongscanner/notify" \
  "$IMAGE_TAG" > "$SANDBOX/run.id" 2>"$SANDBOX/run.err" || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "FAIL docker run failed (rc=$RC):"; cat "$SANDBOX/run.err"; exit 1
fi
echo "ok   container starts detached"; PASS=$((PASS + 1))

PORT_LINE="$(docker port "$CNAME" 8080)"
assert_contains "port is published on 127.0.0.1 only" "$PORT_LINE" "127.0.0.1:"
HOST_PORT="$(printf '%s' "$PORT_LINE" | awk '{ n = split($NF, a, ":"); print a[n] }')"

# The SERVE line is the startup evidence the contract accepts
# (tools/api/README.md §1); the §8 SERVE_PROVENANCE line precedes it —
# the grep anchors on '^SERVE ' (space), which the provenance line's
# 'SERVE_PROVENANCE' prefix never matches.
SERVE_LINE=""
for _ in $(seq 1 120); do
  SERVE_LINE="$(docker logs "$CNAME" 2>/dev/null | grep -m1 '^SERVE ' || true)"
  if [ -n "$SERVE_LINE" ]; then break; fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$CNAME" 2>/dev/null)" \
       != "true" ]; then break; fi
  sleep 0.5
done
assert_eq "SERVE line printed (serve.py startup evidence)" \
  "SERVE 0.0.0.0:8080" "$SERVE_LINE"
if [ -z "$SERVE_LINE" ]; then
  echo "FAIL container never served — aborting the network phase:"
  docker logs "$CNAME" 2>&1 | tail -20 || true
  exit 1
fi

BASE="http://127.0.0.1:$HOST_PORT"
CODE="$(curl -sS -o "$SANDBOX/status.json" -w '%{http_code}' \
  "$BASE/status" 2>/dev/null || echo 000)"
assert_eq "GET /status over the published loopback port is 200" 200 "$CODE"
VRC=0
"$PY" - "$SANDBOX/status.json" <<'PY' || VRC=$?
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(body) == {"sessions", "events", "delivery", "readiness"}, body
assert body["sessions"]["count"] == 1, body["sessions"]
latest = body["sessions"]["latest"]
assert latest["run_json_present"] is True, latest
assert latest["run_id"] == "container-smoke-run", latest
assert latest["session_date"] == "2026-10-29", latest
events = body["events"]
assert events["ledger_present"] is True, events
assert events["count"] == 2, events
assert events["by_type"] == {"CANDIDATE_ENTERED": 1, "SESSION_ENDED": 1}, events
assert body["delivery"]["configured"] is False, body["delivery"]
# The §8.2 readiness block: this fixture has no eligible market run, so
# the prewarm lands READY before the SERVE line is even visible — the
# state is asserted exactly, with the block's two-key shape (no
# composite HEALTHY verdict).
readiness = body["readiness"]
assert set(readiness) == {"state", "error"}, readiness
assert readiness["state"] == "READY", readiness
assert readiness["error"] is None, readiness
PY
assert_eq "GET /status serves the mounted fixture (run dir + ledger)" \
  0 "$VRC"

CODE="$(curl -sS -o "$SANDBOX/405.json" -D "$SANDBOX/405.headers" \
  -w '%{http_code}' -X POST "$BASE/status" 2>/dev/null || echo 000)"
assert_eq "POST /status is 405" 405 "$CODE"
assert_contains "the 405 carries Allow: GET" "$(cat "$SANDBOX/405.headers")" \
  "Allow: GET"
assert_contains "the 405 body names method_not_allowed" \
  "$(cat "$SANDBOX/405.json")" "method_not_allowed"

CODE="$(curl -sS -o "$SANDBOX/404.json" -w '%{http_code}' \
  "$BASE/no-such-endpoint" 2>/dev/null || echo 000)"
assert_eq "GET of an unknown path is 404" 404 "$CODE"
assert_contains "the 404 body names not_found" "$(cat "$SANDBOX/404.json")" \
  "not_found"

# --------------------------------------------------- SIGTERM shutdown
echo "--- shutdown (docker stop = SIGTERM)"
SRC=0
docker stop "$CNAME" >/dev/null || SRC=$?
assert_eq "docker stop returns within the grace period" 0 "$SRC"
STATE="$(docker inspect --format \
  '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}' "$CNAME")"
assert_eq "container exits cleanly on SIGTERM (exited 0, no OOM)" \
  "exited 0 false" "$STATE"

# ------------------------------------------------------- no residue
echo "--- teardown"
RRC=0
docker rm "$CNAME" >/dev/null || RRC=$?
assert_eq "container removed" 0 "$RRC"
IRC=0
docker rmi "$IMAGE_TAG" >/dev/null || IRC=$?
assert_eq "image removed (docker rmi)" 0 "$IRC"
GONE=0
docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || GONE=$?
assert_eq "the test image is gone after rmi" 1 "$GONE"
LEFT="$(docker ps -a --filter "name=$CNAME" --format '{{.Names}}' | wc -l)"
assert_eq "no container with the suite name remains" 0 "$LEFT"

# ---------------------------------------------------------------- summary
echo ""
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
