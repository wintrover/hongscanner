## collector stream-level contract tests: a full synthetic sidecar session
## through the collector core, sealed by the real Recorder protocol, then
## replayed and verified end to end (tools/collector/README.md §8/§10,
## docs/REPLAY_CONTRACT.md §12). No network, no wall clock, no credentials.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_collector_stream_contract.nim
import std/[os, strutils, tempfiles]
import hs/[hcj, digest, records, calendars, bars, engine, replay, verify,
           binfo, sub_input, vendor_input, tickwire, subcheck, collector,
           recorder]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

const ts = "2026-10-29T09:00:00+09:00"

# ---------------------------------------------------------------- builders

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

type SessionOpts = tuple[withClose: bool; foreignTick: bool]

proc runSession(opts: SessionOpts): seq[RecOut] =
  ## One full canned session: ready -> conn -> 0s REG/ack -> initial REST
  ## chains -> 0B REG/ack -> candidate ticks -> [close evidence -> teardown
  ## REMOVE/ack]. Returns every record the core wrote, in write order.
  var c = newCollector()
  var outp = c.cfg.preambleRecords()
  proc feed(line: string) =
    var recs: seq[RecOut]
    discard c.handleEvent(line, recs)
    for r in recs: outp.add(r)
  feed(ev("ready", ts))
  feed(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  feed(evWs(1, ackPayload()))
  feed(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  feed(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  feed(evWs(1, ackPayload()))
  feed(evWs(1, tick0B(item = "005930", t20 = "090500", price = "10000",
                      cum = "100")))
  feed(evWs(1, tick0B(item = "000660", t20 = "090600", price = "20000",
                      cum = "200")))
  if opts.foreignTick:
    feed(evWs(1, tick0B(item = "999999", t20 = "090700", price = "30000",
                        cum = "300")))
  if opts.withClose:
    feed(evWs(1, state0S(value215 = "4")))
    feed(evWs(1, ackPayload(trnm = "REMOVE", code = 0)))
  return outp

proc sealStream(recs: seq[RecOut]): (string, int) =
  ## Write the records through the real Recorder protocol (seal + COMMITTED
  ## marker) into a fresh temp run directory; returns (dir, record count).
  let dir = createTempDir("hs-colstream-", "")
  var r = openRecorder(dir / inputFile)
  for p in recs:
    discard r.append(p.kind, p.raw)
  let total = r.finish()
  (dir, total)

proc replayOf(dir: string): CoreResult =
  runCore(loadRecords(dir / inputFile))

proc verifyOf(dir: string): VerifyResult =
  verifyRun(dir, BuildInfo(codeCommit: "fixture", sourceRef: "main",
    originMainSha: "fixture", dirty: false, nimVersion: NimVersion,
    buildTime: "fixture"))

proc writeRunOf(dir: string; res: CoreResult; withMarker = true): string =
  let runDir = createTempDir("hs-colstream-run-", "")
  discard writeRun(runDir, dir / inputFile, res, BuildInfo(
    codeCommit: "fixture", sourceRef: "main", originMainSha: "fixture",
    dirty: false, nimVersion: NimVersion, buildTime: "fixture"))
  if withMarker:
    # The COMMITTED marker the recorder's finish() writes next to the log,
    # recomputed from the copied artifact's actual bytes (an external
    # verifier's view — test_sub_input_contract's writeMarker pattern).
    let input = runDir / inputFile
    let marker = hObj(("run_id", hStr(lastPathPart(parentDir(input)))),
                      ("schema", hStr(commitMarkerSchema)),
                      ("seq", hInt(loadRecords(input).len)),
                      ("sha256", hStr(sha256Hex(readFile(input)))),
                      ("t", hStr(ts)))
    writeFile(input & ".committed", canonical(marker) & "\n")
  runDir

# ------------------------------------------------------------ the full run

block fullRun:
  let (dir, total) = sealStream(runSession(
    (withClose: true, foreignTick: false)))
  let recs = loadRecords(dir / inputFile)
  check("the sealed stream has the seal as its last record",
        isSealed(recs) and recs.len == total)
  let res = replayOf(dir)
  check("the full collector session replays OK", res.status == rsOk)
  check("the two candidate ticks built two bars", res.bars.len == 2)
  check("the bar prices come from the preserved 0B bytes",
        res.bars.len == 2 and
        res.bars[0].symbol == "000660" and res.bars[0].close == 20000 and
        res.bars[1].symbol == "005930" and res.bars[1].close == 10000)
  check("the candidate REG/REMOVE acks and REQs are the sub evidence",
        res.subCount == 6)
  check("every ws payload is preserved as ws_raw evidence",
        res.wsRawCount == 6)
  check("the declared page chains verified", res.restVerified == 2)
  check("nothing was quarantined in the clean session",
        res.quarantined == 0)
  check("the 0B generation was confirmed and torn down",
        res.regAcks0B == 1 and res.removeAcks0B == 1)
  check("the close evidence is re-derived from the 0s bytes",
        res.closeValues == @["4"])

  let runDir = writeRunOf(dir, res)
  let v = verifyOf(runDir)
  check("verify declares MATCH on the sealed collector stream",
        v.verdict == vMatch and v.matched)
  check("the commit marker is VALID", v.commitState == "VALID")
  check("the SUBCHECK line reports the clean quarantine count",
        v.subcheckLine.startsWith("SUBCHECK quarantined=0") and
        "reg_acks_0b=1" in v.subcheckLine and
        "remove_acks_0b=1" in v.subcheckLine and
        "close_values=4" in v.subcheckLine)

# ------------------------------------------- the truncated initial chain

proc runTruncatedSession(): seq[RecOut] =
  ## A full canned session whose initial chains both close at the declared
  ## cap while cont-yn=Y (the live 2026-11-02 shape: the vendor returns
  ## more than the cap in both directions): each cap-closing page records
  ## the rest_truncated gap, the fetched pages still derive and REG, and
  ## the session streams and closes normally.
  var c = newCollector()
  var outp = c.cfg.preambleRecords()
  proc feed(line: string) =
    var recs: seq[RecOut]
    discard c.handleEvent(line, recs)
    for r in recs: outp.add(r)
  feed(ev("ready", ts))
  feed(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  feed(evWs(1, ackPayload()))
  for page in 1 .. 10:
    feed(evRest("up", page, 200, "Y", "k" & $page,
                restBody(@["0059" & align($page, 2, '0')])))
  for page in 1 .. 10:
    feed(evRest("down", page, 200, "Y", "k" & $page,
                restBody(@["0006" & align($page, 2, '0')])))
  feed(evWs(1, ackPayload()))
  feed(evWs(1, tick0B(item = "005901", t20 = "090500", price = "10000",
                      cum = "100")))
  feed(evWs(1, tick0B(item = "000601", t20 = "090600", price = "20000",
                      cum = "200")))
  feed(evWs(1, state0S(value215 = "4")))
  feed(evWs(1, ackPayload(trnm = "REMOVE", code = 0)))
  return outp

block truncatedRun:
  let (dir, total) = sealStream(runTruncatedSession())
  let recs = loadRecords(dir / inputFile)
  check("the sealed truncated session has the seal as its last record",
        isSealed(recs) and recs.len == total)
  var gaps = 0
  for r in recs:
    if r.kind == kGap and r.raw.get("what").strVal == "rest_truncated":
      inc gaps
  check("both cap-closed legs recorded their rest_truncated gap",
        gaps == 2)
  let res = replayOf(dir)
  check("a cap-closed declared truncated subset replays OK (the audit " &
        "accepts the round, never a REJECT)", res.status == rsOk)
  check("the 20 fetched pages all verified", res.restVerified == 20)
  var nTrunc = 0
  var nCand = 0
  for e in res.events:
    if "\"event_type\":\"REST_TRUNCATED\"" in e: inc nTrunc
    if "\"event_type\":\"CANDIDATE_" in e: inc nCand
  check("the two truncation facts are judged REST_TRUNCATED", nTrunc == 2)
  check("a partial universe is never judged into candidate events",
        nCand == 0)
  check("the truncated-subset ticks built two bars", res.bars.len == 2)
  let runDir = writeRunOf(dir, res)
  let v = verifyOf(runDir)
  check("verify declares MATCH on the truncated collector stream",
        v.verdict == vMatch and v.matched)

# ------------------------------------------------- the daily sweep (VS-1)

proc evRestDaily(body: string; status = 200; contYn = "Y";
                 nextKey = "cur_prc:20261028"; t = ts): string =
  ev("rest_daily", t, ("api_id", hStr(ka10081ApiId)),
     ("body_hex", hStr(hexOf(body))), ("cont_yn", hStr(contYn)),
     ("next_key", hStr(nextKey)), ("page", hInt(1)),
     ("status", hInt(status)))

proc dailyBody(stkCd: string): string =
  ## A measured success ka10081 body: return_code 0 + return_msg + the
  ## top-level stk_cd echo + one 12-field positional daily row.
  "{\"return_code\":0,\"return_msg\":\"정상처리되었습니다\",\"stk_cd\":\"" &
    stkCd & "\",\"stk_dt_pole_chart_qry\":[[\"71500\",\"150000\",\"1074\"," &
    "\"20261028\",\"71000\",\"72000\",\"70500\",\"-500\",\"5\",\"0.80\"," &
    "\"1\",\"0.00\"]]}"

proc runDailySession(failSecond: bool): seq[RecOut] =
  ## The full canned session with the VS-1 daily sweep: after the initial
  ## chain pair completes, the collector walks the universe (up rows then
  ## down rows) one ka10081 page per symbol. The first symbol affirms
  ## success (a rest_resp record); the second either affirms too, or fails
  ## (a vendor error body: the daily_capture_failed gap, symbol skipped,
  ## session continues). The session then streams and closes normally.
  var c = newCollector()
  var outp = c.cfg.preambleRecords()
  proc feed(line: string) =
    var recs: seq[RecOut]
    discard c.handleEvent(line, recs)
    for r in recs: outp.add(r)
  feed(ev("ready", ts))
  feed(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  feed(evWs(1, ackPayload()))
  feed(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  feed(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  feed(evWs(1, ackPayload()))     # candidate REG ack; the sweep is in flight
  feed(evRestDaily(dailyBody("005930")))
  if failSecond:
    feed(evRestDaily("{\"return_code\":5,\"return_msg\":\"조회 거부\"}"))
  else:
    feed(evRestDaily(dailyBody("000660")))
  feed(evWs(1, tick0B(item = "005930", t20 = "090500", price = "10000",
                      cum = "100")))
  feed(evWs(1, tick0B(item = "000660", t20 = "090600", price = "20000",
                      cum = "200")))
  feed(evWs(1, state0S(value215 = "4")))
  feed(evWs(1, ackPayload(trnm = "REMOVE", code = 0)))
  return outp

block dailySweepRun:
  let (dir, total) = sealStream(runDailySession(failSecond = false))
  let recs = loadRecords(dir / inputFile)
  check("the sealed daily-sweep session has the seal as its last record",
        isSealed(recs) and recs.len == total)
  var nDaily = 0
  var nSkip = 0
  for r in recs:
    if r.kind == kRestResp and r.raw.get("api_id").strVal == ka10081ApiId:
      inc nDaily
    if r.kind == kGap and r.raw.get("what").strVal == "daily_capture_failed":
      inc nSkip
  check("both universe symbols landed a ka10081 rest_resp record",
        nDaily == 2 and nSkip == 0)
  let res = replayOf(dir)
  check("the daily-sweep session replays OK", res.status == rsOk)
  check("the ka10027 pair and both daily pages verified",
        res.restVerified == 4)
  check("the daily sweep changed no bar derivation", res.bars.len == 2)
  let runDir = writeRunOf(dir, res)
  let v = verifyOf(runDir)
  check("verify declares MATCH on the daily-sweep collector stream",
        v.verdict == vMatch and v.matched)

block dailySweepSkip:
  let (dir, _) = sealStream(runDailySession(failSecond = true))
  let recs = loadRecords(dir / inputFile)
  var nDaily = 0
  var nSkip = 0
  for r in recs:
    if r.kind == kRestResp and r.raw.get("api_id").strVal == ka10081ApiId:
      inc nDaily
    if r.kind == kGap and r.raw.get("what").strVal == "daily_capture_failed":
      inc nSkip
  check("a failed capture is the daily_capture_failed gap, never a rest_resp",
        nDaily == 1 and nSkip == 1)
  let res = replayOf(dir)
  check("the session with one failed capture still replays OK (fail-closed " &
        "per symbol, not per session)", res.status == rsOk)
  check("only the affirming pages verified", res.restVerified == 3)
  let runDir = writeRunOf(dir, res)
  let v = verifyOf(runDir)
  check("verify still declares MATCH with the skipped symbol's gap",
        v.verdict == vMatch and v.matched)

# --------------------------------------------------- the quarantined tick

block quarantined:
  let (dir, _) = sealStream(runSession(
    (withClose: true, foreignTick: true)))
  let res = replayOf(dir)
  check("the session with a foreign tick still replays OK",
        res.status == rsOk)
  check("the foreign tick is quarantined, not consumed",
        res.quarantined == 1 and
        res.quarantineNotes[0].startsWith("unsubscribed") and
        "999999" in res.quarantineNotes[0])
  check("the quarantined tick changed no bar count", res.bars.len == 2)

  let runDir = writeRunOf(dir, res)
  let v = verifyOf(runDir)
  check("quarantine is not a REJECT: verify still declares MATCH",
        v.verdict == vMatch and v.matched)
  check("the SUBCHECK line reports the quarantine",
        "quarantined=1" in v.subcheckLine)

# ------------------------------------------------ close evidence mandatory

block closeEvidenceRequired:
  # A sealed stream that declares an environment must re-derive the
  # minimum close evidence; without the 0s observation it is REJECT.
  let (dir, _) = sealStream(runSession(
    (withClose: false, foreignTick: false)))
  var msg = ""
  try:
    discard replayOf(dir)
  except RecordError as e:
    msg = e.msg
  check("a sealed environment stream without close evidence is REJECT",
        "minimum close evidence" in msg and "environment demo" in msg)

# ------------------------------------------------ mislabeled/garbage reject

block payloadRejects:
  proc sealedWithExtra(payloadHex, channel: string): string =
    var recs = runSession((withClose: true, foreignTick: false))
    let extra: RecOut = (kWsRaw, hObj(("channel", hStr(channel)),
      ("conn", hInt(1)), ("payload_hex", hStr(payloadHex)), ("t", hStr(ts))))
    recs.insert(extra, recs.len - 0)  # before the seal is added by the writer
    let (dir, _) = sealStream(recs)
    dir

  let badChannel = sealedWithExtra(hexOf(tick0B()), "0s")
  var msg = ""
  try:
    discard replayOf(badChannel)
  except RecordError as e:
    msg = e.msg
  check("a mislabeled channel is REJECT with the record named",
        msg.startsWith("ws_raw at seq") and "does not match" in msg)

  let garbage = sealedWithExtra(hexOf("totally not json"), "0B")
  msg = ""
  try:
    discard replayOf(garbage)
  except RecordError as e:
    msg = e.msg
  check("a garbage 0B payload is REJECT at its own seq",
        msg.startsWith("ws_raw at seq") and "is rejected" in msg)

# ------------------------------------------------- sealed without a marker

block markerMissing:
  # Sealed but no COMMITTED marker: an environment-declared stream is
  # INCOMPLETE (durability unconfirmed), never approved.
  let dir = createTempDir("hs-colstream-nomarker-", "")
  var r = openRecorder(dir / inputFile)
  for p in runSession((withClose: true, foreignTick: false)):
    discard r.append(p.kind, p.raw)
  # seal without the marker protocol: append the session_end by hand is
  # forbidden by the recorder — so write the seal through finish() and then
  # remove the marker to model the "durability unconfirmed" state.
  discard r.finish()
  discard tryRemoveFile(dir / inputFile & ".committed")
  let res = replayOf(dir)
  check("the sealed stream still replays OK", res.status == rsOk)
  let runDir = writeRunOf(dir, res, withMarker = false)
  let v = verifyOf(runDir)
  check("a sealed environment stream without a marker is INCOMPLETE",
        v.verdict == vIncomplete and v.commitState == "ABSENT")

if failures == 0:
  echo "COLLECTOR STREAM CONTRACT PASSED (", passes, " checks)"
else:
  echo "COLLECTOR STREAM CONTRACT FAILED: ", failures, " of ",
    passes + failures
  quit(1)
