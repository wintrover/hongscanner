## S-run pre-open seed materialization contract tests
## (REPLAY_CONTRACT §12.10.1/§12.10.2/§12.10.4).
##
## Synthetic P-runs only: no network, no vendor data, no wall clock.
## Covers: explicit and ka10099 universe derivation (failed = universe
## minus captures), the exact six-field config.preopen_seed record, the
## verbatim block immediately after record 2, legacy byte-identity when
## no seed is declared, the one-capture ledger (captured ∪ failed never
## re-requested by the sweep), the resulting stream passing runCore with
## the seeded audit, and every refusal (seal, date, counts, overlap,
## duplicate, out-of-universe, hash).
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_preopen_inject_contract.nim
import std/[os, strutils, tempfiles, sets, options, algorithm]
import hs/[hcj, digest, records, recorder, calendars, engine, replay,
           vendor_input, rest_resp, collector]
import ../tools/collector/preopen

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

const
  ts = "2026-10-29T09:00:00+09:00"
  sessionDate = "2026-10-29"
  sourceRunId = "2026-10-29-preopen"

# ---------------------------------------------------------------- builders

proc day(o, c: string): HcjValue =
  hObj(("close", hStr(c)), ("open", hStr(o)))

proc calRaw(): HcjValue =
  hObj(("days", hObj(
    ("2026-10-29", day("09:00:00+09:00", "15:30:00+09:00")))))

proc hArrOf(xs: openArray[string]): HcjValue =
  var items: seq[HcjValue]
  for x in xs: items.add(hStr(x))
  hArrSeq(items)

proc explicitUniverse(syms: openArray[string]): HcjValue =
  hObj(("source", hStr("explicit")), ("symbols", hArrOf(syms)))

proc ka10099Universe(markets: openArray[string]; pageCap: int): HcjValue =
  hObj(("market_codes", hArrOf(markets)), ("page_cap", hInt(pageCap)),
       ("source", hStr("ka10099")))

proc pRunConfig(universe: HcjValue): HcjValue =
  hObj(("preopen_universe", universe), ("run_id", hStr(sourceRunId)),
       ("session_date", hStr(sessionDate)))

# ------------------------------------------------------------- ka10081

proc dailyRow(dt = "20261028"): HcjValue =
  hArr(hStr("71500"), hStr("150000"), hStr("1074"), hStr(dt),
       hStr("71000"), hStr("72000"), hStr("70500"), hStr("-500"),
       hStr("5"), hStr("0.80"), hStr("1"), hStr("0.00"))

proc dailyBody(stkCd: string): string =
  canonical(hObj((ka10081ListKey, hArrSeq(@[dailyRow()])),
                 ("return_code", hInt(0)),
                 ("return_msg", hStr("ok")),
                 ("stk_cd", hStr(stkCd))))

proc dailyAttempt(stkCd: string; baseDt = "20261029"): HcjValue =
  hObj(("api_id", hStr(ka10081ApiId)),
       ("body_hex", hStr(hexOfBytes(toBytes(dailyBody(stkCd))))),
       ("cont_yn", hStr("Y")), ("next_key", hStr("cur_prc:20261028")),
       ("page", hInt(1)),
       ("query", hObj(("base_dt", hStr(baseDt)), ("stk_cd", hStr(stkCd)),
                      ("upd_stkpc_tp", hStr(declaredDailyUpdStkpcTp)))),
       ("status", hInt(200)))

# ------------------------------------------------------------- ka10099

proc listBody(codes: openArray[string]): string =
  var rows: seq[HcjValue]
  for c in codes:
    rows.add(hObj(("code", hStr(c)), ("marketCode", hStr("0")),
                  ("name", hStr("name-" & c))))
  canonical(hObj(("list", hArrSeq(rows)), ("return_code", hInt(0)),
                 ("return_msg", hStr("ok"))))

proc listAttempt(mrktTp: string; page: int; contYn: string;
                 codes: openArray[string]): HcjValue =
  hObj(("api_id", hStr("ka10099")),
       ("body_hex", hStr(hexOfBytes(toBytes(listBody(codes))))),
       ("cont_yn", hStr(contYn)),
       ("next_key", hStr(if contYn == "Y": "key-" & $page else: "")),
       ("page", hInt(page)),
       ("query", hObj(("mrkt_tp", hStr(mrktTp)))),
       ("status", hInt(200)))

# ------------------------------------------------------------- manifest

proc blockHash(raws: seq[HcjValue]): string =
  var text = ""
  for r in raws:
    text.add(canonical(r))
    text.add("\n")
  sha256Hex(text)

proc manifestRaw(source: string; marketCodes: seq[string]; symbolCount,
                 capturedCount, failedCount: int; seedSha: string;
                 failed: seq[string] = @[]; declaredFailed = false;
                 truncated = false; historyShort = 0): HcjValue =
  var mc: seq[HcjValue]
  for m in marketCodes: mc.add(hStr(m))
  var pairs: seq[HcjPair] = @[
    ("binary_sha256", hStr(repeat('a', 64))),
    ("capture_failed_count", hInt(failedCount)),
    ("capture_window", hObj(
      ("ended_at", hStr("2026-10-29T08:50:00+09:00")),
      ("started_at", hStr("2026-10-29T08:30:00+09:00")))),
    ("captured_count", hInt(capturedCount)),
    ("config_sha256", hStr(repeat('b', 64))),
    ("history_short_count", hInt(historyShort)),
    ("seed_sha256", hStr(seedSha)),
    ("session_date", hStr(sessionDate)),
    ("source_run_id", hStr(sourceRunId)),
    ("universe", hObj(
      ("market_codes", hArrSeq(mc)),
      ("source", hStr(source)),
      ("symbol_count", hInt(symbolCount)),
      ("truncated", hBool(truncated)),
      ("universe_sha256", hStr(repeat('c', 64)))))]
  if declaredFailed:
    pairs.add(("failed", hArrOf(failed)))
  HcjValue(kind: hkObj, pairs: pairs)

proc writePRun(label: string; cfg, manifest: HcjValue;
               middle: seq[tuple[k: Kind, raw: HcjValue]]): string =
  ## A P-run as the recorder leaves it when abandoned (REPLAY_CONTRACT
  ## §12.10.1: no session_end; the manifest is the last committed record).
  result = createTempDir("hs-prun-" & label & "-", "")
  var r = openRecorder(result / "input.hcj.jsonl")
  discard r.append(kCalendar, calRaw())
  discard r.append(kConfig, cfg)
  for p in middle:
    discard r.append(p.k, p.raw)
  discard r.append(kDailySeedManifest, manifest)
  r.abandon()

proc rejectSeed(name, needle, dir: string;
                date = sessionDate) =
  var raised = false
  var msg = ""
  try:
    discard loadDailySeed(dir, date)
  except DailySeedError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name & " (raises: " & needle & ")", raised and needle in msg)

proc coreErr(name, needle: string; body: proc ()) =
  var raised = false
  var msg = ""
  try:
    body()
  except CollectorError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name & " (raises: " & needle & ")", raised and needle in msg)

# ------------------------------------------------------------- S-run side

proc approvedConfig(seed: Option[PreopenSeedDecl] = none(PreopenSeedDecl);
                    blockRaws: seq[HcjValue] = @[];
                    runId = "2026-10-29"): CollectorConfig =
  initCollectorConfig(
    sessionDate, "demo", "demo-profile",
    "000", "0000", "0", "0", "1", "0", "0", "1",
    Params(warmupBars: 0, lookbackBars: 3, trendMinBp: 50,
           countermoveMinBp: 50, directionalTriggerBp: 30,
           holdOnDegraded: true),
    calRaw(), runId = runId, pageCap = 10,
    preopenSeed = seed, preopenBlock = blockRaws)

proc ev(name, t: string; rest: varargs[HcjPair]): string =
  var ps: seq[HcjPair] = @[("ev", hStr(name)), ("t", hStr(t))]
  for p in rest: ps.add(p)
  canonical(hObj(ps))

proc hexOf(s: string): string =
  const digits = "0123456789abcdef"
  for c in s:
    result.add(digits[int(ord(c)) shr 4])
    result.add(digits[int(ord(c)) and 0x0f])

proc evWs(conn: int; payload: string; t = ts): string =
  ev("ws", t, ("conn", hInt(conn)), ("payload_hex", hStr(hexOf(payload))))

proc evRest(direction: string; page: int; status: int; contYn, nextKey,
            body: string; t = ts): string =
  ev("rest", t, ("body_hex", hStr(hexOf(body))), ("cont_yn", hStr(contYn)),
     ("direction", hStr(direction)), ("page", hInt(page)),
     ("status", hInt(status)), ("next_key", hStr(nextKey)))

proc evRestDaily(body: string; status = 200; contYn = "Y";
                 nextKey = "cur_prc:20261028"; t = ts): string =
  ev("rest_daily", t, ("api_id", hStr(ka10081ApiId)),
     ("body_hex", hStr(hexOf(body))), ("cont_yn", hStr(contYn)),
     ("next_key", hStr(nextKey)), ("page", hInt(1)),
     ("status", hInt(status)))

proc ackPayload(trnm = "REG"; code = 0): string =
  "{\"return_code\":" & $code & ",\"return_msg\":\"\",\"trnm\":\"" &
    trnm & "\"}"

proc tick0B(item: string; price, cum: int): string =
  "{\"trnm\":\"REAL\",\"data\":[{\"item\":\"" & item & "\",\"name\":\"" &
    "주식체결\",\"type\":\"0B\",\"values\":{\"10\":\"" & $price &
    "\",\"13\":\"" & $cum & "\",\"15\":\"+1\",\"20\":\"090500\"," &
    "\"25\":\"2\",\"290\":\"2\"}}]}"

proc state0S(value215 = "4"): string =
  "{\"trnm\":\"REAL\",\"data\":[{\"item\":\"\",\"name\":\"장시작시간\"," &
    "\"type\":\"0s\",\"values\":{\"20\":\"153000\",\"215\":\"" &
    value215 & "\",\"214\":\"000000\"}}]}"

proc restBody(codes: openArray[string]): string =
  var rows: seq[string]
  for c in codes:
    rows.add("[\"1\",\"" & c & "\",\"name\",\"10000\",\"2\",\"1\",\"1.0\"," &
             "\"100\",\"200\",\"50\",\"+\",\"1\"]")
  "{\"pred_pre_flu_rt_upper\":[" & rows.join(",") & "],\"return_code\":0," &
    "\"return_msg\":\"\"}"

proc feed(c: var Collector; outp: var seq[RecOut];
          line: string): seq[Directive] =
  var recs: seq[RecOut]
  result = c.handleEvent(line, recs)
  for r in recs: outp.add(r)

proc dirKinds(dirs: seq[Directive]): seq[string] =
  for d in dirs:
    result.add(case d.kind
               of dkConnect: "connect"
               of dkReg: "reg"
               of dkRemove: "remove"
               of dkRestReq: "rest_req"
               of dkDailyReq: "daily_req"
               of dkRefreshToken: "refresh_token"
               of dkDisarm: "disarm"
               of dkWaitDrain: "wait_drain"
               of dkStop: "stop")

proc sealRecords(recs: seq[RecOut]): string =
  ## Seal the S-run through the real Recorder: session_end + COMMITTED
  ## marker. Returns the run directory.
  result = createTempDir("hs-seeded-run-", "")
  var r = openRecorder(result / "input.hcj.jsonl")
  for p in recs:
    discard r.append(p.kind, p.raw)
  discard r.finish()

proc preopenKeySet(raw: HcjValue): seq[string] =
  if raw.kind != hkObj: return @[]
  let seed = raw.getOpt("preopen_seed")
  if seed.isNone or seed.get.kind != hkObj: return @[]
  for p in seed.get.pairs: result.add(p.k)
  sort(result)

proc gapCount(recs: seq[Record]; what: string): int =
  for r in recs:
    if r.kind == kGap and r.raw.has("what") and
       r.raw.get("what").kind == hkStr and r.raw.get("what").strVal == what:
      inc result

# ------------------------------------------------------ explicit P-run seed

let b1 = dailyAttempt("005930")
let b2 = dailyAttempt("000660")
let bHash = blockHash(@[b1, b2])
let explicitCfg = pRunConfig(explicitUniverse(["005930", "000660", "111111"]))

block explicitSeed:
  let manifest = manifestRaw("explicit", @[], 3, 2, 1, bHash,
                             failed = @["111111"], declaredFailed = true)
  let dir = writePRun("explicit", explicitCfg, manifest,
                      @[(kRestResp, b1), (kRestResp, b2)])
  let ds = loadDailySeed(dir, sessionDate)
  check("an explicit-universe P-run loads", ds.blockRaws.len == 2)
  check("the seed names the manifest source run",
        ds.seed.sourceRunId == sourceRunId)
  check("the seed declares the derived failed symbol",
        ds.seed.failed == @["111111"])
  check("symbol_count = K + |failed|", ds.seed.symbolCount == 3)
  check("manifest_sha256 is canonical(manifest.raw)+LF",
        ds.seed.manifestSha256 == sha256Hex(canonical(manifest) & "\n"))
  check("seed_sha256 is the block's canonical raw-line hash",
        ds.seed.seedSha256 == bHash)

  let cfg = approvedConfig(some(ds.seed), ds.blockRaws)
  let pre = cfg.preambleRecords()
  check("the preamble is calendar, config, then the block verbatim",
        pre.len == 4 and pre[0].kind == kCalendar and
        pre[1].kind == kConfig and pre[2].kind == kRestResp and
        pre[3].kind == kRestResp and
        canonical(pre[2].raw) == canonical(b1) and
        canonical(pre[3].raw) == canonical(b2))
  check("config.preopen_seed is exactly the six declared fields",
        preopenKeySet(pre[1].raw) == @[
          "failed", "manifest_sha256", "seed_sha256", "session_date",
          "source_run_id", "symbol_count"])
  let seedRaw = pre[1].raw.get("preopen_seed")
  check("the recorded seed values match the P-run seal",
        seedRaw.get("source_run_id").strVal == sourceRunId and
        seedRaw.get("session_date").strVal == sessionDate and
        seedRaw.get("seed_sha256").strVal == bHash and
        seedRaw.get("symbol_count").ival == 3 and
        seedRaw.get("failed").items.len == 1 and
        seedRaw.get("failed").items[0].strVal == "111111")

  var c = startCollector(cfg)
  check("dailySeen starts with captured ∪ failed before any round",
        c.dailySeen == toHashSet(["005930", "000660", "111111"]))

  var outp = cfg.preambleRecords()
  discard feed(c, outp, ev("ready", ts))
  discard feed(c, outp, ev("conn", ts, ("conn", hInt(1)),
                           ("state", hStr("open"))))
  discard feed(c, outp, evWs(1, ackPayload()))
  discard feed(c, outp, evRest("up", 1, 200, "N", "",
                               restBody(["005930", "000660"])))
  let pairDirs = feed(c, outp, evRest("down", 1, 200, "N", "",
                                      restBody(["005930", "111111",
                                                "999999"])))
  # The pair's interleaved universe is 005930, 000660, 111111, 999999;
  # the seeded/failed symbols are already completed logical tasks, so the
  # sweep queue is exactly the unseeded 999999.
  check("the sweep queue filters every captured and failed seed symbol",
        c.dailyUniverse == @["999999"] and c.dailySeen.len == 3)
  check("no daily_req is issued for a seeded or failed symbol",
        pairDirs.dirKinds() == @["reg", "daily_req"] and
        pairDirs[1].daily.stkCd == "999999")
  discard feed(c, outp, evWs(1, ackPayload()))   # candidate REG ack
  discard feed(c, outp, evRestDaily(dailyBody("999999")))
  check("the unseeded sweep symbol is captured normally",
        c.dailyPending == "" and c.dailyCursor == 1 and
        c.dailyUniverse == @["999999"])
  discard feed(c, outp, evWs(1, tick0B("005930", 10000, 100)))
  discard feed(c, outp, evWs(1, tick0B("000660", 20000, 200)))
  discard feed(c, outp, evWs(1, state0S("4")))
  discard feed(c, outp, evWs(1, ackPayload(trnm = "REMOVE", code = 0)))

  let runDir = sealRecords(outp)
  let recs = loadRecords(runDir / "input.hcj.jsonl")
  check("the sealed stream keeps the block at seq 3/4 after record 2",
        recs[2].kind == kRestResp and recs[3].kind == kRestResp and
        canonical(recs[2].raw) == canonical(b1) and
        canonical(recs[3].raw) == canonical(b2))
  check("the failed seed symbol leaves no daily_capture_failed gap",
        gapCount(recs, "daily_capture_failed") == 0)
  let res = runCore(recs)
  check("the seeded S-run replays OK under the seeded audit",
        res.status == rsOk and res.config.preopenSeed.isSome)
  check("the replay sees the six-field seed and the failed symbol",
        res.config.preopenSeed.get.failed == @["111111"] and
        res.config.preopenSeed.get.symbolCount == 3 and
        res.config.preopenSeed.get.seedSha256 == bHash)
  check("all ka10027 and ka10081 pages verified (2 pair + 2 block + 1 sweep)",
        res.restVerified == 5)
  check("the seed changes no bar derivation", res.bars.len == 2)

block derivedFailedWithoutManifestList:
  ## The contract manifest carries capture_failed_count, not identities;
  ## the S-run derives failed = universe - captured when no explicit list
  ## is recorded.
  let manifest = manifestRaw("explicit", @[], 3, 2, 1, bHash)
  let dir = writePRun("derived", explicitCfg, manifest,
                      @[(kRestResp, b1), (kRestResp, b2)])
  let ds = loadDailySeed(dir, sessionDate)
  check("failed identities are derived from universe minus captures",
        ds.seed.failed == @["111111"] and ds.seed.symbolCount == 3)

block ka10099Seed:
  ## The §12.10.1 ka10099 derivation: one chain per declared market,
  ## deduped codes in (declared market, page, row) order.
  let uni = ka10099Universe(["0", "10"], 2)
  let cfgRaw = pRunConfig(uni)
  let pages = @[
    (kRestResp, listAttempt("0", 1, "Y", ["005930", "000660"])),
    (kRestResp, listAttempt("0", 2, "N", ["000660", "300001"])),
    (kRestResp, listAttempt("10", 1, "N", ["111111"]))]
  let k1 = dailyAttempt("005930")
  let k2 = dailyAttempt("300001")
  let kHash = blockHash(@[k1, k2])
  let manifest = manifestRaw("ka10099", @["0", "10"], 4, 2, 2, kHash,
                             failed = @["000660", "111111"],
                             declaredFailed = true)
  var middle = pages
  middle.add((kRestResp, k1))
  middle.add((kRestResp, k2))
  let dir = writePRun("ka10099", cfgRaw, manifest, middle)
  let ds = loadDailySeed(dir, sessionDate)
  check("the ka10099 universe is deduped in declared market/page/row order",
        ds.seed.symbolCount == 4 and ds.seed.failed == @["000660", "111111"])
  check("the ka10099 seed block is the captured pages in order",
        ds.blockRaws.len == 2 and
        canonical(ds.blockRaws[0]) == canonical(k1) and
        canonical(ds.blockRaws[1]) == canonical(k2))

# ------------------------------------------------------------- refusals

block refusals:
  let manifest = manifestRaw("explicit", @[], 3, 2, 1, bHash,
                             failed = @["111111"], declaredFailed = true)
  let okDir = writePRun("ok", explicitCfg, manifest,
                        @[(kRestResp, b1), (kRestResp, b2)])
  discard loadDailySeed(okDir, sessionDate)

  let badHash = manifestRaw("explicit", @[], 3, 2, 1, repeat('d', 64),
                            failed = @["111111"], declaredFailed = true)
  rejectSeed("a seed_sha256 mismatch refuses to start", "seed_sha256 mismatch",
             writePRun("badhash", explicitCfg, badHash,
                       @[(kRestResp, b1), (kRestResp, b2)]))

  rejectSeed("a session_date mismatch refuses to start",
             "does not equal the session date", okDir,
             date = "2026-10-30")

  let badCount = manifestRaw("explicit", @[], 3, 1, 1, bHash,
                             failed = @["111111"], declaredFailed = true)
  rejectSeed("a captured_count mismatch refuses to start",
             "captured_count", writePRun("badcount", explicitCfg, badCount,
                                         @[(kRestResp, b1), (kRestResp, b2)]))

  let overlap = manifestRaw("explicit", @[], 3, 2, 1, bHash,
                            failed = @["005930"], declaredFailed = true)
  rejectSeed("a captured/failed overlap refuses to start",
             "not an uncaptured universe symbol",
             writePRun("overlap", explicitCfg, overlap,
                       @[(kRestResp, b1), (kRestResp, b2)]))

  let dupUni = pRunConfig(explicitUniverse(
    ["005930", "000660", "111111", "222222"]))
  let dupFailed = manifestRaw("explicit", @[], 4, 2, 2, bHash,
                              failed = @["111111", "111111"],
                              declaredFailed = true)
  rejectSeed("a duplicate failed symbol refuses to start", "repeats symbol",
             writePRun("dup", dupUni, dupFailed,
                       @[(kRestResp, b1), (kRestResp, b2)]))

  let badSymbolCount = manifestRaw("explicit", @[], 4, 2, 1, bHash,
                                   failed = @["111111"],
                                   declaredFailed = true)
  rejectSeed("a symbol_count mismatch refuses to start", "symbol_count",
             writePRun("badsym", explicitCfg, badSymbolCount,
                       @[(kRestResp, b1), (kRestResp, b2)]))

  let outside = dailyAttempt("777777")
  rejectSeed("a capture outside the declared universe refuses to start",
             "outside the declared universe",
             writePRun("outside", pRunConfig(explicitUniverse(
                         ["005930", "111111"])),
                       manifestRaw("explicit", @[], 2, 2, 0, blockHash(
                         @[b1, outside])),
                       @[(kRestResp, b1), (kRestResp, outside)]))

  # A record behind the seal: the last committed record is not the manifest.
  var lateDir = createTempDir("hs-prun-late-", "")
  block:
    var r = openRecorder(lateDir / "input.hcj.jsonl")
    discard r.append(kCalendar, calRaw())
    discard r.append(kConfig, explicitCfg)
    discard r.append(kRestResp, b1)
    discard r.append(kRestResp, b2)
    discard r.append(kDailySeedManifest, manifest)
    discard r.append(kPong, hNull())
    r.abandon()
  rejectSeed("a non-final manifest refuses to start",
             "not daily_seed_manifest", lateDir)

  # A malformed ka10099 chain: continuation missing below the cap.
  let shortUni = ka10099Universe(["0"], 5)
  let shortManifest = manifestRaw("ka10099", @["0"], 2, 1, 1,
                                  blockHash(@[b1]), failed = @["000660"],
                                  declaredFailed = true)
  rejectSeed("a ka10099 chain missing its continuation refuses to start",
             "declared continuation is missing",
             writePRun("short", pRunConfig(shortUni), shortManifest,
                       @[(kRestResp, listAttempt("0", 1, "Y", ["005930"])),
                         (kRestResp, b1)]))

# --------------------------------------------------------- legacy identity

const legacyConfigLine =
  "{\"ack_timeout_seconds\":10,\"candidate_query\":{\"crd_cnd\":\"0\"," &
  "\"mrkt_tp\":\"000\",\"pric_cnd\":\"0\",\"sort_tp\":\"1|3\"," &
  "\"stex_tp\":\"1\",\"stk_cnd\":\"0\",\"trde_prica_cnd\":\"0\"," &
  "\"trde_qty_cnd\":\"0000\",\"updown_incls\":\"1\"},\"collector\":{" &
  "\"api_id\":\"ka10027\",\"rest_domain\":\"https://mockapi.kiwoom.com\"," &
  "\"schema\":\"hong-scanner-collector-config/1\",\"ws_endpoint\":" &
  "\"wss://mockapi.kiwoom.com:10000/api/dostk/websocket\"}," &
  "\"drain_seconds\":10,\"environment\":\"demo\"," &
  "\"events_contract\":\"top10-v1\",\"market\":\"KRX\",\"page_cap\":10," &
  "\"params\":{\"countermove_min_bp\":50,\"directional_trigger_bp\":30," &
  "\"hold_on_degraded\":true,\"lookback_bars\":3,\"trend_min_bp\":50," &
  "\"warmup_bars\":0},\"repoll_seconds\":300,\"run_id\":\"2026-10-29\"," &
  "\"selection_policy\":\"kiwoom_response_order_first_100_v1\"," &
  "\"session_date\":\"2026-10-29\",\"subscription_caps\":{" &
  "\"per_direction\":100,\"total\":200},\"watchdog\":\"15:40:00+09:00\"}"

block legacyIdentity:
  let cfg = approvedConfig()
  let pre = cfg.preambleRecords()
  check("a run without --daily-seed records no seed and no block",
        pre.len == 2 and preopenKeySet(pre[1].raw).len == 0 and
        cfg.preopenBlock.len == 0)
  check("the legacy config record is byte-identical",
        canonical(pre[1].raw) == legacyConfigLine)
  check("the legacy ledger and sweep state are untouched",
        startCollector(cfg).dailySeen.len == 0 and
        not startCollector(cfg).dailyReady)

  coreErr("a block without a seed declaration is refused", "requires",
          proc () =
            discard approvedConfig(none(PreopenSeedDecl), @[b1]))
  coreErr("a seed with K != symbol_count - |failed| is refused", "symbol_count",
          proc () =
            let s = PreopenSeedDecl(sourceRunId: sourceRunId,
              sessionDate: sessionDate, seedSha256: bHash, symbolCount: 3,
              failed: @["000660"], manifestSha256: repeat('d', 64))
            discard approvedConfig(some(s), @[b1]))

echo ""
if failures > 0:
  echo $failures, " FAILED, ", passes, " passed"
  quit(1)
echo "ALL PREOPEN INJECT TESTS PASSED (", passes, " checks)"