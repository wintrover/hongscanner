#!/usr/bin/env python3
"""Mechanical SSOT consistency checks (VS-D).

Verifies that mirrored constants and build staging lists match their
committed single sources of truth:
  1. contracts/events/event.schema.json <-> tools/notify/notify_ledger.py
  2. contracts/events/delivery.schema.json <-> tools/notify/notify_ledger.py
  3. contracts/events/event.schema.json <-> src/hs/event_gen.nim
     (every event_type string the judgment layer can emit)
  4. contracts/events/event.schema.json <-> tools/api/serve.py
     (the market-view event-type constants and literals)
  5. Dockerfile COPY sources <-> .github/workflows/attest.yml staging step
  6. contracts/events/event.schema.json <-> tools/notify/notify_fcm.py
     (TOP10_EVENT_TYPES, the SUMMARY_WORDS keys),
     notify_dispatcher.py (AGGREGATION_STARTED) and
     notify_config.py (the ADMISSION_DEFAULT keys)
  7. contracts/events/event.schema.json and delivery.schema.json <->
     the wire/policy copies: notify_fcm.py's payload kind values and
     the mobile copies — market_alert_channel.dart (marketEventTypes,
     marketKinds), push_service.dart (the dedupKey kind literals),
     main.dart (the digest channel routing literal), MainActivity.kt
     (the kind routing literals) and digest_list_screen.dart (the
     case-label event types)
"""

import ast
import json
import os
import re
import sys
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "notify"))

import notify_ledger  # noqa: E402


def load_event_type_enum():
    schema_path = os.path.join(
        REPO, "contracts", "events", "event.schema.json")
    with open(schema_path, "r", encoding="utf-8") as f:
        schema = json.load(f)
    return schema["properties"]["event_type"]["enum"]


def load_message_kind_enum():
    schema_path = os.path.join(
        REPO, "contracts", "events", "delivery.schema.json")
    with open(schema_path, "r", encoding="utf-8") as f:
        schema = json.load(f)
    return schema["properties"]["message_kind"]["enum"]


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

    def test_event_schema_covers_event_gen_event_types(self):
        gen_path = os.path.join(REPO, "src", "hs", "event_gen.nim")
        with open(gen_path, "r", encoding="utf-8") as f:
            text = f.read()
        # Every event_type string event_gen.nim can emit, in the shapes
        # the judgment layer writes it: the quoted token in the eventType
        # slot (third argument) of judged(...) calls, the literals fed to
        # the `typ` variable those calls pass instead, and the eventType
        # field of the direct EventFact construction in finish().
        patterns = (
            ("judged() eventType argument",
             r'judged\(\s*\w+,\s*[\w.]+,\s*"([A-Z0-9_]+)"'),
            ("typ assignment", r'\btyp\s*=\s*"([A-Z0-9_]+)"'),
            ("typ seen-tuple guard", r'\btyp:\s*"([A-Z0-9_]+)"'),
            ("typ if/elif expression",
             r'\btyp\s*=\s*if\b[^"\n]*"([A-Z0-9_]+)"'),
            ("elif branch literal", r'\belif\b[^"\n]*"([A-Z0-9_]+)"'),
            ("EventFact eventType field",
             r'\beventType\*?\s*:\s*"([A-Z0-9_]+)"'),
        )
        emitted = set()
        for label, pattern in patterns:
            found = re.findall(pattern, text)
            self.assertTrue(
                found,
                "no %s matches in event_gen.nim: the extraction went "
                "blind" % label)
            emitted.update(found)
        enum = set(load_event_type_enum())
        unknown = emitted - enum
        self.assertEqual(
            unknown, set(),
            "event_gen.nim emits event types missing from "
            "event.schema.json: %s" % sorted(unknown))

    def test_event_schema_matches_serve_market_types(self):
        serve_path = os.path.join(REPO, "tools", "api", "serve.py")
        with open(serve_path, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read(), filename=serve_path)
        enum = set(load_event_type_enum())

        tuples = {}
        change_literals = set()
        compared_literals = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if (isinstance(target, ast.Name)
                            and target.id in ("MARKET_CHANGE_TYPES",
                                              "MARKET_FACT_TYPES")
                            and isinstance(node.value, ast.Tuple)):
                        tuples[target.id] = [
                            elt.value for elt in node.value.elts
                            if isinstance(elt, ast.Constant)
                            and isinstance(elt.value, str)]
            elif isinstance(node, ast.Call):
                if (isinstance(node.func, ast.Attribute)
                        and node.func.attr == "_market_change"
                        and node.args
                        and isinstance(node.args[0], ast.Constant)
                        and isinstance(node.args[0].value, str)):
                    change_literals.add(node.args[0].value)
            elif isinstance(node, ast.Compare) and len(node.ops) == 1 \
                    and isinstance(node.ops[0], ast.Eq):
                sides = [node.left] + list(node.comparators)
                if any(isinstance(side, ast.Name)
                       and side.id == "event_type" for side in sides):
                    for side in sides:
                        if (isinstance(side, ast.Constant)
                                and isinstance(side.value, str)):
                            compared_literals.add(side.value)

        self.assertEqual(
            set(tuples), {"MARKET_CHANGE_TYPES", "MARKET_FACT_TYPES"},
            "serve.py market event-type constants not found")
        for name in sorted(tuples):
            unknown = set(tuples[name]) - enum
            self.assertEqual(
                unknown, set(),
                "serve.py %s drifted from event.schema.json: %s"
                % (name, sorted(unknown)))
        self.assertTrue(
            change_literals,
            "no _market_change literals found in serve.py")
        self.assertTrue(
            compared_literals,
            "no event_type comparisons found in serve.py")
        unknown = (change_literals | compared_literals) - enum
        self.assertEqual(
            unknown, set(),
            "serve.py uses event-type literals outside "
            "event.schema.json: %s" % sorted(unknown))
        stray = change_literals - set(tuples["MARKET_CHANGE_TYPES"])
        self.assertEqual(
            stray, set(),
            "serve.py mints change records outside "
            "MARKET_CHANGE_TYPES: %s" % sorted(stray))

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

    def _module_assignments(self, path, name):
        """The value node of the one assignment to `name` in the module
        at `path` (ast, not import: the module may have import side
        effects). Fails loudly on zero matches (the extraction went
        blind) or on several (ambiguous copy)."""
        with open(path, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read(), filename=path)
        values = [
            node.value for node in ast.walk(tree)
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name)
                    and target.id == name
                    for target in node.targets)]
        self.assertEqual(
            len(values), 1,
            "%s must assign %s exactly once (found %d): the "
            "extraction went blind or is ambiguous"
            % (os.path.basename(path), name, len(values)))
        return values[0]

    def _module_dict_string_keys(self, path, name):
        """The string keys of the one `name = { ... }` dict literal
        assignment in the module at `path`."""
        node = self._module_assignments(path, name)
        self.assertIsInstance(
            node, ast.Dict,
            "%s is not a dict literal: the extraction went blind" % name)
        keys = [
            key.value for key in node.keys
            if isinstance(key, ast.Constant)
            and isinstance(key.value, str)]
        self.assertTrue(
            keys,
            "no string keys in %s: the extraction went blind" % name)
        return keys

    def _dart_set_literals(self, name):
        """The string literals of the one `name = { ... }` set literal
        in market_alert_channel.dart. [^}] crosses the literal's
        newlines without DOTALL and cannot overshoot the closing
        brace."""
        dart_path = os.path.join(
            REPO, "mobile", "lib", "services", "market_alert_channel.dart")
        with open(dart_path, "r", encoding="utf-8") as f:
            text = f.read()
        matches = re.findall(r"\b%s\s*=\s*\{([^}]*)\}" % name, text)
        self.assertEqual(
            len(matches), 1,
            "market_alert_channel.dart must define %s as exactly one "
            "set literal (found %d): the extraction went blind or is "
            "ambiguous" % (name, len(matches)))
        literals = set(re.findall(r"[\"']([^\"']+)[\"']", matches[0]))
        self.assertTrue(
            literals,
            "no string literals in %s: the extraction went blind" % name)
        return literals

    def test_event_schema_covers_notify_fcm_top10_types(self):
        # The delivery policy's TOP10 allowlist (also the truth behind
        # notify_dispatcher.NOTIFIABLE_EVENT_TYPES and
        # notify_config.ADMISSION_UNIVERSE, which reference it): a
        # subset of the contract vocabulary, not a mirror of it.
        fcm_path = os.path.join(REPO, "tools", "notify", "notify_fcm.py")
        node = self._module_assignments(fcm_path, "TOP10_EVENT_TYPES")
        if isinstance(node, ast.Call) and len(node.args) == 1:
            node = node.args[0]
        self.assertIsInstance(
            node, (ast.Tuple, ast.Set),
            "TOP10_EVENT_TYPES is not a set/tuple literal: the "
            "extraction went blind")
        members = [
            elt.value for elt in node.elts
            if isinstance(elt, ast.Constant)
            and isinstance(elt.value, str)]
        self.assertTrue(
            members,
            "no string members in TOP10_EVENT_TYPES: the extraction "
            "went blind")

        enum = set(load_event_type_enum())
        unknown = set(members) - enum
        self.assertEqual(
            unknown, set(),
            "notify_fcm.TOP10_EVENT_TYPES drifted from "
            "event.schema.json: %s" % sorted(unknown))

    def test_dispatcher_never_sends_aggregation_started(self):
        # P27 (user decision 2026-11-18): AGGREGATION_STARTED is a
        # session-lifecycle fact — recorded in the ledger, never pushed
        # to consumers. The type must stay in the schema (the fact is
        # still recorded) and must not be assigned in the dispatcher
        # (a reassignment would mean the consumer filter regressed).
        enum = set(load_event_type_enum())
        self.assertIn(
            "AGGREGATION_STARTED", enum,
            "event.schema.json must keep AGGREGATION_STARTED: the fact "
            "is recorded even though it is never pushed")
        dispatcher_path = os.path.join(
            REPO, "tools", "notify", "notify_dispatcher.py")
        with open(dispatcher_path, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read(), filename=dispatcher_path)
        assigned = [
            target.id for node in ast.walk(tree)
            if isinstance(node, ast.Assign)
            for target in node.targets
            if isinstance(target, ast.Name)
            and target.id == "AGGREGATION_STARTED"]
        self.assertEqual(
            assigned, [],
            "notify_dispatcher.py assigns AGGREGATION_STARTED: the "
            "dispatcher must never deliver it to consumers (P27)")

    def test_event_schema_covers_dart_market_event_types(self):
        enum = set(load_event_type_enum())
        unknown = self._dart_set_literals("marketEventTypes") - enum
        self.assertEqual(
            unknown, set(),
            "market_alert_channel.dart marketEventTypes drifted from "
            "event.schema.json: %s" % sorted(unknown))

    def test_delivery_schema_covers_dart_market_kinds(self):
        enum = set(load_message_kind_enum())
        unknown = self._dart_set_literals("marketKinds") - enum
        self.assertEqual(
            unknown, set(),
            "market_alert_channel.dart marketKinds drifted from "
            "delivery.schema.json message_kind: %s" % sorted(unknown))

    def test_delivery_schema_covers_push_service_kind_literals(self):
        # push_service.dart's dedupKey kind test: the message-kind
        # literals the file compares with == / != (its only
        # equality-compared string literals).
        path = os.path.join(
            REPO, "mobile", "lib", "services", "push_service.dart")
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        found = re.findall(r"[!=]=\s*'([^']+)'", text)
        self.assertTrue(
            found,
            "no '...' equality comparisons in push_service.dart: the "
            "extraction went blind")

        enum = set(load_message_kind_enum())
        unknown = set(found) - enum
        self.assertEqual(
            unknown, set(),
            "push_service.dart kind literals drifted from "
            "delivery.schema.json message_kind: %s" % sorted(unknown))

    def test_delivery_schema_covers_kotlin_kind_literals(self):
        # MainActivity.kt's kind routing: every string literal compared
        # against the `kind` argument (the batch judgment and the
        # digest single-slot test).
        path = os.path.join(
            REPO, "mobile", "android", "app", "src", "main", "kotlin",
            "com", "hongscanner", "hongscanner", "MainActivity.kt")
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        found = re.findall(r"\bkind\s*[!=]=\s*\"([^\"]+)\"", text)
        self.assertTrue(
            found,
            "no kind == \"...\" comparisons in MainActivity.kt: the "
            "extraction went blind")

        enum = set(load_message_kind_enum())
        unknown = set(found) - enum
        self.assertEqual(
            unknown, set(),
            "MainActivity.kt kind literals drifted from "
            "delivery.schema.json message_kind: %s" % sorted(unknown))

    def test_event_schema_covers_digest_list_case_types(self):
        # digest_list_screen.dart's rank-change label switch: the
        # event-type-shaped case labels.
        path = os.path.join(
            REPO, "mobile", "lib", "screens", "digest_list_screen.dart")
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        found = re.findall(r"case\s+'([A-Z0-9_]+)':", text)
        self.assertTrue(
            found,
            "no event-type-shaped case labels in "
            "digest_list_screen.dart: the extraction went blind")

        enum = set(load_event_type_enum())
        unknown = set(found) - enum
        self.assertEqual(
            unknown, set(),
            "digest_list_screen.dart case labels drifted from "
            "event.schema.json: %s" % sorted(unknown))

    def test_main_kind_literals_and_foreground_silence(self):
        # main.dart used to route the digest channel by message.kind and
        # post a local notification; since 2026-11-18 the foreground
        # posts nothing to the OS, so the channel comparison may be
        # gone. Two mechanical checks: any remaining kind comparison
        # must name a delivery.schema.json message_kind, and the shell
        # must never call the local-notification poster again.
        path = os.path.join(REPO, "mobile", "lib", "main.dart")
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        self.assertNotIn(
            "postNotification(",
            text,
            "main.dart calls postNotification: the foreground must "
            "never post a system notification or sound (2026-11-18)")
        found = re.findall(r"\bmessage\.kind\s*[!=]=\s*'([^']+)'", text)
        if not found:
            return
        enum = set(load_message_kind_enum())
        unknown = set(found) - enum
        self.assertEqual(
            unknown, set(),
            "main.dart kind literals drifted from "
            "delivery.schema.json message_kind: %s" % sorted(unknown))

    def test_event_schema_covers_notify_fcm_summary_words(self):
        # notify_fcm.py's summary body word table: the event_type keys
        # (a type outside the table falls back to its own event_type
        # string — never an invented word).
        fcm_path = os.path.join(REPO, "tools", "notify", "notify_fcm.py")
        keys = self._module_dict_string_keys(fcm_path, "SUMMARY_WORDS")

        enum = set(load_event_type_enum())
        unknown = set(keys) - enum
        self.assertEqual(
            unknown, set(),
            "notify_fcm.SUMMARY_WORDS keys drifted from "
            "event.schema.json: %s" % sorted(unknown))

    def test_event_schema_covers_notify_config_admission_default(self):
        # notify_config.py's default admission verdicts: the event_type
        # keys (the values are the config's own admission modes —
        # immediate/digest/suppress — not a schema copy).
        config_path = os.path.join(
            REPO, "tools", "notify", "notify_config.py")
        keys = self._module_dict_string_keys(
            config_path, "ADMISSION_DEFAULT")

        enum = set(load_event_type_enum())
        unknown = set(keys) - enum
        self.assertEqual(
            unknown, set(),
            "notify_config.ADMISSION_DEFAULT keys drifted from "
            "event.schema.json: %s" % sorted(unknown))

    def test_delivery_schema_covers_notify_fcm_payload_kinds(self):
        # The FCM payload data.kind values: the wire message kinds the
        # builders put on every push.
        fcm_path = os.path.join(REPO, "tools", "notify", "notify_fcm.py")
        with open(fcm_path, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read(), filename=fcm_path)
        kinds = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Dict):
                for key, value in zip(node.keys, node.values):
                    if (isinstance(key, ast.Constant)
                            and key.value == "kind"
                            and isinstance(value, ast.Constant)
                            and isinstance(value.value, str)):
                        kinds.add(value.value)
        self.assertTrue(
            kinds,
            "no \"kind\": literal payload values in notify_fcm.py: the "
            "extraction went blind")

        enum = set(load_message_kind_enum())
        unknown = kinds - enum
        self.assertEqual(
            unknown, set(),
            "notify_fcm.py payload kind values drifted from "
            "delivery.schema.json message_kind: %s" % sorted(unknown))

    def test_market_time_is_the_single_window_authority(self):
        """The opening window has one owner (P30): the API's mode
        decision and the dispatcher's peak budget must both consume
        tools/market_time.py, and neither may keep its own 09:00/09:30
        boundary literal — the duplicated-fact shape that let the two
        copies drift apart."""
        consumers = (
            ("tools/api/serve.py",
             os.path.join(REPO, "tools", "api", "serve.py")),
            ("tools/notify/notify_dispatcher.py",
             os.path.join(REPO, "tools", "notify", "notify_dispatcher.py")),
        )
        for label, path in consumers:
            with open(path, encoding="utf-8") as f:
                tree = ast.parse(f.read(), filename=path)
            imported = False
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    imported = imported or any(
                        alias.name == "market_time" for alias in node.names)
                elif isinstance(node, ast.ImportFrom):
                    imported = imported or node.module == "market_time"
            self.assertTrue(
                imported,
                "%s must import market_time (P30 single time authority)"
                % label)
            literals = {
                node.value for node in ast.walk(tree)
                if isinstance(node, ast.Constant)
                and isinstance(node.value, str)}
            self.assertEqual(
                literals & {"09:00:00", "09:30:00"}, set(),
                "%s keeps a duplicated opening-window boundary literal; "
                "the window lives in market_time only" % label)


if __name__ == "__main__":
    unittest.main(verbosity=2)
