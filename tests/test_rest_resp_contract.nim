## rest_resp validated acceptance path contract tests (REPLAY_CONTRACT §12.1,
## the VS-2 implementation choice that replaces the VS-1 reject-everything
## placeholder).
##
## Synthetic payloads only: no network, no vendor data, no wall clock.
## Covers: the HCJ-safe hex byte encoding, the success path (map rows,
## documented positional rows, explicit empty list, multi-page chains,
## interleaved scopes), every failure class (schema / transport / vendor
## error / missing return_code / missing list key), order and page-chain
## consistency, re-derivation from the preserved bytes, and the stream-level
## rule that a verified success changes no output byte while any failure
## stays REJECT (exit 2). ka10081 (the VS-1 daily capture, §12.9) covers the
## same envelope, its measured cont-yn=Y single-page shape, and the
## one-page-per-symbol / once-per-session capture rules.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_rest_resp_contract.nim
import std/[os, strutils, tempfiles]
import hs/[hcj, digest, records, replay, rest_resp, vendor_input, verify,
           binfo]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc restUnit(name: string; failure: VendorFailure; needle: string;
              body: proc ()) =
  ## parseAttempt/verifyAttempts must raise RestRespError of the exact
  ## failure class with a self-explaining message.
  var raised = false
  var msg = ""
  try:
    body()
  except RestRespError as e:
    raised = e.failure == failure
    msg = if raised: e.msg else: "wrong class " & $e.failure & ": " & e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and needle in msg)

proc writeStream(name: string; lines: seq[string]): string =
  ## dir/input.hcj.jsonl with LF discipline; returns the run dir.
  result = createTempDir("hs-restresp-" & name & "-", "")
  var content = ""
  for l in lines: content.add(l & "\n")
  writeFile(result / inputFile, content)

proc day(o, c: string): HcjValue =
  hObj(("close", hStr(c)), ("open", hStr(o)))

proc calRaw(): HcjValue =
  hObj(("days", hObj(
    ("2026-10-29", day("09:00:00+09:00", "15:30:00+09:00")))))

proc cfgRaw(): HcjValue = hObj(("session_date", hStr("2026-10-29")))

proc tickRaw(sym, t: string; price, vol: int64): HcjValue =
  hObj(("m", hStr("2")), ("price", hInt(price)), ("symbol", hStr(sym)),
       ("t", hStr(t)), ("vol", hInt(vol)))

proc baseLines(): seq[string] =
  ## Minimal valid session: two symbols, two bars each, normal close.
  result = @[
    makeRecordLine(1, kCalendar, calRaw()),
    makeRecordLine(2, kConfig, cfgRaw()),
    makeRecordLine(3, kWsFrame, tickRaw("005930", "09:00:00+09:00", 10000, 100)),
    makeRecordLine(4, kWsFrame, tickRaw("000660", "09:00:00+09:00", 20000, 500)),
    makeRecordLine(5, kWsFrame, tickRaw("005930", "09:03:00+09:00", 10100, 200)),
    makeRecordLine(6, kWsFrame, tickRaw("000660", "09:03:00+09:00", 20100, 700)),
    makeRecordLine(7, kSessionEnd, hNull())]

proc withInserts(lines: seq[string]; idx: int;
                 inserts: seq[(Kind, HcjValue)]): seq[string] =
  ## Insert records at idx (0-based) and renumber seq 1..N.
  var recs: seq[tuple[k: Kind, raw: HcjValue]]
  for i, l in lines:
    let r = parseRecord(l, i + 1)
    recs.add((r.kind, r.raw))
  for j, ins in inserts:
    recs.insert(ins, idx + j)
  for i, p in recs:
    result.add(makeRecordLine(i + 1, p.k, p.raw))

proc runOf(name: string; lines: seq[string]): CoreResult =
  runCore(loadRecords(writeStream(name, lines) / inputFile))

proc coreBytes(lines: seq[string]): string =
  let res = runCore(loadRecords(writeStream("core", lines) / inputFile))
  for b in res.bars: result.add(barLine(b) & "\n")
  result.add("--\n")
  for s in res.signals: result.add(signalLine(s) & "\n")

proc rejectRun(name, needle: string; lines: seq[string]) =
  ## The stream must be REJECTed (RecordError) with the wrapper prefix and
  ## the failure detail.
  var raised = false
  var msg = ""
  try:
    discard runOf("rej", lines)
  except RecordError as e:
    raised = true
    msg = e.msg
  except CatchableError as e:
    msg = "wrong exception " & $e.name & ": " & e.msg
  check(name, raised and msg.startsWith("rest_resp at seq") and
        needle in msg)

# ---------------------------------------------------------------- builders

proc hexOf(s: string): string = hexOfBytes(toBytes(s))

proc row(cd, nm, prc, rt: string): HcjValue =
  hObj(("cur_prc", hStr(prc)), ("flu_rt", hStr(rt)),
       ("stk_cd", hStr(cd)), ("stk_nm", hStr(nm)))

proc posRow(): HcjValue =
  ## One row in the documented positional (array) form: the 12 documented
  ## fields in documented order. Values stay strings.
  hArr(hStr("2"), hStr("005930"), hStr("삼성전자"), hStr("+71500"), hStr("2"),
       hStr("5000"), hStr("5.10"), hStr("1000"), hStr("900"),
       hStr("50000"), hStr("+5.5%"), hStr("0"))

proc okBody(rows: seq[HcjValue]): string =
  canonical(hObj((ka10027ListKey, hArrSeq(rows)), ("return_code", hInt(0))))

proc vendorErrBody(code: int; msg: string): string =
  canonical(hObj(("return_code", hInt(code)), ("return_msg", hStr(msg))))

proc rawBody(pairs: varargs[HcjPair]): string = canonical(hObj(pairs))

proc queryObj(sortTp = "1"; stexTp = "1"; mrktTp = "101"): HcjValue =
  ## The nine declared request fields, all pinned at documented enum values.
  hObj(("crd_cnd", hStr("0")), ("mrkt_tp", hStr(mrktTp)),
       ("pric_cnd", hStr("0")), ("sort_tp", hStr(sortTp)),
       ("stk_cnd", hStr("0")), ("stex_tp", hStr(stexTp)),
       ("trde_prica_cnd", hStr("0")), ("trde_qty_cnd", hStr("0000")),
       ("updown_incls", hStr("1")))

proc attemptRaw(body: string; page = 1; status = 200; contYn = "N";
                nextKey = ""; query: HcjValue = queryObj()): HcjValue =
  hObj(("api_id", hStr(ka10027ApiId)), ("body_hex", hStr(hexOf(body))),
       ("cont_yn", hStr(contYn)), ("next_key", hStr(nextKey)),
       ("page", hInt(page)), ("query", query), ("status", hInt(status)))

proc dropKey(v: HcjValue; key: string) =
  var keep: seq[HcjPair]
  for p in v.pairs:
    if p.k != key: keep.add(p)
  v.pairs = keep

proc setType(v: HcjValue; key: string; val: HcjValue) =
  for p in v.pairs.mitems:
    if p.k == key: p.v = val

proc sameQuery(a, b: Ka10027Query): bool =
  canonical(ka10027RequestBody(a)) == canonical(ka10027RequestBody(b))

let refScope = initKa10027Query(dirUp, "101", "0000", "0", "0", "1", "0",
                                "0", "1")

proc dailyRow(dt = "20261028"; cur = "71500"): HcjValue =
  ## One row in the measured positional form: the 12 documented ka10081
  ## fields in documented order, values as measured strings (the mock's
  ## rows are all-string arrays, /tmp/hs-ka10081/).
  hArr(hStr(cur), hStr("150000"), hStr("1074"), hStr(dt), hStr("71000"),
       hStr("72000"), hStr("70500"), hStr("-500"), hStr("5"),
       hStr("0.80"), hStr("1"), hStr("0.00"))

proc okDailyBody(stkCd: string; rows: seq[HcjValue] = @[dailyRow()]): string =
  ## A success ka10081 body: return_code 0 + return_msg + the measured
  ## top-level stk_cd echo + the daily list.
  canonical(hObj((ka10081ListKey, hArrSeq(rows)), ("return_code", hInt(0)),
                 ("return_msg", hStr("정상처리되었습니다")),
                 ("stk_cd", hStr(stkCd))))

proc dailyQueryObj(stkCd = "005930"; baseDt = "20261029";
                   upd = declaredDailyUpdStkpcTp): HcjValue =
  ## The three declared ka10081 request fields, all strings.
  hObj(("base_dt", hStr(baseDt)), ("stk_cd", hStr(stkCd)),
       ("upd_stkpc_tp", hStr(upd)))

proc dailyAttemptRaw(body: string; page = 1; status = 200; contYn = "Y";
                    nextKey = "cur_prc:20261028"; query: HcjValue = dailyQueryObj()): HcjValue =
  ## A ka10081 rest_resp record: the measured success page carries
  ## cont-yn=Y + next-key (600 rows per page, continuation exists) while the
  ## declared capture scope stays a single page.
  hObj(("api_id", hStr(ka10081ApiId)), ("body_hex", hStr(hexOf(body))),
       ("cont_yn", hStr(contYn)), ("next_key", hStr(nextKey)),
       ("page", hInt(page)), ("query", query), ("status", hInt(status)))

# ---------------------------------------------------------------- hex contract

block hexContract:
  check("hex: empty encodes to empty",
        hexOfBytes(@[]).len == 0 and bytesFromHex("").len == 0)
  let bin: seq[byte] = @[0x00'u8, 0x0a'u8, 0x22'u8, 0x7f'u8, 0x80'u8,
                         0xfe'u8, 0xff'u8]
  check("hex: arbitrary bytes round-trip byte-exact",
        bytesFromHex(hexOfBytes(bin)) == bin)
  let ko = "삼성전자/return_code 0"
  check("hex: UTF-8 text round-trips byte-exact",
        bytesFromHex(hexOfBytes(toBytes(ko))) == toBytes(ko))
  check("hex: known vector", hexOfBytes(@[0xde'u8, 0xad'u8, 0xbe'u8,
                                          0xef'u8]) == "deadbeef")
  restUnit("hex: odd length is rejected", vfContract, "odd length",
           proc () = discard bytesFromHex("abc"))
  restUnit("hex: uppercase hex is rejected", vfContract, "lowercase",
           proc () = discard bytesFromHex("DEADBEEF"))
  restUnit("hex: non-hex digit is rejected", vfContract, "lowercase",
           proc () = discard bytesFromHex("0g"))

# ---------------------------------------------------------------- success path

block unitSuccess:
  let body = okBody(@[row("005930", "삼성전자", "71500", "5.10"),
                      row("000660", "SK하이닉스", "182200", "3.25")])
  let a = parseAttempt(4, attemptRaw(body))
  check("parse surfaces the declared page index", a.page == 1)
  check("parse surfaces the declared scope",
        sameQuery(a.scope, refScope))
  check("parse surfaces the preserved response metadata",
        a.resp.apiId == ka10027ApiId and a.resp.status == 200 and
        a.resp.contYn == "N" and a.resp.nextKey == "")
  check("parse decodes the body byte-exact", a.resp.body == toBytes(body))
  check("audit fingerprint matches the decoded bytes",
        a.bodySha256 == sha256Hex(toBytes(body)))
  check("a terminal success page verifies",
        verifyAttempts(@[a]).len == 1)

  let p1 = parseAttempt(3, attemptRaw(
    okBody(@[row("005930", "삼성전자", "71500", "5.10")]),
    page = 1, contYn = "Y", nextKey = "000660"))
  let p2 = parseAttempt(4, attemptRaw(
    okBody(@[row("000660", "SK하이닉스", "182200", "3.25")]), page = 2))
  let v2 = verifyAttempts(@[p1, p2])
  check("a declared two-page chain verifies in order",
        v2.len == 2 and v2[0].page == 1 and v2[1].page == 2)

  let d1 = parseAttempt(5, attemptRaw(
    okBody(@[row("999999", "하락1위", "1000", "-1.0")]),
    page = 1, contYn = "Y", nextKey = "next", query = queryObj(sortTp = "3")))
  let d2 = parseAttempt(6, attemptRaw(
    okBody(@[row("888888", "하락2위", "900", "-2.0")]), page = 2,
    query = queryObj(sortTp = "3")))
  let v3 = verifyAttempts(@[p1, d1, p2, d2])
  check("interleaved scopes verify as separate chains", v3.len == 4)
  check("verified attempts return in stream order",
        v3[0].seqNo == 3 and v3[1].seqNo == 4 and v3[2].seqNo == 5 and
        v3[3].seqNo == 6)

  check("the documented positional row form verifies",
        verifyAttempts(@[parseAttempt(3, attemptRaw(okBody(@[posRow()])))]).len == 1)
  check("an explicit empty list is a confirmed empty answer",
        verifyAttempts(@[parseAttempt(3, attemptRaw(okBody(@[])))]).len == 1)
  check("an empty record set verifies trivially", verifyAttempts(@[]).len == 0)

# ---------------------------------------------------------------- re-derivation

block rederive:
  ## §12.2/§12.3: the normalized rows must be re-derivable from the
  ## preserved bytes. The record's body_hex decode and the original body
  ## string must yield identical events.
  let body = okBody(@[row("005930", "삼성전자", "71500", "5.10"),
                      row("000660", "SK하이닉스", "182200", "3.25")])
  let a = parseAttempt(3, attemptRaw(body))
  let direct = httpResp(ka10027ApiId, 200, "N", "", toBytes(body))
  let fromRecord = normalizeChain(ka10027Spec,
    PageChain(query: refScope, pages: @[a.resp]))
  let fromBytes = normalizeChain(ka10027Spec,
    PageChain(query: refScope, pages: @[direct]))
  check("re-derivation: same event count",
        fromRecord.len == 2 and fromBytes.len == 2)
  var same = fromRecord.len == fromBytes.len
  for i in 0 ..< min(fromRecord.len, fromBytes.len):
    if not sameEvent(fromRecord[i], fromBytes[i]): same = false
  check("re-derivation: events identical byte- and value-wise", same)
  check("re-derivation: source hash is the preserved body",
        fromRecord[0].sourceSha256 == sha256Hex(toBytes(body)))
  let syms = chainSymbols(ka10027Spec,
    PageChain(query: refScope, pages: @[a.resp]))
  check("re-derivation: candidates in vendor order",
        syms == @["005930", "000660"])
  let line = makeRecordLine(3, kRestResp, attemptRaw(body))
  let back = parseAttempt(3, parseRecord(line, 3).raw)
  check("HCJ round trip: canonical record bytes preserve body_hex exactly",
        back.bodySha256 == a.bodySha256 and back.page == 1 and
        sameQuery(back.scope, a.scope))

# ---------------------------------------------------- ka10080 acceptance

block ka10080Acceptance:
  ## The acceptance set now declares two APIs (§12.1 ka10027, §12.8
  ## ka10080): a ka10080 record with its own declared chart scope parses
  ## through the same envelope. The full ka10080 contract (scope schema,
  ## chains, BACKFILL bars) lives in test_backfill_contract.nim; this block
  ## pins the acceptance flip at the record layer.
  let body80 = canonical(hObj((ka10080ListKey, hArr()), ("return_code", hInt(0))))
  let a = parseAttempt(3, hObj(
    ("api_id", hStr(ka10080ApiId)), ("body_hex", hStr(hexOf(body80))),
    ("cont_yn", hStr("N")), ("next_key", hStr("")), ("page", hInt(1)),
    ("query", hObj(("stk_cd", hStr("005930")), ("tic_scope", hStr("3")),
                   ("upd_stkpc_tp", hStr("0")))),
    ("status", hInt(200))))
  check("ka10080: a chart record is accepted through the same envelope",
        a.api == raKa10080 and a.page == 1 and a.resp.status == 200 and
        a.bodySha256 == sha256Hex(toBytes(body80)))
  check("ka10080: a single-page chart chain verifies",
        verifyAttempts(@[a]).len == 1)
  check("ka10080: a page of one stream mixes with the ka10027 chains",
        verifyAttempts(@[a, parseAttempt(4, attemptRaw(
          okBody(@[row("005930", "삼성전자", "71500", "5.10")])))]).len == 2)

# ---------------------------------------------------- ka10081 acceptance

block ka10081Acceptance:
  ## The acceptance set declares ka10081 too (§12.9): a measured single-page
  ## daily capture parses through the same envelope, verifies in the
  ## measured cont-yn=Y page shape (the continuation is preserved response
  ## evidence, never a ka10081 obligation), audits as one scope per symbol,
  ## mixes with the other APIs' chains, and changes no output byte at the
  ## stream level.
  let body = okDailyBody("005930")
  let a = parseAttempt(3, dailyAttemptRaw(body))
  check("ka10081: parse surfaces the declared scope",
        a.api == raKa10081 and a.page == 1 and
        a.scope81.stkCd == "005930" and a.scope81.baseDt == "20261029" and
        a.scope81.updStkpcTp == declaredDailyUpdStkpcTp)
  check("ka10081: parse preserves the response metadata and body bytes",
        a.resp.apiId == ka10081ApiId and a.resp.status == 200 and
        a.resp.contYn == "Y" and a.resp.nextKey != "" and
        a.resp.body == toBytes(body) and
        a.bodySha256 == sha256Hex(toBytes(body)))
  check("ka10081: a measured cont-yn=Y single page verifies (no continuation " &
        "obligation)", verifyAttempts(@[a]).len == 1)
  let b = parseAttempt(4, dailyAttemptRaw(okDailyBody("000660"),
    query = dailyQueryObj(stkCd = "000660")))
  let v = verifyAttempts(@[a, b])
  check("ka10081: one scope per symbol, verified in stream order",
        v.len == 2 and v[0].scope81.stkCd == "005930" and
        v[1].scope81.stkCd == "000660")
  let body80 = canonical(hObj((ka10080ListKey, hArr()), ("return_code", hInt(0))))
  let c80 = parseAttempt(5, hObj(
    ("api_id", hStr(ka10080ApiId)), ("body_hex", hStr(hexOf(body80))),
    ("cont_yn", hStr("N")), ("next_key", hStr("")), ("page", hInt(1)),
    ("query", hObj(("stk_cd", hStr("005930")), ("tic_scope", hStr("3")),
                   ("upd_stkpc_tp", hStr("0")))),
    ("status", hInt(200))))
  check("ka10081: the same symbol's ka10080 scope never collides",
        verifyAttempts(@[a, c80]).len == 2)
  check("ka10081: a daily page mixes with the ka10027 chains",
        verifyAttempts(@[a, parseAttempt(6, attemptRaw(
          okBody(@[row("005930", "삼성전자", "71500", "5.10")])))]).len == 2)
  check("ka10081: an explicit empty daily list is a confirmed empty answer",
        verifyAttempts(@[parseAttempt(3, dailyAttemptRaw(
          okDailyBody("005930", @[])))]).len == 1)

  let lines = withInserts(baseLines(), 6, @[(kRestResp, dailyAttemptRaw(body))])
  let res = runOf("daily-ok", lines)
  check("ka10081: a verified daily capture stream replays OK",
        res.status == rsOk and res.restVerified == 1)
  check("ka10081: the daily acceptance changes no output byte",
        coreBytes(lines) == coreBytes(baseLines()))

# ---------------------------------------------------------------- schema

block failureSchema:
  let body = okBody(@[row("005930", "삼성전자", "71500", "5.10")])

  restUnit("schema: null raw is rejected", vfContract, "not an object",
           proc () = discard parseAttempt(3, hNull()))
  restUnit("schema: string raw is rejected", vfContract, "not an object",
           proc () = discard parseAttempt(3, hStr("ok")))
  restUnit("schema: array raw is rejected", vfContract, "not an object",
           proc () = discard parseAttempt(3, hArr(hInt(200))))
  restUnit("schema: empty object is missing fields", vfContract,
           "missing rest_resp field: api_id",
           proc () = discard parseAttempt(3, hObj()))
  restUnit("schema: unknown record field (legacy vendor_msg)", vfContract,
           "unknown rest_resp field: vendor_msg",
           proc () =
             let r = attemptRaw(body)
             r.pairs.add(("vendor_msg", hStr("extra")))
             discard parseAttempt(3, r))
  restUnit("schema: missing body_hex", vfContract,
           "missing rest_resp field: body_hex",
           proc () =
             let r = attemptRaw(body)
             dropKey(r, "body_hex")
             discard parseAttempt(3, r))
  restUnit("schema: status is not an integer", vfContract, "not an integer",
           proc () =
             let r = attemptRaw(body)
             setType(r, "status", hStr("200"))
             discard parseAttempt(3, r))
  restUnit("schema: page 0 is rejected", vfContract,
           "page index must be >= 1",
           proc () = discard parseAttempt(3, attemptRaw(body, page = 0)))
  restUnit("schema: api_id outside the declared path", vfContract,
           "outside the declared acceptance path",
           proc () =
             let r = attemptRaw(body)
             setType(r, "api_id", hStr("ka11080"))
             discard parseAttempt(3, r))
  restUnit("schema: sort_tp 2 is not a candidate direction", vfContract,
           "not a candidate direction",
           proc () = discard parseAttempt(3,
             attemptRaw(body, query = queryObj(sortTp = "2"))))
  restUnit("schema: stex_tp 3 is outside the KRX universe", vfContract,
           "outside the candidate universe",
           proc () = discard parseAttempt(3,
             attemptRaw(body, query = queryObj(stexTp = "3"))))
  restUnit("schema: mrkt_tp outside the documented enum", vfContract,
           "not in the documented enum",
           proc () = discard parseAttempt(3,
             attemptRaw(body, query = queryObj(mrktTp = "999"))))
  restUnit("schema: query is not an object", vfContract, "not an object",
           proc () =
             let r = attemptRaw(body)
             setType(r, "query", hStr("nope"))
             discard parseAttempt(3, r))
  restUnit("schema: query misses a declared field", vfContract,
           "missing declared query field: sort_tp",
           proc () =
             let q = queryObj()
             dropKey(q, "sort_tp")
             discard parseAttempt(3, attemptRaw(body, query = q)))
  restUnit("schema: query has an unknown field", vfContract,
           "unknown declared query field: extra",
           proc () =
             let q = queryObj()
             q.pairs.add(("extra", hStr("x")))
             discard parseAttempt(3, attemptRaw(body, query = q)))
  restUnit("schema: query field is not a string", vfContract,
           "declared query field is not a string",
           proc () =
             let q = queryObj()
             setType(q, "mrkt_tp", hInt(101))
             discard parseAttempt(3, attemptRaw(body, query = q)))
  restUnit("schema: body_hex is not a string", vfContract, "not a string",
           proc () =
             let r = attemptRaw(body)
             setType(r, "body_hex", hInt(0))
             discard parseAttempt(3, r))

block ka10081Schema:
  let body = okDailyBody("005930")
  restUnit("ka10081 schema: missing base_dt is rejected (the measured " &
           "vendor requires all three fields)", vfContract,
           "missing declared ka10081 query field: base_dt",
           proc () =
             let q = dailyQueryObj()
             dropKey(q, "base_dt")
             discard parseAttempt(3, dailyAttemptRaw(body, query = q)))
  restUnit("ka10081 schema: unknown query field is rejected", vfContract,
           "unknown declared ka10081 query field: extra",
           proc () =
             let q = dailyQueryObj()
             q.pairs.add(("extra", hStr("x")))
             discard parseAttempt(3, dailyAttemptRaw(body, query = q)))
  restUnit("ka10081 schema: a query field is not a string", vfContract,
           "declared ka10081 query field is not a string",
           proc () =
             let q = dailyQueryObj()
             setType(q, "stk_cd", hInt(5930))
             discard parseAttempt(3, dailyAttemptRaw(body, query = q)))
  restUnit("ka10081 schema: upd_stkpc_tp 0 is outside the declared capture " &
           "scope", vfContract, "declared capture scope",
           proc () = discard parseAttempt(3, dailyAttemptRaw(body,
             query = dailyQueryObj(upd = "0"))))
  restUnit("ka10081 schema: base_dt outside the measured YYYYMMDD form",
           vfContract, "YYYYMMDD",
           proc () = discard parseAttempt(3, dailyAttemptRaw(body,
             query = dailyQueryObj(baseDt = "2026-10-29"))))
  restUnit("ka10081 schema: an empty stk_cd is rejected", vfContract,
           "stk_cd must not be empty",
           proc () = discard parseAttempt(3, dailyAttemptRaw(body,
             query = dailyQueryObj(stkCd = ""))))

# ------------------------------------------------- success affirmation failures

proc unitVerify(name: string; failure: VendorFailure; needle: string;
                a: RestRespAttempt) =
  ## The attempt parses; its affirmation/chain check must reject it.
  restUnit(name, failure, needle,
           proc () = discard verifyAttempts(@[a]))

block failureAffirmation:
  unitVerify("transport: HTTP 503 page is rejected", vfTransport,
             "HTTP status 503",
             parseAttempt(3, attemptRaw(okBody(@[]), status = 503)))
  unitVerify("vendor error: return_code 5 is rejected", vfVendorError,
             "vendor return_code 5",
             parseAttempt(3, attemptRaw(vendorErrBody(5, "조회 거부"))))
  unitVerify("missing return_code never maps to success", vfVendorError,
             "return_code is missing",
             parseAttempt(3, attemptRaw(rawBody(("return_msg", hStr("ok"))))))
  unitVerify("missing list key never maps to empty", vfContract,
             ka10027ListKey & " is missing",
             parseAttempt(3, attemptRaw(rawBody(("return_code", hInt(0))))))
  unitVerify("body that is not JSON is rejected", vfContract,
             "not valid HCJ JSON",
             parseAttempt(3, attemptRaw("nope")))
  unitVerify("body that is not an object is rejected", vfContract,
             "not a JSON object",
             parseAttempt(3, attemptRaw("[]")))
  unitVerify("unknown body key is rejected", vfContract,
             "outside the documented schema",
             parseAttempt(3, attemptRaw(rawBody(("extra", hInt(1)),
                                                ("return_code", hInt(0))))))
  unitVerify("row field outside the schema is rejected", vfContract,
             "row field outside the documented schema",
             parseAttempt(3, attemptRaw(okBody(@[
               hObj(("hack", hStr("x")), ("stk_cd", hStr("005930")))]))))
  unitVerify("non-string row field is rejected", vfContract,
             "row field is not a string",
             parseAttempt(3, attemptRaw(okBody(@[
               hObj(("stk_cd", hInt(5930)))]))))
  unitVerify("positional row with the wrong length is rejected", vfContract,
             "positional row length is not the documented field count",
             parseAttempt(3, attemptRaw(okBody(@[
               hArr(hStr("2"), hStr("005930"))]))))

block ka10081Affirmation:
  unitVerify("ka10081: HTTP 429 (rate limit) is transport-rejected",
             vfTransport, "HTTP status 429",
             parseAttempt(3, dailyAttemptRaw(okDailyBody("005930"),
               status = 429)))
  unitVerify("ka10081: vendor return_code 2 (a missing request field at " &
             "the vendor) is rejected", vfVendorError, "vendor return_code 2",
             parseAttempt(3, dailyAttemptRaw(vendorErrBody(2, "필수값 누락"))))
  unitVerify("ka10081: missing return_code never maps to success",
             vfVendorError, "return_code is missing",
             parseAttempt(3, dailyAttemptRaw(
               rawBody(("return_msg", hStr("ok")), ("stk_cd", hStr("005930"))))))
  unitVerify("ka10081: missing list key never maps to empty", vfContract,
             ka10081ListKey & " is missing",
             parseAttempt(3, dailyAttemptRaw(
               rawBody(("return_code", hInt(0)), ("stk_cd", hStr("005930"))))))
  unitVerify("ka10081: a body key outside the documented schema (the echo " &
             "set is exactly stk_cd) is rejected", vfContract,
             "outside the documented schema",
             parseAttempt(3, dailyAttemptRaw(rawBody(
               ("extra", hInt(1)), ("return_code", hInt(0)),
               ("stk_cd", hStr("005930"))))))
  unitVerify("ka10081: row field outside the schema is rejected", vfContract,
             "row field outside the documented schema",
             parseAttempt(3, dailyAttemptRaw(okDailyBody("005930", @[
               hObj(("hack", hStr("x")), ("dt", hStr("20261028")))]))))
  unitVerify("ka10081: non-string row field is rejected", vfContract,
             "row field is not a string",
             parseAttempt(3, dailyAttemptRaw(okDailyBody("005930", @[
               hObj(("dt", hInt(20261028)))]))))
  unitVerify("ka10081: positional row with the wrong length is rejected",
             vfContract, "positional row length is not the documented field count",
             parseAttempt(3, dailyAttemptRaw(okDailyBody("005930", @[
               hArr(hStr("71500"))]))))

# ---------------------------------------------------------------- chain rules

block chainRules:
  restUnit("chain: first recorded page must be 1", vfContract,
           "does not start at page 1",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]), page = 2))]))
  restUnit("chain: a page gap is rejected", vfContract, "leaves a gap",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]), page = 1,
                                        contYn = "Y", nextKey = "k")),
             parseAttempt(4, attemptRaw(okBody(@[]), page = 3))]))
  restUnit("chain: a duplicate page-1 restart is rejected", vfContract,
           "repeats page 1",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]))),
             parseAttempt(4, attemptRaw(okBody(@[])))]))
  restUnit("chain: cont-yn=Y below the cap is incomplete", vfIncomplete,
           "continuation page is missing",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]), contYn = "Y",
                                        nextKey = "k"))]))
  block:
    var xs: seq[RestRespAttempt]
    for p in 1 .. defaultPageCap:
      xs.add(parseAttempt(p + 2, attemptRaw(okBody(@[]), page = p,
                                            contYn = "Y", nextKey = $p)))
    let vt = verifyAttempts(@xs)
    check("chain: a cap-closed round audits as a declared truncated subset " &
          "(accepted, pages verified, truncation carried by the gap record)",
          vt.len == defaultPageCap)
  restUnit("chain: a terminal page followed by more pages is rejected",
           vfContract, "more pages follow",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]))),
             parseAttempt(4, attemptRaw(okBody(@[]), page = 2))]))
  restUnit("chain: cont-yn=Y without next-key is rejected", vfContract,
           "without next-key",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, attemptRaw(okBody(@[]), contYn = "Y")),
             parseAttempt(4, attemptRaw(okBody(@[]), page = 2))]))

block ka10081Chain:
  let a1 = parseAttempt(3, dailyAttemptRaw(okDailyBody("005930")))
  let a2 = parseAttempt(4, dailyAttemptRaw(okDailyBody("005930")))
  restUnit("ka10081 chain: a second page of the same scope is rejected " &
           "(exactly one page)", vfContract, "exactly one page",
           proc () = discard verifyAttempts(@[
             parseAttempt(3, dailyAttemptRaw(okDailyBody("005930"))),
             parseAttempt(4, dailyAttemptRaw(okDailyBody("005930"), page = 2))]))
  restUnit("ka10081 chain: a repeated page 1 is rejected fail-closed",
           vfContract, "repeats page 1",
           proc () = discard verifyAttempts(@[a1, a2]))
  restUnit("ka10081 chain: a repeated scope is rejected even under a " &
           "declared re-poll cadence (once per symbol per session)",
           vfContract, "once per symbol per session",
           proc () = discard verifyAttempts(@[a1, a2], pollSeconds = 300))

# ---------------------------------------------------------------- stream level

let upPage1 = attemptRaw(
  okBody(@[row("005930", "삼성전자", "71500", "5.10")]),
  page = 1, contYn = "Y", nextKey = "000660")
let upPage2 = attemptRaw(
  okBody(@[row("000660", "SK하이닉스", "182200", "3.25")]), page = 2)
let okInfo = BuildInfo(codeCommit: "abc123", sourceRef: "main",
  originMainSha: "abc123", dirty: false, nimVersion: NimVersion,
  buildTime: "t")

block streamAcceptance:
  let successLines = withInserts(baseLines(), 6,
                                 @[(kRestResp, upPage1), (kRestResp, upPage2)])
  let res = runOf("ok", successLines)
  check("a verified success rest_resp stream replays OK",
        res.status == rsOk)
  check("verified pages are recorded on the result", res.restVerified == 2)
  check("acceptance changes no output byte",
        coreBytes(successLines) == coreBytes(baseLines()))

  let early = withInserts(baseLines(), 2,
                          @[(kRestResp, upPage1), (kRestResp, upPage2)])
  let resEarly = runOf("pos-ok", early)
  check("rest_resp right after the preamble is accepted when verified",
        resEarly.status == rsOk and resEarly.restVerified == 2)
  check("acceptance position changes no output byte",
        coreBytes(early) == coreBytes(baseLines()))

block streamIncomplete:
  let terminal = attemptRaw(
    okBody(@[row("005930", "삼성전자", "71500", "5.10")]), page = 1)
  let lines = withInserts(baseLines()[0 .. ^2], 5, @[(kRestResp, terminal)])
  let res = runOf("inc", lines)
  check("a verified success rest_resp without session_end is INCOMPLETE " &
        "(not REJECT)", res.status == rsIncomplete and res.restVerified == 1)
  let dir = writeStream("inc-run", lines)
  let inPath = dir / inputFile
  discard writeRun(dir / "run", inPath, runCore(loadRecords(inPath)), okInfo)
  let v = verifyRun(dir / "run", okInfo)
  check("verify reports INCOMPLETE exit 4 for it",
        v.verdict == vIncomplete and exitCode(v.verdict) == 4)

block streamRejections:
  let legacy = hObj(("body", hArr()), ("http_status", hInt(200)),
                    ("status", hStr("ok")))

  rejectRun("stream: schema violation is REJECT with the record named",
            "unknown rest_resp field",
            withInserts(baseLines(), 6, @[(kRestResp, legacy)]))
  rejectRun("stream: transport failure is REJECT", "HTTP status 503",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(okBody(@[]), status = 503))]))
  rejectRun("stream: vendor error is REJECT", "vendor return_code 5",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(vendorErrBody(5, "조회 거부")))]))
  rejectRun("stream: missing return_code is REJECT", "return_code is missing",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(rawBody(("return_msg", hStr("ok")))))]))
  rejectRun("stream: missing list key is REJECT",
            ka10027ListKey & " is missing",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(rawBody(("return_code", hInt(0)))))]))
  rejectRun("stream: page order violation is REJECT",
            "does not start at page 1",
            withInserts(baseLines(), 6, @[(kRestResp, upPage2)]))
  rejectRun("stream: a chain that ends while cont-yn=Y is REJECT",
            "continuation page is missing",
            withInserts(baseLines(), 6, @[(kRestResp,
              attemptRaw(okBody(@[]), contYn = "Y", nextKey = "k"))]))
  rejectRun("stream: a ka10081 two-page scope is REJECT (exactly one page)",
            "exactly one page",
            withInserts(baseLines(), 6, @[
              (kRestResp, dailyAttemptRaw(okDailyBody("005930"))),
              (kRestResp, dailyAttemptRaw(okDailyBody("005530"), page = 2,
                                          nextKey = ""))]))
  var repollLines = baseLines()
  repollLines[1] = makeRecordLine(2, kConfig, hObj(
    ("repoll_seconds", hInt(300)), ("session_date", hStr("2026-10-29"))))
  rejectRun("stream: a repeated ka10081 scope is REJECT even under a " &
            "declared re-poll cadence",
            "once per symbol per session",
            withInserts(repollLines, 6, @[
              (kRestResp, dailyAttemptRaw(okDailyBody("005930"))),
              (kRestResp, dailyAttemptRaw(okDailyBody("005530")))]))

  var msg = ""
  try:
    discard runOf("msg", withInserts(baseLines(), 6, @[(kRestResp, legacy)]))
  except RecordError as e:
    msg = e.msg
  check("rejection names the record and its seq",
        msg.startsWith("rest_resp at seq 7 is rejected"))
  check("rejection states the unverified wire boundary",
        "unverified" in msg)

block streamVerdict:
  let badLines = withInserts(baseLines(), 6, @[(kRestResp,
    attemptRaw(vendorErrBody(5, "조회 거부")))])
  let bv = verifyRun(writeStream("verdict-bad", badLines))
  check("verify classifies a failing rest_resp stream as REJECT exit 2",
        bv.verdict == vContract and exitCode(bv.verdict) == 2 and
        not bv.matched)
  check("verify prints VERDICT REJECT contract",
        verdictLine(bv) == "VERDICT REJECT contract")
  check("verify surfaces the rest_resp reason as an issue",
        bv.issues.len == 1 and "rest_resp" in bv.issues[0])

  let goodLines = withInserts(baseLines(), 6,
                              @[(kRestResp, upPage1), (kRestResp, upPage2)])
  let goodDir = writeStream("verdict-good", goodLines)
  let inPath = goodDir / inputFile
  discard writeRun(goodDir / "run", inPath, runCore(loadRecords(inPath)),
                   okInfo)
  let g = verifyRun(goodDir / "run", okInfo)
  check("a verified success rest_resp stream is MATCH provenance=OK",
        g.verdict == vMatch and g.matched and
        verdictLine(g) == "VERDICT MATCH provenance=OK")

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
