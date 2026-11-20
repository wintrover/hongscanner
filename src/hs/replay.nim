## Core: records -> bars -> signals. Pure; reads only the record sequence.
## No wall clock, no filesystem, no arguments: every input that changes a
## verdict is inside input.hcj.jsonl (plan §3.0/§3.1).
import std/[strutils, algorithm, options]
import hcj, records, calendars, bars, engine, rest_resp, sub_input, vendor_input,
       tickwire, subcheck, event_gen, backfill, digest

type
  PreopenSeed* = object
    ## The optional config.preopen_seed declaration (REPLAY_CONTRACT
    ## §12.10.2): the S-run's binding to one P-run's ka10081 seed block.
    ## Absent config.preopen_seed = legacy: no block, no declared universe,
    ## every byte and verdict unchanged. Present, it is fail-closed: a
    ## malformed shape is REJECT, never a silent default.
    sourceRunId*: string
    sessionDate*: string
    seedSha256*: string
    symbolCount*: int
    failed*: seq[string]
    manifestSha256*: string

  PreopenUniverse* = object
    ## The optional config.preopen_universe declaration (REPLAY_CONTRACT
    ## §12.10.1): the P-run's universe source. Present = the stream is a
    ## P-run (REST-only capture, manifest last, no ws_frame/session_end);
    ## absent = legacy or S-run. Fail-closed: a malformed shape is REJECT,
    ## never a silent default.
    source*: string              ## "ka10099" or "explicit"
    marketCodes*: seq[string]    ## ka10099: declared market order
    symbols*: seq[string]        ## explicit: declared symbols
    pageCap*: int                ## ka10099: declared chain page cap

  Config* = object
    sessionDate*: string
    params*: Params
    ## Optional declared operating environment ("demo"|"real"; "" when the
    ## stream declares none). The marker-aware verify rules key on this
    ## field; a present-but-invalid value is a parse failure (fail-closed).
    environment*: string
    ## The declared re-poll cadence in seconds (config.repoll_seconds;
    ## 0 = undeclared). Declared, it opens rest_resp's approved multi-round
    ## page-chain audit (rest_resp.verifyAttempts); undeclared, the
    ## chain-restart REJECT stays in force.
    repollSeconds*: int
    ## The declared page cap (config.page_cap; defaultPageCap when absent).
    pageCap*: int
    ## Optional config.daily_scope (REPLAY_CONTRACT §12.9): "" = legacy
    ## scope. Read only to derive the pre-open sweep universe when
    ## config.preopen_seed is present (§12.10.5); the collector records it
    ## and this parser accepts the same vocabulary, fail-closed.
    dailyScope*: string
    ## Optional config.preopen_seed (REPLAY_CONTRACT §12.10.2).
    preopenSeed*: Option[PreopenSeed]
    ## Optional config.preopen_universe (REPLAY_CONTRACT §12.10.1): the
    ## P-run declaration. Mutually exclusive with preopen_seed (a stream
    ## is an S-run or a P-run, never both).
    preopenUniverse*: Option[PreopenUniverse]

  RunStatus* = enum
    rsOk, rsIncomplete, rsUnreliableFlag

  CoreResult* = object
    status*: RunStatus
    bars*: seq[Bar]
    signals*: seq[Signal]
    config*: Config
    spec*: SessionSpec
    frames*: int
    conflicts*: int
    ignoredKinds*: int
    ## rest_resp pages whose declared page chain verified as confirmed
    ## success (REPLAY_CONTRACT §12.1). Minimal consumption record: there is
    ## no live collector yet, so a verified page never moves the verdict --
    ## bars and signals stay exactly the stream's tick-derived output.
    restVerified*: int
    ## Subscription-evidence records consumed (schema-validated, §12.5).
    ## Like restVerified: counted, never moved by them, and they change no
    ## output byte.
    subCount*: int
    wsRawCount*: int
    ## §12.5/§10 consumption checks (subcheck), recomputed deterministically
    ## over the stream-order sub/ws_raw evidence. Quarantined 0B ticks never
    ## fed bars or signals; the count and the first reasons are reported.
    ## Quarantine is NOT a REJECT and never moves a verdict.
    quarantined*: int
    quarantineNotes*: seq[string]
    regAcks0B*: int
    removeAcks0B*: int
    ## The distinct observed FID 215 values, in first-observation order,
    ## re-derived from the 0s ws_raw payloads (the close-evidence subset is
    ## tickwire.closeEvidence215).
    closeValues*: seq[string]
    ## The event facts (REPLAY_CONTRACT §13), as canonical HCJ lines in
    ## judgment order: the single judgment function (event_gen.step)
    ## folded over the recorded stream in seq order, then its
    ## end-of-stream judgment. Produced by exactly one fold, shared with
    ## the live path — there is no second event judgment.
    events*: seq[string]

proc intOr(raw: HcjValue; key: string; dflt: int): int =
  if raw.kind == hkObj and raw.has(key) and raw.get(key).kind == hkInt:
    int(raw.get(key).ival)
  else:
    dflt

proc boolOr(raw: HcjValue; key: string; dflt: bool): bool =
  if raw.kind == hkObj and raw.has(key) and raw.get(key).kind == hkBool:
    raw.get(key).bval
  else:
    dflt

const
  ## The exact declared shape of config.preopen_seed (§12.10.2). Present,
  ## every field is required and nothing else is admitted.
  preopenSeedFields = ["failed", "manifest_sha256", "seed_sha256",
                       "session_date", "source_run_id", "symbol_count"]

  ## The two declared config.preopen_universe shapes (§12.10.1). Present,
  ## exactly one shape is admitted, every field is required and nothing
  ## else is allowed.
  preopenUniverseKa10099 = "ka10099"
  preopenUniverseExplicit = "explicit"
  preopenUniverseFieldsKa10099 = ["market_codes", "page_cap", "source"]
  preopenUniverseFieldsExplicit = ["source", "symbols"]

  ## The 12th kind's exact shape in a P-run (§12.10.1). The manifest has
  ## no `failed` array: a failed capture is the daily_capture_failed gap
  ## record (this is the collector's §12.9 vocabulary), so the declared
  ## failed set is re-derived from the stream itself.
  preopenManifestFields = [
    "binary_sha256", "capture_failed_count", "capture_window",
    "captured_count", "config_sha256", "history_short_count", "seed_sha256",
    "session_date", "source_run_id", "universe"]
  preopenManifestUniverseFields = [
    "market_codes", "source", "symbol_count", "truncated", "universe_sha256"]
  preopenManifestWindowFields = ["ended_at", "started_at"]
  dailyCaptureFailedWhat = "daily_capture_failed"

proc isSha256Hex(s: string): bool =
  ## The declared hash form: 64 lowercase hex digits (the digest.sha256Hex
  ## output). Anything else cannot be a recorded sha256 and is a shape
  ## failure, never a value to compare loosely.
  s.len == 64 and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc seedStr(seed: HcjValue; key: string): string =
  let v = seed.get(key)
  if v.kind != hkStr:
    raise newException(RecordError,
      "config.preopen_seed." & key & " is not a string: " & kindName(v))
  if v.strVal.len == 0:
    raise newException(RecordError,
      "config.preopen_seed." & key & " must not be empty")
  v.strVal

proc parsePreopenSeed(raw: HcjValue; sessionDate: string): PreopenSeed =
  ## The optional seed declaration: absent = legacy (the caller never
  ## reaches here); present = fail-closed. Unknown/missing fields, wrong
  ## types, duplicate failed symbols and an impossible count are REJECT,
  ## never silently defaulted (REPLAY_CONTRACT §12.10.2).
  if raw.kind != hkObj:
    raise newException(RecordError,
      "config.preopen_seed is not an object: " & kindName(raw))
  for p in raw.pairs:
    if p.k notin preopenSeedFields:
      raise newException(RecordError,
        "config.preopen_seed has an unknown field: " & p.k &
        " (the declared shape is exactly " & preopenSeedFields.join(", ") & ")")
  for k in preopenSeedFields:
    if not raw.has(k):
      raise newException(RecordError,
        "config.preopen_seed is missing field: " & k)
  result.sourceRunId = seedStr(raw, "source_run_id")
  result.sessionDate = seedStr(raw, "session_date")
  if result.sessionDate != sessionDate:
    raise newException(RecordError,
      "config.preopen_seed.session_date " & result.sessionDate &
      " does not equal config.session_date " & sessionDate)
  result.seedSha256 = seedStr(raw, "seed_sha256")
  if not isSha256Hex(result.seedSha256):
    raise newException(RecordError,
      "config.preopen_seed.seed_sha256 is not a 64-digit lowercase sha256: " &
      result.seedSha256)
  result.manifestSha256 = seedStr(raw, "manifest_sha256")
  if not isSha256Hex(result.manifestSha256):
    raise newException(RecordError,
      "config.preopen_seed.manifest_sha256 is not a 64-digit lowercase " &
      "sha256: " & result.manifestSha256)
  let sc = raw.get("symbol_count")
  if sc.kind != hkInt:
    raise newException(RecordError,
      "config.preopen_seed.symbol_count is not an integer: " & kindName(sc))
  if sc.ival < 0:
    raise newException(RecordError,
      "config.preopen_seed.symbol_count must be >= 0: " & $sc.ival)
  result.symbolCount = int(sc.ival)
  let failed = raw.get("failed")
  if failed.kind != hkArr:
    raise newException(RecordError,
      "config.preopen_seed.failed is not an array: " & kindName(failed))
  for item in failed.items:
    if item.kind != hkStr:
      raise newException(RecordError,
        "config.preopen_seed.failed element is not a string: " & kindName(item))
    let sym = item.strVal
    if sym.len == 0:
      raise newException(RecordError,
        "config.preopen_seed.failed carries an empty symbol")
    if sym in result.failed:
      raise newException(RecordError,
        "config.preopen_seed.failed repeats symbol: " & sym)
    result.failed.add(sym)
  if result.symbolCount < result.failed.len:
    raise newException(RecordError,
      "config.preopen_seed.symbol_count " & $result.symbolCount &
      " is below |failed| " & $result.failed.len &
      " (symbol_count == K + |failed|, §12.10.2)")

proc requireExactFields(raw: HcjValue; fields: openArray[string];
                        what: string) =
  ## Exact-shape check: an object with every declared field and nothing
  ## else. Used by the P-run declarations, where a producer typo must be a
  ## REJECT rather than a silently ignored field (§12.10.1).
  if raw.kind != hkObj:
    raise newException(RecordError, what & " is not an object: " & kindName(raw))
  for p in raw.pairs:
    if p.k notin fields:
      raise newException(RecordError,
        what & " has an unknown field: " & p.k & " (the declared shape is " &
        "exactly " & fields.join(", ") & ")")
  for f in fields:
    if not raw.has(f):
      raise newException(RecordError, what & " is missing field: " & f)

proc strList(v: HcjValue; what: string; requireNonEmpty: bool): seq[string] =
  ## A declared list of non-empty strings. Duplicates are preserved here;
  ## the caller owns whether they are deduped or rejected.
  if v.kind != hkArr:
    raise newException(RecordError, what & " is not an array: " & kindName(v))
  if requireNonEmpty and v.items.len == 0:
    raise newException(RecordError, what & " must not be empty")
  for item in v.items:
    if item.kind != hkStr:
      raise newException(RecordError,
        what & " element is not a string: " & kindName(item))
    if item.strVal.len == 0:
      raise newException(RecordError, what & " carries an empty string")
    result.add(item.strVal)

proc parsePreopenUniverse(raw: HcjValue): PreopenUniverse =
  ## The optional P-run universe declaration (§12.10.1): exactly
  ## {"source":"ka10099","market_codes":[...],"page_cap":N} or
  ## {"source":"explicit","symbols":[...]}. Unknown/missing fields, empty
  ## lists and a bad page cap are REJECT — a P-run whose universe cannot
  ## be derived is not a capture.
  if raw.kind != hkObj:
    raise newException(RecordError,
      "config.preopen_universe is not an object: " & kindName(raw))
  if not raw.has("source"):
    raise newException(RecordError,
      "config.preopen_universe is missing field: source")
  let src = raw.get("source")
  if src.kind != hkStr:
    raise newException(RecordError,
      "config.preopen_universe.source is not a string: " & kindName(src))
  result.source = src.strVal
  case result.source
  of preopenUniverseKa10099:
    requireExactFields(raw, preopenUniverseFieldsKa10099,
                       "config.preopen_universe")
    result.marketCodes = strList(raw.get("market_codes"),
      "config.preopen_universe.market_codes", requireNonEmpty = true)
    for i, m in result.marketCodes:
      for j in 0 ..< i:
        if result.marketCodes[j] == m:
          raise newException(RecordError,
            "config.preopen_universe.market_codes repeats market: " & m &
            " (declared market order is the universe authority)")
    let pc = raw.get("page_cap")
    if pc.kind != hkInt:
      raise newException(RecordError,
        "config.preopen_universe.page_cap is not an integer: " & kindName(pc))
    if pc.ival < 1:
      raise newException(RecordError,
        "config.preopen_universe.page_cap must be >= 1: " & $pc.ival)
    result.pageCap = int(pc.ival)
  of preopenUniverseExplicit:
    requireExactFields(raw, preopenUniverseFieldsExplicit,
                       "config.preopen_universe")
    result.symbols = strList(raw.get("symbols"),
      "config.preopen_universe.symbols", requireNonEmpty = true)
    result.pageCap = 0
  else:
    raise newException(RecordError,
      "config.preopen_universe.source must be \"" & preopenUniverseKa10099 &
      "\" or \"" & preopenUniverseExplicit & "\": " & result.source)

proc parseConfig*(raw: HcjValue): Config =
  if raw.kind != hkObj:
    raise newException(RecordError, "config raw is not an object")
  if not raw.has("session_date"):
    raise newException(RecordError, "config.session_date is required")
  result.sessionDate = raw.get("session_date").asStr
  # environment is optional (absent = the stream declares no operating
  # environment; every existing synthetic stream stays valid). Present,
  # it is fail-closed: only the string "demo" or "real" is accepted --
  # another value or a non-string type is a contract violation, never a
  # default. The verify commit-marker rules key on this field. ("prod" is
  # a retired name: it was never produced by a sealed run, and the
  # environment naming is unified on demo|real.)
  if raw.has("environment"):
    let e = raw.get("environment")
    if e.kind != hkStr:
      raise newException(RecordError,
        "config.environment is not a string: " & kindName(e))
    if e.strVal != "demo" and e.strVal != "real":
      raise newException(RecordError,
        "config.environment is not demo|real: " & e.strVal)
    result.environment = e.strVal
  # The declared re-poll cadence and page cap (tools/collector/README.md
  # §6.1): both optional, both fail-closed on a wrong type or a
  # non-positive value. repoll_seconds 0 means undeclared — the page-chain
  # audit stays single-round; page_cap defaults to the approved PH-1 value.
  result.repollSeconds = intOr(raw, "repoll_seconds", 0)
  if result.repollSeconds < 0:
    raise newException(RecordError,
      "config.repoll_seconds must be >= 0: " & $result.repollSeconds)
  if raw.has("page_cap"):
    let pc = raw.get("page_cap")
    if pc.kind != hkInt:
      raise newException(RecordError,
        "config.page_cap is not an integer: " & kindName(pc))
    if int(pc.ival) < 1:
      raise newException(RecordError,
        "config.page_cap must be >= 1: " & $pc.ival)
    result.pageCap = int(pc.ival)
  else:
    result.pageCap = defaultPageCap
  # config.daily_scope (REPLAY_CONTRACT §12.9): optional and absent/"" is
  # the legacy scope. It is read only by the pre-open seed's sweep-universe
  # derivation (§12.10.5); the collector's own vocabulary is reused
  # (vendor_input.dailyScope*) so the two parsers cannot drift. A present
  # value outside the declared vocabulary is fail-closed — never a silent
  # reinterpretation.
  if raw.has("daily_scope"):
    let ds = raw.get("daily_scope")
    if ds.kind != hkStr:
      raise newException(RecordError,
        "config.daily_scope is not a string: " & kindName(ds))
    if ds.strVal.len > 0 and ds.strVal != dailyScopeLegacy and
       ds.strVal != dailyScopeAccumulate:
      raise newException(RecordError,
        "config.daily_scope must be \"\", " & dailyScopeLegacy & " or " &
        dailyScopeAccumulate & ": " & ds.strVal)
    result.dailyScope = ds.strVal
  # config.preopen_seed (REPLAY_CONTRACT §12.10.2): optional. Absent is the
  # legacy S-run — no seed block and no declared universe, so every byte
  # and verdict stays as before. Present, the whole block is parsed here
  # (fail-closed shape) and audited against the records after the loop.
  if raw.has("preopen_seed"):
    result.preopenSeed = some(
      parsePreopenSeed(raw.get("preopen_seed"), result.sessionDate))
  # config.preopen_universe (REPLAY_CONTRACT §12.10.1): optional and
  # mutually exclusive with preopen_seed. Present = a P-run: its records
  # are audited against the declared universe source and its last record
  # is the manifest. Absent = legacy/S-run, every byte unchanged.
  if raw.has("preopen_universe"):
    result.preopenUniverse = some(
      parsePreopenUniverse(raw.get("preopen_universe")))
  if result.preopenSeed.isSome and result.preopenUniverse.isSome:
    raise newException(RecordError,
      "config declares both preopen_seed and preopen_universe: a stream is " &
      "an S-run (seed entry) or a P-run (universe capture), never both " &
      "(REPLAY_CONTRACT §12.10.1/§12.10.2)")
  # Symmetric judgment params (P23/§6). Each field is optional with a
  # declared default meaning "pre-contract" (P24 pattern): an absent or
  # legacy-named field (`lookback`, `pullback_min_bp`, ...) falls back to the
  # default — a stream sealed before the VS-1 rewrite replays under its own
  # commit's binary (§8 check 1), so old names reaching this parser are
  # ignored, never a crash. Values that are present but impossible
  # (negative bp thresholds, lookback_bars < 1, negative warmup) are parse
  # failures: fail-closed, never silently reinterpreted.
  # Default mapping from the legacy thresholds: countermove_min_bp 50 and
  # directional_trigger_bp 30 continue pullback_min_bp/rebound_min_bp 50 and
  # recovery_bp/breakdown_bp 30; trend_min_bp 50 starts at the same magnitude
  # family (a trend must not confirm below its own countermove); window
  # defaults keep lookback 3 / warmup 0. PH-1 freezes the real values.
  let p = if raw.has("params"): raw.get("params") else: hNull()
  result.params = Params(
    warmupBars: intOr(p, "warmup_bars", 0),
    lookbackBars: intOr(p, "lookback_bars", 3),
    trendMinBp: intOr(p, "trend_min_bp", 50),
    countermoveMinBp: intOr(p, "countermove_min_bp", 50),
    directionalTriggerBp: intOr(p, "directional_trigger_bp", 30),
    holdOnDegraded: boolOr(p, "hold_on_degraded", true))
  if result.params.warmupBars < 0:
    raise newException(RecordError,
      "params.warmup_bars must be >= 0: " & $result.params.warmupBars)
  if result.params.lookbackBars < 1:
    raise newException(RecordError,
      "params.lookback_bars must be >= 1: " & $result.params.lookbackBars)
  if result.params.trendMinBp < 0 or result.params.countermoveMinBp < 0 or
      result.params.directionalTriggerBp < 0:
    raise newException(RecordError,
      "params bp thresholds must be >= 0: trend=" &
        $result.params.trendMinBp & " countermove=" &
        $result.params.countermoveMinBp & " trigger=" &
        $result.params.directionalTriggerBp)

proc reqField(raw: HcjValue; key: string): HcjValue =
  if raw.kind != hkObj:
    raise newException(RecordError, "record raw is not an object")
  if not raw.has(key):
    raise newException(RecordError, "missing field: " & key)
  raw.get(key)

proc flagOf(raw: HcjValue): string =
  ## Field 290 (session class) as a raw string; "" when absent.
  if raw.kind == hkObj and raw.has("m"):
    let n = raw.get("m")
    if n.kind == hkStr: return n.strVal
    if n.kind == hkInt: return $n.ival
  ""

proc barLine*(bar: Bar): string =
  ## The §7 bar line. `origin` is the optional P21 field: emitted ONLY as
  ## "BACKFILL" on ka10080-derived bars; a LIVE bar (origin == "") emits no
  ## origin field at all, so pre-contract streams and live-only runs stay
  ## byte-identical to the old format (the optional-field principle,
  ## REPLAY_CONTRACT §7).
  var pairs: seq[HcjPair] = @[
    ("bar_index", hInt(bar.index)),
    ("bar_position", hStr(bar.pos)),
    ("close", hInt(bar.close)),
    ("close_boundary", hBool(bar.closeBoundary)),
    ("closed", hBool(bar.closed)),
    ("degraded", hBool(bar.degraded)),
    ("empty", hBool(bar.empty)),
    ("gap_edge", hStr(bar.gapEdge)),
    ("high", hInt(bar.high)),
    ("low", hInt(bar.low)),
    ("open", hInt(bar.open)),
    ("out_of_order", hBool(bar.outOfOrder)),
    ("session_class", hStr(bar.sessionClass)),
    ("symbol", hStr(bar.symbol)),
    ("ticks", hInt(bar.ticks)),
    ("vol", hInt(bar.vol)),
    ("vol_partial", hBool(bar.volPartial))]
  if bar.origin.len > 0:
    if bar.origin != backfillOrigin:
      raise newException(RecordError,
        "bar origin " & bar.origin & " is outside the declared vocabulary " &
        "(only " & backfillOrigin & " exists; LIVE is the absent field)")
    pairs.add(("origin", hStr(bar.origin)))
  canonical(HcjValue(kind: hkObj, pairs: pairs))

proc signalLine*(s: Signal): string =
  canonical(hObj(
    ("bar_index", hInt(s.barIndex)),
    ("price", hInt(s.price)),
    ("reason", hStr(s.reason)),
    ("session_date", hStr(s.sessionDate)),
    ("signal", hStr(s.signal)),
    ("symbol", hStr(s.symbol))))

proc restRejection(seqNo: int; detail: string): string =
  ## Explicit REJECT text for a rest_resp that failed the validated
  ## acceptance path: always names the record, its seq and the verification
  ## boundary, so a rejection is self-explaining on the CLI.
  "rest_resp at seq " & $seqNo & " is rejected: " & detail &
  " (acceptance needs a declared request scope, a preserved response and " &
  "a page chain that affirms success; the live REST wire format is " &
  "unverified by a measured producer (G2/G4), so no unconfirmed state can " &
  "mean success)"

proc schemaRejection(kindNameText: string; seqNo: int; detail: string): string =
  ## Explicit REJECT text for a sub/ws_raw record that failed its schema:
  ## names the record, its seq and the boundary, like restRejection.
  kindNameText & " at seq " & $seqNo & " is rejected: " & detail &
  " (acceptance needs exactly the declared schema fields for the " &
  "record's (action, phase) combination; the live subscription wire " &
  "format is unverified by a measured producer (G2/G4), so any schema " &
  "doubt is a failure)"

proc roundChain(round: seq[RestRespAttempt]): PageChain =
  ## One audited page round as the vendor_input chain shape (the same
  ## grouping verifyAttempts audits).
  var pages: seq[RawHttpResp]
  for a in round: pages.add(a.resp)
  PageChain(query: round[0].scope, pages: pages)

proc roundTruncated(round: seq[RestRespAttempt]; pageCap: int): bool =
  ## The cap-closed declared-subset state verifyAttempts admits: the last
  ## page still says cont-yn=Y at the declared cap. Never inferred below
  ## the cap (a missing continuation stays a REJECT).
  round.len > 0 and round[^1].resp.contYn == "Y" and round.len >= pageCap

proc sweepUniverseOf(attempts: seq[RestRespAttempt]; pageCap: int;
                     accumulate: bool): seq[string] =
  ## The §12.9 sweep queue as replay derives it from the ka10027 chains:
  ## the initial up/down pair's interleaved universe (the one definition,
  ## vendor_input.interleaveUniverse, that the collector's dailyUniverseOf
  ## uses), extended by each later complete poll pair's new symbols only
  ## under accumulate-v2. Rounds split at each page-1 record exactly as
  ## verifyAttempts audits them. Every round is re-validated by
  ## chainSymbols (the same page/affirmation rules normalizeChain applies
  ## in verifyAttempts), so a chain that would fail the audit contributes
  ## no symbol — it rejects the run before any verification result exists.
  var upRounds, downRounds: seq[seq[RestRespAttempt]]
  for a in attempts:
    if a.api != raKa10027: continue
    if a.scope.direction == dirUp:
      if a.page == 1 or upRounds.len == 0: upRounds.add(@[a])
      else: upRounds[^1].add(a)
    else:
      if a.page == 1 or downRounds.len == 0: downRounds.add(@[a])
      else: downRounds[^1].add(a)
  let pairs = min(upRounds.len, downRounds.len)
  let used = if accumulate: pairs else: min(pairs, 1)
  for i in 0 ..< used:
    let up = roundChain(upRounds[i])
    let down = roundChain(downRounds[i])
    let upCodes = chainSymbols(ka10027Spec, up, pageCap,
                               roundTruncated(upRounds[i], pageCap))
    let downCodes = chainSymbols(ka10027Spec, down, pageCap,
                                 roundTruncated(downRounds[i], pageCap))
    for sym in interleaveUniverse(upCodes, downCodes):
      if sym notin result:
        result.add(sym)

proc seedDeclaredSymbols(seed: PreopenSeed; recs: seq[Record];
                         attempts: seq[RestRespAttempt];
                         pageCap: int; accumulate: bool): seq[string] =
  ## Audit the §12.10.2 seed block against the recorded stream and return
  ## the declared ka10081 universe for verifyAttempts (§12.10.5):
  ## block symbols ∪ failed ∪ the replay-derived sweep queue. K is
  ## symbol_count - |failed|; the block is the first K ka10081 rest_resp
  ## records after record 2. Every condition is fail-closed: a missing
  ## block, a hash mismatch, an overlap or a duplicate is a REJECT.
  let k = seed.symbolCount - seed.failed.len
  var daily: seq[RestRespAttempt]
  for a in attempts:
    if a.api == raKa10081: daily.add(a)
  if daily.len < k:
    raise newException(RecordError,
      "preopen_seed block is missing: K = symbol_count " & $seed.symbolCount &
      " - |failed| " & $seed.failed.len & " = " & $k & " ka10081 block " &
      "records expected, " & $daily.len & " recorded (REPLAY_CONTRACT §12.10.2)")
  var blockSymbols, affirming: seq[string]
  for i, a in daily:
    let sym = a.scope81.stkCd
    if sym in affirming:
      raise newException(RecordError,
        "preopen_seed ka10081 scope repeats symbol " & sym & " at seq " &
        $a.seqNo & ": one symbol is one logical capture task (§12.9/§12.10.2)")
    affirming.add(sym)
    if i < k: blockSymbols.add(sym)
  # seed_sha256 = sha256 over the block's canonical raw lines in order,
  # seq excluded: canonical(raw) followed by LF per record, exactly the
  # line form the P-run manifest declares (§12.10.1/§12.10.2).
  var blockText = ""
  for i in 0 ..< k:
    blockText.add(canonical(recs[daily[i].seqNo - 1].raw))
    blockText.add("\n")
  let blockHash = sha256Hex(blockText)
  if blockHash != seed.seedSha256:
    raise newException(RecordError,
      "preopen_seed.seed_sha256 mismatch: the block's canonical raw-line " &
      "hash is " & blockHash & ", declared " & seed.seedSha256 &
      " (the block is the first " & $k & " ka10081 rest_resp records after " &
      "record 2; REPLAY_CONTRACT §12.10.2)")
  # Block and failed are disjoint and duplicate-free; a failed capture is
  # not a rest_resp record, so a failed symbol with any affirming daily
  # record is REJECT.
  for sym in blockSymbols:
    if sym in seed.failed:
      raise newException(RecordError,
        "preopen_seed.symbol " & sym & " is both a block capture and a " &
        "declared failed capture (block and failed must be disjoint)")
  for sym in seed.failed:
    if sym in affirming:
      raise newException(RecordError,
        "preopen_seed.failed symbol " & sym & " also has an affirming " &
        "ka10081 record: a failed capture is not a rest_resp record " &
        "(REPLAY_CONTRACT §12.9/§12.10.2)")
  result = blockSymbols
  for sym in seed.failed:
    result.add(sym)
  var sweep: seq[string]
  try:
    sweep = sweepUniverseOf(attempts, pageCap, accumulate)
  except VendorInputError as e:
    raise newException(RecordError,
      "preopen_seed sweep universe is rejected: " & e.msg)
  for sym in sweep:
    if sym notin result:
      result.add(sym)

proc universeHash*(symbols: seq[string]): string =
  ## The declared universe_sha256 framing (REPLAY_CONTRACT §12.10.1):
  ## sha256 over each deduped symbol in universe order, each followed by
  ## LF. The empty input hashes the empty byte string; a P-run never
  ## declares an empty universe (it is REJECT before this is compared).
  var text = ""
  for sym in symbols:
    text.add(sym)
    text.add("\n")
  sha256Hex(text)

proc preopenUniverseOf*(uni: PreopenUniverse;
                        attempts: seq[RestRespAttempt]):
                        tuple[symbols: seq[string], truncated: bool] =
  ## Derive the P-run universe from the preserved chains (§12.10.1):
  ## explicit = the declared symbols deduped in order; ka10099 = declared
  ## market order, then page order, then row order, taking each row's
  ## `code` and deduping at first appearance. Every declared ka10099
  ## market must have its own 1..N chain, and a ka10099 market outside the
  ## declaration is REJECT — the universe is exactly what the P-run
  ## declared. Each chain is re-validated by ka10099ChainSymbols (the same
  ## affirmation/cont-yn/cap rules verifyAttempts audits); a cap-closed
  ## chain sets truncated. An empty derived universe is REJECT: a P-run
  ## that captured no symbol is not a capture.
  if uni.source == preopenUniverseExplicit:
    for a in attempts:
      if a.api == raKa10099:
        raise newException(RecordError,
          "ka10099 capture at seq " & $a.seqNo & " is outside the explicit " &
          "preopen_universe: an explicit universe declares its symbols and " &
          "has no market-list source (REPLAY_CONTRACT §12.10.1)")
    for sym in uni.symbols:
      if sym notin result.symbols:
        result.symbols.add(sym)
  else:
    for a in attempts:
      if a.api == raKa10099 and a.scope99.mrktTp notin uni.marketCodes:
        raise newException(RecordError,
          "ka10099 market " & a.scope99.mrktTp & " at seq " & $a.seqNo &
          " is outside the declared preopen_universe.market_codes: an " &
          "undeclared market capture is not part of this P-run universe " &
          "(REPLAY_CONTRACT §12.10.1)")
    for m in uni.marketCodes:
      var chain: seq[RestRespAttempt]
      for a in attempts:
        if a.api == raKa10099 and a.scope99.mrktTp == m:
          chain.add(a)
      if chain.len == 0:
        raise newException(RecordError,
          "declared ka10099 market " & m & " has no page chain in the " &
          "P-run: every declared market is captured (REPLAY_CONTRACT §12.10.1)")
      for i, a in chain:
        if a.page != i + 1:
          raise newException(RecordError,
            "ka10099 market " & m & " page chain is not 1..N in stream " &
            "order (page " & $a.page & " at position " & $(i + 1) &
            ", seq " & $a.seqNo & "); rejected fail-closed")
      var pages: seq[RawHttpResp]
      for a in chain: pages.add(a.resp)
      let truncated = chain[^1].resp.contYn == "Y" and chain.len >= uni.pageCap
      var codes: seq[string]
      try:
        codes = ka10099ChainSymbols(pages, uni.pageCap, truncated)
      except VendorInputError as e:
        raise newException(RecordError,
          "ka10099 market " & m & " chain is rejected: " & e.msg)
      for cd in codes:
        if cd notin result.symbols:
          result.symbols.add(cd)
      if truncated:
        result.truncated = true
  if result.symbols.len == 0:
    raise newException(RecordError,
      "preopen_universe derives an empty symbol universe: a P-run that " &
      "captured no symbol is not a capture (REPLAY_CONTRACT §12.10.1)")

proc preopenFailedOf*(recs: seq[Record]): seq[string] =
  ## The declared failed captures of a P-run, re-derived from the stream:
  ## the manifest has no `failed` array, so every daily_capture_failed gap
  ## (§12.9) is the failure evidence. A symbol-less or repeated
  ## daily_capture_failed gap is REJECT — one symbol is one logical
  ## capture task, and a failure must name the symbol it excluded.
  for r in recs:
    if r.kind != kGap: continue
    let raw = r.raw
    if raw.kind != hkObj or not raw.has("what"): continue
    let w = raw.get("what")
    if w.kind != hkStr or w.strVal != dailyCaptureFailedWhat: continue
    let sym = raw.get("symbol")
    if sym.kind != hkStr or sym.strVal.len == 0:
      raise newException(RecordError,
        "P-run daily_capture_failed gap at seq " & $r.seq & " does not " &
        "carry its symbol: a failed capture must name the symbol it " &
        "excluded (§12.9/§12.10.1)")
    if sym.strVal in result:
      raise newException(RecordError,
        "P-run daily_capture_failed repeats symbol " & sym.strVal &
        " at seq " & $r.seq &
        ": one symbol is one logical capture task (§12.9)")
    result.add(sym.strVal)

proc fieldStr(raw: HcjValue; what, key: string): string =
  ## A required non-empty string field of an exact-shaped object.
  let v = raw.get(key)
  if v.kind != hkStr:
    raise newException(RecordError,
      what & "." & key & " is not a string: " & kindName(v))
  if v.strVal.len == 0:
    raise newException(RecordError, what & "." & key & " must not be empty")
  v.strVal

proc fieldInt(raw: HcjValue; what, key: string): int =
  ## A required non-negative integer field of an exact-shaped object.
  let v = raw.get(key)
  if v.kind != hkInt:
    raise newException(RecordError,
      what & "." & key & " is not an integer: " & kindName(v))
  if v.ival < 0:
    raise newException(RecordError,
      what & "." & key & " must be >= 0: " & $v.ival)
  int(v.ival)

proc fieldHash(raw: HcjValue; what, key: string): string =
  ## A required 64-lowercase-hex sha256 field.
  let s = fieldStr(raw, what, key)
  if not isSha256Hex(s):
    raise newException(RecordError,
      what & "." & key & " is not a 64-digit lowercase sha256: " & s)
  s

proc captureStamp(s: string; what: string): tuple[date: string, sec: int] =
  ## Exactly "YYYY-MM-DDTHH:MM:SS+09:00": the declared KST capture-window
  ## form (§12.10.1). A pure format/range check plus calendars.hmsToSec —
  ## a comparison of two recorded values, never a clock input. The offset
  ## must be exactly +09:00 (KST); any other zone is outside the
  ## declaration.
  if s.len != 25 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or
     s[13] != ':' or s[16] != ':' or s[19] != '+' or s[22] != ':' or
     s[20] != '0' or s[21] != '9' or s[23] != '0' or s[24] != '0':
    raise newException(RecordError,
      what & " is not YYYY-MM-DDTHH:MM:SS+09:00: " & s)
  for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]:
    if s[i] notin {'0' .. '9'}:
      raise newException(RecordError,
        what & " is not YYYY-MM-DDTHH:MM:SS+09:00: " & s)
  let mon = (ord(s[5]) - ord('0')) * 10 + (ord(s[6]) - ord('0'))
  let day = (ord(s[8]) - ord('0')) * 10 + (ord(s[9]) - ord('0'))
  if mon < 1 or mon > 12 or day < 1 or day > 31:
    raise newException(RecordError, what & " has an impossible date: " & s)
  var sec = 0
  try:
    sec = hmsToSec(s[11 .. ^1])
  except CoverageError as e:
    raise newException(RecordError, what & ": " & e.msg)
  result = (s[0 .. 9], sec)

proc validatePreopenManifest*(manifest: HcjValue; uni: PreopenUniverse;
                              sessionDate: string; openSec: int;
                              attempts: seq[RestRespAttempt];
                              recs: seq[Record]; universe: seq[string];
                              truncated: bool; failed: seq[string]) =
  ## Audit the P-run seal against the stream it closes (§12.10.1): the
  ## exact manifest shape, the universe declaration/derivation (source,
  ## market order, count, hash, truncation), the ka10081 capture set and
  ## its seed hash, the failed set, and the capture window. Every
  ## violation is REJECT. `attempts` are the verified rest_resp attempts
  ## (the ka10081 subset is the captured set); `recs` supplies the
  ## canonical raw lines the seed hash binds; `universe`/`truncated`/
  ## `failed` are the values replay derived from the records themselves.
  requireExactFields(manifest, preopenManifestFields, "daily_seed_manifest")
  discard fieldStr(manifest, "daily_seed_manifest", "source_run_id")
  let sd = fieldStr(manifest, "daily_seed_manifest", "session_date")
  if sd != sessionDate:
    raise newException(RecordError,
      "daily_seed_manifest.session_date " & sd & " does not equal " &
      "config.session_date " & sessionDate)
  # universe{source, market_codes, symbol_count, universe_sha256, truncated}
  let uv = manifest.get("universe")
  requireExactFields(uv, preopenManifestUniverseFields,
                     "daily_seed_manifest.universe")
  let uSource = fieldStr(uv, "daily_seed_manifest.universe", "source")
  if uSource != uni.source:
    raise newException(RecordError,
      "daily_seed_manifest.universe.source " & uSource & " does not equal " &
      "config.preopen_universe.source " & uni.source)
  let mc = uv.get("market_codes")
  if mc.kind != hkArr:
    raise newException(RecordError,
      "daily_seed_manifest.universe.market_codes is not an array: " &
      kindName(mc))
  var mCodes: seq[string]
  for item in mc.items:
    if item.kind != hkStr:
      raise newException(RecordError,
        "daily_seed_manifest.universe.market_codes element is not a string: " &
        kindName(item))
    mCodes.add(item.strVal)
  if uni.source == preopenUniverseExplicit:
    if mCodes.len != 0:
      raise newException(RecordError,
        "daily_seed_manifest.universe.market_codes must be empty for an " &
        "explicit universe, got " & $mCodes.len & " entries")
  else:
    if mCodes != uni.marketCodes:
      raise newException(RecordError,
        "daily_seed_manifest.universe.market_codes does not equal the " &
        "declared market order (" & mCodes.join(",") & " vs " &
        uni.marketCodes.join(",") & ")")
  let uCount = fieldInt(uv, "daily_seed_manifest.universe", "symbol_count")
  if uCount != universe.len:
    raise newException(RecordError,
      "daily_seed_manifest.universe.symbol_count " & $uCount &
      " does not equal the derived universe size " & $universe.len)
  let uHash = fieldHash(uv, "daily_seed_manifest.universe", "universe_sha256")
  let derivedUHash = universeHash(universe)
  if uHash != derivedUHash:
    raise newException(RecordError,
      "daily_seed_manifest.universe.universe_sha256 mismatch: the derived " &
      "universe hash is " & derivedUHash & ", declared " & uHash &
      " (framing: each deduped symbol + LF, universe order, §12.10.1)")
  let tr = uv.get("truncated")
  if tr.kind != hkBool:
    raise newException(RecordError,
      "daily_seed_manifest.universe.truncated is not a boolean: " &
      kindName(tr))
  if tr.bval != truncated:
    raise newException(RecordError,
      "daily_seed_manifest.universe.truncated is " & $tr.bval &
      " but the derived chains say " & $truncated &
      " (any chain closed at the declared cap while cont-yn=Y is a " &
      "declared truncated subset, §12.10.1)")
  # The captured set: every verified ka10081 record, in stream order, and
  # its canonical raw-line hash (the §12.10.1 seed framing).
  var captured: seq[string]
  var seedText = ""
  for a in attempts:
    if a.api != raKa10081: continue
    let sym = a.scope81.stkCd
    if sym in captured:
      raise newException(RecordError,
        "P-run ka10081 scope repeats symbol " & sym &
        ": one symbol is one logical capture task (§12.9)")
    captured.add(sym)
    seedText.add(canonical(recs[a.seqNo - 1].raw))
    seedText.add("\n")
  let seedHash = sha256Hex(seedText)
  let declaredSeed = fieldHash(manifest, "daily_seed_manifest", "seed_sha256")
  if declaredSeed != seedHash:
    raise newException(RecordError,
      "daily_seed_manifest.seed_sha256 mismatch: the ka10081 canonical " &
      "raw-line hash is " & seedHash & ", declared " & declaredSeed &
      " (framing: canonical(raw) + LF per record, stream order, seq excluded)")
  let capturedCount = fieldInt(manifest, "daily_seed_manifest", "captured_count")
  if capturedCount != captured.len:
    raise newException(RecordError,
      "daily_seed_manifest.captured_count " & $capturedCount &
      " does not equal the ka10081 record count " & $captured.len)
  let failedCount = fieldInt(manifest, "daily_seed_manifest",
                             "capture_failed_count")
  if failedCount != failed.len:
    raise newException(RecordError,
      "daily_seed_manifest.capture_failed_count " & $failedCount &
      " does not equal the derived failed set size " & $failed.len)
  let shortCount = fieldInt(manifest, "daily_seed_manifest",
                            "history_short_count")
  if shortCount > captured.len:
    raise newException(RecordError,
      "daily_seed_manifest.history_short_count " & $shortCount &
      " exceeds captured_count " & $captured.len)
  if captured.len + failed.len != universe.len:
    raise newException(RecordError,
      "captured " & $captured.len & " + failed " & $failed.len &
      " does not equal the universe size " & $universe.len &
      " (symbol_count == captured_count + capture_failed_count, §12.10.1)")
  for sym in captured:
    if sym notin universe:
      raise newException(RecordError,
        "captured symbol " & sym & " is outside the derived universe")
    if sym in failed:
      raise newException(RecordError,
        "symbol " & sym & " is both captured and failed: the sets must be " &
        "disjoint (§12.10.1)")
  for sym in failed:
    if sym notin universe:
      raise newException(RecordError,
        "failed symbol " & sym & " is outside the derived universe")
  for sym in universe:
    if sym notin captured and sym notin failed:
      raise newException(RecordError,
        "universe symbol " & sym & " is neither captured nor failed: " &
        "captured ∪ failed must equal the universe (§12.10.1)")
  # capture_window{started_at, ended_at}: recorded KST values compared
  # with the calendar's open for the session date, never a clock.
  let cw = manifest.get("capture_window")
  requireExactFields(cw, preopenManifestWindowFields,
                     "daily_seed_manifest.capture_window")
  let started = captureStamp(fieldStr(cw, "daily_seed_manifest.capture_window",
                                      "started_at"),
                             "daily_seed_manifest.capture_window.started_at")
  let ended = captureStamp(fieldStr(cw, "daily_seed_manifest.capture_window",
                                    "ended_at"),
                           "daily_seed_manifest.capture_window.ended_at")
  if started.date != sessionDate or ended.date != sessionDate:
    raise newException(RecordError,
      "daily_seed_manifest.capture_window dates " & started.date & ".." &
      ended.date & " are not the session date " & sessionDate)
  if started.sec > ended.sec:
    raise newException(RecordError,
      "daily_seed_manifest.capture_window.started_at is after ended_at: " &
      "an impossible capture window")
  if ended.sec >= openSec:
    raise newException(RecordError,
      "daily_seed_manifest.capture_window.ended_at is not strictly before " &
      "the session open: a P-run must close before the market opens " &
      "(REPLAY_CONTRACT §12.10.1)")
  discard fieldHash(manifest, "daily_seed_manifest", "binary_sha256")
  discard fieldHash(manifest, "daily_seed_manifest", "config_sha256")

proc runCore*(recs: seq[Record]): CoreResult =
  validateRecords(recs)
  let cal = recs[0].raw
  result.config = parseConfig(recs[1].raw)
  result.spec = sessionFor(cal, result.config.sessionDate)
  # A config.preopen_universe declaration makes this a P-run
  # (REPLAY_CONTRACT §12.10.1): a REST-only pre-open capture whose seal is
  # the daily_seed_manifest, exactly the last record. No ws_frame and no
  # session_end belongs to it; anything after the manifest is outside the
  # declared capture. These structural facts are checked before any
  # consumption so a malformed P-run is REJECT, never a partial capture.
  let pRun = result.config.preopenUniverse.isSome
  if pRun:
    if recs[^1].kind != kDailySeedManifest:
      raise newException(RecordError,
        "P-run seal is not the last record: the last record is " &
        kindName(recs[^1].kind) & " at seq " & $recs[^1].seq & "; the " &
        "daily_seed_manifest must close the stream " &
        "(REPLAY_CONTRACT §12.10.1)")
    var manifests = 0
    for r in recs:
      case r.kind
      of kWsFrame:
        raise newException(RecordError,
          "P-run carries a ws_frame at seq " & $r.seq & ": the pre-open " &
          "capture is REST-only, with no tick stream " &
          "(REPLAY_CONTRACT §12.10.1)")
      of kSessionEnd:
        raise newException(RecordError,
          "P-run carries a session_end at seq " & $r.seq & ": a P-run has " &
          "no session seal; its seal is the daily_seed_manifest " &
          "(REPLAY_CONTRACT §12.10.1)")
      of kDailySeedManifest:
        inc manifests
      else: discard
    if manifests != 1:
      raise newException(RecordError,
        "P-run must carry exactly one daily_seed_manifest as its last " &
        "record, found " & $manifests & " (REPLAY_CONTRACT §12.10.1)")
  # The event facts (REPLAY_CONTRACT §13): one fold of the single
  # judgment function over the recorded stream, before the bars loop so
  # the judgment consumes exactly the recorded records in seq order
  # (§13.2/§13.3). A judgment-layer failure is a contract failure of the
  # run, never a silent pass.
  try:
    result.events = eventsOfRecords(recs)
  except EventGenError as e:
    raise newException(RecordError, e.msg)
  var b = initBars(result.spec)
  var sawEnd = false
  var restAttempts: seq[RestRespAttempt] = @[]
  var guard = initSubGuard()
  for i in 2 ..< recs.len:
    case recs[i].kind
    of kWsFrame:
      let raw = recs[i].raw
      let symbol = reqField(raw, "symbol").asStr
      let t = reqField(raw, "t").asStr
      let price = reqField(raw, "price").asInt
      let vol = reqField(raw, "vol").asInt
      let tSec = hmsToSec(t) - result.spec.openSec
      feedTick(b, symbol, tSec, price, vol, flagOf(raw))
    of kGap:
      let raw = recs[i].raw
      if raw.kind != hkObj:
        raise newException(RecordError, "gap raw is not an object")
      if not raw.has("symbol"):
        raise newException(RecordError, "gap raw has no symbol field")
      let sym = raw.get("symbol")
      if not sym.isNull and sym.kind != hkStr:
        raise newException(RecordError, "gap symbol is not a string or null")
      applyGap(b, if sym.isNull: "" else: sym.strVal)
    of kSessionEnd:
      if not recs[i].raw.isNull:
        raise newException(RecordError, "session_end raw is not null")
      sawEnd = true
      closeAtSessionEnd(b)
    of kRestResp:
      # VS-2 §12.1 validated acceptance path, replacing the VS-1 fail-closed
      # placeholder. A record is accepted only when its raw payload parses
      # against the rest_resp schema: a declared request scope (ka10027,
      # KRX-only, one query per direction), a 1-based page index, and the
      # preserved original HTTP response (status, cont-yn/next-key, body
      # bytes byte-exact via body_hex). Schema failures reject here, at the
      # record's own seq. Success is affirmed by the vendor_input rules
      # only -- HTTP 200, return_code present + integer + 0, list key
      # present -- and body-level or chain-level failures (cont-yn repeat,
      # page cap, missing page, page order) still reject the whole run once
      # the stream is complete (see verifyAttempts after the loop).
      # Verified pages are counted in the result but do not move the
      # verdict: no live collector exists, so candidate-scope consumption
      # stays future work (G2/G4: no measured producer capture).
      try:
        restAttempts.add(parseAttempt(recs[i].seq, recs[i].raw))
      except RestRespError as e:
        raise newException(RecordError, restRejection(recs[i].seq, e.msg))
    of kCalendar, kConfig:
      discard
    of kSub, kWsRaw:
      # VS-2 §12.5 subscription evidence, validated acceptance path like
      # rest_resp: each record must parse against its declared schema
      # (sub: gen/action/phase/t plus exactly its combination's fields;
      # ws_raw: channel/conn/t/payload_hex) or the run is rejected at the
      # record's own seq. Beyond the schema, every record feeds the subcheck
      # guard in stream order (README §10): a ws_raw's channel label must
      # match the class its bytes re-derive to, its 0B payload must parse by
      # the single tickwire parser (any deviation REJECTs at this seq), and
      # each parsed tick is either inside the confirmed active set (fed to
      # the bars, byte-identical to the live collector's consumption) or
      # quarantined — counted with its reason, never fed anywhere. The 0s
      # payloads contribute the FID 215 observations. REG/REMOVE/LOGIN/
      # PING/unknown payloads stay preserved bytes only.
      try:
        case recs[i].kind
        of kSub:
          let sub = parseSub(recs[i].seq, recs[i].raw)
          guard.observeSub(sub)
          inc result.subCount
        of kWsRaw:
          let w = parseWsRaw(recs[i].seq, recs[i].raw)
          guard.observeWsRaw(w.conn)
          let cls = classify(w.payload)
          if channelOfClass(cls) != w.channel:
            raise newException(SubInputError,
              "recorded channel \"" & w.channel & "\" does not match the " &
              "class the payload re-derives to (\"" &
              channelOfClass(cls) & "\"); a mislabeled payload is a " &
              "record-consistency failure")
          case cls
          of wcReal0B:
            for tick in ticksOf0B(recs[i].seq, w.payload):
              let q = guard.checkTick(tick.item)
              if q.kind == qkNone:
                feedTick(b, tick.item, hmsToSec(tick.t) - result.spec.openSec,
                         tick.price, tick.cumVol, tick.flag)
              else:
                inc result.quarantined
                if result.quarantineNotes.len < 64:
                  result.quarantineNotes.add(
                    (case q.kind
                     of qkUnsubscribed: "unsubscribed"
                     of qkPostRemove: "post_remove"
                     of qkStaleConn: "stale_conn"
                     of qkNone: "none") & " seq=" & $recs[i].seq &
                    " item=" & tick.item)
          of wcReal0S:
            for st in statesOf0S(recs[i].seq, w.payload):
              if st.value215.len > 0 and st.value215 notin result.closeValues:
                result.closeValues.add(st.value215)
          else:
            discard
          inc result.wsRawCount
        else: discard
      except SubInputError as e:
        raise newException(RecordError,
          schemaRejection(kindName(recs[i].kind), recs[i].seq, e.msg))
      except TickwireError as e:
        raise newException(RecordError,
          schemaRejection(kindName(recs[i].kind), recs[i].seq, e.msg))
      except SubGuardError as e:
        raise newException(RecordError,
          schemaRejection(kindName(recs[i].kind), recs[i].seq, e.msg))
    else:
      inc result.ignoredKinds
  # The declared page chains are audited once the record set is complete: a
  # body or chain failure is a contract violation (REJECT, exit 2) and takes
  # precedence over INCOMPLETE, never a silent pass. The declared re-poll
  # cadence and page cap come from the config record (README §6.1); with no
  # declared cadence the audit stays single-round. Both declared APIs are
  # audited (ka10027 candidate chains, ka10080 backfill chains).
  # config.preopen_seed (§12.10.2/§12.10.5), when present, first audits its
  # block and derives the declared ka10081 universe; the same audit then
  # rejects any daily capture outside it. config.preopen_universe
  # (§12.10.1), when present, derives the P-run universe from the ka10099
  # chains and uses it as the same declared universe. Absent, declaredSymbols
  # stays empty and the audit is byte-identically the legacy one.
  var declaredSymbols: seq[string]
  var preopenTruncated = false
  var preopenPageCap = 0
  var preopenUni = PreopenUniverse()
  if result.config.preopenUniverse.isSome:
    preopenUni = result.config.preopenUniverse.get
    (declaredSymbols, preopenTruncated) =
      preopenUniverseOf(preopenUni, restAttempts)
    preopenPageCap = preopenUni.pageCap
  elif result.config.preopenSeed.isSome:
    declaredSymbols = seedDeclaredSymbols(result.config.preopenSeed.get,
      recs, restAttempts, result.config.pageCap,
      result.config.dailyScope == dailyScopeAccumulate)
  var verified: seq[RestRespAttempt]
  try:
    verified = verifyAttempts(restAttempts, result.config.pageCap,
                              result.config.repollSeconds, declaredSymbols,
                              preopenPageCap)
  except RestRespError as e:
    raise newException(RecordError, restRejection(e.seqNo, e.msg))
  result.restVerified = verified.len
  # The P-run seal (§12.10.1): the last record's manifest is audited
  # against the stream it closes — the declared/derived universe, the
  # verified ka10081 captures and their canonical raw-line hash, the
  # failed gaps, the counts and the recorded capture window (strictly
  # before the calendar open). A violation is REJECT; a P-run without a
  # manifest never reaches this point (the structural check above).
  if result.config.preopenUniverse.isSome:
    validatePreopenManifest(recs[^1].raw, preopenUni,
      result.config.sessionDate, result.spec.openSec, verified, recs,
      declaredSymbols, preopenTruncated, preopenFailedOf(recs))
  # The ka10080 backfill bars (§12.8/P21): derived from the VERIFIED
  # preserved rows, origin:"BACKFILL", merged with the live bars at the
  # sealed output. A derivation failure (row schema, price sanity, session
  # placement, duplicate interval) is a contract violation with the same
  # REJECT precedence as the chain audit — an unconfirmed backfill bar is
  # never silently dropped or passed.
  var backfill: seq[Bar]
  try:
    backfill = backfillBars(verified, result.spec, result.config.sessionDate)
  except BackfillError as e:
    raise newException(RecordError,
      "backfill bars are rejected: " & e.msg &
      " (ka10080 rows are consumed only as verified 3-minute BACKFILL " &
      "evidence — never fabricated into live ticks; the cntr_tm interval " &
      "boundary semantics are UNVERIFIED until the measured demo capture)")
  except VendorInputError as e:
    raise newException(RecordError, restRejection(0, e.msg))
  result.regAcks0B = guard.regAckCount0B()
  result.removeAcks0B = guard.removeAckCount0B()
  # The minimum close evidence of a sealed live stream (README §10): a
  # stream that declares an environment and carries the session_end seal
  # must re-derive, from its own preserved bytes, the documented
  # termination evidence — a FID 215 close value in {4,8} observed and a
  # confirmed (remove, ack 0) 0B teardown. A seal without that evidence is
  # a collector contract violation: REJECT, fail-closed, never approval.
  if result.config.environment.len > 0 and sawEnd:
    var closeSeen = false
    for v in result.closeValues:
      if isCloseEvidence(v): closeSeen = true
    if not closeSeen or result.removeAcks0B < 1:
      raise newException(RecordError,
        "the stream declares environment " & result.config.environment &
        " and is sealed, but the minimum close evidence was not re-detected " &
        "at replay (FID 215 in {4,8} observed: " & $closeSeen &
        "; confirmed 0B REMOVE acks: " & $result.removeAcks0B &
        ") — a sealed live session must carry its termination evidence " &
        "(tools/collector/README.md §10); rejected fail-closed")
  result.frames = b.frames
  result.conflicts = b.conflicts
  if not sawEnd:
    result.status = rsIncomplete
    return
  if not flagReliable(b):
    result.status = rsUnreliableFlag
    return
  result.status = rsOk
  # The sealed output is the LIVE/BACKFILL merge (§12.8): sorted union of
  # the tick-built bars and the ka10080-derived bars. With no overlap the
  # merge is byte-stable; an overlap is a REJECT (mergeKeys are P22
  # session-mode declarations this stream does not carry).
  try:
    result.bars = mergeBars(closedBars(b), backfill)
  except BackfillError as e:
    raise newException(RecordError, "backfill merge is rejected: " & e.msg)
  var eng = initEngine(result.config.params, result.config.sessionDate)
  for bar in result.bars:
    eng.onBar(bar)
  result.signals = sortedSignals(eng)