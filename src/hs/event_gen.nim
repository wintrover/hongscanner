## event_gen: the VS-3 event generator — the ONE judgment function
## (docs/REPLAY_CONTRACT.md §13, contracts/events/event.schema.json).
##
## `step(state, record) -> (state', events)` is the single event judgment
## of the whole system: the live collector feeds recorded records to it
## strictly in recorder seq order (§13.2/§13.3, record-first), and replay
## folds the very same function over the recorded stream. A second
## live/replay judgment path is contractually forbidden; there is none.
##
## Purity: no wall clock, no filesystem, no network, no arguments. Every
## judgment input is inside the record: `observed_at` is derived from the
## record's own `t` (or from the last timestamp observed earlier in the
## stream for records without one — rest_resp, session_end), never from
## a clock. The input seq Q enters only the one-way event-id digest
## (x-event-id-rule); it is never emitted (§2), and no event record
## carries a position field.
##
## Implemented rules (the contract allows implementation lag; the
## vocabulary never depends on the implementation):
##
##   rule_id                    v  event_type             judged from
##   candidate-transition-v1    1  CANDIDATE_ENTERED /    the completed
##                                 CANDIDATE_UPDATED /    ka10027 page
##                                 CANDIDATE_EXITED       chains (up+down
##                                                        re-derivation via
##                                                        vendor_input;
##                                                        direction+rank
##                                                        from vendor order)
##   top10-transition-v1        1  TOP10_ENTERED /        the pending
##                                 TOP10_EXITED /         observation
##                                 RANK_CHANGED           group's tail
##                                                        confirmed by a
##                                                        new observation
##                                                        stamp (or the
##                                                        session_end
##                                                        seal): each
##                                                        direction's top
##                                                        10 of the vendor
##                                                        order, compared
##                                                        with the last
##                                                        confirmed group's
##                                                        tail; observed_at
##                                                        is the confirmed
##                                                        group's own stamp,
##                                                        never the emission
##                                                        moment
##   feed-disconnected-v1       1  FEED_DISCONNECTED      ws_conn with
##                                                        state closed_ok
##                                                        (INFO) /
##                                                        closed_error
##                                                        (HIGH)
##   gap-suspected-v1           1  DATA_GAP_SUSPECTED     every gap record
##                                                        (HIGH, INCOMPLETE)
##   rest-truncated-v1          1  REST_TRUNCATED         gap record with
##                                                        what
##                                                        "rest_truncated"
##                                                        (HIGH, INCOMPLETE)
##   subscription-truncated-    1  SUBSCRIPTION_          gap record with
##   v1                            TRUNCATED              what "subscription_
##                                                        truncated" (HIGH,
##                                                        INCOMPLETE; the
##                                                        gap detail's
##                                                        direction token
##                                                        becomes the fact's
##                                                        direction)
##   market-state-unknown-v1    1  MARKET_STATE_UNKNOWN   0s ws_raw payload
##                                                        with an FID 215
##                                                        value outside the
##                                                        evidenced table
##                                                        (HIGH, UNKNOWN)
##   session-close-v1           1  SESSION_ENDED          the session_end
##                                                        record (INFO,
##                                                        OBSERVING)
##   session-incomplete-v1      1  SESSION_INCOMPLETE     finish(): a
##                                                        consumed stream
##                                                        that did not end
##                                                        with session_end
##                                                        (HIGH, INCOMPLETE)
##
## Not implemented here, by contract: REPLAY_MATCH / REPLAY_MISMATCH and
## SESSION_APPROVED are session-level verify outputs (§13.6), never step
## facts. A chain that did not affirm success (upDownCandidates raised)
## yields no candidate events: the stream-level audit rejects the run
## (rest_resp.verifyAttempts), so no unconfirmed state is ever judged. A
## round that closed at the declared cap while cont-yn=Y is a declared
## truncated subset (REPLAY_CONTRACT §12.1): the audit accepts it as such,
## but it is consumed here without judgment — a partial universe is no
## candidate generation, and the truncation fact is the collector's gap
## record (the REST_TRUNCATED event), never a silent pass.
import std/[strutils, algorithm, options]
import hcj, records, digest, sub_input, vendor_input, rest_resp, tickwire

type
  EventGenError* = object of CatchableError

  EventFact* = object
    ## One judged transition (the immutable fact record of
    ## event.schema.json). `symbol` == "" means not symbol-scoped (the
    ## schema field is absent, the id entity is the wildcard); same for
    ## `direction` and `rank` == 0. `previousRank` == 0 and `name` == ""
    ## are absent the same way (top10-transition facts only: the rank in
    ## the previous confirmed group, and the vendor row's preserved
    ## stk_nm).
    eventId*: string
    eventType*: string
    observedAt*: string
    sessionId*: string
    ruleId*: string
    ruleVersion*: int
    dataQuality*: string
    severity*: string
    evidenceRef*: string
    symbol*: string
    direction*: string
    rank*: int
    previousRank*: int
    name*: string

  RestRound = object
    ## One declared page chain of one ka10027 query, assembled in stream
    ## order (the event-layer mirror of the collector's chain; the
    ## stream-level acceptance audit stays in rest_resp.verifyAttempts).
    key: string                 ## scopeKey of the declared query
    direction: Direction
    pages: seq[RestRespAttempt]

  EventGenState* = object
    ## The judgment state: a pure function of the record prefix consumed
    ## so far (§13.2). After a crash it is exactly reconstructed by
    ## re-consuming the recorded stream (stateAt + step); nothing else
    ## exists to persist.
    sessionId*: string       ## config.session_date (record 2)
    runId*: string           ## config.run_id (optional, record 2): the
                             ## run's own identity — the run directory's
                             ## basename, the same value the recorder's
                             ## COMMITTED marker carries. Namespaces the
                             ## event ids (2026-11-09: a failed run and its
                             ## same-day restart must coexist in the notify
                             ## ledger; the id space of one date alone
                             ## collided and the immutable ledger refused
                             ## the restart's facts). Absent on legacy
                             ## records: their ids keep the legacy rule and
                             ## sealed runs replay byte-identically.
    pageCap*: int            ## config.page_cap, defaultPageCap when absent
    lastT*: string           ## last observation timestamp derived so far
    lastSeq*: int            ## seq of the last consumed record
    lastEvidence*: string    ## content hash of that record's canonical line
    sawEnd*: bool            ## a session_end record was consumed
    rounds: seq[RestRound]
    candidates*: UpDownCandidates  ## last derived (fully affirmed) generation
    candidatesKnown*: bool
    top10Confirmed*: Option[UpDownCandidates]
                             ## the tail of the last CONFIRMED observation
                             ## group (top10-transition-v1). None until the
                             ## second group's first pair completes: the
                             ## first group is the baseline and emits
                             ## nothing (a generation with no predecessor
                             ## has no transition).
    pendingStamp*: string      ## the observation stamp (fallbackT at the
                               ## pair's completion) of the pending group —
                               ## the group whose tail s.candidates holds
    pendingQ*: int             ## the completing pair's q of the pending
                               ## group's latest generation

const
  ruleCandidateTransition* = "candidate-transition-v1"
  ruleTop10Transition* = "top10-transition-v1"
  ruleFeedDisconnected* = "feed-disconnected-v1"
  ruleGapSuspected* = "gap-suspected-v1"
  ruleRestTruncated* = "rest-truncated-v1"
  ruleSubscriptionTruncated* = "subscription-truncated-v1"
  ruleMarketStateUnknown* = "market-state-unknown-v1"
  ruleSessionClose* = "session-close-v1"
  ruleSessionIncomplete* = "session-incomplete-v1"
  ruleVersionEventGen* = 1
  ## The evidenced FID 215 market-state values (REPLAY_CONTRACT §12.5:
  ## the close subset 2, 4, 8 and the full close 9). The full value table
  ## is UNVERIFIED, so any other observed value is judged
  ## MARKET_STATE_UNKNOWN — never interpreted.
  evidenced215* = ["2", "4", "8", "9"]

proc egenerr(msg: string): ref EventGenError =
  newException(EventGenError, msg)

proc initEventGenState*(): EventGenState =
  EventGenState(pageCap: defaultPageCap)

# ------------------------------------------------------------------- facts

proc eventIdOf*(sessionId, eventType, ruleId, entity: string;
                transitionSeq: int; runId = ""): string =
  ## x-event-id-rule: sha256 lowercase hex over the HCJ canonical
  ## serialization (keys in codepoint-ascending order, no whitespace, bare
  ## integer) of
  ## {"entity":E,"event_type":T,"rule_id":R,"session_id":S,"transition_seq":Q}
  ## — plus "run_id":U sorted between "rule_id" and "session_id" when a
  ## runId is given. Q is the input record seq and enters only this digest.
  ## runId (the config record's run_id, the run directory's basename —
  ## the same identity the recorder's COMMITTED marker carries) namespaces
  ## the digest when present: a same-date restart of a failed run is a
  ## DIFFERENT run whose facts must coexist with the failure's facts in
  ## the immutable notify ledger (2026-11-09 incident: the legacy id space
  ## collided and the ledger refused the restart's whole event batch).
  ## Absent runId keeps the legacy object byte-identically, so every
  ## sealed pre-run_id run replays with its recorded ids.
  let t = if runId.len == 0:
      hObj(("entity", hStr(entity)),
           ("event_type", hStr(eventType)),
           ("rule_id", hStr(ruleId)),
           ("session_id", hStr(sessionId)),
           ("transition_seq", hInt(transitionSeq)))
    else:
      hObj(("entity", hStr(entity)),
           ("event_type", hStr(eventType)),
           ("rule_id", hStr(ruleId)),
           ("run_id", hStr(runId)),
           ("session_id", hStr(sessionId)),
           ("transition_seq", hInt(transitionSeq)))
  sha256Hex(canonical(t))

proc eventHcj*(e: EventFact): HcjValue =
  ## The fact record exactly as event.schema.json defines it (closed
  ## field set; no verification state, no delivery state, no position).
  ## previous_rank (>= 1) and name (non-empty) are optional fact fields of
  ## the top10-transition rule, emitted only when judged.
  result = hObj(
    ("data_quality", hStr(e.dataQuality)),
    ("event_id", hStr(e.eventId)),
    ("event_type", hStr(e.eventType)),
    ("evidence_ref", hStr(e.evidenceRef)),
    ("observed_at", hStr(e.observedAt)),
    ("rule_id", hStr(e.ruleId)),
    ("rule_version", hInt(e.ruleVersion)),
    ("session_id", hStr(e.sessionId)),
    ("severity", hStr(e.severity)))
  if e.direction.len > 0:
    result.pairs.add(("direction", hStr(e.direction)))
  if e.name.len > 0:
    result.pairs.add(("name", hStr(e.name)))
  if e.previousRank > 0:
    result.pairs.add(("previous_rank", hInt(e.previousRank)))
  if e.rank > 0:
    result.pairs.add(("rank", hInt(e.rank)))
  if e.symbol.len > 0:
    result.pairs.add(("symbol", hStr(e.symbol)))

proc eventLine*(e: EventFact): string =
  canonical(eventHcj(e))

proc judged(s: EventGenState; seqNo: int; eventType, ruleId, symbol,
            observedAt, severity, dataQuality, evidenceRef: string;
            direction = ""; rank = 0; previousRank = 0;
            name = ""): EventFact =
  ## Build one fact: the id entity is the 6-digit symbol when the
  ## judgment is symbol-scoped and the wildcard "*" otherwise. Fail
  ## closed: a fact without a session or without evidence is never
  ## emitted.
  if s.sessionId.len == 0:
    raise egenerr("no session id: the config record was not consumed")
  if evidenceRef.len == 0:
    raise egenerr("refusing to emit " & eventType & " without evidence")
  let sym = if validCode(symbol): symbol else: ""
  let entity = if sym.len > 0: sym else: "*"
  EventFact(
    eventId: eventIdOf(s.sessionId, eventType, ruleId, entity, seqNo,
                       s.runId),
    eventType: eventType,
    observedAt: observedAt,
    sessionId: s.sessionId,
    ruleId: ruleId,
    ruleVersion: ruleVersionEventGen,
    dataQuality: dataQuality,
    severity: severity,
    evidenceRef: evidenceRef,
    symbol: sym,
    direction: direction,
    rank: rank,
    previousRank: previousRank,
    name: name)

proc contentHash(r: Record): string =
  ## Content address of the consumed evidence: the sha256 hex of the
  ## record's canonical line (the x-event-id-rule schema's record-backed
  ## evidence_ref form).
  sha256Hex(makeRecordLine(r.seq, r.kind, r.raw))

proc vendorScopeRef(scope: Ka10027Query): string =
  ## The declared vendor scope as the evidence_ref (the schema's
  ## declared-scope form), e.g. ka10027:stex_tp=1:sort_tp=1.
  "ka10027:stex_tp=" & scope.stexTp & ":sort_tp=" & sortTpOf(scope.direction)

# ------------------------------------------------------------- observations

proc touchT(s: var EventGenState; raw: HcjValue) =
  ## Advance lastT from a record's own `t`: a full ISO 8601 timestamp
  ## with numeric offset, or the ws_frame time-of-day form
  ## "HH:MM:SS+HH:MM" (§3), composed onto the session date. Anything
  ## else leaves lastT unchanged.
  if raw.kind != hkObj:
    return
  let t = raw.getOpt("t")
  if t.isNone or t.get.kind != hkStr:
    return
  let v = t.get.strVal
  if validIso8601Offset(v):
    s.lastT = v
  elif s.sessionId.len > 0 and v.len == 14 and v[2] == ':' and v[5] == ':' and
       v[8] == '+':
    s.lastT = s.sessionId & "T" & v

proc fallbackT(s: EventGenState): string =
  ## The deterministic observed_at for a record that carries no `t`:
  ## the last observation strictly earlier in the stream, or the session
  ## date's midnight (both derived from consumed records, never a clock).
  if s.lastT.len > 0: s.lastT
  elif s.sessionId.len > 0: s.sessionId & "T00:00:00+09:00"
  else: ""

# ------------------------------------------------------------------- step

proc consumeConfig(s: var EventGenState; r: Record) =
  ## The config record is the only source of the session id and the
  ## declared page cap (the same fail-closed fields the core's
  ## parseConfig consumes; a malformed config rejects the run there
  ## before any judgment surfaces).
  let raw = r.raw
  if raw.kind != hkObj:
    raise egenerr("event judgment: config raw is not an object")
  if not raw.has("session_date") or raw.get("session_date").kind != hkStr:
    raise egenerr("event judgment: config.session_date is required")
  s.sessionId = raw.get("session_date").strVal
  if s.sessionId.len == 0:
    raise egenerr("event judgment: config.session_date is empty")
  if raw.has("page_cap"):
    let pc = raw.get("page_cap")
    if pc.kind != hkInt or int(pc.ival) < 1:
      raise egenerr("event judgment: config.page_cap must be an integer >= 1")
    s.pageCap = int(pc.ival)
  if raw.has("run_id"):
    let ri = raw.get("run_id")
    if ri.kind != hkStr:
      raise egenerr("event judgment: config.run_id must be a string")
    s.runId = ri.strVal

proc gapEvents(s: var EventGenState; r: Record; events: var seq[EventFact]) =
  ## Every gap record is DATA_GAP_SUSPECTED (§3: a gap is a period whose
  ## data cannot be trusted — authority, unlike ws_conn). A gap whose
  ## `what` names a REST truncation is additionally REST_TRUNCATED, and
  ## one whose `what` names a subscription truncation is additionally
  ## SUBSCRIPTION_TRUNCATED: two facts of one record, distinguished by
  ## event_type (and so by id). The subscription fact's direction is the
  ## pinned `direction=up|down` token of the gap detail — an optional
  ## schema field, left absent when the token is absent, never guessed.
  let raw = r.raw
  var sym = ""
  var what = ""
  var ownT = ""
  if raw.kind == hkObj:
    let sn = raw.getOpt("symbol")
    if sn.isSome and sn.get.kind == hkStr:
      sym = sn.get.strVal
    let wn = raw.getOpt("what")
    if wn.isSome and wn.get.kind == hkStr:
      what = wn.get.strVal
    let tn = raw.getOpt("t")
    if tn.isSome and tn.get.kind == hkStr and validIso8601Offset(tn.get.strVal):
      ownT = tn.get.strVal
  let at = if ownT.len > 0: ownT else: s.fallbackT
  events.add(judged(s, r.seq, "DATA_GAP_SUSPECTED", ruleGapSuspected, sym,
                    at, "HIGH", "INCOMPLETE", contentHash(r)))
  if what == "rest_truncated":
    events.add(judged(s, r.seq, "REST_TRUNCATED", ruleRestTruncated, sym,
                      at, "HIGH", "INCOMPLETE", contentHash(r)))
  if what == "subscription_truncated":
    var dirName = ""
    let dtn = raw.getOpt("detail")
    if dtn.isSome and dtn.get.kind == hkStr:
      for tok in dtn.get.strVal.split(' '):
        if tok == "direction=up": dirName = "UP"
        elif tok == "direction=down": dirName = "DOWN"
    events.add(judged(s, r.seq, "SUBSCRIPTION_TRUNCATED",
                      ruleSubscriptionTruncated, sym, at, "HIGH",
                      "INCOMPLETE", contentHash(r), direction = dirName))

proc connEvents(s: var EventGenState; r: Record; events: var seq[EventFact]) =
  ## ws_conn closed_ok / closed_error is FEED_DISCONNECTED. `open`
  ## judges nothing (a reconnection is judged by the gap records and the
  ## subscription acks that re-confirm the feed, not by the open itself).
  let raw = r.raw
  if raw.kind != hkObj:
    return
  let st = raw.getOpt("state")
  if st.isNone or st.get.kind != hkStr:
    return
  var severity = ""
  case st.get.strVal
  of "closed_ok": severity = "INFO"
  of "closed_error": severity = "HIGH"
  else: return
  var at = s.fallbackT
  let tn = raw.getOpt("t")
  if tn.isSome and tn.get.kind == hkStr and validIso8601Offset(tn.get.strVal):
    at = tn.get.strVal
  events.add(judged(s, r.seq, "FEED_DISCONNECTED", ruleFeedDisconnected, "",
                    at, severity, "INCOMPLETE", contentHash(r)))

proc rawEvents(s: var EventGenState; r: Record; events: var seq[EventFact]) =
  ## A 0s ws_raw payload whose FID 215 value is outside the evidenced
  ## table (§12.5) is MARKET_STATE_UNKNOWN: the announced state cannot
  ## be interpreted, so it is judged unknown and never guessed. One
  ## event per record (the first unevidenced value in payload order).
  ## A record that fails its acceptance schema is skipped: the core
  ## rejects the run at this seq, so no event can leak past a rejection.
  var w: WsRawRecord
  try:
    w = parseWsRaw(r.seq, r.raw)
  except SubInputError:
    return
  try:
    if channelOfClass(classify(w.payload)) == "0s":
      for st in statesOf0S(r.seq, w.payload):
        if st.value215.len > 0 and st.value215 notin evidenced215:
          events.add(judged(s, r.seq, "MARKET_STATE_UNKNOWN",
                            ruleMarketStateUnknown, "", w.t, "HIGH",
                            "UNKNOWN", contentHash(r)))
          break
  except TickwireError:
    return
  touchT(s, r.raw)

proc candidateTransitions(s: EventGenState; prev, cur: seq[string];
                          dirName, evidenceRef: string; q: int;
                          seen: var seq[tuple[ent, typ: string]];
                          events: var seq[EventFact]) =
  ## One direction's transitions: ENTERED (a code the previous
  ## generation did not carry, with its rank), UPDATED (a persisting
  ## code whose rank changed, with the new rank), EXITED (a dropped
  ## code, no rank — it has no rank in the new ranking). Persisting
  ## with an unchanged rank is no event. Each (entity, event_type) is
  ## judged once per derivation: a code the vendor lists in both
  ## directions is judged in the up direction (vendor order), never
  ## twice — two facts of one tuple would carry one id. The evidence is
  ## the declared vendor scope of the direction's query.
  for i, code in cur:
    let rank = i + 1
    let pos = prev.find(code)
    let typ = if pos < 0: "CANDIDATE_ENTERED"
              elif pos + 1 != rank: "CANDIDATE_UPDATED"
              else: ""
    if typ.len == 0:
      continue
    if (ent: code, typ: typ) in seen:
      continue
    seen.add((ent: code, typ: typ))
    events.add(judged(s, q, typ, ruleCandidateTransition, code,
                      s.fallbackT, "INFO", "OBSERVING", evidenceRef,
                      direction = dirName, rank = rank))
  if s.candidatesKnown:
    for code in prev:
      if code in cur: continue
      if (ent: code, typ: "CANDIDATE_EXITED") in seen: continue
      seen.add((ent: code, typ: "CANDIDATE_EXITED"))
      events.add(judged(s, q, "CANDIDATE_EXITED", ruleCandidateTransition,
                        code, s.fallbackT, "INFO", "OBSERVING", evidenceRef,
                        direction = dirName))

proc top10Direction(s: EventGenState; prev, cur: seq[string]; dirName,
                    observedAt: string; q: int; evidenceRef: string;
                    names: seq[tuple[code, name: string]];
                    seen: var seq[tuple[ent, typ: string]];
                    events: var seq[EventFact]) =
  ## One direction's TOP10 transitions between the last confirmed group's
  ## tail (prev) and the pending group's tail (cur), rank = vendor order
  ## index + 1: ENTERED (into the top 10 — previous_rank only when the
  ## code ranked 11+ before), EXITED (out of the top 10 — rank only while
  ## the code still ranks), RANK_CHANGED (inside the top 10 at a different
  ## rank). Same rank, outside<->outside and absent->absent judge nothing.
  ## The observed_at is the pending group's own stamp (the group these
  ## facts describe — never the emission moment) and the id's
  ## transition_seq is that group's last pair q. The name is the pending generation's preserved
  ## stk_nm (absent when its rows carried none — the consumer falls back
  ## to the symbol). The candidate rules' up-first once-per-(entity,
  ## event_type) dedup is inherited: a code the vendor lists in both
  ## directions is judged in the up direction, never twice.
  for i, code in cur:
    let rank = i + 1
    let pos = prev.find(code)
    let prevRank = pos + 1
    var typ = ""
    if rank <= 10:
      if pos < 0 or prevRank > 10:
        typ = "TOP10_ENTERED"
      elif prevRank != rank:
        typ = "RANK_CHANGED"
    elif pos >= 0 and prevRank <= 10:
      typ = "TOP10_EXITED"
    if typ.len == 0:
      continue
    if (ent: code, typ: typ) in seen:
      continue
    seen.add((ent: code, typ: typ))
    events.add(judged(s, q, typ, ruleTop10Transition, code, observedAt,
                      "INFO", "OBSERVING", evidenceRef,
                      direction = dirName, rank = rank,
                      previousRank = (if pos < 0: 0 else: prevRank),
                      name = nameOf(names, code)))
  for i, code in prev:
    let prevRank = i + 1
    if prevRank > 10:
      continue
    if code in cur:
      continue
    if (ent: code, typ: "TOP10_EXITED") in seen:
      continue
    seen.add((ent: code, typ: "TOP10_EXITED"))
    events.add(judged(s, q, "TOP10_EXITED", ruleTop10Transition, code,
                      observedAt, "INFO", "OBSERVING", evidenceRef,
                      direction = dirName, previousRank = prevRank,
                      name = nameOf(names, code)))

proc top10Transitions(s: EventGenState; confirmed, pending: UpDownCandidates;
                      observedAt: string; q: int;
                      upEvidenceRef, downEvidenceRef: string;
                      seen: var seq[tuple[ent, typ: string]];
                      events: var seq[EventFact]) =
  ## The top10-transition-v1 judgment: the last confirmed observation
  ## group's tail against the pending group's tail, both directions
  ## independently, up first (vendor order). observed_at is the pending
  ## group's own stamp and q its last pair's completing record seq; the
  ## evidence is each direction's declared vendor scope (the pair
  ## boundary) or the seal record's content address (the session-end
  ## flush). The names come from the pending generation (the group whose
  ## membership the facts describe).
  top10Direction(s, confirmed.up, pending.up, "UP", observedAt, q,
                 upEvidenceRef, pending.names, seen, events)
  top10Direction(s, confirmed.down, pending.down, "DOWN", observedAt, q,
                 downEvidenceRef, pending.names, seen, events)

proc pagesResp(rr: RestRound): seq[RawHttpResp] =
  for a in rr.pages: result.add(a.resp)

proc pairRounds(s: var EventGenState; events: var seq[EventFact]) =
  ## Pair the oldest complete up round with the oldest complete down
  ## round and derive the candidate generation (vendor_input stays the
  ## single normalization authority — nothing is re-parsed here). The
  ## transition seq is the paired record the derivation completed on:
  ## the later of the two rounds' last pages. A chain that did not
  ## affirm success consumes the rounds and yields no events. A round
  ## that closed at the declared cap while cont-yn=Y is a declared
  ## truncated subset (REPLAY_CONTRACT §12.1): consumed the same way and
  ## never judged — a partial universe is no candidate generation, and
  ## the truncation fact is the collector's gap record (the
  ## REST_TRUNCATED event), never a silent pass.
  ##
  ## The top10-transition-v1 observation groups: pairs completing under
  ## one observation stamp (fallbackT — rest_resp carries no t, so the
  ## stamp is the last t observed earlier in the stream) form one group,
  ## and a pair completing under a NEW stamp confirms the pending group
  ## (its tail can no longer change). The first group is the baseline:
  ## confirmed = the pending tail, no facts. Every later boundary judges
  ## confirmed tail -> pending tail and — THE ORDER CONTRACT — those
  ## TOP10 facts enter the sequence BEFORE the new group's candidate
  ## facts of this very pair. The session_end flush (stepInto) confirms
  ## the last group the same way.
  while true:
    var i = 0
    while i < s.rounds.len:
      let rr = s.rounds[i]
      if rr.pages.len > 0 and rr.pages[^1].resp.contYn == "Y" and
          rr.pages.len >= s.pageCap:
        s.rounds.delete(i)
      else:
        inc i
    var ui = -1
    var di = -1
    for i, rr in s.rounds:
      if rr.pages.len == 0: continue
      let terminal = rr.pages[^1].resp.contYn != "Y"
      if terminal and rr.direction == dirUp and ui < 0: ui = i
      if terminal and rr.direction == dirDown and di < 0: di = i
    if ui < 0 or di < 0:
      return
    let up = s.rounds[ui]
    let down = s.rounds[di]
    if di > ui:
      s.rounds.delete(di)
      s.rounds.delete(ui)
    else:
      s.rounds.delete(ui)
      s.rounds.delete(di)
    let q = max(up.pages[^1].seqNo, down.pages[^1].seqNo)
    var cand: UpDownCandidates
    try:
      cand = upDownCandidates(
        PageChain(query: up.pages[0].scope, pages: pagesResp(up)),
        PageChain(query: down.pages[0].scope, pages: pagesResp(down)),
        s.pageCap)
    except VendorInputError:
      continue
    # An empty pendingStamp is the first generation, not a boundary: the
    # group starts here and its stamp is pending from this pair on.
    let boundary = s.pendingStamp.len > 0 and s.fallbackT != s.pendingStamp
    var seen: seq[tuple[ent, typ: string]]
    if boundary and s.top10Confirmed.isSome:
      top10Transitions(s, s.top10Confirmed.get, s.candidates, s.pendingStamp,
                       s.pendingQ, vendorScopeRef(up.pages[0].scope),
                       vendorScopeRef(down.pages[0].scope), seen, events)
    let prev = s.candidates
    candidateTransitions(s, prev.up, cand.up, "UP",
                         vendorScopeRef(up.pages[0].scope), q, seen, events)
    candidateTransitions(s, prev.down, cand.down, "DOWN",
                         vendorScopeRef(down.pages[0].scope), q, seen, events)
    if boundary:
      s.top10Confirmed = some(prev)
    s.candidates = cand
    s.candidatesKnown = true
    s.pendingStamp = s.fallbackT
    s.pendingQ = q

proc restEvents(s: var EventGenState; r: Record; events: var seq[EventFact]) =
  ## One recorded REST attempt joins the declared page chain of its
  ## scope. A page-1 record always opens a fresh round of that scope
  ## (the collector's chain policy; an abandoned below-cap incomplete
  ## round is never judged — the stream-level audit rejects such a
  ## stream; a cap-closed round is a declared truncated subset — the
  ## audit accepts it and pairRounds consumes it without judgment). A
  ## later page must continue the scope's newest round at exactly the
  ## next page index; anything else is chain corruption the audit
  ## rejects, so it judges nothing.
  ##
  ## ka10080 records judge nothing here: candidate facts are ka10027
  ## chains only (§13 rule table), and the backfill bars carry no event
  ## rule — the record stays preserved evidence.
  var a: RestRespAttempt
  try:
    a = parseAttempt(r.seq, r.raw)
  except RestRespError:
    return
  if a.api != raKa10027:
    return
  let key = scopeKey(a.scope)
  var idx = -1
  for i in countdown(s.rounds.len - 1, 0):
    if s.rounds[i].key == key:
      idx = i
      break
  if a.page == 1:
    s.rounds.add(RestRound(key: key, direction: a.scope.direction,
                           pages: @[a]))
    pairRounds(s, events)
    return
  if idx < 0 or a.page != s.rounds[idx].pages.len + 1:
    return
  s.rounds[idx].pages.add(a)
  pairRounds(s, events)

proc stepInto(s: var EventGenState; r: Record; events: var seq[EventFact]) =
  ## The one judgment body. `lastSeq`/`lastEvidence` advance first: a
  ## fact's content evidence is the record the judgment consumed it
  ## from, including the record this very step is judging.
  s.lastSeq = r.seq
  s.lastEvidence = contentHash(r)
  case r.kind
  of kCalendar, kSub, kOutFrame, kPong:
    discard
  of kConfig:
    consumeConfig(s, r)
  of kWsFrame:
    touchT(s, r.raw)
  of kGap:
    gapEvents(s, r, events)
    touchT(s, r.raw)
  of kWsConn:
    connEvents(s, r, events)
    touchT(s, r.raw)
  of kWsRaw:
    rawEvents(s, r, events)
  of kRestResp:
    restEvents(s, r, events)
  of kSessionEnd:
    # The final group flush (top10-transition-v1): the seal confirms the
    # pending observation group — the one boundary no successor pair ever
    # opens — so its confirmed-vs-pending facts are judged here, BEFORE
    # SESSION_ENDED, with the pending group's own stamp and q; the
    # evidence is the seal record itself (s.lastEvidence was advanced to
    # it at the top of this step). A stream whose only group is the
    # baseline (top10Confirmed none) flushes nothing: a generation with
    # no predecessor has no transition.
    if not s.sawEnd and s.top10Confirmed.isSome and s.pendingStamp.len > 0:
      var seen: seq[tuple[ent, typ: string]]
      top10Transitions(s, s.top10Confirmed.get, s.candidates, s.pendingStamp,
                       s.pendingQ, s.lastEvidence, s.lastEvidence, seen,
                       events)
    s.sawEnd = true
    events.add(judged(s, r.seq, "SESSION_ENDED", ruleSessionClose, "",
                      s.fallbackT, "INFO", "OBSERVING", s.lastEvidence))

proc step*(s: EventGenState; r: Record): tuple[state: EventGenState,
                                               events: seq[EventFact]] =
  ## THE single judgment function (REPLAY_CONTRACT §13.1). The live
  ## path feeds recorded records in recorder seq order (§13.3) and the
  ## replay path folds this over the recorded stream; there is no other
  ## event judgment. Value in, value out: the state is a pure function
  ## of the record prefix consumed so far.
  result.state = s
  result.events = @[]
  stepInto(result.state, r, result.events)

proc finish*(s: EventGenState): seq[EventFact] =
  ## The end-of-stream judgment (part of the same judgment layer, used
  ## by both paths at the same points): a consumed stream that did not
  ## end with a session_end record is SESSION_INCOMPLETE, judged at the
  ## last consumed record. A sealed stream judges nothing here.
  if s.sawEnd or s.lastSeq == 0 or s.sessionId.len == 0:
    return @[]
  result = @[EventFact(
    eventId: eventIdOf(s.sessionId, "SESSION_INCOMPLETE",
                       ruleSessionIncomplete, "*", s.lastSeq, s.runId),
    eventType: "SESSION_INCOMPLETE",
    observedAt: s.fallbackT,
    sessionId: s.sessionId,
    ruleId: ruleSessionIncomplete,
    ruleVersion: ruleVersionEventGen,
    dataQuality: "INCOMPLETE",
    severity: "HIGH",
    evidenceRef: s.lastEvidence,
    symbol: "",
    direction: "",
    rank: 0)]

proc stateAt*(recs: seq[Record]): EventGenState =
  ## The judgment state after consuming a record prefix: the fold of
  ## step alone. Death/restart recovery is exactly this — re-consume the
  ## recorded stream from any point (or from the start; the state is
  ## reconstructible from the log, §13.2) and resume stepping.
  result = initEventGenState()
  for r in recs:
    let (s2, _) = step(result, r)
    result = s2

proc eventsOfRecords*(recs: seq[Record]): seq[string] =
  ## The replay path's event production: the single judgment function
  ## folded over the recorded stream in seq order, then the
  ## end-of-stream judgment, as canonical HCJ lines in judgment order.
  var s = initEventGenState()
  for r in recs:
    let (s2, evs) = step(s, r)
    s = s2
    for f in evs:
      result.add(eventLine(f))
  for f in finish(s):
    result.add(eventLine(f))
