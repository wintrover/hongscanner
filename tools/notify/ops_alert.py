#!/usr/bin/env python3
"""ops_alert: the ops side-channel — a one-shot alert send.

Design intent: this tool sends an ops alert WITHOUT leaving any notify
event or delivery ledger record. The attempt and its outcome are
recorded by the CALLER (runs-retention/retention-log.jsonl, the session
launcher log); this tool's whole report is one stdout result line per
device plus its exit code. The session launcher
(tools/run_session.sh) no longer invokes this tool: its ops-alert path
is record-only (OPS_ALERT_SUPPRESSED reason=consumer_push_removed).
When an alert ever needs persistent
notification (retry, delivery records), the path is an event-contract
extension following the AGGREGATION_STARTED precedent — never growing
this tool into that role.

Contract: tools/notify/README.md §8 (the credential path, TokenSource)
and §9 (exit codes). The notify library is reused directly (config
load, device registry, OAuth token, one FCM HTTP v1 send per device)
because the dispatcher's admission gate would silently suppress an
unknown event type: ops alerts are not event facts, so no admission
and no delivery record ever exists for them.

Usage:
  python3.13 tools/notify/ops_alert.py [--config <path>] <title> <body>

  --config   default: $HSNOTIFY_CONFIG, then
             ~/.local/share/hongscanner/notify/notify_config.json

Exit codes: 0 every send accepted, 2 usage/config (incl. payload over
the 4096-byte vendor limit), 3 no active devices, credential failure
or any non-accepted send.
"""

import argparse
import json
import os
import sys

import notify_clock
import notify_config
import notify_fcm
import notify_ledger

DEFAULT_CONFIG = os.path.expanduser(
    "~/.local/share/hongscanner/notify/notify_config.json")


def _message(title, body, token):
    return {"message": {
        "token": token,
        "notification": {"title": title, "body": body},
        "android": {"priority": "high",
                    "notification": {"channel_id": "market_rank_changes"}},
        "data": {"kind": "ops_alert", "title": title, "body": body}}}


def _main(argv):
    parser = argparse.ArgumentParser(
        description="send a one-shot ops alert (ops side-channel: no "
                    "event or delivery ledger record; docs/RETENTION.md)")
    parser.add_argument("--config",
                        default=os.environ.get("HSNOTIFY_CONFIG", "")
                        or DEFAULT_CONFIG,
                        help="notify config path; default $HSNOTIFY_CONFIG"
                             " then %s" % DEFAULT_CONFIG)
    parser.add_argument("title", help="notification title")
    parser.add_argument("body", help="notification body")
    args = parser.parse_args(argv)

    try:
        cfg = notify_config.load_config(args.config, "dispatch")
    except notify_config.ConfigError as exc:
        print("ops_alert: config refused: %s" % exc, file=sys.stderr)
        return 2

    registry = notify_ledger.Registry(cfg["registry_path"], lock=False)
    try:
        devices = registry.devices()
    finally:
        registry.close()
    if not devices:
        print("ops_alert: no active devices in the registry",
              file=sys.stderr)
        return 3

    try:
        tokens = notify_fcm.TokenSource(cfg)
        code = 0
        for device_id in sorted(devices):
            payload = _message(args.title, args.body, devices[device_id])
            size = len(json.dumps(payload, ensure_ascii=False,
                                  separators=(",", ":")).encode("utf-8"))
            if size > notify_fcm.PAYLOAD_LIMIT_BYTES:
                # A payload violation is a usage/config refusal (2), not
                # a send failure (3): nothing was sent for this alert.
                print("ops_alert: payload %d bytes is over the vendor "
                      "limit" % size, file=sys.stderr)
                return 2
            outcome = notify_fcm.send_message(cfg["project_id"],
                                              tokens.get(), payload)
            print("ops_alert device=%s result=%s status=%s error=%s %s" % (
                device_id, outcome.kind, outcome.http_status,
                outcome.error_code, notify_clock.stamp()), flush=True)
            if outcome.kind != "accepted":
                code = 3
        return code
    except notify_fcm.FcmError as exc:
        print("ops_alert: credential failure: %s" % exc, file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
