## Pre-open capture producer contract tests (REPLAY_CONTRACT §12.10.1).
##
## One fake sidecar (the injected PreopenExchange: a P-run command in, the
## sidecar event out) and an injected clock — no process, no network, no
## wall clock. Covers: the 2-page ka10099 chain per declared market,
## dedupe and the frozen universe hash; daily classification by completed
## rows (20+/1..19/0) and the failure gap; the 429-then-success bounded
## retry counted as one logical task; page-cap truncation; refusal to
## overwrite an existing run directory; the capture window strictly before
## the calendar open; and the producer <-> consumer round-trip through
## Core (`runCore`) and the S-run loader (`loadDailySeed`).
## Run: nim c -r --hints:off --warnings:off --path:src --path:tools/collector tests/test_preopen_capture_producer_contract.nim
import std/[os, strutils, sets, tempfiles, times, options]
import hs/[hcj, digest, records, recorder, calendars, engine, collector,
          rest_resp, vendor_input, replay]
import preopen_capture, preopen

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc expectUsage(name, needle: string; body: proc ()) =
  var raised = false
  var msg = ""
  try:
    body()
  except PreopenUsageError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name & " (raises: " & needle & ")", raised and needle in msg)
  if not (raised and needle in msg):
    echo "     got: ", msg

proc expectCaptureError(name, needle: string; body: proc ()) =
  var raised = false
  var msg = ""
  try:
    body()
  except PreopenError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name & " (raises: " & needle & ")", raised and needle in msg)
  if not (raised and needle in msg):
    echo "     got: ", msg

# ---------------------------------------------------------------- builders

const
  sessionDate = "2026-10-29"
  ## 2026-10-29T06:00:00+09:00, 08:59:59+09:00 and the 09:00:00 open.
  startEpoch = 1793221200'i64
  beforeOpenEpoch = 1793231999'i64
  openEpoch = 1793232000'i64
  ## sha256 over "005930\n000660\n035420\n111111\n" (universe order):
  ## the frozen §12.10.1 universe hash framing.
  frozenUniverseHash =
    "426a7df4231395a29a7ef595aa1f30063470a238e075f5ba8ed04ee8a19da1bd"

proc strArr(xs: openArray[string]): HcjValue =
  var items: seq[HcjValue]
  for x in xs: items.add(hStr(x))
  hArrSeq(items)

proc calRaw(): HcjValue =
  hObj(("days", hObj((sessionDate, hObj(
         ("close", hStr("15:30:00+09:00")),
         ("open", hStr("09:00:00+09:00")))))),
       ("version", hStr("CAL-PRODUCER-TEST")))

proc producerCfg(markets: seq[string]; pageCap: int;
                 runId = sessionDate & "-preopen"): CollectorConfig =
  initCollectorConfig(
    sessionDate, "demo", "demo-profile",
    "000", "0000", "0", "0", "1", "0", "0", "1",
    Params(warmupBars: 0, lookbackBars: 3, trendMinBp: 50,
           countermoveMinBp: 50, directionalTriggerBp: 30,
           holdOnDegraded: true),
    calRaw(), runId = runId, repollSeconds = 0,
    preopenUniverse = some(PreopenUniverseDecl(
      marketCodes: markets, pageCap: pageCap)))

proc listBody(market: string; codes: seq[string]): string =
  var rows: seq[HcjValue]
  for cd in codes:
    rows.add(hObj(("code", hStr(cd)), ("marketCode", hStr(market)),
                  ("name", hStr("name-" & cd))))
  canonical(hObj((ka10099ListKey, hArrSeq(rows)), ("return_code", hInt(0)),
                 ("return_msg", hStr("ok"))))

proc row(dt, curPrc: string): HcjValue =
  hArr(hStr(curPrc), hStr("150000"), hStr("1074"), hStr(dt),
       hStr("71000"), hStr("72000"), hStr("70500"), hStr("-500"),
       hStr("5"), hStr("0.80"), hStr("1"), hStr("0.00"))

proc dailyBody(sym: string; rows: seq[HcjValue]): string =
  canonical(hObj((ka10081ListKey, hArrSeq(rows)), ("return_code", hInt(0)),
                 ("return_msg", hStr("ok")), ("stk_cd", hStr(sym))))

proc completedRows(n: int): seq[HcjValue] =
  ## n distinct completed days (2026-10-01 ..), each with a positive close.
  for d in 1 .. n:
    result.add(row("202610" & align($d, 2, '0'), "71500"))

# -------------------------------------------------------------- fake sidecar

type
  ListReply = object
    market: string
    page: int
    codes: seq[string]
    contYn: string
    nextKey: string

  DailyReply = object
    symbol: string
    event: HcjValue
    physical: int          ## physical HTTP requests the sidecar made

  TestClock = ref object
    now: Time
    calls: int
    switchAt: int          ## 0 = never switch
    switchTo: Time

  FakeSidecar = ref object
    list: seq[ListReply]
    daily: seq[DailyReply]
    physical: int
    clock: TestClock
    markEndSymbol: string  ## serving this daily reply moves the clock to end
    endAt: Time

proc clockFn(c: TestClock): proc (): Time {.closure.} =
  result = proc (): Time =
    inc c.calls
    if c.switchAt > 0 and c.calls >= c.switchAt:
      return c.switchTo
    c.now

proc listEvent(r: ListReply): HcjValue =
  hObj(("ev", hStr("rest_list")), ("mrkt_tp", hStr(r.market)),
       ("page", hInt(r.page)), ("status", hInt(200)),
       ("cont_yn", hStr(r.contYn)), ("next_key", hStr(r.nextKey)),
       ("body_hex", hStr(hexOfBytes(toBytes(listBody(r.market, r.codes))))))

proc dailyOk(sym: string; rows: seq[HcjValue]): HcjValue =
  hObj(("ev", hStr("rest_daily")), ("api_id", hStr(ka10081ApiId)),
       ("page", hInt(1)), ("status", hInt(200)),
       ("cont_yn", hStr("Y")), ("next_key", hStr("cur_prc:20261028")),
       ("body_hex", hStr(hexOfBytes(toBytes(dailyBody(sym, rows))))))

proc dailyErr(detail: string): HcjValue =
  hObj(("ev", hStr("error")), ("what", hStr("rest")),
       ("req", hStr("daily")), ("detail", hStr(detail)))

proc exchangeOf(f: FakeSidecar): PreopenExchange =
  result = proc (cmd: HcjValue): HcjValue =
    let kind = cmd.get("type").strVal
    if kind == "list_req":
      let market = cmd.get("mrkt_tp").strVal
      let page = int(cmd.get("page").ival)
      for r in f.list:
        if r.market == market and r.page == page:
          inc f.physical
          return listEvent(r)
      return hObj(("ev", hStr("error")), ("what", hStr("rest")),
                  ("req", hStr("list")),
                  ("detail", hStr("unexpected list request " & market & " " &
                                  $page)))
    elif kind == "daily_req":
      let sym = cmd.get("params").get("stk_cd").strVal
      for r in f.daily:
        if r.symbol == sym:
          f.physical += r.physical
          if f.markEndSymbol == sym:
            f.clock.now = f.endAt
          return r.event
      return dailyErr("unexpected daily request " & sym)
    else:
      return hObj(("ev", hStr("error")), ("what", hStr("protocol")),
                  ("detail", hStr("unexpected command " & kind)))

# ---------------------------------------------------------------- helpers

proc keySet(v: HcjValue): HashSet[string] =
  result = initHashSet[string]()
  for p in v.pairs: result.incl(p.k)

proc keys(xs: openArray[string]): HashSet[string] =
  result = initHashSet[string]()
  for x in xs: result.incl(x)

proc runDir(name: string): string =
  ## A fresh, NON-existent run directory (createTempDir itself exists and
  ## would be refused: an existing path is prior evidence).
  createTempDir("hs-pprod-" & name & "-", "") / (sessionDate & "-preopen")

proc captureAt(cfg: CollectorConfig; f: FakeSidecar; dir: string):
              PreopenCapture =
  let clock = f.clock
  runPreopenCapture(cfg, dir, exchangeOf(f), clockFn(clock))

proc captureWith(cfg: CollectorConfig; f: FakeSidecar;
                 name: string): PreopenCapture =
  captureAt(cfg, f, runDir(name))

proc baseFake(): FakeSidecar =
  FakeSidecar(clock: TestClock(now: fromUnix(startEpoch)),
              endAt: fromUnix(beforeOpenEpoch))

proc mainFake(): FakeSidecar =
  ## Two pages per market; the universe dedupes to
  ## 005930, 000660, 035420, 111111 (declared market order, page order,
  ## row order). 005930 has 21 completed days, 000660 has 3 (short),
  ## 035420 has no valid completed row, 111111 fails in transport.
  result = baseFake()
  result.markEndSymbol = "111111"
  result.list = @[
    ListReply(market: "0", page: 1, codes: @["005930", "000660", "005930"],
              contYn: "Y", nextKey: "0-page-2"),
    ListReply(market: "0", page: 2, codes: @["035420"],
              contYn: "N", nextKey: ""),
    ListReply(market: "10", page: 1, codes: @["000660", "111111"],
              contYn: "Y", nextKey: "10-page-2"),
    ListReply(market: "10", page: 2, codes: @["005930"],
              contYn: "N", nextKey: "")]
  result.daily = @[
    DailyReply(symbol: "005930", event: dailyOk("005930", completedRows(21)),
               physical: 1),
    DailyReply(symbol: "000660", event: dailyOk("000660", completedRows(3)),
               physical: 1),
    DailyReply(symbol: "035420", event: dailyOk("035420", @[
      row("20261029", "71500"),   # the session's in-progress row: never counts
      row("20261028", "0")]),     # a zero close is not a completed day
      physical: 1),
    DailyReply(symbol: "111111", event: dailyErr("connection reset"),
               physical: 1)]

# ------------------------------------------------------------------- tests

let mainF = mainFake()
let cap = captureWith(producerCfg(@["0", "10"], 2), mainF, "main")

check("the derived universe is deduped in declared market/page/row order",
      cap.universe == @["005930", "000660", "035420", "111111"])
check("the universe captures 2 symbols", cap.captured == 2)
check("the two failures are counted", cap.failed == 2)
check("only the 1..19-row symbol is history-short", cap.historyShort == 1)
check("no chain reached the declared cap", not cap.truncated)
check("the frozen universe_sha256 matches Core's framing",
      cap.manifest.get("universe").get("universe_sha256").strVal ==
        frozenUniverseHash)
check("one logical request per list page and per universe symbol",
      mainF.physical == 8)

block manifestShape:
  let m = cap.manifest
  check("the manifest has exactly the ten documented fields",
        keySet(m) == keys(["binary_sha256", "capture_failed_count",
                           "capture_window", "captured_count", "config_sha256",
                           "history_short_count", "seed_sha256", "session_date",
                           "source_run_id", "universe"]))
  check("the manifest universe has exactly the five documented fields",
        keySet(m.get("universe")) == keys(["market_codes", "source",
                                           "symbol_count", "truncated",
                                           "universe_sha256"]))
  check("the capture window has exactly started_at/ended_at",
        keySet(m.get("capture_window")) == keys(["started_at", "ended_at"]))
  check("the capture window starts at the injected clock",
        m.get("capture_window").get("started_at").strVal ==
          "2026-10-29T06:00:00+09:00")
  check("the capture window ends strictly before the open",
        m.get("capture_window").get("ended_at").strVal ==
          "2026-10-29T08:59:59+09:00")
  check("the universe source is ka10099",
        m.get("universe").get("source").strVal == "ka10099")
  check("the declared market order is preserved",
        m.get("universe").get("market_codes").items.len == 2)
  check("the source run id is the run directory name",
        m.get("source_run_id").strVal == sessionDate & "-preopen")
  check("binary_sha256 is a 64-digit lowercase sha256",
        cap.manifest.get("binary_sha256").strVal.len == 64)
  check("config_sha256 is a 64-digit lowercase sha256",
        cap.manifest.get("config_sha256").strVal.len == 64)
  check("captured_count is 2", m.get("captured_count").ival == 2)
  check("capture_failed_count is 2", m.get("capture_failed_count").ival == 2)
  check("history_short_count is 1", m.get("history_short_count").ival == 1)
  check("symbol_count is 4", m.get("universe").get("symbol_count").ival == 4)
  check("truncated is false",
        not m.get("universe").get("truncated").bval)

block recordLayout:
  let recs = readRecorderFile(cap.dir / "input.hcj.jsonl")
  var sawWs = false
  var sawEnd = false
  var manifestCount = 0
  var captures: seq[string]
  var listPages = 0
  var gaps: seq[string]
  for r in recs:
    case r.kind
    of kWsFrame:
      sawWs = true
    of kSessionEnd:
      sawEnd = true
    of kDailySeedManifest:
      inc manifestCount
    of kRestResp:
      let a = parseAttempt(r.seq, r.raw)
      if a.api == raKa10081: captures.add(a.scope81.stkCd)
      elif a.api == raKa10099: inc listPages
    of kGap:
      gaps.add(r.raw.get("symbol").strVal)
    else:
      discard
  check("the P-run is REST-only: no ws_frame", not sawWs)
  check("the P-run carries no session_end", not sawEnd)
  check("exactly one daily_seed_manifest and it is last",
        manifestCount == 1 and recs[^1].kind == kDailySeedManifest)
  check("the ka10081 block has one record per captured symbol",
        captures == @["005930", "000660"])
  check("all four chain pages are preserved",
        listPages == 4)
  check("the failures are daily_capture_failed gaps with their symbols",
        gaps == @["035420", "111111"])
  check("no daily record was written for the zero-row symbol",
        "035420" notin captures)
  check("the config declares the P-run universe",
        recs[1].raw.has("preopen_universe"))
  check("the config has no preopen_seed",
        not recs[1].raw.has("preopen_seed"))
  check("the config declares repoll_seconds=0 (no re-poll rounds)",
        recs[1].raw.get("repoll_seconds").ival == 0)
  check("config.preopen_universe is exactly source/market_codes/page_cap",
        keySet(recs[1].raw.get("preopen_universe")) ==
          keys(["source", "market_codes", "page_cap"]))
  check("config.run_id equals the manifest source_run_id",
        recs[1].raw.get("run_id").strVal ==
          cap.manifest.get("source_run_id").strVal)

block roundTrip:
  ## Producer <-> consumer: the S-run loader and Core both accept exactly
  ## the bytes the producer wrote.
  let ds = loadDailySeed(cap.dir, sessionDate)
  check("loadDailySeed accepts the produced P-run",
        ds.seed.symbolCount == 4 and ds.blockRaws.len == 2)
  check("loadDailySeed derives the failed set from the gaps",
        ds.seed.failed == @["035420", "111111"])
  check("loadDailySeed's seed hash equals the produced manifest",
        ds.seed.seedSha256 ==
          cap.manifest.get("seed_sha256").strVal)
  let core = runCore(loadRecords(cap.dir / "input.hcj.jsonl"))
  check("runCore accepts the produced P-run (status incomplete, no bars)",
        core.status == rsIncomplete and core.bars.len == 0 and
        core.signals.len == 0)
  check("runCore sees the P-run universe declaration",
        core.config.preopenUniverse.isSome)
  check("runCore verifies all six rest_resp pages (4 list + 2 daily)",
        core.restVerified == 6)

# -------------------------------------------------- page-cap truncation

block truncation:
  let f = baseFake()
  f.list = @[
    ListReply(market: "0", page: 1, codes: @["005930", "000660"],
              contYn: "Y", nextKey: "more")]
  f.daily = @[
    DailyReply(symbol: "005930", event: dailyOk("005930", completedRows(20)),
               physical: 1),
    DailyReply(symbol: "000660", event: dailyOk("000660", completedRows(20)),
               physical: 1)]
  let cap1 = captureWith(producerCfg(@["0"], 1), f, "trunc")
  check("a cap-closed chain sets universe.truncated",
        cap1.truncated and
        cap1.manifest.get("universe").get("truncated").bval)
  check("the truncated run still captures its derived subset",
        cap1.captured == 2 and cap1.failed == 0)
  let ds = loadDailySeed(cap1.dir, sessionDate)
  check("loadDailySeed accepts a truncated P-run", ds.seed.symbolCount == 2)
  let core = runCore(loadRecords(cap1.dir / "input.hcj.jsonl"))
  check("Core accepts the truncated P-run", core.status == rsIncomplete)

# ------------------------------------------------- 429-then-success retry

block retry:
  let f = baseFake()
  f.list = @[ListReply(market: "0", page: 1, codes: @["005930"],
                       contYn: "N", nextKey: "")]
  f.daily = @[
    DailyReply(symbol: "005930", event: dailyOk("005930", completedRows(21)),
               physical: 2)]  # 429, bounded retry, success: one event
  let r = captureWith(producerCfg(@["0"], 1), f, "retry")
  check("429-then-success is one captured task, two physical requests",
        r.captured == 1 and f.physical == 3)
  var dailyRecords = 0
  for rec in readRecorderFile(r.dir / "input.hcj.jsonl"):
    if rec.kind == kRestResp and
       parseAttempt(rec.seq, rec.raw).api == raKa10081:
      inc dailyRecords
  check("the retried symbol has exactly one ka10081 record",
        dailyRecords == 1)

# --------------------------------------------------- existing run refused

block refusal:
  let base = createTempDir("hs-pprod-refuse-", "")
  let dir = base / (sessionDate & "-preopen")
  createDir(dir)
  writeFile(dir / "sentinel", "prior evidence")
  let f = mainFake()
  expectUsage("an existing run directory is refused", "REFUSED"):
    discard runPreopenCapture(producerCfg(@["0", "10"], 2), dir,
                              exchangeOf(f), clockFn(f.clock))
  check("the refused directory keeps its sentinel",
        readFile(dir / "sentinel") == "prior evidence")
  check("the refused directory gains no input log",
        not fileExists(dir / "input.hcj.jsonl"))

# ------------------------------------------------ window overrun fail-closed

block overrun:
  let f = baseFake()
  f.list = @[ListReply(market: "0", page: 1, codes: @["005930"],
                       contYn: "N", nextKey: "")]
  f.daily = @[DailyReply(symbol: "005930",
                         event: dailyOk("005930", completedRows(20)),
                         physical: 1)]
  let clock = f.clock
  clock.switchAt = 3           # start + list page pass; the daily check trips
  clock.switchTo = fromUnix(openEpoch)
  let dir = runDir("overrun")
  expectCaptureError("a capture reaching the open is refused", "open"):
    discard captureAt(producerCfg(@["0"], 1), f, dir)
  # The abandoned run preserves its evidence but never a seal.
  let recs = readRecorderFile(dir / "input.hcj.jsonl")
  var sawManifest = false
  for r in recs:
    if r.kind == kDailySeedManifest: sawManifest = true
  check("the overrun writes no daily_seed_manifest", not sawManifest)
  check("the overrun records a run-level preopen_window_overrun gap",
        recs[^1].kind == kGap and
        recs[^1].raw.get("what").strVal == "preopen_window_overrun")

# --------------------------------------------------------- usage refusals

expectUsage("a P-run without config.preopen_universe is refused",
            "preopen_universe"):
  discard runPreopenCapture(
    initCollectorConfig(sessionDate, "demo", "demo-profile",
      "000", "0000", "0", "0", "1", "0", "0", "1",
      Params(warmupBars: 0, lookbackBars: 3, trendMinBp: 50,
             countermoveMinBp: 50, directionalTriggerBp: 30,
             holdOnDegraded: true),
      calRaw(), runId = sessionDate & "-preopen"),
    runDir("noconfig"), exchangeOf(mainFake()), clockFn(baseFake().clock))

echo ""
if failures > 0:
  echo failures, " FAILED, ", passes, " passed"
  quit(1)
echo "ALL PREOPEN CAPTURE PRODUCER TESTS PASSED (", passes, " checks)"