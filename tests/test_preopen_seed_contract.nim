## Pre-open daily seed contract tests (REPLAY_CONTRACT §3/§12.9/§12.10).
##
## Synthetic payloads only: no network, no vendor data, no wall clock.
## Covers: the 12th record kind accepted and ignored by Core; legacy
## byte-identity when config.preopen_seed is absent; the seed block
## (K = symbol_count - |failed| first ka10081 records, canonical raw-line
## hash match/mismatch, Rule 3 diagnostics never entering the hash);
## block/failed disjointness and duplicate rejection; the replay-derived
## sweep universe (inside passes, outside REJECT, legacy vs accumulate-v2);
## and every malformed config.preopen_seed shape (fail-closed, never a
## silent default).
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_preopen_seed_contract.nim
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
  result = createTempDir("hs-preopen-" & name & "-", "")
  var content = ""
  for l in lines: content.add(l & "\n")
  writeFile(result / inputFile, content)

proc runOf(name: string; lines: seq[string]): CoreResult =
  runCore(loadRecords(writeStream(name, lines) / inputFile))

proc coreBytes(lines: seq[string]): string =
  ## The deterministic Core artifacts (bars then signals) — the bytes a
  ## legacy stream must keep when an ignored record is added.
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

# ---------------------------------------------------------------- builders

proc day(o, c: string): HcjValue =
  hObj(("close", hStr(c)), ("open", hStr(o)))

proc calRaw(): HcjValue =
  hObj(("days", hObj(("2026-10-29",
                      day("09:00:00+09:00", "15:30:00+09:00")))))

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

proc manifestRaw(): HcjValue =
  ## A realistic P-run seal: Core ignores every field, so only the kind
  ## and the fact that the raw parses matter.
  hObj(("binary_sha256", hStr(repeat('a', 64))),
       ("captured_count", hInt(2)),
       ("capture_failed_count", hInt(0)),
       ("config_sha256", hStr(repeat('b', 64))),
       ("history_short_count", hInt(0)),
       ("seed_sha256", hStr(repeat('c', 64))),
       ("session_date", hStr("2026-10-29")),
       ("source_run_id", hStr("2026-10-29-preopen")),
       ("universe", hObj(("source", hStr("explicit")),
                         ("symbol_count", hInt(2)),
                         ("truncated", hBool(false)))))

proc seedRaw(seedHash: string; symbolCount: int; failed: seq[string] = @[];
             sessionDate = "2026-10-29";
             manifest = repeat('d', 64)): HcjValue =
  var f: seq[HcjValue]
  for sym in failed: f.add(hStr(sym))
  hObj(("failed", hArrSeq(f)),
       ("manifest_sha256", hStr(manifest)),
       ("seed_sha256", hStr(seedHash)),
       ("session_date", hStr(sessionDate)),
       ("source_run_id", hStr("2026-10-29-preopen")),
       ("symbol_count", hInt(symbolCount)))

proc cfgWithSeedNode(node: HcjValue): HcjValue =
  hObj(("preopen_seed", node), ("session_date", hStr("2026-10-29")))

proc cfgSeed(seed: HcjValue; dailyScope = ""; repoll = 0): HcjValue =
  var pairs: seq[HcjPair] = @[
    ("preopen_seed", seed), ("session_date", hStr("2026-10-29"))]
  if dailyScope.len > 0: pairs.add(("daily_scope", hStr(dailyScope)))
  if repoll > 0: pairs.add(("repoll_seconds", hInt(repoll)))
  HcjValue(kind: hkObj, pairs: pairs)

proc dropKey(v: HcjValue; key: string) =
  var keep: seq[HcjPair]
  for p in v.pairs:
    if p.k != key: keep.add(p)
  v.pairs = keep

proc setKey(v: HcjValue; key: string; val: HcjValue) =
  for p in v.pairs.mitems:
    if p.k == key: p.v = val

proc seededPairs(config: HcjValue; blockRecs: seq[HcjValue];
                 after: seq[tuple[k: Kind, raw: HcjValue]] = @[]):
                 seq[tuple[k: Kind, raw: HcjValue]] =
  ## A complete S-run shape: calendar, seeded config, the seed block, any
  ## later records (chains/sweep), then the seal.
  result.add((kCalendar, calRaw()))
  result.add((kConfig, config))
  for raw in blockRecs: result.add((kRestResp, raw))
  for p in after: result.add(p)
  result.add((kSessionEnd, hNull()))

# ---------------------------------------------------------------- ka10027

proc queryObj(sortTp: string): HcjValue =
  hObj(("crd_cnd", hStr("0")), ("mrkt_tp", hStr("101")),
       ("pric_cnd", hStr("0")), ("sort_tp", hStr(sortTp)),
       ("stk_cnd", hStr("0")), ("stex_tp", hStr("1")),
       ("trde_prica_cnd", hStr("0")), ("trde_qty_cnd", hStr("0000")),
       ("updown_incls", hStr("1")))

proc candBody(codes: seq[string]): string =
  var rows: seq[HcjValue]
  for cd in codes:
    rows.add(hObj(("stk_cd", hStr(cd)), ("stk_nm", hStr("name-" & cd))))
  canonical(hObj((ka10027ListKey, hArrSeq(rows)),
                 ("return_code", hInt(0))))

proc candidateAttempt(codes: seq[string]; sortTp: string;
                      page = 1; contYn = "N"; nextKey = ""): HcjValue =
  hObj(("api_id", hStr(ka10027ApiId)),
       ("body_hex", hStr(hexOfBytes(toBytes(candBody(codes))))),
       ("cont_yn", hStr(contYn)), ("next_key", hStr(nextKey)),
       ("page", hInt(page)), ("query", queryObj(sortTp)),
       ("status", hInt(200)))

# ---------------------------------------------------------------- ka10081

proc dailyRow(dt = "20261028"): HcjValue =
  ## One row in the measured positional form: the 12 documented ka10081
  ## fields in documented order, values as measured strings.
  hArr(hStr("71500"), hStr("150000"), hStr("1074"), hStr(dt),
       hStr("71000"), hStr("72000"), hStr("70500"), hStr("-500"),
       hStr("5"), hStr("0.80"), hStr("1"), hStr("0.00"))

proc dailyBody(stkCd: string): string =
  canonical(hObj((ka10081ListKey, hArrSeq(@[dailyRow()])),
                 ("return_code", hInt(0)),
                 ("return_msg", hStr("ok")),
                 ("stk_cd", hStr(stkCd))))

proc dailyAttempt(stkCd: string): HcjValue =
  ## The measured success page shape: cont-yn=Y with a next-key, exactly
  ## one page per symbol (§12.9).
  hObj(("api_id", hStr(ka10081ApiId)),
       ("body_hex", hStr(hexOfBytes(toBytes(dailyBody(stkCd))))),
       ("cont_yn", hStr("Y")), ("next_key", hStr("cur_prc:20261028")),
       ("page", hInt(1)),
       ("query", hObj(("base_dt", hStr("20261029")),
                      ("stk_cd", hStr(stkCd)),
                      ("upd_stkpc_tp", hStr(declaredDailyUpdStkpcTp)))),
       ("status", hInt(200)))

proc blockHash(raws: seq[HcjValue]): string =
  ## The §12.10.1/§12.10.2 framing: canonical raw + LF per record, order
  ## preserved, seq excluded — independent of record envelope numbering.
  var text = ""
  for r in raws:
    text.add(canonical(r))
    text.add("\n")
  sha256Hex(text)

# ------------------------------------------------------- 12th kind acceptance

block sealKind:
  check("daily_seed_manifest is the 12th parsed kind",
        parseKind("daily_seed_manifest") == kDailySeedManifest and
        kindName(kDailySeedManifest) == "daily_seed_manifest")
  check("daily_seed_manifest is ignored by Core, never consumed",
        kDailySeedManifest in ignoredKinds and
        kDailySeedManifest notin consumedKinds)
  check("the manifest envelope round-trips",
        parseRecord(makeRecordLine(3, kDailySeedManifest, manifestRaw()),
                    3).kind == kDailySeedManifest)
  var ps = pairsOfLines(sessionLines())
  ps.insert((kDailySeedManifest, manifestRaw()), 2)
  let withSeal = linesOf(ps)
  let res = runOf("seal", withSeal)
  check("a stream carrying the P-run seal still replays OK",
        res.status == rsOk)
  check("the seal is counted as an ignored kind", res.ignoredKinds == 1)
  check("the seal changes no bar/signal byte",
        coreBytes(sessionLines()) == coreBytes(withSeal))

# ------------------------------------------------------ legacy (no seed) path

block legacyNoSeed:
  ## A ka10081 capture outside any seed universe is legacy-legal when the
  ## config declares no preopen_seed: no new audit, no new byte.
  var ps = pairsOfLines(sessionLines())
  ps.insert((kRestResp, dailyAttempt("777777")), 2)
  let withDaily = linesOf(ps)
  let res = runOf("legacy-outside", withDaily)
  check("no preopen_seed: the capture verifies under the legacy audit",
        res.status == rsOk and res.restVerified == 1)
  check("no preopen_seed: Config carries no seed and the legacy daily scope",
        res.config.preopenSeed.isNone and res.config.dailyScope.len == 0)
  check("no preopen_seed: bars/signals are byte-identical",
        coreBytes(sessionLines()) == coreBytes(withDaily))

  let a = parseAttempt(3, dailyAttempt("777777"))
  check("verifyAttempts keeps the legacy result without a declaration",
        verifyAttempts(@[a]).len == 1 and
        verifyAttempts(@[a], declaredSymbols = @[]).len == 1)
  var rejected = false
  try:
    discard verifyAttempts(@[a], declaredSymbols = @["005930"])
  except RestRespError:
    rejected = true
  check("a declared universe rejects an out-of-universe ka10081 scope",
        rejected)

# ---------------------------------------------------------------- seed block

block seedBlock:
  let b1 = dailyAttempt("005930")
  let b2 = dailyAttempt("000660")
  check("the block hash framing is canonical(raw)+LF, seq excluded",
        blockHash(@[b1]) ==
          "fdbb43cdda877311d22d1311516a55555db15699361d1a0a6bff8951594ff674")
  let twoHash = blockHash(@[b1, b2])
  let goodCfg = cfgSeed(seedRaw(twoHash, 2))
  let res = runOf("seed-good", linesOf(seededPairs(goodCfg, @[b1, b2])))
  check("a hash-matching seed block replays OK", res.status == rsOk)
  check("both block records verify as captured", res.restVerified == 2)

  # Rule 3 diagnostics may interleave inside the block: the block and its
  # hash are defined by the first K ka10081 records only.
  var interleaved: seq[tuple[k: Kind, raw: HcjValue]]
  interleaved.add((kCalendar, calRaw()))
  interleaved.add((kConfig, goodCfg))
  interleaved.add((kRestResp, b1))
  interleaved.add((kPong, hNull()))
  interleaved.add((kRestResp, b2))
  interleaved.add((kSessionEnd, hNull()))
  let diag = runOf("seed-diag", linesOf(interleaved))
  check("Rule 3 diagnostics inside the block never change the hash",
        diag.status == rsOk and diag.restVerified == 2)

  rejectRun("a seed_sha256 mismatch is REJECT", "seed_sha256 mismatch",
    linesOf(seededPairs(cfgSeed(seedRaw(blockHash(@[b1]), 2)), @[b1, b2])))
  rejectRun("a missing block is REJECT", "block is missing",
    linesOf(seededPairs(cfgSeed(seedRaw(twoHash, 3)), @[b1, b2])))

  # K = 0 is a degenerate but shape-valid seed: no ka10081 record is owed.
  let emptyHash = sha256Hex("")
  check("a zero-symbol seed with the empty-block hash replays OK",
        runOf("seed-empty",
              linesOf(seededPairs(cfgSeed(seedRaw(emptyHash, 0)), @[]))).status ==
          rsOk)

# --------------------------------------------------------------- failed list

block failedRules:
  let b1 = dailyAttempt("005930")
  let h1 = blockHash(@[b1])
  check("a failed symbol with no affirming record is a legal seed",
        runOf("failed-ok",
              linesOf(seededPairs(cfgSeed(seedRaw(h1, 2, @["000660"])),
                                  @[b1]))).status == rsOk)
  rejectRun("a block symbol also declared failed is REJECT",
            "both a block capture and a declared failed",
    linesOf(seededPairs(cfgSeed(seedRaw(h1, 2, @["005930"])), @[b1])))
  rejectRun("a failed symbol with an affirming record is REJECT",
            "also has an affirming",
    linesOf(seededPairs(cfgSeed(seedRaw(h1, 2, @["000660"])), @[b1],
                        after = @[(kRestResp, dailyAttempt("000660"))])))
  rejectRun("a duplicate ka10081 symbol is REJECT", "repeats symbol",
    linesOf(seededPairs(cfgSeed(seedRaw(h1, 1)), @[b1, dailyAttempt("005930")])))
  rejectConfig("a duplicate failed symbol is REJECT", "repeats symbol",
               cfgSeed(seedRaw(h1, 3, @["000660", "000660"])))
  rejectConfig("symbol_count below |failed| is REJECT", "below |failed|",
               cfgSeed(seedRaw(h1, 1, @["000660", "999999"])))

# ------------------------------------------------- declared sweep universe

block declaredUniverse:
  ## The universe is the §12.9 dailyUniverseOf rule over the verified
  ## ka10027 chains: up/down rows interleaved (up #1, down #1, ...),
  ## deduped. up [005930, 000660] + down [000660, 999999] -> that order.
  let up = candidateAttempt(@["005930", "000660"], "1")
  let down = candidateAttempt(@["000660", "999999"], "3")
  let b = dailyAttempt("005930")
  let cfg = cfgSeed(seedRaw(blockHash(@[b]), 1))
  let inside = @[(kRestResp, up), (kRestResp, down),
                 (kRestResp, dailyAttempt("000660")),
                 (kRestResp, dailyAttempt("999999"))]
  let res = runOf("universe-inside",
                  linesOf(seededPairs(cfg, @[b], after = inside)))
  check("captures inside the replay-derived universe pass",
        res.status == rsOk and res.restVerified == 5)
  let outside = @[(kRestResp, up), (kRestResp, down),
                  (kRestResp, dailyAttempt("777777"))]
  rejectRun("a capture outside the derived universe is REJECT",
            "outside the declared daily universe",
            linesOf(seededPairs(cfg, @[b], after = outside)))

block accumulateUniverse:
  ## The legacy scope's universe is the initial pair only; accumulate-v2
  ## extends it with each later poll round's new symbols (§12.9).
  let up1 = candidateAttempt(@["005930"], "1")
  let down1 = candidateAttempt(@["000660"], "3")
  let up2 = candidateAttempt(@["111111"], "1")
  let down2 = candidateAttempt(@["222222"], "3")
  let b = dailyAttempt("005930")
  let h = blockHash(@[b])
  let sweep = @[(kRestResp, up1), (kRestResp, down1),
                (kRestResp, up2), (kRestResp, down2),
                (kRestResp, dailyAttempt("111111"))]
  rejectRun("legacy scope: a later poll round's new symbol is outside",
            "outside the declared daily universe",
            linesOf(seededPairs(cfgSeed(seedRaw(h, 1), repoll = 300), @[b],
                                after = sweep)))
  let acc = cfgSeed(seedRaw(h, 1), dailyScope = dailyScopeAccumulate,
                    repoll = 300)
  check("accumulate-v2: the later poll round extends the declared universe",
        runOf("accumulate",
              linesOf(seededPairs(acc, @[b], after = sweep))).status == rsOk)

# -------------------------------------------------------- malformed shapes

block malformedSeed:
  let emptyHash = sha256Hex("")
  let base = seedRaw(emptyHash, 0)
  check("the minimal empty seed parses",
        parseConfig(cfgWithSeedNode(seedRaw(emptyHash, 0))).preopenSeed.isSome)
  rejectConfig("a non-object preopen_seed is REJECT", "not an object",
               cfgWithSeedNode(hStr("x")))
  var s = seedRaw(emptyHash, 0)
  s.dropKey("failed")
  rejectConfig("a missing field is REJECT", "missing field: failed",
               cfgWithSeedNode(s))
  s = seedRaw(emptyHash, 0)
  s.pairs.add(("unexpected", hStr("x")))
  rejectConfig("an unknown field is REJECT", "unknown field",
               cfgWithSeedNode(s))
  s = seedRaw(emptyHash, 0)
  s.setKey("seed_sha256", hInt(1))
  rejectConfig("a non-string seed_sha256 is REJECT", "not a string",
               cfgWithSeedNode(s))
  s = seedRaw(emptyHash, 0)
  s.setKey("seed_sha256", hStr("ABC"))
  rejectConfig("a non-sha256 seed_sha256 is REJECT", "lowercase sha256",
               cfgWithSeedNode(s))
  s = seedRaw(emptyHash, 0)
  s.setKey("manifest_sha256", hStr("00"))
  rejectConfig("a short manifest_sha256 is REJECT", "manifest_sha256",
               cfgWithSeedNode(s))
  s = seedRaw(emptyHash, 0)
  s.setKey("symbol_count", hStr("0"))
  rejectConfig("a string symbol_count is REJECT", "not an integer",
               cfgWithSeedNode(s))
  s = seedRaw(emptyHash, 0)
  s.setKey("symbol_count", hInt(-1))
  rejectConfig("a negative symbol_count is REJECT", ">= 0",
               cfgWithSeedNode(s))
  s = seedRaw(emptyHash, 0)
  s.setKey("failed", hStr("x"))
  rejectConfig("a non-array failed is REJECT", "not an array",
               cfgWithSeedNode(s))
  s = seedRaw(emptyHash, 0)
  s.setKey("failed", hArr(hInt(1)))
  rejectConfig("a non-string failed element is REJECT",
               "element is not a string", cfgWithSeedNode(s))
  s = seedRaw(emptyHash, 0)
  s.setKey("source_run_id", hStr(""))
  rejectConfig("an empty source_run_id is REJECT", "must not be empty",
               cfgWithSeedNode(s))
  rejectConfig("a session_date mismatch is REJECT",
               "does not equal config.session_date",
               cfgWithSeedNode(seedRaw(emptyHash, 0,
                                       sessionDate = "2026-10-30")))
  rejectConfig("an undeclared daily_scope is REJECT", "daily_scope must be",
               cfgSeed(seedRaw(emptyHash, 0), dailyScope = "accumulate-v3"))

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)