## Vendor-input contract tests for hs/vendor_input.
## Synthetic only: no fixtures, no network, no wall clock, no secrets.
## Run: nim c -r --path:src tests/test_vendor_input.nim
import std/[strutils]
import hs/[hcj, digest, vendor_input]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

proc checkNotRaises(name: string; body: proc ()) =
  var ok = true
  try:
    body()
  except CatchableError as e:
    ok = false
    echo "     unexpected ", e.name, ": ", e.msg
  check(name, ok)

proc raisesVendor(name: string; body: proc ()): string {.discardable.} =
  var hit = false
  var msg = ""
  try:
    body()
  except VendorInputError as e:
    hit = true
    msg = e.msg
  except CatchableError as e:
    echo "     wrong class ", e.name, ": ", e.msg
  check(name, hit)
  result = msg

proc raisesVendorAs(name: string; want: VendorFailure;
                    body: proc ()): string {.discardable.} =
  ## The failure must raise AND carry the exact VendorFailure class.
  var hit = true
  var msg = ""
  try:
    body()
    hit = false
  except VendorInputError as e:
    msg = e.msg
    if e.failure != want:
      echo "     wrong failure class ", e.failure, " (want ", want, "): ", e.msg
      hit = false
  except CatchableError as e:
    echo "     wrong class ", e.name, ": ", e.msg
    hit = false
  check(name, hit)
  result = msg

# ---------------------------------------------------------------- helpers

proc bts(s: string): seq[byte] = toBytes(s)

proc pg(body: string; contYn = "N"; nextKey = ""; status = 200;
        apiId = "ka10027"): RawHttpResp =
  httpResp(apiId, status, contYn, nextKey, bts(body))

proc rowMap(stkCd, curPrc, fluRt: string): string =
  "{\"stk_cls\":\"ST\",\"stk_cd\":\"" & stkCd & "\",\"stk_nm\":\"이름" & stkCd &
    "\",\"cur_prc\":\"" & curPrc & "\",\"pred_pre_sig\":\"2\"," &
    "\"pred_pre\":\"+100\",\"flu_rt\":\"" & fluRt & "\",\"sel_req\":\"10\"," &
    "\"buy_req\":\"20\",\"now_trde_qty\":\"30\",\"cntr_str\":\"150.00\"," &
    "\"cnt\":\"1\"}"

proc pageBody(rows: seq[string]): string =
  "{\"pred_pre_flu_rt_upper\":[" & rows.join(",") &
    "],\"return_code\":0,\"return_msg\":\"정상적으로 처리되었습니다\"}"

proc pageBodyNoRc(rows: seq[string]): string =
  ## A body that never affirms success: no return_code.
  "{\"pred_pre_flu_rt_upper\":[" & rows.join(",") & "]}"

proc kq(direction: Direction; stexTp = krxStexTp): Ka10027Query =
  initKa10027Query(direction, "000", "0000", "0", "0", "1", "0", "0", stexTp)

proc ch(direction: Direction; pages: seq[RawHttpResp]): PageChain =
  PageChain(query: kq(direction), pages: pages)

proc upDown(pagesUp, pagesDown: seq[RawHttpResp]): UpDownCandidates =
  upDownCandidates(ch(dirUp, pagesUp), ch(dirDown, pagesDown))

let fullRow =
  "{\"stk_cls\":\"ST\",\"stk_cd\":\"005930\",\"stk_nm\":\"삼성전자\"," &
  "\"cur_prc\":\"+1000\",\"pred_pre_sig\":\"2\",\"pred_pre\":\"+100\"," &
  "\"flu_rt\":\"+1.00\",\"sel_req\":\"10\",\"buy_req\":\"20\"," &
  "\"now_trde_qty\":\"30\",\"cntr_str\":\"150.00\",\"cnt\":\"1\"}"

let fullRowArr =
  "[\"ST\",\"005930\",\"삼성전자\",\"+1000\",\"2\",\"+100\"," &
  "\"+1.00\",\"10\",\"20\",\"30\",\"150.00\",\"1\"]"

let expectedEventCanonical =
  "{\"api_id\":\"ka10027\",\"buy_req\":\"20\",\"cnt\":\"1\"," &
  "\"cntr_str\":\"150.00\",\"cur_prc\":\"+1000\",\"flu_rt\":\"+1.00\"," &
  "\"now_trde_qty\":\"30\",\"page\":1,\"pred_pre\":\"+100\"," &
  "\"pred_pre_sig\":\"2\",\"row_index\":0,\"sel_req\":\"10\"," &
  "\"sort_tp\":\"1\",\"stk_cd\":\"005930\",\"stk_cls\":\"ST\"," &
  "\"stk_nm\":\"삼성전자\"}"

# ---------------------------------------------------------------- preservation

block preservationHttp:
  let src = "{\"a\":1}"
  let r = httpResp("ka10027", 200, "N", "", bts(src))
  check("http response body bytes are preserved verbatim", r.body == bts(src))
  check("http body byte view is byte-exact", bytesText(r.body) == src)
  check("http body hash matches digest.sha256Hex", sha256Hex(r) == sha256Hex(bts(src)))
  let blob = @[0'u8, 1, 2, 127, 128, 200, 255]
  let r2 = httpResp("ka10027", 500, "N", "", blob)
  check("arbitrary (non-UTF-8) body bytes are preserved", r2.body == blob)
  check("a failed response is still preserved verbatim",
        r2.status == 500 and sha256Hex(r2) == sha256Hex(blob))
  let empty = httpResp("ka10027", 200, "N", "", newSeq[byte](0))
  check("an empty body is preserved as zero bytes", empty.body.len == 0)

block preservationWs:
  let blob = @[0'u8, 16, 127, 128, 254, 255, 10, 13]
  let w = wsPayload("0B", blob)
  check("ws application payload bytes are preserved verbatim", w.payload == blob)
  check("ws payload hash is over the exact bytes", sha256Hex(w) == sha256Hex(blob))
  let w2 = wsPayload("0B", blob)
  check("identical payloads share the identity hash", sha256Hex(w2) == sha256Hex(w))
  check("ws channel label is kept", w.channel == "0B")
  raisesVendor("an empty channel label is rejected", proc () =
    discard wsPayload("", @[1'u8]))

# ---------------------------------------------------------------- secret guard

block secretGuard:
  check("authorization header is a secret offender",
        secretOffenders(@["authorization"]).len == 1)
  check("secret detection is case-insensitive",
        secretOffenders(@["Authorization", "CONTENT-TYPE"]) == @["Authorization"])
  check("appkey and secretkey are secret offenders",
        secretOffenders(@["appkey", "secretkey"]).len == 2)
  check("non-secret headers are clean",
        secretOffenders(@["api-id", "content-type", "cont-yn", "next-key"]).len == 0)
  raisesVendorAs("refuseSecretHeaders fails closed on a secret header", vfSecret,
                 proc () = refuseSecretHeaders(@["content-type", "appkey"]))
  checkNotRaises("refuseSecretHeaders accepts a clean header set", proc () =
    refuseSecretHeaders(@["api-id", "content-type"]))

# ---------------------------------------------------------------- raw validation

block httpRespValidation:
  checkNotRaises("cont-yn Y/N/absent are accepted", proc () =
    discard httpResp("ka10027", 200, "", "", "")
    discard httpResp("ka10027", 200, "Y", "K", "")
    discard httpResp("ka10027", 200, "N", "", ""))
  raisesVendor("lowercase cont-yn is rejected", proc () =
    discard httpResp("ka10027", 200, "y", "", ""))
  raisesVendor("garbage cont-yn is rejected", proc () =
    discard httpResp("ka10027", 200, "X", "", ""))
  raisesVendor("empty api-id is rejected", proc () =
    discard httpResp("", 200, "N", "", ""))
  raisesVendor("oversized api-id is rejected", proc () =
    discard httpResp("ka1002712345", 200, "N", "", ""))
  raisesVendor("oversized next-key is rejected (documented 50)", proc () =
    discard httpResp("ka10027", 200, "N", "k".repeat(51), ""))
  checkNotRaises("a 50-character next-key is accepted", proc () =
    discard httpResp("ka10027", 200, "N", "k".repeat(50), ""))
  raisesVendor("nonsense HTTP status is rejected", proc () =
    discard httpResp("ka10027", 42, "N", "", ""))
  checkNotRaises("an error status is preserved for evidence", proc () =
    discard httpResp("ka10027", 503, "N", "", "oops"))

# ---------------------------------------------------------------- query schema

block queryValidation:
  checkNotRaises("a documented query validates", proc () = discard kq(dirUp))
  raisesVendor("stex_tp 9 is rejected (undocumented)", proc () =
    discard kq(dirUp, "9"))
  checkNotRaises("stex_tp 2 validates at schema level (NXT)", proc () =
    discard kq(dirUp, "2"))
  raisesVendor("undocumented mrkt_tp is rejected", proc () =
    discard initKa10027Query(dirUp, "002", "0000", "0", "0", "1", "0", "0", "1"))
  raisesVendor("undocumented trde_qty_cnd is rejected", proc () =
    discard initKa10027Query(dirUp, "000", "0011", "0", "0", "1", "0", "0", "1"))
  raisesVendor("undocumented updown_incls is rejected", proc () =
    discard initKa10027Query(dirUp, "000", "0000", "0", "0", "2", "0", "0", "1"))
  raisesVendor("an empty required field is rejected", proc () =
    discard initKa10027Query(dirUp, "", "0000", "0", "0", "1", "0", "0", "1"))
  check("sort_tp of up is 1 (상승률)", sortTpOf(dirUp) == "1")
  check("sort_tp of down is 3 (하락률)", sortTpOf(dirDown) == "3")

# ---------------------------------------------------------------- request side

block requestBuilding:
  let body = ka10027RequestBody(kq(dirUp))
  check("request body canonical bytes are pinned", canonical(body) ==
    "{\"crd_cnd\":\"0\",\"mrkt_tp\":\"000\",\"pric_cnd\":\"0\"," &
    "\"sort_tp\":\"1\",\"stex_tp\":\"1\",\"stk_cnd\":\"0\"," &
    "\"trde_prica_cnd\":\"0\",\"trde_qty_cnd\":\"0000\"," &
    "\"updown_incls\":\"1\"}")
  check("request body carries exactly the nine documented fields",
        body.pairs.len == 9)
  check("request body has no authorization material",
        not body.has("authorization"))
  check("the down query carries sort_tp 3",
        canonical(ka10027RequestBody(kq(dirDown))).contains("\"sort_tp\":\"3\""))
  let p1 = pg("{}", "Y", "KEY1")
  check("continuation headers echo Y + next-key",
        continuationHeaders(p1) == ("Y", "KEY1"))
  check("a terminal page continues with N and no key",
        continuationHeaders(pg("{}", "N")) == ("N", ""))
  raisesVendor("cont-yn=Y without next-key cannot continue", proc () =
    discard continuationHeaders(pg("{}", "Y", "")))

# ---------------------------------------------------------------- normalization

block normalization:
  let upResp = pg(pageBody(@[fullRow]))
  let pinned = normalizeChain(ka10027Spec, ch(dirUp, @[upResp]))
  check("event canonical bytes are pinned", pinned[0].canonical == expectedEventCanonical)
  check("event canonical bytes are valid HCJ", parseLine(pinned[0].canonical).has("stk_cd"))
  check("events carry the raw body hash", pinned[0].sourceSha256 == sha256Hex(upResp))
  check("events label the api-id", pinned[0].label == "ka10027")

  let twoRows = pg(pageBody(@[rowMap("005930", "+1000", "+1.00"),
                               rowMap("000660", "+2000", "+2.00")]))
  let evs = normalizeChain(ka10027Spec, ch(dirUp, @[twoRows]))
  check("one page of two rows yields two events", evs.len == 2)
  check("row order is vendor order",
        parseLine(evs[0].canonical).get("stk_cd").asStr == "005930" and
        parseLine(evs[1].canonical).get("stk_cd").asStr == "000660")
  check("normalization is pure: a second run is byte-identical",
        normalizeChain(ka10027Spec, ch(dirUp, @[twoRows]))[0].canonical ==
        evs[0].canonical)

block positionalRows:
  let evMap = normalizeChain(ka10027Spec, ch(dirUp, @[pg(pageBody(@[fullRow]))]))
  let evArr = normalizeChain(ka10027Spec, ch(dirUp, @[pg(pageBody(@[fullRowArr]))]))
  check("object row and positional row normalize identically",
        evMap[0].canonical == expectedEventCanonical and
        evArr[0].canonical == expectedEventCanonical)

# ---------------------------------------------------------------- pagination

block pagination:
  let p1 = pg(pageBody(@[rowMap("005930", "+1000", "+1.00")]), "Y", "KEY1")
  let p2 = pg(pageBody(@[rowMap("000660", "+2000", "+2.00"),
                         rowMap("035420", "+3000", "+3.00")]))
  let evs = normalizeChain(ka10027Spec, ch(dirUp, @[p1, p2]))
  check("a Y->N two-page chain yields rows from both pages", evs.len == 3)
  check("events record the page number",
        parseLine(evs[0].canonical).get("page").asInt == 1 and
        parseLine(evs[2].canonical).get("page").asInt == 2)
  checkNotRaises("the cap does not reject a chain inside it", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[p1, p2]), 2))
  let badY = pg(pageBody(@[rowMap("005930", "+1000", "+1.00")]), "Y", "")
  raisesVendor("a middle page with Y but no next-key rejects the chain", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[badY, p2])))
  raisesVendor("a terminal page followed by more pages rejects the chain", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[p2, p1])))
  let mi = raisesVendorAs(
    "cont-yn=Y below the cap is classified incomplete (a page is missing)",
    vfIncomplete, proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[p1])))
  check("the incomplete message names the missing page", mi.contains("missing"))
  raisesVendorAs("an empty page chain is classified incomplete", vfIncomplete,
                 proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[])))
  raisesVendorAs("exceeding the declared cap is a contract violation",
                 vfContract, proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[p1, p2]), 1))
  let p2y = pg(pageBody(@[rowMap("000660", "+2000", "+2.00")]), "Y", "KEY2")
  let mt = raisesVendorAs(
    "reaching the cap while cont-yn=Y is classified truncated, never success",
    vfTruncated, proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[p1, p2y]), 2))
  check("the truncated message says the subset is truncated",
        mt.contains("truncated"))
  raisesVendorAs("truncated (at the cap) is distinct from incomplete (below)",
                 vfTruncated, proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(pageBody(@[]), "Y", "K")]), 1))
  checkNotRaises(
    "truncatedOk consumes the cap-closed chain as a declared subset", proc () =
      let evs = normalizeChain(ka10027Spec, ch(dirUp, @[p1, p2y]), 2,
                               truncatedOk = true)
      doAssert evs.len == 2)
  raisesVendorAs(
    "truncatedOk never waives a below-cap missing continuation page",
    vfIncomplete, proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[p1]), 2,
                             truncatedOk = true))
  raisesVendor("a page cap below 1 is rejected", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[p2]), 0))

# ------------------------------------------------------ repeat/cap subset rule

block subsetSemantics:
  check("ka10027 is declared paginated", ka10027Spec.paginated)
  check("the explicit paginated subset is exactly ka10027 and ka10080",
        paginatedTrs.len == 2 and paginatedTrs[0] == "ka10027" and
        paginatedTrs[1] == "ka10080")
  let nonPaginated = TrSpec(apiId: "ka10027", path: ka10027Path,
                            paginated: false, listKey: ka10027ListKey,
                            rowFields: @ka10027RowFields)
  checkNotRaises("a single N page normalizes under a non-paginated spec", proc () =
    discard normalizeChain(nonPaginated, ch(dirUp, @[pg(pageBody(@[]))])))
  raisesVendor("a non-paginated TR rejects cont-yn=Y", proc () =
    discard normalizeChain(nonPaginated, ch(dirUp, @[pg(pageBody(@[]), "Y", "K")])))
  raisesVendor("a non-paginated TR rejects a second page", proc () =
    discard normalizeChain(nonPaginated,
                           ch(dirUp, @[pg(pageBody(@[])), pg(pageBody(@[]))])))

# ---------------------------------------------------------------- fail-closed

block failClosedResponses:
  let one = @[rowMap("005930", "+1000", "+1.00")]
  raisesVendorAs("HTTP 404 is classified transport and rejects the page",
                 vfTransport, proc () =
    discard normalizeChain(ka10027Spec,
                           ch(dirUp, @[pg(pageBody(one), status = 404)])))
  let m = raisesVendorAs(
    "a vendor business error (return_code 1511) is classified vendor error",
    vfVendorError, proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
        "{\"pred_pre_flu_rt_upper\":[],\"return_code\":1511," &
        "\"return_msg\":\"필수 파라미터 누락\"}")])))
  check("the business error message names return_code", m.contains("1511"))
  raisesVendor("a non-integer return_code rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg("{\"return_code\":\"0\"}")])))
  raisesVendor("a non-JSON body rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg("not json")])))
  raisesVendor("an empty body rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg("")])))
  raisesVendor("a non-object body rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg("[1]")])))
  let mlk = raisesVendorAs(
    "return_code 0 without the list key is rejected (absence is not empty)",
    vfContract, proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[pg("{\"return_code\":0}")])))
  check("the missing list key message names the list key",
        mlk.contains(ka10027ListKey))
  let mlkMsg = raisesVendorAs(
    "return_code 0 with return_msg but no list key is rejected",
    vfContract, proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
        "{\"return_code\":0,\"return_msg\":\"정상적으로 처리되었습니다\"}")])))
  check("the missing list key message names return_code 0 context",
        mlkMsg.contains("return_code"))
  checkNotRaises(
    "return_code 0 with an explicit empty array is empty success", proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
        "{\"pred_pre_flu_rt_upper\":[],\"return_code\":0}")])))
  let mrc = raisesVendorAs(
    "HTTP 200 without return_code is rejected (not confirmed success)",
    vfVendorError, proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(pageBodyNoRc(@[]))])))
  check("the missing return_code message names return_code",
        mrc.contains("return_code"))
  raisesVendorAs(
    "HTTP 200 with rows but no return_code is rejected (fail-closed)",
    vfVendorError, proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
        pageBodyNoRc(@[rowMap("005930", "+1000", "+1.00")]))])))
  raisesVendorAs(
    "an error-shaped body (return_msg, no return_code) is rejected",
    vfVendorError, proc () =
      discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
        "{\"return_msg\":\"필수 파라미터 누락\"}")])))
  raisesVendor("an api-id that does not match the spec rejects the page", proc () =
    discard normalizeChain(ka10027Spec,
                           ch(dirUp, @[pg(pageBody(one), apiId = "ka10030")])))
  raisesVendor("a response key outside the schema rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
      "{\"pred_pre_flu_rt_upper\":[],\"extra\":1}")])) )
  raisesVendor("a row that is a string rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
      "{\"pred_pre_flu_rt_upper\":[\"x\"]}")])))
  raisesVendor("a positional row of the wrong length rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
      "{\"pred_pre_flu_rt_upper\":[[\"ST\",\"005930\"]]}")])))
  raisesVendor("a positional row with a non-string element rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
      "{\"pred_pre_flu_rt_upper\":[[\"ST\",1]]}")])))
  raisesVendor("a row field outside the documented schema rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
      "{\"pred_pre_flu_rt_upper\":[{\"stk_cd\":\"005930\",\"oops\":\"1\"}]}")])))
  raisesVendor("a non-string row field rejects the page", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
      "{\"pred_pre_flu_rt_upper\":[{\"stk_cd\":1}]}")])))
  checkNotRaises("a row object may omit optional documented fields", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
      "{\"pred_pre_flu_rt_upper\":[{\"stk_cd\":\"005930\"}],\"return_code\":0}")])))
  raisesVendor("a float literal in the body rejects the page (HCJ domain)", proc () =
    discard normalizeChain(ka10027Spec, ch(dirUp, @[pg(
      "{\"pred_pre_flu_rt_upper\":[],\"return_code\":0.5}")])))

# ---------------------------------------------------------------- candidates

block candidates:
  let upP = pg(pageBody(@[rowMap("005930", "+1000", "+1.00"),
                          rowMap("000660", "+2000", "+2.00")]))
  let downP = pg(pageBody(@[rowMap("035420", "-3000", "-3.00")]))
  let c = upDown(@[upP], @[downP])
  check("up candidates keep vendor order", c.up == @["005930", "000660"])
  check("down candidates keep vendor order", c.down == @["035420"])
  check("names: every row's stk_nm is preserved (up leg first, first " &
        "appearance wins)",
        c.names == @[(code: "005930", name: "이름005930"),
                     (code: "000660", name: "이름000660"),
                     (code: "035420", name: "이름035420")])
  check("names: the lookup falls back to empty on a nameless row, never " &
        "to a re-parse",
        nameOf(c.names, "035420") == "이름035420" and
        nameOf(c.names, "999999") == "")
  let namedDown = upDown(@[pg(pageBody(@[rowMap("005930", "+1000", "+1.00")]))],
                         @[pg(pageBody(@[
                           rowMap("005930", "-1000", "-1.00"),
                           rowMap("035420", "-3000", "-3.00")]))])
  check("names: a code seen on the up leg keeps its first name (the down " &
        "leg never rewrites it)",
        namedDown.names == @[(code: "005930", name: "이름005930"),
                             (code: "035420", name: "이름035420")])
  let nameless = upDown(@[pg("{\"pred_pre_flu_rt_upper\":[{\"stk_cd\":" &
                            "\"005930\",\"cur_prc\":\"+1000\"}]," &
                            "\"return_code\":0}")],
                        @[pg(pageBody(@[]))])
  check("names: a row without stk_nm is collected nowhere (a nameless " &
        "row is not a failure — the consumer falls back to the symbol)",
        nameless.up == @["005930"] and nameless.names.len == 0)
  let p1u = pg(pageBody(@[rowMap("005930", "+1000", "+1.00")]), "Y", "KEY1")
  let p2u = pg(pageBody(@[rowMap("000660", "+2000", "+2.00")]))
  let c2 = upDown(@[p1u, p2u], @[downP])
  check("candidates span repeated pages in order", c2.up == @["005930", "000660"])
  let empty = upDown(@[pg(pageBody(@[]))], @[pg(pageBody(@[]))])
  check("empty rank lists are a valid answer, not a failure",
        empty.up.len == 0 and empty.down.len == 0)
  raisesVendorAs(
    "a success body without the list key rejects the candidates (not empty)",
    vfContract, proc () =
      discard upDown(@[pg("{\"return_code\":0}")], @[downP]))
  let dup = upDown(@[pg(pageBody(@[rowMap("005930", "+1", "+1.00"),
                                   rowMap("005930", "+2", "+2.00")]))],
                   @[downP])
  check("duplicate symbols are preserved (lossless, no dedup)",
        dup.up == @["005930", "005930"])
  raisesVendor("a non-KRX stex_tp query rejects the candidates (KRX-only)", proc () =
    discard upDownCandidates(ch(dirUp, @[upP]),
                             PageChain(query: kq(dirDown, "2"), pages: @[downP])))
  raisesVendor("a swapped direction rejects the candidates", proc () =
    discard upDownCandidates(ch(dirDown, @[downP]), ch(dirUp, @[upP])))
  raisesVendor("a row without stk_cd rejects the candidates", proc () =
    discard upDown(@[pg("{\"pred_pre_flu_rt_upper\":[{\"stk_nm\":\"x\"}]," &
                       "\"return_code\":0}")],
                   @[downP]))
  raisesVendor("a failed up page rejects the whole candidate set", proc () =
    discard upDown(@[pg(pageBody(@[]), status = 500)], @[downP]))
  raisesVendor("a failed down page rejects the whole candidate set", proc () =
    discard upDown(@[upP], @[pg(pageBody(@[]), status = 500)]))
  raisesVendorAs("an up chain ending cont-yn=Y rejects the candidates",
                 vfIncomplete, proc () =
    discard upDown(@[p1u], @[downP]))
  raisesVendorAs("a truncated up chain rejects the candidates", vfTruncated,
                 proc () =
    discard upDownCandidates(ch(dirUp, @[p1u, pg(pageBody(@[]), "Y", "K")]),
                             ch(dirDown, @[downP]), 2))
  checkNotRaises(
    "upTruncated consumes a cap-closed up leg as a declared subset", proc () =
      let ct = upDownCandidates(ch(dirUp, @[p1u, pg(pageBody(@[]), "Y", "K")]),
                                ch(dirDown, @[downP]), 2, upTruncated = true)
      doAssert ct.up == @["005930"] and ct.down == @["035420"])
  raisesVendorAs(
    "upTruncated never waives a below-cap missing continuation page",
    vfIncomplete, proc () =
      discard upDownCandidates(ch(dirUp, @[p1u]), ch(dirDown, @[downP]), 2,
                               upTruncated = true))
  raisesVendorAs(
    "truncatedOk never waives a failed page (only the cap rule)", vfTransport,
    proc () =
      discard upDownCandidates(ch(dirUp, @[pg(pageBody(@[]), "Y", "K", 500)]),
                               ch(dirDown, @[downP]), 1, upTruncated = true))

block candidateScope:
  ## The 2026-11-09 demo capture incident: the ka10027 ranking mixes rows
  ## whose stk_cd is not the 6-digit candidate shape (ELW "18064K" and
  ## mock alphanumeric codes at the TOP of the up ranking, so they enter
  ## any top-N selection). The official request enum documents no ELW
  ## exclusion and no stk_cls value table, so the code shape itself is
  ## the declared universe boundary: partitioned out, never a candidate,
  ## never a failure, preserved in the raw bytes.
  check("scope: exactly 6 digits is the candidate code shape",
        isCandidateCode("005930") and not isCandidateCode("18064K") and
        not isCandidateCode("0147B0") and not isCandidateCode("12345") and
        not isCandidateCode("1234567") and not isCandidateCode(""))
  let upP = pg(pageBody(@[rowMap("18064K", "+6760", "+29.90"),
                          rowMap("005930", "+1000", "+29.88"),
                          rowMap("0147B0", "+642", "+29.86"),
                          rowMap("000660", "+2000", "+29.84")]))
  let downP = pg(pageBody(@[rowMap("035420", "-3000", "-3.00"),
                            rowMap("0088M0", "-500", "-2.90")]))
  let c = upDown(@[upP], @[downP])
  check("scope: only candidate-shaped codes are candidates, in vendor order",
        c.up == @["005930", "000660"] and c.down == @["035420"])
  check("scope: out-of-shape codes are excluded per leg in vendor order",
        c.upExcluded == @["18064K", "0147B0"] and
        c.downExcluded == @["0088M0"])
  let c2 = upDown(@[upP], @[downP])
  check("scope: deterministic — the same pages partition identically",
        c.up == c2.up and c.upExcluded == c2.upExcluded and
        c.down == c2.down and c.downExcluded == c2.downExcluded)
  let dup = upDown(@[pg(pageBody(@[rowMap("005930", "+1", "+1.00"),
                                   rowMap("18064K", "+2", "+2.00"),
                                   rowMap("005930", "+3", "+3.00")]))],
                   @[downP])
  check("scope: lossless per class — kept duplicates stay kept, the " &
        "out-of-shape row stays excluded",
        dup.up == @["005930", "005930"] and dup.upExcluded == @["18064K"])

# ---------------------------------------------------------------- ws identity

block wsIdentity:
  let evs = wsEvents(@[wsPayload("0B", @[1'u8, 2, 3, 255, 0]),
                       wsPayload("0D", @[9'u8])])
  check("ws events are identity-normalized",
        evs[0].kind == evWsPayload and evs[0].payload == @[1'u8, 2, 3, 255, 0])
  check("ws events carry no canonical text", evs[0].canonical == "")
  check("ws event label is the channel", evs[1].label == "0D")
  check("ws event hash covers the exact payload bytes",
        evs[0].sourceSha256 == sha256Hex(@[1'u8, 2, 3, 255, 0]))
  check("binary (non-UTF-8) payloads are never parsed", evs[0].payload.len == 5)

# ------------------------------------------------------- recompute-verification

block verifyRoundTrip:
  let p1u = pg(pageBody(@[rowMap("005930", "+1000", "+1.00")]), "Y", "KEY1")
  let p2u = pg(pageBody(@[rowMap("000660", "+2000", "+2.00")]))
  let downP = pg(pageBody(@[rowMap("035420", "-3000", "-3.00")]))
  var cap = initVendorCapture()
  cap.chains.add(ch(dirUp, @[p1u, p2u]))
  cap.chains.add(ch(dirDown, @[downP]))
  cap.wsPayloads.add(wsPayload("0B", @[1'u8, 2, 255]))
  cap.wsPayloads.add(wsPayload("0B", @[7'u8]))
  let stored = normalizeEvents(cap)
  check("the capture yields rest and ws events in order",
        stored.len == 5 and stored[0].kind == evRestRow and
        stored[3].kind == evWsPayload and stored[4].kind == evWsPayload)
  check("recomputation verifies the stored events",
        verifyEvents(cap, stored).len == 0)
  let again = normalizeEvents(cap)
  var agree = again.len == stored.len
  for i in 0 ..< again.len:
    if not sameEvent(again[i], stored[i]):
      agree = false
  check("normalization is pure: two runs agree byte-for-byte", agree)

  var tampered = stored
  tampered[1].canonical = stored[1].canonical.replace("000660", "000661")
  check("a tampered canonical byte is rejected",
        verifyEvents(cap, tampered).len > 0)
  var tamperedSha = stored
  tamperedSha[0].sourceSha256 = "0".repeat(64)
  check("a tampered source hash is rejected",
        verifyEvents(cap, tamperedSha).len > 0)
  var dropped = stored
  dropped.setLen(4)
  check("a missing stored event is rejected",
        verifyEvents(cap, dropped).len > 0)
  var dupd = stored
  dupd.add(stored[0])
  check("an extra stored event is rejected",
        verifyEvents(cap, dupd).len > 0)
  var swapped = stored
  let tmpEv = swapped[0]
  swapped[0] = swapped[1]
  swapped[1] = tmpEv
  check("reordered stored events are rejected",
        verifyEvents(cap, swapped).len > 0)
  var tamperedWs = stored
  tamperedWs[4].payload = @[1'u8, 2, 254]
  check("a tampered ws payload byte is rejected",
        verifyEvents(cap, tamperedWs).len > 0)

  var cap2 = initVendorCapture()
  cap2.chains.add(ch(dirUp, @[p1u, pg(pageBody(@[rowMap("000660", "+9999", "+2.00")]))]))
  cap2.chains.add(ch(dirDown, @[downP]))
  cap2.wsPayloads.add(wsPayload("0B", @[1'u8, 2, 255]))
  cap2.wsPayloads.add(wsPayload("0B", @[7'u8]))
  check("a diverging raw capture is rejected against the stored events",
        verifyEvents(cap2, stored).len > 0)

  var capBad = initVendorCapture()
  capBad.chains.add(ch(dirUp, @[pg(pageBody(@[]), status = 500)]))
  let issues = verifyEvents(capBad, @[])
  check("a capture that cannot be recomputed is rejected, never accepted",
        issues.len > 0 and issues[0].contains("recomputation rejected"))
  var capNoRc = initVendorCapture()
  capNoRc.chains.add(ch(dirUp, @[pg(pageBodyNoRc(@[]))]))
  let noRcIssues = verifyEvents(capNoRc, @[])
  check("a missing return_code makes verification reject the capture",
        noRcIssues.len > 0 and noRcIssues[0].contains("return_code"))
  var capNoList = initVendorCapture()
  capNoList.chains.add(ch(dirUp, @[pg("{\"return_code\":0}")]))
  let noListIssues = verifyEvents(capNoList, @[])
  check("a missing list key makes verification reject the capture",
        noListIssues.len > 0 and noListIssues[0].contains(ka10027ListKey))

block eventEquality:
  let e1 = normalizeChain(ka10027Spec, ch(dirUp, @[pg(pageBody(@[fullRow]))]))[0]
  let e2 = normalizeChain(ka10027Spec, ch(dirUp, @[pg(pageBody(@[fullRow]))]))[0]
  check("identical events compare equal", sameEvent(e1, e2))
  var e3 = e2
  e3.canonical = e2.canonical & " "
  check("a one-byte canonical difference breaks equality", not sameEvent(e1, e3))
  var e4 = e2
  e4.label = "ka10030"
  check("a label difference breaks equality", not sameEvent(e1, e4))
  var e5 = e2
  e5.kind = evWsPayload
  check("a kind difference breaks equality", not sameEvent(e1, e5))
  let w1 = wsEvents(@[wsPayload("0B", @[1'u8, 2])])[0]
  let w2 = wsEvents(@[wsPayload("0B", @[1'u8, 2])])[0]
  check("identical ws events compare equal", sameEvent(w1, w2))
  var w3 = w2
  w3.payload = @[1'u8, 3]
  check("a payload byte difference breaks equality", not sameEvent(w1, w3))

echo ""
echo passes, " passed, ", failures, " failed"
if failures > 0: quit(1)
