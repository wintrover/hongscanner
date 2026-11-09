## collector-core contract tests: one sidecar line in, records + directives
## out (tools/collector/README.md §2/§3/§8, src/hs/collector.nim). All
## inputs are canned synthetic event lines — no network, no wall clock, no
## credentials. The stream-level end-to-end lives in
## test_collector_stream_contract.nim.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_collector_contract.nim
import std/[strutils]
import hs/[hcj, records, calendars, engine, sub_input, vendor_input,
           rest_resp, tickwire, subcheck, collector]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc coreErr(name: string; needle: string; body: proc ()) =
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

proc newCfg(tokenSource: string): CollectorConfig =
  ## The same approved config with an explicit init-line token_source
  ## (README §2.1/§5.1): "kiwoomcli" (the default) or "env".
  initCollectorConfig(
    "2026-10-29", "demo", "demo-profile",
    "000", "0000", "0", "0", "1", "0", "0", "1",
    Params(warmupBars: 0, lookbackBars: 3, trendMinBp: 50,
           countermoveMinBp: 50, directionalTriggerBp: 30,
           holdOnDegraded: true),
    calRaw(), tokenSource)

proc newEnvCfg(environment: string): CollectorConfig =
  ## The same approved config with the environment as the only variable:
  ## every endpoint must be derived from that one selection.
  initCollectorConfig(
    "2026-10-29", environment, "demo-profile",
    "000", "0000", "0", "0", "1", "0", "0", "1",
    Params(warmupBars: 0, lookbackBars: 3, trendMinBp: 50,
           countermoveMinBp: 50, directionalTriggerBp: 30,
           holdOnDegraded: true),
    calRaw())

proc evLine(ps: seq[HcjPair]): string =
  canonical(hObj(ps))

proc ev(name, t: string; rest: varargs[HcjPair]): string =
  var all: seq[HcjPair] = @[("ev", hStr(name)), ("t", hStr(t))]
  for p in rest: all.add(p)
  evLine(all)

proc hexOf(s: string): string =
  const digits = "0123456789abcdef"
  for c in s:
    result.add(digits[int(ord(c)) shr 4])
    result.add(digits[int(ord(c)) and 0x0f])

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
  ## A success ka10027 page body: return_code 0 + the documented list key +
  ## positional rows in the documented field order (12 fields).
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

proc dataOf(items: seq[SubRegItem]): seq[string] =
  ## The directive's data list as "type:codes" rows for assertions.
  for it in items:
    result.add(it.typ & ":" & it.codes.join(","))

# ------------------------------------------------------------ config/bounds

block config:
  check("initLine carries the approved values",
        "\"ack_timeout_seconds\":10" in newCollector().cfg.initLine() and
        "\"repoll_seconds\":300" in newCollector().cfg.initLine() and
        "\"page_cap\":10" in newCollector().cfg.initLine() and
        "\"watchdog\":\"15:40:00+09:00\"" in
        newCollector().cfg.initLine() and
        "\"profile\":\"demo-profile\"" in newCollector().cfg.initLine())
  check("initLine names the kiwoomcli token source by default (an " &
        "undecorated init line never switches the credential path)",
        "\"token_source\":\"kiwoomcli\"" in newCollector().cfg.initLine())
  check("the env token source reaches the init line verbatim (README §5.1)",
        "\"token_source\":\"env\"" in newCfg("env").initLine() and
        "kiwoomcli" notin newCfg("env").initLine())
  coreErr("a non-approved token source is refused",
          "token_source must be kiwoomcli or env",
          proc () =
            discard newCfg("bogus"))
  let pre = newCollector().cfg.preambleRecords()
  check("preamble is calendar then config",
        pre.len == 2 and pre[0].kind == kCalendar and
        pre[1].kind == kConfig)
  check("the config record declares the environment and the cadence",
        "\"environment\":\"demo\"" in canonical(pre[1].raw) and
        "\"repoll_seconds\":300" in canonical(pre[1].raw) and
        "\"page_cap\":10" in canonical(pre[1].raw))
  proc cfgWithRunId(runId: string): CollectorConfig =
    initCollectorConfig(
      "2026-10-29", "demo", "demo-profile",
      "000", "0000", "0", "0", "1", "0", "0", "1",
      Params(warmupBars: 0, lookbackBars: 3, trendMinBp: 50,
             countermoveMinBp: 50, directionalTriggerBp: 30,
             holdOnDegraded: true),
      calRaw(), "kiwoomcli", runId)
  let runPre = cfgWithRunId("fidelity-2026-10-29-a").preambleRecords()
  check("a run_id reaches the config record verbatim",
        "\"run_id\":\"fidelity-2026-10-29-a\"" in canonical(runPre[1].raw))
  check("an absent run_id keeps the config record run_id-free (legacy " &
        "streams record byte-identical configs)",
        "run_id" notin canonical(pre[1].raw) and
        (block:
           var stripped: seq[HcjPair] = @[]
           for p in runPre[1].raw.pairs:
             if p.k != "run_id": stripped.add(p)
           canonical(hObj(stripped)) == canonical(pre[1].raw)))
  coreErr("a run_id with a path separator is refused (basename rule)",
          "run_id must be a directory basename", proc () =
    discard cfgWithRunId("runs/foo"))
  coreErr("a run_id with whitespace is refused (basename rule)",
          "run_id must be a directory basename", proc () =
    discard cfgWithRunId("run id"))
  coreErr("a non-approved environment is refused (staging)",
          "environment must be demo or real", proc () =
    discard initCollectorConfig(
      "2026-10-29", "staging", "p", "000", "0000", "0", "0", "1", "0",
      "0", "1", Params(), calRaw()))
  coreErr("the retired prod name is refused (never aliased to real)",
          "environment must be demo or real", proc () =
    discard initCollectorConfig(
      "2026-10-29", "prod", "p", "000", "0000", "0", "0", "1", "0",
      "0", "1", Params(), calRaw()))
  coreErr("an empty environment is refused (no default fallback)",
          "environment must be demo or real", proc () =
    discard initCollectorConfig(
      "2026-10-29", "", "p", "000", "0000", "0", "0", "1", "0",
      "0", "1", Params(), calRaw()))
  coreErr("restDomainFor refuses an unknown environment",
          "environment must be demo or real", proc () =
    discard restDomainFor("prod"))
  coreErr("wsEndpointFor refuses an unknown environment",
          "environment must be demo or real", proc () =
    discard wsEndpointFor("prod"))
  let demo = newEnvCfg("demo")
  let real = newEnvCfg("real")
  check("demo derives the official mock domains",
        demo.restDomain == "https://mockapi.kiwoom.com" and
        demo.wsEndpoint == "wss://mockapi.kiwoom.com:10000/api/dostk/websocket")
  check("real derives the official operational domains (no mixing)",
        real.restDomain == "https://api.kiwoom.com" and
        real.wsEndpoint == "wss://api.kiwoom.com:10000/api/dostk/websocket")
  check("real carries the environment through the init line verbatim",
        "\"environment\":\"real\"" in real.initLine() and
        "\"rest_domain\":\"https://api.kiwoom.com\"" in real.initLine() and
        "\"ws_endpoint\":\"wss://api.kiwoom.com:10000/api/dostk/websocket\"" in
        real.initLine() and
        "mockapi" notin real.initLine())
  check("demo still carries the demo domains through the init line",
        "\"environment\":\"demo\"" in demo.initLine() and
        "\"rest_domain\":\"https://mockapi.kiwoom.com\"" in demo.initLine() and
        "\"://api.kiwoom.com" notin demo.initLine())
  let preReal = real.preambleRecords()
  check("the real config record records the real environment and domains",
        "\"environment\":\"real\"" in canonical(preReal[1].raw) and
        "\"rest_domain\":\"https://api.kiwoom.com\"" in
          canonical(preReal[1].raw) and
        "mockapi" notin canonical(preReal[1].raw))
  let cReal = startCollector(real)
  check("a real session runs the same state machine (demo and real " &
        "differ only in the derived endpoints)",
        cReal.phase == phStart and cReal.cfg.environment == "real")
  try:
    discard initCollectorConfig(
      "2026-10-31", "demo", "p", "000", "0000", "0", "0", "1", "0",
      "0", "1", Params(), calRaw())
    check("a session outside the calendar is refused", false)
  except CoverageError as e:
    check("a session outside the calendar is refused (the calendar is " &
          "the trading-day authority)",
          "CALENDAR_COVERAGE_UNKNOWN" in e.msg or "not a trading day" in e.msg)
  except CatchableError:
    check("a session outside the calendar is refused", false)
  coreErr("a non-KRX scope is refused", "KRX-only", proc () =
    discard initCollectorConfig(
      "2026-10-29", "demo", "p", "000", "0000", "0", "0", "1", "0", "0",
      "2", Params(), calRaw()))
  coreErr("a whitespace profile is refused", "whitespace", proc () =
    discard initCollectorConfig(
      "2026-10-29", "demo", "a b", "000", "0000", "0", "0", "1", "0", "0",
      "1", Params(), calRaw()))

# ------------------------------------------------------- the normal session

block normalSession:
  var c = newCollector()
  var recs: seq[RecOut]
  var dirs: seq[Directive]

  (recs, dirs) = c.step(ev("ready", ts))
  check("ready -> connect", dirs.dirKinds() == @["connect"])
  check("ready records nothing", recs.len == 0)

  coreErr("conn open before ready is a protocol violation",
          "before the ready event", proc () =
            var bad = newCollector()
            var r: seq[RecOut]
            discard bad.handleEvent(ev("conn", ts, ("conn", hInt(1)),
              ("state", hStr("open"))), r))

  (recs, dirs) = c.step(ev("conn", ts, ("conn", hInt(1)),
                           ("state", hStr("open"))))
  check("conn open records the ws_conn and the 0s REG req",
        recs.kinds() == @["ws_conn", "sub"])
  check("the 0s REG goes out with refresh=1",
        dirs.dirKinds() == @["reg"] and dirs[0].gen == 1)
  check("the REG data is the market-state channel only",
        dirs[0].data.dataOf() == @["0s:"])

  (recs, dirs) = c.step(evWs(1, ackPayload()))
  check("the 0s REG ack records ws_raw then the paired sub ack",
        recs.kinds() == @["ws_raw", "sub"])
  check("the ack disarms and starts the initial up chain",
        dirs.dirKinds() == @["disarm", "rest_req"] and
        dirs[1].direction == dirUp and dirs[1].page == 1 and
        dirs[1].contYn == "N")

  (recs, dirs) = c.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  check("the terminal up page records rest_resp and opens the down chain",
        recs.kinds() == @["rest_resp"] and
        dirs.dirKinds() == @["rest_req"] and
        dirs[0].direction == dirDown and dirs[0].page == 1)

  (recs, dirs) = c.step(evRest("down", 1, 200, "N", "",
                               restBody(@["000660"])))
  check("the down chain completes the derivation and REGs the 0B set",
        recs.kinds() == @["rest_resp", "sub"] and
        dirs.dirKinds() == @["reg"] and dirs[0].gen == 2)
  check("the 0s channel is structurally excluded from the 0B REG",
        dirs[0].data.dataOf() == @["0B:005930,000660"])

  (recs, dirs) = c.step(evWs(1, ackPayload()))
  check("the candidate REG ack confirms the subscription",
        recs.kinds() == @["ws_raw", "sub"] and
        dirs.dirKinds() == @["disarm"] and c.registered and
        c.phase == phStreaming)

  (recs, dirs) = c.step(evWs(1, tick0B()))
  check("an active 0B tick is recorded and consumed (no quarantine)",
        recs.kinds() == @["ws_raw"] and dirs.len == 0 and
        c.quarantine == 0)

  (recs, dirs) = c.step(evWs(1, tick0B(item = "999999")))
  check("a foreign-symbol tick is quarantined, never consumed",
        recs.kinds() == @["ws_raw"] and c.quarantine == 1 and
        c.quarantineNotes[0].startsWith("unsubscribed"))

  (recs, dirs) = c.step(evWs(1, state0S(value215 = "4")))
  check("close evidence (215=4) fires the teardown REMOVE immediately",
        recs.kinds() == @["ws_raw", "sub"] and
        dirs.dirKinds() == @["remove"] and dirs[0].gen == 3 and
        c.closeSeen)

  (recs, dirs) = c.step(evWs(1, ackPayload(trnm = "REMOVE", code = 0)))
  check("the teardown REMOVE ack ends the protocol with wait_drain",
        recs.kinds() == @["ws_raw", "sub"] and
        dirs.dirKinds() == @["disarm", "wait_drain"] and
        c.removeAckDone and c.phase == phDraining)

  (recs, dirs) = c.step(ev("drain_done", ts))
  check("drain_done finishes the session with stop",
        dirs.dirKinds() == @["stop"] and c.done and c.phase == phDone)
  var recs2: seq[RecOut]
  check("handleEvent after done is a no-op",
        c.handleEvent(evWs(1, tick0B()), recs2).len == 0 and
        recs2.len == 0)

# -------------------------------------------------------- close evidence 8

block closeEvidence8:
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  discard c.step(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  discard c.step(evWs(1, ackPayload()))
  var step = c.step(evWs(1, state0S(value215 = "8")))
  check("215=8 is close evidence too", step[1].dirKinds() == @["remove"])

# -------------------------------------------------------- re-poll and swap

block pollSwap:
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  discard c.step(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  discard c.step(evWs(1, ackPayload()))

  var recs: seq[RecOut]
  var dirs = c.step(ev("timer", ts, ("kind", hStr("poll"))))[1]
  check("the poll timer opens a poll chain with no stale-ws gap",
        dirs.dirKinds() == @["rest_req"] and dirs[0].direction == dirUp)

  discard c.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  dirs = c.step(evRest("down", 1, 200, "N", "",
                       restBody(@["000660", "003540"])))[1]
  # The candidate set changed: REMOVE(old) -> ack -> REG(new) -> ack.
  check("a changed candidate set starts the swap with REMOVE(old)",
        dirs.dirKinds() == @["remove"] and dirs[0].gen == 3)

  var recsSwap: seq[RecOut]
  (recsSwap, dirs) = c.step(evWs(1, ackPayload(trnm = "REMOVE", code = 0)))
  check("the swap REMOVE ack is recorded and REGs the new generation",
        dirs.dirKinds() == @["disarm", "reg"] and dirs[1].gen == 4)

  (recsSwap, dirs) = c.step(evWs(1, ackPayload()))
  check("the swap REG ack completes the swap",
        dirs.dirKinds() == @["disarm"] and c.registered)

  # Poll with an unchanged set: no swap.
  discard c.step(ev("timer", ts, ("kind", hStr("poll"))))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  dirs = c.step(evRest("down", 1, 200, "N", "",
                       restBody(@["000660", "003540"])))[1]
  check("an unchanged candidate set swaps nothing", dirs.len == 0)

# --------------------------------------------------------- stale/quiet/etc

block timers:
  var c = newCollector()
  var recs: seq[RecOut]
  var dirs: seq[Directive]
  (recs, dirs) = c.step(ev("timer", ts, ("kind", hStr("poll"))))
  check("a poll with no ws traffic since the last one is a stale gap",
        "stale" in recs[0].raw.get("what").strVal)

  coreErr("an unknown timer kind is a protocol violation", "unknown timer",
          proc () =
            var bad = newCollector()
            var r: seq[RecOut]
            discard bad.handleEvent(ev("timer", ts, ("kind", hStr("zzz"))),
                                    r))

  var c2 = newCollector()
  discard c2.step(ev("ready", ts))
  discard c2.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  # quiet while awaiting the 0s REG ack: the ack timeout is INCOMPLETE.
  (recs, dirs) = c2.step(ev("timer", ts, ("kind", hStr("quiet"))))
  check("an ack timeout while awaiting is INCOMPLETE with stop",
        c2.incomplete and dirs.dirKinds() == @["stop"] and
        "ack timeout" in c2.incompleteReason)

  var c3 = newCollector()
  discard c3.step(ev("ready", ts))
  discard c3.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c3.step(evWs(1, ackPayload()))
  discard c3.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  discard c3.step(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  discard c3.step(evWs(1, ackPayload()))
  var recs3: seq[RecOut]
  var dirs3 = c3.step(ev("timer", ts, ("kind", hStr("quiet"))))[1]
  check("a quiet timer with nothing pending is counted, never fatal",
        dirs3.len == 0 and not c3.incomplete and c3.quietNoPending == 1)

  var c4 = newCollector()
  discard c4.step(ev("ready", ts))
  discard c4.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  var dirs4 = c4.step(ev("timer", ts, ("kind", hStr("watchdog"))))[1]
  check("the watchdog without close evidence is INCOMPLETE",
        c4.incomplete and dirs4.dirKinds() == @["stop"] and
        "watchdog" in c4.incompleteReason)

# -------------------------------------------------------------- re-connect

block reconnect:
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  discard c.step(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  discard c.step(evWs(1, ackPayload()))

  var recs: seq[RecOut]
  var dirs: seq[Directive]
  (recs, dirs) = c.step(ev("conn", ts, ("conn", hInt(1)),
                           ("code", hInt(1006)), ("reason", hStr("dropped")),
                           ("state", hStr("closed_error"))))
  check("a closed connection is a ws_conn record plus a null-symbol gap",
        recs.kinds() == @["ws_conn", "gap"] and
        recs[1].raw.get("symbol").isNull)

  (recs, dirs) = c.step(ev("conn", ts, ("conn", hInt(2)),
                           ("state", hStr("open"))))
  check("the new generation re-registers the market state first",
        dirs.dirKinds() == @["reg"] and dirs[0].gen == 3)

  # The fresh connection confirmed nothing until the REGs are acked again:
  # the market ack re-REGisters the KNOWN candidate set directly (no REST
  # re-derivation is needed — the confirmed set is the collector's state).
  (recs, dirs) = c.step(evWs(2, ackPayload()))
  check("the known candidate set is re-REGistered on the new connection",
        dirs.dirKinds() == @["disarm", "reg"] and dirs[1].gen == 4)
  discard c.step(evWs(2, ackPayload()))
  discard c.step(evWs(2, tick0B()))
  check("the re-acked set consumes ticks again on generation 2",
        c.quarantine == 0)

  coreErr("a skipped connection generation is a protocol violation",
          "not the next one", proc () =
            var bad = newCollector()
            var r: seq[RecOut]
            discard bad.handleEvent(ev("ready", ts), r)
            discard bad.handleEvent(ev("conn", ts, ("conn", hInt(1)),
              ("state", hStr("open"))), r)
            discard bad.handleEvent(ev("conn", ts, ("conn", hInt(3)),
              ("state", hStr("open"))), r))

# ------------------------------------------------------- error classification

block errors:
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  var recs: seq[RecOut]
  var dirs: seq[Directive]
  (recs, dirs) = c.step(ev("error", ts, ("detail", hStr("timeout")),
                           ("what", hStr("rest"))))
  check("an initial-chain REST transport failure is INCOMPLETE",
        c.incomplete)
  check("the initial-chain transport failure stops the session",
        dirs.dirKinds() == @["stop"])
  check("the transport failure is recorded as a gap (transport + the " &
        "incomplete gap)",
        recs.kinds() == @["gap", "gap"])

  var c2 = newCollector()
  discard c2.step(ev("ready", ts))
  var step2 = c2.step(ev("error", ts, ("detail", hStr("rc=1")),
                         ("what", hStr("token"))))
  check("a token failure is INCOMPLETE", c2.incomplete and
        step2[1].dirKinds() == @["stop"])

  var c3 = newCollector()
  discard c3.step(ev("ready", ts))
  discard c3.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c3.step(evWs(1, ackPayload()))
  discard c3.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  discard c3.step(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  discard c3.step(evWs(1, ackPayload()))
  discard c3.step(evWs(1, state0S(value215 = "4")))
  var step3 = c3.step(ev("error", ts, ("detail", hStr("broken pipe")),
                         ("what", hStr("send"))))
  check("a teardown send failure is INCOMPLETE (the close evidence " &
        "cannot complete)",
        c3.incomplete and step3[1].dirKinds() == @["stop"])

  var c4 = newCollector()
  discard c4.step(ev("ready", ts))
  var step4 = c4.step(ev("error", ts, ("detail", hStr("x")),
                         ("what", hStr("internal"))))
  check("a sidecar internal fault is INCOMPLETE", c4.incomplete and
        step4[1].dirKinds() == @["stop"])

  var c5 = newCollector()
  discard c5.step(ev("ready", ts))
  discard c5.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c5.step(evWs(1, ackPayload()))
  discard c5.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  discard c5.step(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  discard c5.step(evWs(1, ackPayload()))
  var recs5: seq[RecOut]
  var dirs5: seq[Directive]
  (recs5, dirs5) = c5.step(ev("error", ts, ("detail", hStr("timeout")),
                              ("what", hStr("rest"))))
  check("a poll-chain REST failure stays streaming (retried next poll)",
        not c5.incomplete and dirs5.len == 0 and
        recs5.kinds() == @["gap"])

# ------------------------------------------------- protocol violations

block violations:
  coreErr("an unknown sidecar event is a violation", "unknown sidecar event",
          proc () =
            var c = newCollector()
            var r: seq[RecOut]
            discard c.handleEvent(ev("zzz", ts), r))
  coreErr("a malformed line is a violation", "not valid HCJ JSON",
          proc () =
            var c = newCollector()
            var r: seq[RecOut]
            discard c.handleEvent("{nope", r))
  coreErr("a non-object line is a violation", "not a JSON object",
          proc () =
            var c = newCollector()
            var r: seq[RecOut]
            discard c.handleEvent("[1]", r))
  coreErr("a missing t is a violation", "must be a string",
          proc () =
            var c = newCollector()
            var r: seq[RecOut]
            discard c.handleEvent(canonical(hObj(("ev", hStr("ready")))), r))
  coreErr("a non-ISO t is a violation", "is not ISO 8601",
          proc () =
            var c = newCollector()
            var r: seq[RecOut]
            discard c.handleEvent(ev("ready", "not-a-time"), r))
  coreErr("a ws event with non-hex payload is a violation", "hex",
          proc () =
            var c = newCollector()
            var r: seq[RecOut]
            discard c.handleEvent(ev("ws", ts, ("conn", hInt(1)),
              ("payload_hex", hStr("zz"))), r))
  coreErr("an unsolicited rest event is a violation", "unsolicited",
          proc () =
            var c = newCollector()
            var r: seq[RecOut]
            discard c.handleEvent(evRest("up", 1, 200, "N", "", "{}"), r))
  coreErr("a rest event out of chain order is a violation", "unsolicited",
          proc () =
            var c = newCollector()
            discard c.step(ev("ready", ts))
            discard c.step(ev("conn", ts, ("conn", hInt(1)),
              ("state", hStr("open"))))
            discard c.step(evWs(1, ackPayload()))
            var r: seq[RecOut]
            discard c.handleEvent(evRest("down", 1, 200, "N", "",
              restBody(@["005930"])), r))
  coreErr("an unknown conn state is a violation", "unknown conn state",
          proc () =
            var c = newCollector()
            discard c.step(ev("ready", ts))
            var r: seq[RecOut]
            discard c.handleEvent(ev("conn", ts, ("conn", hInt(1)),
              ("state", hStr("zzz"))), r))
  coreErr("an unknown error kind is a violation", "unknown error kind",
          proc () =
            var c = newCollector()
            discard c.step(ev("ready", ts))
            var r: seq[RecOut]
            discard c.handleEvent(ev("error", ts, ("detail", hStr("")),
              ("what", hStr("zzz"))), r))
  coreErr("a page jump inside a chain is a violation", "unsolicited",
          proc () =
            var c = newCollector()
            discard c.step(ev("ready", ts))
            discard c.step(ev("conn", ts, ("conn", hInt(1)),
              ("state", hStr("open"))))
            discard c.step(evWs(1, ackPayload()))
            var r: seq[RecOut]
            discard c.handleEvent(evRest("up", 2, 200, "N", "",
              restBody(@["005930"])), r))

# ------------------------------------------- truncated chains (poll / initial)

block truncation:
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  discard c.step(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(ev("timer", ts, ("kind", hStr("poll"))))
  # A poll chain that rides cont-yn=Y to the declared cap is a recorded
  # truncation, never a swap: the session keeps streaming. The cap is 10.
  for page in 1 .. 9:
    discard c.step(evRest("up", page, 200, "Y", "k" & $page,
                          restBody(@["005930"])))
  var recs: seq[RecOut]
  var dirs: seq[Directive]
  (recs, dirs) = c.step(evRest("up", 10, 200, "Y", "k10",
                               restBody(@["005930"])))
  check("riding the cap with cont-yn=Y records the truncation gap",
        recs.kinds() == @["rest_resp", "gap"] and
        recs[1].raw.get("what").strVal == "rest_truncated")
  check("a truncated poll chain swaps nothing and keeps streaming",
        dirs.len == 0 and c.phase == phStreaming and not c.incomplete)

  # A truncated INITIAL chain is a declared truncated subset: the gap
  # record carries the truncation (never success), the fetched pages feed
  # the derivation, and the session proceeds (REPLAY_CONTRACT §12.1: the
  # pages beyond the cap are "not fetched", never "no more candidates").
  var c2 = newCollector()
  discard c2.step(ev("ready", ts))
  discard c2.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c2.step(evWs(1, ackPayload()))
  var recs2: seq[RecOut]
  var dirs2: seq[Directive]
  for page in 1 .. 10:
    (recs2, dirs2) = c2.step(evRest("up", page, 200, "Y", "k" & $page,
                                    restBody(@["0059" & align($page, 2, '0')])))
  check("a truncated INITIAL up chain records the gap and opens the down " &
        "leg (the declared subset proceeds, never an early INCOMPLETE)",
        recs2.kinds() == @["rest_resp", "gap"] and
        recs2[1].raw.get("what").strVal == "rest_truncated" and
        dirs2.dirKinds() == @["rest_req"] and
        dirs2[0].direction == dirDown and dirs2[0].page == 1 and
        c2.phase == phInitialRest and not c2.incomplete)
  for page in 1 .. 10:
    (recs2, dirs2) = c2.step(evRest("down", page, 200, "Y", "k" & $page,
                                     restBody(@["0006" & align($page, 2, '0')])))
  check("a truncated INITIAL down chain records the gap, derives the " &
        "declared subset and issues the candidate REG",
        recs2.kinds() == @["rest_resp", "gap", "sub"] and
        recs2[1].raw.get("what").strVal == "rest_truncated" and
        dirs2.dirKinds() == @["reg"] and c2.awaiting == awCandReg and
        c2.candidatesKnown and not c2.incomplete)

# ---------------------------------------------------- parse-failure counting

block parseFailures:
  var c = newCollector()
  discard c.step(ev("ready", ts))
  discard c.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  discard c.step(evWs(1, ackPayload()))
  discard c.step(evRest("up", 1, 200, "N", "", restBody(@["005930"])))
  discard c.step(evRest("down", 1, 200, "N", "", restBody(@["000660"])))
  discard c.step(evWs(1, ackPayload()))
  var recs: seq[RecOut]
  (recs, _) = c.step(evWs(1, tick0B(cum = "-5")))
  check("an unparseable 0B stays preserved, counted, and non-fatal: the " &
        "session keeps recording",
        recs.kinds() == @["ws_raw"] and c.parseFailures == 1 and
        not c.incomplete)
  (recs, _) = c.step(evWs(1, "not json at all"))
  check("unknown-class payloads are ws_raw-only evidence",
        recs.kinds() == @["ws_raw"] and c.unknownPayloads == 1 and
        recs[0].raw.get("channel").strVal == "unknown")
  (recs, _) = c.step(evWs(1, ackPayload(code = 1)))
  check("an ack with nothing in flight adds no sub record (ws_raw only)",
        recs.kinds() == @["ws_raw"])

  var c2 = newCollector()
  discard c2.step(ev("ready", ts))
  discard c2.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  (recs, _) = c2.step(evWs(1, ackPayload(trnm = "REMOVE", code = 0)))
  check("an ack whose action mismatches the awaited one is counted " &
        "without a sub record",
        recs.kinds() == @["ws_raw"] and c2.unmatchedAcks == 1 and
        c2.awaiting == awMarketReg)
  (recs, _) = c2.step(evWs(1, ackPayload()))
  check("the correctly awaited ack still pairs afterwards",
        recs.kinds() == @["ws_raw", "sub"] and c2.awaiting == awNone)

  var c3 = newCollector()
  discard c3.step(ev("ready", ts))
  discard c3.step(ev("conn", ts, ("conn", hInt(1)), ("state", hStr("open"))))
  (recs, _) = c3.step(evWs(1, "{\"trnm\":\"REG\"}"))
  check("an awaited ack without return_code is a parse failure (ws_raw " &
        "only, nothing recorded, nothing disarmed)",
        recs.kinds() == @["ws_raw"] and c3.parseFailures == 1 and
        c3.awaiting == awMarketReg)

if failures == 0:
  echo "COLLECTOR CONTRACT PASSED (", passes, " checks)"
else:
  echo "COLLECTOR CONTRACT FAILED: ", failures, " of ", passes + failures
  quit(1)
