#!/usr/bin/env bash
## Pre-open daily seed capture (P-run) launcher — the server entry point
## (REPLAY_CONTRACT §12.10.1). One invocation = one P-run directory
## (default runs/<session_date>-preopen/) whose last record is the
## daily_seed_manifest seal.
##
## The collector binary's `--preopen` mode owns the sidecar, the recorder
## and every validation; this launcher only supplies the run identity (the
## session date and the run directory), records its own provenance, and
## preserves the collector's exit code:
##   0  sealed P-run (manifest appended, recorder abandoned)
##   2  usage/refusal/calendar-independent config error (nothing captured)
##   3  the session date is not covered by the approved calendar
##   4  capture failed / window overrun (no manifest; evidence preserved)
##
## Evidence: runs/<session_date>.preopen.log (a SIBLING of the run dir —
## the run dir itself belongs to the collector, which refuses to overwrite
## an existing one). An existing run directory is refused before the
## collector starts: a failed P-run is preserved as evidence, never
## retried into the same path.
##
## Usage: tools/run_preopen.sh --session-date=YYYY-MM-DD
##                             --calendar=<approved snapshot>
##                             [--out=<run dir>]
##                             [--profile=<alias>] [--environment=demo|real]
##                             [--preopen-markets=0,10]
##                             [--preopen-page-cap=10]
##                             [any other collector --preopen argument]
## Env:   HSCOLLECTOR_BIN  collector binary (default
##                         <repo>/tools/collector/collector)
##        HSCOLLECTOR_PYTHON  sidecar interpreter (passed through)
## Exit:  the collector's exit code; 2 for launcher usage/refusal.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  printf 'usage: tools/run_preopen.sh --session-date=YYYY-MM-DD --calendar=PATH [--out=DIR] [collector --preopen args...]\n' >&2
}

OUT=""
SESSION_DATE=""
CALENDAR=""
for arg in "$@"; do
  case "$arg" in
    --out=*) OUT="${arg#--out=}" ;;
    --session-date=*) SESSION_DATE="${arg#--session-date=}" ;;
    --calendar=*) CALENDAR="${arg#--calendar=}" ;;
  esac
done
if [ -z "$SESSION_DATE" ]; then
  usage
  exit 2
fi
case "$SESSION_DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *)
    echo "run_preopen: --session-date must be YYYY-MM-DD: $SESSION_DATE" >&2
    exit 2
    ;;
esac
if [ -z "$CALENDAR" ]; then
  echo "run_preopen: --calendar is required (the approved snapshot)" >&2
  usage
  exit 2
fi
if [ -z "$OUT" ]; then
  OUT="$REPO/runs/$SESSION_DATE-preopen"
fi
case "$OUT" in
  /*) OUT_ABS="$OUT" ;;
  *)  OUT_ABS="$PWD/$OUT" ;;
esac
SESSION="$(basename "$OUT_ABS")"
LOG_DIR="$(dirname "$OUT_ABS")"
PREOPEN_LOG="$LOG_DIR/$SESSION_DATE.preopen.log"

COLLECTOR="${HSCOLLECTOR_BIN:-$REPO/tools/collector/collector}"
if [ ! -x "$COLLECTOR" ]; then
  echo "run_preopen: collector not executable: $COLLECTOR" >&2
  exit 2
fi
if [ -d "$OUT_ABS" ] || [ -f "$OUT_ABS" ]; then
  echo "run_preopen: PRE-OPEN REFUSED: the run directory already exists," \
    "refusing to overwrite: $OUT_ABS" >&2
  exit 2
fi

mkdir -p "$LOG_DIR"        # the run dir itself stays the collector's (O_EXCL)
touch "$PREOPEN_LOG"

# The launcher records its own execution identity so the P-run evidence
# names the commit and launcher bytes that produced it. Each lookup
# degrades to "unknown" instead of aborting the capture.
STARTED_AT="$(date --iso-8601=seconds)"
GIT_COMMIT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
if ! printf '%s' "$GIT_COMMIT" | grep -Eq '^[0-9a-f]{40}$'; then
  GIT_COMMIT="unknown"
fi
LAUNCHER_SHA256="$(sha256sum "$REPO/tools/run_preopen.sh" 2>/dev/null || true)"
LAUNCHER_SHA256="${LAUNCHER_SHA256%% *}"
if ! printf '%s' "$LAUNCHER_SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
  LAUNCHER_SHA256="unknown"
fi
GIT_DIRTY="unknown"
if GIT_STATUS="$(git -C "$REPO" status --porcelain 2>/dev/null)"; then
  if [ -n "$GIT_STATUS" ]; then GIT_DIRTY=1; else GIT_DIRTY=0; fi
fi

{
  echo "=== run_preopen start $(date --iso-8601=seconds)"
  echo "collector=$COLLECTOR"
  echo "log=$PREOPEN_LOG"
  echo "PREOPEN_PROVENANCE run_id=$SESSION session_date=$SESSION_DATE" \
    "git_commit=$GIT_COMMIT launcher_sha256=$LAUNCHER_SHA256" \
    "git_dirty=$GIT_DIRTY started_at=${STARTED_AT:-unknown}"
} >>"$PREOPEN_LOG"

# The caller's --out/--session-date are replaced by the canonical values
# above; every other argument passes through verbatim, including a
# caller-supplied --preopen (harmless: the mode is selected, not counted).
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --out=*|--session-date=*) ;;
    *) ARGS+=("$arg") ;;
  esac
done
ARGS=(--preopen "--session-date=$SESSION_DATE" "--out=$OUT_ABS" "${ARGS[@]}")

"$COLLECTOR" "${ARGS[@]}" >>"$PREOPEN_LOG" 2>&1
PREOPEN_RC=$?
echo "PREOPEN_EXIT=$PREOPEN_RC" >>"$PREOPEN_LOG"
echo "=== run_preopen end $(date --iso-8601=seconds) exit=$PREOPEN_RC" \
  >>"$PREOPEN_LOG"
if [ "$PREOPEN_RC" -ne 0 ]; then
  echo "run_preopen: PRE-OPEN INCOMPLETE (exit=$PREOPEN_RC, log: $PREOPEN_LOG)" >&2
fi
exit "$PREOPEN_RC"