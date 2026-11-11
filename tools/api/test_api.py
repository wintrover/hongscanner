#!/usr/bin/env python3
"""Read-only API contract suite (tools/api/README.md §6): unittest over
a real serve.py process on an EPHEMERAL port (0), loopback by default
plus one --bind case on 127.0.0.2, against synthetic fixture run
directories and ledgers built in a mktemp sandbox. Loopback network
only, no market data, no credentials, no live calls.

The suite starts and reaps every server process it spawns and asserts
each one exits cleanly (SIGTERM -> exit 0, no residue). A malformed
response byte, a leaked path/secret, or a surviving process fails the
suite. Fail-closed: no assertion reports a pass on absence of evidence.

The §3.7 market view is covered by four suites: MarketViewSuite holds
the core fold and the legacy change-history contract, MarketViewFactSuite
the events_contract "top10-v1" dual path (the fact translation, its
eligibility rule, the discriminator branches), MarketViewOpeningSuite
the VS-2 opening MA20 mode (the recorded window predicate, the
chain-pair correspondence offsets, the integer cross-product order, the
honest exclusions and the DataFault shapes), and MarketFoldSuite the
pure fold_market_projection unit and its memoization."""

import hashlib
import json
import os
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import unittest

from urllib import request as urlrequest
from urllib.error import HTTPError

SERVE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "serve.py")
PY = sys.executable

# The module under unit test for the §3.7 name-dictionary fold (pure
# function + memoization behavior — endpoint bytes stay black-box).
sys.path.insert(0, os.path.dirname(SERVE))
import serve  # noqa: E402

SECRET = "SUPERSECRET-VALUE-NEVER-SERVE"
HIDDEN_HOST = "hidden-host-internal"
HIDDEN_EGRESS = "203.0.113.7"
HIDDEN_PID = 987654321


def canonical(obj):
    """The response wire encoding the contract pins: UTF-8, compact,
    keys in codepoint order, no floats."""
    return json.dumps(obj, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def event_id(tag):
    return sha(b"event-fixture-" + tag)


def event_fact(tag, event_type, session_id, observed_at, rule_id,
               severity="INFO", **extra):
    fact = {
        "data_quality": "OBSERVING",
        "event_id": event_id(tag),
        "event_type": event_type,
        "evidence_ref": sha(b"evidence-" + tag),
        "observed_at": observed_at,
        "rule_id": rule_id,
        "rule_version": 1,
        "session_id": session_id,
        "severity": severity,
    }
    fact.update(extra)
    return fact


EV1 = event_fact(b"1", "CANDIDATE_ENTERED", "2026-10-29",
                 "2026-10-29T09:12:33+09:00", "candidate-entered",
                 direction="UP", rank=1, symbol="005930")
EV2 = event_fact(b"2", "SESSION_ENDED", "2026-10-29",
                 "2026-10-29T15:30:00+09:00", "session-close-v1")
EV3 = event_fact(b"3", "CANDIDATE_ENTERED", "2026-10-30",
                 "2026-10-30T10:00:00+09:00", "candidate-entered",
                 severity="HIGH", direction="DOWN", rank=2, symbol="000660")
EV4 = event_fact(b"4", "CANDIDATE_EXITED", "2026-10-30",
                 "2026-10-30T11:00:00+09:00", "candidate-exited",
                 symbol="000660")

D1 = {"attempts": 0, "device_id": "dev-1", "event_id": EV1["event_id"],
      "state": "PENDING", "updated_at": "2026-11-01T09:00:00+09:00"}
D2 = {"attempts": 1, "device_id": "dev-1", "event_id": EV1["event_id"],
      "provider_message_id": "projects/drill-project/messages/m-1",
      "state": "ACCEPTED", "updated_at": "2026-11-01T09:01:00+09:00"}
D3 = {"attempts": 2, "device_id": "dev-1", "error_code": "UNREGISTERED",
      "event_id": EV3["event_id"], "state": "FAILED",
      "updated_at": "2026-11-01T09:02:00+09:00"}
D4 = {"attempts": 0, "device_id": "dev-2", "event_id": EV4["event_id"],
      "state": "PENDING", "updated_at": "2026-11-01T09:02:00+09:00"}

COMMIT_A = sha(b"code-commit-a")
COMMIT_B = sha(b"code-commit-b")
COMMIT_C = sha(b"code-commit-c")

RUN_JSON_A = {"bar_count": 2, "code_commit": COMMIT_A,
              "egress_ip": HIDDEN_EGRESS, "host": HIDDEN_HOST,
              "pid": HIDDEN_PID, "run_id": "run-a",
              "session_date": "2026-10-29", "signal_count": 1,
              "started_at": "2026-11-01T08:00:00+09:00"}
RUN_JSON_B = {"code_commit": COMMIT_B, "run_id": "run-b",
              "session_date": "2026-10-30",
              "started_at": "2026-11-01T09:00:00+09:00"}
RUN_JSON_C = {"code_commit": COMMIT_C, "run_id": "run-c",
              "session_date": "2026-10-31",
              "started_at": "2026-11-02T08:00:00+09:00"}

INPUT_A = [
    {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
    {"kind": "config", "raw": {"session_date": "2026-10-29"}, "seq": 2},
    {"kind": "ws_frame", "raw": {"price": 10000, "symbol": "005930"},
     "seq": 3},
    {"kind": "ws_frame", "raw": {"price": 10100, "symbol": "005930"},
     "seq": 4},
    {"kind": "session_end", "raw": None, "seq": 5},
]
INPUT_B = [
    {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
    {"kind": "config", "raw": {"session_date": "2026-10-30"}, "seq": 2},
]
BARS_LINE = {"bar_index": 0, "price": 10100, "symbol": "005930"}
SIGNALS_LINE = {"bar_index": 0, "reason": "first_after_sub",
                "signal": "SIGNAL_HELD", "symbol": "005930"}

# -- /mobile/market-view (README §3.7) fixtures --------------------------

MV_WINNER = "market-2026-11-09-b"

# The winning run's change-history scenario (README §3.7): four
# observation groups over a ~15-symbol universe, both directions.
# Group 1 is the baseline (every candidate ENTERED — zero changes).
# Group 2 exercises every classification: RANK_CHANGED, TOP10_ENTERED
# from rank 11, TOP10_EXITED to rank 11, a TOP10-outside move (15 -> 14)
# and a TOP10-outside EXIT with no record, and a DOWN TOP10 member's
# CANDIDATE_EXITED. Groups 3A/3B are two consecutive batches stamped
# identically — one merged group whose net effect is zero. Group 4 is a
# direction switch (one UP TOP10 member leaves and re-enters DOWN) plus
# the DOWN re-ranking. The winner is UNSEALED by default: group 4's
# changes stay out of history until the committed marker exists.
MV_T1 = "2026-11-09T10:00:01+09:00"
MV_T2 = "2026-11-09T10:05:01+09:00"
MV_T3 = "2026-11-09T10:10:01+09:00"   # the same-stamp merge pair
MV_T4 = "2026-11-09T10:15:01+09:00"
MV_T5 = "2026-11-09T10:20:01+09:00"   # the torn-tail fixture's stamp
MV_TEND = "2026-11-09T15:30:00+09:00"  # the run's last committed event


def mv_fact(tag, stamp, event_type, symbol, direction, rank=None):
    """A §3.7 candidate event of the fixture universe: the recorded
    twelve-field shape (candidate data_quality is always OBSERVING;
    rank is absent on CANDIDATE_EXITED)."""
    extra = {"direction": direction, "symbol": symbol}
    if rank is not None:
        extra["rank"] = rank
    return event_fact(b"mv-" + tag, event_type, "2026-11-09", stamp,
                      "candidate-transition-v1", **extra)


# Group 1 (MV_T1) — the baseline: thirteen UP and three DOWN candidates
# enter (batch order: the UP upserts, then the DOWN upserts).
MV_G1_UP06 = mv_fact(b"g1-up06", MV_T1, "CANDIDATE_ENTERED", "009150",
                     "UP", 6)
MV_G1 = [
    mv_fact(b"g1-up01", MV_T1, "CANDIDATE_ENTERED", "005930", "UP", 1),
    mv_fact(b"g1-up02", MV_T1, "CANDIDATE_ENTERED", "006660", "UP", 2),
    mv_fact(b"g1-up03", MV_T1, "CANDIDATE_ENTERED", "007070", "UP", 3),
    mv_fact(b"g1-up04", MV_T1, "CANDIDATE_ENTERED", "008480", "UP", 4),
    mv_fact(b"g1-up05", MV_T1, "CANDIDATE_ENTERED", "008560", "UP", 5),
    MV_G1_UP06,
    mv_fact(b"g1-up07", MV_T1, "CANDIDATE_ENTERED", "009540", "UP", 7),
    mv_fact(b"g1-up08", MV_T1, "CANDIDATE_ENTERED", "010060", "UP", 8),
    mv_fact(b"g1-up09", MV_T1, "CANDIDATE_ENTERED", "011060", "UP", 9),
    mv_fact(b"g1-up10", MV_T1, "CANDIDATE_ENTERED", "011140", "UP", 10),
    mv_fact(b"g1-up11", MV_T1, "CANDIDATE_ENTERED", "011780", "UP", 11),
    mv_fact(b"g1-up12", MV_T1, "CANDIDATE_ENTERED", "012330", "UP", 12),
    mv_fact(b"g1-up15", MV_T1, "CANDIDATE_ENTERED", "015760", "UP", 15),
    mv_fact(b"g1-dn01", MV_T1, "CANDIDATE_ENTERED", "000660", "DOWN", 1),
    mv_fact(b"g1-dn02", MV_T1, "CANDIDATE_ENTERED", "000810", "DOWN", 2),
    mv_fact(b"g1-dn03", MV_T1, "CANDIDATE_ENTERED", "001440", "DOWN", 11),
]

# Group 2 (MV_T2) — one recorded batch: the UP upserts (the vendor
# emits events only for candidates whose rank changed), the UP exit of
# the rank-12 outside member (no record), then the DOWN exit of a TOP10
# member (CANDIDATE_EXITED).
MV_G2_UP05 = mv_fact(b"g2-up05", MV_T2, "CANDIDATE_UPDATED", "008560",
                     "UP", 2)
MV_G2_UP02 = mv_fact(b"g2-up02", MV_T2, "CANDIDATE_UPDATED", "006660",
                     "UP", 3)
MV_G2_UP03 = mv_fact(b"g2-up03", MV_T2, "CANDIDATE_UPDATED", "007070",
                     "UP", 4)
MV_G2_UP04 = mv_fact(b"g2-up04", MV_T2, "CANDIDATE_UPDATED", "008480",
                     "UP", 5)
MV_G2_UP11 = mv_fact(b"g2-up11", MV_T2, "CANDIDATE_UPDATED", "011780",
                     "UP", 7)
MV_G2_UP07 = mv_fact(b"g2-up07", MV_T2, "CANDIDATE_UPDATED", "009540",
                     "UP", 8)
MV_G2_UP08 = mv_fact(b"g2-up08", MV_T2, "CANDIDATE_UPDATED", "010060",
                     "UP", 11)
MV_G2_UP12X = mv_fact(b"g2-up12x", MV_T2, "CANDIDATE_EXITED", "012330",
                      "UP")
MV_G2_DN02X = mv_fact(b"g2-dn02x", MV_T2, "CANDIDATE_EXITED", "000810",
                      "DOWN")
MV_G2 = [MV_G2_UP05, MV_G2_UP02, MV_G2_UP03, MV_G2_UP04, MV_G2_UP11,
         MV_G2_UP07, MV_G2_UP08,
         mv_fact(b"g2-up15", MV_T2, "CANDIDATE_UPDATED", "015760", "UP", 14),
         MV_G2_UP12X, MV_G2_DN02X]

# Groups 3A/3B (both MV_T3) — two consecutive batches stamped
# identically: one merged observation group whose net effect is zero
# (ranks 1 and 2 swap, then swap back). Splitting them would record
# changes that never happened.
MV_G3A = [
    mv_fact(b"g3a-up01", MV_T3, "CANDIDATE_UPDATED", "005930", "UP", 2),
    mv_fact(b"g3a-up05", MV_T3, "CANDIDATE_UPDATED", "008560", "UP", 1),
]
MV_G3B_UP01 = mv_fact(b"g3b-up01", MV_T3, "CANDIDATE_UPDATED", "005930",
                      "UP", 1)
MV_G3B_UP05 = mv_fact(b"g3b-up05", MV_T3, "CANDIDATE_UPDATED", "008560",
                      "UP", 2)
MV_G3B = [MV_G3B_UP01, MV_G3B_UP05]

# Group 4 (MV_T4) — a direction switch: the UP rank-9 member 011060
# leaves UP (the members below re-rank) and re-enters DOWN at rank 1,
# re-ranking DOWN. The two sides are two separate change records.
MV_G4_UP10 = mv_fact(b"g4-up10", MV_T4, "CANDIDATE_UPDATED", "011140",
                     "UP", 9)
MV_G4_UP08 = mv_fact(b"g4-up08", MV_T4, "CANDIDATE_UPDATED", "010060",
                     "UP", 10)
MV_G4_UP09X = mv_fact(b"g4-up09x", MV_T4, "CANDIDATE_EXITED", "011060",
                      "UP")
MV_G4_DN09 = mv_fact(b"g4-dn09", MV_T4, "CANDIDATE_ENTERED", "011060",
                     "DOWN", 1)
MV_G4_DN01 = mv_fact(b"g4-dn01", MV_T4, "CANDIDATE_UPDATED", "000660",
                     "DOWN", 2)
MV_G4_DN03 = mv_fact(b"g4-dn03", MV_T4, "CANDIDATE_UPDATED", "001440",
                     "DOWN", 3)
MV_G4 = [MV_G4_UP10, MV_G4_UP08,
         mv_fact(b"g4-up15", MV_T4, "CANDIDATE_UPDATED", "015760", "UP", 13),
         MV_G4_UP09X, MV_G4_DN09, MV_G4_DN01, MV_G4_DN03]

# The run's last committed event — a non-candidate INCOMPLETE record:
# it never closes a group, and it is the as_of/latest evidence.
MV_INCOMPLETE_SUB = event_fact(b"mv-sub", "SUBSCRIPTION_TRUNCATED",
                               "2026-11-09", MV_TEND,
                               "subscription-truncated-v1",
                               severity="HIGH", data_quality="INCOMPLETE",
                               direction="UP")

# The >100-change ring scenario: batches after group 4 that alternate
# the UP TOP10's rank-pair assignment, so every group boundary derives
# exactly ten RANK_CHANGED records (five pairs x two sides).
MV_SWAP_BASE = [("005930", 1), ("008560", 2), ("006660", 3),
                ("007070", 4), ("008480", 5), ("009150", 6),
                ("011780", 7), ("009540", 8), ("011140", 9),
                ("010060", 10)]


def mv_swap_groups(count):
    """`count` post-group-4 batches, each assigning the swapped or base
    ranking of the ten UP TOP10 members: every group boundary derives
    ten RANK_CHANGED records, so eleven groups exceed the 100-record
    ring on top of the sealed scenario's fourteen."""
    swapped = [(sym, rk + 1 if rk % 2 else rk - 1)
               for sym, rk in MV_SWAP_BASE]
    groups = []
    for g in range(count):
        stamp = "2026-11-09T10:%02d:01+09:00" % (25 + g)
        assignment = swapped if g % 2 == 0 else MV_SWAP_BASE
        groups.append([
            mv_fact(("gsw%02d-%s" % (g, sym)).encode(), stamp,
                    "CANDIDATE_UPDATED", sym, "UP", rk)
            for sym, rk in assignment])
    return groups


def mv_winner_events(swap_groups=0):
    """The winner's committed sequence: the four observation groups
    (including the same-stamp merge pair), optionally `swap_groups`
    ring-stressing batches, always closed by the non-candidate
    INCOMPLETE record."""
    events = MV_G1 + MV_G2 + MV_G3A + MV_G3B + MV_G4
    for group in mv_swap_groups(swap_groups):
        events += group
    events.append(MV_INCOMPLETE_SUB)
    return events


# A single DOWN entry event, used only by the ineligible-run fixtures
# and the empty suites — never folded by the selected run.
MV_DOWN_ENTERED_1 = mv_fact(b"mv-dn-e1", MV_T1, "CANDIDATE_ENTERED",
                            "000660", "DOWN", 1)

# -- §3.7 name dictionary fixtures: ka10027 rest_resp records in the
# winner's input.hcj.jsonl, with the recorder's envelope shape. The
# recorded bodies exercise every fold rule: an error body without the
# ranking list (no names — absence served), a first page whose 006660
# name is later superseded (file order, last record wins), a ka10080
# record (scanned, never a name source), and a symbol (000660) no
# recorded body ever names (name null — the app falls back to the
# symbol).

MV_KA10027_QUERY = {"crd_cnd": "0", "mrkt_tp": "000", "pric_cnd": "0",
                    "sort_tp": "1", "stk_cnd": "16", "stex_tp": "1",
                    "trde_prica_cnd": "0", "trde_qty_cnd": "0000",
                    "updown_incls": "1"}


def rest_resp_record(seq, body_obj, api_id="ka10027", page=1, status=200,
                     cont_yn="N", sort_tp=None, query=None):
    return {"kind": "rest_resp",
            "raw": {"api_id": api_id,
                    "body_hex": canonical(body_obj).hex(),
                    "cont_yn": cont_yn, "next_key": "", "page": page,
                    "query": dict(query if query is not None
                                  else MV_KA10027_QUERY
                                  if sort_tp is None
                                  else dict(MV_KA10027_QUERY,
                                            sort_tp=sort_tp)),
                    "status": status},
            "seq": seq}


def ka10027_body(rows):
    """A recorded ka10027 ranking body. Rows are (symbol, name, price)
    triples — cur_prc is the recorded signed KRW integer the price fold
    depends on."""
    return {"pred_pre_flu_rt_upper": [{"cur_prc": "+%d" % price,
                                       "stk_cd": cd, "stk_nm": nm}
                                      for cd, nm, price in rows],
            "return_code": 0, "return_msg": "정상처리 되었습니다."}


MV_ERROR_BODY = {"return_code": 5,
                 "return_msg": "허용된 요청 개수를 초과하였습니다"}
MV_KA10080_BODY = {"return_code": 0, "return_msg": "정상처리 되었습니다.",
                   "stk_min_pole_chart_qry": [{"cur_prc": "+1000",
                                               "trde_qty": "100"}]}

MV_WINNER_INPUT = [
    rest_resp_record(3, MV_ERROR_BODY, status=429),
    rest_resp_record(4, ka10027_body([("005930", "삼성전자", 75000),
                                      ("006660", "구형이름", 45000)])),
    rest_resp_record(5, MV_KA10080_BODY, api_id="ka10080"),
    rest_resp_record(6, ka10027_body([("006660", "LG전자", 45000),
                                      ("179530", "애드바이오텍", 80000)]),
                     page=2),
    {"kind": "ws_frame", "raw": {"price": 10000, "symbol": "005930"},
     "seq": 7},
]

# The folded dictionary the winner's input must project: latest record
# wins for 006660, the error and ka10080 bodies contribute nothing, and
# 000660 is never named.
MV_NAME_MAP = {"005930": "삼성전자", "006660": "LG전자"}


def mv_item(ev, names=None):
    """The §3.7 item whitelist of a fixture fact: nine fields — seven
    recorded plus `name` from the fixture's folded ka10027 dictionary
    (None when no recorded body names the symbol — the fail-closed
    fallback) and `ma20_tag` (null outside the opening mode), rank null
    when the fact records none (CANDIDATE_EXITED)."""
    item = {k: ev[k] for k in ("data_quality", "direction", "event_id",
                               "event_type", "observed_at", "symbol")}
    item["ma20_tag"] = None
    item["rank"] = ev.get("rank")
    item["name"] = (names or {}).get(ev["symbol"])
    return item


def mv_change(change_type, ev, rank, prev_rank, names=None):
    """The §3.7 change record of a fixture fact: nine fields — the
    display classification plus the evidence event's recorded values
    (rank null on CANDIDATE_EXITED — honest absence, never 0)."""
    return {"change_type": change_type,
            "data_quality": ev["data_quality"],
            "direction": ev["direction"],
            "event_id": ev["event_id"],
            "name": (names or {}).get(ev["symbol"]),
            "observed_at": ev["observed_at"],
            "prev_rank": prev_rank,
            "rank": rank,
            "symbol": ev["symbol"]}


# Group 2's confirmed changes, ordered by the evidence events' ledger
# positions: 008560's record is the earlier ledger line even though the
# snapshot dict visits 006660 first (group-1 insertion order).
MV_HISTORY_G2 = [
    mv_change("RANK_CHANGED", MV_G2_UP05, 2, 5, MV_NAME_MAP),
    mv_change("RANK_CHANGED", MV_G2_UP02, 3, 2, MV_NAME_MAP),
    mv_change("RANK_CHANGED", MV_G2_UP03, 4, 3, MV_NAME_MAP),
    mv_change("RANK_CHANGED", MV_G2_UP04, 5, 4, MV_NAME_MAP),
    mv_change("TOP10_ENTERED", MV_G2_UP11, 7, 11, MV_NAME_MAP),
    mv_change("RANK_CHANGED", MV_G2_UP07, 8, 7, MV_NAME_MAP),
    mv_change("TOP10_EXITED", MV_G2_UP08, 11, 8, MV_NAME_MAP),
    mv_change("CANDIDATE_EXITED", MV_G2_DN02X, None, 2, MV_NAME_MAP),
]
# Group 4's confirmed changes (only after the seal): the direction
# switch of 011060 is two records — UP CANDIDATE_EXITED and DOWN
# TOP10_ENTERED.
MV_HISTORY_G4 = [
    mv_change("RANK_CHANGED", MV_G4_UP10, 9, 10, MV_NAME_MAP),
    mv_change("TOP10_ENTERED", MV_G4_UP08, 10, 11, MV_NAME_MAP),
    mv_change("CANDIDATE_EXITED", MV_G4_UP09X, None, 9, MV_NAME_MAP),
    mv_change("TOP10_ENTERED", MV_G4_DN09, 1, None, MV_NAME_MAP),
    mv_change("RANK_CHANGED", MV_G4_DN01, 2, 1, MV_NAME_MAP),
    mv_change("TOP10_ENTERED", MV_G4_DN03, 3, 11, MV_NAME_MAP),
]

MV_EXPECTED = {
    "as_of": MV_TEND,
    "falling_top10": [mv_item(MV_G4_DN09, MV_NAME_MAP),
                      mv_item(MV_G4_DN01, MV_NAME_MAP),
                      mv_item(MV_G4_DN03, MV_NAME_MAP)],
    "history": MV_HISTORY_G2,  # the unsealed run: group 4 is excluded
    "latest": {"data_quality": "INCOMPLETE",
               "event_id": MV_INCOMPLETE_SUB["event_id"],
               "event_type": "SUBSCRIPTION_TRUNCATED",
               "observed_at": MV_TEND},
    "mode": "core",  # the winner's groups are all 10:00+ stamps
    "rising_top10": [mv_item(MV_G3B_UP01, MV_NAME_MAP),
                     mv_item(MV_G3B_UP05, MV_NAME_MAP),
                     mv_item(MV_G2_UP02, MV_NAME_MAP),
                     mv_item(MV_G2_UP03, MV_NAME_MAP),
                     mv_item(MV_G2_UP04, MV_NAME_MAP),
                     mv_item(MV_G1_UP06, MV_NAME_MAP),
                     mv_item(MV_G2_UP11, MV_NAME_MAP),
                     mv_item(MV_G2_UP07, MV_NAME_MAP),
                     mv_item(MV_G4_UP10, MV_NAME_MAP),
                     mv_item(MV_G4_UP08, MV_NAME_MAP)],
    "run": {"environment": "demo", "run_id": MV_WINNER,
            "session": MV_WINNER, "session_date": "2026-11-09"},
    "runs_present": True,
    "status": {"by_data_quality": {"INCOMPLETE": 1, "OBSERVING": 37}},
}
# The sealed variant: the final observation group is confirmed and its
# changes enter the history.
MV_EXPECTED_SEALED = dict(MV_EXPECTED,
                          history=MV_HISTORY_G2 + MV_HISTORY_G4)


# -- §3.7 VS-2 opening MA20 mode fixtures (README §3.7) ------------------
#
# A separate 2026-11-10 run: three observation groups — the 08:50
# baseline, the reference group whose RECORDED observed_at decides the
# window (its stamp is a fixture parameter), and an unsealed 10:05
# group that exists only to CONFIRM the reference group (the last
# CONFIRMED group is the mode's reference, never the unconfirmed tail)
# — plus an INCOMPLETE non-candidate tail record. The input carries
# three ka10027 chain-pair snapshots and per-symbol ka10081 daily bars.
# The reference group's upserts are {011060, 006660} (017960's EXITED
# symbol is never part of the correspondence check and no snapshot
# carries it): snapshot 2 carries both upserts (offset 0), snapshots 1
# and 3 carry trap prices that would classify differently — the served
# lists can only come from the snapshot the mode actually mapped.
# 006660 is dual-direction (UP in group 1, DOWN in group 2): the
# per-symbol candidate state dedups it to the later DOWN upsert.

OM_WINNER = "opening-2026-11-10-a"
OM_SESSION_DATE = "2026-11-10"
OM_T1 = "2026-11-10T08:50:00+09:00"
OM_T3 = "2026-11-10T10:05:00+09:00"
OM_TEND = "2026-11-10T10:06:00+09:00"
OM_REF_STAMP = "2026-11-10T09:10:00+09:00"

OM_NAMES = {"000660": "SK하이닉스", "001440": "삼성카드",
            "005930": "삼성전자", "006660": "LG전자",
            "008480": "신풍제약", "009150": "삼성전기",
            "011060": "SK텔레콤", "012330": "현대모비스",
            "015760": "한국전력"}


def om_fact(tag, stamp, event_type, symbol, direction, rank=None):
    extra = {"direction": direction, "symbol": symbol}
    if rank is not None:
        extra["rank"] = rank
    return event_fact(b"om-" + tag, event_type, OM_SESSION_DATE, stamp,
                      "candidate-transition-v1", **extra)


# Group 1 (OM_T1) — the baseline: the whole universe enters (UP batch,
# then DOWN batch). Twelve candidates; zero change records.
OM_G1 = [
    om_fact(b"g1-up01", OM_T1, "CANDIDATE_ENTERED", "005930", "UP", 1),
    om_fact(b"g1-up02", OM_T1, "CANDIDATE_ENTERED", "006660", "UP", 2),
    om_fact(b"g1-up03", OM_T1, "CANDIDATE_ENTERED", "012330", "UP", 6),
    om_fact(b"g1-up04", OM_T1, "CANDIDATE_ENTERED", "015760", "UP", 7),
    om_fact(b"g1-up05", OM_T1, "CANDIDATE_ENTERED", "002420", "UP", 10),
    om_fact(b"g1-up06", OM_T1, "CANDIDATE_ENTERED", "005490", "UP", 11),
    om_fact(b"g1-dn01", OM_T1, "CANDIDATE_ENTERED", "000660", "DOWN", 1),
    om_fact(b"g1-dn02", OM_T1, "CANDIDATE_ENTERED", "009150", "DOWN", 4),
    om_fact(b"g1-dn03", OM_T1, "CANDIDATE_ENTERED", "008480", "DOWN", 8),
    om_fact(b"g1-dn04", OM_T1, "CANDIDATE_ENTERED", "001440", "DOWN", 9),
    om_fact(b"g1-dn05", OM_T1, "CANDIDATE_ENTERED", "003490", "DOWN", 12),
    om_fact(b"g1-dn06", OM_T1, "CANDIDATE_ENTERED", "017960", "DOWN", 5),
]
OM_G1_BY_SYMBOL = {ev["symbol"]: ev for ev in OM_G1}


# Group 2 (the reference group) — three facts whose stamps are the
# window parameter: a DOWN exit of the group-1 rank-5 member (017960),
# and the two upserts the correspondence check is about.
def om_g2_017960x(stamp):
    return om_fact(b"g2-dn01x", stamp, "CANDIDATE_EXITED", "017960", "DOWN")


def om_g2_011060(stamp):
    return om_fact(b"g2-dn02", stamp, "CANDIDATE_ENTERED", "011060",
                   "DOWN", 3)


def om_g2_006660(stamp):
    return om_fact(b"g2-dn03", stamp, "CANDIDATE_ENTERED", "006660",
                   "DOWN", 7)


# Group 3 (OM_T3, unsealed) — one same-rank update: it only opens the
# group that confirms group 2; its own changes are never derived.
OM_G3_005930 = om_fact(b"g3-up01", OM_T3, "CANDIDATE_UPDATED", "005930",
                       "UP", 1)

# The run's last committed event — a non-candidate INCOMPLETE record
# (data_quality is served verbatim; the mode is orthogonal to it).
OM_TAIL = event_fact(b"om-sub", "SUBSCRIPTION_TRUNCATED",
                     OM_SESSION_DATE, OM_TEND, "subscription-truncated-v1",
                     severity="HIGH", data_quality="INCOMPLETE",
                     direction="UP")


def om_winner_events(ref_stamp):
    return OM_G1 + [om_g2_017960x(ref_stamp), om_g2_011060(ref_stamp),
                    om_g2_006660(ref_stamp), OM_G3_005930, OM_TAIL]


# The ka10027 rows of the three chain-pair snapshots (prices are the
# signed cur_prc values the fold strips):
#   snapshot 1 (offset -1): 005930 +50000, 000660 +60000, 011060 +90000
#   snapshot 2 (offset  0): 005930 +75000, 000660 +120000, 009150 +30000,
#                           012330 +50000, 015760 +50000, 011060 +17000,
#                           008480 +20000, 006660 +45000, 001440 +10000
#   snapshot 3 (offset +1): 005930 +40000, 012330 +20000, 006660 +99000
# 003490 has bars but never a snapshot price; 002420 and 005490 have no
# usable closes (no record, and only nineteen completed days).
def om_rows(*pairs):
    return [(symbol, OM_NAMES[symbol], price) for symbol, price in pairs]


def om_chain(seq, sort_tp, rows, page=1, cont_yn="N"):
    return rest_resp_record(seq, ka10027_body(rows), sort_tp=sort_tp,
                            page=page, cont_yn=cont_yn)


# The ka10081 daily bars: uniform closes so each symbol's twenty-close
# sum is 20 x close. The first row is the session's in-progress bar
# (dt == session_date, never summed).
OM_MA20_CLOSES = {"000660": 100000, "001440": 10000, "003490": 30000,
                  "005930": 70000, "006660": 50000, "008480": 22500,
                  "009150": 25000, "011060": 20000, "012330": 45000,
                  "015760": 47500}


def om_dts(count):
    dts = ["20261109", "20261106", "20261105", "20261104", "20261103",
           "20261102", "20261030", "20261029", "20261028", "20261027",
           "20261026", "20261023", "20261022", "20261021", "20261020",
           "20261019", "20261016", "20261015", "20261014", "20261013"]
    return dts[:count]


def ka10081_row(dt, close):
    return {"acml_trde_qty": "1000000", "cur_prc": str(close), "dt": dt,
            "flr_tp": "01", "high_prc": str(close + 500),
            "low_prc": str(close - 500), "open_prc": str(close - 200),
            "trde_amt": "100000000", "trde_qty": "50000",
            "trde_tp": "001", "updn_prc": "+100", "updn_rate": "+0.50"}


def ka10081_record(seq, symbol, close, completed=20):
    rows = [ka10081_row("20261110", close + 123)]  # the in-progress bar
    rows += [ka10081_row(dt, close) for dt in om_dts(completed)]
    return rest_resp_record(
        seq, {"return_code": 0, "return_msg": "정상처리 되었습니다.",
              "stk_dt_pole_chart_qry": rows},
        api_id="ka10081",
        query={"base_dt": "", "stk_cd": symbol, "tick_kind": "2"})


def om_winner_input(variant, pre_empty_pairs=0):
    """The winner's recorded rest_resp sequence. `variant` moves the
    reference group's upsert symbols between chain-pair snapshots:
    "0" keeps both in snapshot 2 (offset 0, the measured default),
    "+1" only in snapshot 3, "-1" only in snapshot 1, "none" in no
    snapshot at all (the correspondence failure — DataFault).
    `pre_empty_pairs` prepends that many pre-open polls — both legs
    affirming success with no ranking rows (the 2026-11-11 live
    pre-open shape): an empty pair contributes no snapshot and must
    not drift the snapshot index against the candidate-group index."""
    s1_falling = om_rows(("011060", 90000))
    if variant == "-1":
        s1_falling += om_rows(("006660", 30000))
    s2_falling1 = om_rows(("008480", 20000))
    if variant == "0":
        s2_falling1 += om_rows(("011060", 17000))
    s3_falling = om_rows(("006660", 99000))
    if variant == "+1":
        s3_falling += om_rows(("011060", 99000))
    records = []
    seq = 3
    for _ in range(pre_empty_pairs):
        records.append(om_chain(seq, "1", []))
        records.append(om_chain(seq + 1, "3", []))
        seq += 2
    for rows, sort_tp, page, cont_yn in (
        # pair 1: snapshot 1 (the offset -1 trap prices)
        (om_rows(("005930", 50000), ("000660", 60000)), "1", 1, "N"),
        (s1_falling, "3", 1, "N"),
        # pair 2: snapshot 2 — the reference chain-pair, two pages per
        # leg (page 1 continues, page 2 completes)
        (om_rows(("005930", 75000), ("000660", 120000),
                 ("009150", 30000)), "1", 1, "Y"),
        (om_rows(("012330", 50000), ("015760", 50000)), "1", 2, "N"),
        (s2_falling1, "3", 1, "Y"),
        (om_rows(("006660", 45000), ("001440", 10000)), "3", 2, "N"),
        # pair 3: snapshot 3 (the offset +1 trap prices)
        (om_rows(("005930", 40000), ("012330", 20000)), "1", 1, "N"),
        (s3_falling, "3", 1, "N"),
    ):
        records.append(om_chain(seq, sort_tp, rows, page=page,
                                cont_yn=cont_yn))
        seq += 1
    for symbol in sorted(OM_MA20_CLOSES):
        records.append(ka10081_record(seq, symbol, OM_MA20_CLOSES[symbol]))
        seq += 1
    records.append(ka10081_record(seq, "005490", 10000, completed=19))
    return records


def om_item(ev, ma20_tag):
    """The §3.7 opening-mode item of a fixture fact: the nine-field
    whitelist, ma20_tag set by the mode, every other value the fact's
    own recorded value."""
    item = {k: ev[k] for k in ("data_quality", "direction", "event_id",
                               "event_type", "observed_at", "symbol")}
    item["ma20_tag"] = ma20_tag
    item["name"] = OM_NAMES.get(ev["symbol"])
    item["rank"] = ev.get("rank")
    return item


def om_expected(ref_stamp, rising, falling):
    history = [
        mv_change("CANDIDATE_EXITED", om_g2_017960x(ref_stamp), None, 5,
                  OM_NAMES),
        mv_change("TOP10_ENTERED", om_g2_011060(ref_stamp), 3, None,
                  OM_NAMES),
        mv_change("TOP10_ENTERED", om_g2_006660(ref_stamp), 7, None,
                  OM_NAMES),
    ]
    return {
        "as_of": OM_TEND,
        "falling_top10": falling,
        "history": history,
        "latest": {"data_quality": "INCOMPLETE",
                   "event_id": OM_TAIL["event_id"],
                   "event_type": "SUBSCRIPTION_TRUNCATED",
                   "observed_at": OM_TEND},
        "mode": "opening_ma20",
        "run": {"environment": "demo", "run_id": OM_WINNER,
                "session": OM_WINNER, "session_date": OM_SESSION_DATE},
        "rising_top10": rising,
        "runs_present": True,
        "status": {"by_data_quality": {"INCOMPLETE": 1, "OBSERVING": 16}},
    }


def om_expected_bodies(ref_stamp):
    """The three correspondence variants' expected bodies (offset 0
    reads snapshot 2, +1 snapshot 3, -1 snapshot 1 — the trap prices
    differ per snapshot, so each variant's lists are distinct)."""
    g1 = OM_G1_BY_SYMBOL
    zero = om_expected(
        ref_stamp,
        [om_item(g1["000660"], "ABOVE"), om_item(g1["009150"], "ABOVE"),
         om_item(g1["012330"], "ABOVE"), om_item(g1["005930"], "ABOVE"),
         om_item(g1["015760"], "ABOVE")],
        [om_item(om_g2_011060(ref_stamp), "BELOW"),
         om_item(g1["008480"], "BELOW"),
         om_item(om_g2_006660(ref_stamp), "BELOW")])
    plus_one = om_expected(
        ref_stamp,
        [om_item(om_g2_011060(ref_stamp), "ABOVE"),
         om_item(om_g2_006660(ref_stamp), "ABOVE")],
        [om_item(g1["012330"], "BELOW"), om_item(g1["005930"], "BELOW")])
    minus_one = om_expected(
        ref_stamp,
        [om_item(om_g2_011060(ref_stamp), "ABOVE")],
        [om_item(g1["000660"], "BELOW"),
         om_item(om_g2_006660(ref_stamp), "BELOW"),
         om_item(g1["005930"], "BELOW")])
    return zero, plus_one, minus_one


def build_opening_sandbox(ref_stamp=OM_REF_STAMP, variant="0",
                          pre_empty_pairs=0):
    """The §3.7 opening-mode fixture tree: the eligible winner run and
    one smoke-like ineligible directory (runs_present stays true while
    selection has exactly one eligible run)."""
    box = Sandbox()
    run_dir = box.session_dir(OM_WINNER)
    box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
        {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
        {"kind": "config", "raw": {"environment": "demo",
                                   "run_id": OM_WINNER,
                                   "session_date": OM_SESSION_DATE},
         "seq": 2},
        *om_winner_input(variant, pre_empty_pairs)))
    box.write(os.path.join(run_dir, "events.hcj.jsonl"),
              jsonl(*om_winner_events(ref_stamp)))
    smoke = box.session_dir("smoke-like-2026-11-10")
    box.write(os.path.join(smoke, "input.hcj.jsonl"), jsonl(
        {"kind": "config", "raw": {"session_date": OM_SESSION_DATE},
         "seq": 1}))
    box.write(os.path.join(smoke, "events.hcj.jsonl"), b"")
    return box


# -- §3.7 events_contract "top10-v1" fact-path fixtures (README §3.7) -----
#
# A separate 2026-11-12 run: the same candidate-event fold as the legacy
# winner, plus the TOP10 facts Core journals per the emission contract —
# a group's boundary facts sit between its candidate batch and the next
# group's batch, the final group's kSessionEnd flush facts are followed
# only by the same-stamp SESSION_ENDED. Unsealed, the run serves exactly
# group 2's boundary facts (group 3's next-stamp batch follows them);
# the seal admits group 3's flush facts too. The same recorded events
# with NO config marker project the legacy state-comparison history —
# the discriminator test's both branches.

TF_WINNER = "fact-2026-11-12-a"
TF_SESSION_DATE = "2026-11-12"
TF_T1 = "2026-11-12T10:00:01+09:00"
TF_T2 = "2026-11-12T10:05:01+09:00"
TF_T3 = "2026-11-12T10:10:01+09:00"  # the flush facts' AND
                                     # SESSION_ENDED's shared stamp

TF_NAMES = {"005930": "삼성전자", "006660": "LG전자"}


def tf_candidate(tag, stamp, event_type, symbol, direction, rank=None):
    extra = {"direction": direction, "symbol": symbol}
    if rank is not None:
        extra["rank"] = rank
    return event_fact(b"tf-" + tag, event_type, TF_SESSION_DATE, stamp,
                      "candidate-transition-v1", **extra)


def tf_fact(tag, stamp, event_type, symbol, direction=None, rank=None,
            previous_rank=None, name=None, session_id=TF_SESSION_DATE):
    """A TOP10 fact of the events_contract shape: the event schema's
    common fields plus the optional direction / rank / previous_rank /
    name the fact path translates (an absent key projects as null —
    TOP10_EXITED's candidate-disappearance case records no rank, a
    brand-new TOP10 member records no previous_rank)."""
    extra = {"symbol": symbol}
    if direction is not None:
        extra["direction"] = direction
    if rank is not None:
        extra["rank"] = rank
    if previous_rank is not None:
        extra["previous_rank"] = previous_rank
    if name is not None:
        extra["name"] = name
    return event_fact(b"tff-" + tag, event_type, session_id, stamp,
                      "top10-market-alert-v1", **extra)


# Group 1 (TF_T1) — the baseline: twelve UP candidates (ranks 1..12, so
# TOP10 membership is ranks 1-10) and two DOWN candidates enter. The
# baseline group confirms zero changes — Core journals no facts for it.
TF_G1 = [
    tf_candidate(b"g1-up01", TF_T1, "CANDIDATE_ENTERED", "005930", "UP", 1),
    tf_candidate(b"g1-up02", TF_T1, "CANDIDATE_ENTERED", "006660", "UP", 2),
    tf_candidate(b"g1-up03", TF_T1, "CANDIDATE_ENTERED", "007070", "UP", 3),
    tf_candidate(b"g1-up04", TF_T1, "CANDIDATE_ENTERED", "008480", "UP", 4),
    tf_candidate(b"g1-up05", TF_T1, "CANDIDATE_ENTERED", "009150", "UP", 5),
    tf_candidate(b"g1-up06", TF_T1, "CANDIDATE_ENTERED", "010060", "UP", 6),
    tf_candidate(b"g1-up07", TF_T1, "CANDIDATE_ENTERED", "011060", "UP", 7),
    tf_candidate(b"g1-up08", TF_T1, "CANDIDATE_ENTERED", "011140", "UP", 8),
    tf_candidate(b"g1-up09", TF_T1, "CANDIDATE_ENTERED", "011780", "UP", 9),
    tf_candidate(b"g1-up10", TF_T1, "CANDIDATE_ENTERED", "012330", "UP", 10),
    tf_candidate(b"g1-up11", TF_T1, "CANDIDATE_ENTERED", "015760", "UP", 11),
    tf_candidate(b"g1-up12", TF_T1, "CANDIDATE_ENTERED", "012450", "UP", 12),
    tf_candidate(b"g1-dn01", TF_T1, "CANDIDATE_ENTERED", "000660", "DOWN",
                 1),
    tf_candidate(b"g1-dn02", TF_T1, "CANDIDATE_ENTERED", "000810", "DOWN",
                 2),
]

# Group 2 (TF_T2) — the recorded candidate batch: the TOP10 head swap
# (005930/006660), 011060 pushed to rank 11, 015760 entering at 7, a
# DOWN reshuffle (000720 new at 1, 000660 to 2) and 000810's exit.
TF_G2 = [
    tf_candidate(b"g2-up01", TF_T2, "CANDIDATE_UPDATED", "005930", "UP", 2),
    tf_candidate(b"g2-up02", TF_T2, "CANDIDATE_UPDATED", "006660", "UP", 1),
    tf_candidate(b"g2-up07", TF_T2, "CANDIDATE_UPDATED", "011060", "UP", 11),
    tf_candidate(b"g2-up11", TF_T2, "CANDIDATE_UPDATED", "015760", "UP", 7),
    tf_candidate(b"g2-dn00", TF_T2, "CANDIDATE_ENTERED", "000720", "DOWN",
                 1),
    tf_candidate(b"g2-dn01", TF_T2, "CANDIDATE_UPDATED", "000660", "DOWN",
                 2),
    tf_candidate(b"g2-dn02x", TF_T2, "CANDIDATE_EXITED", "000810", "DOWN"),
]

# Group 2's boundary facts (TF_T2, recorded in a deliberately non-
# symbol-sorted order — history must keep this journal order): the
# vocabulary's three types, the rank-null (candidate disappearance) and
# previous_rank-null (brand-new member) cases, and the three name
# shapes (the fact's own name, the ka10027 dictionary fallback, and
# honest null when neither names the symbol).
TF_G2_FACTS = [
    tf_fact(b"g2-f02", TF_T2, "RANK_CHANGED", "006660", "UP", rank=1,
            previous_rank=2),
    tf_fact(b"g2-f01", TF_T2, "RANK_CHANGED", "005930", "UP", rank=2,
            previous_rank=1, name="삼성전자"),
    tf_fact(b"g2-f07", TF_T2, "TOP10_EXITED", "011060", "UP", rank=11,
            previous_rank=7, name="SK텔레콤"),
    tf_fact(b"g2-f11", TF_T2, "TOP10_ENTERED", "015760", "UP", rank=7,
            previous_rank=11),
    tf_fact(b"g2-fd01", TF_T2, "RANK_CHANGED", "000660", "DOWN", rank=2,
            previous_rank=1),
    tf_fact(b"g2-fx02", TF_T2, "TOP10_EXITED", "000810", "DOWN",
            previous_rank=2),
    tf_fact(b"g2-fn00", TF_T2, "TOP10_ENTERED", "000720", "DOWN", rank=1),
]

# Group 3 (TF_T3) — a four-side reshuffle; its facts are the kSessionEnd
# flush (group 4 never comes), followed only by the same-stamp
# SESSION_ENDED: unsealed they have no eligibility, sealed they serve.
TF_G3 = [
    tf_candidate(b"g3-up01", TF_T3, "CANDIDATE_UPDATED", "005930", "UP", 1),
    tf_candidate(b"g3-up02", TF_T3, "CANDIDATE_UPDATED", "006660", "UP", 2),
    tf_candidate(b"g3-up03", TF_T3, "CANDIDATE_UPDATED", "007070", "UP", 4),
    tf_candidate(b"g3-up04", TF_T3, "CANDIDATE_UPDATED", "008480", "UP", 3),
]
TF_G3_FLUSH_FACTS = [
    tf_fact(b"g3-f01", TF_T3, "RANK_CHANGED", "005930", "UP", rank=1,
            previous_rank=2),
    tf_fact(b"g3-f02", TF_T3, "RANK_CHANGED", "006660", "UP", rank=2,
            previous_rank=1),
    tf_fact(b"g3-f03", TF_T3, "RANK_CHANGED", "007070", "UP", rank=4,
            previous_rank=3),
    tf_fact(b"g3-f04", TF_T3, "RANK_CHANGED", "008480", "UP", rank=3,
            previous_rank=4),
]
TF_SESSION_END = event_fact(b"tf-end", "SESSION_ENDED", TF_SESSION_DATE,
                            TF_T3, "session-close-v1")


def tf_winner_events():
    """The fact run's committed sequence: three candidate batches with
    their fact blocks interleaved per the emission order, closed by the
    same-stamp SESSION_ENDED."""
    return (TF_G1 + TF_G2 + TF_G2_FACTS + TF_G3 + TF_G3_FLUSH_FACTS
            + [TF_SESSION_END])


def tf_committed_marker(name):
    return canonical({"run_id": name, "schema": "hong-scanner-commit/1",
                      "seq": 3, "sha256": sha(b"input-tf"),
                      "t": "2026-11-12T10:11:00+09:00"}) + b"\n"


# The input's ka10027 rows: the folded dictionary is exactly TF_NAMES
# (005930 named at the head, 006660 renamed later — the fallback order
# is irrelevant here, only the final map).
TF_WINNER_INPUT = [
    rest_resp_record(3, ka10027_body([("005930", "삼성전자", 75000),
                                      ("006660", "LG전자", 45000)])),
]


def tf_change(fact, names=None):
    """The §3.7 fact-path change record of a fixture fact: the fact's
    own nine whitelisted fields — change_type is the event_type
    verbatim, prev_rank the fact's previous_rank (absent -> null), rank
    the fact's rank (absent -> null), name the fact's name with the
    fixture dictionary fallback."""
    return {"change_type": fact["event_type"],
            "data_quality": fact["data_quality"],
            "direction": fact.get("direction"),
            "event_id": fact["event_id"],
            "name": fact.get("name", (names or {}).get(fact["symbol"])),
            "observed_at": fact["observed_at"],
            "prev_rank": fact.get("previous_rank"),
            "rank": fact.get("rank"),
            "symbol": fact["symbol"]}


def tf_item(ev):
    """The §3.7 top10 item of a fixture candidate event (the unchanged
    candidate fold's own shape): nine fields, name from the folded
    dictionary, rank null on CANDIDATE_EXITED."""
    item = {k: ev[k] for k in ("data_quality", "direction", "event_id",
                               "event_type", "observed_at", "symbol")}
    item["ma20_tag"] = None
    item["rank"] = ev.get("rank")
    item["name"] = TF_NAMES.get(ev["symbol"])
    return item


TF_HISTORY_G2 = [tf_change(f, TF_NAMES) for f in TF_G2_FACTS]
TF_HISTORY_G3 = [tf_change(f, TF_NAMES) for f in TF_G3_FLUSH_FACTS]

TF_EXPECTED = {
    "as_of": TF_T3,
    "falling_top10": [tf_item(TF_G2[4]), tf_item(TF_G2[5])],
    "history": TF_HISTORY_G2,  # the unsealed run: flush facts ineligible
    "latest": {"data_quality": "OBSERVING",
               "event_id": TF_SESSION_END["event_id"],
               "event_type": "SESSION_ENDED",
               "observed_at": TF_T3},
    "mode": "core",  # every confirmed group stamps 10:05 or earlier
    "rising_top10": [tf_item(TF_G3[0]), tf_item(TF_G3[1]),
                     tf_item(TF_G3[3]), tf_item(TF_G3[2]),
                     tf_item(TF_G1[4]), tf_item(TF_G1[5]),
                     tf_item(TF_G2[3]), tf_item(TF_G1[7]),
                     tf_item(TF_G1[8]), tf_item(TF_G1[9])],
    "run": {"environment": "demo", "run_id": TF_WINNER,
            "session": TF_WINNER, "session_date": TF_SESSION_DATE},
    "runs_present": True,
    "status": {"by_data_quality": {"OBSERVING": 37}},
}
TF_EXPECTED_SEALED = dict(TF_EXPECTED, history=TF_HISTORY_G2 + TF_HISTORY_G3)

# The SAME recorded events through the legacy path (config marker
# absent): the state-comparison derivation of groups 2 and (sealed) 3 —
# the facts count in status like any event but never fold into history.
TF_LEGACY_HISTORY_G2 = [
    mv_change("RANK_CHANGED", TF_G2[0], 2, 1, TF_NAMES),
    mv_change("RANK_CHANGED", TF_G2[1], 1, 2, TF_NAMES),
    mv_change("TOP10_EXITED", TF_G2[2], 11, 7, TF_NAMES),
    mv_change("TOP10_ENTERED", TF_G2[3], 7, 11, TF_NAMES),
    mv_change("TOP10_ENTERED", TF_G2[4], 1, None, TF_NAMES),
    mv_change("RANK_CHANGED", TF_G2[5], 2, 1, TF_NAMES),
    mv_change("CANDIDATE_EXITED", TF_G2[6], None, 2, TF_NAMES),
]
TF_LEGACY_HISTORY_G3 = [
    mv_change("RANK_CHANGED", TF_G3[0], 1, 2, TF_NAMES),
    mv_change("RANK_CHANGED", TF_G3[1], 2, 1, TF_NAMES),
    mv_change("RANK_CHANGED", TF_G3[2], 4, 3, TF_NAMES),
    mv_change("RANK_CHANGED", TF_G3[3], 3, 4, TF_NAMES),
]


def tf_ring_events(groups=12, per_group=10):
    """A facts-only run: `groups` fact blocks of `per_group`
    RANK_CHANGED facts (distinct stamps per block) closed by a
    non-candidate INCOMPLETE record at a later stamp — every fact is
    eligible without the seal, so the ring alone bounds the history."""
    events = []
    for g in range(groups):
        stamp = "2026-11-12T11:%02d:01+09:00" % g
        for i in range(per_group):
            events.append(tf_fact(("ring%02d-%02d" % (g, i)).encode(),
                                  stamp, "RANK_CHANGED", "005930", "UP",
                                  rank=i + 1, previous_rank=i + 2))
    events.append(event_fact(b"tf-ring-tail", "SUBSCRIPTION_TRUNCATED",
                             TF_SESSION_DATE,
                             "2026-11-12T11:%02d:01+09:00" % groups,
                             "subscription-truncated-v1",
                             severity="HIGH", data_quality="INCOMPLETE",
                             direction="UP"))
    return events


def build_fact_sandbox(events_contract="top10-v1", sealed=False):
    """The §3.7 fact-path fixture tree: one eligible run.
    `events_contract` writes the config discriminator (None omits the
    key — the legacy-path branch); `sealed` plants the finish()
    marker."""
    box = Sandbox()
    run_dir = box.session_dir(TF_WINNER)
    config = {"environment": "demo", "run_id": TF_WINNER,
              "session_date": TF_SESSION_DATE}
    if events_contract is not None:
        config["events_contract"] = events_contract
    box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
        {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
        {"kind": "config", "raw": config, "seq": 2},
        *TF_WINNER_INPUT))
    box.write(os.path.join(run_dir, "events.hcj.jsonl"),
              jsonl(*tf_winner_events()))
    if sealed:
        box.write(os.path.join(run_dir, "input.hcj.jsonl.committed"),
                  tf_committed_marker(TF_WINNER))
    return box


def jsonl(*objects):
    return b"".join(canonical(o) + b"\n" for o in objects)


class Sandbox:
    """mktemp fixture tree: runs root, ledger, delivery. Every file is
    canonical-JSON synthetic bytes; nothing here is real data."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="hs-api-contract-")
        self.runs = os.path.join(self.root, "runs")
        self.ledger = os.path.join(self.root, "ledger.hcj.jsonl")
        self.delivery = os.path.join(self.root, "delivery.hcj.jsonl")
        os.makedirs(self.runs)

    def session_dir(self, name):
        path = os.path.join(self.runs, name)
        os.makedirs(path, exist_ok=True)
        return path

    def write(self, path, data):
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    def write_session_files(self, name, with_session_end, with_marker):
        run_dir = self.session_dir(name)
        self.write(os.path.join(run_dir, "input.hcj.jsonl"),
                   jsonl(*(INPUT_A if with_session_end else INPUT_B)))
        self.write(os.path.join(run_dir, "bars.hcj.jsonl"),
                   canonical(BARS_LINE) + b"\n")
        self.write(os.path.join(run_dir, "signals.hcj.jsonl"),
                   canonical(SIGNALS_LINE) + b"\n")
        self.write(os.path.join(run_dir, "events.hcj.jsonl"),
                   canonical(EV2) + b"\n")
        return run_dir

    def write_checksums(self, run_dir, names):
        lines = []
        for name in names:
            with open(os.path.join(run_dir, name), "rb") as f:
                lines.append("%s  %s\n" % (sha(f.read()), name))
        self.write(os.path.join(run_dir, "CHECKSUMS.sha256"),
                   "".join(lines).encode("utf-8"))

    def cleanup(self):
        shutil.rmtree(self.root)


def build_main_sandbox():
    """The fixture contract of the main suite: four recorded sessions
    covering every projection branch, plus a 4-event ledger and a
    4-record delivery ledger."""
    box = Sandbox()

    # dir-20261031-plain: a bare run directory, no run.json, no
    # artifacts beyond one file — every absence branch of verification.
    box.write_session_files("dir-20261031-plain", with_session_end=False,
                            with_marker=False)
    os.remove(os.path.join(box.runs, "dir-20261031-plain",
                           "input.hcj.jsonl"))
    os.remove(os.path.join(box.runs, "dir-20261031-plain",
                           "signals.hcj.jsonl"))
    os.remove(os.path.join(box.runs, "dir-20261031-plain",
                           "events.hcj.jsonl"))

    # run-20261101-a: complete committed session, all checksums match,
    # session_end recorded, plus planted never-to-serve values.
    run_a = box.write_session_files("run-20261101-a", with_session_end=True,
                                    with_marker=False)
    box.write(os.path.join(run_a, "run.json"),
              canonical(RUN_JSON_A) + b"\n")
    box.write(os.path.join(run_a, "input.hcj.jsonl.committed"),
              canonical({"run_id": "run-a", "schema":
                         "hong-scanner-commit/1", "seq": 5,
                         "sha256": sha(b"input-a"),
                         "t": "2026-11-01T08:00:00+09:00"}) + b"\n")
    box.write_checksums(run_a, ["input.hcj.jsonl", "bars.hcj.jsonl",
                                "events.hcj.jsonl", "signals.hcj.jsonl"])
    box.write(os.path.join(run_a, "secret.txt"), (SECRET + "\n").encode())

    # run-20261101-b: checksums recorded, then bars.tcl tampered — the
    # recorded hash can no longer be confirmed. No committed marker, no
    # session_end: the session is recorded but incomplete.
    run_b = box.write_session_files("run-20261101-b", with_session_end=False,
                                    with_marker=False)
    box.write(os.path.join(run_b, "run.json"),
              canonical(RUN_JSON_B) + b"\n")
    box.write_checksums(run_b, ["input.hcj.jsonl", "bars.hcj.jsonl",
                                "events.hcj.jsonl", "signals.hcj.jsonl"])
    with open(os.path.join(run_b, "bars.hcj.jsonl"), "ab") as f:
        f.write(b"x")  # tampered after the checksum was recorded

    # run-20261102-c: operator-recorded verify output, no CHECKSUMS.
    run_c = box.session_dir("run-20261102-c")
    box.write(os.path.join(run_c, "run.json"),
              canonical(RUN_JSON_C) + b"\n")
    box.write(os.path.join(run_c, "verify.stdout"),
              ("VERDICT MATCH provenance=OK\n"
               "COMMIT=VALID\n"
               "EVENTS=%s\n" % sha(b"events-c")).encode("utf-8"))
    box.write(os.path.join(run_c, "events.hcj.jsonl"),
              canonical(EV2) + b"\n")

    box.write(box.ledger, jsonl(EV1, EV2, EV3, EV4))
    box.write(box.delivery, jsonl(D1, D2, D3, D4))
    return box


def build_market_view_sandbox(swap_groups=0, sealed=False):
    """The §3.7 fixture tree: the winning eligible run (the multi-group
    change-history scenario, run_id recorded, unsealed by default), an
    older same-date eligible run whose dirname sorts AFTER the winner
    (the observed_at tie-break must beat the dirname tie-break), an
    older-date eligible run with a NEWER last observed_at (session_date
    outranks observed_at), and the ineligible shapes: config without
    environment (smoke-like), config with a malformed session_date, and
    a directory holding only a subdirectory (drill-like). `sealed`
    plants the recorder's finish() marker in the winner — the §3.7
    group-finalization signal; `swap_groups` appends ring-stressing
    batches after group 4."""
    box = Sandbox()

    def write_market_run(name, config, events, input_extra=()):
        run_dir = box.session_dir(name)
        box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
            {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
            {"kind": "config", "raw": config, "seq": 2},
            *input_extra))
        box.write(os.path.join(run_dir, "events.hcj.jsonl"), jsonl(*events))

    write_market_run(MV_WINNER,
                     {"environment": "demo", "run_id": MV_WINNER,
                      "session_date": "2026-11-09"},
                     mv_winner_events(swap_groups), MV_WINNER_INPUT)
    if sealed:
        # the recorder's finish() product: present exactly at the seal —
        # the same marker the verification endpoint reports
        box.write(os.path.join(box.runs, MV_WINNER,
                               "input.hcj.jsonl.committed"),
                  canonical({"run_id": MV_WINNER,
                             "schema": "hong-scanner-commit/1",
                             "seq": 7, "sha256": sha(b"input-mv"),
                             "t": "2026-11-09T15:31:00+09:00"}) + b"\n")
    write_market_run("market-2026-11-09-z",
                     {"environment": "demo", "session_date": "2026-11-09"},
                     [event_fact(b"mv-old-same", "CANDIDATE_ENTERED",
                                 "2026-11-09",
                                 "2026-11-09T09:00:00+09:00",
                                 "candidate-transition-v1",
                                 direction="UP", rank=1, symbol="005930")])
    write_market_run("market-2026-11-08-y",
                     {"environment": "demo", "run_id": "market-2026-11-08-y",
                      "session_date": "2026-11-08"},
                     [event_fact(b"mv-old-date", "CANDIDATE_ENTERED",
                                 "2026-11-08",
                                 "2026-11-09T23:59:00+09:00",
                                 "candidate-transition-v1",
                                 direction="UP", rank=1, symbol="005930")])
    # smoke-like: both files present, but the config record carries no
    # environment — the collector-only field — so it is ineligible
    write_market_run("smoke-like-2026-11-09",
                     {"page_cap": 10, "session_date": "2026-11-09"},
                     [MV_DOWN_ENTERED_1])
    # eligible files and environment, but session_date is not the
    # collector's own validation shape
    write_market_run("bad-date-like",
                     {"environment": "demo", "session_date": "2026-11-9"},
                     [MV_DOWN_ENTERED_1])
    # drill-like: only a subdirectory, no recorded files at all
    os.makedirs(os.path.join(box.runs, "drill-like-20261109", "sub"))
    return box


class ServerProc:
    """One serve.py subprocess on an ephemeral port. The SERVE line is
    the only startup evidence the suite accepts, and it must name the
    address the server was asked to bind."""

    def __init__(self, box, with_delivery=True, bind=None):
        host = bind if bind is not None else "127.0.0.1"
        args = [PY, SERVE, "--runs", box.runs, "--ledger", box.ledger,
                "--port", "0"]
        if with_delivery:
            args += ["--delivery", box.delivery]
        if bind is not None:
            args += ["--bind", bind]
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        ready = select.select([self.proc.stdout], [], [], 20)[0]
        if not ready:
            self.proc.kill()
            out, err = self.proc.communicate(timeout=10)
            raise AssertionError("serve.py did not print SERVE in 20s: "
                                 "stdout=%r stderr=%r" % (out, err))
        line = self.proc.stdout.readline().decode("utf-8").strip()
        if not line.startswith("SERVE %s:" % host):
            raise AssertionError("unexpected serve line: %r" % line)
        self.bind = host
        self.port = int(line.split(":")[1])
        self.base = "http://%s:%d" % (host, self.port)

    def get(self, path, method="GET"):
        req = urlrequest.Request(self.base + path, method=method)
        try:
            with urlrequest.urlopen(req, timeout=10) as resp:
                return resp.status, resp.read(), dict(resp.headers)
        except HTTPError as err:
            return err.code, err.read(), dict(err.headers)

    def get_json(self, path):
        status, body, headers = self.get(path)
        return status, json.loads(body.decode("utf-8")), body, headers

    def stop(self):
        """SIGTERM, then reap. Returns (returncode, stderr). The suite
        asserts exit code 0 and no residue."""
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
        out, err = self.proc.communicate(timeout=15)
        return self.proc.returncode, err.decode("utf-8", "replace")

    def assert_gone(self):
        assert self.proc.poll() is not None, \
            "serve.py process survived SIGTERM"
        with socket.socket() as probe:
            try:
                probe.connect((self.bind, self.port))
            except ConnectionRefusedError:
                return
            raise AssertionError("port %d still accepting: residue" %
                                 self.port)


class ApiContractSuite(unittest.TestCase):
    """Endpoint contract against the main fixture sandbox."""

    def setUp(self):
        self.box = build_main_sandbox()
        self.addCleanup(self.box.cleanup)
        self.server = ServerProc(self.box)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        self.server.assert_gone()

    # -- startup evidence --------------------------------------------------

    def test_serve_line_binds_loopback_ephemeral(self):
        self.assertGreater(self.server.port, 0)
        self.assertLess(self.server.port, 65536)
        status, _, body, headers = self.server.get_json("/status")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")
        self.assertTrue(body.endswith(b"\n"))

    # -- /status -----------------------------------------------------------

    def test_status_projects_recorded_summary(self):
        status, body, _, _ = self.server.get_json("/status")
        self.assertEqual(status, 200)
        self.assertEqual(body["sessions"]["count"], 4)
        latest = body["sessions"]["latest"]
        self.assertEqual(latest["session"], "run-20261102-c")
        self.assertEqual(latest["session_date"], "2026-10-31")
        self.assertEqual(latest["code_commit"], COMMIT_C)
        self.assertTrue(latest["run_json_present"])
        events = body["events"]
        self.assertTrue(events["ledger_present"])
        self.assertEqual(events["count"], 4)
        self.assertEqual(events["by_type"], {
            "CANDIDATE_ENTERED": 2, "CANDIDATE_EXITED": 1,
            "SESSION_ENDED": 1})
        self.assertEqual(events["by_severity"], {"HIGH": 1, "INFO": 3})
        self.assertEqual(events["latest_session_id"], "2026-10-30")
        self.assertEqual(events["latest_event"]["event_id"],
                         EV4["event_id"])
        delivery = body["delivery"]
        self.assertTrue(delivery["configured"])
        self.assertTrue(delivery["present"])
        self.assertEqual(delivery["by_state"],
                         {"ACCEPTED": 1, "FAILED": 1, "PENDING": 1})
        self.assertEqual(delivery["pairs"], 3)
        self.assertEqual(delivery["devices"], 2)

    # -- /candidates ---------------------------------------------------------

    def test_candidates_latest_session_byte_canonical(self):
        expected = {"count": 2, "events": [EV3, EV4],
                    "ledger_present": True, "session_id": "2026-10-30"}
        status, body, raw, headers = self.server.get_json("/candidates")
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        self.assertEqual(body["events"][0]["symbol"], "000660")
        self.assertTrue(all(e["event_type"].startswith("CANDIDATE_")
                            for e in body["events"]))
        self.assertNotIn(EV1["event_id"],
                         [e["event_id"] for e in body["events"]])
        self.assertNotIn(EV2["event_id"],
                         [e["event_id"] for e in body["events"]])
        # the whole body is canonical bytes: keys sorted, LF-terminated
        self.assertEqual(raw, canonical(expected) + b"\n")
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")

    # -- /events -------------------------------------------------------------

    def test_events_join_delivery_last_record_wins(self):
        status, body, _, _ = self.server.get_json("/events")
        self.assertEqual(status, 200)
        self.assertTrue(body["ledger_present"])
        self.assertEqual(body["count"], 4)
        self.assertEqual(body["events"], [EV1, EV2, EV3, EV4])
        self.assertEqual(sorted(body["delivery"]),
                         sorted([EV1["event_id"], EV3["event_id"],
                                 EV4["event_id"]]))
        self.assertEqual(body["delivery"][EV1["event_id"]], [{
            "attempts": 1, "device_id": "dev-1",
            "provider_message_id": "projects/drill-project/messages/m-1",
            "state": "ACCEPTED",
            "updated_at": "2026-11-01T09:01:00+09:00"}])
        self.assertEqual(body["delivery"][EV3["event_id"]], [{
            "attempts": 2, "device_id": "dev-1",
            "error_code": "UNREGISTERED", "state": "FAILED",
            "updated_at": "2026-11-01T09:02:00+09:00"}])
        self.assertEqual(body["delivery"][EV4["event_id"]], [{
            "attempts": 0, "device_id": "dev-2", "state": "PENDING",
            "updated_at": "2026-11-01T09:02:00+09:00"}])

    def test_events_session_filter_exact_match(self):
        status, body, _, _ = self.server.get_json(
            "/events?session_id=2026-10-29")
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 2)
        self.assertEqual(body["events"], [EV1, EV2])
        self.assertEqual(sorted(body["delivery"]), [EV1["event_id"]])
        status, body, _, _ = self.server.get_json(
            "/events?session_id=1999-01-01")
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 0)
        self.assertEqual(body["events"], [])
        self.assertEqual(body["delivery"], {})

    # -- present-but-empty ledger (README §3.1: the writer's O_CREAT
    # opens the file before the first record — a real day-one state) ---

    def truncate_event_ledger(self):
        # Zero committed records in an EXISTING file: the notify worker
        # opens the event ledger with O_CREAT when the session starts,
        # so "file present, nothing recorded yet" is an operational
        # state the projection must survive, never a 500.
        with open(self.box.ledger, "wb"):
            pass

    def test_status_empty_ledger_projects_zero_count(self):
        self.truncate_event_ledger()
        status, body, _, _ = self.server.get_json("/status")
        self.assertEqual(status, 200)
        events = body["events"]
        self.assertTrue(events["ledger_present"])
        self.assertEqual(events["count"], 0)
        self.assertEqual(events["by_type"], {})
        self.assertEqual(events["by_severity"], {})
        self.assertIsNone(events["latest_session_id"])
        self.assertIsNone(events["latest_event"])
        # run directories are independent of the ledger state
        self.assertEqual(body["sessions"]["count"], 4)

    def test_candidates_empty_ledger_has_no_latest_session(self):
        self.truncate_event_ledger()
        status, body, _, _ = self.server.get_json("/candidates")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"ledger_present": True,
                                "session_id": None,
                                "count": 0, "events": []})

    def test_events_empty_ledger_lists_nothing(self):
        self.truncate_event_ledger()
        status, body, _, _ = self.server.get_json("/events")
        self.assertEqual(status, 200)
        self.assertTrue(body["ledger_present"])
        self.assertEqual(body["count"], 0)
        self.assertEqual(body["events"], [])
        self.assertEqual(body["delivery"], {})

    # -- /events/{id} --------------------------------------------------------

    def test_event_detail_with_and_without_delivery(self):
        status, body, _, _ = self.server.get_json("/events/" + EV1["event_id"])
        self.assertEqual(status, 200)
        self.assertEqual(body["event"], EV1)
        self.assertEqual(len(body["delivery"]), 1)
        self.assertEqual(body["delivery"][0]["state"], "ACCEPTED")
        status, body, _, _ = self.server.get_json("/events/" + EV2["event_id"])
        self.assertEqual(status, 200)
        self.assertEqual(body["event"], EV2)
        self.assertEqual(body["delivery"], [])

    def test_event_unknown_and_malformed_ids_404(self):
        unknown = sha(b"no-such-event")
        for path in ("/events/" + unknown,      # valid hex, not recorded
                     "/events/zzz",              # not hex
                     "/events/" + EV1["event_id"] + "/",   # trailing slash
                     "/events/..",               # traversal
                     "/events/%2e%2e",           # encoded traversal
                     "/events/a%2fb",            # encoded separator
                     "/events/" + "x" * 64,      # wrong alphabet
                     "/events/" + EV1["event_id"] + "%20"):  # trailing space
            status, _, body, _ = self.server.get_json(path)
            self.assertEqual(status, 404, path)
            self.assertIn(b"not_found", body)
            self.assertNotIn(SECRET.encode(), body)
            self.assertNotIn(self.box.root.encode(), body)

    # -- /sessions -----------------------------------------------------------

    def test_sessions_lists_run_directories_with_whitelist(self):
        status, body, _, _ = self.server.get_json("/sessions")
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 4)
        names = [s["session"] for s in body["sessions"]]
        self.assertEqual(names, ["dir-20261031-plain", "run-20261101-a",
                                 "run-20261101-b", "run-20261102-c"])
        plain = body["sessions"][0]
        self.assertFalse(plain["run_json_present"])
        for field in ("session_date", "run_id", "started_at",
                      "code_commit"):
            self.assertIsNone(plain[field], field)
        a = body["sessions"][1]
        self.assertEqual(a["session_date"], "2026-10-29")
        self.assertEqual(a["run_id"], "run-a")
        self.assertEqual(a["started_at"], "2026-11-01T08:00:00+09:00")
        self.assertEqual(a["code_commit"], COMMIT_A)

    # -- /sessions/{id}/verification ------------------------------------------

    def test_verification_complete_session(self):
        status, body, raw, _ = self.server.get_json(
            "/sessions/run-20261101-a/verification")
        self.assertEqual(status, 200)
        self.assertEqual(body["session"], "run-20261101-a")
        self.assertTrue(body["run_json_present"])
        self.assertEqual(body["session_date"], "2026-10-29")
        self.assertEqual(body["code_commit"], COMMIT_A)
        self.assertTrue(body["committed_marker"]["present"])
        self.assertEqual(body["committed_marker"]["file"],
                         "input.hcj.jsonl.committed")
        self.assertTrue(body["session_end_recorded"])
        with open(os.path.join(self.box.runs, "run-20261101-a",
                               "events.hcj.jsonl"), "rb") as f:
            self.assertEqual(body["events_file"],
                             {"present": True, "sha256": sha(f.read())})
        checksums = body["checksums"]
        self.assertTrue(checksums["present"])
        self.assertEqual([a["file"] for a in checksums["artifacts"]],
                         ["input.hcj.jsonl", "bars.hcj.jsonl",
                          "events.hcj.jsonl", "signals.hcj.jsonl"])
        self.assertTrue(all(a["match"] for a in checksums["artifacts"]))
        self.assertTrue(all(a["computed_sha256"] == a["recorded_sha256"]
                            for a in checksums["artifacts"]))
        self.assertEqual(body["replay_verdict"], {"recorded": False})
        self.assertTrue(raw.endswith(b"\n"))

    def test_verification_checksum_mismatch_and_incomplete(self):
        status, body, _, _ = self.server.get_json(
            "/sessions/run-20261101-b/verification")
        self.assertEqual(status, 200)
        self.assertFalse(body["committed_marker"]["present"])
        self.assertFalse(body["session_end_recorded"])
        self.assertTrue(body["run_json_present"])
        self.assertEqual(body["session_date"], "2026-10-30")
        self.assertEqual(body["code_commit"], COMMIT_B)
        artifacts = {a["file"]: a for a in body["checksums"]["artifacts"]}
        self.assertFalse(artifacts["bars.hcj.jsonl"]["match"])
        self.assertNotEqual(artifacts["bars.hcj.jsonl"]["computed_sha256"],
                            artifacts["bars.hcj.jsonl"]["recorded_sha256"])
        self.assertTrue(artifacts["input.hcj.jsonl"]["match"])
        self.assertTrue(artifacts["events.hcj.jsonl"]["match"])
        self.assertEqual(body["replay_verdict"], {"recorded": False})

    def test_verification_quotes_recorded_verdict_only(self):
        status, body, _, _ = self.server.get_json(
            "/sessions/run-20261102-c/verification")
        self.assertEqual(status, 200)
        self.assertEqual(body["replay_verdict"],
                         {"recorded": True, "source": "verify.stdout",
                          "line": "VERDICT MATCH provenance=OK"})
        self.assertFalse(body["checksums"]["present"])
        self.assertEqual(body["checksums"]["artifacts"], [])
        self.assertTrue(body["events_file"]["present"])
        self.assertEqual(body["code_commit"], COMMIT_C)

    def test_verification_all_absent_is_served_honestly(self):
        status, body, _, _ = self.server.get_json(
            "/sessions/dir-20261031-plain/verification")
        self.assertEqual(status, 200)
        self.assertFalse(body["run_json_present"])
        self.assertIsNone(body["session_date"])
        self.assertIsNone(body["code_commit"])
        self.assertFalse(body["committed_marker"]["present"])
        self.assertFalse(body["session_end_recorded"])
        self.assertEqual(body["events_file"], {"present": False,
                                               "sha256": None})
        self.assertFalse(body["checksums"]["present"])
        self.assertEqual(body["checksums"]["artifacts"], [])
        self.assertEqual(body["replay_verdict"], {"recorded": False})

    def test_verification_traversal_and_unknown_sessions_404(self):
        for path in ("/sessions/nosuch-session/verification",
                     "/sessions/./verification",
                     "/sessions/../verification",
                     "/sessions/..%2fverification",
                     "/sessions/run-20261101-a%2f..%2f..%2fsecret"
                     "/verification",
                     "/sessions/run-20261101-a..ok/verification",
                     "/sessions/run-20261101-a/verification/x",
                     "/sessions/run-20261101-a",
                     "/sessions//verification"):
            status, _, body, _ = self.server.get_json(path)
            self.assertEqual(status, 404, path)
            self.assertNotIn(SECRET.encode(), body)
            self.assertNotIn(self.box.root.encode(), body)

    def test_verification_safe_name_guard_in_recorded_checksums(self):
        # a recorded checksum naming an unsafe artifact is refused
        # without opening it, not followed
        run_dir = self.box.session_dir("run-guard-fixture")
        self.box.write(os.path.join(run_dir, "CHECKSUMS.sha256"),
                       ("%s  ../secret.txt\n" % sha(b"x")).encode())
        status, body, _, _ = self.server.get_json(
            "/sessions/run-guard-fixture/verification")
        self.assertEqual(status, 200)
        artifacts = body["checksums"]["artifacts"]
        self.assertEqual(len(artifacts), 1)
        self.assertEqual(artifacts[0]["file"], "../secret.txt")
        self.assertFalse(artifacts[0]["match"])
        self.assertIsNone(artifacts[0]["computed_sha256"])
        self.assertIn("refused", artifacts[0]["note"])

    # -- method and path guards ------------------------------------------------

    def test_only_get_is_allowed(self):
        for method, path in (("POST", "/events"), ("PUT", "/status"),
                             ("DELETE", "/sessions"),
                             ("PATCH", "/candidates"),
                             ("HEAD", "/status"), ("OPTIONS", "/events")):
            status, body, headers = self.server.get(path, method=method)
            self.assertEqual(status, 405, (method, path))
            self.assertEqual(headers.get("Allow"), "GET")
            if method != "HEAD":
                # HEAD responses carry no body by HTTP semantics
                self.assertIn(b"method_not_allowed", body)
                self.assertNotIn(SECRET.encode(), body)

    def test_unknown_paths_are_json_404(self):
        for path in ("/", "/api/status", "/events/", "/status/",
                     "/status?x=1", "/sessions/", "/candidates/x",
                     "/verification", "/favicon.ico"):
            status, body, headers = self.server.get(path)
            expected = 200 if path == "/status?x=1" else 404
            self.assertEqual(status, expected, path)
            self.assertEqual(headers["Content-Type"],
                             "application/json; charset=utf-8")
            self.assertTrue(body.endswith(b"\n"), path)
            if expected == 404:
                self.assertNotIn(path.encode(), body)  # no reflection

    # -- honesty of the projection ----------------------------------------------

    def test_no_secrets_or_filesystem_paths_in_any_body(self):
        paths = ("/status", "/candidates", "/events",
                 "/events/" + EV1["event_id"], "/sessions",
                 "/sessions/run-20261101-a/verification",
                 "/sessions/run-20261101-b/verification",
                 "/sessions/run-20261102-c/verification",
                 "/sessions/dir-20261031-plain/verification",
                 "/mobile/market-view")
        bodies = b""
        for path in paths:
            _, body, _ = self.server.get(path)
            bodies += body
        for needle in (SECRET.encode(), HIDDEN_HOST.encode(),
                       HIDDEN_EGRESS.encode(), str(HIDDEN_PID).encode(),
                       self.box.root.encode(), b"secret.txt\x00",
                       b"/home/", b"password"):
            self.assertNotIn(needle, bodies, needle)


class MarketViewSuite(unittest.TestCase):
    """GET /mobile/market-view (README §3.7): the bounded fold and the
    state-comparison change history of the latest eligible
    market-collection run — recorded facts only, ranks from the ledger,
    changes classified by comparing recorded snapshots, no judgment."""

    def setUp(self):
        self.box = build_market_view_sandbox()
        self.addCleanup(self.box.cleanup)
        self.server = ServerProc(self.box, with_delivery=False)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        self.server.assert_gone()

    def _reap(self, server):
        code, _ = server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        server.assert_gone()

    def seal_winner(self):
        """Plant the recorder's finish() marker — the §3.7 run seal. The
        server re-reads the recorded files on every request, so sealing
        needs no restart."""
        self.box.write(
            os.path.join(self.box.runs, MV_WINNER,
                         "input.hcj.jsonl.committed"),
            canonical({"run_id": MV_WINNER,
                       "schema": "hong-scanner-commit/1", "seq": 7,
                       "sha256": sha(b"input-mv"),
                       "t": "2026-11-09T15:31:00+09:00"}) + b"\n")

    # -- full-response contract --------------------------------------------

    def test_market_view_full_scenario_byte_canonical(self):
        # selection: session_date max beats the newer observed_at of the
        # 2026-11-08 run; the observed_at tie-break beats the winner's
        # smaller dirname; smoke/bad-date/drill dirs are ineligible
        status, body, raw, headers = self.server.get_json(
            "/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, MV_EXPECTED)
        # the whole body is canonical bytes: keys sorted, LF-terminated
        self.assertEqual(raw, canonical(MV_EXPECTED) + b"\n")
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")
        # the contract's mechanical size bound (README §3.7)
        self.assertLessEqual(len(raw), 65536)

    def test_market_view_unsealed_excludes_final_group(self):
        # the run is unsealed: group 2 was confirmed by group 3's new
        # stamp, but the final group (group 4) is unconfirmed — its
        # changes are absent from history even though the top10 fold
        # serves the final live state (a partial batch is never made to
        # look complete)
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(body["history"], MV_HISTORY_G2)
        self.assertTrue(all(c["observed_at"] != MV_T4
                            for c in body["history"]))
        self.assertNotIn("011060", [c["symbol"] for c in body["history"]])
        # the live top10 is last-record-wins regardless of the seal: the
        # direction switch IS served in falling_top10
        self.assertEqual(body["falling_top10"][0]["symbol"], "011060")

    def test_market_view_sealed_confirms_final_group(self):
        # the finish() marker exists: the last observation group is
        # confirmed and its changes enter the history
        self.seal_winner()
        status, body, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, MV_EXPECTED_SEALED)
        self.assertEqual(raw, canonical(MV_EXPECTED_SEALED) + b"\n")
        self.assertLessEqual(len(raw), 65536)

    # -- change-record shape and vocabulary ----------------------------------

    def test_market_view_change_records_shape(self):
        # every history record is the nine-field change whitelist: no
        # event_type key (a change record is not an event), no pos, and
        # the rank/prev_rank rules of the four-value vocabulary
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertTrue(body["history"])
        for item in body["history"]:
            self.assertEqual(sorted(item),
                             ["change_type", "data_quality", "direction",
                              "event_id", "name", "observed_at",
                              "prev_rank", "rank", "symbol"])
            self.assertNotIn("event_type", item)
            self.assertIn(item["change_type"], serve.MARKET_CHANGE_TYPES)
            if item["change_type"] == "CANDIDATE_EXITED":
                self.assertIsNone(item["rank"])  # honest absence, never 0
                self.assertIsInstance(item["prev_rank"], int)
            else:
                self.assertIsInstance(item["rank"], int)
                self.assertGreaterEqual(item["rank"], 1)
        for item in body["history"]:
            kind = item["change_type"]
            if kind == "RANK_CHANGED":
                self.assertLessEqual(item["rank"], 10)
                self.assertLessEqual(item["prev_rank"], 10)
                self.assertNotEqual(item["rank"], item["prev_rank"])
            elif kind == "TOP10_ENTERED":
                self.assertLessEqual(item["rank"], 10)
                self.assertTrue(item["prev_rank"] is None
                                or item["prev_rank"] > 10)
            elif kind == "TOP10_EXITED":
                self.assertLessEqual(item["prev_rank"], 10)
                self.assertGreater(item["rank"], 10)

    def test_market_view_group_records_sorted_by_evidence_position(self):
        # within one confirmed group the records are ordered by the
        # ledger position of the evidence event — an explicit sort, not
        # dict iteration order: the snapshot dict visits 006660 before
        # 008560 (group-1 insertion order), but 008560's evidence record
        # is the earlier ledger line
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual([c["event_id"] for c in body["history"]],
                         [ev["event_id"] for ev in
                          (MV_G2_UP05, MV_G2_UP02, MV_G2_UP03, MV_G2_UP04,
                           MV_G2_UP11, MV_G2_UP07, MV_G2_UP08,
                           MV_G2_DN02X)])

    def test_market_view_same_stamp_batches_merge(self):
        # groups 3A/3B share one observed_at: one merged group whose net
        # effect is zero — no record carries the merged stamp, and no
        # intermediate swap is ever recorded
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertTrue(all(c["observed_at"] != MV_T3
                            for c in body["history"]))
        self.assertEqual(body["history"], MV_HISTORY_G2)

    def test_market_view_direction_switch_is_two_records(self):
        # 011060 leaves UP and re-enters DOWN in one group: two records,
        # one per side — no separate switching judgment
        self.seal_winner()
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        switch = [c for c in body["history"] if c["symbol"] == "011060"]
        self.assertEqual(len(switch), 2)
        up_exit, down_entry = switch
        self.assertEqual(up_exit["change_type"], "CANDIDATE_EXITED")
        self.assertEqual(up_exit["direction"], "UP")
        self.assertIsNone(up_exit["rank"])
        self.assertEqual(up_exit["prev_rank"], 9)
        self.assertEqual(up_exit["event_id"], MV_G4_UP09X["event_id"])
        self.assertEqual(down_entry["change_type"], "TOP10_ENTERED")
        self.assertEqual(down_entry["direction"], "DOWN")
        self.assertEqual(down_entry["rank"], 1)
        self.assertIsNone(down_entry["prev_rank"])
        self.assertEqual(down_entry["event_id"], MV_G4_DN09["event_id"])

    def test_market_view_no_records_for_unchanged_or_outside(self):
        # same-rank symbols (005930 stayed rank 1 through group 2), the
        # TOP10-outside move 015760 15 -> 14 and the TOP10-outside exit
        # of 012330 all record nothing
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        recorded = [c["symbol"] for c in body["history"]]
        self.assertNotIn("015760", recorded)
        self.assertNotIn("012330", recorded)
        g2 = [c for c in body["history"] if c["observed_at"] == MV_T2]
        for symbol in ("005930", "009150", "011060", "011140"):
            self.assertNotIn(symbol, [c["symbol"] for c in g2])

    def test_market_view_first_group_is_baseline_zero_changes(self):
        # group 1 (every candidate ENTERED at MV_T1) is the comparison
        # baseline: it records zero changes — no record in any history
        # carries its stamp
        self.seal_winner()
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertTrue(all(c["observed_at"] != MV_T1
                            for c in body["history"]))

    def test_market_view_history_ring_keeps_last_100(self):
        # eleven post-group-4 swap batches (110 changes) plus the sealed
        # scenario's 14 exceed the ring: exactly the last 100 records are
        # served — the oldest 24 (group 2, group 4 and the first swap
        # batch) are dropped
        box = build_market_view_sandbox(swap_groups=11, sealed=True)
        self.addCleanup(box.cleanup)
        server = ServerProc(box, with_delivery=False)
        self.addCleanup(self._reap, server)
        status, body, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(len(body["history"]), 100)
        first, last = body["history"][0], body["history"][-1]
        # first kept: the second swap batch's first record (005930 back
        # to rank 1); last kept: the final batch's last record
        self.assertEqual(first["symbol"], "005930")
        self.assertEqual(first["change_type"], "RANK_CHANGED")
        self.assertEqual((first["rank"], first["prev_rank"]), (1, 2))
        self.assertEqual(first["observed_at"],
                         "2026-11-09T10:26:01+09:00")
        self.assertEqual(last["symbol"], "010060")
        self.assertEqual((last["rank"], last["prev_rank"]), (9, 10))
        self.assertEqual(last["observed_at"],
                         "2026-11-09T10:35:01+09:00")
        # the dropped window: nothing but the swap RANK_CHANGEDs remain
        self.assertEqual({c["change_type"] for c in body["history"]},
                         {"RANK_CHANGED"})
        self.assertNotIn("000810", [c["symbol"] for c in body["history"]])
        # top10 is the final live state (the last swap assignment)
        self.assertEqual([i["symbol"] for i in body["rising_top10"]],
                         ["008560", "005930", "007070", "006660",
                          "009150", "008480", "009540", "011780",
                          "010060", "011140"])
        # the ring keeps the response inside the contract's bound
        self.assertLessEqual(len(raw), 65536)

    # -- §3.7 name dictionary ----------------------------------------------

    def test_market_view_name_projection(self):
        # names come from the recorded ka10027 bodies of the selected
        # run only: latest record wins (006660 was renamed mid-run), an
        # error body without the ranking list contributes nothing, and
        # a ka10080 record is never a name source
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        names = {item["symbol"]: item["name"]
                 for item in body["rising_top10"] + body["falling_top10"]}
        self.assertEqual(names["005930"], "삼성전자")
        self.assertEqual(names["006660"], "LG전자")  # supersedes 구형이름
        self.assertNotIn("구형이름", json.dumps(body, ensure_ascii=False))
        history_names = {item["symbol"]: item["name"]
                         for item in body["history"]}
        self.assertEqual(history_names["006660"], "LG전자")
        # the map entry for a symbol with no event is never projected
        self.assertNotIn("179530", history_names)

    def test_market_view_name_null_when_not_recorded(self):
        # 011060 appears in events (the direction switch) but no
        # recorded ka10027 body ever names it: name stays null (honest
        # absence — the app falls back to the symbol), never "" or the
        # symbol itself
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(body["falling_top10"][0]["symbol"], "011060")
        self.assertIsNone(body["falling_top10"][0]["name"])
        exited = [item for item in body["history"]
                  if item["change_type"] == "CANDIDATE_EXITED"]
        self.assertEqual(exited[0]["symbol"], "000810")
        self.assertIsNone(exited[0]["name"])

    def test_market_view_input_torn_tail_not_folded(self):
        # a torn (non-LF) ka10027 tail naming 011060 is not committed:
        # folding it would flip the name null — the response stays the
        # committed one exactly
        torn = canonical(rest_resp_record(
            8, ka10027_body([("011060", "SK텔레콤", 17000)])))
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(torn[: len(torn) // 2])
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, MV_EXPECTED)

    def test_market_view_malformed_input_line_is_data_fault(self):
        # a committed but malformed input line is corruption, not a
        # skip — the name fold reads the same committed-lines rule
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(b"{not json}\n")
        status, _, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)

    def test_market_view_name_envelope_violation_is_data_fault(self):
        # body_hex is an envelope field the recorder itself guarantees
        # (hex): a committed record violating it is corruption
        record = rest_resp_record(8, ka10027_body([("011060", "SK텔레콤",
                                                    17000)]))
        record["raw"]["body_hex"] = "zz" + record["raw"]["body_hex"][2:]
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(canonical(record) + b"\n")
        status, _, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)

    def test_market_view_name_row_violation_is_data_fault(self):
        # a ranking row missing stk_nm violates the fold's dependent
        # recorded shape — same discipline as a candidate event
        # without rank
        record = rest_resp_record(8, {
            "pred_pre_flu_rt_upper": [{"stk_cd": "011060"}],
            "return_code": 0, "return_msg": "row without a name"})
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(canonical(record) + b"\n")
        status, _, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)

    def test_market_view_name_rescan_on_file_change(self):
        # the memoization key is (path, size, mtime_ns): appending a
        # committed ka10027 record changes the file, so the next
        # request — same server, no restart — rescans and serves the
        # newly recorded name; the request after that is stable
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertIsNone(body["falling_top10"][0]["name"])
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "input.hcj.jsonl"), "ab") as f:
            f.write(canonical(rest_resp_record(
                8, ka10027_body([("011060", "SK텔레콤", 17000)]))) + b"\n")
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body["falling_top10"][0]["symbol"], "011060")
        self.assertEqual(body["falling_top10"][0]["name"], "SK텔레콤")
        status2, body2, raw2, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status2, 200)
        self.assertEqual(body2, body)
        self.assertEqual(raw2, self.server.get("/mobile/market-view")[1])

    def test_market_view_torn_tail_is_not_committed(self):
        # the concurrently-appending shape: a torn (non-LF) tail record
        # is not folded, not in history, and not the selection's last
        # observed_at — the response is exactly the committed one
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "events.hcj.jsonl"), "ab") as f:
            f.write(canonical(mv_fact(b"torn", MV_T5, "CANDIDATE_ENTERED",
                                      "002420", "UP", 1))[:24])
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, MV_EXPECTED)

    def test_market_view_malformed_committed_line_is_data_fault(self):
        # a committed but malformed last line is corruption, not a skip
        with open(os.path.join(self.box.runs, MV_WINNER,
                               "events.hcj.jsonl"), "ab") as f:
            f.write(b"{not json}\n")
        status, _, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)

    def test_market_view_exact_path_only(self):
        for path in ("/mobile", "/mobile/market-view/",
                     "/mobile/market-view/x"):
            status, _, body, _ = self.server.get_json(path)
            self.assertEqual(status, 404, path)
            self.assertIn(b"not_found", body)


class MarketViewEmptySuite(unittest.TestCase):
    """§3.7 empty states: a runs root with no directories, directories
    but none eligible, and a selected run with zero committed events."""

    def run_with(self, box):
        self.addCleanup(box.cleanup)
        self.server = ServerProc(box, with_delivery=False)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0)
        self.server.assert_gone()

    def test_no_directories_projects_absent(self):
        box = Sandbox()
        self.run_with(box)
        expected = {"as_of": None, "falling_top10": [], "history": [],
                    "latest": None, "mode": "core", "rising_top10": [],
                    "run": None, "runs_present": False, "status": None}
        status, body, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        self.assertEqual(raw, canonical(expected) + b"\n")

    def test_directories_but_none_eligible(self):
        box = Sandbox()
        run_dir = box.session_dir("smoke-like-2026-11-09")
        box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
            {"kind": "calendar", "raw": {}, "seq": 1},
            {"kind": "config", "raw": {"session_date": "2026-11-09"},
             "seq": 2}))
        box.write(os.path.join(run_dir, "events.hcj.jsonl"),
                  jsonl(MV_DOWN_ENTERED_1))
        os.makedirs(os.path.join(box.runs, "drill-like", "sub"))
        self.run_with(box)
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"as_of": None, "falling_top10": [],
                                "history": [], "latest": None,
                                "mode": "core", "rising_top10": [],
                                "run": None, "runs_present": True,
                                "status": None})

    def test_selected_run_zero_committed_events(self):
        box = Sandbox()
        run_dir = box.session_dir("market-2026-11-09-empty")
        box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
            {"kind": "calendar", "raw": {}, "seq": 1},
            {"kind": "config", "raw": {"environment": "demo",
                                       "session_date": "2026-11-09"},
             "seq": 2}))
        box.write(os.path.join(run_dir, "events.hcj.jsonl"), b"")
        self.run_with(box)
        status, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, {
            "as_of": None, "falling_top10": [], "history": [],
            "latest": None, "mode": "core", "rising_top10": [],
            "run": {"environment": "demo", "run_id": None,
                    "session": "market-2026-11-09-empty",
                    "session_date": "2026-11-09"},
            "runs_present": True,
            "status": {"by_data_quality": {}}})


class MarketViewOpeningSuite(unittest.TestCase):
    """GET /mobile/market-view (README §3.7, VS-2): the opening MA20
    mode. The window predicate reads the reference group's RECORDED
    observed_at (converted to KST, never the wall clock); inside
    [09:00:00, 09:30:00) the top10 lists are reconstituted from the
    recorded chain-pair prices of that group's snapshot against the
    recorded twenty-day close sums — the integer cross product, no
    float. Rank, event_id and direction stay the state item's own
    recorded values; the mode's only decisions are placement and
    ma20_tag. Outside the window the response is the core
    last-record-wins assembly (mode "core")."""

    def setUp(self):
        self.box = build_opening_sandbox()
        self.addCleanup(self.box.cleanup)
        self.server = ServerProc(self.box, with_delivery=False)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        self.server.assert_gone()

    def _reap(self, server):
        code, _ = server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        server.assert_gone()

    def opening_server(self, ref_stamp=OM_REF_STAMP, variant="0",
                       pre_empty_pairs=0):
        box = build_opening_sandbox(ref_stamp, variant, pre_empty_pairs)
        self.addCleanup(box.cleanup)
        server = ServerProc(box, with_delivery=False)
        self.addCleanup(self._reap, server)
        return server

    @staticmethod
    def symbols(body, key):
        return [item["symbol"] for item in body[key]]

    # -- full-response contract --------------------------------------------

    def test_opening_mode_full_scenario_byte_canonical(self):
        expected, _, _ = om_expected_bodies(OM_REF_STAMP)
        status, body, raw, headers = self.server.get_json(
            "/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        self.assertEqual(raw, canonical(expected) + b"\n")
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")
        # the contract's mechanical size bound (README §3.7)
        self.assertLessEqual(len(raw), 65536)
        # every top10 item is the nine-field whitelist and no item is
        # ever served with a null tag inside the mode
        for item in body["rising_top10"] + body["falling_top10"]:
            self.assertEqual(sorted(item),
                             ["data_quality", "direction", "event_id",
                              "event_type", "ma20_tag", "name",
                              "observed_at", "rank", "symbol"])
            self.assertIn(item["ma20_tag"], ("ABOVE", "BELOW"))

    def test_opening_mode_consecutive_requests_identical(self):
        # determinism through the memoized fold: two consecutive
        # requests serve identical bytes (a cache hit is byte-identical
        # to a rescan, and never a different answer)
        raw1 = self.server.get("/mobile/market-view")[1]
        raw2 = self.server.get("/mobile/market-view")[1]
        self.assertEqual(raw1, raw2)

    # -- recorded fields stay verbatim --------------------------------------

    def test_opening_mode_recorded_fields_stay_verbatim(self):
        # the mode never re-judges: the dual-direction 006660 is ONE
        # item (the later DOWN upsert wins the per-symbol dedup of the
        # two ranking legs) with its recorded DOWN rank and the
        # group-2 event id; UP and DOWN mix freely across the two lists
        # because classification is price-vs-MA20, not direction
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        both = body["rising_top10"] + body["falling_top10"]
        self.assertEqual([i["symbol"] for i in both].count("006660"), 1)
        item = next(i for i in both if i["symbol"] == "006660")
        self.assertEqual(item["direction"], "DOWN")
        self.assertEqual(item["rank"], 7)
        self.assertEqual(item["event_id"],
                         om_g2_006660(OM_REF_STAMP)["event_id"])
        self.assertEqual(item["observed_at"], OM_REF_STAMP)
        # 000660's own recorded DOWN rank 1 rides along in the RISING
        # list: the placement is the mode's, the fields are recorded
        rising = {i["symbol"]: i for i in body["rising_top10"]}
        self.assertEqual(rising["000660"]["rank"], 1)
        self.assertEqual(rising["000660"]["direction"], "DOWN")
        self.assertEqual(rising["000660"]["event_id"],
                         OM_G1_BY_SYMBOL["000660"]["event_id"])

    def test_opening_mode_order_ties_and_cross_product(self):
        # above: descending distance from MA20 — 000660 and 009150
        # share +0.2, the symbol codepoint breaks the tie; 012330
        # before 015760 is the integer cross product 20·P₁·ΣC₂ vs
        # 20·P₂·ΣC₁ (equal P, the larger close sum is further above).
        # below: ascending distance (furthest below first)
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(self.symbols(body, "rising_top10"),
                         ["000660", "009150", "012330", "005930", "015760"])
        self.assertEqual(self.symbols(body, "falling_top10"),
                         ["011060", "008480", "006660"])
        self.assertTrue(all(i["ma20_tag"] == "ABOVE"
                            for i in body["rising_top10"]))
        self.assertTrue(all(i["ma20_tag"] == "BELOW"
                            for i in body["falling_top10"]))

    def test_opening_mode_excludes_unclassifiable_symbols(self):
        # honest exclusion, never a fallback to the core lists: 001440
        # sits exactly at MA20 (20·P == ΣC — neither side), 003490 has
        # closes but no price in the mapped snapshot, 002420 has no
        # ka10081 record, 005490 only nineteen completed days; 017960
        # left the reference group (EXITED) and no snapshot carries it
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        served = {i["symbol"] for i in body["rising_top10"]
                  + body["falling_top10"]}
        for symbol in ("001440", "003490", "002420", "005490", "017960"):
            self.assertNotIn(symbol, served)

    # -- the chain-pair correspondence --------------------------------------

    def test_opening_mode_offset_zero_is_the_default(self):
        # snapshots 1 and 3 carry trap prices that would flip the
        # classification (005930 +50000/+40000 would be BELOW, 011060
        # +90000 and 006660 +99000 would be ABOVE): the served tags can
        # only come from snapshot 2 — the same-index correspondence
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        rising = {i["symbol"]: i for i in body["rising_top10"]}
        falling = {i["symbol"]: i for i in body["falling_top10"]}
        self.assertEqual(rising["005930"]["ma20_tag"], "ABOVE")
        self.assertEqual(rising["009150"]["ma20_tag"], "ABOVE")
        self.assertEqual(falling["011060"]["ma20_tag"], "BELOW")
        self.assertEqual(falling["006660"]["ma20_tag"], "BELOW")

    def test_opening_mode_offset_plus_one(self):
        # snapshot 2 lacks 011060, snapshot 3 carries both upserts: the
        # +1 mapping holds and snapshot 3's (trap) prices are served
        server = self.opening_server(variant="+1")
        _, expected, _ = om_expected_bodies(OM_REF_STAMP)
        status, body, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        self.assertEqual(raw, canonical(expected) + b"\n")

    def test_opening_mode_offset_minus_one(self):
        # neither snapshot 2 nor 3 carries 011060, snapshot 1 carries
        # both upserts: the -1 mapping holds and snapshot 1's prices
        # are served
        server = self.opening_server(variant="-1")
        _, _, expected = om_expected_bodies(OM_REF_STAMP)
        status, body, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        self.assertEqual(raw, canonical(expected) + b"\n")

    def test_opening_mode_all_offsets_fail_is_data_fault(self):
        # no snapshot's symbol set covers the reference group's
        # upserts: the recorded backing for the mode is incomplete and
        # the endpoint fails closed — never a core fallback
        server = self.opening_server(variant="none")
        status, _, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)

    def test_opening_mode_pre_open_empty_pairs_do_not_drift(self):
        # live 2026-11-11 regression: pre-open polls affirm success
        # with no ranking rows, closing empty pairs ahead of the first
        # price-bearing pair — the candidate groups still count from
        # the first upsert batch, so the empty pairs must contribute
        # no snapshot or the index drifts past the ±1 re-establishment
        # and the mode fails closed on sound data
        server = self.opening_server(variant="0", pre_empty_pairs=2)
        expected, _, _ = om_expected_bodies(OM_REF_STAMP)
        status, body, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        self.assertEqual(raw, canonical(expected) + b"\n")

    def test_opening_mode_pre_open_empty_pairs_keep_the_fault(self):
        # skipping empty pairs must not weaken the correspondence: the
        # upserts in no price-bearing snapshot still fail closed
        server = self.opening_server(variant="none", pre_empty_pairs=2)
        status, _, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)
        self.assertIn(b"chain-pair correspondence failed", raw)

    # -- the window -------------------------------------------------------

    def test_opening_mode_window_boundaries(self):
        # the half-open window over the reference group's recorded KST
        # time-of-day: 09:00:00 in, 09:30:00 out. Outside it the core
        # last-record-wins assembly is served with null ma20_tag
        for stamp, mode in (("2026-11-10T08:59:59+09:00", "core"),
                            ("2026-11-10T09:00:00+09:00", "opening_ma20"),
                            ("2026-11-10T09:29:59+09:00", "opening_ma20"),
                            ("2026-11-10T09:30:00+09:00", "core")):
            server = self.opening_server(ref_stamp=stamp)
            status, body, _, _ = server.get_json("/mobile/market-view")
            self.assertEqual(status, 200, stamp)
            self.assertEqual(body["mode"], mode, stamp)
            if mode == "opening_ma20":
                # the reference group is the last CONFIRMED group: the
                # unsealed 10:05 group never takes over
                self.assertEqual(self.symbols(body, "rising_top10"),
                                 ["000660", "009150", "012330", "005930",
                                  "015760"], stamp)
                self.assertEqual(self.symbols(body, "falling_top10"),
                                 ["011060", "008480", "006660"], stamp)
                stamps = {i["observed_at"] for i in body["rising_top10"]
                          + body["falling_top10"]}
                self.assertEqual(stamps, {stamp, OM_T1})
            else:
                self.assertEqual(self.symbols(body, "rising_top10"),
                                 ["005930", "006660", "012330", "015760",
                                  "002420", "005490"], stamp)
                self.assertEqual(self.symbols(body, "falling_top10"),
                                 ["000660", "011060", "009150", "006660",
                                  "008480", "001440", "003490"], stamp)
                self.assertTrue(all(i["ma20_tag"] is None for i
                                    in body["rising_top10"]
                                    + body["falling_top10"]), stamp)

    def test_opening_mode_stamp_zone_is_converted(self):
        # the window predicate converts the recorded stamp to KST:
        # 00:20+00:00 is 09:20 KST — inside the window
        server = self.opening_server(ref_stamp="2026-11-10T00:20:00+00:00")
        status, body, _, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body["mode"], "opening_ma20")
        self.assertEqual(self.symbols(body, "falling_top10"),
                         ["011060", "008480", "006660"])

    def test_opening_mode_stamp_shape_violation_is_data_fault(self):
        # the reference group's stamp is not the event schema's offset
        # shape: the predicate never guesses, it fails closed
        server = self.opening_server(ref_stamp="2026-11-10T09:10:00")
        status, _, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 500)
        self.assertIn(b"data_fault", raw)


class MarketViewFactSuite(unittest.TestCase):
    """GET /mobile/market-view (README §3.7): the events_contract
    "top10-v1" dual path. The history is the display translation of the
    Core-confirmed TOP10 facts recorded in the journal — every change
    record value is the fact's own recorded value, no classification,
    no judgment — while the top10 fold, the opening mode and every
    other field keep the candidate-event projection unchanged. The
    eligibility rule is the fact-path equivalent of the legacy
    unsealed-tail rule: a fact serves only when the run is sealed or a
    different-stamp journal event follows it."""

    def setUp(self):
        self.box = build_fact_sandbox()
        self.addCleanup(self.box.cleanup)
        self.server = ServerProc(self.box, with_delivery=False)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        self.server.assert_gone()

    def _reap(self, server):
        code, _ = server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        server.assert_gone()

    def fact_server(self, **kwargs):
        box = build_fact_sandbox(**kwargs)
        self.addCleanup(box.cleanup)
        server = ServerProc(box, with_delivery=False)
        self.addCleanup(self._reap, server)
        return box, server

    def seal_winner(self, box):
        """Plant the recorder's finish() marker — the §3.7 run seal; the
        server re-reads the recorded files every request."""
        box.write(os.path.join(box.runs, TF_WINNER,
                               "input.hcj.jsonl.committed"),
                  tf_committed_marker(TF_WINNER))

    # -- full-response contract --------------------------------------------

    def test_fact_path_full_scenario_byte_canonical(self):
        # unsealed: group 2's boundary facts serve (group 3's next-stamp
        # batch follows them), group 3's flush facts do not; top10 is
        # the final live candidate state; status counts every event
        # including the facts; the whole body is canonical bytes
        status, body, raw, headers = self.server.get_json(
            "/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, TF_EXPECTED)
        self.assertEqual(raw, canonical(TF_EXPECTED) + b"\n")
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")
        # the contract's mechanical size bound (README §3.7)
        self.assertLessEqual(len(raw), 65536)

    def test_fact_path_flush_facts_need_the_seal(self):
        # group 3's kSessionEnd flush facts are followed only by the
        # same-stamp SESSION_ENDED: unsealed they stay out of history
        # (the seal is their only confirmation), sealed they enter —
        # the same file, no restart, the server re-reads per request
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(body["history"], TF_HISTORY_G2)
        self.assertTrue(all(c["observed_at"] != TF_T3
                            for c in body["history"]))
        self.seal_winner(self.box)
        status, body, raw, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, TF_EXPECTED_SEALED)
        self.assertEqual(raw, canonical(TF_EXPECTED_SEALED) + b"\n")
        self.assertLessEqual(len(raw), 65536)

    def test_fact_path_consecutive_requests_identical(self):
        # determinism: two consecutive requests serve identical bytes
        raw1 = self.server.get("/mobile/market-view")[1]
        raw2 = self.server.get("/mobile/market-view")[1]
        self.assertEqual(raw1, raw2)

    # -- the translation ---------------------------------------------------

    def test_fact_path_translate_fields_and_order(self):
        # journal-order translation: the fact block was recorded in a
        # non-symbol order and history keeps exactly that order; every
        # record is the nine-field change whitelist with no event_type
        # key; CANDIDATE_EXITED — the legacy-only display type — never
        # occurs in the fact path
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        history = body["history"]
        self.assertEqual([c["event_id"] for c in history],
                         [f["event_id"] for f in TF_G2_FACTS])
        for item in history:
            self.assertEqual(sorted(item),
                             ["change_type", "data_quality", "direction",
                              "event_id", "name", "observed_at",
                              "prev_rank", "rank", "symbol"])
            self.assertNotIn("event_type", item)
            self.assertIn(item["change_type"], serve.MARKET_CHANGE_TYPES)
        self.assertEqual({c["change_type"] for c in history},
                         {"RANK_CHANGED", "TOP10_ENTERED", "TOP10_EXITED"})
        by_symbol = {c["symbol"]: c for c in history}
        # rank null: the candidate-disappearance TOP10_EXITED records no
        # rank — honest absence, never 0
        disappeared = by_symbol["000810"]
        self.assertEqual(disappeared["change_type"], "TOP10_EXITED")
        self.assertIsNone(disappeared["rank"])
        self.assertEqual(disappeared["prev_rank"], 2)
        # prev_rank null: the brand-new DOWN member records no previous
        entered = by_symbol["000720"]
        self.assertEqual(entered["change_type"], "TOP10_ENTERED")
        self.assertIsNone(entered["prev_rank"])
        self.assertEqual(entered["rank"], 1)
        self.assertEqual(entered["direction"], "DOWN")
        # name: the fact's own recorded name, the ka10027 dictionary
        # fallback, and honest null when neither names the symbol
        self.assertEqual(by_symbol["005930"]["name"], "삼성전자")  # fact
        self.assertEqual(by_symbol["011060"]["name"], "SK텔레콤")  # fact
        self.assertEqual(by_symbol["006660"]["name"], "LG전자")  # dict
        self.assertIsNone(by_symbol["015760"]["name"])
        self.assertIsNone(by_symbol["000660"]["name"])
        self.assertIsNone(by_symbol["000810"]["name"])
        self.assertIsNone(by_symbol["000720"]["name"])
        # the record's evidence is the fact itself: the drilldown id is
        # the fact's own event_id
        self.assertEqual(by_symbol["006660"]["event_id"],
                         TF_G2_FACTS[0]["event_id"])

    def test_fact_path_top10_lists_come_from_the_candidate_fold(self):
        # only the history source changes: the top10 lists are still
        # the candidate-event last-record-wins fold of the final live
        # state, event_type included verbatim
        _, body, _, _ = self.server.get_json("/mobile/market-view")
        self.assertEqual([i["symbol"] for i in body["rising_top10"]],
                         ["005930", "006660", "008480", "007070", "009150",
                          "010060", "015760", "011140", "011780", "012330"])
        self.assertEqual([i["symbol"] for i in body["falling_top10"]],
                         ["000720", "000660"])
        for item in body["rising_top10"] + body["falling_top10"]:
            self.assertIsNone(item["ma20_tag"])
            self.assertIn(item["event_type"],
                          ("CANDIDATE_ENTERED", "CANDIDATE_UPDATED"))

    # -- the eligibility rule ----------------------------------------------

    def test_fact_path_boundary_facts_without_later_stamp_excluded(self):
        # the rule's exclusion case: boundary facts followed only by a
        # same-stamp merged batch (no different-stamp event after them)
        # are not eligible unsealed — the seal alone confirms them
        box = Sandbox()
        self.addCleanup(box.cleanup)
        run_dir = box.session_dir("fact-2026-11-12-edge")
        stamp1 = "2026-11-12T10:00:01+09:00"
        stamp2 = "2026-11-12T10:05:01+09:00"
        box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
            {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
            {"kind": "config", "raw": {"environment": "demo",
                                       "events_contract": "top10-v1",
                                       "run_id": "fact-2026-11-12-edge",
                                       "session_date": TF_SESSION_DATE},
             "seq": 2},
            rest_resp_record(3, ka10027_body([("005930", "삼성전자",
                                               75000)]))))
        facts = [
            tf_fact(b"e-f01", stamp2, "RANK_CHANGED", "005930", "UP",
                    rank=2, previous_rank=1),
            # a fact recording no direction projects the honest null
            tf_fact(b"e-f02", stamp2, "RANK_CHANGED", "006660",
                    rank=1, previous_rank=2),
        ]
        events = [
            tf_candidate(b"e-up01", stamp1, "CANDIDATE_ENTERED",
                         "005930", "UP", 1),
            tf_candidate(b"e-up02", stamp1, "CANDIDATE_ENTERED",
                         "006660", "UP", 2),
            tf_candidate(b"e-up01b", stamp2, "CANDIDATE_UPDATED",
                         "005930", "UP", 2),
            tf_candidate(b"e-up02b", stamp2, "CANDIDATE_UPDATED",
                         "006660", "UP", 1),
        ] + facts + [
            # a same-stamp merged batch after the facts: the only events
            # that follow them carry the facts' own stamp
            tf_candidate(b"e-up01c", stamp2, "CANDIDATE_UPDATED",
                         "005930", "UP", 1),
            tf_candidate(b"e-up02c", stamp2, "CANDIDATE_UPDATED",
                         "006660", "UP", 2),
        ]
        box.write(os.path.join(run_dir, "events.hcj.jsonl"),
                  jsonl(*events))
        server = ServerProc(box, with_delivery=False)
        self.addCleanup(self._reap, server)
        status, body, _, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body["history"], [])  # unsealed: excluded
        box.write(os.path.join(run_dir, "input.hcj.jsonl.committed"),
                  tf_committed_marker("fact-2026-11-12-edge"))
        status, body, _, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        expected = [
            tf_change(facts[0], {"005930": "삼성전자"}),
            tf_change(facts[1], {"005930": "삼성전자"}),
        ]
        self.assertEqual(body["history"], expected)
        self.assertIsNone(body["history"][1]["direction"])

    def test_fact_path_ring_keeps_last_100(self):
        # a facts-only run (no candidates — facts never open a group):
        # 120 eligible facts, the ring keeps exactly the last 100, the
        # oldest twenty (blocks one and two) are dropped
        box = Sandbox()
        self.addCleanup(box.cleanup)
        run_dir = box.session_dir("fact-2026-11-12-ring")
        box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
            {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
            {"kind": "config", "raw": {"environment": "demo",
                                       "events_contract": "top10-v1",
                                       "run_id": "fact-2026-11-12-ring",
                                       "session_date": TF_SESSION_DATE},
             "seq": 2}))
        box.write(os.path.join(run_dir, "events.hcj.jsonl"),
                  jsonl(*tf_ring_events()))
        server = ServerProc(box, with_delivery=False)
        self.addCleanup(self._reap, server)
        status, body, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(len(body["history"]), 100)
        first, last = body["history"][0], body["history"][-1]
        self.assertEqual(first["observed_at"],
                         "2026-11-12T11:02:01+09:00")
        self.assertEqual((first["rank"], first["prev_rank"]), (1, 2))
        self.assertEqual(last["observed_at"],
                         "2026-11-12T11:11:01+09:00")
        self.assertEqual((last["rank"], last["prev_rank"]), (10, 11))
        self.assertEqual({c["change_type"] for c in body["history"]},
                         {"RANK_CHANGED"})
        self.assertEqual(body["rising_top10"], [])
        self.assertEqual(body["falling_top10"], [])
        self.assertEqual(body["mode"], "core")
        self.assertEqual(body["status"]["by_data_quality"],
                         {"INCOMPLETE": 1, "OBSERVING": 120})
        self.assertLessEqual(len(raw), 65536)

    # -- the discriminator -------------------------------------------------

    def test_config_without_the_marker_is_the_legacy_path(self):
        # the absence branch: the same recorded bytes with no
        # events_contract key project the legacy state-comparison
        # history — the facts are ordinary non-candidate events there
        # (counted in status, never folded into groups or history)
        box, server = self.fact_server(events_contract=None)
        status, body, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        expected = dict(TF_EXPECTED, history=TF_LEGACY_HISTORY_G2)
        self.assertEqual(body, expected)
        self.assertEqual(raw, canonical(expected) + b"\n")
        # sealed, the legacy derivation confirms group 3 on the same
        # events — the facts still never enter history
        self.seal_winner(box)
        status, body, _, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body["history"],
                         TF_LEGACY_HISTORY_G2 + TF_LEGACY_HISTORY_G3)

    def test_unknown_events_contract_value_is_data_fault(self):
        # fail-closed discriminator: a recorded contract this projection
        # cannot consume is never guessed into either path — a future
        # version string or a non-string value both fault
        for value in ("top10-v2", 17):
            _, server = self.fact_server(events_contract=value)
            status, _, raw, _ = server.get_json("/mobile/market-view")
            self.assertEqual(status, 500, value)
            self.assertIn(b"data_fault", raw, value)

    def test_fact_path_shape_violations_are_data_fault(self):
        # the fact fold's dependent recorded shape: a rank below 1 and
        # an unknown TOP10_* event type are corruption, never a skip
        for label, bad in (
                ("rank", tf_fact(b"bad-rank", TF_T3, "RANK_CHANGED",
                                 "005930", "UP", rank=0, previous_rank=1)),
                ("type", tf_fact(b"bad-type", TF_T3, "TOP10_PROMOTED",
                                 "005930", "UP", rank=1))):
            with open(os.path.join(self.box.runs, TF_WINNER,
                                   "events.hcj.jsonl"), "ab") as f:
                f.write(canonical(bad) + b"\n")
            status, _, raw, _ = self.server.get_json("/mobile/market-view")
            self.assertEqual(status, 500, label)
            self.assertIn(b"data_fault", raw, label)
            # restore the fixture bytes for the next case
            self.box.write(
                os.path.join(self.box.runs, TF_WINNER, "events.hcj.jsonl"),
                jsonl(*tf_winner_events()))

    # -- the opening mode is orthogonal to the history path ---------------

    def test_fact_path_opening_mode_unchanged(self):
        # a top10-v1 run in the opening window: the reference group is
        # still the last CONFIRMED candidate group, the top10 lists
        # still come from the recorded chain-pair prices against the
        # close sums — and history is the fact translation
        box = Sandbox()
        self.addCleanup(box.cleanup)
        run_dir = box.session_dir(OM_WINNER)
        box.write(os.path.join(run_dir, "input.hcj.jsonl"), jsonl(
            {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
            {"kind": "config", "raw": {"environment": "demo",
                                       "events_contract": "top10-v1",
                                       "run_id": OM_WINNER,
                                       "session_date": OM_SESSION_DATE},
             "seq": 2},
            *om_winner_input("0")))
        facts = [
            # group 2's boundary facts: the disappearance (rank null),
            # and the two TOP10 entries the correspondence check is
            # about
            tf_fact(b"om-f01", OM_REF_STAMP, "TOP10_EXITED", "017960",
                    "DOWN", previous_rank=5, session_id=OM_SESSION_DATE),
            tf_fact(b"om-f02", OM_REF_STAMP, "TOP10_ENTERED", "011060",
                    "DOWN", rank=3, session_id=OM_SESSION_DATE),
            tf_fact(b"om-f03", OM_REF_STAMP, "TOP10_ENTERED", "006660",
                    "DOWN", rank=7, session_id=OM_SESSION_DATE),
        ]
        box.write(os.path.join(run_dir, "events.hcj.jsonl"), jsonl(
            *(OM_G1 + [om_g2_017960x(OM_REF_STAMP),
                       om_g2_011060(OM_REF_STAMP),
                       om_g2_006660(OM_REF_STAMP)]
              + facts + [OM_G3_005930, OM_TAIL])))
        server = ServerProc(box, with_delivery=False)
        self.addCleanup(self._reap, server)
        expected, _, _ = om_expected_bodies(OM_REF_STAMP)
        expected = dict(expected,
                        history=[tf_change(f, OM_NAMES) for f in facts],
                        status={"by_data_quality": {"INCOMPLETE": 1,
                                                    "OBSERVING": 19}})
        status, body, raw, _ = server.get_json("/mobile/market-view")
        self.assertEqual(status, 200)
        self.assertEqual(body, expected)
        self.assertEqual(raw, canonical(expected) + b"\n")
        self.assertEqual(body["mode"], "opening_ma20")


class MarketFoldSuite(unittest.TestCase):
    """Unit contract of the §3.7 market fold: fold_market_projection
    (the pure function over one input.hcj.jsonl's recorded bytes — the
    ka10027 name dictionary, the ka10027 chain-pair price snapshots and
    the ka10081 twenty-close sums) and the Projector's (path, size,
    mtime_ns) memoization. These are function- and cache-behavior facts
    the endpoint bytes cannot observe directly (a rescan is
    byte-identical to a hit); endpoint projection stays black-box in
    MarketViewSuite and MarketViewOpeningSuite."""

    def setUp(self):
        self.box = Sandbox()
        self.addCleanup(self.box.cleanup)
        self.runs = self.box.runs

    def write_input(self, *records, torn=b""):
        run_dir = self.box.session_dir("market-2026-11-09-n")
        self.box.write(os.path.join(run_dir, "input.hcj.jsonl"),
                       jsonl(*records) + torn)
        return os.path.join(run_dir, "input.hcj.jsonl")

    # -- the name dictionary -----------------------------------------------

    def test_fold_latest_wins_and_skips(self):
        path = self.write_input(
            {"kind": "calendar", "raw": {"market": "KRX"}, "seq": 1},
            rest_resp_record(2, MV_ERROR_BODY, status=429),
            rest_resp_record(3, ka10027_body([("005930", "삼성전자", 75000),
                                              ("006660", "구형이름", 45000)])),
            rest_resp_record(4, MV_KA10080_BODY, api_id="ka10080"),
            rest_resp_record(5, ka10027_body([("006660", "LG전자", 45000)]),
                             page=2),
            {"kind": "ws_frame", "raw": {"price": 1}, "seq": 6},
            # a non-object body: recorded verbatim, no ranking to fold
            rest_resp_record(7, {"body": "not-a-ranking"}),
            torn=canonical(rest_resp_record(
                8, ka10027_body([("000660", "SK하이닉스", 120000)])))
                [:40])  # torn tail: not committed, never folded
        # no falling leg ever completes: zero snapshots, no bars
        self.assertEqual(serve.fold_market_projection(path, "2026-11-09"),
                         ({"005930": "삼성전자", "006660": "LG전자"},
                          [], {}))

    def test_fold_absent_and_empty_input(self):
        self.assertEqual(serve.fold_market_projection(
            os.path.join(self.runs, "no-such-run", "input.hcj.jsonl"),
            "2026-11-09"), ({}, [], {}))
        path = self.write_input()
        self.assertEqual(serve.fold_market_projection(path, "2026-11-09"),
                         ({}, [], {}))

    def test_fold_non_json_body_contributes_nothing(self):
        # error bodies preserved verbatim (text, empty) are legitimately
        # recorded and carry no ranking: absence, never a fault
        raw_body = {"kind": "rest_resp",
                    "raw": {"api_id": "ka10027",
                            "body_hex": b"Bad Gateway".hex(),
                            "cont_yn": "", "next_key": "", "page": 1,
                            "query": dict(MV_KA10027_QUERY),
                            "status": 502}, "seq": 4}
        path = self.write_input(
            rest_resp_record(2, "plain 429 text", status=429),
            rest_resp_record(3, {"return_code": 5}, status=429),
            raw_body)
        self.assertEqual(serve.fold_market_projection(path, "2026-11-09"),
                         ({}, [], {}))

    def test_fold_malformed_committed_line_is_data_fault(self):
        path = self.write_input(
            rest_resp_record(2, ka10027_body([("005930", "삼성전자", 75000)])))
        with open(path, "ab") as f:
            f.write(b"{not json}\n")
        with self.assertRaises(serve.DataFault):
            serve.fold_market_projection(path, "2026-11-09")

    def test_fold_envelope_violations_are_data_fault(self):
        bad_raw = rest_resp_record(2, ka10027_body([("005930", "삼성전자",
                                                     75000)]))
        bad_raw["raw"] = "not-an-object"
        bad_api = rest_resp_record(2, ka10027_body([("005930", "삼성전자",
                                                     75000)]))
        bad_api["raw"]["api_id"] = 10027
        bad_hex = rest_resp_record(2, ka10027_body([("005930", "삼성전자",
                                                     75000)]))
        bad_hex["raw"]["body_hex"] = "zz"
        no_hex = rest_resp_record(2, ka10027_body([("005930", "삼성전자",
                                                    75000)]))
        del no_hex["raw"]["body_hex"]
        for label, record in (("raw", bad_raw), ("api_id", bad_api),
                              ("hex", bad_hex), ("no body_hex", no_hex)):
            path = self.write_input(record)
            with self.assertRaises(serve.DataFault, msg=label):
                serve.fold_market_projection(path, "2026-11-09")

    def test_fold_ka10027_row_violation_is_data_fault(self):
        for label, rows in (
                ("row not object", ["005930"]),
                ("no stk_nm", [{"cur_prc": "+1000", "stk_cd": "005930"}]),
                ("no stk_cd", [{"cur_prc": "+1000", "stk_nm": "삼성전자"}]),
                ("no cur_prc", [{"stk_cd": "005930", "stk_nm": "삼성전자"}]),
                ("unsigned cur_prc",
                 [{"cur_prc": "1000", "stk_cd": "005930",
                   "stk_nm": "삼성전자"}]),
                ("non-string cur_prc",
                 [{"cur_prc": 1000, "stk_cd": "005930",
                   "stk_nm": "삼성전자"}]),
                ("non-string", [{"cur_prc": "+1000", "stk_cd": 59530,
                                 "stk_nm": "삼성전자"}])):
            path = self.write_input(rest_resp_record(2, {
                "pred_pre_flu_rt_upper": rows,
                "return_code": 0, "return_msg": label}))
            with self.assertRaises(serve.DataFault, msg=label):
                serve.fold_market_projection(path, "2026-11-09")

    def test_fold_ka10027_query_violation_is_data_fault(self):
        for label, kwargs in (("sort_tp", {"sort_tp": "2"}),
                              ("page", {"page": 0}),
                              ("cont_yn", {"cont_yn": 1})):
            path = self.write_input(
                rest_resp_record(2, ka10027_body(om_rows(("005930", 75000))),
                                 **kwargs))
            with self.assertRaises(serve.DataFault, msg=label):
                serve.fold_market_projection(path, "2026-11-09")

    # -- the chain-pair snapshots -------------------------------------------

    def test_fold_chain_pairs_form_snapshots(self):
        # a rising leg over two pages and a falling leg over two pages
        # merge into ONE snapshot (union; a same-symbol collision is
        # won by the falling row); the next completed pair appends the
        # next snapshot
        path = self.write_input(
            om_chain(2, "1", om_rows(("005930", 75000),
                                     ("000660", 120000)), cont_yn="Y"),
            om_chain(3, "1", om_rows(("009150", 30000)), page=2),
            om_chain(4, "3", om_rows(("005930", 74000)), cont_yn="Y"),
            om_chain(5, "3", om_rows(("011060", 17000)), page=2),
            om_chain(6, "1", om_rows(("012330", 50000))),
            om_chain(7, "3", om_rows(("012330", 49000))))
        _, snapshots, _ = serve.fold_market_projection(path, "2026-11-10")
        self.assertEqual(snapshots, [
            {"005930": 74000, "000660": 120000, "009150": 30000,
             "011060": 17000},
            {"012330": 49000}])

    def test_fold_interrupted_chain_is_dropped(self):
        # a page-1 restart abandons the chain being read: its prices
        # never enter a snapshot — only the restarted, completed chain
        # pairs with the falling leg
        path = self.write_input(
            om_chain(2, "1", om_rows(("005930", 75000)), cont_yn="Y"),
            om_chain(3, "1", om_rows(("000660", 120000)), cont_yn="Y"),
            om_chain(4, "1", om_rows(("012330", 50000)), page=2),
            om_chain(5, "3", om_rows(("011060", 17000))))
        _, snapshots, _ = serve.fold_market_projection(path, "2026-11-10")
        self.assertEqual(snapshots,
                         [{"000660": 120000, "012330": 50000,
                           "011060": 17000}])

    def test_fold_falling_chain_without_rising_is_own_snapshot(self):
        # a completed falling leg with no pending rising leg is a
        # snapshot of its own — consecutive falling legs are two
        # snapshots
        path = self.write_input(
            om_chain(2, "3", om_rows(("011060", 17000))),
            om_chain(3, "3", om_rows(("008480", 20000))))
        _, snapshots, _ = serve.fold_market_projection(path, "2026-11-10")
        self.assertEqual(snapshots, [{"011060": 17000},
                                     {"008480": 20000}])

    # -- the ka10081 close sums ---------------------------------------------

    def test_fold_ka10081_sums_completed_closes(self):
        # the session's in-progress bar (dt == session_date) is never
        # summed; nineteen completed days make no twenty-close sum
        path = self.write_input(
            ka10081_record(2, "005930", 70000),
            ka10081_record(3, "005490", 10000, completed=19))
        _, _, ma20 = serve.fold_market_projection(path, "2026-11-10")
        self.assertEqual(ma20, {"005930": 1400000})

    def test_fold_ka10081_caps_twenty_and_dedups_days(self):
        # a twenty-first completed day and a repeated dt are both
        # skipped: the sum is exactly the first twenty distinct days
        rows = [ka10081_row("20261110", 88888)]  # the in-progress bar
        dts = om_dts(20)
        rows += [ka10081_row(dt, 1000) for dt in dts]
        rows.append(ka10081_row(dts[0], 9999))      # the same day twice
        rows.append(ka10081_row("20261012", 9999))  # a 21st older day
        record = rest_resp_record(
            2, {"return_code": 0, "return_msg": "정상처리 되었습니다.",
                "stk_dt_pole_chart_qry": rows},
            api_id="ka10081",
            query={"base_dt": "", "stk_cd": "005930", "tick_kind": "2"})
        path = self.write_input(record)
        _, _, ma20 = serve.fold_market_projection(path, "2026-11-10")
        self.assertEqual(ma20, {"005930": 20000})

    def test_fold_ka10081_violation_is_data_fault(self):
        for label, row, query in (
                ("dt not YYYYMMDD",
                 {"cur_prc": "1000", "dt": "2026-1-09"},
                 {"stk_cd": "005930"}),
                ("signed cur_prc",
                 {"cur_prc": "+1000", "dt": "20261109"},
                 {"stk_cd": "005930"}),
                ("no query stk_cd",
                 {"cur_prc": "1000", "dt": "20261109"}, {})):
            path = self.write_input(rest_resp_record(
                2, {"return_code": 0, "return_msg": label,
                    "stk_dt_pole_chart_qry": [row]},
                api_id="ka10081", query=query))
            with self.assertRaises(serve.DataFault, msg=label):
                serve.fold_market_projection(path, "2026-11-10")

    def test_fold_session_date_shape_is_validated(self):
        # the fold validates the selected run's own recorded session
        # date before any row is folded
        path = self.write_input(
            ka10081_record(2, "005930", 70000))
        for bad in ("2026-11-9", "20261110", 20261110):
            with self.assertRaises(serve.DataFault):
                serve.fold_market_projection(path, bad)

    # -- memoization -------------------------------------------------------

    def test_fold_cache_hit_and_invalidation(self):
        # same (path, size, mtime_ns) -> no rescan; a committed append
        # changes the stat -> rescan serves the new recorded name
        path = self.write_input(
            om_chain(2, "1", om_rows(("005930", 75000))))
        projector = serve.Projector(self.runs, self.box.ledger)
        calls = []
        real_fold = serve.fold_market_projection

        def counting_fold(p, session_date):
            calls.append((p, session_date))
            return real_fold(p, session_date)
        serve.fold_market_projection = counting_fold
        self.addCleanup(setattr, serve, "fold_market_projection",
                        real_fold)
        first = projector._market_projection(path, "2026-11-09")
        self.assertEqual(first, ({"005930": "삼성전자"}, [], {}))
        self.assertEqual(len(calls), 1)
        # identical stat: served from the cache, fold not re-entered
        self.assertEqual(projector._market_projection(path, "2026-11-09"),
                         first)
        self.assertEqual(len(calls), 1)
        # a committed append changes size: rescan, new name served
        with open(path, "ab") as f:
            f.write(canonical(om_chain(3, "1",
                                       om_rows(("006660", 45000)))) + b"\n")
        second = projector._market_projection(path, "2026-11-09")
        self.assertEqual(second[0], {"005930": "삼성전자",
                                     "006660": "LG전자"})
        self.assertEqual(len(calls), 2)

    def test_fold_cache_not_published_for_absent_file(self):
        # a vanished input folds to {} and publishes nothing: a later
        # re-created file must be scanned, not served stale
        path = self.write_input(
            om_chain(2, "1", om_rows(("005930", 75000))))
        projector = serve.Projector(self.runs, self.box.ledger)
        self.assertEqual(projector._market_projection(path, "2026-11-09"),
                         ({"005930": "삼성전자"}, [], {}))
        os.remove(path)
        self.assertEqual(projector._market_projection(path, "2026-11-09"),
                         ({}, [], {}))
        self.write_input(om_chain(2, "1", om_rows(("006660", 45000))))
        self.assertEqual(
            projector._market_projection(path, "2026-11-09")[0],
            {"006660": "LG전자"})


class TornLedgerSuite(unittest.TestCase):
    """A ledger being appended concurrently: committed records are
    served, the non-LF-terminated tail is skipped, and delivery
    without --delivery is reported unconfigured."""

    def setUp(self):
        self.box = Sandbox()
        self.addCleanup(self.box.cleanup)
        committed = jsonl(EV1, EV2)
        torn = canonical(EV3)[:20]  # a torn record: no LF, not committed
        self.box.write(self.box.ledger, committed + torn)
        self.box.write_session_files("torn-session", with_session_end=False,
                                     with_marker=False)
        self.server = ServerProc(self.box, with_delivery=False)
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0)
        self.server.assert_gone()

    def test_torn_tail_is_not_served_and_delivery_unconfigured(self):
        status, body, _, _ = self.server.get_json("/events")
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 2)
        self.assertEqual([e["event_id"] for e in body["events"]],
                         [EV1["event_id"], EV2["event_id"]])
        self.assertNotIn(EV3["event_id"], body["delivery"])
        self.assertEqual(body["delivery"], {})
        status, body, _, _ = self.server.get_json(
            "/events/" + EV3["event_id"])
        self.assertEqual(status, 404)  # the torn record is not committed
        status, body, _, _ = self.server.get_json("/status")
        self.assertEqual(body["delivery"],
                         {"by_state": None, "configured": False,
                          "devices": None, "pairs": None,
                          "present": None})
        self.assertEqual(body["events"]["count"], 2)


class StartupFailClosed(unittest.TestCase):
    """Refusals at startup: bad configuration never becomes a running
    server, and never a clean exit."""

    def run_serve(self, args):
        return subprocess.run([PY, SERVE] + args, capture_output=True,
                              timeout=15)

    def test_missing_runs_directory_refused(self):
        box = Sandbox()
        try:
            done = self.run_serve(["--runs", os.path.join(box.root, "nope"),
                                   "--ledger", box.ledger, "--port", "0"])
            self.assertNotEqual(done.returncode, 0)
            self.assertNotIn(b"SERVE", done.stdout)
        finally:
            box.cleanup()

    def test_port_out_of_range_refused(self):
        box = Sandbox()
        try:
            done = self.run_serve(["--runs", box.runs, "--ledger",
                                   box.ledger, "--port", "70000"])
            self.assertEqual(done.returncode, 2)
            self.assertNotIn(b"SERVE", done.stdout)
        finally:
            box.cleanup()

    def test_bind_refuses_multicast_broadcast_and_non_ipv4(self):
        # a bad --bind value dies on the argparse usage-error path
        # (exit 2, stderr names --bind) before any socket exists
        for value in ("224.0.0.1", "239.255.255.255",   # multicast 224/4
                      "255.255.255.255",                # broadcast
                      "240.0.0.1",                      # reserved 240/4
                      "0.0.0.1",                        # 0/8 beyond 0.0.0.0
                      "not-an-ip", "1.2.3", "999.0.0.1",
                      "::1"):
            box = Sandbox()
            try:
                done = self.run_serve(["--runs", box.runs, "--ledger",
                                       box.ledger, "--port", "0",
                                       "--bind", value])
                self.assertEqual(done.returncode, 2, value)
                self.assertIn(b"usage:", done.stderr, value)
                self.assertIn(b"error: --bind", done.stderr, value)
                self.assertNotIn(b"SERVE", done.stdout)
            finally:
                box.cleanup()

    def test_bind_zero_address_accepted_at_argument_level(self):
        # 0.0.0.0 passes --bind validation: the run proceeds past
        # argument parsing and dies later on the recorded --runs check
        # ("--runs is not an existing directory", not a bind error).
        # Asserted without opening any socket.
        box = Sandbox()
        try:
            done = self.run_serve(["--runs", os.path.join(box.root, "nope"),
                                   "--ledger", box.ledger, "--port", "0",
                                   "--bind", "0.0.0.0"])
            self.assertEqual(done.returncode, 2)
            self.assertNotIn(b"SERVE", done.stdout)
            stderr = done.stderr.decode("utf-8", "replace")
            self.assertIn("--runs is not an existing directory", stderr)
            self.assertNotIn("error: --bind", stderr)
        finally:
            box.cleanup()

    def test_missing_required_arguments_refused(self):
        box = Sandbox()
        try:
            done = self.run_serve(["--runs", box.runs, "--port", "0"])
            self.assertEqual(done.returncode, 2)
        finally:
            box.cleanup()


class BindAddressSuite(unittest.TestCase):
    """--bind with a concrete unicast address (README §1/§5): the SERVE
    line names the bound address, the socket really listens on it, and
    SIGTERM still ends the server cleanly with no residue."""

    def setUp(self):
        self.box = Sandbox()
        self.addCleanup(self.box.cleanup)
        self.server = ServerProc(self.box, bind="127.0.0.2")
        self.addCleanup(self.reap_server)

    def reap_server(self):
        code, _ = self.server.stop()
        self.assertEqual(code, 0, "serve.py did not exit 0 on SIGTERM")
        self.server.assert_gone()

    def test_serve_line_and_listener_follow_bind_127_0_0_2(self):
        self.assertEqual(self.server.bind, "127.0.0.2")
        self.assertGreater(self.server.port, 0)
        self.assertLess(self.server.port, 65536)
        # a loopback GET through 127.0.0.2 proves the socket is bound
        # to the requested address, not merely announced
        status, body, raw, headers = self.server.get_json("/status")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"],
                         "application/json; charset=utf-8")
        self.assertTrue(raw.endswith(b"\n"))
        self.assertEqual(body["sessions"]["count"], 0)


if __name__ == "__main__":
    unittest.main()
