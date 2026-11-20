#!/usr/bin/env bash
## Full contract suite with a real fail-fast exit code.
##
## Why this exists: `nimble test` runs its task's `exec` lines through
## nimscript, and a failed command raises inside nimble's script runner,
## which prints "Exception raised during nimble script execution" but the
## nimble process still exits 0. A red suite therefore passed the required
## `ci` check on a real main push (2026-10-29, run 40883550758: the build
## contract suite failed, the check reported success). CI and the
## attestation test gate run THIS script; the nimble `test` task delegates
## to it for convenience only -- the gate is the script.
##
## Fail-closed: set -e stops at the first failing suite, and every
## assertion-counting script must itself exit non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

run() {
  echo "=== $* ==="
  "$@"
}

run nim c -r --hints:off --warnings:off --path:src tests/test_all.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_engine_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_provenance_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_input_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_bars_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_rest_failure_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_rest_resp_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_preopen_seed_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_preopen_inject_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_backfill_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_sub_input_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_vendor_input.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_recorder_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_tickwire_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_event_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_event_gen_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_subcheck_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_collector_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_collector_stream_contract.nim
run nim c -r --hints:off --warnings:off --path:src tests/test_subscription_selection_contract.nim
run bash tests/test_collector_pipe_contract.sh
run bash tools/collector/test_sidecar.sh
run bash tests/test_collector_sidecar_init.sh
run bash tools/notify/test_notify.sh
run bash tools/notify/drill/drill_fcm.sh
run bash tools/notify/drill/drill_watch.sh
run bash tools/api/test_api.sh
run bash tools/container/test_supervisor.sh
run bash tests/test_container_contract.sh
run bash tests/test_cli_contract.sh
run bash tests/test_build_contract.sh
run bash tests/test_install_attested.sh
run bash tests/test_retention_contract.sh
run bash tests/test_launcher_ops_alert.sh
run bash tests/test_launcher_worker_order.sh
run bash tests/test_observe_notifications.sh
run python3 tests/test_attest_notifications.py
run python3 tests/test_observe_schedule.py
run python3 tests/test_calendar_source.py
run python3 tests/test_market_time.py
run python3 tests/test_ssot_consistency.py

echo "ALL CONTRACT SUITES PASSED"
