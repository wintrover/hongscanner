## preopen: the S-run's read side of one P-run's daily seed
## (REPLAY_CONTRACT §12.10.1/§12.10.2).
##
## Adapter boundary: reads a P-run directory's input.hcj.jsonl and turns
## its seal (the last committed `daily_seed_manifest` record) plus its
## preserved ka10081/ka10099 rest_resp records into the exact
## `config.preopen_seed` declaration and the verbatim ka10081 block the
## S-run emits immediately after its config record.
##
## Every check is fail-closed: a missing/torn tail, a non-final manifest,
## a count or date mismatch, a duplicate or overlapping symbol, an
## out-of-universe capture, a malformed ka10099 chain and a hash mismatch
## all raise DailySeedError. The caller refuses to start (exit 2); a
## partial seed is never returned.
##
## `manifest_sha256` binds the source seal: sha256 over
## `canonical(manifest.raw)` + LF — the same line framing `seed_sha256`
## uses for the block, `seq` excluded because a record never hashes its
## own envelope. Core does not recompute it (it has no source run
## directory); the acceptance audit compares both recorded hashes.
import std/[os, strutils, sets, options]
import hs/[hcj, digest, records, recorder, rest_resp, vendor_input, collector]

type
  DailySeedError* = object of CatchableError

  DailySeed* = object
    seed*: PreopenSeedDecl
    blockRaws*: seq[HcjValue]

const
  pRunInputFile = "input.hcj.jsonl"
  manifestFields = [
    "binary_sha256", "capture_failed_count", "capture_window",
    "captured_count", "config_sha256", "history_short_count",
    "seed_sha256", "session_date", "source_run_id", "universe"]
  universeFields = [
    "market_codes", "source", "symbol_count", "truncated",
    "universe_sha256"]
  captureWindowFields = ["ended_at", "started_at"]

proc sde(msg: string): ref DailySeedError =
  newException(DailySeedError, msg)

proc isSha256Hex(s: string): bool =
  s.len == 64 and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc checkShape(obj: HcjValue; what: string; fields: openArray[string]) =
  ## Required fields present with the declared types; unknown fields are
  ## not silently interpreted (the caller-side shapes below are stricter).
  if obj.kind != hkObj:
    raise sde(what & " is not an object: " & kindName(obj))
  for f in fields:
    if not obj.has(f):
      raise sde(what & " is missing field: " & f)

proc objOf(obj: HcjValue; key, what: string): HcjValue =
  if obj.kind != hkObj:
    raise sde(what & " is not an object: " & kindName(obj))
  let v = obj.getOpt(key)
  if v.isNone:
    raise sde(what & " is missing field: " & key)
  if v.get.kind != hkObj:
    raise sde(what & "." & key & " is not an object: " & kindName(v.get))
  v.get

proc strOf(obj: HcjValue; key, what: string): string =
  if obj.kind != hkObj:
    raise sde(what & " is not an object: " & kindName(obj))
  let v = obj.getOpt(key)
  if v.isNone:
    raise sde(what & " is missing field: " & key)
  if v.get.kind != hkStr:
    raise sde(what & "." & key & " is not a string: " & kindName(v.get))
  v.get.strVal

proc intOf(obj: HcjValue; key, what: string): int =
  if obj.kind != hkObj:
    raise sde(what & " is not an object: " & kindName(obj))
  let v = obj.getOpt(key)
  if v.isNone:
    raise sde(what & " is missing field: " & key)
  if v.get.kind != hkInt:
    raise sde(what & "." & key & " is not an integer: " & kindName(v.get))
  if v.get.ival < 0 or v.get.ival > int64(high(int)):
    raise sde(what & "." & key & " is out of range: " & $v.get.ival)
  int(v.get.ival)

proc boolOf(obj: HcjValue; key, what: string): bool =
  if obj.kind != hkObj:
    raise sde(what & " is not an object: " & kindName(obj))
  let v = obj.getOpt(key)
  if v.isNone:
    raise sde(what & " is missing field: " & key)
  if v.get.kind != hkBool:
    raise sde(what & "." & key & " is not a boolean: " & kindName(v.get))
  v.get.bval

proc arrOf(obj: HcjValue; key, what: string): HcjValue =
  if obj.kind != hkObj:
    raise sde(what & " is not an object: " & kindName(obj))
  let v = obj.getOpt(key)
  if v.isNone:
    raise sde(what & " is missing field: " & key)
  if v.get.kind != hkArr:
    raise sde(what & "." & key & " is not an array: " & kindName(v.get))
  v.get

proc strItems(arr: HcjValue; what: string): seq[string] =
  for item in arr.items:
    if item.kind != hkStr:
      raise sde(what & " element is not a string: " & kindName(item))
    if item.strVal.len == 0:
      raise sde(what & " carries an empty string")
    result.add(item.strVal)

proc hasExactKeys(obj: HcjValue; keys: openArray[string]; what: string) =
  ## config.preopen_universe's declared shape is exact (§12.10.1: "Any
  ## other shape is rejected").
  if obj.kind != hkObj:
    raise sde(what & " is not an object: " & kindName(obj))
  for p in obj.pairs:
    if p.k notin keys:
      raise sde(what & " has an unknown field: " & p.k)
  for k in keys:
    if not obj.has(k):
      raise sde(what & " is missing field: " & k)

proc deriveKa10099(pages: seq[RestRespAttempt]; markets: seq[string];
                   pageCap: int; truncated: var bool): seq[string] =
  ## The declared universe is the deduped `code` sequence in (declared
  ## market order, page order, row order) (§12.10.1). The chain structure
  ## (1..N order, terminal page, cap closure) is checked here with this
  ## adapter's messages; each page's success affirmation and row schema
  ## come from Core's `ka10099ChainSymbols` — the same path replay/verify
  ## use — so a row means one thing on both sides of the seed.
  if markets.len == 0:
    raise sde("ka10099 universe declares no market_codes")
  var byMarket = newSeq[seq[RestRespAttempt]](markets.len)
  for p in pages:
    var idx = -1
    for i, m in markets:
      if m == p.scope99.mrktTp:
        idx = i
        break
    if idx < 0:
      raise sde("ka10099 page names an undeclared market: " &
                p.scope99.mrktTp)
    byMarket[idx].add(p)
  var seen = initHashSet[string]()
  for i, m in markets:
    let chain = byMarket[i]
    if chain.len == 0:
      raise sde("ka10099 market " & m & " has no captured page")
    if chain.len > pageCap:
      raise sde("ka10099 market " & m & " carries " & $chain.len &
                " pages above the declared page_cap " & $pageCap)
    for j, p in chain:
      if p.page != j + 1:
        raise sde("ka10099 market " & m & " page index " & $p.page &
                  " leaves a gap (expected " & $(j + 1) & ")")
      if j + 1 < chain.len and p.resp.contYn != "Y":
        raise sde("ka10099 market " & m & " continues past a page whose " &
                  "cont_yn is not Y (page " & $p.page & ")")
    var chainTruncated = false
    if chain[^1].resp.contYn == "Y":
      if chain.len < pageCap:
        raise sde("ka10099 market " & m & " has cont-yn=Y at page " &
                  $chain.len & " below the declared page_cap " & $pageCap &
                  ": a declared continuation is missing")
      chainTruncated = true
      truncated = true
    var resps: seq[RawHttpResp]
    for p in chain:
      resps.add(p.resp)
    var codes: seq[string]
    try:
      codes = ka10099ChainSymbols(resps, pageCap, chainTruncated)
    except VendorInputError as e:
      raise sde("ka10099 market " & m & " chain is rejected: " & e.msg)
    for code in codes:
      if code notin seen:
        seen.incl(code)
        result.add(code)

proc manifestFailed(manifest: HcjValue): seq[string] =
  ## Optional producer extension: an explicit failed-symbol list. When
  ## present it must equal the derived (universe - captured) set; when
  ## absent the derived list is authoritative.
  if not manifest.has("failed"):
    return @[]
  var seen = initHashSet[string]()
  for sym in strItems(arrOf(manifest, "failed", "P-run manifest"),
                      "P-run manifest.failed"):
    if sym in seen:
      raise sde("P-run manifest.failed repeats symbol: " & sym)
    seen.incl(sym)
    result.add(sym)

proc loadDailySeed*(pRunDir, sessionDate: string): DailySeed =
  ## Read and validate one P-run directory. Raises DailySeedError on any
  ## deviation; nothing is partially materialized.
  if pRunDir.len == 0:
    raise sde("--daily-seed requires a P-run directory")
  let path = pRunDir / pRunInputFile
  if not dirExists(pRunDir):
    raise sde("P-run directory does not exist: " & pRunDir)
  if not fileExists(path):
    raise sde("P-run input is missing: " & path)
  var recs: seq[Record]
  try:
    recs = readRecorderFile(path)
  except PartialTailError as e:
    raise sde("P-run input has an uncommitted partial tail: " & e.msg)
  except RecorderError as e:
    raise sde("P-run input is not a valid record stream: " & e.msg)
  if recs.len < 3:
    raise sde("P-run input has " & $recs.len & " records; a P-run carries " &
              "calendar, config and a daily_seed_manifest seal")
  try:
    validateRecords(recs)
  except RecordError as e:
    raise sde("P-run input violates the record envelope: " & e.msg)
  if recs[^1].kind != kDailySeedManifest:
    raise sde("the last committed P-run record is " &
              kindName(recs[^1].kind) & ", not daily_seed_manifest")

  let cfgRaw = recs[1].raw
  let cfgDate = strOf(cfgRaw, "session_date", "P-run config")
  if cfgDate != sessionDate:
    raise sde("P-run config.session_date " & cfgDate &
              " does not equal the session date " & sessionDate)

  let manifest = recs[^1].raw
  checkShape(manifest, "P-run manifest", manifestFields)
  let sourceRunId = strOf(manifest, "source_run_id", "P-run manifest")
  if sourceRunId.len == 0:
    raise sde("P-run manifest.source_run_id must not be empty")
  if cfgRaw.has("run_id"):
    let cfgRunId = strOf(cfgRaw, "run_id", "P-run config")
    if cfgRunId != sourceRunId:
      raise sde("P-run manifest.source_run_id " & sourceRunId &
                " does not equal config.run_id " & cfgRunId)
  let manifestDate = strOf(manifest, "session_date", "P-run manifest")
  if manifestDate != sessionDate:
    raise sde("P-run manifest.session_date " & manifestDate &
              " does not equal the session date " & sessionDate)
  let seedSha = strOf(manifest, "seed_sha256", "P-run manifest")
  if not isSha256Hex(seedSha):
    raise sde("P-run manifest.seed_sha256 is not a 64-digit lowercase " &
              "sha256: " & seedSha)
  for f in ["binary_sha256", "config_sha256"]:
    if not isSha256Hex(strOf(manifest, f, "P-run manifest")):
      raise sde("P-run manifest." & f & " is not a 64-digit lowercase sha256")
  let universe = objOf(manifest, "universe", "P-run manifest")
  checkShape(universe, "P-run manifest.universe", universeFields)
  let source = strOf(universe, "source", "P-run manifest.universe")
  if source != "explicit" and source != "ka10099":
    raise sde("P-run manifest.universe.source must be explicit or " &
              "ka10099: " & source)
  if not isSha256Hex(strOf(universe, "universe_sha256",
                           "P-run manifest.universe")):
    raise sde("P-run manifest.universe.universe_sha256 is not a 64-digit " &
              "lowercase sha256")
  let marketCodes = strItems(arrOf(universe, "market_codes",
                                   "P-run manifest.universe"),
                             "P-run manifest.universe.market_codes")
  let symbolCount = intOf(universe, "symbol_count",
                          "P-run manifest.universe")
  let truncated = boolOf(universe, "truncated", "P-run manifest.universe")
  let captureWindow = objOf(manifest, "capture_window", "P-run manifest")
  checkShape(captureWindow, "P-run manifest.capture_window",
             captureWindowFields)
  discard strOf(captureWindow, "started_at",
                "P-run manifest.capture_window")
  discard strOf(captureWindow, "ended_at",
                "P-run manifest.capture_window")
  let capturedCount = intOf(manifest, "captured_count", "P-run manifest")
  let captureFailedCount = intOf(manifest, "capture_failed_count",
                                 "P-run manifest")
  let historyShortCount = intOf(manifest, "history_short_count",
                                "P-run manifest")

  let uniCfg = objOf(cfgRaw, "preopen_universe", "P-run config")
  if strOf(uniCfg, "source", "P-run config.preopen_universe") != source:
    raise sde("P-run config.preopen_universe.source does not equal the " &
              "manifest's universe.source")

  var blockRaws: seq[HcjValue]
  var captured: seq[string]
  var listAttempts: seq[RestRespAttempt]
  for i in 2 ..< recs.len - 1:
    let r = recs[i]
    if r.kind != kRestResp:
      continue
    var attempt: RestRespAttempt
    try:
      attempt = parseAttempt(r.seq, r.raw)
    except RestRespError as e:
      raise sde("P-run rest_resp at seq " & $r.seq &
                " is not a declared P-run record: " & e.msg)
    case attempt.api
    of raKa10081:
      try:
        discard parsePageRows(ka10081Spec, attempt.resp)
      except VendorInputError as e:
        raise sde("P-run ka10081 record at seq " & $r.seq &
                  " does not affirm success: " & e.msg)
      captured.add(attempt.scope81.stkCd)
      blockRaws.add(r.raw)
    of raKa10099:
      listAttempts.add(attempt)
    else:
      raise sde("P-run rest_resp at seq " & $r.seq & " declares api_id " &
                strOf(r.raw, "api_id", "P-run rest_resp at seq " & $r.seq) &
                "; a P-run carries only ka10099 universe pages and " &
                "ka10081 captures")

  if capturedCount != blockRaws.len:
    raise sde("P-run manifest.captured_count " & $capturedCount &
              " does not equal the " & $blockRaws.len &
              " ka10081 rest_resp records (K = captured_count)")
  var capturedSeen = initHashSet[string]()
  for sym in captured:
    if sym in capturedSeen:
      raise sde("P-run captures symbol " & sym &
                " more than once: one symbol is one logical task")
    capturedSeen.incl(sym)

  var blockText = ""
  for raw in blockRaws:
    blockText.add(canonical(raw))
    blockText.add("\n")
  let blockHash = sha256Hex(blockText)
  if blockHash != seedSha:
    raise sde("P-run manifest.seed_sha256 mismatch: the ka10081 block's " &
              "canonical raw-line hash is " & blockHash & ", declared " &
              seedSha)

  var derivedUniverse: seq[string]
  var derivedTruncated = false
  case source
  of "explicit":
    hasExactKeys(uniCfg, ["source", "symbols"],
                 "P-run config.preopen_universe")
    for a in listAttempts:
      raise sde("P-run ka10099 rest_resp at seq " & $a.seqNo &
                " is outside the explicit preopen_universe: an explicit " &
                "universe declares its symbols and has no market-list " &
                "source")
    var seen = initHashSet[string]()
    for sym in strItems(arrOf(uniCfg, "symbols",
                              "P-run config.preopen_universe"),
                        "P-run config.preopen_universe.symbols"):
      if sym in seen:
        raise sde("P-run config.preopen_universe.symbols repeats symbol: " &
                  sym)
      seen.incl(sym)
      derivedUniverse.add(sym)
  of "ka10099":
    hasExactKeys(uniCfg, ["source", "market_codes", "page_cap"],
                 "P-run config.preopen_universe")
    let cfgMarkets = strItems(arrOf(uniCfg, "market_codes",
                                    "P-run config.preopen_universe"),
                              "P-run config.preopen_universe.market_codes")
    if cfgMarkets != marketCodes:
      raise sde("P-run config.preopen_universe.market_codes does not " &
                "equal the manifest's market_codes")
    let pageCap = intOf(uniCfg, "page_cap",
                        "P-run config.preopen_universe")
    if pageCap < 1:
      raise sde("P-run config.preopen_universe.page_cap must be >= 1")
    derivedUniverse = deriveKa10099(listAttempts, cfgMarkets, pageCap,
                                    derivedTruncated)
  else:
    raise sde("unreachable universe source: " & source)

  if derivedTruncated != truncated:
    raise sde("P-run manifest.universe.truncated is " & $truncated &
              " but the preserved chains say " & $derivedTruncated)
  if symbolCount != derivedUniverse.len:
    raise sde("P-run manifest.universe.symbol_count " & $symbolCount &
              " does not equal the derived universe size " &
              $derivedUniverse.len)

  var universeSeen = initHashSet[string]()
  for sym in derivedUniverse:
    if sym in universeSeen:
      raise sde("P-run declared universe repeats symbol: " & sym)
    universeSeen.incl(sym)
  for sym in captured:
    if sym notin universeSeen:
      raise sde("P-run captures symbol " & sym &
                " outside the declared universe")

  var derivedFailed: seq[string]
  for sym in derivedUniverse:
    if sym notin capturedSeen:
      derivedFailed.add(sym)
  let declaredFailed = manifestFailed(manifest)
  var failed: seq[string]
  if manifest.has("failed"):
    if declaredFailed.len != derivedFailed.len:
      raise sde("P-run manifest.failed has " & $declaredFailed.len &
                " symbols; the universe minus captures has " &
                $derivedFailed.len)
    var derivedSet = initHashSet[string]()
    for sym in derivedFailed: derivedSet.incl(sym)
    for sym in declaredFailed:
      if sym notin derivedSet:
        raise sde("P-run manifest.failed symbol " & sym &
                  " is not an uncaptured universe symbol")
    failed = declaredFailed
  else:
    failed = derivedFailed
  if captureFailedCount != failed.len:
    raise sde("P-run manifest.capture_failed_count " & $captureFailedCount &
              " does not equal |failed| " & $failed.len)
  if symbolCount != capturedCount + failed.len:
    raise sde("P-run symbol_count " & $symbolCount &
              " does not equal captured_count " & $capturedCount &
              " + |failed| " & $failed.len)
  if historyShortCount > capturedCount:
    raise sde("P-run manifest.history_short_count " & $historyShortCount &
              " exceeds captured_count " & $capturedCount)

  result = DailySeed(
    seed: PreopenSeedDecl(
      sourceRunId: sourceRunId,
      sessionDate: sessionDate,
      seedSha256: seedSha,
      symbolCount: symbolCount,
      failed: failed,
      manifestSha256: sha256Hex(canonical(manifest) & "\n")),
    blockRaws: blockRaws)