## Pre-open capture run (P-run) contract tests (REPLAY_CONTRACT §12.10.1).
##
## Synthetic payloads only: no network, no vendor data, no wall clock.
## Covers: the ka10099 rest_resp schema (one market per request, `list[]`,
## symbol field `code`); the per-market cont-yn/next-key chain audit and the
## declared page cap; config.preopen_universe parsing (ka10099 and explicit,
## fully fail-closed) and its mutual exclusion with config.preopen_seed; the
## derived universe (declared market order, page order, row order, dedupe);
## the P-run structural rules (no ws_frame/session_end, manifest exactly
## last); the manifest audit (universe source/order/count/hash/truncation,
## captured/failed set algebra, seed hash, capture window before the open,
## hash forms); and legacy byte-identity when no P-run is declared.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_preopen_capture_contract.nim
import std/[os, strutils, tempfiles, options]
import hs/[hcj, digest, records, replay, rest_resp, vendor_input, verify]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc writeStream(name: string; lines: seq[string]): string =
  result = createTempDir("hs-pcapture-" & name & "-", "")
  var content = ""
  for l in lines: content.add(l & "\n")
  writeFile(result / inputFile, content)

proc runOf(name: string; lines: seq[string]): CoreResult =
  runCore(loadRecords(writeStream(name, lines) / inputFile))

proc coreBytes(lines: seq[string]): string =
  let res = runOf("core", lines)
  for b in res.bars: result.add(barLine(b) & "\n")
  result.add("--\n")
  for s in res.signals: result.add(signalLine(s) & "\n")

proc rejectRun(name, needle: string; lines: seq[string]) =
  var raised = false
  var msg = ""
  try:
    discard runOf("rej", lines)
  except RecordError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)
  if not (raised and needle in msg):
    echo "     got: ", msg

proc rejectConfig(name, needle: string; cfg: HcjValue) =
  var raised = false
  var msg = ""
  try:
    discard parseConfig(cfg)
  except RecordError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)
  if not (raised and needle in msg):
    echo "     got: ", msg

proc rejectVerify(name, needle: string; attempts: seq[RestRespAttempt]) =
  var raised = false
  var msg = ""
  try:
    discard verifyAttempts(attempts, preopenPageCap = 10)
  except RestRespError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)
  if not (raised and needle in msg):
    echo "     got: ", msg

# ---------------------------------------------------------------- builders

proc day(o, c: string): HcjValue =
  hObj(("close", hStr(c)), ("open", hStr(o)))

proc calRaw(): HcjValue =
  hObj(("days", hObj(("2026-10-29",
                      day("09:00:00+09:00", "15:30:00+09:00")))),
       ("version", hStr("CAL-TEST")))

proc cfgRaw(): HcjValue = hObj(("session_date", hStr("2026-10-29")))

proc tickRaw(sym, t: string; price, vol: int64): HcjValue =
  hObj(("m", hStr("2")), ("price", hInt(price)), ("symbol", hStr(sym)),
       ("t", hStr(t)), ("vol", hInt(vol)))

proc sessionLines(): seq[string] =
  @[
    makeRecordLine(1, kCalendar, calRaw()),
    makeRecordLine(2, kConfig, cfgRaw()),
    makeRecordLine(3, kWsFrame, tickRaw("005930", "09:00:00+09:00", 10000, 100)),
    makeRecordLine(4, kWsFrame, tickRaw("005930", "09:03:00+09:00", 10100, 200)),
    makeRecordLine(5, kSessionEnd, hNull())]

proc pairsOfLines(lines: seq[string]): seq[tuple[k: Kind, raw: HcjValue]] =
  for i, l in lines:
    let r = parseRecord(l, i + 1)
    result.add((r.kind, r.raw))

proc linesOf(pairs: seq[tuple[k: Kind, raw: HcjValue]]): seq[string] =
  for i, p in pairs:
    result.add(makeRecordLine(i + 1, p.k, p.raw))

proc strArr(xs: seq[string]): HcjValue =
  var items: seq[HcjValue]
  for x in xs: items.add(hStr(x))
  hArrSeq(items)

proc k99Node(markets: seq[string]; pageCap: int): HcjValue =
  hObj(("market_codes", strArr(markets)), ("page_cap", hInt(pageCap)),
       ("source", hStr("ka10099")))

proc explicitNode(symbols: seq[string]): HcjValue =
  hObj(("source", hStr("explicit")), ("symbols", strArr(symbols)))

proc cfgUniverse(node: HcjValue): HcjValue =
  hObj(("preopen_universe", node), ("session_date", hStr("2026-10-29")))

proc cfgUniverseExtra(node: HcjValue; extra: seq[HcjPair]): HcjValue =
  var pairs: seq[HcjPair] = @[
    ("preopen_universe", node), ("session_date", hStr("2026-10-29"))]
  for p in extra: pairs.add(p)
  HcjValue(kind: hkObj, pairs: pairs)

proc setKey(v: HcjValue; key: string; val: HcjValue) =
  for p in v.pairs.mitems:
    if p.k == key: p.v = val

proc clone(v: HcjValue): HcjValue =
  ## Deep copy: HcjValue is a ref, so a mutated "copy" would otherwise
  ## change every earlier manifest built from the same nodes.
  case v.kind
  of hkNull: result = HcjValue(kind: hkNull)
  of hkBool: result = HcjValue(kind: hkBool, bval: v.bval)
  of hkInt: result = HcjValue(kind: hkInt, ival: v.ival)
  of hkStr: result = HcjValue(kind: hkStr, strVal: v.strVal)
  of hkArr:
    result = HcjValue(kind: hkArr)
    for item in v.items: result.items.add(clone(item))
  of hkObj:
    result = HcjValue(kind: hkObj)
    for p in v.pairs: result.pairs.add((p.k, clone(p.v)))

proc dropKey(v: HcjValue; key: string) =
  var keep: seq[HcjPair]
  for p in v.pairs:
    if p.k != key: keep.add(p)
  v.pairs = keep

proc addKey(v: HcjValue; key: string; val: HcjValue) =
  v.pairs.add((key, val))

# ---------------------------------------------------------------- ka10099

proc marketBody(codes: seq[string]; rowFieldMissing = false): string =
  var rows: seq[HcjValue]
  for cd in codes:
    if rowFieldMissing:
      rows.add(hObj(("name", hStr("name-" & cd))))
    else:
      rows.add(hObj(("code", hStr(cd)), ("name", hStr("name-" & cd))))
  canonical(hObj((ka10099ListKey, hArrSeq(rows)),
                 ("return_code", hInt(0)),
                 ("return_msg", hStr("ok"))))

proc marketAttempt(mrkt: string; body: string; page = 1;
                   contYn = "N"; nextKey = ""): HcjValue =
  hObj(("api_id", hStr(ka10099ApiId)),
       ("body_hex", hStr(hexOfBytes(toBytes(body)))),
       ("cont_yn", hStr(contYn)), ("next_key", hStr(nextKey)),
       ("page", hInt(page)),
       ("query", hObj(("mrkt_tp", hStr(mrkt)))),
       ("status", hInt(200)))

proc marketPage(mrkt: string; codes: seq[string]; page = 1;
                contYn = "N"; nextKey = ""): HcjValue =
  marketAttempt(mrkt, marketBody(codes), page, contYn, nextKey)

## ---------------------------------------------------------------- ka10081

proc dailyRow(dt = "20261028"): HcjValue =
  hArr(hStr("71500"), hStr("150000"), hStr("1074"), hStr(dt),
       hStr("71000"), hStr("72000"), hStr("70500"), hStr("-500"),
       hStr("5"), hStr("0.80"), hStr("1"), hStr("0.00"))

proc dailyBody(stkCd: string): string =
  canonical(hObj((ka10081ListKey, hArrSeq(@[dailyRow()])),
                 ("return_code", hInt(0)),
                 ("return_msg", hStr("ok")),
                 ("stk_cd", hStr(stkCd))))

proc dailyAttempt(stkCd: string): HcjValue =
  hObj(("api_id", hStr(ka10081ApiId)),
       ("body_hex", hStr(hexOfBytes(toBytes(dailyBody(stkCd))))),
       ("cont_yn", hStr("Y")), ("next_key", hStr("cur_prc:20261028")),
       ("page", hInt(1)),
       ("query", hObj(("base_dt", hStr("20261029")),
                      ("stk_cd", hStr(stkCd)),
                      ("upd_stkpc_tp", hStr(declaredDailyUpdStkpcTp)))),
       ("status", hInt(200)))

## ---------------------------------------------------------------- manifest

proc uniHash(symbols: seq[string]): string =
  var text = ""
  for sym in symbols:
    text.add(sym)
    text.add("\n")
  sha256Hex(text)

proc rawLinesHash(raws: seq[HcjValue]): string =
  var text = ""
  for r in raws:
    text.add(canonical(r))
    text.add("\n")
  sha256Hex(text)

proc manifestRaw(source: string; marketCodes, universe, captured,
                 failed: seq[string]; truncated: bool;
                 dailyRaws: seq[HcjValue]): HcjValue =
  hObj(("binary_sha256", hStr(repeat('a', 64))),
       ("capture_failed_count", hInt(failed.len)),
       ("capture_window", hObj(
         ("ended_at", hStr("2026-10-29T08:59:59+09:00")),
         ("started_at", hStr("2026-10-29T08:00:00+09:00")))),
       ("captured_count", hInt(captured.len)),
       ("config_sha256", hStr(repeat('b', 64))),
       ("history_short_count", hInt(0)),
       ("seed_sha256", hStr(rawLinesHash(dailyRaws))),
       ("session_date", hStr("2026-10-29")),
       ("source_run_id", hStr("2026-10-29-preopen")),
       ("universe", hObj(
         ("market_codes", strArr(marketCodes)),
         ("source", hStr(source)),
         ("symbol_count", hInt(universe.len)),
         ("truncated", hBool(truncated)),
         ("universe_sha256", hStr(uniHash(universe))))))

proc gapRaw(sym: string): HcjValue =
  hObj(("detail", hStr("failed")), ("symbol", hStr(sym)),
       ("t", hStr("08:50:00+09:00")),
       ("what", hStr("daily_capture_failed")))

proc pRunPairs(cfg: HcjValue; universeRecs, dailyRecs: seq[HcjValue];
               failed: seq[string]; manifest: HcjValue):
               seq[tuple[k: Kind, raw: HcjValue]] =
  result.add((kCalendar, calRaw()))
  result.add((kConfig, cfg))
  for r in universeRecs: result.add((kRestResp, r))
  for r in dailyRecs: result.add((kRestResp, r))
  for sym in failed: result.add((kGap, gapRaw(sym)))
  result.add((kDailySeedManifest, manifest))

# ------------------------------------------------------- P-run happy path

block pRunHappyPath:
  ## 2 markets, 2 pages on market 0, 3 universe symbols (market 10 repeats
  ## B, which dedupes), 3 affirming ka10081 captures.
  let uniRecs = @[
    marketPage("0", @["005930", "000660"], contYn = "Y", nextKey = "k1"),
    marketPage("0", @["035420"], page = 2),
    marketPage("10", @["000660"])]
  let daily = @[dailyAttempt("005930"), dailyAttempt("000660"),
                dailyAttempt("035420")]
  let dailyRaws = daily
  let manifest = manifestRaw("ka10099", @["0", "10"],
    @["005930", "000660", "035420"], @["005930", "000660", "035420"], @[],
    false, dailyRaws)
  let lines = linesOf(pRunPairs(cfgUniverse(k99Node(@["0", "10"], 2)),
                                uniRecs, daily, @[], manifest))
  let res = runOf("happy", lines)
  check("P-run happy path: 2 markets / 2 pages / 3 symbols verifies",
        res.config.preopenUniverse.isSome and res.restVerified == 6)
  check("P-run status is INCOMPLETE (no session_end seal)",
        res.status == rsIncomplete)
  check("P-run bars/signals stay empty", res.bars.len == 0 and
        res.signals.len == 0)
  # The derived universe is the declared market order, page order, row
  # order, deduped at first appearance.
  let derived = preopenUniverseOf(res.config.preopenUniverse.get,
    @[parseAttempt(3, uniRecs[0]), parseAttempt(4, uniRecs[1]),
      parseAttempt(5, uniRecs[2])])
  check("universe order: market 0 page 1, page 2, then market 10 (B deduped)",
        derived.symbols == @["005930", "000660", "035420"] and
        not derived.truncated)

  # Same stream with one failed capture instead of the third record.
  let failedManifest = manifestRaw("ka10099", @["0", "10"],
    @["005930", "000660", "035420"], @["005930", "000660"], @["035420"],
    false, @[dailyAttempt("005930"), dailyAttempt("000660")])
  let failedLines = linesOf(pRunPairs(cfgUniverse(k99Node(@["0", "10"], 2)),
    uniRecs, @[dailyAttempt("005930"), dailyAttempt("000660")],
    @["035420"], failedManifest))
  let failedRes = runOf("failed", failedLines)
  check("a failed capture is the daily_capture_failed gap and still verifies",
        failedRes.status == rsIncomplete and
        failedRes.config.preopenUniverse.isSome)

# ------------------------------------------------------- truncation rules

block truncation:
  let uniRecs = @[
    marketPage("0", @["005930"], contYn = "Y", nextKey = "k1"),
    marketPage("0", @["000660"], page = 2, contYn = "Y", nextKey = "k2")]
  let daily = @[dailyAttempt("005930"), dailyAttempt("000660")]
  let manifest = manifestRaw("ka10099", @["0"], @["005930", "000660"],
    @["005930", "000660"], @[], true, daily)
  let lines = linesOf(pRunPairs(cfgUniverse(k99Node(@["0"], 2)),
                                uniRecs, daily, @[], manifest))
  let res = runOf("trunc", lines)
  check("a cap-closed Y chain is a declared truncated subset",
        res.status == rsIncomplete and res.restVerified == 4)
  let derived = preopenUniverseOf(res.config.preopenUniverse.get,
    @[parseAttempt(3, uniRecs[0]), parseAttempt(4, uniRecs[1])])
  check("the derived universe records truncated=true",
        derived.truncated and derived.symbols == @["005930", "000660"])

  let mFalse = manifestRaw("ka10099", @["0"], @["005930", "000660"],
    @["005930", "000660"], @[], false, daily)
  rejectRun("manifest truncated=false against a cap-closed chain is REJECT",
    "truncated", linesOf(pRunPairs(cfgUniverse(k99Node(@["0"], 2)),
      uniRecs, daily, @[], mFalse)))

  let belowCap = @[
    marketPage("0", @["005930"], contYn = "Y", nextKey = "k1")]
  let mBelow = manifestRaw("ka10099", @["0"], @["005930"],
    @["005930"], @[], false, @[dailyAttempt("005930")])
  rejectRun("a below-cap cont-yn=Y chain is REJECT, never a subset",
    "missing", linesOf(pRunPairs(cfgUniverse(k99Node(@["0"], 3)),
      belowCap, @[dailyAttempt("005930")], @[], mBelow)))

  let mOver = manifestRaw("ka10099", @["0"], @["005930"],
    @["005930"], @[], false, @[dailyAttempt("005930")])
  rejectRun("a chain beyond the declared page cap is REJECT",
    "cap", linesOf(pRunPairs(cfgUniverse(k99Node(@["0"], 1)),
      @[marketPage("0", @["005930"]),
        marketPage("0", @["000660"], page = 2)], @[dailyAttempt("005930")],
      @[], mOver)))

# ------------------------------------------------------- universe algebra

block manifestUniverse:
  let uniRecs = @[
    marketPage("0", @["005930"]),
    marketPage("10", @["000660"])]
  let daily = @[dailyAttempt("005930"), dailyAttempt("000660")]
  let good = manifestRaw("ka10099", @["0", "10"],
    @["005930", "000660"], @["005930", "000660"], @[], false, daily)
  let base = cfgUniverse(k99Node(@["0", "10"], 2))

  var wrongOrder = clone(good)
  setKey(wrongOrder.get("universe"), "market_codes", strArr(@["10", "0"]))
  rejectRun("manifest market order must equal the declared order",
    "market_codes", linesOf(pRunPairs(base, uniRecs, daily, @[], wrongOrder)))

  var wrongCount = clone(good)
  setKey(wrongCount.get("universe"), "symbol_count", hInt(3))
  rejectRun("manifest symbol_count must equal the derived size",
    "symbol_count", linesOf(pRunPairs(base, uniRecs, daily, @[], wrongCount)))

  var wrongHash = clone(good)
  setKey(wrongHash.get("universe"), "universe_sha256", hStr(repeat('c', 64)))
  rejectRun("manifest universe_sha256 must match the declared framing",
    "universe_sha256", linesOf(pRunPairs(base, uniRecs, daily, @[], wrongHash)))

  var wrongSource = clone(good)
  setKey(wrongSource.get("universe"), "source", hStr("explicit"))
  rejectRun("manifest universe.source must equal the config source",
    "source", linesOf(pRunPairs(base, uniRecs, daily, @[], wrongSource)))

  var wrongCaptured = clone(good)
  setKey(wrongCaptured, "captured_count", hInt(1))
  rejectRun("manifest captured_count must equal the ka10081 record count",
    "captured_count", linesOf(pRunPairs(base, uniRecs, daily, @[],
                                        wrongCaptured)))

  var wrongShort = clone(good)
  setKey(wrongShort, "history_short_count", hInt(3))
  rejectRun("history_short_count above captured_count is REJECT",
    "history_short_count", linesOf(pRunPairs(base, uniRecs, daily, @[],
                                             wrongShort)))

  # captured ∪ failed must cover the universe.
  let mGap = manifestRaw("ka10099", @["0", "10"],
    @["005930", "000660"], @["005930"], @[], false,
    @[dailyAttempt("005930")])
  rejectRun("captured ∪ failed != universe is REJECT",
    "does not equal the universe", linesOf(pRunPairs(base, uniRecs,
      @[dailyAttempt("005930")], @[], mGap)))

  # captured and failed disjoint.
  let mOverlap = manifestRaw("ka10099", @["0", "10"],
    @["005930", "000660"], @["005930"], @["005930"], false,
    @[dailyAttempt("005930")])
  rejectRun("captured ∩ failed must be empty",
    "both captured and failed", linesOf(pRunPairs(base, uniRecs,
      @[dailyAttempt("005930")], @["005930"], mOverlap)))

  # Out-of-universe ka10081 capture.
  let mOut = manifestRaw("ka10099", @["0", "10"],
    @["005930", "000660"], @["005930", "000660"], @[], false, daily)
  rejectRun("a ka10081 capture outside the derived universe is REJECT",
    "outside the declared daily universe",
    linesOf(pRunPairs(base, uniRecs, @[dailyAttempt("999999")], @[], mOut)))

  # Undeclared market.
  let mUndeclared = manifestRaw("ka10099", @["0"], @["005930"],
    @["005930"], @[], false, @[dailyAttempt("005930")])
  rejectRun("a ka10099 market outside market_codes is REJECT",
    "outside the declared preopen_universe.market_codes",
    linesOf(pRunPairs(cfgUniverse(k99Node(@["0"], 2)),
      @[marketPage("30", @["005930"])], @[dailyAttempt("005930")], @[],
      mUndeclared)))

  # Declared market with no chain.
  rejectRun("a declared ka10099 market without a chain is REJECT",
    "has no page chain",
    linesOf(pRunPairs(cfgUniverse(k99Node(@["0", "10"], 2)),
      @[marketPage("0", @["005930"])],
      @[dailyAttempt("005930")], @[], mUndeclared)))

# ------------------------------------------------------- seed hash / shape

block manifestHashAndShape:
  let uniRecs = @[marketPage("0", @["005930"])]
  let daily = @[dailyAttempt("005930")]
  let good = manifestRaw("ka10099", @["0"], @["005930"], @["005930"], @[],
                         false, daily)
  let base = cfgUniverse(k99Node(@["0"], 1))

  var wrongSeed = clone(good)
  setKey(wrongSeed, "seed_sha256", hStr(repeat('d', 64)))
  rejectRun("manifest seed_sha256 must hash canonical(raw)+LF in stream order",
    "seed_sha256", linesOf(pRunPairs(base, uniRecs, daily, @[], wrongSeed)))

  var unknown = clone(good)
  addKey(unknown, "extra", hInt(1))
  rejectRun("an unknown manifest field is REJECT",
    "unknown field", linesOf(pRunPairs(base, uniRecs, daily, @[], unknown)))

  var missing = clone(good)
  dropKey(missing, "captured_count")
  rejectRun("a missing manifest field is REJECT",
    "missing field", linesOf(pRunPairs(base, uniRecs, daily, @[], missing)))

  var badBinary = clone(good)
  setKey(badBinary, "binary_sha256", hStr("ABC"))
  rejectRun("binary_sha256 must be 64 lowercase hex",
    "binary_sha256", linesOf(pRunPairs(base, uniRecs, daily, @[], badBinary)))

  var badConfig = clone(good)
  setKey(badConfig, "config_sha256", hStr(repeat('A', 64)))
  rejectRun("config_sha256 must be 64 lowercase hex",
    "config_sha256", linesOf(pRunPairs(base, uniRecs, daily, @[], badConfig)))

  var emptyRunId = clone(good)
  setKey(emptyRunId, "source_run_id", hStr(""))
  rejectRun("an empty source_run_id is REJECT",
    "source_run_id", linesOf(pRunPairs(base, uniRecs, daily, @[], emptyRunId)))

  var wrongDate = clone(good)
  setKey(wrongDate, "session_date", hStr("2026-10-30"))
  rejectRun("manifest session_date must equal config.session_date",
    "session_date", linesOf(pRunPairs(base, uniRecs, daily, @[], wrongDate)))

  var badUniverseShape = clone(good)
  addKey(badUniverseShape.get("universe"), "extra", hBool(true))
  rejectRun("an unknown universe field is REJECT",
    "universe has an unknown field",
    linesOf(pRunPairs(base, uniRecs, daily, @[], badUniverseShape)))

  # P-run structural rules.
  var withEnd = pRunPairs(base, uniRecs, daily, @[], good)
  withEnd.add((kSessionEnd, hNull()))
  rejectRun("a P-run session_end is REJECT", "session_end",
    linesOf(withEnd))

  var withTick = pRunPairs(base, uniRecs, daily, @[], good)
  withTick.insert((kWsFrame, tickRaw("005930", "09:00:00+09:00", 10000, 100)), 2)
  rejectRun("a P-run ws_frame is REJECT", "ws_frame", linesOf(withTick))

  var noManifest = pRunPairs(base, uniRecs, daily, @[], good)
  noManifest.setLen(noManifest.len - 1)
  rejectRun("a P-run without the manifest is REJECT",
    "P-run seal is not the last record", linesOf(noManifest))

  var notLast = pRunPairs(base, uniRecs, daily, @[], good)
  notLast.add((kGap, gapRaw("005930")))
  rejectRun("a manifest that is not the last record is REJECT",
    "not the last record", linesOf(notLast))

# ------------------------------------------------------- capture window

block captureWindow:
  let uniRecs = @[marketPage("0", @["005930"])]
  let daily = @[dailyAttempt("005930")]
  let good = manifestRaw("ka10099", @["0"], @["005930"], @["005930"], @[],
                         false, daily)
  let base = cfgUniverse(k99Node(@["0"], 1))

  proc withWindow(m: HcjValue; start, finish: string): HcjValue =
    result = clone(m)
    setKey(result.get("capture_window"), "started_at", hStr(start))
    setKey(result.get("capture_window"), "ended_at", hStr(finish))

  rejectRun("ended_at at the open is REJECT (strictly before only)",
    "strictly before", linesOf(pRunPairs(base, uniRecs, daily, @[],
      withWindow(good, "2026-10-29T08:00:00+09:00",
                 "2026-10-29T09:00:00+09:00"))))
  rejectRun("ended_at after the open is REJECT", "strictly before",
    linesOf(pRunPairs(base, uniRecs, daily, @[],
      withWindow(good, "2026-10-29T08:00:00+09:00",
                 "2026-10-29T09:00:01+09:00"))))
  rejectRun("a non-KST offset is REJECT", "+09:00",
    linesOf(pRunPairs(base, uniRecs, daily, @[],
      withWindow(good, "2026-10-29T08:00:00+00:00",
                 "2026-10-29T08:59:59+09:00"))))
  rejectRun("a malformed capture time is REJECT", "YYYY-MM-DDTHH:MM:SS+09:00",
    linesOf(pRunPairs(base, uniRecs, daily, @[],
      withWindow(good, "2026-10-29 08:00:00", "2026-10-29T08:59:59+09:00"))))
  rejectRun("started_at after ended_at is REJECT", "after ended_at",
    linesOf(pRunPairs(base, uniRecs, daily, @[],
      withWindow(good, "2026-10-29T08:59:59+09:00",
                 "2026-10-29T08:00:00+09:00"))))
  rejectRun("a capture window on another date is REJECT", "session date",
    linesOf(pRunPairs(base, uniRecs, daily, @[],
      withWindow(good, "2026-10-28T08:00:00+09:00",
                 "2026-10-28T08:59:59+09:00"))))

# ------------------------------------------------------- explicit universe

block explicitUniverse:
  let daily = @[dailyAttempt("005930"), dailyAttempt("000660")]
  let manifest = manifestRaw("explicit", @[], @["005930", "000660"],
    @["005930", "000660"], @[], false, daily)
  let cfg = cfgUniverse(explicitNode(@["005930", "005930", "000660"]))
  let lines = linesOf(pRunPairs(cfg, @[], daily, @[], manifest))
  let res = runOf("explicit", lines)
  check("an explicit P-run dedupes symbols in declared order",
        res.status == rsIncomplete and res.restVerified == 2)
  let derived = preopenUniverseOf(res.config.preopenUniverse.get, @[])
  check("explicit derivation: deduped order, no truncation",
        derived.symbols == @["005930", "000660"] and not derived.truncated)

  rejectRun("an explicit universe carrying a ka10099 capture is REJECT",
    "outside the explicit preopen_universe",
    linesOf(pRunPairs(cfg, @[marketPage("0", @["005930"])], daily, @[],
      manifest)))

  let mMarkets = manifestRaw("explicit", @["0"], @["005930", "000660"],
    @["005930", "000660"], @[], false, daily)
  rejectRun("explicit universe.market_codes must be empty",
    "must be empty", linesOf(pRunPairs(cfg, @[], daily, @[], mMarkets)))

# ------------------------------------------------------- config shapes

block configShapes:
  rejectConfig("preopen_universe must be an object", "not an object",
    cfgUniverse(hArr()))
  rejectConfig("preopen_universe.source must be a string",
    "source is not a string",
    cfgUniverse(hObj(("market_codes", strArr(@["0"])), ("page_cap", hInt(1)),
                     ("source", hInt(1)))))
  rejectConfig("an unknown source is REJECT", "source must be",
    cfgUniverse(hObj(("market_codes", strArr(@["0"])), ("page_cap", hInt(1)),
                     ("source", hStr("ka10100")))))
  rejectConfig("ka10099 unknown field is REJECT", "unknown field",
    cfgUniverse(hObj(("market_codes", strArr(@["0"])), ("page_cap", hInt(1)),
                     ("source", hStr("ka10099")), ("symbols", strArr(@[])))))
  rejectConfig("ka10099 missing page_cap is REJECT", "missing field",
    cfgUniverse(hObj(("market_codes", strArr(@["0"])),
                     ("source", hStr("ka10099")))))
  rejectConfig("ka10099 empty market list is REJECT", "must not be empty",
    cfgUniverse(k99Node(@[], 1)))
  rejectConfig("ka10099 duplicate market is REJECT", "repeats market",
    cfgUniverse(k99Node(@["0", "0"], 1)))
  rejectConfig("ka10099 page_cap below 1 is REJECT", "page_cap must be >= 1",
    cfgUniverse(k99Node(@["0"], 0)))
  rejectConfig("ka10099 page_cap must be an integer",
    "page_cap is not an integer",
    cfgUniverse(hObj(("market_codes", strArr(@["0"])),
                     ("page_cap", hStr("1")),
                     ("source", hStr("ka10099")))))
  rejectConfig("explicit missing symbols is REJECT", "missing field",
    cfgUniverse(hObj(("source", hStr("explicit")))))
  rejectConfig("explicit unknown field is REJECT", "unknown field",
    cfgUniverse(hObj(("source", hStr("explicit")),
                     ("symbols", strArr(@["005930"])),
                     ("page_cap", hInt(1)))))
  rejectConfig("explicit empty symbol list is REJECT", "must not be empty",
    cfgUniverse(explicitNode(@[])))
  rejectConfig("explicit non-string symbol is REJECT", "not a string",
    cfgUniverse(hObj(("source", hStr("explicit")),
                     ("symbols", hArr(hStr("005930"), hInt(1))))))
  let validSeed = hObj(
    ("failed", hArrSeq(@[])),
    ("manifest_sha256", hStr(repeat('d', 64))),
    ("seed_sha256", hStr(repeat('c', 64))),
    ("session_date", hStr("2026-10-29")),
    ("source_run_id", hStr("2026-10-29-preopen")),
    ("symbol_count", hInt(1)))
  rejectConfig("preopen_seed and preopen_universe together are REJECT",
    "never both",
    cfgUniverseExtra(explicitNode(@["005930"]),
      @[("preopen_seed", validSeed)]))

# ------------------------------------------------------- ka10099 schema

block ka10099Schema:
  let a = parseAttempt(3, marketAttempt("0", marketBody(@["005930", "000660"])))
  check("ka10099: parse surfaces the declared market scope",
        a.api == raKa10099 and a.page == 1 and a.scope99.mrktTp == "0")
  check("ka10099: parse preserves the response metadata and body bytes",
        a.resp.apiId == ka10099ApiId and a.resp.status == 200 and
        a.resp.contYn == "N" and a.resp.body == toBytes(
          marketBody(@["005930", "000660"])))
  check("ka10099: the symbol field is `code` (page order preserved)",
        ka10099ChainSymbols(@[a.resp]) == @["005930", "000660"])

  # Positional rows in the documented 14-field order.
  var posRow: seq[HcjValue] = @[]
  for i in 0 ..< ka10099RowFields.len:
    posRow.add(hStr(if i == 0: "005930" else: "v" & $i))
  let posBody = canonical(hObj((ka10099ListKey, hArrSeq(@[hArrSeq(posRow)])),
                               ("return_code", hInt(0))))
  let posA = parseAttempt(3, marketAttempt("0", posBody))
  check("ka10099: a positional row in the documented order parses",
        ka10099ChainSymbols(@[posA.resp]) == @["005930"])

  # Failure classes: the shared acceptance path, unchanged for ka10099.
  let asBad = proc (body: string): RestRespAttempt =
    parseAttempt(3, marketAttempt("0", body))

  let noList = canonical(hObj(("return_code", hInt(0))))
  rejectVerify("ka10099: a success body without list is REJECT", "is missing",
    @[asBad(noList)])
  var badStatusRaw = marketAttempt("0", noList)
  setKey(badStatusRaw, "status", hInt(500))
  rejectVerify("ka10099: transport status 500 is REJECT", "HTTP status",
    @[parseAttempt(3, badStatusRaw)])
  var badCodeRaw = marketAttempt("0", canonical(hObj(
    (ka10099ListKey, hArrSeq(@[])), ("return_code", hInt(1)))))
  rejectVerify("ka10099: vendor return_code != 0 is REJECT", "return_code",
    @[parseAttempt(3, badCodeRaw)])
  var strCodeRaw = marketAttempt("0", canonical(hObj(
    (ka10099ListKey, hArrSeq(@[])), ("return_code", hStr("0")))))
  rejectVerify("ka10099: a numeric-string return_code is not success",
    "not an integer", @[parseAttempt(3, strCodeRaw)])
  var unknownRow = canonical(hObj((ka10099ListKey,
    hArrSeq(@[hObj(("code", hStr("005930")), ("bogus", hStr("x")))])),
    ("return_code", hInt(0))))
  rejectVerify("ka10099: an unknown row field is REJECT",
    "outside the documented schema", @[asBad(unknownRow)])
  rejectVerify("ka10099: a row without code cannot enter the universe",
    "without a non-empty string code",
    @[asBad(marketBody(@["005930"], rowFieldMissing = true))])
  var emptyCodeBody = canonical(hObj((ka10099ListKey,
    hArrSeq(@[hObj(("code", hStr("")))])), ("return_code", hInt(0))))
  rejectVerify("ka10099: an empty code is REJECT", "empty string code",
    @[asBad(emptyCodeBody)])

  # Chain rules: contiguous 1..N, one chain per market.
  let p1 = parseAttempt(3, marketPage("0", @["005930"], contYn = "Y",
                                      nextKey = "k1"))
  let p2 = parseAttempt(4, marketPage("0", @["000660"], page = 2))
  check("ka10099: a contiguous 2-page chain verifies",
        verifyAttempts(@[p1, p2], preopenPageCap = 2).len == 2)
  rejectVerify("ka10099: pages out of order are REJECT", "does not start",
    @[parseAttempt(3, marketPage("0", @["000660"], page = 2)),
      parseAttempt(4, marketPage("0", @["005930"], contYn = "Y"))])
  rejectVerify("ka10099: a page gap is REJECT", "leaves a gap",
    @[p1, parseAttempt(4, marketPage("0", @["000660"], page = 3))])
  rejectVerify("ka10099: a second terminal page is REJECT",
    "terminal", @[p1, p2, parseAttempt(5, marketPage("0", @["035420"],
                                                      page = 3))])
  rejectVerify("ka10099: a page-1 repeat is a restart REJECT", "repeats page 1",
    @[p1, parseAttempt(4, marketPage("0", @["000660"]))])
  let rep = @[p1, parseAttempt(4, marketPage("0", @["000660"]))]
  var raised = false
  try:
    discard verifyAttempts(rep, pollSeconds = 60, preopenPageCap = 2)
  except RestRespError:
    raised = true
  check("ka10099: a repeated market scope is REJECT even under re-poll cadence",
        raised)

  # The declared universe cap is separate from the S-run chain cap.
  let y1 = parseAttempt(3, marketPage("0", @["005930"], contYn = "Y",
                                      nextKey = "k1"))
  let y2 = parseAttempt(4, marketPage("0", @["000660"], page = 2, contYn = "Y",
                                      nextKey = "k2"))
  check("ka10099: preopenPageCap closes a cap-closed chain as a subset",
        verifyAttempts(@[y1, y2], preopenPageCap = 2).len == 2)
  var belowCapRaised = false
  try:
    discard verifyAttempts(@[y1, y2])
  except RestRespError:
    belowCapRaised = true
  check("ka10099: the same chain is REJECT without the P-run declaration",
        belowCapRaised)

  # Query schema.
  var raisedQuery = false
  try:
    discard parseAttempt(3, marketAttempt("", marketBody(@[])))
  except RestRespError:
    raisedQuery = true
  check("ka10099: an empty mrkt_tp is REJECT", raisedQuery)
  var extraQuery = marketAttempt("0", marketBody(@[]))
  setKey(extraQuery, "query", hObj(("mrkt_tp", hStr("0")),
                                   ("page_cap", hInt(1))))
  var extraRaised = false
  try:
    discard parseAttempt(3, extraQuery)
  except RestRespError:
    extraRaised = true
  check("ka10099: an extra query field is REJECT", extraRaised)

# ------------------------------------------------------- legacy identity

block legacyIdentity:
  ## Without config.preopen_universe the 12th kind stays ignored and the
  ## output bytes are unchanged; a normal session is never a P-run.
  let base = sessionLines()
  var ps = pairsOfLines(base)
  let manifest = manifestRaw("explicit", @[], @["005930"], @["005930"], @[],
                             false, @[])
  ps.insert((kDailySeedManifest, manifest), 2)
  let withSeal = linesOf(ps)
  check("legacy: a manifest without preopen_universe is ignored",
        runOf("legacy-seal", withSeal).status == rsOk)
  check("legacy: bars/signals are byte-identical", coreBytes(base) ==
        coreBytes(withSeal))
  let legacy = runOf("legacy", base)
  check("legacy: no preopen declaration, no P-run universe",
        legacy.config.preopenUniverse.isNone and
        legacy.config.preopenSeed.isNone)

echo ""
if failures > 0:
  echo failures, " FAILED, ", passes, " passed"
  quit(1)
echo passes, " passed, 0 failed"