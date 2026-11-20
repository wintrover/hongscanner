## preopen_capture: the P-run producer (REPLAY_CONTRACT §12.10.1).
##
## Adapter boundary: one pre-open run captures the ka10099 market-list
## universe (declared markets, one cont-yn/next-key chain per market) and
## exactly one ka10081 page per derived symbol, into a run directory whose
## last record is the `daily_seed_manifest` seal. Core (`src/hs/replay.nim`)
## alone judges the stream; this module reuses Core's helpers
## (`ka10099ChainSymbols`, `universeHash`, `preopenUniverseOf`,
## `preopenFailedOf`, `validatePreopenManifest`) so producer and consumer
## cannot drift, and re-audits the whole run with them BEFORE the manifest
## is appended — a seal Core would reject is never written.
##
## Fail-closed: any chain, response, window or hash deviation abandons the
## recorder (no manifest, no session_end), preserves the records written so
## far as evidence, and exits non-zero. A `daily_capture_failed` gap with the
## symbol is the only failure representation (§12.9); a symbol is never
## marked captured without at least one valid completed daily row
## (`dt < session_date` and CLOSE > 0).
##
## The wall clock is an adapter input: the driver reads it once for the
## recorded `capture_window` and the pre-open guard, and the capture logic
## takes it as an injected function so the contract tests never depend on
## the host clock.
import std/[os, osproc, posix, strutils, times, options, sets, streams]
import hs/[hcj, digest, records, recorder, calendars, engine, collector,
          rest_resp, vendor_input, replay]

type
  PreopenUsageError* = object of CatchableError
    ## A usage/refusal error: exit 2, nothing captured.

  PreopenError* = object of CatchableError
    ## A capture that could not produce a valid seal: exit 4.

  PreopenExchange* = proc(cmd: HcjValue): HcjValue {.closure.}
    ## One P-run command -> the sidecar event that answers it. The
    ## production adapter (main below) owns the sidecar pipe; the contract
    ## tests substitute a fake sidecar without a process or a network.

  PreopenCapture* = object
    dir*: string
    manifest*: HcjValue
    universe*: seq[string]
    truncated*: bool
    captured*: int
    failed*: int
    historyShort*: int
    records*: int

const
  ## One ka10081 page is one HTTP attempt (plus the sidecar's bounded 429
  ## retry); 120 s covers a slow vendor response without letting a hung
  ## sidecar block the capture past the open. The pre-open guard still
  ## fails closed on every request boundary and on the final window.
  sidecarTimeoutMs = 120_000
  historyDays = 20
  runInputFile = "input.hcj.jsonl"

proc perr(msg: string): ref PreopenError =
  newException(PreopenError, msg)

proc pusage(msg: string): ref PreopenUsageError =
  newException(PreopenUsageError, msg)

# ---------------------------------------------------------------- clock

proc kstText*(t: times.Time): string =
  ## Exactly the §12.10.1 capture-window form, seconds resolution:
  ## YYYY-MM-DDTHH:MM:SS+09:00 (KST is a fixed +09:00 offset, no DST).
  let shifted = times.fromUnix(t.toUnix + 9'i64 * 3600'i64)
  shifted.utc.format("yyyy-MM-dd'T'HH:mm:ss") & "+09:00"

proc secOfDay(text: string): int =
  ## Seconds since midnight of a kstText value (positions 11..18).
  result = (ord(text[11]) - ord('0')) * 36000 +
           (ord(text[12]) - ord('0')) * 3600 +
           (ord(text[14]) - ord('0')) * 600 +
           (ord(text[15]) - ord('0')) * 60 +
           (ord(text[17]) - ord('0')) * 10 +
           (ord(text[18]) - ord('0'))

proc windowProblem(now: times.Time; sessionDate: string; openSec: int): string =
  ## Empty when `now` is on the session date and strictly before the open;
  ## otherwise the fail-closed reason. The comparison is between recorded
  ## values (the stamp and the calendar's open), never a second clock.
  let text = kstText(now)
  if text[0 .. 9] != sessionDate:
    return "capture time " & text & " is not on the session date " &
           sessionDate
  if secOfDay(text) >= openSec:
    return "capture time " & text & " reached the session open " &
           sessionDate & " " & $openSec & "s (the P-run must close before " &
           "the market opens)"
  ""

# ------------------------------------------------------------- run dir

proc createPreopenRunDir*(outDir: string) =
  ## Atomic creation: an existing run directory (or file/symlink) is prior
  ## evidence and is refused, never overwritten. `posix.mkdir` makes the
  ## existence check and the creation one operation.
  if outDir.len == 0:
    raise pusage("a P-run requires an output directory")
  let parent = parentDir(outDir)
  if parent.len > 0 and not dirExists(parent):
    try:
      createDir(parent)
    except OSError as e:
      raise pusage("cannot create the run directory's parent " & parent &
                   ": " & e.msg)
  if posix.mkdir(outDir.cstring, Mode(0o755)) != 0:
    if errno == EEXIST:
      raise pusage("P-run REFUSED: the run directory already exists, " &
                   "refusing to overwrite: " & outDir)
    raise pusage("cannot create the run directory " & outDir & ": " &
                 $strerror(errno))

proc runningBinarySha256*(): string =
  ## The manifest's `binary_sha256`: the bytes of the running executable.
  ## Unreadable is a capture failure, never a fabricated hash.
  let path = getAppFilename()
  try:
    result = sha256Hex(readFile(path))
  except IOError as e:
    raise perr("cannot hash the running executable " & path & ": " & e.msg)

# ------------------------------------------------------------- events

proc evOf(ev: HcjValue; key: string): HcjValue =
  if ev.kind != hkObj:
    raise perr("sidecar event is not an object")
  let v = ev.getOpt(key)
  if v.isNone:
    raise perr("sidecar event has no " & key & " field")
  v.get

proc evStr(ev: HcjValue; key: string): string =
  let v = evOf(ev, key)
  if v.kind != hkStr:
    raise perr("sidecar event." & key & " is not a string")
  v.strVal

proc evInt(ev: HcjValue; key: string): int =
  let v = evOf(ev, key)
  if v.kind != hkInt:
    raise perr("sidecar event." & key & " is not an integer")
  if v.ival < int64(low(int)) or v.ival > int64(high(int)):
    raise perr("sidecar event." & key & " is out of range")
  int(v.ival)

proc respOf(ev: HcjValue; apiId, where: string): RawHttpResp =
  ## The preserved response fields every REST event carries. The body bytes
  ## stay verbatim; the vendor schema is validated separately.
  var body: seq[byte]
  try:
    body = bytesFromHex(evStr(ev, "body_hex"))
  except RestRespError as e:
    raise perr(where & ": body_hex is rejected: " & e.msg)
  try:
    result = httpResp(apiId, evInt(ev, "status"), evStr(ev, "cont_yn"),
                      evStr(ev, "next_key"), body)
  except VendorInputError as e:
    raise perr(where & ": response is rejected: " & e.msg)

proc errorOf(ev: HcjValue): tuple[what, req, detail: string] =
  result.what = evStr(ev, "what")
  result.req = if ev.has("req"): evStr(ev, "req") else: ""
  result.detail = if ev.has("detail"): evStr(ev, "detail") else: ""

# ------------------------------------------------------------- records

proc strArr(xs: seq[string]): HcjValue =
  var items: seq[HcjValue]
  for x in xs: items.add(hStr(x))
  hArrSeq(items)

proc listRestResp(market: string; page: int; resp: RawHttpResp): HcjValue =
  ## The §12.10.1 ka10099 rest_resp shape: the preserved response plus the
  ## declared one-field query {mrkt_tp} and the caller's page index.
  hObj(("api_id", hStr(ka10099ApiId)),
       ("body_hex", hStr(hexOfBytes(resp.body))),
       ("cont_yn", hStr(resp.contYn)),
       ("next_key", hStr(resp.nextKey)),
       ("page", hInt(page)),
       ("query", hObj(("mrkt_tp", hStr(market)))),
       ("status", hInt(resp.status)))

proc dailyRestResp(q: Ka10081Query; resp: RawHttpResp): HcjValue =
  ## The §12.9 ka10081 rest_resp shape: the declared one-page scope plus
  ## the preserved response. `page` is always 1 (never paginated).
  hObj(("api_id", hStr(ka10081ApiId)),
       ("body_hex", hStr(hexOfBytes(resp.body))),
       ("cont_yn", hStr(resp.contYn)),
       ("next_key", hStr(resp.nextKey)),
       ("page", hInt(1)),
       ("query", hObj(
         ("base_dt", hStr(q.baseDt)),
         ("stk_cd", hStr(q.stkCd)),
         ("upd_stkpc_tp", hStr(q.updStkpcTp)))),
       ("status", hInt(resp.status)))

proc failureGap(symbol, detail, t: string): HcjValue =
  ## The §12.9 per-symbol failure: Core's `preopenFailedOf` derives the
  ## manifest's failed set from exactly these gaps. The symbol is never
  ## optional here — a failure must name the capture task it excluded.
  hObj(("detail", hStr(detail)), ("symbol", hStr(symbol)),
       ("t", hStr(t)), ("what", hStr("daily_capture_failed")))

proc runGap(detail, t: string; what = "preopen_capture_aborted"): HcjValue =
  ## A run-level abort (window overrun, chain failure). It is not a
  ## daily_capture_failed gap: no symbol was excluded.
  hObj(("detail", hStr(detail)), ("symbol", hNull()), ("t", hStr(t)),
       ("what", hStr(what)))

# ------------------------------------------------------ daily row validity

proc completedDays*(rows: seq[HcjValue]; sessionDigits: string): int =
  ## The §12.10.6 eligibility rule, by `dt` and never by row index:
  ## distinct YYYYMMDD values strictly before the session date whose
  ## `cur_prc` is a positive unsigned integer close. The session date's
  ## own in-progress row (and any later row) never counts. A malformed row
  ## contributes nothing — it is not a completed day.
  var seen = initHashSet[string]()
  for row in rows:
    let dto = row.getOpt("dt")
    if dto.isNone or dto.get.kind != hkStr: continue
    let dt = dto.get.strVal
    if dt.len != 8: continue
    var shaped = true
    for c in dt:
      if c notin {'0' .. '9'}: shaped = false
    if not shaped or dt >= sessionDigits: continue
    let po = row.getOpt("cur_prc")
    if po.isNone or po.get.kind != hkStr: continue
    let priceText = po.get.strVal
    if priceText.len == 0: continue
    var price = 0'i64
    var valid = true
    for c in priceText:
      if c notin {'0' .. '9'}:
        valid = false
        break
      price = price * 10 + int64(ord(c) - ord('0'))
    if not valid or price <= 0: continue
    if dt in seen: continue
    seen.incl(dt)
    inc result

# -------------------------------------------------------------- capture

proc runPreopenCapture*(cfg: CollectorConfig; outDir: string;
                        exchange: PreopenExchange;
                        clock: proc (): times.Time {.closure.};
                        log: proc (msg: string) {.closure.} = nil):
                        PreopenCapture =
  ## Capture one P-run into a fresh `outDir`. The caller owns the sidecar
  ## lifecycle; `exchange` answers one command with one event. Every
  ## failure before the manifest abandons the recorder (no seal) and
  ## raises; a successful return means the manifest is the last record.
  if cfg.preopenUniverse.isNone:
    raise pusage("a P-run requires config.preopen_universe")
  let uni = cfg.preopenUniverse.get
  createPreopenRunDir(outDir)
  let inputPath = outDir / runInputFile
  var rec: Recorder
  try:
    rec = openRecorder(inputPath)
  except RecorderError as e:
    raise pusage("cannot create the P-run input log: " & e.msg)

  var abandoned = false
  proc abandonNow() =
    if not abandoned:
      abandoned = true
      try:
        rec.abandon()
      except CatchableError:
        discard

  proc appendRec(kind: Kind; raw: HcjValue) =
    try:
      discard rec.append(kind, raw)
    except RecorderError as e:
      abandonNow()
      raise perr("the recorder failed during the P-run: " & e.msg)

  proc abortRun(detail: string; what = "preopen_capture_aborted"):
                ref PreopenError =
    ## Preserve one run-level gap as the abort evidence, then close the
    ## recorder WITHOUT a seal: no manifest is ever written for a failed
    ## capture.
    let t = kstText(clock())
    try:
      discard rec.append(kGap, runGap(detail, t, what))
    except CatchableError:
      discard
    abandonNow()
    perr(detail)

  var configRaw: HcjValue
  try:
    let pre = cfg.preambleRecords()
    for (kind, raw) in pre:
      appendRec(kind, raw)
    configRaw = pre[1].raw
  except CollectorError as e:
    abandonNow()
    raise perr("the P-run preamble is rejected: " & e.msg)
  except CoverageError as e:
    abandonNow()
    raise perr("the P-run calendar is rejected: " & e.msg)

  let openSec =
    try:
      sessionFor(cfg.calendar, cfg.sessionDate).openSec
    except CoverageError as e:
      abandonNow()
      raise perr("the P-run session is not in the calendar: " & e.msg)

  let started = clock()
  let startProblem = windowProblem(started, cfg.sessionDate, openSec)
  if startProblem.len > 0:
    raise abortRun(startProblem, "preopen_window_overrun")
  let startText = kstText(started)

  # ------------------------------------------------------ ka10099 universe
  var universe: seq[string]
  var universeSeen = initHashSet[string]()
  var truncated = false
  for market in uni.marketCodes:
    var pages: seq[RawHttpResp]
    var page = 1
    var contYn = ""
    var nextKey = ""
    var done = false
    var chainTruncated = false
    while not done:
      let problem = windowProblem(clock(), cfg.sessionDate, openSec)
      if problem.len > 0:
        raise abortRun(problem, "preopen_window_overrun")
      let cmd = hObj(("type", hStr("list_req")),
                     ("mrkt_tp", hStr(market)),
                     ("page", hInt(page)),
                     ("cont_yn", hStr(contYn)),
                     ("next_key", hStr(nextKey)))
      let ev = exchange(cmd)
      let name = evStr(ev, "ev")
      if name == "error":
        let err = errorOf(ev)
        raise abortRun("ka10099 market " & market & " page " & $page &
          " transport failure: " & err.detail)
      if name != "rest_list":
        raise abortRun("ka10099 market " & market & " page " & $page &
          " answered " & name & ", not rest_list")
      if evStr(ev, "mrkt_tp") != market:
        raise abortRun("ka10099 event names market " & evStr(ev, "mrkt_tp") &
          ", expected " & market)
      if evInt(ev, "page") != page:
        raise abortRun("ka10099 event page " & $evInt(ev, "page") &
          " does not match the request page " & $page)
      let resp = respOf(ev, ka10099ApiId,
                        "ka10099 market " & market & " page " & $page)
      appendRec(kRestResp, listRestResp(market, page, resp))
      # Affirmation and row schema are checked before the next page is
      # requested: a non-affirming page never becomes part of a chain.
      try:
        discard parsePageRows(ka10099Spec, resp)
      except VendorInputError as e:
        raise abortRun("ka10099 market " & market & " page " & $page &
          " does not affirm success: " & e.msg)
      pages.add(resp)
      if resp.contYn == "Y":
        if page >= uni.pageCap:
          done = true
          chainTruncated = true
        else:
          if resp.nextKey.len == 0:
            raise abortRun("ka10099 market " & market & " page " & $page &
              " says cont-yn=Y without next-key")
          contYn = "Y"
          nextKey = resp.nextKey
          inc page
      else:
        done = true
    var codes: seq[string]
    try:
      codes = ka10099ChainSymbols(pages, uni.pageCap, chainTruncated)
    except VendorInputError as e:
      raise abortRun("ka10099 market " & market & " chain is rejected: " &
                     e.msg)
    for code in codes:
      if code notin universeSeen:
        universeSeen.incl(code)
        universe.add(code)
    if chainTruncated:
      truncated = true
      if not log.isNil:
        log("PREOPEN_TRUNCATED market=" & market & " pages=" & $pages.len &
            " cap=" & $uni.pageCap)

  if universe.len == 0:
    raise abortRun("the declared ka10099 universe is empty: a P-run that " &
                   "captured no symbol is not a capture")

  # --------------------------------------------------------- daily capture
  var captured = 0
  var failed = 0
  var historyShort = 0
  var seedRaws: seq[HcjValue]
  let sessionDigits = cfg.sessionDate.replace("-", "")
  for symbol in universe:
    let problem = windowProblem(clock(), cfg.sessionDate, openSec)
    if problem.len > 0:
      raise abortRun(problem, "preopen_window_overrun")
    let q = cfg.dailyQueryOf(symbol)
    let cmd = hObj(("type", hStr("daily_req")),
                   ("api_id", hStr(ka10081ApiId)),
                   ("params", ka10081RequestBody(q)),
                   ("page", hInt(1)))
    let ev = exchange(cmd)
    let name = evStr(ev, "ev")
    if name == "error":
      let err = errorOf(ev)
      if err.req != "daily":
        raise abortRun("daily capture of " & symbol & " failed outside its " &
                       "request path: " & err.what & ": " & err.detail)
      appendRec(kGap, failureGap(symbol,
        "ka10081 daily capture failed (stk_cd " & symbol & "): " &
        err.detail & " — the symbol is excluded from the seed and never " &
        "marked captured", kstText(clock())))
      inc failed
      continue
    if name != "rest_daily":
      raise abortRun("daily capture of " & symbol & " answered " & name &
                     ", not rest_daily")
    if evStr(ev, "api_id") != ka10081ApiId:
      raise abortRun("daily capture of " & symbol & " answered api_id " &
                     evStr(ev, "api_id"))
    if evInt(ev, "page") != 1:
      raise abortRun("daily capture of " & symbol & " answered page " &
                     $evInt(ev, "page") & " (the declared scope is one page)")
    let resp = respOf(ev, ka10081ApiId, "daily capture of " & symbol)
    var rows: seq[HcjValue]
    try:
      rows = parsePageRows(ka10081Spec, resp)
    except VendorInputError as e:
      appendRec(kGap, failureGap(symbol,
        "ka10081 daily capture failed (stk_cd " & symbol & "): " & e.msg &
        " — the symbol is excluded from the seed and never marked captured",
        kstText(clock())))
      inc failed
      continue
    let completed = completedDays(rows, sessionDigits)
    if completed == 0:
      # Mandatory: a success-shaped page with no valid completed row is NOT
      # a capture. Marking it captured would corrupt the §12.10.6 audit.
      appendRec(kGap, failureGap(symbol,
        "ka10081 daily capture has no valid completed row strictly before " &
        cfg.sessionDate & " (stk_cd " & symbol & "): the symbol is " &
        "excluded from the seed and never marked captured",
        kstText(clock())))
      inc failed
      continue
    let raw = dailyRestResp(q, resp)
    appendRec(kRestResp, raw)
    seedRaws.add(raw)
    inc captured
    if completed < historyDays:
      inc historyShort

  # -------------------------------------------------------------- window
  let ended = clock()
  let endText = kstText(ended)
  var endProblem = windowProblem(ended, cfg.sessionDate, openSec)
  if endProblem.len == 0 and ended.toUnix < started.toUnix:
    endProblem = "the capture window ends before it starts"
  if endProblem.len > 0:
    raise abortRun(endProblem, "preopen_window_overrun")

  # ------------------------------------------------------------- manifest
  var seedText = ""
  for raw in seedRaws:
    seedText.add(canonical(raw))
    seedText.add("\n")
  let manifest = hObj(
    ("binary_sha256", hStr(runningBinarySha256())),
    ("capture_failed_count", hInt(failed)),
    ("capture_window", hObj(
      ("ended_at", hStr(endText)),
      ("started_at", hStr(startText)))),
    ("captured_count", hInt(captured)),
    ("config_sha256", hStr(sha256Hex(canonical(configRaw)))),
    ("history_short_count", hInt(historyShort)),
    ("seed_sha256", hStr(sha256Hex(seedText))),
    ("session_date", hStr(cfg.sessionDate)),
    ("source_run_id", hStr(lastPathPart(outDir))),
    ("universe", hObj(
      ("market_codes", strArr(uni.marketCodes)),
      ("source", hStr("ka10099")),
      ("symbol_count", hInt(universe.len)),
      ("truncated", hBool(truncated)),
      ("universe_sha256", hStr(universeHash(universe))))))

  # Producer self-audit: the exact Core path the S-run/verify will use.
  # A manifest Core would reject is never appended.
  var recs: seq[Record]
  try:
    recs = readRecorderFile(inputPath)
  except PartialTailError as e:
    raise abortRun("the P-run input has a torn tail: " & e.msg)
  except RecorderError as e:
    raise abortRun("the P-run input is not a valid record stream: " & e.msg)
  var attempts: seq[RestRespAttempt]
  for r in recs:
    if r.kind != kRestResp: continue
    try:
      attempts.add(parseAttempt(r.seq, r.raw))
    except RestRespError as e:
      raise abortRun("a P-run rest_resp record is rejected: " & e.msg)
  var derivedSymbols: seq[string]
  var derivedTruncated = false
  var derivedFailed: seq[string]
  let coreUni = PreopenUniverse(source: "ka10099",
                                marketCodes: uni.marketCodes,
                                pageCap: uni.pageCap)
  try:
    (derivedSymbols, derivedTruncated) = preopenUniverseOf(coreUni, attempts)
    derivedFailed = preopenFailedOf(recs)
  except RecordError as e:
    raise abortRun("the produced P-run does not pass its universe audit: " &
                   e.msg)
  if derivedSymbols != universe or derivedTruncated != truncated or
     derivedFailed.len != failed:
    raise abortRun("the produced P-run disagrees with its own derivation " &
      "(universe " & $derivedSymbols.len & "/" & $universe.len &
      ", truncated " & $derivedTruncated & "/" & $truncated &
      ", failed " & $derivedFailed.len & "/" & $failed & ")")
  try:
    validatePreopenManifest(manifest, coreUni, cfg.sessionDate, openSec,
                            attempts, recs, derivedSymbols,
                            derivedTruncated, derivedFailed)
  except RecordError as e:
    raise abortRun("the produced seal does not pass the Core audit: " & e.msg)

  appendRec(kDailySeedManifest, manifest)
  abandonNow()
  result = PreopenCapture(
    dir: outDir, manifest: manifest, universe: universe,
    truncated: truncated, captured: captured, failed: failed,
    historyShort: historyShort, records: rec.seqNo)

# ----------------------------------------------------------- sidecar pipe

type
  SidecarLink = object
    p: Process
    fd: cint
    acc: string
    eof: bool

proc pollFd(fd: cint; timeoutMs: int): bool =
  var pfd: TPollfd
  pfd.fd = fd
  pfd.events = POLLIN
  let n = posix.poll(addr pfd, 1, cint(timeoutMs))
  result = n > 0 and
    (pfd.revents and (POLLIN or POLLHUP or POLLERR)) != 0

proc nextLine(l: var SidecarLink; timeoutMs: int): string =
  let deadline = times.epochTime() + float(timeoutMs) / 1000.0
  while true:
    let nl = find(l.acc, '\n')
    if nl >= 0:
      result = l.acc[0 ..< nl]
      l.acc = l.acc[nl + 1 ..< l.acc.len]
      return
    if l.eof:
      raise perr("the sidecar pipe closed before the capture completed")
    let remaining = int((deadline - times.epochTime()) * 1000.0)
    if remaining <= 0:
      raise perr("the sidecar did not answer within " & $timeoutMs & " ms")
    if not pollFd(l.fd, min(remaining, 500)):
      continue
    var chunk: array[65536, char]
    let n = posix.read(l.fd, addr chunk[0], chunk.len)
    if n < 0:
      if errno == EINTR:
        continue
      raise perr("sidecar stdout read failed: " & $strerror(errno))
    if n == 0:
      l.eof = true
      continue
    for i in 0 ..< n:
      l.acc.add(chunk[i])

proc nextEvent(l: var SidecarLink): HcjValue =
  let line = l.nextLine(sidecarTimeoutMs)
  try:
    result = parseLine(line)
  except HcjError as e:
    raise perr("the sidecar line is not HCJ JSON: " & e.msg)
  if result.kind != hkObj:
    raise perr("the sidecar line is not a JSON object")

proc waitReady(l: var SidecarLink) =
  while true:
    let ev = l.nextEvent()
    let name = evStr(ev, "ev")
    case name
    of "token":
      discard
    of "timer":
      discard
    of "ready":
      return
    of "error":
      let err = errorOf(ev)
      raise perr("sidecar " & err.what & " error before ready: " & err.detail)
    else:
      raise perr("unexpected sidecar event before ready: " & name)

proc request(l: var SidecarLink; cmd: HcjValue): HcjValue =
  try:
    l.p.inputStream.write(canonical(cmd) & "\n")
    l.p.inputStream.flush()
  except CatchableError:
    raise perr("the sidecar stdin broke before the capture completed")
  while true:
    let ev = l.nextEvent()
    let name = evStr(ev, "ev")
    case name
    of "token":
      discard
    of "timer":
      discard
    else:
      return ev

# ------------------------------------------------------------------ main

const preopenUsage = """collector --preopen — pre-open daily seed capture (P-run)

  collector --preopen --profile <alias> --session-date YYYY-MM-DD
            --out <dir> --calendar=<path>
            [--environment=demo|real]
            [--token-source=kiwoomcli|env]
            [--preopen-markets=0,10]
            [--preopen-page-cap=10]

Captures the ka10099 market-list universe (one cont-yn/next-key chain per
declared market; market codes are a declaration, default KOSPI "0" +
KOSDAQ "10"), then exactly one ka10081 page per deduped symbol. The run
directory must not exist. The last record is the daily_seed_manifest seal;
no ws_frame and no session_end are ever written. A symbol with zero valid
completed daily rows (dt < session_date and CLOSE > 0) is a
daily_capture_failed gap, never a captured record. The capture must close
strictly before the calendar's open for the session date; an overrun
abandons the run without a manifest.

Exit codes: 0 sealed P-run, 2 usage/refusal, 3 calendar, 4 capture failed.
"""

proc pythonCmd(): string =
  let env = getEnv("HSCOLLECTOR_PYTHON")
  if env.len > 0:
    return env
  let venvPython = getAppDir() / ".venv" / "bin" / "python"
  if fileExists(venvPython):
    return venvPython
  "python3"

proc sidecarScript(): string =
  for candidate in [getAppDir() / "sidecar.py",
                    "tools" / "collector" / "sidecar.py"]:
    if fileExists(candidate):
      return candidate
  raise perr("sidecar.py not found next to the binary or in the repository")

proc argValue(args: seq[string]; name: string): string =
  for a in args:
    if a.startsWith("--" & name & "="):
      return a[("--" & name & "=").len .. ^1]
  ""

proc hasArgValue(args: seq[string]; name: string): bool =
  for a in args:
    if a.startsWith("--" & name & "="):
      return true
  false

proc defaultInt(v: string; d: int; name: string): int =
  if v.len == 0: return d
  try:
    parseInt(v)
  except ValueError:
    raise pusage("--" & name & " must be an integer")

proc parseMarkets(v: string): seq[string] =
  if v.len == 0:
    raise pusage("--preopen-markets must not be empty")
  var seen = initHashSet[string]()
  for part in v.split(','):
    if part.len == 0:
      raise pusage("--preopen-markets carries an empty market")
    for c in part:
      if c in {' ', '\t', '\n', '\r'}:
        raise pusage("--preopen-markets must not contain whitespace")
    if part in seen:
      raise pusage("--preopen-markets repeats market: " & part)
    seen.incl(part)
    result.add(part)

proc sendStop(p: Process) =
  try:
    p.inputStream.write("{\"type\":\"stop\"}\n")
    p.inputStream.flush()
  except CatchableError:
    discard

proc preopenMain*(args: seq[string]): int =
  ## The `--preopen` branch of the collector binary. Returns the process
  ## exit code; the caller never runs the session path after this.
  if args.len == 0 or "--help" in args or "--h" in args:
    stdout.write(preopenUsage)
    return 2
  let profile = argValue(args, "profile")
  let sessionDate = argValue(args, "session-date")
  let outDir = argValue(args, "out")
  let calendarPath = argValue(args, "calendar")
  let environment = if hasArgValue(args, "environment"):
                      argValue(args, "environment")
                    else:
                      "demo"
  let tokenSource = argValue(args, "token-source")
  let effectiveToken = if tokenSource.len == 0: "kiwoomcli" else: tokenSource
  if profile.len == 0 or sessionDate.len == 0 or outDir.len == 0:
    stderr.writeLine("collector: --preopen requires --profile, " &
                     "--session-date and --out")
    return 2
  if calendarPath.len == 0:
    stderr.writeLine("collector: --preopen requires --calendar (the " &
                     "approved snapshot)")
    return 2
  if environment != "demo" and environment != "real":
    stderr.writeLine("collector: --environment must be demo or real (got: " &
                     environment & ")")
    return 2
  if effectiveToken != "kiwoomcli" and effectiveToken != "env":
    stderr.writeLine("collector: --token-source must be kiwoomcli or env")
    return 2
  var markets: seq[string]
  var pageCap: int
  try:
    markets = parseMarkets(
      if hasArgValue(args, "preopen-markets"):
        argValue(args, "preopen-markets")
      else:
        "0,10")
    pageCap = defaultInt(argValue(args, "preopen-page-cap"),
                         defaultPageCap, "preopen-page-cap")
  except PreopenUsageError as e:
    stderr.writeLine("collector: " & e.msg)
    return 2
  if pageCap < 1 or pageCap > 200:
    stderr.writeLine("collector: --preopen-page-cap must be 1..200: " &
                     $pageCap)
    return 2
  if dirExists(outDir) or fileExists(outDir):
    stderr.writeLine("PRE-OPEN REFUSED: the run directory already exists, " &
                     "refusing to overwrite: " & outDir)
    return 2
  var calendar: HcjValue
  try:
    calendar = readDocFile(calendarPath)
  except HcjError as e:
    stderr.writeLine("collector: the calendar is unreadable: " & e.msg)
    return 2
  except IOError as e:
    stderr.writeLine("collector: the calendar is unreadable: " & e.msg)
    return 2
  var cfg: CollectorConfig
  try:
    cfg = initCollectorConfig(
      sessionDate, environment, profile,
      "000", "0000", "16", "0", "1", "0", "0", "1",
      Params(
        warmupBars: 0,
        lookbackBars: defaultInt(argValue(args, "lookback-bars"), 3,
                                "lookback-bars"),
        trendMinBp: defaultInt(argValue(args, "trend-min-bp"), 50,
                               "trend-min-bp"),
        countermoveMinBp: defaultInt(argValue(args, "countermove-min-bp"), 50,
                                     "countermove-min-bp"),
        directionalTriggerBp: defaultInt(
          argValue(args, "directional-trigger-bp"), 30,
          "directional-trigger-bp"),
        holdOnDegraded: defaultInt(argValue(args, "hold-on-degraded"), 1,
                                   "hold-on-degraded") != 0),
      calendar,
      tokenSource = effectiveToken,
      runId = lastPathPart(outDir),
      pageCap = defaultInt(argValue(args, "page-cap"), defaultPageCap,
                           "page-cap"),
      repollSeconds = 0,
      preopenUniverse = some(PreopenUniverseDecl(
        marketCodes: markets, pageCap: pageCap)))
  except CollectorError as e:
    stderr.writeLine("collector: PRE-OPEN CONFIG: " & e.msg)
    return 2
  except CoverageError as e:
    stderr.writeLine("collector: PRE-OPEN CALENDAR: " & e.msg)
    return 3
  except PreopenUsageError as e:
    stderr.writeLine("collector: " & e.msg)
    return 2

  var script: string
  try:
    script = sidecarScript()
  except PreopenError as e:
    stderr.writeLine("collector: " & e.msg)
    return 2
  var p: Process
  try:
    p = startProcess(pythonCmd(), args = @[script], options = {poUsePath})
  except OSError as e:
    # No pipe, no capture: fail closed with no run directory (the recorder
    # was not opened yet — createPreopenRunDir runs inside the capture).
    stderr.writeLine("collector: PRE-OPEN INCOMPLETE: cannot start the " &
                     "sidecar: " & e.msg)
    return 4
  defer:
    try:
      p.close()
    except CatchableError:
      discard
  var link = SidecarLink(p: p, fd: p.outputHandle())
  proc exchange(cmd: HcjValue): HcjValue {.closure.} =
    link.request(cmd)
  try:
    try:
      p.inputStream.write(cfg.initLine() & "\n")
      p.inputStream.flush()
    except CatchableError:
      raise perr("the sidecar stdin broke at init")
    link.waitReady()
    let res = runPreopenCapture(cfg, outDir, exchange,
                                proc (): times.Time = times.getTime())
    sendStop(p)
    try:
      p.inputStream.close()
    except CatchableError:
      discard
    let code = p.waitForExit()
    if code != 0:
      stderr.writeLine("collector: PRE-OPEN INCOMPLETE: the sidecar exited " &
                       $code & " after stop (the P-run seal is preserved)")
      return 4
    echo "PREOPEN DONE records=", res.records, " universe=",
         res.universe.len, " captured=", res.captured, " failed=",
         res.failed, " history_short=", res.historyShort
    0
  except PreopenUsageError as e:
    sendStop(p)
    try:
      p.inputStream.close()
    except CatchableError:
      discard
    try:
      discard p.waitForExit()
    except CatchableError:
      discard
    stderr.writeLine(e.msg)
    2
  except PreopenError as e:
    sendStop(p)
    try:
      p.inputStream.close()
    except CatchableError:
      discard
    try:
      discard p.waitForExit()
    except CatchableError:
      discard
    stderr.writeLine("PRE-OPEN INCOMPLETE: " & e.msg)
    4