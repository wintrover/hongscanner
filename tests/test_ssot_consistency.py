#!/usr/bin/env python3
"""Mechanical SSOT consistency checks (VS-D).

Verifies that mirrored constants and build staging lists match their
committed single sources of truth:
  1. contracts/events/event.schema.json <-> tools/notify/notify_ledger.py
  2. contracts/events/delivery.schema.json <-> tools/notify/notify_ledger.py
  3. Dockerfile COPY sources <-> .github/workflows/attest.yml staging step
"""

import json
import os
import re
import sys
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "notify"))

import notify_ledger  # noqa: E402


class SsotConsistencySuite(unittest.TestCase):
    def test_event_schema_matches_notify_ledger(self):
        schema_path = os.path.join(
            REPO, "contracts", "events", "event.schema.json")
        with open(schema_path, "r", encoding="utf-8") as f:
            schema = json.load(f)
        props = schema["properties"]
        self.assertEqual(
            set(props["event_type"]["enum"]),
            set(notify_ledger.EVENT_TYPES),
            "notify_ledger.EVENT_TYPES drifted from event.schema.json",
        )
        self.assertEqual(
            len(props["event_type"]["enum"]),
            len(notify_ledger.EVENT_TYPES),
        )
        self.assertEqual(
            set(props["severity"]["enum"]),
            set(notify_ledger.SEVERITIES),
        )
        self.assertEqual(
            set(props["data_quality"]["enum"]),
            set(notify_ledger.DATA_QUALITIES),
        )
        self.assertEqual(
            set(props["direction"]["enum"]),
            set(notify_ledger.DIRECTIONS),
        )

    def test_delivery_schema_matches_notify_ledger(self):
        schema_path = os.path.join(
            REPO, "contracts", "events", "delivery.schema.json")
        with open(schema_path, "r", encoding="utf-8") as f:
            schema = json.load(f)
        props = schema["properties"]
        self.assertEqual(
            set(props["state"]["enum"]),
            set(notify_ledger.DELIVERY_STATES),
        )
        self.assertEqual(
            set(props["message_kind"]["enum"]),
            set(notify_ledger.MESSAGE_KINDS),
        )

    def test_dockerfile_copy_matches_attest_staging(self):
        dockerfile_path = os.path.join(REPO, "Dockerfile")
        attest_path = os.path.join(REPO, ".github", "workflows", "attest.yml")
        with open(dockerfile_path, "r", encoding="utf-8") as f:
            docker_lines = f.readlines()
        with open(attest_path, "r", encoding="utf-8") as f:
            attest_text = f.read()

        copy_sources = set()
        for line in docker_lines:
            m = re.match(r"^\s*COPY\s+(\S+)\s+\S+\s*$", line)
            if m:
                src = m.group(1)
                if not src.startswith("bin/"):
                    copy_sources.add(src)

        self.assertTrue(copy_sources, "no COPY sources found in Dockerfile")
        for src in sorted(copy_sources):
            basename = os.path.basename(src)
            self.assertTrue(
                src in attest_text or basename in attest_text,
                f"Dockerfile COPY source {src!r} missing from attest.yml",
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
