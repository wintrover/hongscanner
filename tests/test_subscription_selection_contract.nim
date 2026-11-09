## subscription selection contract tests (PR-A, REPLAY_CONTRACT §12.1,
## policy kiwoom_response_order_first_100_v1): the deterministic
## top-100-per-direction selection between candidate derivation
## (vendor_input) and REG composition (composeRegData), the collector's
## subscription_truncated gaps on every REG path (initial, market-ack
## restart, swap, poll restart), the SUBSCRIPTION_TRUNCATED event
## judgment (event_gen, the rest-truncated mirror), the recorded config
## selection_policy, and the end-to-end stream: same raw REST in, same
## selection and same events out; the candidate event universe stays the
## FULL recorded IN-SCOPE universe (selection exclusions are recorded,
## never judged away; out-of-shape rows are partitioned out of the
## universe at derivation — the 2026-11-09 ELW incident fix — and stay
## preserved in the raw bytes);
## verify MATCH. No network, no wall clock, no credentials.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_subscription_selection_contract.nim
import std/[os, strutils, tempfiles]
import hs/[hcj, digest, records, calendars, engine, replay, verify, binfo,
           sub_input, vendor_input, event_gen, collector, recorder]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

# ---------------------------------------------------------------- builders

const ts = "2026-10-29T09:00:00+09:00"

proc day(o, c: string): HcjValue =
  hObj(("close", hStr(c)), ("open", hStr(o)))

proc calRaw(): HcjValue =
  hObj(("days", hObj(
    ("2026-10-29", day("09:00:00+09:00", "15:30:00+09:00")))))

proc newCollector(): Collector =
  startCollector(initCollectorConfig(
    "2026-10-29", "demo", "demo-profile",
    "000", "0000", "0", "0", "1", "0", "0", "1",
    Params(warmupBars: 0, lookbackBars: 3, trendMinBp: 50,
           countermoveMinBp: 50, directionalTriggerBp: 30,
           holdOnDegraded: true),
    calRaw()))

proc hexOf(s: string): string =
  const digits = "0123456789abcdef"
  for c in s:
    result.add(digits[int(ord(c)) shr 4])
    result.add(digits[int(ord(c)) and 0x0f])

proc ev(name, t: string; rest: varargs[HcjPair]): string =
  var ps: seq[HcjPair] = @[("ev", hStr(name)), ("t", hStr(t))]
  for p in rest: ps.add(p)
  canonical(hObj(ps))

proc evWs(conn: int; payload: string; t = ts): string =
  ev("ws", t, ("conn", hInt(conn)), ("payload_hex", hStr(hexOf(payload))))

proc evRest(direction: string; page: int; status: int; contYn, nextKey: string;
            body: string; t = ts): string =
  ev("rest", t, ("body_hex", hStr(hexOf(body))), ("cont_yn", hStr(contYn)),
     ("direction", hStr(direction)), ("page", hInt(page)),
     ("status", hInt(status)), ("next_key", hStr(nextKey)))

proc ackPayload(trnm = "REG"; code = 0): string =
  "{\"return_code\":" & $code & ",\"return_msg\":\"\",\"trnm\":\"" &
    trnm & "\"}"

proc tick0B(item = "005930"; t20 = "090500"; price = "10000";
            cum = "100"): string =
  "{\"trnm\":\"REAL\",\"data\":[{\"item\":\"" & item & "\",\"name\":\"" &
    "주식체결\",\"type\":\"0B\",\"values\":{\"10\":\"" & price &
    "\",\"13\":\"" & cum & "\",\"15\":\"+1\",\"20\":\"" & t20 &
    "\",\"25\":\"2\",\"290\":\"2\"}}]}"

proc state0S(value215 = "4"; t20 = "153000"): string =
  "{\"trnm\":\"REAL\",\"data\":[{\"item\":\"\",\"name\":\"장시작시간\"," &
    "\"type\":\"0s\",\"values\":{\"20\":\"" & t20 & "\",\"215\":\"" &
    value215 & "\",\"214\":\"000000\"}}]}"

proc restBody(codes: openArray[string]): string =
  var rows: seq[string]
  for c in codes:
    rows.add("[\"1\",\"" & c & "\",\"name\",\"10000\",\"2\",\"1\",\"1.0\"," &
             "\"100\",\"200\",\"50\",\"+\",\"1\"]")
  "{\"pred_pre_flu_rt_upper\":[" & rows.join(",") & "],\"return_code\":0," &
    "\"return_msg\":\"\"}"

proc step(c: var Collector; line: string): (seq[RecOut], seq[Directive]) =
  var recs: seq[RecOut]
  let dirs = c.handleEvent(line, recs)
  (recs, dirs)

proc kinds(recs: seq[RecOut]): seq[string] =
  for r in recs: result.add(kindName(r.kind))

proc dirKinds(dirs: seq[Directive]): seq[string] =
  for d in dirs:
    result.add(case d.kind
               of dkConnect: "connect"
               of dkReg: "reg"
               of dkRemove: "remove"
               of dkRestReq: "rest_req"
               of dkRefreshToken: "refresh_token"
               of dkDisarm: "disarm"
               of dkWaitDrain: "wait_drain"
               of dkStop: "stop")

proc codesOf(n, base: int): seq[string] =
  ## n unique 6-digit codes base+1 .. base+n, in this (vendor) order.
  for i in 1 .. n: result.add($(base + i))

proc detailToken(raw: HcjValue): string =
  raw.get("detail").strVal

proc bigSession(): seq[RecOut] =
  ## A canned session whose initial chains carry 149 up and 120 down
  ## candidates (both terminal), three ticks (one on an EXCLUDED code),
  ## close evidence and teardown. Returns every record, in write order.
  let ups = codesOf(149, 100000)
  let downs = codesOf(120, 300000)
  var c = newCollector()
  var outp = c.cfg.preambleRecords()
  proc feed(line: string) =
    var recs: seq[RecOut]
    discard c.handleEvent(line, recs)
    for r in recs: outp.add(r)
  feed(ev("ready", ts))
  feed(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  feed(evWs(1, ackPayload()))
  feed(evRest("up", 1, 200, "Y", "k1", restBody(ups[0 ..< 100])))
  feed(evRest("up", 2, 200, "N", "", restBody(ups[100 ..< 149])))
  feed(evRest("down", 1, 200, "Y", "k1", restBody(downs[0 ..< 100])))
  feed(evRest("down", 2, 200, "N", "", restBody(downs[100 ..< 120])))
  feed(evWs(1, ackPayload()))
  feed(evWs(1, tick0B(item = "100001", t20 = "090500")))
  feed(evWs(1, tick0B(item = "100120", t20 = "090600")))
  feed(evWs(1, tick0B(item = "300001", t20 = "090700")))
  feed(evWs(1, state0S(value215 = "4")))
  feed(evWs(1, ackPayload(trnm = "REMOVE", code = 0)))
  return outp

proc sealStream(recs: seq[RecOut]): string =
  ## Write the records through the real Recorder protocol into a fresh
  ## temp run directory; returns the directory.
  let dir = createTempDir("hs-subsell-", "")
  var r = openRecorder(dir / inputFile)
  for p in recs:
    discard r.append(p.kind, p.raw)
  discard r.finish()
  dir

proc replayOf(dir: string): CoreResult =
  runCore(loadRecords(dir / inputFile))

proc verifyOf(dir: string): VerifyResult =
  verifyRun(dir, BuildInfo(codeCommit: "fixture", sourceRef: "main",
    originMainSha: "fixture", dirty: false, nimVersion: NimVersion,
    buildTime: "fixture"))

proc writeRunOf(dir: string; res: CoreResult): string =
  let runDir = createTempDir("hs-subsell-run-", "")
  discard writeRun(runDir, dir / inputFile, res, BuildInfo(
    codeCommit: "fixture", sourceRef: "main", originMainSha: "fixture",
    dirty: false, nimVersion: NimVersion, buildTime: "fixture"))
  # The COMMITTED marker the recorder's finish() writes next to the log,
  # recomputed from the copied artifact's actual bytes.
  let input = runDir / inputFile
  let marker = hObj(("run_id", hStr(lastPathPart(parentDir(input)))),
                    ("schema", hStr(commitMarkerSchema)),
                    ("seq", hInt(loadRecords(input).len)),
                    ("sha256", hStr(sha256Hex(readFile(input)))),
                    ("t", hStr(ts)))
  writeFile(input & ".committed", canonical(marker) & "\n")
  runDir

proc countType(res: CoreResult; typ: string): int =
  for e in res.events:
    if "\"event_type\":\"" & typ & "\"" in e: inc result

# ------------------------------------------------------------ selection unit

block selectionUnit:
  let ups = codesOf(149, 100000)
  let downs = codesOf(120, 300000)
  let sel = selectTopPerDirection(UpDownCandidates(up: ups, down: downs))
  check("selection: the kept sets are exactly the first 100 codes in " &
        "vendor response order (never re-ranked)",
        sel.selected.up == ups[0 ..< 100] and
        sel.selected.down == downs[0 ..< 100])
  check("selection: the up facts carry the confirmed counts " &
        "(149 -> 100, 49 excluded)",
        sel.facts[0].direction == "up" and
        sel.facts[0].candidateCount == 149 and
        sel.facts[0].selectedCount == 100 and
        sel.facts[0].excludedCount == 49)
  check("selection: the down facts carry the confirmed counts " &
        "(120 -> 100, 20 excluded)",
        sel.facts[1].direction == "down" and
        sel.facts[1].candidateCount == 120 and
        sel.facts[1].selectedCount == 100 and
        sel.facts[1].excludedCount == 20)
  # A deterministic non-monotonic vendor order (37 is coprime to 149, so
  # (i*37 mod 149) is a bijection): the prefix is kept verbatim.
  var scrambled: seq[string]
  for i in 0 ..< 149:
    scrambled.add($(100000 + (i * 37) mod 149 + 1))
  let selS = selectTopPerDirection(UpDownCandidates(up: scrambled, down: @[]))
  check("selection: arrival order is the only ranking — a scrambled " &
        "response order is kept verbatim, no field is parsed",
        selS.selected.up == scrambled[0 ..< 100] and
        selS.facts[0].candidateCount == 149 and
        selS.facts[0].excludedCount == 49)
  let selSmall = selectTopPerDirection(UpDownCandidates(
    up: codesOf(37, 100000), down: codesOf(5, 300000)))
  check("selection: at or below the cap every candidate is kept and no " &
        "direction excludes",
        selSmall.selected.up.len == 37 and selSmall.selected.down.len == 5 and
        selSmall.facts[0].excludedCount == 0 and
        selSmall.facts[1].excludedCount == 0)
  let selB = selectTopPerDirection(UpDownCandidates(
    up: codesOf(100, 100000), down: codesOf(101, 300000)))
  check("selection: exactly 100 stays whole and 101 excludes exactly one",
        selB.selected.up.len == 100 and selB.facts[0].excludedCount == 0 and
        selB.selected.down.len == 100 and selB.facts[1].excludedCount == 1)
  check("selection: deterministic — same candidates, same selection",
        sel == selectTopPerDirection(UpDownCandidates(up: ups, down: downs)))
  let selEmpty = selectTopPerDirection(UpDownCandidates())
  check("selection: an empty universe selects nothing and excludes nothing",
        selEmpty.selected.up.len == 0 and selEmpty.selected.down.len == 0 and
        selEmpty.facts[0].excludedCount == 0 and
        selEmpty.facts[1].excludedCount == 0)
  let scopeC = UpDownCandidates(
    up: codesOf(50, 100000), down: codesOf(5, 300000),
    upExcluded: @["18064K", "0147B0"], downExcluded: @["0088M0"])
  let selScope = selectTopPerDirection(scopeC)
  check("selection: out-of-shape rows are not candidates — below the cap " &
        "everything in-scope is kept and the facts count the scope " &
        "exclusion separately from the selection exclusion",
        selScope.selected.up == codesOf(50, 100000) and
        selScope.selected.down == codesOf(5, 300000) and
        selScope.facts[0].candidateCount == 50 and
        selScope.facts[0].excludedCount == 0 and
        selScope.facts[0].scopeExcludedCount == 2 and
        selScope.facts[1].scopeExcludedCount == 1)
  var composed = false
  try:
    discard composeRegData(sel.selected.up, sel.selected.down)
    composed = true
  except SubInputError:
    discard
  check("selection: the selected 100+100 composes inside the notice #49 " &
        "caps", composed)
  var refused = false
  try:
    discard composeRegData(codesOf(101, 100000), @[])
  except SubInputError as e:
    refused = e.failure == vfContract and
      "up direction exceeds the subscription cap" in e.msg
  check("defense: 101 codes handed straight to composeRegData still " &
        "raise — the checks are unchanged by the selection", refused)
  var crossRaised = false
  try:
    discard composeRegData(@["005930"], @["005930"])
  except SubInputError as e:
    crossRaised = "duplicate code" in e.msg
  check("defense: a code in BOTH directions is still a SubInputError " &
        "rejection (fail-closed, no auto-dedup)", crossRaised)

# ------------------------------------------------- collector: initial path

block collectorInitialSelection:
  let ups = codesOf(149, 100000)
  let downs = codesOf(120, 300000)
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "Y", "k1", restBody(ups[0 ..< 100])))
  discard c.step(evRest("up", 2, 200, "N", "", restBody(ups[100 ..< 149])))
  discard c.step(evRest("down", 1, 200, "Y", "k1", restBody(downs[0 ..< 100])))
  var recs: seq[RecOut]
  var dirs: seq[Directive]
  (recs, dirs) = c.step(evRest("down", 2, 200, "N", "",
                               restBody(downs[100 ..< 120])))
  check("initial: the completing step records the page, both exclusion " &
        "gaps and the selected REG request",
        recs.kinds() == @["rest_resp", "gap", "gap", "sub"])
  check("initial: the up gap names the policy, the direction and the " &
        "confirmed counts",
        recs[1].raw.get("what").strVal == "subscription_truncated" and
        "selection policy kiwoom_response_order_first_100_v1" in
          detailToken(recs[1].raw) and
        "direction=up" in detailToken(recs[1].raw) and
        "candidate_count=149" in detailToken(recs[1].raw) and
        "selected_count=100" in detailToken(recs[1].raw) and
        "excluded_count=49" in detailToken(recs[1].raw) and
        "remaining_unverified_pages=false" in detailToken(recs[1].raw))
  check("initial: the down gap carries its direction and counts",
        recs[2].raw.get("what").strVal == "subscription_truncated" and
        "direction=down" in detailToken(recs[2].raw) and
        "candidate_count=120" in detailToken(recs[2].raw) and
        "selected_count=100" in detailToken(recs[2].raw) and
        "excluded_count=20" in detailToken(recs[2].raw))
  check("initial: the exclusion gap is connection-wide (symbol null)",
        recs[1].raw.get("symbol").kind == hkNull)
  check("initial: the REG directive carries exactly the selected 100+100 " &
        "in vendor order",
        dirs.dirKinds() == @["reg"] and dirs[0].data.len == 1 and
        dirs[0].data[0].typ == "0B" and
        dirs[0].data[0].codes == ups[0 ..< 100] & downs[0 ..< 100])
  check("initial: candPending itself holds the selection — every later " &
        "compose path sees the selected sets",
        c.candPending.up == ups[0 ..< 100] and
        c.candPending.down == downs[0 ..< 100] and
        c.awaiting == awCandReg and c.candidatesKnown)

# -------------------------- collector: out-of-shape codes (2026-11-09 fix)

block scopeExclusionLive:
  ## The 2026-11-09 demo session death, reproduced: the up ranking's very
  ## first row is the ELW "18064K" (flu_rt +29.90 — inside any top-N
  ## selection). The pre-fix collector raised "candidate code is not a
  ## 6-digit code" at REG composition and exited fail-closed (run
  ## fidelity-2026-11-09-demo-v2, COLLECTOR_EXIT=2). The contract fix:
  ## derivation partitions out-of-shape rows out of the candidate
  ## universe, so the session survives, the REG carries only
  ## candidate-shaped codes, and the gap fact carries the scope count.
  let ups = @["18064K"] & codesOf(149, 100000)
  let downs = codesOf(120, 300000)
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "Y", "k1", restBody(ups[0 ..< 100])))
  discard c.step(evRest("up", 2, 200, "N", "", restBody(ups[100 ..< 150])))
  discard c.step(evRest("down", 1, 200, "Y", "k1", restBody(downs[0 ..< 100])))
  var recs: seq[RecOut]
  var dirs: seq[Directive]
  (recs, dirs) = c.step(evRest("down", 2, 200, "N", "",
                               restBody(downs[100 ..< 120])))
  check("scope: the mixed ranking completes — page, gaps, REG, no rejection",
        recs.kinds() == @["rest_resp", "gap", "gap", "sub"])
  check("scope: the up gap counts 149 in-scope candidates and the 1 " &
        "out-of-shape row separately",
        "direction=up" in detailToken(recs[1].raw) and
        "candidate_count=149" in detailToken(recs[1].raw) and
        "selected_count=100" in detailToken(recs[1].raw) and
        "excluded_count=49" in detailToken(recs[1].raw) and
        "scope_excluded_count=1" in detailToken(recs[1].raw))
  check("scope: the down gap carries a zero scope count (uniform detail)",
        "direction=down" in detailToken(recs[2].raw) and
        "candidate_count=120" in detailToken(recs[2].raw) and
        "scope_excluded_count=0" in detailToken(recs[2].raw))
  check("scope: the REG carries only candidate-shaped codes — the ELW " &
        "never reaches composition",
        dirs.dirKinds() == @["reg"] and dirs[0].data[0].codes ==
          codesOf(149, 100000)[0 ..< 100] & downs[0 ..< 100])

# ----------------------------------------------- collector: below the cap

block noExclusionBelowCap:
  var c = newCollector()
  var outp = c.cfg.preambleRecords()
  proc feed(line: string) =
    var recs: seq[RecOut]
    discard c.handleEvent(line, recs)
    for r in recs: outp.add(r)
  feed(ev("ready", ts))
  feed(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  feed(evWs(1, ackPayload()))
  feed(evRest("up", 1, 200, "N", "", restBody(codesOf(3, 100000))))
  feed(evRest("down", 1, 200, "N", "", restBody(codesOf(2, 300000))))
  feed(evWs(1, ackPayload()))
  var sawSelectionGap = false
  for r in outp:
    if r.kind == kGap and r.raw.get("what").strVal == "subscription_truncated":
      sawSelectionGap = true
  check("below the cap: no subscription_truncated gap anywhere in the " &
        "whole session", not sawSelectionGap)
  var regCodes = ""
  for r in outp:
    if r.kind == kSub and r.raw.get("action").strVal == "reg" and
       r.raw.get("phase").strVal == "req":
      let tys = r.raw.get("types")
      if tys.kind == hkArr and tys.items.len == 1 and
         tys.items[0].strVal == "0B":
        for cv in r.raw.get("codes").items:
          if regCodes.len > 0: regCodes.add(",")
          regCodes.add(cv.strVal)
  check("below the cap: the REG carries every candidate (3 up then 2 " &
        "down, vendor order) — no gap, no event",
        regCodes == "100001,100002,100003,300001,300002")

# --------------------------- collector: page-cap truncation + selection

block truncatedAndSelection:
  let downs = codesOf(110, 300000)
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(codesOf(3, 100000))))
  var recs: seq[RecOut]
  var dirs: seq[Directive]
  for page in 1 .. 10:
    (recs, dirs) = c.step(evRest("down", page, 200, "Y", "k" & $page,
                                 restBody(downs[(page - 1) * 11 ..<
                                            page * 11])))
  check("truncated leg: the cap page records rest_truncated first, then " &
        "the selection gap, then the selected REG request",
        recs.kinds() == @["rest_resp", "gap", "gap", "sub"] and
        recs[1].raw.get("what").strVal == "rest_truncated" and
        recs[2].raw.get("what").strVal == "subscription_truncated")
  check("truncated leg: the down gap counts only the CONFIRMED candidates " &
        "(110 — never an estimate of the unfetched remainder) and names " &
        "the unverified pages",
        "direction=down" in detailToken(recs[2].raw) and
        "candidate_count=110" in detailToken(recs[2].raw) and
        "selected_count=100" in detailToken(recs[2].raw) and
        "excluded_count=10" in detailToken(recs[2].raw) and
        "remaining_unverified_pages=true" in detailToken(recs[2].raw))
  check("truncated leg: the fully-fetched up leg fires no selection gap " &
        "(only directions that excluded fire)",
        "direction=up" notin detailToken(recs[2].raw))
  check("truncated leg: the REG carries the 3 up candidates and the " &
        "first 100 down codes",
        dirs.dirKinds() == @["reg"] and dirs[0].data[0].codes ==
          codesOf(3, 100000) & downs[0 ..< 100] and
        c.awaiting == awCandReg and not c.incomplete)

# --------------------------------------- collector: market-ack restart path

block marketAckRestart:
  let ups = codesOf(149, 100000)
  let downs = codesOf(120, 300000)
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "Y", "k1", restBody(ups[0 ..< 100])))
  discard c.step(evRest("up", 2, 200, "N", "", restBody(ups[100 ..< 149])))
  discard c.step(evRest("down", 1, 200, "Y", "k1", restBody(downs[0 ..< 100])))
  discard c.step(evRest("down", 2, 200, "N", "", restBody(downs[100 ..< 120])))
  # The candidate REG awaits its ack; the connection dies and a new one
  # opens: the market-state REG restarts, and its ack must compose the
  # SELECTED sets — the raw 149-code universe would raise SubInputError.
  discard c.step(ev("conn", ts, ("conn", hInt(1)),
                     ("state", hStr("closed_ok"))))
  discard c.step(ev("conn", ts, ("conn", hInt(2)), ("state", hStr("open"))))
  var raised = false
  var recs: seq[RecOut]
  var dirs: seq[Directive]
  try:
    (recs, dirs) = c.step(evWs(2, ackPayload()))
  except CatchableError:
    raised = true
  check("market-ack restart: the ack composes the selected sets (no raw " &
        "universe reaches composeRegData on the restart path)",
        not raised and dirs.dirKinds() == @["disarm", "reg"] and
        dirs[1].data[0].codes == ups[0 ..< 100] & downs[0 ..< 100])
  check("market-ack restart: the ack step records ws_raw + ack + the " &
        "selected REG request",
        recs.kinds() == @["ws_raw", "sub", "sub"])

# ---------------------------------------------- collector: poll swap path

block pollSwap:
  let ups = codesOf(149, 100000)
  let downs = codesOf(20, 300000)
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(codesOf(3, 100000))))
  discard c.step(evRest("down", 1, 200, "N", "", restBody(codesOf(2, 300000))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(ev("timer", ts, ("kind", hStr("poll"))))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(ups)))
  var recs: seq[RecOut]
  var dirs: seq[Directive]
  (recs, dirs) = c.step(evRest("down", 1, 200, "N", "", restBody(downs)))
  check("poll swap: the poll derive selects too — the up exclusion gap, " &
        "then the REMOVE of the outgoing generation",
        recs.kinds() == @["rest_resp", "gap", "sub"] and
        recs[1].raw.get("what").strVal == "subscription_truncated" and
        recs[2].raw.get("action").strVal == "remove")
  check("poll swap: the up gap counts the confirmed candidates (149 -> " &
        "100) while the 20-candidate down leg fires none",
        "direction=up" in detailToken(recs[1].raw) and
        "candidate_count=149" in detailToken(recs[1].raw) and
        "excluded_count=49" in detailToken(recs[1].raw))
  check("poll swap: the REMOVE names the whole outgoing generation (3+2)",
        dirs.dirKinds() == @["remove"] and
        dirs[0].data[0].codes == codesOf(3, 100000) & codesOf(2, 300000))
  var recs2: seq[RecOut]
  var dirs2: seq[Directive]
  (recs2, dirs2) = c.step(evWs(1, ackPayload(trnm = "REMOVE", code = 0)))
  check("poll swap: the REMOVE ack composes the incoming REG from the " &
        "selected sets (100 up + all 20 down)",
        dirs2.dirKinds() == @["disarm", "reg"] and
        dirs2[1].data[0].codes == ups[0 ..< 100] & downs)

# -------------------------------------------- collector: poll restart path

block pollRestart:
  # An initially EMPTY universe acks an empty 0B REG (registered, no
  # active codes). The next poll derives 149/20: the swap branch finds
  # no active codes and issues the REG directly — the fourth
  # composeRegData path, selected like the others.
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(@[])))
  discard c.step(evRest("down", 1, 200, "N", "", restBody(@[])))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(ev("timer", ts, ("kind", hStr("poll"))))
  let ups = codesOf(149, 100000)
  let downs = codesOf(20, 300000)
  discard c.step(evRest("up", 1, 200, "N", "", restBody(ups)))
  var recs: seq[RecOut]
  var dirs: seq[Directive]
  (recs, dirs) = c.step(evRest("down", 1, 200, "N", "", restBody(downs)))
  check("poll restart: with no active codes the selected REG is issued " &
        "directly (the fourth composeRegData path)",
        recs.kinds() == @["rest_resp", "gap", "sub"] and
        recs[1].raw.get("what").strVal == "subscription_truncated" and
        recs[2].raw.get("action").strVal == "reg" and
        dirs.dirKinds() == @["reg"] and
        dirs[0].data[0].codes == ups[0 ..< 100] & downs)

# ---------------------------------------------------------- event judgment

block eventJudgment:
  let cfgRaw = hObj(("page_cap", hInt(10)),
                    ("session_date", hStr("2026-11-03")))
  let gapRaw = hObj(
    ("detail", hStr("selection policy kiwoom_response_order_first_100_v1: " &
                    "direction=down candidate_count=110 selected_count=100 " &
                    "excluded_count=10 remaining_unverified_pages=true — " &
                    "the excluded codes are excluded from this session's " &
                    "subscription, not absent from the market")),
    ("symbol", hNull()),
    ("t", hStr("2026-11-03T09:00:00+09:00")),
    ("what", hStr("subscription_truncated")))
  let s0 = stateAt(@[Record(seq: 1, kind: kConfig, raw: cfgRaw)])
  let (s1, evs) = step(s0, Record(seq: 2, kind: kGap, raw: gapRaw))
  check("event: the subscription gap judges DATA_GAP_SUSPECTED and " &
        "SUBSCRIPTION_TRUNCATED — the double emission holds",
        evs.len == 2 and evs[0].eventType == "DATA_GAP_SUSPECTED" and
        evs[1].eventType == "SUBSCRIPTION_TRUNCATED")
  check("event: rule_id subscription-truncated-v1 at rule_version 1",
        evs[1].ruleId == "subscription-truncated-v1" and
        evs[1].ruleVersion == 1)
  check("event: HIGH severity, INCOMPLETE data quality",
        evs[1].severity == "HIGH" and evs[1].dataQuality == "INCOMPLETE")
  check("event: the direction comes from the gap detail token; the " &
        "connection-wide gap stays symbol-free",
        evs[1].direction == "DOWN" and evs[1].symbol == "")
  check("event: evidence_ref is the gap record's content hash — one " &
        "record backs both facts",
        evs[1].evidenceRef == sha256Hex(makeRecordLine(2, kGap, gapRaw)) and
        evs[0].evidenceRef == evs[1].evidenceRef)
  check("event: the id follows the x-event-id-rule (wildcard entity, Q=2)",
        evs[1].eventId == eventIdOf("2026-11-03", "SUBSCRIPTION_TRUNCATED",
                                    "subscription-truncated-v1", "*", 2))
  check("event: observed_at is the record's own t, never a clock",
        evs[1].observedAt == "2026-11-03T09:00:00+09:00")
  let line = eventLine(evs[1])
  check("event: the emitted line carries the direction and never the " &
        "counts (counts live in the gap detail only)",
        "\"direction\":\"DOWN\"" in line and
        "candidate_count" notin line and "excluded_count" notin line)
  let restGapRaw = hObj(
    ("detail", hStr("page cap 10 reached while cont-yn=Y (initial down " &
                    "chain): the declared candidate subset is truncated " &
                    "— never success")),
    ("symbol", hNull()),
    ("t", hStr("2026-11-03T09:00:00+09:00")),
    ("what", hStr("rest_truncated")))
  let (s2, evsRest) = step(s1, Record(seq: 3, kind: kGap, raw: restGapRaw))
  check("event: a rest_truncated gap still judges REST_TRUNCATED — not " &
        "SUBSCRIPTION_TRUNCATED",
        evsRest.len == 2 and evsRest[1].eventType == "REST_TRUNCATED")
  let bareGapRaw = hObj(
    ("detail", hStr("subscription truncated without the pinned token")),
    ("symbol", hNull()),
    ("t", hStr("2026-11-03T09:00:00+09:00")),
    ("what", hStr("subscription_truncated")))
  let (s3, evsBare) = step(s2, Record(seq: 4, kind: kGap, raw: bareGapRaw))
  check("event: a detail without the direction token leaves the " &
        "optional direction absent (never guessed)",
        evsBare.len == 2 and
        evsBare[1].eventType == "SUBSCRIPTION_TRUNCATED" and
        evsBare[1].direction == "" and
        "\"direction\"" notin eventLine(evsBare[1]))
  let recsAll = @[Record(seq: 1, kind: kConfig, raw: cfgRaw),
                  Record(seq: 2, kind: kGap, raw: gapRaw)]
  check("event: the same records fold to the same lines twice",
        eventsOfRecords(recsAll) == eventsOfRecords(recsAll))
  discard s3

# ------------------------------------------------------------ config record

block configRecord:
  let pre = newCollector().cfg.preambleRecords()
  let cfgCanonical = canonical(pre[1].raw)
  check("config: the recorded config carries the selection policy",
        "\"selection_policy\":\"kiwoom_response_order_first_100_v1\"" in
          cfgCanonical)
  check("config: the recorded config still parses for replay",
        parseConfig(pre[1].raw).sessionDate == "2026-10-29" and
        parseConfig(pre[1].raw).pageCap == 10)

# ------------------------------------------------------- the full run (e2e)

block fullRun:
  let dir = sealStream(bigSession())
  let recs = loadRecords(dir / inputFile)
  let res = replayOf(dir)
  check("stream: the full big-universe session replays OK",
        res.status == rsOk)
  var regCodes: seq[string]
  for r in recs:
    if r.kind == kSub and r.raw.get("action").strVal == "reg" and
       r.raw.get("phase").strVal == "req":
      let tys = r.raw.get("types")
      if tys.kind == hkArr and tys.items.len == 1 and
         tys.items[0].strVal == "0B":
        for cv in r.raw.get("codes").items: regCodes.add(cv.strVal)
  check("stream: the 0B REG req carries exactly the selected 200 codes " &
        "in vendor order — the excluded 100120 is not subscribed",
        regCodes == codesOf(149, 100000)[0 ..< 100] &
          codesOf(120, 300000)[0 ..< 100] and
        "100120" notin regCodes and regCodes.len == 200)
  check("stream: the declared page chains verified",
        res.restVerified == 4)
  check("stream: the subscribed ticks built two bars (selected codes only)",
        res.bars.len == 2 and res.bars[0].symbol == "100001" and
        res.bars[1].symbol == "300001")
  check("stream: the tick of the EXCLUDED candidate is quarantined, " &
        "not consumed",
        res.quarantined == 1 and
        res.quarantineNotes[0].startsWith("unsubscribed") and
        "100120" in res.quarantineNotes[0])
  check("stream: the candidate events are the FULL recorded universe " &
        "(149 up + 120 down — selection never filters them)",
        countType(res, "CANDIDATE_ENTERED") == 269)
  var excludedEntered = false
  for e in res.events:
    if "\"event_type\":\"CANDIDATE_ENTERED\"" in e and
       "\"symbol\":\"100120\"" in e and "\"rank\":120" in e:
      excludedEntered = true
  check("stream: the excluded candidate is still judged with its " &
        "universe rank (an exclusion is not an absence)",
        excludedEntered)
  check("stream: both directions judged their SUBSCRIPTION_TRUNCATED fact",
        countType(res, "SUBSCRIPTION_TRUNCATED") == 2)
  var upF = false
  var downF = false
  for e in res.events:
    if "\"event_type\":\"SUBSCRIPTION_TRUNCATED\"" in e:
      if "\"direction\":\"UP\"" in e: upF = true
      if "\"direction\":\"DOWN\"" in e: downF = true
  check("stream: the two facts carry the gap directions UP and DOWN",
        upF and downF)
  check("stream: the only gaps of the session are the two selection " &
        "exclusions",
        countType(res, "DATA_GAP_SUSPECTED") == 2 and
        countType(res, "REST_TRUNCATED") == 0)
  let runDir = writeRunOf(dir, res)
  let v = verifyOf(runDir)
  check("stream: verify declares MATCH on the selected-universe run",
        v.verdict == vMatch and v.matched)

# ---------------------- the full run with out-of-shape rows (e2e, fix)

proc scopeStreamSession(): seq[RecOut] =
  ## The incident's data shape as a full canned session: the up ranking
  ## leads with two out-of-shape rows (the ELW "18064K" and a mock
  ## alphanumeric code) above 149 in-scope codes, the down leg is clean.
  let ups = @["18064K", "0147B0"] & codesOf(149, 100000)
  let downs = codesOf(120, 300000)
  var c = newCollector()
  var outp = c.cfg.preambleRecords()
  proc feed(line: string) =
    var recs: seq[RecOut]
    discard c.handleEvent(line, recs)
    for r in recs: outp.add(r)
  feed(ev("ready", ts))
  feed(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  feed(evWs(1, ackPayload()))
  feed(evRest("up", 1, 200, "Y", "k1", restBody(ups[0 ..< 100])))
  feed(evRest("up", 2, 200, "N", "", restBody(ups[100 ..< 151])))
  feed(evRest("down", 1, 200, "Y", "k1", restBody(downs[0 ..< 100])))
  feed(evRest("down", 2, 200, "N", "", restBody(downs[100 ..< 120])))
  feed(evWs(1, ackPayload()))
  feed(evWs(1, tick0B(item = "100001", t20 = "090500")))
  feed(evWs(1, tick0B(item = "300001", t20 = "090600")))
  feed(evWs(1, state0S(value215 = "4")))
  feed(evWs(1, ackPayload(trnm = "REMOVE", code = 0)))
  outp

block scopeExcludedStream:
  ## End-to-end with the incident's data shape: the recorded stream keeps
  ## the raw pages verbatim (the out-of-shape rows included — the evidence
  ## never lies), replay re-derives the identical partition, the candidate
  ## events judge only the in-scope universe (the ELW is never a
  ## candidate, so never judged), and verify MATCHes the sealed run.
  let dir = sealStream(scopeStreamSession())
  let res = replayOf(dir)
  check("scope stream: the mixed-universe session replays OK",
        res.status == rsOk)
  check("scope stream: the candidate events judge the full recorded " &
        "IN-SCOPE universe (149 up + 120 down — never the out-of-shape " &
        "rows)",
        countType(res, "CANDIDATE_ENTERED") == 269)
  var elwEntered = false
  for e in res.events:
    if "\"event_type\":\"CANDIDATE_ENTERED\"" in e and
       ("\"symbol\":\"18064K\"" in e or "\"symbol\":\"0147B0\"" in e):
      elwEntered = true
  check("scope stream: the out-of-shape rows are never candidate events",
        not elwEntered)
  check("scope stream: the raw evidence keeps the out-of-shape rows " &
        "verbatim (the ELW code stays hex-encoded in the recorded page " &
        "bytes)",
        hexOf("18064K") in readFile(dir / inputFile))
  check("scope stream: both directions judged their SUBSCRIPTION_TRUNCATED " &
        "fact with the scope count in the gap detail",
        countType(res, "SUBSCRIPTION_TRUNCATED") == 2)
  let runDir = writeRunOf(dir, res)
  let v = verifyOf(runDir)
  check("scope stream: verify declares MATCH on the mixed-universe run",
        v.verdict == vMatch and v.matched)
  let dirB = sealStream(scopeStreamSession())
  check("scope stream: deterministic — the same mixed input seals " &
        "byte-identically",
        readFile(dir / inputFile) == readFile(dirB / inputFile))

# ------------------------------------------------------------- determinism

block determinism:
  let dirA = sealStream(bigSession())
  let dirB = sealStream(bigSession())
  check("determinism: the same raw REST input seals byte-identically",
        readFile(dirA / inputFile) == readFile(dirB / inputFile))
  let evA = replayOf(dirA).events
  let evB = replayOf(dirB).events
  check("determinism: the same raw REST input folds to the same events " &
        "(same selection, same facts)",
        evA == evB)

if failures == 0:
  echo "SUBSCRIPTION SELECTION CONTRACT PASSED (", passes, " checks)"
else:
  echo "SUBSCRIPTION SELECTION CONTRACT FAILED: ", failures, " of ",
    passes + failures
  quit(1)
