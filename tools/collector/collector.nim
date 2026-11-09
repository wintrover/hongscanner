## collector: the VS-2 live collector binary (tools/collector/README.md).
##
## Owns the sidecar process and the Recorder; the judgment authority is
## src/hs/collector.nim (one sidecar line in, records + directives out).
## This file adds the adapter-boundary pieces the core must not have: the
## subprocess, the record file, the 60 s syncNow heartbeat, the input-log
## fsync that precedes every event publication (REPLAY_CONTRACT §13.2:
## evidence is durable before the event that cites it is published) and
## the exit codes (README §8):
##   0  normal — drain_done -> recorder.finish() (seal + COMMITTED marker)
##      -> stop -> sidecar exit 0;
##   2  usage or pipe-protocol violation — nothing is sealed, the file is
##      preserved via abandon();
##   4  INCOMPLETE — the honest failure: finish() is never called, the
##      unsealed file is preserved (exit codes; GATES: INCOMPLETE never
##      becomes success).
##
## Usage: collector --profile <alias> --session-date YYYY-MM-DD --out <dir>
##                --calendar=<path> [--environment=demo]
##                [--token-source=kiwoomcli]
##                [--mrkt-tp=000] ... (declared query
##                scope, approved PH-1 values by default).
import std/[os, osproc, strutils, posix, times, streams]
import hs/[hcj, records, calendars, engine, collector, recorder, event_gen]

const usageText = """collector — the VS-2 live collector (demo|real)

  collector --profile <alias> --session-date YYYY-MM-DD --out <dir>
            --calendar=<path>
            [--environment=demo]
            [--token-source=kiwoomcli]
            [--mrkt-tp=000 --trde-qty-cnd=0000 --stk-cnd=0 --crd-cnd=0
             --updown-incls=1 --pric-cnd=0 --trde-prica-cnd=0 --stex-tp=1]
            [--lookback-bars=3 --warmup-bars=0 --trend-min-bp=50
             --countermove-min-bp=50 --directional-trigger-bp=30
             --hold-on-degraded=1]

--environment selects the operating environment: "demo" (default, the
mock servers) or "real" (the operational servers). Every domain — REST,
WS, the OAuth token endpoint — is derived from this one selection; there
is no cross-environment mix and no fallback: an unknown value is
refused. Any other name (including "prod") is refused.

--token-source names the sidecar credential path carried in the init
line: "kiwoomcli" (default — the native client's token cache) or "env"
(direct OAuth issuance from the environment-selected credential
variables — APP_KEY_MOCK/APP_SECRET_MOCK for demo,
APP_KEY_REAL/APP_SECRET_REAL for real; README §5.1 — the cloud
container path). Any other value is refused. The env path never
substitutes one environment's credentials for the other: a real session
refuses to start on demo variables, and vice versa.

Exit codes: 0 normal, 2 usage/contract, 4 INCOMPLETE (unsealed, preserved).
"""

proc fail(code: int; msg: string) {.noreturn.} =
  stderr.writeLine(msg)
  quit(code)

proc argValue(args: seq[string]; name: string): string =
  for a in args:
    if a.startsWith("--" & name & "="):
      return a[("--" & name & "=").len .. ^1]
  ""

proc hasArgValue(args: seq[string]; name: string): bool =
  ## Whether the flag was passed at all — an explicitly empty value is
  ## distinct from an absent flag: the absent flag takes the declared
  ## default, the empty value is a refusal, never a silent default.
  for a in args:
    if a.startsWith("--" & name & "="):
      return true
  false

proc defaultStr(v, d: string): string =
  if v.len == 0: d else: v

proc defaultInt(v: string; d: int; name: string): int =
  if v.len == 0: return d
  try:
    parseInt(v)
  except ValueError:
    fail(2, "collector: --" & name & " must be an integer")

proc argFlag(args: seq[string]; name: string): bool =
  "--" & name in args

# ---------------------------------------------------------------- sidecar

proc pythonCmd(): string =
  ## The sidecar interpreter: $HSCOLLECTOR_PYTHON, then the slice's venv,
  ## then the system python3 (the venv is what test_sidecar.sh guarantees;
  ## a live run needs websockets installed wherever this resolves).
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
  fail(2, "sidecar.py not found next to the binary or in the repository")

# ------------------------------------------------------------- pipe input

type
  ReadResult* = enum rrLine, rrTimeout, rrEof
  PipeReader = object
    fd: cint
    acc: string
    eof: bool

proc pollFd(fd: cint; timeoutMs: int): bool =
  var pfd: TPollfd
  pfd.fd = fd
  pfd.events = POLLIN
  let n = posix.poll(addr pfd, 1, cint(timeoutMs))
  # POLLHUP (the last writer closed the pipe) and POLLERR are ready too:
  # a pipe at end-of-file may report POLLHUP without POLLIN (measured on
  # kernel 6.17: events=16), and read() then answers the EOF. Treating it
  # as a timeout made readLine return rrTimeout forever — the collector
  # spun instead of going honestly INCOMPLETE when the sidecar died
  # mid-session (found by the process-pair drill).
  result = n > 0 and
    (pfd.revents and (POLLIN or POLLHUP or POLLERR)) != 0

proc readLine(r: var PipeReader; timeoutMs: int): (ReadResult, string) =
  ## One LF-terminated line, a timeout (for the syncNow heartbeat), or EOF.
  ## Never returns a partial line as a record: EOF carries the remainder,
  ## which the caller refuses.
  while true:
    let nl = find(r.acc, '\n')
    if nl >= 0:
      result = (rrLine, r.acc[0 ..< nl])
      # Consume the returned line: without this the next call would find
      # the same newline again and re-deliver the first line forever
      # (found by the process-pair drill; a session could never get past
      # its first event).
      r.acc = r.acc[nl + 1 ..< r.acc.len]
      return
    if r.eof:
      if r.acc.len == 0:
        return (rrEof, "")
      result = (rrEof, r.acc)
      r.acc = ""
      return
    if not pollFd(r.fd, timeoutMs):
      return (rrTimeout, "")
    var chunk: array[65536, char]
    let n = posix.read(r.fd, addr chunk[0], chunk.len)
    if n < 0:
      if errno == EINTR:
        continue
      raise newException(IOError, "sidecar stdout read failed: " &
        $strerror(errno))
    if n == 0:
      r.eof = true
      continue
    for i in 0 ..< n:
      r.acc.add(chunk[i])

# ------------------------------------------------------------- events journal

const oNoFollow = cint(0o400000) ## Linux `O_NOFOLLOW`; not in std/posix.

type
  EventsLogError* = object of CatchableError

  EventsLog = object
    ## The live event journal (REPLAY_CONTRACT §13): every judged fact
    ## appended in judgment order, each as one complete canonical HCJ
    ## line + LF, strictly AFTER its evidence record exists in
    ## input.hcj.jsonl and that evidence's fsync has succeeded
    ## (record-first, §13.2). The journal is derived
    ## evidence: a crash loses nothing that replaying the recorded
    ## stream cannot reconstruct, so it carries the recorder's
    ## exclusive-creation and complete-line discipline but no seal
    ## protocol — the seal belongs to the input log alone.
    fd: cint
    path: string
    count: int

proc openEventsLog(path: string): EventsLog =
  ## Exclusive creation next to the input log: an existing journal is
  ## prior evidence, never overwritten, exactly like openRecorder's rule
  ## for the input log.
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL or
                      oNoFollow or O_CLOEXEC, 0o644)
  if fd < 0:
    if errno == EEXIST:
      raise newException(EventsLogError,
        "COLLECTOR REFUSED: the live events journal already exists, " &
        "refusing to overwrite: " & path)
    raise newException(EventsLogError,
      "COLLECTOR REFUSED: cannot create the live events journal " & path &
      ": " & $strerror(errno))
  EventsLog(fd: fd, path: path)

proc appendEvent(el: var EventsLog; line: string) =
  ## One complete canonical event line + LF, EINTR-retried like the
  ## recorder's writes. A hard error closes the fd: every later append
  ## is refused, so a torn line can never be followed by more lines.
  var buf = line & "\n"
  var off = 0
  while off < buf.len:
    let n = posix.write(el.fd, cast[pointer](unsafeAddr buf[off]),
                        buf.len - off)
    if n > 0:
      inc off, n
    elif n < 0 and errno == EINTR:
      discard
    else:
      discard posix.close(el.fd)
      el.fd = -1
      raise newException(IOError,
        "events journal write failed: " & el.path & ": " & $strerror(errno))
  inc el.count

proc closeEventsLog(el: var EventsLog) =
  if el.fd >= 0:
    discard posix.close(el.fd)
    el.fd = -1

# ------------------------------------------------------------------- main

proc main(): int =
  let args = commandLineParams()
  if args.len == 0 or argFlag(args, "help") or argFlag(args, "h"):
    stdout.write(usageText)
    return 2
  let profile = argValue(args, "profile")
  let sessionDate = argValue(args, "session-date")
  let outDir = argValue(args, "out")
  let calendarPath = argValue(args, "calendar")
  let environment = if hasArgValue(args, "environment"):
                      argValue(args, "environment")
                    else:
                      "demo"
  let tokenSource = argValue(args, "token-source").defaultStr("kiwoomcli")
  if profile.len == 0 or sessionDate.len == 0 or outDir.len == 0:
    fail(2, "collector requires --profile, --session-date and --out")
  if calendarPath.len == 0:
    fail(2, "collector requires --calendar (the approved snapshot)")
  if environment != "demo" and environment != "real":
    fail(2, "collector: --environment must be demo or real (got: " &
                environment & "; there is no fallback to another " &
                "environment)")
  if tokenSource != "kiwoomcli" and tokenSource != "env":
    fail(2, "collector: --token-source must be kiwoomcli or env")
  # createDir is pure creation: it never destroys an existing directory's
  # content, and openRecorder refuses an existing input file outright.
  try:
    createDir(outDir)
  except OSError as e:
    fail(2, "cannot create the run directory: " & outDir & ": " & e.msg)
  if not dirExists(outDir):
    fail(2, "run directory is not a directory: " & outDir)

  var cfg: CollectorConfig
  try:
    cfg = initCollectorConfig(
      sessionDate, environment, profile,
      argValue(args, "mrkt-tp").defaultStr("000"),
      argValue(args, "trde-qty-cnd").defaultStr("0000"),
      argValue(args, "stk-cnd").defaultStr("16"),
      argValue(args, "crd-cnd").defaultStr("0"),
      argValue(args, "updown-incls").defaultStr("1"),
      argValue(args, "pric-cnd").defaultStr("0"),
      argValue(args, "trde-prica-cnd").defaultStr("0"),
      argValue(args, "stex-tp").defaultStr("1"),
      Params(
        warmupBars: argValue(args, "warmup-bars").defaultInt(0, "warmup-bars"),
        lookbackBars: argValue(args, "lookback-bars").defaultInt(3,
          "lookback-bars"),
        trendMinBp: argValue(args, "trend-min-bp").defaultInt(50,
          "trend-min-bp"),
        countermoveMinBp: argValue(args, "countermove-min-bp").defaultInt(50,
          "countermove-min-bp"),
        directionalTriggerBp: argValue(args, "directional-trigger-bp")
          .defaultInt(30, "directional-trigger-bp"),
        holdOnDegraded:
          argValue(args, "hold-on-degraded").defaultInt(1,
            "hold-on-degraded") != 0),
      readDocFile(calendarPath),
      tokenSource)
  except CollectorError as e:
    fail(2, "COLLECTOR CONFIG: " & e.msg)
  except CoverageError as e:
    fail(3, "COLLECTOR CALENDAR: " & e.msg)
  except HcjError as e:
    fail(2, "COLLECTOR CALENDAR unreadable: " & e.msg)
  except IOError as e:
    fail(2, "COLLECTOR CALENDAR unreadable: " & e.msg)

  var rec: Recorder
  let inputPath = outDir / "input.hcj.jsonl"
  try:
    rec = openRecorder(inputPath)
  except RecorderError as e:
    fail(2, "COLLECTOR RECORDER: " & e.msg)

  # The live event journal: created exclusively next to the input log
  # (an existing journal is prior evidence, never overwritten).
  var elog: EventsLog
  try:
    elog = openEventsLog(outDir / "events.hcj.jsonl")
  except EventsLogError:
    try:
      rec.abandon()
    except CatchableError:
      discard
    fail(2, getCurrentExceptionMsg())
  defer:
    closeEventsLog(elog)

  var egen = initEventGenState()

  # Launch the sidecar (no shell): its stderr stays ours for diagnosis; its
  # stdout is the event pipe, its stdin the command pipe. Declared before
  # the judgment machinery so judge (below) can reach preserveAndExit,
  # which shuts this process down on every failure path.
  let p = startProcess(pythonCmd(), args = @[sidecarScript()],
                       options = {poUsePath})
  defer:
    try:
      p.close()
    except CatchableError:
      discard

  proc send(cmdLine: string): bool =
    ## One command line to the sidecar; false when the pipe is broken.
    try:
      p.inputStream().write(cmdLine & "\n")
      p.inputStream().flush()
      true
    except CatchableError:
      false

  var stopSent = false

  proc sealEvents() =
    ## The end-of-stream judgment (event_gen.finish): SESSION_INCOMPLETE
    ## on an honest incomplete exit; a no-op once the stream is sealed.
    ## Best effort on failure paths only — the input log is the
    ## authoritative evidence and replay reconstructs the journal.
    try:
      for f in finish(egen):
        elog.appendEvent(eventLine(f))
    except CatchableError:
      discard

  template preserveAndExit(code: int; msg: string) {.dirty.} =
    sealEvents()
    try:
      rec.abandon()
    except CatchableError:
      discard
    if not stopSent:
      discard send(Directive(kind: dkStop).directiveLine())
    try:
      p.inputStream().close()
    except CatchableError:
      discard
    let sc = p.peekExitCode()
    if sc == -1:
      discard p.waitForExit()
    fail(code, msg)

  # The single judgment function (REPLAY_CONTRACT §13.1): every record
  # the recorder has numbered is fed to it in recorder seq order
  # (§13.3), and the judged facts are appended to the journal in
  # judgment order. Replay folds the very same function over the same
  # records; there is no second judgment. It is declared after
  # preserveAndExit so a failed pre-publication fsync can take that
  # shared failure path.
  proc judge(kind: Kind; raw: HcjValue; seqNo: int) =
    let r = Record(seq: seqNo, kind: kind, raw: raw)
    let (s2, evs) = step(egen, r)
    egen = s2
    # Durability before publication (§13.2): the notification worker
    # consumes an appended event moments after it lands, so the input
    # bytes the event was judged from must be fsynced first — a power
    # failure must never leave "the push went out, its evidence did not".
    # Event-less records, the overwhelming majority, stay on the 60 s
    # heartbeat alone, and the seal's judgment runs after finish(),
    # whose durable-completion protocol has already fsynced the whole
    # log (rec.finished()). syncNow changes no byte and poisons nothing,
    # so one immediate retry is safe; if that fails too, the event is
    # never published and the session is preserved and ends INCOMPLETE.
    if evs.len > 0 and not rec.finished():
      try:
        rec.syncNow()
      except RecorderError as e:
        stderr.writeLine("COLLECTOR sync failed (no byte changed): " & e.msg)
        try:
          rec.syncNow()
        except RecorderError:
          preserveAndExit(4, "COLLECTOR INCOMPLETE: input fsync failed " &
            "before event publication")
    for f in evs:
      elog.appendEvent(eventLine(f))

  var c = startCollector(cfg)
  try:
    if not send(cfg.initLine()):
      rec.abandon()
      fail(4, "COLLECTOR INCOMPLETE: the sidecar stdin broke at init")
    for (kind, raw) in cfg.preambleRecords():
      let sq = rec.append(kind, raw)
      judge(kind, raw, sq)
  except RecorderError as e:
    try:
      rec.abandon()
    except CatchableError:
      discard
    fail(4, "COLLECTOR INCOMPLETE: the recorder failed during the preamble: " &
      e.msg)
  except CatchableError as e:
    try:
      rec.abandon()
    except CatchableError:
      discard
    fail(2, "COLLECTOR CONTRACT: the event judgment failed during the " &
      "preamble (the records are durable, the events journal is short): " &
      e.msg)

  var reader = PipeReader(fd: p.outputHandle())
  var nextSync = epochTime() + 60.0

  while not stopSent:
    let now = epochTime()
    let waitMs = int(clamp(nextSync - now, 0.0, 60.0) * 1000.0)
    var (res, line) = reader.readLine(waitMs)
    case res
    of rrTimeout:
      try:
        rec.syncNow()
      except RecorderError as e:
        stderr.writeLine("COLLECTOR sync failed (no byte changed): " & e.msg)
      nextSync = epochTime() + 60.0
      continue
    of rrEof:
      if c.done:
        break
      # The sidecar died mid-session (or sent a torn final fragment): the
      # stream stays unsealed — INCOMPLETE, never a silent pass.
      var gapRecords: seq[RecOut]
      discard c.goIncomplete(gapRecords, $now(),
        "the sidecar pipe closed before the termination protocol completed " &
        "(exit code " & $p.peekExitCode() & ")")
      try:
        for (kind, raw) in gapRecords:
          let sq = rec.append(kind, raw)
          judge(kind, raw, sq)
      except RecorderError:
        discard
      except CatchableError:
        discard   # best effort here: the input log is the authority
      preserveAndExit(4, "COLLECTOR INCOMPLETE: the sidecar pipe closed " &
        "before the termination protocol completed")
    of rrLine:
      if line.len == 0:
        continue
      nextSync = epochTime() + 60.0
      var recs: seq[RecOut]
      var directives: seq[Directive]
      try:
        directives = c.handleEvent(line, recs)
      except CatchableError as e:
        preserveAndExit(2, "COLLECTOR CONTRACT: " & e.msg)
      try:
        for (kind, raw) in recs:
          let sq = rec.append(kind, raw)
          judge(kind, raw, sq)
      except RecorderError as e:
        preserveAndExit(4, "COLLECTOR INCOMPLETE: the recorder refused a " &
          "record; preserve and inspect the file: " & e.msg)
      except CatchableError as e:
        preserveAndExit(2, "COLLECTOR CONTRACT: the event judgment failed " &
          "(the record is durable, the events journal is short; everything " &
          "is preserved): " & e.msg)
      if c.done and not rec.finished():
        # §8 normal order: finish() (seal + COMMITTED marker) BEFORE stop.
        var sealed = false
        try:
          let total = rec.finish()
          sealed = true
          judge(kSessionEnd, hNull(), total)
        except CatchableError as e:
          if sealed:
            preserveAndExit(2, "COLLECTOR CONTRACT: the stream IS sealed " &
              "(the COMMIT marker was written) but the seal record's event " &
              "judgment failed; the journal is reconstructible by replay, " &
              "everything is preserved: " & e.msg)
          preserveAndExit(4, "COLLECTOR INCOMPLETE: the finish protocol " &
            "did not reach the COMMITTED marker: " & e.msg)
      for d in directives:
        if not send(d.directiveLine()):
          if not c.done:
            preserveAndExit(4, "COLLECTOR INCOMPLETE: the sidecar stdin " &
              "broke while sending a directive")
        if d.kind == dkStop:
          stopSent = true

  if c.incomplete:
    preserveAndExit(4, "COLLECTOR INCOMPLETE: " & c.incompleteReason)

  # Normal path: the seal is on disk; wait for the sidecar's own exit.
  p.inputStream().close()
  let sidecarCode = p.waitForExit()
  if sidecarCode != 0:
    fail(4, "COLLECTOR INCOMPLETE: the sidecar exited " & $sidecarCode &
      " after stop (the stream is sealed; inspect the run directory)")
  echo "COLLECTOR DONE records=", rec.seqNo(), " events=", elog.count
  0

when isMainModule:
  quit(main())
