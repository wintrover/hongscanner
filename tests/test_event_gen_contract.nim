## event generator contract tests (REPLAY_CONTRACT §13, PR-4): the single
## judgment function step(state, record) -> (state', events) and its
## end-of-stream judgment finish(), over the committed synthetic fixtures
## (fixtures/events/gen_session.hcj.jsonl,
## fixtures/events/gen_incomplete.hcj.jsonl).
##
## Covered: the x-event-id-rule over known tuples (the id is sha256 over
## the canonical serialization of the id tuple, including the input record
## seq, which is never emitted), the judgment's determinism (same fold
## twice -> identical bytes; value semantics of the state), the derived
## observed_at (record content, never a wall clock), the record-first
## death/restart recovery (a prefix fold is a byte-prefix of the full
## fold; resuming the recorded stream from the prefix state reproduces
## exactly the same events), the candidate transition rules (ENTERED /
## UPDATED rank change / EXITED, the declared-vendor-scope evidence, the
## one-judgment-per-tuple dedup), the TOP10 observation-group rules
## (top10-transition-v1: pairs under one observation stamp form a group;
## a new stamp confirms the pending group — the first group is the
## baseline, ENTERED/EXITED/RANK_CHANGED compare the confirmed tail with
## the pending tail per direction, the facts precede the new group's
## candidate facts, the session_end seal flushes the last group before
## SESSION_ENDED, and an unsealed stream never flushes), the
## no-verification/no-delivery immutability of every generated fact, and
## the verify byte comparison of the events artifact (MATCH with the
## replayed file; tampered or missing file is a MISMATCH, never a pass).
##
## Hand-rolled assertions in the repo's contract-suite style; synthetic
## fixtures only: no network, no vendor data, no wall clock.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_event_gen_contract.nim
import std/[os, strutils, tempfiles, options]
import hs/[hcj, digest, records, sub_input, replay, verify, event_gen, binfo]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

# ------------------------------------------------------------------ helpers

const
  eventFields = @["data_quality", "direction", "event_id", "event_type",
                  "evidence_ref", "name", "observed_at", "previous_rank",
                  "rank", "rule_id", "rule_version", "session_id",
                  "severity", "symbol"]
  requiredEventFields = @["data_quality", "event_id", "event_type",
                          "evidence_ref", "observed_at", "rule_id",
                          "rule_version", "session_id", "severity"]
  eventTypes = @["CANDIDATE_ENTERED", "CANDIDATE_UPDATED",
                 "CANDIDATE_EXITED", "TOP10_ENTERED", "TOP10_EXITED",
                 "RANK_CHANGED", "FEED_DISCONNECTED",
                 "DATA_GAP_SUSPECTED", "REST_TRUNCATED",
                 "SUBSCRIPTION_TRUNCATED", "MARKET_STATE_UNKNOWN",
                 "REPLAY_MATCH", "REPLAY_MISMATCH",
                 "SESSION_ENDED", "SESSION_INCOMPLETE", "SESSION_APPROVED"]
  severities = @["INFO", "HIGH", "CRITICAL"]
  dataQualities = @["OBSERVING", "INCOMPLETE", "UNKNOWN"]

proc validateEventLine(line: string): seq[string] =
  ## Structural validation of one generated fact against the committed
  ## event schema (closed field set = the immutability rule: any
  ## verification, delivery or position field is an unknown field).
  var v: HcjValue
  try:
    v = parseLine(line)
  except CatchableError as e:
    return @["not parseable: " & e.msg]
  if canonical(v) != line:
    result.add("line is not canonical HCJ")
  if v.kind != hkObj:
    return @["event: not an object"]
  for p in v.pairs:
    if not eventFields.contains(p.k):
      result.add("event: unknown field: " & p.k)
  for k in requiredEventFields:
    if not v.has(k):
      result.add("event: missing field: " & k)
  if v.has("event_id") and not validSha256Hex(v.get("event_id").asStr):
    result.add("event: event_id is not 64 lowercase hex")
  if v.has("event_type") and not eventTypes.contains(v.get("event_type").asStr):
    result.add("event: event_type is not a contract event type")
  if v.has("observed_at") and not validIso8601Offset(v.get("observed_at").asStr):
    result.add("event: observed_at is not YYYY-MM-DDTHH:MM:SS+HH:MM")
  for k in ["session_id", "rule_id", "evidence_ref"]:
    if v.has(k) and v.get(k).asStr.len == 0:
      result.add("event: " & k & " is empty")
  if v.has("rule_version") and v.get("rule_version").ival < 1:
    result.add("event: rule_version must be >= 1")
  if v.has("symbol") and not validCode(v.get("symbol").asStr):
    result.add("event: symbol is not a 6-digit code")
  if v.has("previous_rank") and v.get("previous_rank").ival < 1:
    result.add("event: previous_rank must be >= 1")
  if v.has("name") and v.get("name").asStr.len == 0:
    result.add("event: name is empty")
  if v.has("severity") and not severities.contains(v.get("severity").asStr):
    result.add("event: severity is not INFO|HIGH|CRITICAL")
  if v.has("data_quality") and
     not dataQualities.contains(v.get("data_quality").asStr):
    result.add("event: data_quality is not OBSERVING|INCOMPLETE|UNKNOWN")

proc lineValue(line: string): HcjValue = parseLine(line)

proc fieldOf(line, key: string): string = lineValue(line).get(key).asStr

proc hasField(line, key: string): bool = lineValue(line).has(key)

proc fieldSeq(lines: seq[string]; key: string): seq[string] =
  for l in lines: result.add(fieldOf(l, key))

proc allCanonical(lines: seq[string]): bool =
  for l in lines:
    if canonical(parseLine(l)) != l: return false
  true

proc allValid(lines: seq[string]): bool =
  for l in lines:
    if validateEventLine(l).len != 0: return false
  true

proc idsDistinct(lines: seq[string]): bool =
  var seen: seq[string]
  for l in lines:
    let id = fieldOf(l, "event_id")
    if id in seen: return false
    seen.add(id)
  true

proc idsUnique(facts: seq[EventFact]): bool =
  var seen: seq[string]
  for f in facts:
    if f.eventId in seen: return false
    seen.add(f.eventId)
  true

proc contentRef(r: Record): string =
  sha256Hex(makeRecordLine(r.seq, r.kind, r.raw))

# ------------------------------------------------------------------ fixtures

let repoRoot = parentDir(parentDir(getAppFilename()))
let sessionPath = repoRoot / "fixtures" / "events" / "gen_session.hcj.jsonl"
let incompletePath = repoRoot / "fixtures" / "events" / "gen_incomplete.hcj.jsonl"

block fixtures:
  check("fixtures: both synthetic fixtures exist",
        fileExists(sessionPath) and fileExists(incompletePath))
  let recs = loadRecords(sessionPath)
  let incRecs = loadRecords(incompletePath)
  check("fixtures: the sealed stream has 13 records and ends with session_end",
        recs.len == 13 and recs[^1].kind == kSessionEnd)
  # Record equality is canonical-line equality: HcjValue has no structural
  # == (case-object comparison), and the replay contract's identity IS the
  # canonical line (contentRef).
  check("fixtures: the incomplete stream is the same prefix without the seal",
        incRecs.len == 12 and
        (block:
           var ok = true
           for i in 0 ..< incRecs.len:
             if contentRef(incRecs[i]) != contentRef(recs[i]): ok = false
           ok))
  check("fixtures: the sealed stream replays to status rsOk",
        runCore(recs).status == rsOk)
  check("fixtures: the unsealed stream is INCOMPLETE, never a pass",
        runCore(incRecs).status == rsIncomplete)

let recs = loadRecords(sessionPath)
let events = eventsOfRecords(recs)

# ------------------------------------------------------- generation & shape

block generationShape:
  check("generation: the sealed session judges exactly 8 facts",
        events.len == 8)
  check("generation: every fact line is canonical HCJ",
        allCanonical(events))
  check("generation: every fact passes the closed-field validation",
        allValid(events))
  check("generation: the event_type sequence is the judgment order",
        fieldSeq(events, "event_type") == @[
          "CANDIDATE_ENTERED", "CANDIDATE_ENTERED", "DATA_GAP_SUSPECTED",
          "DATA_GAP_SUSPECTED", "REST_TRUNCATED", "FEED_DISCONNECTED",
          "MARKET_STATE_UNKNOWN", "SESSION_ENDED"])
  check("generation: the rule_id sequence is per rule",
        fieldSeq(events, "rule_id") == @[
          "candidate-transition-v1", "candidate-transition-v1",
          "gap-suspected-v1", "gap-suspected-v1", "rest-truncated-v1",
          "feed-disconnected-v1", "market-state-unknown-v1",
          "session-close-v1"])
  check("generation: every fact carries rule_version 1",
        (block:
           var ok = true
           for l in events:
             if lineValue(l).get("rule_version").ival != 1: ok = false
           ok))
  check("generation: session_id is the config record's session_date",
        fieldSeq(events, "session_id") ==
        @["2026-11-02", "2026-11-02", "2026-11-02", "2026-11-02",
          "2026-11-02", "2026-11-02", "2026-11-02", "2026-11-02"])
  check("generation: all 8 ids are distinct", idsDistinct(events))
  check("generation: no position field is ever emitted",
        (block:
           var ok = true
           for l in events:
             if hasField(l, "transition_seq") or hasField(l, "seq") or
                hasField(l, "position"): ok = false
           ok))
  check("generation: no verification or delivery field exists on any fact",
        (block:
           var ok = true
           for l in events:
             for k in ["verification_status", "state", "attempts",
                       "device_id", "error_code", "provider_message_id"]:
               if hasField(l, k): ok = false
           ok))

# --------------------------------------------------------- observed_at rules

block observedAt:
  check("observed_at: candidate facts observe the stream's first derived " &
        "timestamp (config midnight), never a clock",
        fieldOf(events[0], "observed_at") ==
        "2026-11-02T00:00:00+09:00" and
        fieldOf(events[1], "observed_at") ==
        "2026-11-02T00:00:00+09:00")
  check("observed_at: a gap fact observes its own record t",
        fieldOf(events[2], "observed_at") == "2026-11-02T10:00:00+09:00")
  check("observed_at: the truncation facts observe their own record t",
        fieldOf(events[3], "observed_at") == "2026-11-02T10:15:00+09:00" and
        fieldOf(events[4], "observed_at") == "2026-11-02T10:15:00+09:00")
  check("observed_at: the feed-disconnection fact observes its record t",
        fieldOf(events[5], "observed_at") == "2026-11-02T10:25:00+09:00")
  check("observed_at: the market-state fact observes the ws_raw t",
        fieldOf(events[6], "observed_at") == "2026-11-02T10:30:00+09:00")
  check("observed_at: the session_end fact observes the last recorded t " &
        "(0s FID 20), not a wall clock",
        fieldOf(events[7], "observed_at") == "2026-11-02T15:30:10+09:00")
  check("observed_at: the evidenced 0s record (seq 12) judges exactly no " &
        "fact — its t never appears as an unevidenced observation",
        events.len == 8 and
        fieldOf(events[6], "evidence_ref") == contentRef(recs[10]))

# ------------------------------------------------------------- the id rule

proc idFor(eventType, ruleId, entity: string; q: int): string =
  eventIdOf("2026-11-02", eventType, ruleId, entity, q)

block eventIdRule:
  check("event_id: candidate UP 005930 is the rule over its tuple at Q=4",
        fieldOf(events[0], "event_id") ==
        idFor("CANDIDATE_ENTERED", "candidate-transition-v1", "005930", 4))
  check("event_id: candidate DOWN 000660 is the rule over its tuple at Q=4",
        fieldOf(events[1], "event_id") ==
        idFor("CANDIDATE_ENTERED", "candidate-transition-v1", "000660", 4))
  check("event_id: the symbol gap fact binds to Q=5",
        fieldOf(events[2], "event_id") ==
        idFor("DATA_GAP_SUSPECTED", "gap-suspected-v1", "005930", 5))
  check("event_id: the connection-wide gap fact binds to Q=7 with the " &
        "wildcard entity",
        fieldOf(events[3], "event_id") ==
        idFor("DATA_GAP_SUSPECTED", "gap-suspected-v1", "*", 7))
  check("event_id: the truncation fact differs from the gap fact of the " &
        "same record only by event_type",
        fieldOf(events[4], "event_id") ==
        idFor("REST_TRUNCATED", "rest-truncated-v1", "*", 7) and
        fieldOf(events[3], "event_id") != fieldOf(events[4], "event_id"))
  check("event_id: the feed disconnection binds to Q=9",
        fieldOf(events[5], "event_id") ==
        idFor("FEED_DISCONNECTED", "feed-disconnected-v1", "*", 9))
  check("event_id: the market-state fact binds to Q=11",
        fieldOf(events[6], "event_id") ==
        idFor("MARKET_STATE_UNKNOWN", "market-state-unknown-v1", "*", 11))
  check("event_id: the session close binds to the seal record Q=13",
        fieldOf(events[7], "event_id") ==
        idFor("SESSION_ENDED", "session-close-v1", "*", 13))
  check("event_id: a differing Q yields a different id",
        idFor("SESSION_ENDED", "session-close-v1", "*", 13) !=
        idFor("SESSION_ENDED", "session-close-v1", "*", 12))
  check("event_id: the id is a pure function of the tuple",
        idFor("CANDIDATE_ENTERED", "candidate-transition-v1", "005930", 4) ==
        idFor("CANDIDATE_ENTERED", "candidate-transition-v1", "005930", 4))

# ------------------------------------------------------- run_id namespacing

proc withRunId(rs: seq[Record]; runId: string): seq[Record] =
  ## The same recorded stream, its config record carrying a run_id (the
  ## run directory's basename — the recorder COMMITTED convention).
  result = rs
  var pairs: seq[HcjPair] = rs[1].raw.pairs
  pairs.add(("run_id", hStr(runId)))
  result[1] = Record(seq: rs[1].seq, kind: rs[1].kind, raw: hObj(pairs))

block runIdNamespace:
  # 2026-11-09 incident, reproduced: a failed same-date run and its
  # restart judge the same tuples, so the legacy id space collides and
  # the immutable notify ledger refuses the restart's whole batch.
  check("incident: two same-date folds under the legacy rule are the " &
        "same ids (the collision the ledger refused)",
        eventsOfRecords(recs) == eventsOfRecords(recs))
  let runA = eventsOfRecords(withRunId(recs, "fidelity-2026-11-02-a"))
  let runB = eventsOfRecords(withRunId(recs, "fidelity-2026-11-02-b"))
  check("run_id: every id of run A is the rule over its tuple plus the " &
        "namespace (candidate UP at Q=4)",
        fieldOf(runA[0], "event_id") ==
          eventIdOf("2026-11-02", "CANDIDATE_ENTERED",
                    "candidate-transition-v1", "005930", 4,
                    "fidelity-2026-11-02-a") and
        fieldOf(runA[2], "event_id") ==
          eventIdOf("2026-11-02", "DATA_GAP_SUSPECTED", "gap-suspected-v1",
                    "005930", 5, "fidelity-2026-11-02-a"))
  check("run_id: runs A and B share no id — the failed run's facts and " &
        "the restart's facts coexist in one ledger",
        (block:
           var ok = true
           for la in runA:
             for lb in runB:
               if fieldOf(la, "event_id") == fieldOf(lb, "event_id"):
                 ok = false
           ok))
  check("run_id: a namespaced id differs from the legacy id of the same tuple",
        fieldOf(runA[0], "event_id") != fieldOf(events[0], "event_id"))
  check("run_id: determinism — the same run_id folds to the same bytes",
        eventsOfRecords(withRunId(recs, "fidelity-2026-11-02-a")) == runA)
  check("run_id: the event shape is unchanged (closed field set, schema " &
        "valid — the namespace is inside the id, never a new field)",
        (block:
           var bad: seq[string]
           for l in runA:
             bad.add(validateEventLine(l))
           bad.len == 0))
  let incA = eventsOfRecords(
    withRunId(loadRecords(incompletePath), "inc-a"))
  let incB = eventsOfRecords(
    withRunId(loadRecords(incompletePath), "inc-b"))
  check("run_id: the unsealed stream's SESSION_INCOMPLETE (finish path) " &
        "is namespaced too",
        incA.len > 0 and incB.len > 0 and
        incA[^1] != incB[^1] and
        fieldOf(incA[^1], "event_type") == "SESSION_INCOMPLETE" and
        fieldOf(incA[^1], "event_id") ==
          eventIdOf("2026-11-02", "SESSION_INCOMPLETE",
                    "session-incomplete-v1", "*", 12, "inc-a"))
  var refused = false
  var msg = ""
  try:
    var rs = recs
    var pairs: seq[HcjPair] = rs[1].raw.pairs
    pairs.add(("run_id", hInt(7)))
    rs[1] = Record(seq: rs[1].seq, kind: rs[1].kind, raw: hObj(pairs))
    discard eventsOfRecords(rs)
  except CatchableError as e:
    refused = true
    msg = e.msg
  check("run_id: a non-string run_id is refused, never ignored",
        refused and "config.run_id must be a string" in msg)

# -------------------------------------------------------------- evidence_ref

block evidenceRef:
  check("evidence_ref: candidate facts name the declared vendor scope",
        fieldOf(events[0], "evidence_ref") == "ka10027:stex_tp=1:sort_tp=1" and
        fieldOf(events[1], "evidence_ref") == "ka10027:stex_tp=1:sort_tp=3")
  check("evidence_ref: record-backed facts are content addresses of the " &
        "consumed record's canonical line",
        fieldOf(events[2], "evidence_ref") == contentRef(recs[4]) and
        fieldOf(events[3], "evidence_ref") == contentRef(recs[6]) and
        fieldOf(events[4], "evidence_ref") == contentRef(recs[6]) and
        fieldOf(events[5], "evidence_ref") == contentRef(recs[8]) and
        fieldOf(events[6], "evidence_ref") == contentRef(recs[10]) and
        fieldOf(events[7], "evidence_ref") == contentRef(recs[12]))

# ----------------------------------------------------- determinism & purity

block determinism:
  let again = eventsOfRecords(recs)
  check("determinism: the same fold twice yields the same bytes",
        again == events)
  var s0 = initEventGenState()
  var manual: seq[string]
  for r in recs:
    let (s1, evs) = step(s0, r)
    s0 = s1
    for f in evs:
      manual.add(eventLine(f))
  for f in finish(s0):
    manual.add(eventLine(f))
  check("determinism: a per-record step loop is byte-identical to the " &
        "replay fold (one judgment, two drivers)",
        manual == events)
  let fresh = initEventGenState()
  let before = $fresh.lastSeq & "|" & fresh.lastEvidence
  discard step(fresh, recs[2])
  check("determinism: step is a value function — the caller's state is " &
        "never mutated in place",
        ($fresh.lastSeq & "|" & fresh.lastEvidence) == before)

# --------------------------------------- record-first recovery (death/restart)

proc foldFrom(s: EventGenState; rs: seq[Record]): seq[string] =
  var st = s
  for r in rs:
    let (s2, evs) = step(st, r)
    st = s2
    for f in evs:
      result.add(eventLine(f))
  for f in finish(st):
    result.add(eventLine(f))

proc stepEvents(recs: seq[Record]): seq[string] =
  ## What a live process wrote to its events log by the time it died at the
  ## end of `recs`: the per-record judgments only — a dead process never
  ## reaches the end-of-stream judgment.
  var s = initEventGenState()
  for r in recs:
    let (s2, evs) = step(s, r)
    s = s2
    for f in evs:
      result.add(eventLine(f))

block recovery:
  let prefix = recs[0 ..< 8]
  let prefixEvents = stepEvents(prefix)
  check("recovery: the events judged before the crash are a byte-prefix " &
        "of the full judgment (nothing lost, nothing rewritten)",
        prefixEvents.len < events.len and
        events[0 ..< prefixEvents.len] == prefixEvents)
  let resumed = foldFrom(stateAt(prefix), recs[8 ..< recs.len])
  check("recovery: resuming the recorded stream from the last judgment " &
        "state reproduces exactly the missing events",
        resumed == events[prefixEvents.len ..< events.len])
  check("recovery: prefix + resume is the whole judgment",
        prefixEvents & resumed == events)
  let incRecs = loadRecords(incompletePath)
  let incEvents = eventsOfRecords(incRecs)
  check("recovery: the unsealed stream ends with SESSION_INCOMPLETE",
        incEvents.len == 8 and
        fieldOf(incEvents[^1], "event_type") == "SESSION_INCOMPLETE")
  check("recovery: the incomplete fact binds to the last consumed record " &
        "(Q=12) and carries its content address",
        fieldOf(incEvents[^1], "event_id") ==
        eventIdOf("2026-11-02", "SESSION_INCOMPLETE", "session-incomplete-v1",
                  "*", 12) and
        fieldOf(incEvents[^1], "evidence_ref") ==
        contentRef(incRecs[11]) and
        fieldOf(incEvents[^1], "severity") == "HIGH" and
        fieldOf(incEvents[^1], "data_quality") == "INCOMPLETE")
  check("recovery: finish() on a sealed stream judges nothing",
        finish(stateAt(recs)).len == 0)
  let prefixFinish = finish(stateAt(prefix))
  check("recovery: finish() on a consumed prefix judges exactly one fact",
        prefixFinish.len == 1 and
        prefixFinish[0].eventType == "SESSION_INCOMPLETE")
  check("recovery: the live definition (prefix fold + resume + finish) " &
        "matches the replay fold of the unsealed stream",
        foldFrom(stateAt(prefix), incRecs[8 ..< incRecs.len]) ==
        incEvents[prefixEvents.len ..< incEvents.len])

# ------------------------------------------------------ candidate transitions

proc hexOf(s: string): string =
  const digits = "0123456789abcdef"
  for i in 0 ..< s.len:
    let b = byte(s[i])
    result.add(digits[int(b shr 4)])
    result.add(digits[int(b and 0x0f'u8)])

proc restRecordRows(seqNo: int; sortTp: string;
                    rows: seq[tuple[code, nm: string]];
                    contYn = "N"): Record =
  ## A synthetic terminal ka10027 page with per-row stk_nm control: an
  ## empty nm omits the field entirely (a nameless row — collected
  ## nowhere, the consumer falls back to the symbol).
  var rowVals: seq[HcjValue]
  for r in rows:
    var ps: seq[HcjPair] = @[
      ("buy_req", hStr("500")), ("cnt", hStr("1")),
      ("cntr_str", hStr("0")), ("cur_prc", hStr("70000")),
      ("flu_rt", hStr("3.50")), ("now_trde_qty", hStr("100")),
      ("pred_pre", hStr("500")), ("pred_pre_sig", hStr("2")),
      ("sel_req", hStr("1000")), ("stk_cd", hStr(r.code)),
      ("stk_cls", hStr("2"))]
    if r.nm.len > 0:
      ps.add(("stk_nm", hStr(r.nm)))
    rowVals.add(hObj(ps))
  let body = canonical(hObj(("pred_pre_flu_rt_upper", hArrSeq(rowVals)),
                            ("return_code", hInt(0)),
                            ("return_msg", hStr("synthetic"))))
  Record(seq: seqNo, kind: kRestResp, raw: hObj(
    ("api_id", hStr("ka10027")),
    ("body_hex", hStr(hexOf(body))),
    ("cont_yn", hStr(contYn)),
    ("next_key", hStr(if contYn == "Y": "k" else: "")),
    ("page", hInt(1)),
    ("query", hObj(
      ("crd_cnd", hStr("0")), ("mrkt_tp", hStr("000")),
      ("pric_cnd", hStr("0")), ("sort_tp", hStr(sortTp)),
      ("stk_cnd", hStr("0")), ("stex_tp", hStr("1")),
      ("trde_prica_cnd", hStr("0")), ("trde_qty_cnd", hStr("0000")),
      ("updown_incls", hStr("1")))),
    ("status", hInt(200))))

proc restRecord(seqNo: int; sortTp: string; codes: seq[string];
                contYn = "N"): Record =
  ## A synthetic terminal ka10027 page: the declared scope, a preserved
  ## body affirming success (return_code 0 + the documented list key).
  var rows: seq[tuple[code, nm: string]]
  for c in codes:
    rows.add((code: c, nm: "synthetic"))
  restRecordRows(seqNo, sortTp, rows, contYn)

proc wsFrame(seqNo: int; t: string): Record =
  ## A ws_frame whose own t advances the observation stamp (touchT
  ## composes the time-of-day form onto the session date). The record
  ## judges nothing itself — its role here is the observation-group
  ## boundary.
  Record(seq: seqNo, kind: kWsFrame, raw: hObj(
    ("m", hStr("2")), ("price", hInt(70000)), ("symbol", hStr("005930")),
    ("t", hStr(t)), ("vol", hInt(1000))))

proc sessionEndRecord(seqNo: int): Record =
  Record(seq: seqNo, kind: kSessionEnd, raw: hNull())

proc summary(evs: seq[EventFact]): string =
  for f in evs:
    result.add(f.eventType & "/" & f.symbol & "/" & f.direction & "/" &
      $f.rank & " ")

block candidateTransitions:
  var s = stateAt(recs[0 ..< 2])
  # first generation: up [005930], down [000660]
  let (s1, e1) = step(s, restRecord(3, "1", @["005930"]))
  s = s1
  check("candidates: an up chain alone judges nothing", e1.len == 0)
  let (s2, e2) = step(s, restRecord(4, "3", @["000660"]))
  s = s2
  check("candidates: the first completed up+down pair enters both " &
        "candidates with rank and direction",
        e2.summary() ==
        "CANDIDATE_ENTERED/005930/UP/1 CANDIDATE_ENTERED/000660/DOWN/1 ")
  check("candidates: the derivation binds to the completing record (Q=4)",
        e2[0].eventId == eventIdOf("2026-11-02", "CANDIDATE_ENTERED",
                                   "candidate-transition-v1", "005930", 4))
  check("candidates: the evidence is the declared vendor scope of the " &
        "judged direction",
        e2[0].evidenceRef == "ka10027:stex_tp=1:sort_tp=1" and
        e2[1].evidenceRef == "ka10027:stex_tp=1:sort_tp=3")
  # poll 1: 000660 moved from down to up (rank 2); 005930 persists at rank 1
  let (s3, e3) = step(s, restRecord(5, "1", @["005930", "000660"]))
  s = s3
  let (s4, e4) = step(s, restRecord(6, "3", @[]))
  s = s4
  check("candidates: a poll judges the move (EXITED down, ENTERED up) " &
        "and stays silent about the unchanged rank",
        e4.summary() ==
        "CANDIDATE_ENTERED/000660/UP/2 CANDIDATE_EXITED/000660/DOWN/0 ")
  # poll 2: the up ranking swaps places — an UPDATED rank change
  let (s5, e5) = step(s, restRecord(7, "1", @["000660", "005930"]))
  s = s5
  let (s6, e6) = step(s, restRecord(8, "3", @[]))
  s = s6
  check("candidates: a rank change is CANDIDATE_UPDATED with the new rank",
        e6.summary() ==
        "CANDIDATE_UPDATED/000660/UP/1 CANDIDATE_UPDATED/005930/UP/2 ")
  # poll 3: everything drops out of both rankings
  let (s7, e7) = step(s, restRecord(9, "1", @[]))
  s = s7
  let (s8, e8) = step(s, restRecord(10, "3", @[]))
  s = s8
  check("candidates: a dropped candidate exits without a rank",
        e8.summary() ==
        "CANDIDATE_EXITED/000660/UP/0 CANDIDATE_EXITED/005930/UP/0 ")
  # dedup: a code the vendor lists in BOTH directions is judged once (up first)
  let (s9, e9) = step(s, restRecord(11, "1", @["005930"]))
  s = s9
  let (s10, e10) = step(s, restRecord(12, "3", @["005930"]))
  s = s10
  check("candidates: a both-directions code is judged once, in the up " &
        "direction — one fact per id tuple",
        e10.summary() == "CANDIDATE_ENTERED/005930/UP/1 " and
        idsUnique(e10))
  # an unterminated chain (cont-yn Y) judges nothing
  let (s11, e11) = step(s, restRecord(13, "1", @["005930"], contYn = "Y"))
  s = s11
  check("candidates: a chain that never terminates judges nothing (the " &
        "stream-level audit rejects it; no event leaks past)",
        e11.len == 0)
  discard s

# ------------------------------------------------------ TOP10 transitions

proc top10Facts(evs: seq[EventFact]): seq[EventFact] =
  for f in evs:
    if f.ruleId == ruleTop10Transition: result.add(f)

proc candFacts(evs: seq[EventFact]): seq[EventFact] =
  for f in evs:
    if f.ruleId == ruleCandidateTransition: result.add(f)

proc top10Summary(evs: seq[EventFact]): string =
  for f in evs:
    result.add(f.eventType & "/" & f.symbol & "/" & f.direction & "/" &
               $f.rank & "/" & $f.previousRank & "/" & f.name & " ")

block top10Transitions:
  ## The top10-transition-v1 judgment over three observation groups. G1
  ## completes under the config-midnight stamp (rest_resp records carry
  ## no t), G2 under 10:10, G3 under 10:20: the G1 pair starts the
  ## pending group; the G2 pair crosses the FIRST boundary (G1 becomes
  ## the confirmed baseline — zero facts); the G3 pair crosses the second
  ## boundary and judges the G1->G2 TOP10 transitions BEFORE its own
  ## G2->G3 candidate facts; the seal flushes G2->G3 before
  ## SESSION_ENDED.
  let g1up = @["000001", "000002", "000003", "000004", "000005", "000006",
               "000007", "000008", "000009", "000010", "000011", "000012",
               "000013", "000014", "000015"]
  let g2up = @["000001", "000005", "000003", "000004", "000002", "000006",
               "000007", "000016", "000009", "000011", "000010", "000012",
               "000013", "000015", "000014"]
  let g3up = @["000001", "000005", "000004", "000003", "000002", "000006",
               "000007", "000016", "000009", "000011", "000010", "000012",
               "000013", "000015", "000014"]
  var stream = recs[0 ..< 2]
  var s = stateAt(recs[0 ..< 2])
  var journal: seq[string]

  proc feed(r: Record): seq[EventFact] =
    stream.add(r)
    let (s2, evs) = step(s, r)
    s = s2
    for f in evs: journal.add(eventLine(f))
    evs

  # G1: the first completed pair starts the pending group — no boundary.
  let e1 = feed(restRecord(3, "1", g1up))
  check("top10: an up chain alone still judges nothing", e1.len == 0)
  let e2 = feed(restRecord(4, "3", @[]))
  check("top10: the first generation judges only candidate facts — the " &
        "group baseline carries no transition",
        e2.top10Facts().len == 0 and e2.len == 15 and
        (block:
           var ok = true
           for f in e2:
             if f.eventType != "CANDIDATE_ENTERED": ok = false
           ok))
  check("top10: the first generation sets the pending stamp and q",
        s.pendingStamp == "2026-11-02T00:00:00+09:00" and s.pendingQ == 4 and
        s.top10Confirmed.isNone)

  # G2: the stamp changes — the first boundary. G1 becomes the confirmed
  # baseline: zero TOP10 facts (never guessed), the candidate rule
  # unchanged.
  discard feed(wsFrame(5, "10:10:00+09:00"))
  discard feed(restRecord(6, "1", g2up))
  let e4 = feed(restRecord(7, "3", @[]))
  check("top10: the first boundary confirms the baseline with zero facts " &
        "(a generation with no predecessor has no transition)",
        e4.top10Facts().len == 0 and
        s.top10Confirmed.isSome and s.top10Confirmed.get.up == g1up)
  check("top10: the baseline boundary still judges the new generation's " &
        "candidate facts (the existing rule is unchanged — the 14/15 " &
        "rank swap too)",
        e4.candFacts().len == 8)
  check("top10: the pending group is G2 now (stamp, q, tail)",
        s.pendingStamp == "2026-11-02T10:10:00+09:00" and s.pendingQ == 7 and
        s.candidates.up == g2up)

  # G3: the second boundary. The G1->G2 TOP10 facts are judged FIRST,
  # then the G2->G3 candidate facts — the order contract.
  discard feed(wsFrame(8, "10:20:00+09:00"))
  discard feed(restRecord(9, "1", g3up))
  let e6 = feed(restRecord(10, "3", @[]))
  check("top10: the second boundary judges the confirmed->pending tail " &
        "transition — the full rule table (11->10 ENTERED with " &
        "previous_rank, 10->11 EXITED with rank, 5->2 RANK_CHANGED, " &
        "absence->top10 ENTERED without previous_rank, top10->absence " &
        "EXITED without rank)",
        e6.top10Facts().top10Summary() ==
        "RANK_CHANGED/000005/UP/2/5/synthetic " &
        "RANK_CHANGED/000002/UP/5/2/synthetic " &
        "TOP10_ENTERED/000016/UP/8/0/synthetic " &
        "TOP10_ENTERED/000011/UP/10/11/synthetic " &
        "TOP10_EXITED/000010/UP/11/10/synthetic " &
        "TOP10_EXITED/000008/UP/0/8/ ")
  check("top10: the boundary TOP10 facts precede the new group's " &
        "candidate facts (the order contract)",
        e6.len == 8 and
        (block:
           var ok = true
           for i in 0 ..< 6:
             if e6[i].ruleId != ruleTop10Transition: ok = false
           for i in 6 ..< 8:
             if e6[i].ruleId != ruleCandidateTransition: ok = false
           ok))
  check("top10: the candidate facts after the boundary facts are the " &
        "G2->G3 rank swap only",
        summary(@[e6[6], e6[7]]) ==
        "CANDIDATE_UPDATED/000004/UP/3 CANDIDATE_UPDATED/000003/UP/4 ")
  check("top10: unchanged ranks and outside<->outside judge nothing " &
        "(1->1, 6->6, 9->9, 12->12, 13->13, 15->14, 14->15)",
        (block:
           var ok = true
           for f in e6.top10Facts():
             if f.symbol in ["000001", "000003", "000004", "000006",
                             "000007", "000009", "000012", "000013",
                             "000014", "000015"]: ok = false
           ok))
  check("top10: the boundary facts bind the PENDING pair's q (7), never " &
        "the current pair's (10)",
        e6.top10Facts()[0].eventId ==
          eventIdOf("2026-11-02", "RANK_CHANGED", ruleTop10Transition,
                    "000005", 7) and
        e6.top10Facts()[2].eventId ==
          eventIdOf("2026-11-02", "TOP10_ENTERED", ruleTop10Transition,
                    "000016", 7))
  check("top10: the boundary facts observe the pending group's own stamp " &
        "(10:10), never the emission moment's fallbackT (10:20)",
        (block:
           var ok = true
           for f in e6.top10Facts():
             if f.observedAt != "2026-11-02T10:10:00+09:00": ok = false
           ok))
  check("top10: the boundary facts carry the direction's declared vendor " &
        "scope evidence and are INFO/OBSERVING facts of the top10 rule",
        e6.top10Facts()[0].evidenceRef == "ka10027:stex_tp=1:sort_tp=1" and
        (block:
           var ok = true
           for f in e6.top10Facts():
             if f.severity != "INFO" or f.dataQuality != "OBSERVING": ok = false
           ok))
  check("top10: every boundary fact is a schema-valid fact line (closed " &
        "field set, previous_rank >= 1 or absent, name non-empty or absent)",
        (block:
           var bad: seq[string]
           for f in e6:
             bad.add(validateEventLine(eventLine(f)))
           bad.len == 0))
  check("top10: the boundary facts' ids are distinct",
        idsUnique(e6) and idsUnique(e6.top10Facts()))

  # The seal: the final group (G2->G3) is flushed BEFORE SESSION_ENDED.
  let seRec = sessionEndRecord(11)
  let e7 = feed(seRec)
  check("top10: the seal flushes the final group before SESSION_ENDED " &
        "(order, shape and the 5->5 silence)",
        e7.len == 3 and e7.top10Facts().len == 2 and
        e7[2].eventType == "SESSION_ENDED" and
        e7.top10Facts().top10Summary() ==
        "RANK_CHANGED/000004/UP/3/4/synthetic " &
        "RANK_CHANGED/000003/UP/4/3/synthetic ")
  check("top10: the flush binds the pending pair's q (10) and the pending " &
        "group's stamp (10:20)",
        e7[0].eventId ==
          eventIdOf("2026-11-02", "RANK_CHANGED", ruleTop10Transition,
                    "000004", 10) and
        e7[0].observedAt == "2026-11-02T10:20:00+09:00")
  check("top10: the flush's evidence is the seal record's content address",
        e7[0].evidenceRef == contentRef(seRec) and
        e7[2].evidenceRef == contentRef(seRec))

  check("top10: the fold of the whole stream is exactly the manual " &
        "judgment and byte-identical on a second fold (replay twice)",
        eventsOfRecords(stream) == journal and
        eventsOfRecords(stream) == eventsOfRecords(stream))

  # Without the seal the final group is never flushed: finish() judges
  # only SESSION_INCOMPLETE and the journal holds no G2->G3 TOP10 fact.
  let unsealed = eventsOfRecords(stream[0 ..< ^1])
  var nTop10 = 0
  for l in unsealed:
    if "\"rule_id\":\"top10-transition-v1\"" in l: inc nTop10
  check("top10: an unsealed stream never flushes the final group — only " &
        "the boundary facts exist and the tail is SESSION_INCOMPLETE",
        nTop10 == 6 and unsealed.len == 32 and
        unsealed[^1].contains("\"SESSION_INCOMPLETE\""))

block top10GroupMerge:
  ## Consecutive pairs under one observation stamp merge into one group:
  ## only the group's TAIL is ever compared (an intra-group change judges
  ## no TOP10 fact), and a previous group's facts appear only when a
  ## different-stamp pair arrives (the boundary delay).
  var stream = recs[0 ..< 2]
  var s = stateAt(recs[0 ..< 2])

  proc feed(r: Record): seq[EventFact] =
    stream.add(r)
    let (s2, evs) = step(s, r)
    s = s2
    evs

  # group A (the config-midnight stamp): two pairs, the second reorders
  # the ranking — same stamp, one merged group.
  discard feed(restRecord(3, "1", @["000001", "000002"]))
  discard feed(restRecord(4, "3", @[]))
  discard feed(restRecord(5, "1", @["000002", "000001"]))
  let eMerge = feed(restRecord(6, "3", @[]))
  check("top10 merge: an intra-group ranking change judges no TOP10 fact " &
        "(the group's tail is the only compared state)",
        eMerge.top10Facts().len == 0 and eMerge.candFacts().len == 2)
  # group B (10:10): the first boundary confirms the baseline (still zero
  # facts — A has no predecessor), so no A->B fact exists yet.
  discard feed(wsFrame(7, "10:10:00+09:00"))
  discard feed(restRecord(8, "1", @["000001", "000002"]))
  let eB = feed(restRecord(9, "3", @[]))
  check("top10 delay: the previous group's facts do not exist until a " &
        "different-stamp pair arrives (the boundary itself judged the " &
        "baseline, never a guess)",
        eB.top10Facts().len == 0)
  # group C (10:20): its pair's boundary judges A(tail, the merged " &
  # reorder)->B — two RANK_CHANGED facts prove the tail (not A's first
  # generation, which equals B and would judge nothing).
  discard feed(wsFrame(10, "10:20:00+09:00"))
  discard feed(restRecord(11, "1", @["000001", "000002"]))
  let eC = feed(restRecord(12, "3", @[]))
  check("top10 delay: the different-stamp pair finally judges the merged " &
        "A-tail -> B transition (the boundary delay is real, the tail is " &
        "the merged one)",
        eC.top10Facts().top10Summary() ==
        "RANK_CHANGED/000001/UP/1/2/synthetic " &
        "RANK_CHANGED/000002/UP/2/1/synthetic ")
  # the seal flushes B->C (identical lists): nothing, then SESSION_ENDED.
  let eSeal = feed(sessionEndRecord(13))
  check("top10 merge: an identical final group flushes nothing before " &
        "SESSION_ENDED",
        eSeal.len == 1 and eSeal[0].eventType == "SESSION_ENDED")

block top10Names:
  ## The name is the pending generation's preserved stk_nm (the group
  ## whose membership the fact describes): a nameless row emits no name
  ## field — the consumer falls back to the symbol, never to a re-parse
  ## of the raw response.
  var s = stateAt(recs[0 ..< 2])

  proc feed(r: Record): seq[EventFact] =
    let (s2, evs) = step(s, r)
    s = s2
    evs

  discard feed(restRecordRows(3, "1", @[(code: "000001", nm: "에이")]))
  discard feed(restRecordRows(4, "3", @[]))
  discard feed(wsFrame(5, "10:10:00+09:00"))
  discard feed(restRecordRows(6, "1",
                              @[(code: "000002", nm: "비"),
                                (code: "000001", nm: "")]))
  discard feed(restRecordRows(7, "3", @[]))
  discard feed(wsFrame(8, "10:20:00+09:00"))
  discard feed(restRecordRows(9, "1",
                              @[(code: "000003", nm: "씨"),
                                (code: "000002", nm: ""),
                                (code: "000001", nm: "에이")]))
  let e6 = feed(restRecordRows(10, "3", @[]))
  check("top10 names: the fact carries the pending generation's name; a " &
        "nameless pending row emits no name field",
        e6.top10Facts().top10Summary() ==
        "TOP10_ENTERED/000002/UP/1/0/비 RANK_CHANGED/000001/UP/2/1/ " and
        not hasField(eventLine(e6.top10Facts()[1]), "name") and
        fieldOf(eventLine(e6.top10Facts()[0]), "name") == "비")
  let e7 = feed(sessionEndRecord(11))
  check("top10 names: the seal flush's facts name from the final pending " &
        "generation (nameless row -> absent field)",
        e7.top10Facts().top10Summary() ==
        "TOP10_ENTERED/000003/UP/1/0/씨 " &
        "RANK_CHANGED/000002/UP/2/1/ " &
        "RANK_CHANGED/000001/UP/3/2/에이 " and
        not hasField(eventLine(e7.top10Facts()[1]), "name"))

block top10Directions:
  ## Each direction is judged independently (rank = that direction's
  ## vendor order); a code entering the top 10 of BOTH directions is
  ## judged once, in the up direction — the inherited up-first dedup.
  var s = stateAt(recs[0 ..< 2])

  proc feed(r: Record): seq[EventFact] =
    let (s2, evs) = step(s, r)
    s = s2
    evs

  discard feed(restRecord(3, "1", @["000001"]))
  discard feed(restRecord(4, "3", @["000002"]))
  discard feed(wsFrame(5, "10:10:00+09:00"))
  discard feed(restRecord(6, "1", @["000003", "000001"]))
  discard feed(restRecord(7, "3", @["000003", "000002"]))
  discard feed(wsFrame(8, "10:20:00+09:00"))
  discard feed(restRecord(9, "1", @["000001"]))
  let e6 = feed(restRecord(10, "3", @["000002"]))
  check("top10 directions: UP and DOWN are judged independently and a " &
        "both-directions code is judged once, up first",
        e6.top10Facts().top10Summary() ==
        "TOP10_ENTERED/000003/UP/1/0/synthetic " &
        "RANK_CHANGED/000001/UP/2/1/synthetic " &
        "RANK_CHANGED/000002/DOWN/2/1/synthetic ")
  check("top10 directions: the DOWN facts carry the down scope evidence",
        e6.top10Facts()[2].evidenceRef == "ka10027:stex_tp=1:sort_tp=3")
  let e7 = feed(sessionEndRecord(11))
  check("top10 directions: the flush judges both directions and the " &
        "both-directions exit once, up first (nameless — the code is " &
        "absent from the final pending tail)",
        e7.top10Facts().top10Summary() ==
        "RANK_CHANGED/000001/UP/1/2/synthetic " &
        "TOP10_EXITED/000003/UP/0/1/ " &
        "RANK_CHANGED/000002/DOWN/1/2/synthetic " and
        e7[^1].eventType == "SESSION_ENDED")

# ------------------------------------------------- verify byte comparison

block verifyByteCompare:
  let fixtureInfo = BuildInfo(codeCommit: "fixture", sourceRef: "main",
    originMainSha: "fixture", dirty: false, nimVersion: NimVersion,
    buildTime: "fixture")
  let res = runCore(recs)
  let tmp = createTempDir("hs-eventgen-test-", "")
  defer: removeDir(tmp)
  let runDir = writeRun(tmp / "run", sessionPath, res, fixtureInfo)
  let v = verifyRun(runDir, fixtureInfo)
  check("verify: a replay-written run verifies MATCH",
        v.verdict == vMatch and v.matched)
  check("verify: the events hash is the artifact's sha256",
        v.eventsSha256 == sha256Hex(readFile(runDir / eventsFile)) and
        v.eventsSha256.len == 64)
  check("verify: the replayed events are byte-identical to the fold",
        readFile(runDir / eventsFile) == linesText(res.events))
  let manifest = readFile(runDir / checksumsFile)
  var manifestCoversEvents = false
  for line in manifest.split('\n'):
    if line.endsWith("  " & eventsFile): manifestCoversEvents = true
  check("verify: CHECKSUMS.sha256 covers the events artifact",
        manifestCoversEvents)
  # A live-produced events file that is byte-exact (as proven above for
  # this stream) passes the comparison; differing live bytes never do.
  writeFile(runDir / eventsFile,
            readFile(runDir / eventsFile) & "{\"tampered\":true}\n")
  let vBad = verifyRun(runDir, fixtureInfo)
  var namedIssue = false
  for issue in vBad.issues:
    if "events.hcj.jsonl differs from replay" in issue: namedIssue = true
  check("verify: tampered live event bytes are a MISMATCH with a named " &
        "issue, never a pass",
        vBad.verdict == vMismatch and namedIssue and not vBad.matched)
  check("verify: the reported EVENTS hash still names the recomputation " &
        "when the artifact differs",
        vBad.eventsSha256 == v.eventsSha256)
  removeFile(runDir / eventsFile)
  let vMissing = verifyRun(runDir, fixtureInfo)
  var missingIssue = false
  for issue in vMissing.issues:
    if "missing artifact: events.hcj.jsonl" in issue: missingIssue = true
  check("verify: a missing events artifact is fail-closed MISMATCH",
        vMissing.verdict == vMismatch and missingIssue)

# ---------------------------------------------------------- incomplete replay

block incompleteReplay:
  let incRecs = loadRecords(incompletePath)
  let res = runCore(incRecs)
  check("incomplete: runCore carries the judgment lines including the " &
        "SESSION_INCOMPLETE tail",
        res.events.len == 8 and
        res.events[^1].contains("\"SESSION_INCOMPLETE\""))

# ------------------------------------------------------------------- summary

if failures == 0:
  echo "EVENT GENERATOR CONTRACT PASSED (", passes, " checks)"
else:
  echo "EVENT GENERATOR CONTRACT FAILED: ", failures, " of ",
       passes + failures
  quit(1)
