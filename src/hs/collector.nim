## collector: the VS-2 live collector core — the single writer and the
## single judgment authority (tools/collector/README.md, the committed
## pipe-protocol contract).
##
## Pure state machine: no wall clock (every `t` arrives inside a sidecar
## event), no filesystem, no network. The binary in tools/collector/
## owns the sidecar process, the Recorder and the exit codes; this module
## turns one sidecar line into (records, directives) — exactly what the
## contract tests drive with canned event lines.
##
## Judgment authority implemented here (all decisions, none in the
## sidecar):
##   - REG/REMOVE composition via sub_input (0s on its own REG, refresh
##     "1" only; the 0s channel is structurally excluded from every 0B
##     replacement request);
##   - candidate derivation from the preserved REST bytes via
##     vendor_input.upDownCandidates (KRX, one query per direction,
##     declared page cap; any chain failure is fail-closed);
##   - the once-per-session ka10081 daily sweep (VS-1, REPLAY_CONTRACT
##     §12.9): after the first complete, explicitly non-empty initial
##     candidate pair is derived and selected, the universe (the pair's
##     ka10027 row stk_cd union, alternating up/down rank order, deduped)
##     enters a waiting state; confirmed empty initial pairs never
##     finalize an empty universe and never start a subscription.
##     is swept one daily_req at a time; only an affirmed response becomes
##     a rest_resp record (a failed capture is the daily_capture_failed
##     gap and the symbol is skipped — fail-closed per symbol, never per
##     session), each symbol is requested at most once, and the versioned
##     universe scope (config.daily_scope) decides whether later poll
##     rounds extend the FIFO queue (accumulate-v2) or never extend it
##     (the legacy single-page-initial-pair scope);
##   - the deterministic subscription selection between derivation and
##     REG composition (sub_input.selectTopPerDirection, policy
##     selectionPolicyId): each direction's first 100 candidates in
##     vendor response order, never re-ranked — every REG path
##     (initial, market-ack restart, swap, poll restart) is composed
##     from the selected sets, and any exclusion is a recorded
##     subscription_truncated gap, never a silent drop;
##   - the generation swap REMOVE(old) -> ack -> REG(new) -> ack;
##   - the 0B/0s channel discrimination and tick parsing via tickwire
##     (single parser, shared with replay);
##   - the three consumption checks via subcheck (ticks outside the
##     confirmed active set are quarantined — counted, never used);
##   - GAP classification onto the existing record kinds;
##   - the termination protocol: close evidence 215 in {4,8} + 0B REMOVE
##     ack + drain, then the recorder's durable finish — or the honest
##     INCOMPLETE path with no seal at all.
##
## Fail-closed everywhere: an unexpected event, a malformed line, a
## vendor response that does not affirm success, an unparseable payload
## or an unpaired ack is never mapped to success. INCOMPLETE never calls
## finish().
import std/[strutils, options, algorithm, sets]
import hcj, records, calendars, engine, vendor_input, rest_resp, sub_input,
       subcheck, tickwire

type
  CollectorError* = object of CatchableError

  PreopenSeedDecl* = object
    ## The S-run's declared binding to one P-run's ka10081 seed
    ## (REPLAY_CONTRACT §12.10.2). Exactly the six recorded fields; the
    ## block itself is carried separately (preopenBlock) so the config
    ## record stays a declaration and the block records stay records.
    sourceRunId*: string
    sessionDate*: string
    seedSha256*: string
    symbolCount*: int
    failed*: seq[string]
    manifestSha256*: string

  PreopenUniverseDecl* = object
    ## The P-run's declared ka10099 universe source (REPLAY_CONTRACT
    ## §12.10.1). The producer emits exactly this shape; the `explicit`
    ## source is a Core/consumer declaration that the capture producer
    ## never writes. Absent (none) = a legacy/S-run config record.
    marketCodes*: seq[string]  ## declared market order, unique, non-empty
    pageCap*: int              ## per-market chain cap, >= 1

  CollectorConfig* = object
    sessionDate*: string
    environment*: string       ## "demo" | "real" (the only two names)
    apiId*: string             ## ka10027
    restDomain*: string        ## derived from the environment (official split)
    wsEndpoint*: string        ## environment WS base + /api/dostk/websocket
    mrktTp*, trdeQtyCnd*, stkCnd*, crdCnd*: string
    updownIncls*, pricCnd*, trdePricaCnd*, stexTp*: string
    pageCap*: int              ## approved PH-1 value 10
    repollSeconds*: int        ## approved PH-1 value 300
    drainSeconds*: int         ## approved PH-1 value 10
    ackTimeoutSeconds*: int    ## declared quiescence bound, derived from drain
    watchdog*: string          ## "15:40:00+09:00" (scanner clock, not market authority)
    profile*: string           ## kiwoomcli account alias (demo profile)
    tokenSource*: string       ## init-line token_source: "kiwoomcli" (default)
                               ## or "env" (README §5.1, the container path)
    runId*: string             ## config.run_id (the run directory's basename,
                               ## the recorder COMMITTED run_id convention).
                               ## Empty = legacy stream: no run_id key is
                               ## recorded and event ids stay legacy-shaped.
    dailyScope*: string        ## config.daily_scope (REPLAY_CONTRACT §12.9):
                               ## "" = legacy (no key recorded, byte-identical
                               ## streams), "single-page-initial-pair" = the
                               ## same legacy scope declared explicitly,
                               ## "accumulate-v2" = FIFO union across polls
    preopenSeed*: Option[PreopenSeedDecl]
                               ## config.preopen_seed (REPLAY_CONTRACT
                               ## §12.10.2): absent = the legacy stream, no
                               ## seed key and not one changed byte.
    preopenBlock*: seq[HcjValue]
                               ## The P-run ka10081 raw records, verbatim, in
                               ## P-run order: emitted as the S-run's rest_resp
                               ## records immediately after the config record
                               ## (§12.10.2). Non-empty only with preopenSeed.
    preopenUniverse*: Option[PreopenUniverseDecl]
                               ## config.preopen_universe (REPLAY_CONTRACT
                               ## §12.10.1): the P-run producer's declared
                               ## ka10099 universe source. Absent = the key is
                               ## not recorded and the config record is
                               ## byte-identical to the legacy one.
    params*: Params
    calendar*: HcjValue        ## the approved calendar snapshot (recorded as seq 1)

  DirectiveKind* = enum
    dkConnect, dkReg, dkRemove, dkRestReq, dkDailyReq, dkRefreshToken,
    dkDisarm, dkWaitDrain, dkStop

  Directive* = object
    kind*: DirectiveKind
    gen*: int                  ## reg/remove subscription generation
    data*: seq[SubRegItem]     ## reg/remove
    direction*: Direction      ## rest_req
    page*: int                 ## rest_req / daily_req
    contYn*: string            ## rest_req
    nextKey*: string           ## rest_req
    daily*: Ka10081Query       ## daily_req (the declared ka10081 scope)

  Awaiting* = enum
    awNone, awMarketReg, awCandReg, awSwapRemove, awSwapReg, awTeardownRemove

  ChainPurpose* = enum
    cpNone, cpInitial, cpPoll

  RestChain = object
    purpose: ChainPurpose
    direction: Direction
    pages: seq[RawHttpResp]    ## pages of the chain in flight
    firstPages: seq[RawHttpResp] ## the completed opposite-direction pages
    firstTruncated: bool       ## the completed up leg closed at the cap

  ColPhase* = enum
    phStart, phConnecting, phMarketReg, phInitialRest, phCandidateReg,
    phStreaming, phDraining, phDone, phIncomplete

  RecOut* = tuple[kind: Kind, raw: HcjValue]

  Collector* = object
    cfg*: CollectorConfig
    phase*: ColPhase
    awaiting*: Awaiting
    awaitingGen*: int
    subGen*: int
    connGen*: int
    chain: RestChain
    candPending*: UpDownCandidates   ## derivation awaiting its REG ack
    candidates*: UpDownCandidates    ## last CONFIRMED (acked) generation
    candidatesKnown*: bool
    registered*: bool                ## a 0B generation is currently acked
    guard*: SubGuard
    closeSeen*: bool
    removeAckDone*: bool
    closeValues*: seq[string]        ## distinct observed 215 values, in order
    quarantine*: int
    quarantineNotes*: seq[string]
    dailyUniverse*: seq[string]  ## the ka10081 sweep universe (FIFO): the
                                 ## first complete non-empty initial pair's
                                 ## ka10027 row stk_cds, up/down symbols
                                 ## interleaved by their in-chain appearance
                                 ## order, deduped; accumulate-v2 appends each
                                 ## later poll round's new symbols
    dailyReady*: bool            ## the universe was explicitly finalized once
    dailyCursor*: int            ## index of the next universe symbol to request
    dailyPending*: string        ## stk_cd of the in-flight daily request (""
                                 ## = none)
    dailySeen*: HashSet[string]  ## the one-capture ledger (REPLAY_CONTRACT
                                 ## §12.9/§12.10.4): a symbol enters the FIFO
                                 ## universe at most once, so no capture is
                                 ## ever re-issued; a pre-open seed starts it
                                 ## with captured ∪ failed before any round
    wsCount*: int
    wsSincePoll*: int
    parseFailures*: int
    unmatchedAcks*: int
    unknownPayloads*: int
    quietNoPending*: int
    skippedPolls*: int
    incomplete*: bool
    incompleteReason*: string
    done*: bool

const collectorConfigSchema* = "hong-scanner-collector-config/1"

const eventsContractMarker* = "top10-v1"
  ## The config record's events_contract marker (top-level key): names the
  ## event judgment contract the run's stream carries (the TOP10 market
  ## alert rules, event_gen.ruleTop10Transition). Recorded on every new
  ## run — never read back by the core (the judgment itself re-derives
  ## from the preserved records); the marker is the display/serve
  ## branching key, absent on legacy streams (which carry no TOP10 facts
  ## and replay byte-identically).

proc cerr(msg: string): ref CollectorError =
  newException(CollectorError, msg)

# ---------------------------------------------------------------- config

const
  demoRestDomain* = "https://mockapi.kiwoom.com"
  demoWsEndpoint* = "wss://mockapi.kiwoom.com:10000/api/dostk/websocket"
  realRestDomain* = "https://api.kiwoom.com"
  realWsEndpoint* = "wss://api.kiwoom.com:10000/api/dostk/websocket"
  approvedWatchdog* = "15:40:00+09:00"

proc restDomainFor*(environment: string): string =
  ## The REST domain derived from the selected environment — the official
  ## server-split constants (ASSUMPTIONS "Vendor facts": 운영
  ## https://api.kiwoom.com / 모의 https://mockapi.kiwoom.com). There is no
  ## caller-supplied domain and no cross-environment fallback: an unknown
  ## environment name is refused, never defaulted.
  case environment
  of "demo": demoRestDomain
  of "real": realRestDomain
  else: raise cerr("environment must be demo or real: " & environment)

proc wsEndpointFor*(environment: string): string =
  ## The WS endpoint derived from the selected environment: the official
  ## base (wss://api.kiwoom.com:10000 / wss://mockapi.kiwoom.com:10000)
  ## plus the official WS API path /api/dostk/websocket — the same
  ## composition rule for both environments.
  case environment
  of "demo": demoWsEndpoint
  of "real": realWsEndpoint
  else: raise cerr("environment must be demo or real: " & environment)

proc isSha256Hex(s: string): bool =
  s.len == 64 and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc seedBlockSymbol(raw: HcjValue; idx: int): string =
  ## The stk_cd a pre-open seed block record declares (its ka10081 query
  ## scope). The block is copied verbatim from the P-run, so only the
  ## fields the ledger needs are inspected here; Core re-validates the
  ## whole record on replay.
  if raw.kind != hkObj:
    raise cerr("preopen seed block record " & $idx & " is not an object")
  let api = raw.getOpt("api_id")
  if api.isNone or api.get.kind != hkStr or api.get.strVal != ka10081ApiId:
    raise cerr("preopen seed block record " & $idx & " is not a " &
               ka10081ApiId & " rest_resp record")
  let q = raw.getOpt("query")
  if q.isNone or q.get.kind != hkObj:
    raise cerr("preopen seed block record " & $idx &
               " has no declared query object")
  let sym = q.get.getOpt("stk_cd")
  if sym.isNone or sym.get.kind != hkStr or sym.get.strVal.len == 0:
    raise cerr("preopen seed block record " & $idx & " declares no stk_cd")
  sym.get.strVal

proc validatePreopenSeed(seed: PreopenSeedDecl; blockRaws: seq[HcjValue];
                         sessionDate: string) =
  ## The recorded shape is exactly the six §12.10.2 fields and the block
  ## must match the declared arithmetic: K = symbol_count - |failed|,
  ## duplicate-free captured symbols, captured ∩ failed empty. The hash is
  ## verified by the adapter that read the P-run (which owns the block
  ## bytes); this is the pure invariant the core can still check.
  if seed.sourceRunId.len == 0:
    raise cerr("preopen seed source_run_id must not be empty")
  if seed.sessionDate != sessionDate:
    raise cerr("preopen seed session_date " & seed.sessionDate &
               " does not equal the session date " & sessionDate)
  if not isSha256Hex(seed.seedSha256):
    raise cerr("preopen seed seed_sha256 is not a 64-digit lowercase sha256")
  if not isSha256Hex(seed.manifestSha256):
    raise cerr("preopen seed manifest_sha256 is not a 64-digit lowercase " &
               "sha256")
  if seed.symbolCount < 0:
    raise cerr("preopen seed symbol_count must be >= 0")
  var failed = initHashSet[string]()
  for sym in seed.failed:
    if sym.len == 0:
      raise cerr("preopen seed failed carries an empty symbol")
    if sym in failed:
      raise cerr("preopen seed failed repeats symbol: " & sym)
    failed.incl(sym)
  if seed.symbolCount != blockRaws.len + seed.failed.len:
    raise cerr("preopen seed symbol_count " & $seed.symbolCount &
               " does not equal K " & $blockRaws.len & " + |failed| " &
               $seed.failed.len)
  var captured = initHashSet[string]()
  for i, raw in blockRaws:
    let sym = seedBlockSymbol(raw, i)
    if sym in captured:
      raise cerr("preopen seed block repeats symbol: " & sym)
    if sym in failed:
      raise cerr("preopen seed symbol " & sym &
                 " is both a block capture and a declared failed capture")
    captured.incl(sym)

proc initCollectorConfig*(sessionDate, environment, profile: string;
                          mrktTp, trdeQtyCnd, stkCnd, crdCnd, updownIncls,
                          pricCnd, trdePricaCnd, stexTp: string;
                          params: Params; calendar: HcjValue;
                          tokenSource = "kiwoomcli";
                          runId = "";
                          dailyScope = "";
                          pageCap = defaultPageCap;
                          repollSeconds = 300;
                          preopenSeed: Option[PreopenSeedDecl] =
                            none(PreopenSeedDecl);
                          preopenBlock: seq[HcjValue] = @[];
                          preopenUniverse: Option[PreopenUniverseDecl] =
                            none(PreopenUniverseDecl)): CollectorConfig =
  ## Build and validate the collector configuration. The approved PH-1
  ## values are pinned here (README §5/§6.1): the environment-derived
  ## endpoint, page cap 10 (the declared default; a session may declare
  ## a larger cap — REPLAY_CONTRACT §12.1 "the cap is a scanner-side
  ## declaration" — and the recorded config carries it), repoll 300 s,
  ## drain 10 s, ack timeout 10 s, watchdog 15:40 KST. A different value
  ## is refused, never silently run. `repollSeconds = 0` is the P-run
  ## declaration: a pre-open universe capture is one chain per market,
  ## never a re-poll round.
  if environment != "demo" and environment != "real":
    raise cerr("environment must be demo or real: " & environment)
  if sessionDate.len != 10 or sessionDate[4] != '-' or sessionDate[7] != '-':
    raise cerr("session_date must be YYYY-MM-DD: " & sessionDate)
  for i in [0, 1, 2, 3, 5, 6, 8, 9]:
    if sessionDate[i] notin {'0' .. '9'}:
      raise cerr("session_date must be YYYY-MM-DD: " & sessionDate)
  if profile.len < 1 or profile.len > 64:
    raise cerr("profile alias must be 1..64 characters")
  for c in profile.items:
    if c in {' ', '\t', '\n', '\r'}:
      raise cerr("profile alias must not contain whitespace: " & profile)
  # The declared token path is pinned to the two approved values: anything
  # else is refused, never silently run (README §2.1/§5.1). The default
  # "kiwoomcli" changes nothing for callers that do not pass the field.
  if tokenSource != "kiwoomcli" and tokenSource != "env":
    raise cerr("token_source must be kiwoomcli or env: " & tokenSource)
  # run_id must be the run directory's basename (the recorder COMMITTED
  # convention): no path separators, no whitespace, bounded length. Empty
  # is the legacy pre-run_id stream and stays legacy.
  if runId.len > 0:
    if runId.len > 128:
      raise cerr("run_id must be at most 128 characters")
    for c in runId.items:
      if c in {'/', '\\', ' ', '\t', '\n', '\r'}:
        raise cerr("run_id must be a directory basename: " & runId)
  # config.daily_scope (REPLAY_CONTRACT §12.9): absent/"" is the legacy
  # single-page-initial-pair scope (no key recorded, streams byte-identical);
  # the explicit legacy name and the FIFO accumulate-v2 scope are the only
  # other declared values. Anything else is refused, never silently run.
  if dailyScope.len > 0 and dailyScope != dailyScopeLegacy and
     dailyScope != dailyScopeAccumulate:
    raise cerr("daily_scope must be \"\", " & dailyScopeLegacy & " or " &
               dailyScopeAccumulate & ": " & dailyScope)
  # The declared page cap (REPLAY_CONTRACT §12.1: "the cap is a
  # scanner-side declaration"). The PH-1 default 10 was measured against
  # a ranking that fits ten pages; 2026-11-20 measured a down leg still
  # cont-yn=Y at page 10, so every poll round closed as a truncated
  # subset and no poll generation was ever judged. A session may declare
  # a larger cap; an implausible one is refused, never silently run.
  if pageCap < 1 or pageCap > 200:
    raise cerr("page_cap must be 1..200: " & $pageCap)
  # The declared re-poll cadence: 300 is the approved PH-1 value and 0 is
  # the P-run declaration (single-round page chains). Negative is refused.
  if repollSeconds < 0:
    raise cerr("repoll_seconds must be >= 0: " & $repollSeconds)
  # config.preopen_seed (REPLAY_CONTRACT §12.10.2): optional, fail-closed
  # when present. Absent, the block must be empty too — a block without
  # its declaration would be records no audit can bind to a source run.
  if preopenSeed.isSome:
    validatePreopenSeed(preopenSeed.get, preopenBlock, sessionDate)
  elif preopenBlock.len > 0:
    raise cerr("preopen seed block requires config.preopen_seed")
  # config.preopen_universe (REPLAY_CONTRACT §12.10.1): the P-run
  # declaration is exclusive with config.preopen_seed, and every field is
  # validated here before any record or request exists. Absent, nothing
  # changes.
  if preopenUniverse.isSome:
    if preopenSeed.isSome:
      raise cerr("config.preopen_universe and config.preopen_seed are " &
                 "mutually exclusive: a stream is a P-run or an S-run")
    let u = preopenUniverse.get
    if u.marketCodes.len == 0:
      raise cerr("preopen_universe.market_codes must not be empty")
    var markets = initHashSet[string]()
    for m in u.marketCodes:
      if m.len == 0:
        raise cerr("preopen_universe.market_codes carries an empty market")
      if m in markets:
        raise cerr("preopen_universe.market_codes repeats market: " & m)
      markets.incl(m)
    if u.pageCap < 1 or u.pageCap > 200:
      raise cerr("preopen_universe.page_cap must be 1..200: " & $u.pageCap)
  # The declared query scope must be inside the documented enums for both
  # directions before anything is recorded or sent.
  discard initKa10027Query(dirUp, mrktTp, trdeQtyCnd, stkCnd, crdCnd,
                           updownIncls, pricCnd, trdePricaCnd, stexTp)
  discard initKa10027Query(dirDown, mrktTp, trdeQtyCnd, stkCnd, crdCnd,
                           updownIncls, pricCnd, trdePricaCnd, stexTp)
  if stexTp != krxStexTp:
    raise cerr("candidate selection is KRX-only (stex_tp " & krxStexTp & ")")
  discard sessionFor(calendar, sessionDate)  # trading-day authority: the calendar
  result = CollectorConfig(
    sessionDate: sessionDate,
    environment: environment,
    apiId: ka10027ApiId,
    restDomain: restDomainFor(environment),
    wsEndpoint: wsEndpointFor(environment),
    mrktTp: mrktTp, trdeQtyCnd: trdeQtyCnd, stkCnd: stkCnd, crdCnd: crdCnd,
    updownIncls: updownIncls, pricCnd: pricCnd,
    trdePricaCnd: trdePricaCnd, stexTp: stexTp,
    pageCap: pageCap,
    repollSeconds: repollSeconds,
    drainSeconds: 10,
    ackTimeoutSeconds: 10,
    watchdog: approvedWatchdog,
    profile: profile,
    tokenSource: tokenSource,
    runId: runId,
    dailyScope: dailyScope,
    preopenSeed: preopenSeed,
    preopenBlock: preopenBlock,
    preopenUniverse: preopenUniverse,
    params: params,
    calendar: calendar)

proc queryOf(cfg: CollectorConfig; d: Direction): Ka10027Query =
  initKa10027Query(d, cfg.mrktTp, cfg.trdeQtyCnd, cfg.stkCnd, cfg.crdCnd,
                   cfg.updownIncls, cfg.pricCnd, cfg.trdePricaCnd, cfg.stexTp)

proc preambleRecords*(cfg: CollectorConfig): seq[RecOut] =
  ## seq 1 (calendar, the approved snapshot verbatim) and seq 2 (config
  ## with every approved PH-1 value recorded — README §6.1). run_id is
  ## recorded only when set: an empty runId keeps the config record — and
  ## therefore every legacy sealed stream — byte-identical. daily_scope is
  ## recorded only when set too (the P24 optional-field pattern): an
  ## absent/empty scope changes not a single byte of the config record and
  ## keeps the legacy single-page-initial-pair sweep. The
  ## events_contract marker names the event judgment contract the run's
  ## stream carries (top10-v1); it is recorded on every new run and never
  ## read back by the judgment (which re-derives from the preserved
  ## records).
  discard sessionFor(cfg.calendar, cfg.sessionDate)
  let qp = cfg.queryOf(dirUp)
  let qd = cfg.queryOf(dirDown)
  let cfgRaw = block:
    var pairs: seq[HcjPair] = @[
      ("ack_timeout_seconds", hInt(cfg.ackTimeoutSeconds)),
      ("candidate_query", hObj(
        ("crd_cnd", hStr(qp.crdCnd)),
        ("mrkt_tp", hStr(qp.mrktTp)),
        ("pric_cnd", hStr(qp.pricCnd)),
        ("sort_tp", hStr(sortTpOf(dirUp) & "|" & sortTpOf(dirDown))),
        ("stk_cnd", hStr(qp.stkCnd)),
        ("stex_tp", hStr(qp.stexTp)),
        ("trde_prica_cnd", hStr(qp.trdePricaCnd)),
        ("trde_qty_cnd", hStr(qp.trdeQtyCnd)),
        ("updown_incls", hStr(qp.updownIncls)))),
      ("collector", hObj(
        ("api_id", hStr(cfg.apiId)),
        ("rest_domain", hStr(cfg.restDomain)),
        ("schema", hStr(collectorConfigSchema)),
        ("ws_endpoint", hStr(cfg.wsEndpoint)))),
      ("drain_seconds", hInt(cfg.drainSeconds)),
      ("environment", hStr(cfg.environment)),
      ("events_contract", hStr(eventsContractMarker)),
      ("market", hStr("KRX")),
      ("page_cap", hInt(cfg.pageCap)),
      ("params", hObj(
        ("countermove_min_bp", hInt(cfg.params.countermoveMinBp)),
        ("directional_trigger_bp", hInt(cfg.params.directionalTriggerBp)),
        ("hold_on_degraded", hBool(cfg.params.holdOnDegraded)),
        ("lookback_bars", hInt(cfg.params.lookbackBars)),
        ("trend_min_bp", hInt(cfg.params.trendMinBp)),
        ("warmup_bars", hInt(cfg.params.warmupBars)))),
      ("repoll_seconds", hInt(cfg.repollSeconds))]
    if cfg.dailyScope.len > 0:
      pairs.add(("daily_scope", hStr(cfg.dailyScope)))
    if cfg.preopenSeed.isSome:
      # Exactly the six §12.10.2 fields. An absent seed adds no key at all:
      # the legacy config record stays byte-identical.
      let s = cfg.preopenSeed.get
      var failed: seq[HcjValue]
      for sym in s.failed: failed.add(hStr(sym))
      pairs.add(("preopen_seed", hObj(
        ("failed", hArrSeq(failed)),
        ("manifest_sha256", hStr(s.manifestSha256)),
        ("seed_sha256", hStr(s.seedSha256)),
        ("session_date", hStr(s.sessionDate)),
        ("source_run_id", hStr(s.sourceRunId)),
        ("symbol_count", hInt(s.symbolCount)))))
    if cfg.preopenUniverse.isSome:
      # Exactly the §12.10.1 ka10099 shape: source, market order, cap.
      # Absent adds no key, so every legacy/S-run config record is
      # byte-identical.
      let u = cfg.preopenUniverse.get
      var markets: seq[HcjValue]
      for m in u.marketCodes: markets.add(hStr(m))
      pairs.add(("preopen_universe", hObj(
        ("market_codes", hArrSeq(markets)),
        ("page_cap", hInt(u.pageCap)),
        ("source", hStr("ka10099")))))
    if cfg.runId.len > 0:
      pairs.add(("run_id", hStr(cfg.runId)))
    pairs.add(("selection_policy", hStr(selectionPolicyId)))
    pairs.add(("session_date", hStr(cfg.sessionDate)))
    pairs.add(("subscription_caps", hObj(
      ("per_direction", hInt(maxPerDirection)),
      ("total", hInt(maxTotalSubscriptions)))))
    pairs.add(("watchdog", hStr(cfg.watchdog)))
    hObj(pairs)
  result = @[(kCalendar, cfg.calendar), (kConfig, cfgRaw)]
  # The seed block starts immediately after record 2 (§12.10.2): the P-run
  # raw values verbatim, each renumbered only by the Recorder's S-run seq.
  # Rule-3 diagnostics follow the whole block in this producer; Core defines
  # the block as the first K ka10081 records after record 2 regardless.
  for raw in cfg.preopenBlock:
    result.add((kRestResp, raw))

# ---------------------------------------------------------------- wire out

proc hArrStr(xs: seq[string]): HcjValue =
  var items: seq[HcjValue]
  for x in xs: items.add(hStr(x))
  HcjValue(kind: hkArr, items: items)

proc dataJson(data: seq[SubRegItem]): HcjValue =
  var items: seq[HcjValue]
  for it in data:
    items.add(hObj(
      ("item", hArrStr(it.codes)),
      ("type", hArrStr(@[it.typ]))))
  HcjValue(kind: hkArr, items: items)

proc initLine*(cfg: CollectorConfig): string =
  ## The `init` instruction (README §2.1), written by the binary before
  ## any event is read.
  canonical(hObj(
    ("ack_timeout_seconds", hInt(cfg.ackTimeoutSeconds)),
    ("api_id", hStr(cfg.apiId)),
    ("drain_seconds", hInt(cfg.drainSeconds)),
    ("environment", hStr(cfg.environment)),
    ("page_cap", hInt(cfg.pageCap)),
    ("profile", hStr(cfg.profile)),
    ("protocol", hInt(1)),
    ("repoll_seconds", hInt(cfg.repollSeconds)),
    ("rest_domain", hStr(cfg.restDomain)),
    ("rest_params", hObj(
      ("crd_cnd", hStr(cfg.crdCnd)),
      ("mrkt_tp", hStr(cfg.mrktTp)),
      ("pric_cnd", hStr(cfg.pricCnd)),
      ("stk_cnd", hStr(cfg.stkCnd)),
      ("stex_tp", hStr(cfg.stexTp)),
      ("trde_prica_cnd", hStr(cfg.trdePricaCnd)),
      ("trde_qty_cnd", hStr(cfg.trdeQtyCnd)),
      ("updown_incls", hStr(cfg.updownIncls)))),
    ("token_source", hStr(cfg.tokenSource)),
    ("watchdog", hStr(cfg.watchdog)),
    ("ws_endpoint", hStr(cfg.wsEndpoint))))

proc directiveLine*(d: Directive): string =
  case d.kind
  of dkConnect:
    canonical(hObj(("type", hStr("connect"))))
  of dkReg:
    canonical(hObj(("data", dataJson(d.data)), ("gen", hInt(d.gen)),
                   ("refresh", hStr("1")), ("type", hStr("reg"))))
  of dkRemove:
    canonical(hObj(("data", dataJson(d.data)), ("gen", hInt(d.gen)),
                   ("type", hStr("remove"))))
  of dkRestReq:
    canonical(hObj(("cont_yn", hStr(d.contYn)), ("direction",
      hStr(case d.direction
           of dirUp: "up"
           of dirDown: "down")),
      ("next_key", hStr(d.nextKey)), ("page", hInt(d.page)),
      ("type", hStr("rest_req"))))
  of dkDailyReq:
    canonical(hObj(("api_id", hStr(ka10081ApiId)),
      ("page", hInt(d.page)), ("params", ka10081RequestBody(d.daily)),
      ("type", hStr("daily_req"))))
  of dkRefreshToken:
    canonical(hObj(("type", hStr("refresh_token"))))
  of dkDisarm:
    canonical(hObj(("type", hStr("disarm"))))
  of dkWaitDrain:
    canonical(hObj(("type", hStr("wait_drain"))))
  of dkStop:
    canonical(hObj(("type", hStr("stop"))))

# ---------------------------------------------------------------- events in

proc strE(obj: HcjValue; key: string): string =
  let v = obj.getOpt(key)
  if v.isNone or v.get.kind != hkStr:
    raise cerr("sidecar event field " & key & " must be a string")
  v.get.strVal

proc intE(obj: HcjValue; key: string): int =
  let v = obj.getOpt(key)
  if v.isNone or v.get.kind != hkInt:
    raise cerr("sidecar event field " & key & " must be an integer")
  int(v.get.ival)

proc optIntE(obj: HcjValue; key: string): int =
  let v = obj.getOpt(key)
  if v.isNone: return -1
  if v.get.kind != hkInt:
    raise cerr("sidecar event field " & key & " must be an integer")
  int(v.get.ival)

proc connE(obj: HcjValue): int =
  let v = intE(obj, "conn")
  if v < 1:
    raise cerr("sidecar event conn must be >= 1: " & $v)
  v

proc tE(obj: HcjValue): string =
  let t = strE(obj, "t")
  if not validIso8601Offset(t):
    raise cerr("sidecar event t is not ISO 8601 with numeric offset: " & t)
  t

proc startCollector*(cfg: CollectorConfig): Collector =
  discard sessionFor(cfg.calendar, cfg.sessionDate)
  result = Collector(cfg: cfg, phase: phStart, guard: initSubGuard())
  # REPLAY_CONTRACT §12.10.4: every seeded symbol — captured and failed —
  # enters dailySeen before any candidate round, so the sweep never
  # re-requests it and a failed seed is not retried. The ledger is also
  # what filters the initial universe (below).
  if cfg.preopenSeed.isSome:
    for i, raw in cfg.preopenBlock:
      result.dailySeen.incl(seedBlockSymbol(raw, i))
    for sym in cfg.preopenSeed.get.failed:
      result.dailySeen.incl(sym)

proc gapRecord(symbol: string; what, detail, t: string): RecOut =
  ## One gap record (existing kind). symbol == "" means a connection-wide
  ## gap: the record carries symbol null (bars.nim applyGap semantics).
  var raw = hObj(("detail", hStr(detail)), ("symbol", hStr(symbol)),
                 ("t", hStr(t)), ("what", hStr(what)))
  if symbol.len == 0:
    var ps: seq[HcjPair]
    for p in raw.pairs:
      if p.k == "symbol": ps.add((p.k, hNull()))
      else: ps.add(p)
    raw = HcjValue(kind: hkObj, pairs: ps)
  (kGap, raw)

proc goIncomplete*(c: var Collector; records: var seq[RecOut]; t: string;
                   reason: string): seq[Directive] =
  ## The honest INCOMPLETE path: a final gap record names the reason, the
  ## phase closes unsealed, and the caller must NOT call finish().
  if c.incomplete:
    return @[]
  c.incomplete = true
  c.incompleteReason = reason
  c.phase = phIncomplete
  records.add(gapRecord("", "incomplete", reason, t))
  result = @[Directive(kind: dkStop)]

proc subReqRecord(c: var Collector; action: SubAction; data: seq[SubRegItem];
                  t: string): RecOut =
  ## Record a (req) sub record before the instruction is sent and feed the
  ## same record to the guard, so replay's mirror sees the same stream.
  var types: seq[string]
  var codes: seq[string]
  for it in data:
    types.add(it.typ)
    for code in it.codes: codes.add(code)
  c.subGen = c.subGen + 1
  var raw = hObj(
    ("action", hStr(case action
                    of saReg: "reg"
                    of saRemove: "remove")),
    ("codes", hArrStr(codes)),
    ("gen", hInt(c.subGen)),
    ("phase", hStr("req")),
    ("t", hStr(t)),
    ("types", hArrStr(types)))
  if action == saReg:
    raw.pairs.add(("refresh", hStr("1")))
  let rec = parseSub(0, raw)
  c.guard.observeSub(rec)
  (kSub, raw)

proc subAckRecord(c: var Collector; gen: int; action: SubAction;
                  returnCode: int; returnMsg: string; t: string): RecOut =
  ## The paired (ack) sub record; the guard sees it too (activeSets rules).
  var raw = hObj(
    ("action", hStr(case action
                    of saReg: "reg"
                    of saRemove: "remove")),
    ("gen", hInt(gen)),
    ("phase", hStr("ack")),
    ("return_code", hInt(returnCode)),
    ("t", hStr(t)))
  if returnMsg.len > 0:
    raw.pairs.add(("return_msg", hStr(returnMsg)))
  let rec = parseSub(0, raw)
  c.guard.observeSub(rec)
  (kSub, raw)

proc wsConnRecord(conn: int; state: string; code: int; reason, t: string): RecOut =
  var raw = hObj(("conn", hInt(conn)), ("state", hStr(state)),
                 ("t", hStr(t)))
  if code >= 0:
    raw.pairs.add(("code", hInt(code)))
  if reason.len > 0:
    raw.pairs.add(("reason", hStr(reason)))
  (kWsConn, raw)

proc issueReg(c: var Collector; records: var seq[RecOut];
              data: seq[SubRegItem]; t: string): Directive =
  let rec = c.subReqRecord(saReg, data, t)
  records.add(rec)
  Directive(kind: dkReg, gen: c.subGen, data: data)

proc issueRemove(c: var Collector; records: var seq[RecOut];
                 codes: seq[string]; t: string): Directive =
  let data = composeRemoveData(codes)
  let rec = c.subReqRecord(saRemove, data, t)
  records.add(rec)
  Directive(kind: dkRemove, gen: c.subGen, data: data)

proc sameCand(a, b: UpDownCandidates): bool =
  var x = a
  var y = b
  sort(x.up, cmp); sort(x.down, cmp); sort(y.up, cmp); sort(y.down, cmp)
  x.up == y.up and x.down == y.down

proc derive(c: var Collector; upPages, downPages: seq[RawHttpResp];
            upTruncated, downTruncated: bool): UpDownCandidates =
  let upChain = PageChain(query: c.cfg.queryOf(dirUp), pages: upPages)
  let downChain = PageChain(query: c.cfg.queryOf(dirDown), pages: downPages)
  upDownCandidates(upChain, downChain, c.cfg.pageCap,
                   upTruncated, downTruncated)

proc selectCandidates(records: var seq[RecOut]; cand: UpDownCandidates;
                      upTruncated, downTruncated: bool; t: string):
                     UpDownCandidates =
  ## The one selection point (sub_input.selectTopPerDirection, policy
  ## selectionPolicyId), applied to the derived candidates before
  ## anything stores or composes them: candPending and every REG —
  ## initial, market-ack restart, swap REG, poll restart — carry the
  ## selected sets, so the raw derived universe can never reach
  ## composeRegData on any path. Each direction that excluded any
  ## candidate records the exclusion here as a subscription_truncated
  ## gap (symbol null). The detail carries the direction, the CONFIRMED
  ## counts (what the recorded pages affirm — never an estimate of
  ## unfetched pages), whether unverified pages may remain on that leg,
  ## and the policy id. Distinct from rest_truncated: a leg can close
  ## at the page cap and above the selection cap at once, or only above
  ## the selection cap.
  ## scope_excluded_count in the detail is the count of rows the
  ## derivation partitioned out of the candidate universe by code shape
  ## (vendor_input.isCandidateCode) — a declared universe boundary, not a
  ## data gap; the excluded codes stay preserved in the raw response
  ## bytes and recompute identically on replay. The gap itself still
  ## fires only for the selection truncation (excludedCount > 0).
  let sel = selectTopPerDirection(cand)
  if sel.crossDuplicates.len > 0:
    records.add(gapRecord("", "cross_duplicate",
      "selection policy " & selectionPolicyId & ": up_wins_dedup count=" &
      $sel.crossDuplicates.len & " codes=" & sel.crossDuplicates.join(","),
      t))
  if sel.intraUpDuplicates.len > 0 or sel.intraDownDuplicates.len > 0:
    records.add(gapRecord("", "duplicate_code",
      "selection policy " & selectionPolicyId &
      ": intra_direction_dedup up_count=" &
      $sel.intraUpDuplicates.len & " up_codes=" &
      sel.intraUpDuplicates.join(",") & " down_count=" &
      $sel.intraDownDuplicates.len & " down_codes=" &
      sel.intraDownDuplicates.join(",") &
      " — first appearance wins, the repeats are not registered", t))
  for i in 0 ..< sel.facts.len:
    let f = sel.facts[i]
    if f.excludedCount <= 0:
      continue
    records.add(gapRecord("", "subscription_truncated",
      "selection policy " & selectionPolicyId & ": direction=" &
      f.direction & " candidate_count=" & $f.candidateCount &
      " selected_count=" & $f.selectedCount &
      " excluded_count=" & $f.excludedCount &
      " scope_excluded_count=" & $f.scopeExcludedCount &
      " remaining_unverified_pages=" &
      (if (i == 0 and upTruncated) or (i == 1 and downTruncated): "true"
       else: "false") &
      " — the excluded codes are excluded from this session's " &
      "subscription, not absent from the market", t))
  sel.selected

proc restRespRecord(c: Collector; direction: Direction; page: int;
                    resp: RawHttpResp): RecOut =
  ## One rest_resp record (rest_resp.nim schema): declared scope + page +
  ## preserved response. Written before any judgment — every response is
  ## evidence, successful or not. Record order is the time order; the schema
  ## itself carries no timestamp field.
  let q = c.cfg.queryOf(direction)
  (kRestResp, hObj(
    ("api_id", hStr(resp.apiId)),
    ("body_hex", hStr(payloadHexOfBytes(resp.body))),
    ("cont_yn", hStr(resp.contYn)),
    ("next_key", hStr(resp.nextKey)),
    ("page", hInt(page)),
    ("query", hObj(
      ("crd_cnd", hStr(q.crdCnd)),
      ("mrkt_tp", hStr(q.mrktTp)),
      ("pric_cnd", hStr(q.pricCnd)),
      ("sort_tp", hStr(sortTpOf(direction))),
      ("stk_cnd", hStr(q.stkCnd)),
      ("stex_tp", hStr(q.stexTp)),
      ("trde_prica_cnd", hStr(q.trdePricaCnd)),
      ("trde_qty_cnd", hStr(q.trdeQtyCnd)),
      ("updown_incls", hStr(q.updownIncls)))),
    ("status", hInt(resp.status))))

proc dailyQueryOf*(cfg: CollectorConfig; stkCd: string): Ka10081Query =
  ## The declared ka10081 capture scope for one symbol: base_dt is the
  ## session date in the measured YYYYMMDD form (the response's first row
  ## is that day's in-progress bar, real-time updated), upd_stkpc_tp is
  ## the pinned declared capture scope. One page only: the
  ## recent-20+-completed-trading-days need is inside one 600-row page, so
  ## no continuation is ever requested.
  initKa10081Query(stkCd, cfg.sessionDate.replace("-", ""),
                   declaredDailyUpdStkpcTp)

proc dailyUniverseOf(c: Collector; upPages, downPages: seq[RawHttpResp];
                     upTruncated, downTruncated: bool): seq[string] =
  ## A complete non-empty initial pair finalizes the ka10081 sweep universe:
  ## the union of the pair's ka10027 row stk_cds, interleaved by each leg's
  ## vendor appearance order so both directions start entering the sweep
  ## immediately (up #1, down #1, up #2, ...), deduped at first appearance.
  ## Out-of-shape codes (the rows the derivation partitioned into
  ## upExcluded/downExcluded) are included: each is a legitimate query
  ## symbol and its capture outcome is judged per symbol, fail-closed.
  ## Built for the initial pair, and only for a confirmed non-empty one; the
  ## accumulate-v2 scope reuses it per later poll round (extendDailyUniverse).
  let upChain = PageChain(query: c.cfg.queryOf(dirUp), pages: upPages)
  let downChain = PageChain(query: c.cfg.queryOf(dirDown), pages: downPages)
  let upCodes = chainSymbols(ka10027Spec, upChain, c.cfg.pageCap, upTruncated)
  let downCodes = chainSymbols(ka10027Spec, downChain, c.cfg.pageCap,
                               downTruncated)
  result = interleaveUniverse(upCodes, downCodes)

proc extendDailyUniverse(c: var Collector; upPages, downPages: seq[RawHttpResp];
                         upTruncated, downTruncated: bool) =
  ## accumulate-v2 (REPLAY_CONTRACT §12.9): append a later poll round's new
  ## symbols to the FIFO sweep universe in vendor appearance order. The
  ## legacy scope never extends — a symbol that appears only in a later
  ## poll round stays uncaptured and is never re-issued. dailySeen is the
  ## assignment ledger: an already-queued (or already-swept) symbol is
  ## never appended twice, so no capture is ever repeated. The sweep ends at
  ## teardown: after the close evidence a completing poll chain extends
  ## nothing (the daily_universe_unfinished gap is already recorded).
  if c.cfg.dailyScope != dailyScopeAccumulate: return
  if c.closeSeen: return
  for sym in dailyUniverseOf(c, upPages, downPages, upTruncated, downTruncated):
    if sym notin c.dailySeen:
      c.dailySeen.incl(sym)
      c.dailyUniverse.add(sym)

proc dailyRespRecord(c: Collector; stkCd: string; resp: RawHttpResp): RecOut =
  ## One rest_resp record of the daily sweep (rest_resp.nim ka10081 schema:
  ## declared scope + page + preserved response). Recorded only AFTER the
  ## response affirmed success (parsePageRows) — the stream's rest_resp
  ## acceptance path rejects any non-affirming attempt on replay, and the
  ## per-symbol skip policy (fail-closed, the session continues) must not
  ## turn one symbol's failed capture into a whole-stream REJECT: a failed
  ## capture is the daily_capture_failed gap record, never a rest_resp
  ## record.
  let q = c.cfg.dailyQueryOf(stkCd)
  (kRestResp, hObj(
    ("api_id", hStr(resp.apiId)),
    ("body_hex", hStr(payloadHexOfBytes(resp.body))),
    ("cont_yn", hStr(resp.contYn)),
    ("next_key", hStr(resp.nextKey)),
    ("page", hInt(1)),
    ("query", hObj(
      ("base_dt", hStr(q.baseDt)),
      ("stk_cd", hStr(q.stkCd)),
      ("upd_stkpc_tp", hStr(q.updStkpcTp)))),
    ("status", hInt(resp.status))))

proc dailyStep(c: var Collector): seq[Directive] =
  ## Issue the next daily_req of the sweep, if and only if the universe was
  ## explicitly finalized and a symbol remains: one request in flight at a
  ## time, each universe symbol at most once (accumulate-v2 appends only
  ## unseen symbols, so a later poll round can resume an exhausted queue
  ## but never re-issue a capture), and nothing new after the close
  ## evidence or outside the active phases (teardown/drain/end issue
  ## nothing).
  if not c.dailyReady: return @[]
  if c.dailyPending.len > 0: return @[]
  if c.dailyCursor >= c.dailyUniverse.len: return @[]
  if c.closeSeen: return @[]
  if c.phase != phCandidateReg and c.phase != phStreaming: return @[]
  c.dailyPending = c.dailyUniverse[c.dailyCursor]
  inc c.dailyCursor
  @[Directive(kind: dkDailyReq, page: 1,
              daily: c.cfg.dailyQueryOf(c.dailyPending))]

proc dailySkipRecord(stkCd, detail, t: string): RecOut =
  ## The honest skip: the symbol's daily capture failed (affirmation or
  ## transport) — it is excluded from this session's daily-bar evidence,
  ## never marked captured, and the session continues (fail-closed per
  ## symbol, not per session).
  gapRecord(stkCd, "daily_capture_failed",
    "ka10081 daily capture failed (stk_cd " & stkCd & "): " & detail &
    " — the symbol is skipped, excluded from this session's daily-bar " &
    "evidence, never marked captured", t)

proc dailyCompletedDays(c: Collector; rows: seq[HcjValue]): int =
  ## Distinct completed trading days in an affirmed ka10081 page: the dt
  ## values strictly before the session date (the session date's own row
  ## is the in-progress first bar, so the strict comparison excludes it).
  let sessionDigits = c.cfg.sessionDate.replace("-", "")
  var seen = initHashSet[string]()
  for row in rows:
    let dto = row.getOpt("dt")
    if dto.isNone or dto.get.kind != hkStr: continue
    let dt = dto.get.strVal
    if dt.len > 0 and dt < sessionDigits and dt notin seen:
      seen.incl(dt)
      inc result

proc dailyHistoryShortGap(c: Collector; stkCd: string; rows: seq[HcjValue];
                          t: string): Option[RecOut] =
  ## accumulate-v2 (REPLAY_CONTRACT §12.9): fewer than 20 completed trading
  ## days behind base_dt is the daily_history_short gap. The legacy scope
  ## records nothing — an empty/absent daily_scope changes no byte.
  if c.cfg.dailyScope != dailyScopeAccumulate:
    return none(RecOut)
  let completed = c.dailyCompletedDays(rows)
  if completed >= 20:
    return none(RecOut)
  some(gapRecord(stkCd, "daily_history_short",
    "ka10081 daily history has " & $completed & " completed trading days " &
    "strictly before " & c.cfg.sessionDate.replace("-", "") &
    " (need 20): the opening-MA20 warmup is short", t))

proc maybeTeardown(c: var Collector; records: var seq[RecOut];
                   t: string): seq[Directive]

proc handleAckPayload(c: var Collector; records: var seq[RecOut];
                      payload: seq[byte]; conn: int; t: string): seq[Directive] =
  ## A REG/REMOVE ack: pair it with the collector's own outstanding
  ## request, record the (ack) sub record, feed the guard, disarm, and
  ## route the state machine. An unpaired or unparseable ack stays
  ## ws_raw-only evidence (no honest gen/code to record), fail-closed.
  let trnm = try:
    ackTrnmOf(0, payload)
  except TickwireError:
    inc c.parseFailures
    return @[]
  let wantedAction: SubAction =
    case c.awaiting
    of awMarketReg, awCandReg, awSwapReg: saReg
    of awSwapRemove, awTeardownRemove: saRemove
    of awNone: return @[]            # unpaired: ws_raw evidence only
  let wanted: bool = case trnm
    of "REG": wantedAction == saReg
    else: wantedAction == saRemove
  if not wanted:
    inc c.unmatchedAcks
    return @[]
  let code = try:
    ackReturnCode(0, payload)
  except TickwireError:
    inc c.parseFailures
    return @[]                       # cannot honestly record an ack code
  var doc: HcjValue
  try:
    doc = parseDoc(bytesText(payload))
  except HcjError:
    inc c.parseFailures
    return @[]
  var returnMsg = ""
  let rm = doc.getOpt("return_msg")
  if rm.isSome and rm.get.kind == hkStr:
    returnMsg = rm.get.strVal
  let gen = c.awaitingGen
  let action = wantedAction
  records.add(c.subAckRecord(gen, action, code, returnMsg, t))
  let aw = c.awaiting
  c.awaiting = awNone
  result.add(Directive(kind: dkDisarm))
  case aw
  of awMarketReg:
    if code != 0:
      return c.goIncomplete(records, t,
        "market-state (0s) REG ack failed: return_code " & $code &
        " — the close-evidence channel is not confirmed")
    if c.candidatesKnown:
      let data = composeRegData(c.candPending.up, c.candPending.down)
      result.add(c.issueReg(records, data, t))
      c.awaiting = awCandReg
      c.awaitingGen = c.subGen
      c.phase = phCandidateReg
    else:
      c.chain = RestChain(purpose: cpInitial, direction: dirUp)
      result.add(Directive(kind: dkRestReq, direction: dirUp, page: 1,
                           contYn: "N", nextKey: ""))
      c.phase = phInitialRest
  of awCandReg:
    if code != 0:
      return c.goIncomplete(records, t,
        "candidate (0B) REG ack failed: return_code " & $code &
        " — no confirmed subscription, the session cannot stream honestly")
    c.candidates = c.candPending
    c.candidatesKnown = true
    c.registered = true
    c.phase = phStreaming
    result.add(c.maybeTeardown(records, t))
  of awSwapRemove:
    if code == 0:
      let data = composeRegData(c.candPending.up, c.candPending.down)
      result.add(c.issueReg(records, data, t))
      c.awaiting = awSwapReg
      c.awaitingGen = c.subGen
    else:
      # The old generation stays active (a failed REMOVE changes nothing —
      # activeSets rule); the swap retries on the next poll.
      c.phase = phStreaming
  of awSwapReg:
    if code == 0:
      c.candidates = c.candPending
      c.candidatesKnown = true
      c.registered = true
    else:
      # The old generation was already removed and the new REG failed:
      # no confirmed 0B subscription remains (the guard quarantines every
      # 0B tick). The next poll retries with a plain REG.
      c.candidates = UpDownCandidates()
      c.registered = false
    c.phase = phStreaming
    result.add(c.maybeTeardown(records, t))
  of awTeardownRemove:
    if code != 0:
      return c.goIncomplete(records, t,
        "teardown REMOVE ack failed: return_code " & $code &
        " — the minimum close evidence is not complete")
    c.removeAckDone = true
    result.add(Directive(kind: dkWaitDrain))
    c.phase = phDraining
  of awNone:
    discard

proc chainAdvance(c: var Collector; records: var seq[RecOut];
                  resp: RawHttpResp; t: string): seq[Directive] =
  ## Cont-scan of the page chain currently being assembled. Truncation at
  ## the declared cap is never a success (GATES: TRUNCATED≠성공): the gap
  ## record and the REST_TRUNCATED event (HIGH/INCOMPLETE) carry that.
  ## A truncated POLL chain swaps nothing (streaming continues on the
  ## old generation). A truncated INITIAL chain closes as a declared
  ## truncated subset — the fetched pages feed the derivation and the
  ## session proceeds (REPLAY_CONTRACT: those pages are "not fetched",
  ## never "no more candidates") — live 2026-11-02: the vendor returns
  ## more than the cap in both directions, so the initial observation
  ## must not die at the cap.
  let page = c.chain.pages.len
  var truncated = false
  if resp.contYn == "Y":
    if page >= c.cfg.pageCap:
      records.add(gapRecord("", "rest_truncated",
        "page cap " & $c.cfg.pageCap & " reached while cont-yn=Y (" &
        (case c.chain.purpose
         of cpInitial: "initial"
         of cpPoll: "poll"
         of cpNone: "?") & " " &
        (case c.chain.direction
         of dirUp: "up"
         of dirDown: "down") & " chain): the declared " &
        "candidate subset is truncated — never success", t))
      if c.chain.purpose != cpInitial:
        c.chain = RestChain(purpose: cpNone, direction: dirUp)
        c.phase = phStreaming
        return @[]
      truncated = true
    else:
      result.add(Directive(kind: dkRestReq, direction: c.chain.direction,
                           page: page + 1, contYn: "Y", nextKey: resp.nextKey))
      return
  # Terminal page (or a cap-closed declared truncated subset): finish this
  # chain. A terminal up chain (initial or poll) always opens the down leg
  # first — the derivation needs both.
  let finished = c.chain
  if finished.direction == dirUp:
    c.chain = RestChain(purpose: finished.purpose, direction: dirDown,
                        firstPages: finished.pages,
                        firstTruncated: truncated)
    result.add(Directive(kind: dkRestReq, direction: dirDown, page: 1,
                         contYn: "N", nextKey: ""))
    return
  # A full up+down pair: derive the candidates (fail-closed).
  var upPages: seq[RawHttpResp]
  var downPages: seq[RawHttpResp]
  if finished.direction == dirUp:
    upPages = finished.pages
  else:
    upPages = finished.firstPages
    downPages = finished.pages
  c.chain = RestChain(purpose: cpNone, direction: dirUp)
  var cand: UpDownCandidates
  try:
    cand = c.derive(upPages, downPages, finished.firstTruncated, truncated)
  except VendorInputError as e:
    records.add(gapRecord("", "rest_chain",
      (case finished.purpose
       of cpInitial: "initial"
       of cpPoll: "poll"
       of cpNone: "?") & " candidate chain rejected: " &
      e.msg, t))
    if finished.purpose == cpInitial:
      return c.goIncomplete(records, t,
        "the initial candidate chain did not affirm success: " & e.msg &
        " — the session's candidate derivation never completed")
    c.phase = phStreaming
    return
  if finished.purpose == cpInitial:
    let universe = dailyUniverseOf(c, upPages, downPages,
                                   finished.firstTruncated, truncated)
    if universe.len == 0:
      records.add(gapRecord("", "daily_universe_waiting",
        "confirmed empty initial candidate pair: no universe is finalized, " &
        "daily sweep remains unstarted", t))
      c.chain = RestChain(purpose: cpInitial, direction: dirUp)
      c.phase = phInitialRest
      result.add(Directive(kind: dkRestReq, direction: dirUp, page: 1,
                           contYn: "N", nextKey: ""))
      return
  cand = selectCandidates(records, cand, finished.firstTruncated,
                          truncated, t)
  if finished.purpose == cpInitial:
    c.candPending = cand
    c.candidatesKnown = true
    # The ka10081 daily sweep (VS-1, REPLAY_CONTRACT §12.9): the universe
    # is seeded from the first complete non-empty initial pair's row stk_cd
    # union. Under accumulate-v2 this is the FIFO seed (later poll rounds
    # append their new symbols via extendDailyUniverse); under the legacy
    # scope a symbol that appears only in a later round stays uncaptured.
    var universe = dailyUniverseOf(c, upPages, downPages,
                                   finished.firstTruncated, truncated)
    if c.cfg.preopenSeed.isSome:
      # REPLAY_CONTRACT §12.10.4: a seeded symbol (captured or failed) is
      # already one completed logical task, so it never enters this
      # session's sweep queue — one symbol, one capture (§12.9). The
      # derived universe itself is unchanged; only the queue is filtered.
      var queue: seq[string]
      for sym in universe:
        if sym notin c.dailySeen: queue.add(sym)
      universe = queue
    c.dailyUniverse = universe
    if c.cfg.dailyScope == dailyScopeAccumulate:
      # Without a seed this is the historical FIFO seed. With a seed the
      # ledger already holds captured ∪ failed and must not be reset.
      if c.cfg.preopenSeed.isNone:
        c.dailySeen = initHashSet[string]()
      for sym in c.dailyUniverse:
        c.dailySeen.incl(sym)
    c.dailyReady = true
    c.dailyCursor = 0
    c.dailyPending = ""
    let data = composeRegData(cand.up, cand.down)
    result.add(c.issueReg(records, data, t))
    c.awaiting = awCandReg
    c.awaitingGen = c.subGen
    c.phase = phCandidateReg
    for d in c.dailyStep():
      result.add(d)
    return
  # poll: swap only when the sets differ.
  if not c.candidatesKnown or not sameCand(cand, c.candidates):
    c.candPending = cand
    let active = c.guard.active0BCodes()
    if active.len > 0:
      result.add(c.issueRemove(records, active, t))
      c.awaiting = awSwapRemove
      c.awaitingGen = c.subGen
    else:
      let data = composeRegData(cand.up, cand.down)
      result.add(c.issueReg(records, data, t))
      c.awaiting = awSwapReg
      c.awaitingGen = c.subGen
  # accumulate-v2 (REPLAY_CONTRACT §12.9): a completed poll pair extends the
  # FIFO sweep universe with that round's new symbols and the sweep resumes.
  # Queue exhaustion is not completion — a later round's append resumes it.
  # The legacy scope returns immediately from extendDailyUniverse.
  c.extendDailyUniverse(upPages, downPages, finished.firstTruncated, truncated)
  for d in c.dailyStep():
    result.add(d)
  c.phase = phStreaming

proc handleWsPayload(c: var Collector; records: var seq[RecOut];
                     payload: seq[byte]; conn: int; t: string): seq[Directive] =
  ## Channel discrimination, recording, close-evidence observation and
  ## the quarantine checks — core authority (README §6/§10). Returns the
  ## directives the payload routing produced (an ack can disarm, chain a
  ## REG, or fire the teardown).
  inc c.wsCount
  inc c.wsSincePoll
  c.guard.observeWsRaw(conn)
  let cls = classify(payload)
  let channel = channelOfClass(cls)
  records.add((kWsRaw, hObj(
    ("channel", hStr(channel)),
    ("conn", hInt(conn)),
    ("payload_hex", hStr(payloadHexOfBytes(payload))),
    ("t", hStr(t)))))
  case cls
  of wcReg, wcRemove:
    result = c.handleAckPayload(records, payload, conn, t)
  of wcReal0B:
    var ticks: seq[Tick0B]
    try:
      ticks = ticksOf0B(0, payload)
    except TickwireError:
      # fail-closed: the bytes stay preserved above; the failure is
      # counted and will be re-detected (REJECT) by replay. The session
      # keeps recording — stopping the recorder would stop the evidence.
      inc c.parseFailures
      return
    for tick in ticks:
      let q = c.guard.checkTick(tick.item)
      if q.kind != qkNone:
        inc c.quarantine
        if c.quarantineNotes.len < 64:
          c.quarantineNotes.add($(case q.kind
                                  of qkUnsubscribed: "unsubscribed"
                                  of qkPostRemove: "post_remove"
                                  of qkStaleConn: "stale_conn"
                                  of qkNone: "none") & " " & q.detail)
  of wcReal0S:
    var states: seq[Tick0S]
    try:
      states = statesOf0S(0, payload)
    except TickwireError:
      inc c.parseFailures
      return
    for st in states:
      if st.value215.len > 0 and st.value215 notin c.closeValues and
         c.closeValues.len < 64:
        c.closeValues.add(st.value215)
      if isCloseEvidence(st.value215):
        c.closeSeen = true
  of wcUnknown:
    inc c.unknownPayloads
  of wcPing, wcLogin:
    discard

proc beginTeardown(c: var Collector; records: var seq[RecOut];
                   t: string): seq[Directive] =
  ## Close evidence observed: remove the full active 0B generation. With
  ## no active codes there is no honest REMOVE (composeRemoveData rejects
  ## empty) and the minimum close evidence can never complete — INCOMPLETE.
  if c.cfg.dailyScope == dailyScopeAccumulate and
     (c.dailyCursor < c.dailyUniverse.len or c.dailyPending.len > 0):
    # REPLAY_CONTRACT §12.9: queue exhaustion is not completion, but the
    # sweep does end at teardown — a still pending queue is recorded here
    # (remaining count, cursor, queue size, the symbol in flight).
    let remaining = c.dailyUniverse.len - c.dailyCursor
    records.add(gapRecord("", "daily_universe_unfinished",
      "accumulate-v2 daily sweep unfinished at teardown: remaining " &
      $remaining & ", cursor " & $c.dailyCursor & ", queue size " &
      $c.dailyUniverse.len & ", pending " &
      (if c.dailyPending.len > 0: c.dailyPending else: "none"), t))
  let active = c.guard.active0BCodes()
  if active.len == 0:
    return c.goIncomplete(records, t,
      "close evidence observed but no active 0B generation is registered: " &
      "the teardown REMOVE (and so the minimum close evidence) cannot " &
      "be issued")
  result.add(c.issueRemove(records, active, t))
  c.awaiting = awTeardownRemove
  c.awaitingGen = c.subGen
  c.phase = phStreaming   # still waiting for the ack

proc maybeTeardown(c: var Collector; records: var seq[RecOut];
                   t: string): seq[Directive] =
  ## Fire the teardown the moment close evidence is in hand and no
  ## protocol step is in flight — reached from both the ws and the ack
  ## paths, so the ordering of the two never delays the honest close.
  if c.closeSeen and not c.removeAckDone and c.registered and
     c.awaiting == awNone and c.phase == phStreaming:
    result = c.beginTeardown(records, t)

proc handleEvent*(c: var Collector; line: string;
                  records: var seq[RecOut]): seq[Directive] =
  ## The one entry point: one sidecar line in, records + directives out.
  ## Raises CollectorError on a line that violates the pipe contract
  ## (fail-closed; the binary exits 2 and preserves the file).
  if c.incomplete or c.done:
    return @[]
  var ev: HcjValue
  try:
    ev = parseLine(line)
  except HcjError as e:
    raise cerr("sidecar line is not valid HCJ JSON: " & e.msg)
  if ev.kind != hkObj:
    raise cerr("sidecar line is not a JSON object")
  let evName = strE(ev, "ev")
  let t = tE(ev)
  case evName
  of "ready":
    if c.phase != phStart:
      raise cerr("unexpected ready event in phase " & $c.phase)
    c.phase = phConnecting
    result = @[Directive(kind: dkConnect)]
  of "token":
    discard
  of "conn":
    let conn = connE(ev)
    let state = strE(ev, "state")
    let code = optIntE(ev, "code")
    let reason = if ev.has("reason"): strE(ev, "reason") else: ""
    case state
    of "open":
      if c.phase == phStart:
        raise cerr("conn open before the ready event: the sidecar " &
                   "connected without being told to")
      if conn != c.connGen + 1:
        raise cerr("conn generation is not the next one: " & $conn & " after " &
                   $c.connGen)
      c.connGen = conn
      records.add(wsConnRecord(conn, "open", -1, "", t))
      # A request in flight died with the old connection; the new one has
      # confirmed nothing (the guard quarantines until a fresh reg ack).
      c.awaiting = awNone
      let d = c.issueReg(records, composeMarketStateReg(), t)
      c.awaiting = awMarketReg
      c.awaitingGen = c.subGen
      c.phase = phMarketReg
      result = @[d]
    of "closed_ok", "closed_error":
      records.add(wsConnRecord(conn, state, code, reason, t))
      records.add(gapRecord("", "conn_closed",
        state & " code=" & $code & (if reason.len > 0: " reason=" & reason
                                    else: ""), t))
      if c.awaiting != awNone:
        c.awaiting = awNone
    else:
      raise cerr("unknown conn state: " & state)
  of "ws":
    let conn = connE(ev)
    var payload: seq[byte]
    try:
      payload = payloadFromHex(0, strE(ev, "payload_hex"))
    except SubInputError as e:
      raise cerr("ws event payload_hex rejected: " & e.msg)
    result = c.handleWsPayload(records, payload, conn, t)
    for d in c.maybeTeardown(records, t):
      result.add(d)
  of "rest":
    let dirName = strE(ev, "direction")
    if dirName != "up" and dirName != "down":
      raise cerr("rest event direction is not up|down: " & dirName)
    let direction = if dirName == "up": dirUp else: dirDown
    let page = intE(ev, "page")
    if page < 1:
      raise cerr("rest event page must be >= 1: " & $page)
    if c.chain.purpose == cpNone or c.chain.direction != direction or
       page != c.chain.pages.len + 1:
      raise cerr("unsolicited rest event (direction " & dirName & ", page " &
                 $page & "): no matching request in flight")
    let contYn = strE(ev, "cont_yn")
    if contYn != "Y" and contYn != "N" and contYn != "":
      raise cerr("rest event cont_yn is not Y|N|\"\": " & contYn)
    var resp: RawHttpResp
    try:
      resp = httpResp(c.cfg.apiId, intE(ev, "status"), contYn,
                      strE(ev, "next_key"),
                      payloadFromHex(0, strE(ev, "body_hex")))
    except SubInputError as e:
      raise cerr("rest event body_hex rejected: " & e.msg)
    except VendorInputError as e:
      raise cerr("rest event response rejected: " & e.msg)
    records.add(c.restRespRecord(direction, page, resp))
    c.chain.pages.add(resp)
    result = c.chainAdvance(records, resp, t)
  of "rest_daily":
    # One ka10081 daily response (README §3.8): the declared scope was
    # issued by this core (dkDailyReq), so the pending symbol attributes
    # the event — the request parameters are never repeated on the wire.
    let apiId = strE(ev, "api_id")
    if apiId != ka10081ApiId:
      raise cerr("rest_daily event api_id must be " & ka10081ApiId & ": " &
                 apiId)
    let page = intE(ev, "page")
    if page != 1:
      raise cerr("rest_daily event page must be 1 (the declared capture " &
                 "scope is one page): " & $page)
    if c.dailyPending.len == 0:
      raise cerr("unsolicited rest_daily event (no daily request in flight)")
    let contYn = strE(ev, "cont_yn")
    if contYn != "Y" and contYn != "N" and contYn != "":
      raise cerr("rest_daily event cont_yn is not Y|N|\"\": " & contYn)
    var resp: RawHttpResp
    try:
      resp = httpResp(ka10081ApiId, intE(ev, "status"), contYn,
                      strE(ev, "next_key"),
                      payloadFromHex(0, strE(ev, "body_hex")))
    except SubInputError as e:
      raise cerr("rest_daily event body_hex rejected: " & e.msg)
    except VendorInputError as e:
      raise cerr("rest_daily event response rejected: " & e.msg)
    let sym = c.dailyPending
    # The capture verdict precedes the record (the ka10081 divergence from
    # the ka10027 record-first rule, REPLAY_CONTRACT §12.9): only an
    # affirmed response becomes a rest_resp record — the acceptance path
    # rejects any non-affirming attempt on replay, and the approved
    # per-symbol skip policy must not reject the whole sealed stream. A
    # failed capture is the honest gap and the symbol is skipped.
    try:
      let rows = parsePageRows(ka10081Spec, resp)
      records.add(c.dailyRespRecord(sym, resp))
      # accumulate-v2 only (REPLAY_CONTRACT §12.9): an affirmed capture
      # with fewer than 20 completed days is recorded as daily_history_short
      # for that symbol. The rest_resp record itself is unchanged, and the
      # legacy scope records neither.
      let short = c.dailyHistoryShortGap(sym, rows, t)
      if short.isSome:
        records.add(short.get)
    except VendorInputError as e:
      records.add(dailySkipRecord(sym, e.msg, t))
    c.dailyPending = ""
    for d in c.dailyStep():
      result.add(d)
  of "timer":
    let kind = strE(ev, "kind")
    case kind
    of "poll":
      if c.wsSincePoll == 0:
        records.add(gapRecord("", "stale",
          "no WS application message arrived between two poll timers " &
          "(" & $c.cfg.repollSeconds & "s) — GAP_SUSPECTED", t))
      c.wsSincePoll = 0
      if c.phase == phStreaming and c.awaiting == awNone and
         not c.closeSeen and c.registered:
        c.chain = RestChain(purpose: cpPoll, direction: dirUp)
        result = @[Directive(kind: dkRestReq, direction: dirUp, page: 1,
                             contYn: "N", nextKey: "")]
      else:
        inc c.skippedPolls
    of "watchdog":
      result = c.goIncomplete(records, t,
        "watchdog " & c.cfg.watchdog & " reached without close evidence " &
        "(FID 215 in {4,8}): the session ends INCOMPLETE, never sealed")
    of "quiet":
      if c.awaiting != awNone:
        result = c.goIncomplete(records, t,
          "ack timeout: the wire was quiet for " &
          $c.cfg.ackTimeoutSeconds & "s while awaiting " &
          (case c.awaiting
           of awMarketReg: "the market-state REG ack"
           of awCandReg: "the candidate REG ack"
           of awSwapRemove: "the swap REMOVE ack"
           of awSwapReg: "the swap REG ack"
           of awTeardownRemove: "the teardown REMOVE ack"
           of awNone: "nothing"))
      else:
        inc c.quietNoPending
    else:
      raise cerr("unknown timer kind: " & kind)
  of "drain_done":
    if c.phase != phDraining or not c.removeAckDone:
      raise cerr("drain_done without a teardown in progress")
    c.phase = phDone
    c.done = true
    result = @[Directive(kind: dkStop)]
  of "error":
    let what = strE(ev, "what")
    let detail = if ev.has("detail"): strE(ev, "detail") else: ""
    case what
    of "rest":
      if ev.has("req") and strE(ev, "req") == "daily":
        # The failed transport was a daily_req (README §2.8/§3.6): the
        # symbol is skipped (fail-closed per symbol — the session
        # continues) and the sweep advances.
        if c.dailyPending.len == 0:
          raise cerr("daily REST transport failure reported with no daily " &
                     "request in flight")
        let sym = c.dailyPending
        records.add(dailySkipRecord(sym,
          "REST transport failure: " & detail, t))
        c.dailyPending = ""
        for d in c.dailyStep():
          result.add(d)
      else:
        records.add(gapRecord("", "rest_transport",
          (if c.chain.purpose == cpInitial: "initial"
           elif c.chain.purpose == cpPoll: "poll"
           else: "standalone") & " REST transport failure: " & detail, t))
        let purpose = c.chain.purpose
        c.chain = RestChain(purpose: cpNone, direction: dirUp)
        if purpose == cpInitial:
          result = c.goIncomplete(records, t,
            "the initial candidate chain failed at the transport layer: " &
            detail & " — the session's candidate derivation never completed")
    of "token":
      result = c.goIncomplete(records, t,
        "token refresh failed: " & detail &
        " — the session cannot authenticate, ending INCOMPLETE")
    of "send":
      records.add(gapRecord("", "send_failed", detail, t))
      if c.awaiting == awTeardownRemove:
        result = c.goIncomplete(records, t,
          "the teardown REMOVE could not be sent: " & detail)
      else:
        c.awaiting = awNone
    of "internal":
      result = c.goIncomplete(records, t,
        "sidecar internal failure: " & detail)
    else:
      raise cerr("unknown error kind: " & what)
  else:
    raise cerr("unknown sidecar event: " & evName)
