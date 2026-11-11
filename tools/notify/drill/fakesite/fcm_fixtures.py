"""Fixtures for the fake-FCM drill (tools/notify/drill/drill_fcm.sh).

Everything here is synthetic: the event facts follow the committed
schemas and the committed id rule, the FCM registration tokens and the
OAuth token are fake strings that exist only in drill-scoped temp
directories OUTSIDE the repository (config validation refuses credential
paths under the repo root — scenario D asserts that guard live). The
event_id values are computed with the contract's rule (the sha256 of
the HCJ-canonical {entity, event_type, rule_id, session_id,
transition_seq}); the transition seq enters only the digest and is
never emitted in any artifact.
"""

import hashlib
import json

SESSION = "2026-11-01"
OBSERVED_AT = "2026-11-01T09:12:33+09:00"
EVIDENCE_REF = "ka10027:stex_tp=1:sort_tp=1"


def event_id(session_id, event_type, rule_id, entity, transition_seq):
    doc = {"entity": entity, "event_type": event_type,
           "rule_id": rule_id, "session_id": session_id,
           "transition_seq": transition_seq}
    canonical = json.dumps(doc, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def make_event(event_type="TOP10_ENTERED", rule_id="top10-entered",
               seq=17, severity="INFO", symbol="005930", name="삼성전자",
               previous_rank=None, rank=3, direction="UP"):
    doc = {
        "event_id": event_id(SESSION, event_type, rule_id,
                             symbol if symbol else "*", seq),
        "event_type": event_type,
        "observed_at": OBSERVED_AT,
        "session_id": SESSION,
        "rule_id": rule_id,
        "rule_version": 1,
        "data_quality": "OBSERVING",
        "severity": severity,
        "evidence_ref": EVIDENCE_REF,
        "direction": direction,
    }
    if symbol:
        doc["symbol"] = symbol
    if name:
        doc["name"] = name
    if previous_rank is not None:
        doc["previous_rank"] = previous_rank
    if rank is not None:
        doc["rank"] = rank
    return doc


def events_source():
    """Scenario A fact stream: two market TOP10 transitions (a new
    entry, a rank change), byte-stable. The dispatcher's allowlist
    sends exactly these types — the drill must produce them."""
    return [
        make_event(seq=17, rank=7),
        make_event(event_type="RANK_CHANGED", rule_id="rank-changed",
                   seq=18, previous_rank=5, rank=2),
    ]


def single_event():
    """Scenario B/C fact stream: one TOP10 exit (the candidate left
    the universe: previous_rank, no rank), one device."""
    return [make_event(event_type="TOP10_EXITED", rule_id="top10-exited",
                       seq=7, previous_rank=6, rank=None,
                       direction="DOWN")]


def write_source(path, events):
    with open(path, "w", encoding="utf-8") as f:
        for event in events:
            f.write(json.dumps(event, ensure_ascii=False,
                               separators=(",", ":")) + "\n")
    return path


def registry_projection(registry_path):
    """A masked view of the registry for the evidence directory: device
    ids and token hashes only — the raw token values never leave the
    drill's temp directory (and never enter the repository)."""
    lines = []
    try:
        with open(registry_path, "r", encoding="utf-8") as f:
            for line in f:
                doc = json.loads(line)
                record = {"kind": doc.get("kind"),
                          "device_id": doc.get("device_id")}
                if "fcm_token_hash" in doc:
                    record["fcm_token_hash"] = doc["fcm_token_hash"]
                else:
                    record["fcm_token_hash"] = "sha256:" + hashlib.sha256(
                        (doc.get("fcm_token") or "").encode()
                    ).hexdigest()[:16]
                record["at"] = doc.get("at")
                lines.append(json.dumps(record, ensure_ascii=False,
                                        separators=(",", ":")))
    except FileNotFoundError:
        pass
    return lines


def delivery_summary(delivery_path):
    """The delivery records for assertion, in file order."""
    records = []
    try:
        with open(delivery_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    records.append(json.loads(line))
    except FileNotFoundError:
        pass
    return records
