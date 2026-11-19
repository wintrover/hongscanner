#!/usr/bin/env python3
"""pace_probe — measure the vendor's REST rate limit per API family.

This is a MEASUREMENT TOOL, not a session component: it issues the same
requests the collector would issue, at a caller-chosen spacing, and reports
only status codes / vendor return_code values. It reuses sidecar.TokenStore
(the exact credential path) so a demo run authenticates the same way the
collector does. The token value is never printed, logged, or recorded.

Contract: tools/collector/README.md §5.1 (credential path), §2.8 (ka10081
shape). A probe result is an OPERATING DECLARATION for one environment —
a mock-measured spacing is not evidence about the real domain.

Usage:
  python3 tools/collector/pace_probe.py \
      --environment demo --profile <alias> \
      --api ka10081 --interval 0.5 --count 20

  --mix ka10027  alternates ka10027 and ka10081 in one loop, so an
                 account-global (not per-API) limit also shows up as 429.

Exit codes: 0 measured (whatever the outcome), 3 token failure,
4 usage / internal fault. Results are one JSON object per interval on
stdout plus a final summary line.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sidecar  # noqa: E402  (the credential + domain authority)

DEF_BASE_DT = "20261118"


class Probe:
    def __init__(self, environment, profile, token_source):
        self.environment = environment
        self.rest_domain = sidecar.environment_rest_domain(environment)
        if token_source == "env":
            self.tokens = sidecar.EnvTokenProvider(
                self.rest_domain + sidecar.OAUTH_TOKEN_PATH,
                environment=environment)
        else:
            self.tokens = sidecar.TokenStore(profile)

    def _post(self, path, api_id, body):
        token, token_type = self.tokens.get()
        data = json.dumps(body, ensure_ascii=False,
                          separators=(",", ":")).encode("utf-8")
        req = urllib.request.Request(
            self.rest_domain + path, data=data, method="POST",
            headers={
                "Content-Type": "application/json;charset=utf-8",
                "api-id": api_id,
                "authorization": ("%s %s" % (token_type, token)).strip(),
            })
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            try:
                return e.code, e.read()
            except Exception:
                return e.code, b""
        except Exception as exc:
            raise RuntimeError("transport failed: %s" % type(exc).__name__)

    @staticmethod
    def _return_code(raw):
        try:
            doc = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return None
        if not isinstance(doc, dict):
            return None
        return sidecar.normalize_return_code(doc.get("return_code"))

    def daily(self, symbol, base_dt):
        body = {"base_dt": base_dt, "stk_cd": symbol,
                "upd_stkpc_tp": "1"}
        return self._post(sidecar.CHART_REST_PATH, sidecar.DAILY_API_ID, body)

    def candidate(self, symbol_unused, base_dt):
        params = {
            "mrkt_tp": "000", "trde_qty_cnd": "0000", "stk_cnd": "16",
            "crd_cnd": "0", "updown_incls": "1", "pric_cnd": "0",
            "trde_prica_cnd": "0", "stex_tp": "1", "sort_tp": "1"}
        return self._post(sidecar.REST_PATH, "ka10027", params)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--environment", choices=["demo", "real"],
                    default="demo")
    ap.add_argument("--profile", default="")
    ap.add_argument("--token-source", choices=["kiwoomcli", "env"],
                    default="kiwoomcli")
    ap.add_argument("--api", choices=["ka10081", "ka10027"],
                    default="ka10081")
    ap.add_argument("--mix", choices=["", "ka10027"], default="")
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--count", type=int, default=20)
    ap.add_argument("--base-dt", default=DEF_BASE_DT)
    ap.add_argument("--symbols",
                    default="006660,000020,000100,000120,000140")
    args = ap.parse_args(argv)
    if args.interval <= 0 or args.count <= 0:
        raise SystemExit("interval and count must be positive")
    if args.token_source == "kiwoomcli" and not args.profile:
        raise SystemExit("--profile is required for token_source=kiwoomcli")
    if args.environment == "real" and args.token_source == "env" and \
            not os.environ.get("APP_KEY_REAL"):
        raise SystemExit("APP_KEY_REAL missing")

    probe = Probe(args.environment, args.profile, args.token_source)
    symbols = [s for s in args.symbols.split(",") if s]
    tallies = {"ok": 0, "http_error": 0, "vendor_error": 0,
               "transport_error": 0, "second_429": 0}
    statuses = {}
    started = time.monotonic()
    last_429 = False
    issued = 0
    while issued < args.count:
        sym = symbols[issued % len(symbols)]
        if args.mix == "ka10027" and issued % 2 == 1:
            fn, api = probe.candidate, "ka10027"
        else:
            fn, api = probe.daily, args.api
        try:
            status, raw = fn(sym, args.base_dt)
        except RuntimeError as exc:
            tallies["transport_error"] += 1
            print(json.dumps({"event": "attempt", "api": api,
                              "n": issued + 1, "status": None,
                              "error": str(exc)}))
        else:
            code = probe._return_code(raw)
            statuses[str(status)] = statuses.get(str(status), 0) + 1
            if status == 200 and code == 0:
                tallies["ok"] += 1
                last_429 = False
            elif status == 429:
                tallies["http_error"] += 1
                tallies["second_429"] += 1 if last_429 else 0
                last_429 = True
            elif status != 200:
                tallies["http_error"] += 1
                last_429 = False
            else:
                tallies["vendor_error"] += 1
                last_429 = False
            print(json.dumps({"event": "attempt", "api": api,
                              "n": issued + 1, "status": status,
                              "return_code": code}))
        issued += 1
        if issued < args.count:
            time.sleep(args.interval)
    elapsed = round(time.monotonic() - started, 3)
    summary = {
        "event": "summary",
        "environment": args.environment,
        "api": args.api,
        "mix": args.mix,
        "interval_s": args.interval,
        "count": args.count,
        "elapsed_s": elapsed,
        "effective_rate_per_s": round(args.count / elapsed, 3)
        if elapsed > 0 else None,
        "statuses": statuses,
        "tallies": tallies,
        "attempts_note": ("this probe issues one physical request per loop "
                          "step; it does not model the sidecar's 429 retry"),
    }
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except sidecar.TokenError as exc:
        print(json.dumps({"event": "fatal", "what": "token",
                          "detail": str(exc)}), file=sys.stderr)
        sys.exit(3)