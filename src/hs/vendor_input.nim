## Vendor input: lossless preservation, schema-derived normalization and
## recompute-verification of Kiwoom REST pages and WebSocket payloads.
##
## Cross-checked 2026-10-29 against the official Kiwoom REST specification
## (Kiwoom-Securities/Kiwoom-REST-API, main: kiwoom/_data/kiwoom_api_spec.json
## and examples/국내주식/순위정보/get_domestic_prev_day_change_rate_top.py) and
## the committed local extracts fixtures/kiwoom-doc/ka10080.txt,
## ka11080.txt. Schema facts used here, all from those sources:
##
##   ka10027 전일대비등락률상위요청 — POST /api/dostk/rkinfo, JSON,
##   Content-Type application/json;charset=UTF-8.
##   request body (all String, required): mrkt_tp, sort_tp, trde_qty_cnd,
##     stk_cnd, crd_cnd, updown_incls, pric_cnd, trde_prica_cnd, stex_tp.
##     sort_tp 1:상승률 3:하락률; stex_tp 1:KRX 2:NXT 3:통합.
##   response body: pred_pre_flu_rt_upper (LIST) of rows with 12 String
##     fields (stk_cls stk_cd stk_nm cur_prc pred_pre_sig pred_pre flu_rt
##     sel_req buy_req now_trde_qty cntr_str cnt); documented examples add
##     return_code (int, 0 = ok) and return_msg (string).
##   ka10080 주식분봉차트조회 — POST /api/dostk/chart, JSON (official
##   document, 2026-11-06 collection). Request body (String): stk_cd
##   (required), tic_scope (required; "1:1분, 3:3분, 5, 10, 15, 30, 45,
##   60" — this implementation pins "3", the declared 3-minute scope),
##   upd_stkpc_tp (required; 0 or 1), base_dt (OPTIONAL, YYYYMMDD).
##   Continuation is the same cont-yn/next-key header pair (all pages,
##   until cont_yn != "Y"). Response body: stk_min_pole_chart_qry (LIST)
##   of rows with 9 String fields (cur_prc trde_qty cntr_tm open_pric
##   high_pric low_pric pred_pre pred_pre_sig acc_trde_qty); cur_prc is
##   부호가 포함된 숫자 (원), cntr_tm is 체결시간 YYYYMMDDHHmmss. The
##   mock domain is https://mockapi.kiwoom.com (KRX only).
##   ka10081 주식일봉차트조회요청 — POST /api/dostk/chart (same path as
##   ka10080), JSON. MEASURED on the mock server 2026-11-10 (agent-59
##   capture preserved at /tmp/hs-ka10081/): ka10081 is NOT in the official
##   spec JSON — every shape below is mock-measured, real environment
##   UNVERIFIED. Request body (String, all three REQUIRED — the vendor
##   answers a missing field with HTTP 200 + return_code 2): stk_cd,
##   base_dt (YYYYMMDD; current or past dates), upd_stkpc_tp (0 or 1; both
##   measured accepted — the 0/1 value difference itself is UNMEASURED,
##   mock upd_rt is 0.00 in both modes). Response body: return_code,
##   return_msg, stk_cd (echo of the request) and stk_dt_pole_chart_qry
##   (LIST) of rows with 12 String fields (cur_prc trde_qty trde_prica dt
##   open_pric high_pric low_pric pred_pre pred_pre_sig trde_tern_rt
##   upd_stkpc_tp upd_rt); dt is YYYYMMDD, rows newest-first (the first
##   row is the base_dt day's in-progress bar), 600 rows per page, and
##   the page legitimately carries cont-yn=Y + next-key (the vendor offers
##   continuation) — but the recent-20+-completed-trading-days need is
##   inside one page, so the declared capture scope never continues.
##   cur_prc (close) is UNSIGNED here, unlike ka10027's signed cur_prc:
##   per-TR sign conventions differ. Rate limit: TR 1/s — a sub-1 s
##   repeat draws HTTP 429 (body return_code 5), recovers after 1 s, and
##   1.5 s pacing measured zero hits.
##   business errors arrive as HTTP 200 with return_code != 0; the official
##     example also tolerates an absent return_code (a client-side choice).
##   continuation: response headers cont-yn ("Y" while more data) + next-key;
##     the official example repeats pages while cont-yn == "Y", bounded by
##     MAX_PAGES = 10.
##   row encoding: the official example accepts both object rows and
##     positional array rows in the documented field order.
##
## Contract of this module:
##   - PRESERVE: RawHttpResp.body and RawWsPayload.payload keep the original
##     bytes (HTTP response body; WS application payload after TLS and frame
##     reassembly — never frames, never TLS records). Nothing decodes or
##     re-encodes bytes on the preservation path.
##   - NO SECRETS: no type here can carry authorization/appkey/secretkey or
##     login material, and refuseSecretHeaders fails closed on an attempt.
##     Authentication belongs to the (unwritten) transport adapter.
##   - NORMALIZE: pure functions turn preserved bytes into events. Every
##     response/page failure rejects the whole result; a partial candidate
##     list is never returned. Failures carry a VendorFailure class:
##     vfSecret, vfContract (malformed input / derived-schema violation),
##     vfTransport (non-200 status), vfVendorError (the response did not
##     affirm success), vfIncomplete (a declared continuation page is
##     missing), vfTruncated (the declared subset is truncated at the cap).
##   - AFFIRM SUCCESS: a page is usable only when its body affirms success:
##     return_code present, integer, 0. A missing return_code is
##     vfVendorError. Kiwoom business errors arrive as HTTP 200, and the
##     official client library's tolerance of an absent code is a client
##     choice, not an independently confirmed production guarantee — an
##     unconfirmed state is never mapped to success here.
##   - LIST KEY: a success body must carry the list key. The official
##     specification documents pred_pre_flu_rt_upper but nowhere guarantees
##     that an absent key means an empty list, so absence is vfContract; an
##     explicit empty array is a confirmed empty answer and succeeds.
##   - INCOMPLETE vs TRUNCATED: a chain that ends with cont-yn=Y below the
##     declared cap is vfIncomplete (a continuation page is missing from the
##     capture); a chain that reaches the cap while cont-yn=Y is vfTruncated
##     (the declared candidate subset did not cover the vendor's
##     continuation). Both are rejected: "truncated" is a classification the
##     acceptance contract may consume, never a success. The consumption is
##     explicit and caller-owned: truncatedOk/upTruncated/downTruncated
##     declare that the caller owns the truncation fact (the collector's gap
##     record and the REST_TRUNCATED event) and consumes the chain as a
##     declared truncated subset -- the fetched pages are still fully
##     validated, and below-cap cont-yn=Y is never consumable (no caller can
##     declare a missing continuation page away).
##   - VERIFY: verifyEvents recomputes the events from the raw capture and
##     compares them byte- and value-wise with the stored events; any
##     difference is an issue and the caller must reject.
##   - REPEAT/CAP SUBSET: page repetition and the page cap are properties of
##     TRs explicitly declared paginated (paginatedTrs — ka10027 and ka10080),
##     not of vendor input in general.
##   - CANDIDATES: up = sort_tp "1", down = sort_tp "3", stex_tp "1" (KRX).
##     The candidate universe is further bounded by the code shape
##     (isCandidateCode: exactly 6 digits): the ranking mixes in rows whose
##     stk_cd is not that shape (ELW/ETF/ETN-style alphanumeric codes — the
##     official request enum documents no ELW exclusion and no stk_cls
##     value table, checked 2026-11-09), and those rows are partitioned
##     into the excluded lists, never into candidates and never into a
##     failure.
##
## Unverified by a live capture (G2/G4): actual response values, present vs
## absent optional row fields, row field max lengths (not enforced), the sign
## convention of 부호가 포함된 숫자 fields (values stay strings, never
## interpreted numerically), page sizes, and whether production ever omits
## return_code on a success (until that is independently confirmed, omission
## is a failure, per the fail-closed requirement). return_msg is preserved in
## the raw bytes but never parsed for a decision. For ka10080 specifically:
## whether cntr_tm denotes the bar interval's start or its end is not stated
## by the official document (UNVERIFIED) — the raw cntr_tm string is
## preserved verbatim in the response bytes and no re-encoded copy is ever
## recorded; the derived bar's interval placement is a declared scanner-side
## interpretation documented in backfill.nim, to be resolved by a measured
## demo capture. Tests are synthetic only (M10).
import std/[strutils, options]
import hcj, digest

type
  VendorFailure* = enum
    ## Why vendor input was rejected. Every value is a failure: an
    ## unconfirmed state is never mapped to success.
    vfSecret        ## secret material attempted to enter this layer
    vfContract      ## malformed input or a violation of the derived schema
    vfTransport     ## non-200 HTTP transport status
    vfVendorError   ## the response did not affirm success (return_code)
    vfIncomplete    ## a declared continuation page is missing from the capture
    vfTruncated     ## the declared subset is truncated at the page cap

  VendorInputError* = object of CatchableError
    failure*: VendorFailure

  RawHttpResp* = object
    ## One vendor REST response, preserved verbatim. No field can carry an
    ## authorization header or any other secret: those never enter this layer.
    apiId*: string     ## response api-id header (non-secret)
    status*: int       ## HTTP status, supplied by the transport adapter
    contYn*: string    ## response cont-yn header: "Y", "N" or absent ("")
    nextKey*: string   ## response next-key header (non-secret, <= 50 chars)
    body*: seq[byte]   ## exact response body bytes

  RawWsPayload* = object
    ## One vendor WebSocket application message, preserved verbatim: payload
    ## bytes after TLS decryption and frame reassembly — never frames, never
    ## TLS records. The vendor payload schema is unverified (U1), so
    ## normalization is identity: the bytes are the event.
    channel*: string   ## non-secret channel label, e.g. "0B"
    payload*: seq[byte]

  TrSpec* = object
    ## Vendor TR schema derived from the official specification; only the
    ## cross-checked parts are encoded, nothing is guessed.
    apiId*: string
    path*: string
    paginated*: bool         ## explicit subset: only these TRs repeat pages
    listKey*: string         ## response body key holding the row list
    rowFields*: seq[string]  ## documented row fields, documented order
    extraBodyKeys*: seq[string]  ## measured non-generic top-level body keys
                                 ## (e.g. ka10081's stk_cd echo); the generic
                                 ## three (list key, return_code, return_msg)
                                 ## are always allowed, everything else stays
                                 ## a schema failure

  Direction* = enum
    dirUp    ## sort_tp "1" (상승률)
    dirDown  ## sort_tp "3" (하락률)

  Ka10027Query* = object
    direction*: Direction
    mrktTp*: string
    trdeQtyCnd*: string
    stkCnd*: string
    crdCnd*: string
    updownIncls*: string
    pricCnd*: string
    trdePricaCnd*: string
    stexTp*: string

  Ka10080Query* = object
    ## The declared request scope of one ka10080 chart query: one symbol's
    ## 3-minute bars. tic_scope is pinned to the declared 3-minute scope
    ## ("3") by the acceptance path; base_dt is the documented OPTIONAL
    ## request field ("" = absent).
    stkCd*: string
    ticScope*: string
    updStkpcTp*: string
    baseDt*: string

  Ka10081Query* = object
    ## The declared request scope of one ka10081 daily chart query: one
    ## symbol's daily bars, one page. All three fields are REQUIRED by the
    ## measured vendor contract (unlike ka10080's optional base_dt); the
    ## acceptance path pins upd_stkpc_tp to the declared capture scope.
    stkCd*: string
    baseDt*: string
    updStkpcTp*: string

  PageChain* = object
    ## Ordered pages answering one ka10027 query. Physical order is the
    ## authority; the cont-yn chain is validated, never trusted.
    query*: Ka10027Query
    pages*: seq[RawHttpResp]

  Ka10080Chain* = object
    ## Ordered pages answering one ka10080 query. Same authority rule as
    ## PageChain: physical order, validated cont-yn, never trusted.
    query*: Ka10080Query
    pages*: seq[RawHttpResp]

  EventKind* = enum
    evRestRow    ## normalized ka10027 row (canonical HCJ bytes)
    evWsPayload  ## WS application payload (identity normalization)

  VendorEvent* = object
    ## A normalized event, recomputable from the raw capture. Verification
    ## compares stored events against a recomputation byte- and value-wise.
    kind*: EventKind
    label*: string          ## api-id (REST) or channel (WS)
    sourceSha256*: string   ## sha256 over the raw bytes this event came from
    canonical*: string      ## canonical HCJ event bytes (evRestRow only)
    payload*: seq[byte]     ## exact payload bytes (evWsPayload only)

  VendorCapture* = object
    ## Everything the recorder must preserve: page chains plus WS payloads.
    spec*: TrSpec
    chains*: seq[PageChain]
    wsPayloads*: seq[RawWsPayload]

  UpDownCandidates* = object
    ## The candidate universe of one completed up+down query pair. The
    ## in-scope lists (up/down) carry only candidate-shaped codes; rows
    ## whose stk_cd is not that shape (ELW/ETF/ETN-style alphanumeric
    ## codes) are out of the universe and land in the excluded lists in
    ## vendor order — preserved in the raw evidence, never judged.
    up*: seq[string]    ## in-scope stk_cd in vendor order, sort_tp "1"
    down*: seq[string]  ## in-scope stk_cd in vendor order, sort_tp "3"
    upExcluded*: seq[string]   ## out-of-scope stk_cd in vendor order, up leg
    downExcluded*: seq[string] ## out-of-scope stk_cd in vendor order, down leg

const
  ka10027ApiId* = "ka10027"
  ka10027Path* = "/api/dostk/rkinfo"
  ka10027ListKey* = "pred_pre_flu_rt_upper"
  ka10027RowFields* = [
    "stk_cls", "stk_cd", "stk_nm", "cur_prc", "pred_pre_sig", "pred_pre",
    "flu_rt", "sel_req", "buy_req", "now_trde_qty", "cntr_str", "cnt"]

  ka10080ApiId* = "ka10080"
  ka10080Path* = "/api/dostk/chart"
  ka10080ListKey* = "stk_min_pole_chart_qry"
  ka10080RowFields* = [
    "cur_prc", "trde_qty", "cntr_tm", "open_pric", "high_pric", "low_pric",
    "pred_pre", "pred_pre_sig", "acc_trde_qty"]

  ka10081ApiId* = "ka10081"
  ka10081Path* = "/api/dostk/chart"
  ka10081ListKey* = "stk_dt_pole_chart_qry"
  ka10081RowFields* = [
    "cur_prc", "trde_qty", "trde_prica", "dt", "open_pric", "high_pric",
    "low_pric", "pred_pre", "pred_pre_sig", "trde_tern_rt", "upd_stkpc_tp",
    "upd_rt"]

  ## Request enums, verbatim from the official ka10080 field descriptions.
  ka10080TicScopeValues* = ["1", "3", "5", "10", "15", "30", "45", "60"]
  ka10080UpdStkpcTpValues* = ["0", "1"]

  ## Request enum, measured on the mock server 2026-11-10
  ## (/tmp/hs-ka10081/): both ka10081 upd_stkpc_tp values are accepted.
  ka10081UpdStkpcTpValues* = ["0", "1"]

  ## Measured response echo keys: a ka10081 success body repeats the
  ## requested stk_cd at the top level (ka10080/ka10027 bodies carry no
  ## such key). Declared per spec so the generic body-key check accepts
  ## exactly what the measured vendor emits.
  ka10081BodyEchoKeys* = ["stk_cd"]

  ## Request enums, verbatim from the official ka10027 field descriptions.
  ka10027MrktTpValues* = ["000", "001", "101"]
  ka10027SortTpValues* = ["1", "2", "3", "4", "5"]
  ka10027TrdeQtyCndValues* = [
    "0000", "0010", "0050", "0100", "0150", "0200", "0300", "0500", "1000"]
  ka10027StkCndValues* = [
    "0", "1", "3", "4", "5", "6", "7", "8", "9", "11", "12", "13", "14",
    "15", "16"]
  ka10027CrdCndValues* = ["0", "1", "2", "3", "4", "7", "9"]
  ka10027UpdownInclsValues* = ["0", "1"]
  ka10027PricCndValues* = ["0", "1", "2", "3", "4", "5", "8", "10"]
  ka10027TrdePricaCndValues* = [
    "0", "3", "5", "10", "30", "50", "100", "300", "500", "1000", "3000",
    "5000"]
  ka10027StexTpValues* = ["1", "2", "3"]

  krxStexTp* = "1"       ## stex_tp 1:KRX, 2:NXT, 3:통합 (official spec)
  sortTpRiseRate* = "1"  ## sort_tp 1:상승률
  sortTpFallRate* = "3"  ## sort_tp 3:하락률

  defaultPageCap* = 10   ## MAX_PAGES of the official ka10027 example

  ## The explicit subset of TRs this module declares paginated: repeat and
  ## the page cap apply to these only, never to vendor input as a whole.
  paginatedTrs* = ["ka10027", "ka10080"]

  ## Header names that must never pass through this layer.
  secretHeaderNames* = [
    "authorization", "appkey", "app_key", "secretkey", "app_secret",
    "access_token", "refresh_token", "token"]

let
  ka10027Spec* = TrSpec(
    apiId: ka10027ApiId,
    path: ka10027Path,
    paginated: true,
    listKey: ka10027ListKey,
    rowFields: @ka10027RowFields)

  ka10080Spec* = TrSpec(
    apiId: ka10080ApiId,
    path: ka10080Path,
    paginated: true,
    listKey: ka10080ListKey,
    rowFields: @ka10080RowFields)

  ## ka10081 is declared non-paginated: the vendor offers cont-yn/next-key
  ## continuation, but the declared capture scope is a single page (the
  ## recent-20+-completed-days need is inside one 600-row page) and a
  ## measured success page legitimately carries cont-yn=Y. The paginated
  ## chain rules therefore do NOT apply to it at all — the ka10081 audit
  ## (rest_resp.nim) enforces the single-page scope itself; validateChainPages
  ## never sees this spec.
  ka10081Spec* = TrSpec(
    apiId: ka10081ApiId,
    path: ka10081Path,
    paginated: false,
    listKey: ka10081ListKey,
    rowFields: @ka10081RowFields,
    extraBodyKeys: @ka10081BodyEchoKeys)

proc verr(f: VendorFailure; msg: string): ref VendorInputError =
  let e = newException(VendorInputError, msg)
  e.failure = f
  e

proc inStrs(v: string; xs: openArray[string]): bool =
  for x in xs:
    if v == x: return true
  false

proc requireIn(name, value: string; allowed: openArray[string]) =
  if not inStrs(value, allowed):
    raise verr(vfContract, name & " value is not in the documented enum: " & value)

# ---------------------------------------------------------------- byte helpers

proc toBytes*(s: string): seq[byte] =
  ## Byte-exact view of a string; no encoding change.
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc bytesText*(b: seq[byte]): string =
  ## Byte-exact view of a byte string; no encoding change, no validation.
  result = newString(len(b))
  for i in 0 ..< len(b):
    result[i] = char(b[i])

proc sha256Hex*(r: RawHttpResp): string {.inline.} =
  sha256Hex(r.body)

proc sha256Hex*(w: RawWsPayload): string {.inline.} =
  sha256Hex(w.payload)

# ---------------------------------------------------------------- secret guard

proc secretOffenders*(names: openArray[string]): seq[string] =
  ## Header names (any case) that are secrets and must not be recorded here.
  for n in names:
    if inStrs(n.toLowerAscii, secretHeaderNames):
      result.add(n)

proc refuseSecretHeaders*(names: openArray[string]) =
  ## Fail closed when a caller tries to route secret headers through the
  ## vendor-input layer: auth and login live in the transport adapter.
  let bad = secretOffenders(names)
  if bad.len > 0:
    raise verr(vfSecret,
               "secret headers are not allowed in vendor input: " & bad.join(", "))

# ---------------------------------------------------------------- preservation

proc httpResp*(apiId: string; status: int; contYn, nextKey: string;
               body: seq[byte]): RawHttpResp =
  ## Preserve one vendor REST response. Only non-secret response metadata is
  ## accepted (api-id, status, cont-yn, next-key); the body bytes are kept
  ## verbatim, whatever they are. Anything secret has nowhere to go.
  if apiId.len == 0 or apiId.len > 10:
    raise verr(vfContract, "api-id must be 1..10 characters: " & apiId)
  if not inStrs(contYn, ["", "Y", "N"]):
    raise verr(vfContract, "cont-yn must be Y or N: " & contYn)
  if nextKey.len > 50:
    raise verr(vfContract,
               "next-key exceeds the documented 50 characters: " & $nextKey.len)
  if status < 100 or status > 599:
    raise verr(vfContract, "HTTP status out of range: " & $status)
  result = RawHttpResp(apiId: apiId, status: status, contYn: contYn,
                       nextKey: nextKey, body: body)

proc httpResp*(apiId: string; status: int; contYn, nextKey, body: string): RawHttpResp =
  httpResp(apiId, status, contYn, nextKey, toBytes(body))

proc wsPayload*(channel: string; payload: seq[byte]): RawWsPayload =
  ## Preserve one WS application message. The caller supplies the payload
  ## after TLS and frame reassembly; this module never guesses framing.
  if channel.len == 0:
    raise verr(vfContract, "channel label must not be empty")
  result = RawWsPayload(channel: channel, payload: payload)

proc wsPayload*(channel, payload: string): RawWsPayload =
  wsPayload(channel, toBytes(payload))

proc initVendorCapture*(spec: TrSpec = ka10027Spec): VendorCapture =
  VendorCapture(spec: spec)

# ---------------------------------------------------------------- query schema

proc sortTpOf*(d: Direction): string =
  case d
  of dirUp: sortTpRiseRate
  of dirDown: sortTpFallRate

proc validateKa10027Query*(q: Ka10027Query) =
  ## All nine request fields are required and must be documented enum values.
  requireIn("mrkt_tp", q.mrktTp, ka10027MrktTpValues)
  requireIn("trde_qty_cnd", q.trdeQtyCnd, ka10027TrdeQtyCndValues)
  requireIn("stk_cnd", q.stkCnd, ka10027StkCndValues)
  requireIn("crd_cnd", q.crdCnd, ka10027CrdCndValues)
  requireIn("updown_incls", q.updownIncls, ka10027UpdownInclsValues)
  requireIn("pric_cnd", q.pricCnd, ka10027PricCndValues)
  requireIn("trde_prica_cnd", q.trdePricaCnd, ka10027TrdePricaCndValues)
  requireIn("stex_tp", q.stexTp, ka10027StexTpValues)
  requireIn("sort_tp", sortTpOf(q.direction), ka10027SortTpValues)

proc initKa10027Query*(direction: Direction; mrktTp, trdeQtyCnd, stkCnd,
                       crdCnd, updownIncls, pricCnd, trdePricaCnd,
                       stexTp: string): Ka10027Query =
  result = Ka10027Query(
    direction: direction, mrktTp: mrktTp, trdeQtyCnd: trdeQtyCnd,
    stkCnd: stkCnd, crdCnd: crdCnd, updownIncls: updownIncls,
    pricCnd: pricCnd, trdePricaCnd: trdePricaCnd, stexTp: stexTp)
  validateKa10027Query(result)

proc ka10027RequestBody*(q: Ka10027Query): HcjValue =
  ## The nine documented request body fields. No authorization header is
  ## produced here: authentication is out of scope for this module.
  validateKa10027Query(q)
  hObj(
    ("mrkt_tp", hStr(q.mrktTp)),
    ("sort_tp", hStr(sortTpOf(q.direction))),
    ("trde_qty_cnd", hStr(q.trdeQtyCnd)),
    ("stk_cnd", hStr(q.stkCnd)),
    ("crd_cnd", hStr(q.crdCnd)),
    ("updown_incls", hStr(q.updownIncls)),
    ("pric_cnd", hStr(q.pricCnd)),
    ("trde_prica_cnd", hStr(q.trdePricaCnd)),
    ("stex_tp", hStr(q.stexTp)))

proc allDigits(s: string): bool =
  if s.len == 0: return false
  for c in s.items:
    if c < '0' or c > '9': return false
  true

proc validateKa10080Query*(q: Ka10080Query) =
  ## The documented request fields. stk_cd is a free string (the official
  ## spec pins no enum; lengths are not enforced, like ka10027), tic_scope
  ## and upd_stkpc_tp must be documented enum values, and a present base_dt
  ## must be the documented YYYYMMDD form (8 digits). The acceptance path
  ## additionally pins tic_scope to the declared 3-minute scope.
  if q.stkCd.len == 0:
    raise verr(vfContract, "ka10080 stk_cd must not be empty")
  requireIn("tic_scope", q.ticScope, ka10080TicScopeValues)
  requireIn("upd_stkpc_tp", q.updStkpcTp, ka10080UpdStkpcTpValues)
  if q.baseDt.len > 0 and not allDigits(q.baseDt):
    raise verr(vfContract,
               "ka10080 base_dt is not the documented YYYYMMDD form: " &
               q.baseDt)

proc initKa10080Query*(stkCd, ticScope, updStkpcTp, baseDt: string): Ka10080Query =
  result = Ka10080Query(stkCd: stkCd, ticScope: ticScope,
                        updStkpcTp: updStkpcTp, baseDt: baseDt)
  validateKa10080Query(result)

proc ka10080RequestBody*(q: Ka10080Query): HcjValue =
  ## The documented request body fields. base_dt is OPTIONAL in the official
  ## spec: it is emitted only when declared (non-empty), so an absent
  ## base_dt round-trips as an absent field, never as an empty string.
  ## No authorization header is produced here.
  validateKa10080Query(q)
  if q.baseDt.len > 0:
    hObj(
      ("base_dt", hStr(q.baseDt)),
      ("stk_cd", hStr(q.stkCd)),
      ("tic_scope", hStr(q.ticScope)),
      ("upd_stkpc_tp", hStr(q.updStkpcTp)))
  else:
    hObj(
      ("stk_cd", hStr(q.stkCd)),
      ("tic_scope", hStr(q.ticScope)),
      ("upd_stkpc_tp", hStr(q.updStkpcTp)))

proc validateKa10081Query*(q: Ka10081Query) =
  ## The measured request fields (mock, 2026-11-10, /tmp/hs-ka10081/):
  ## stk_cd is a free string (the measured vendor pins no enum), upd_stkpc_tp
  ## must be a measured enum value, and base_dt is REQUIRED — unlike
  ## ka10080's optional field — in the measured YYYYMMDD form (8 digits).
  if q.stkCd.len == 0:
    raise verr(vfContract, "ka10081 stk_cd must not be empty")
  requireIn("upd_stkpc_tp", q.updStkpcTp, ka10081UpdStkpcTpValues)
  if not (q.baseDt.len == 8 and allDigits(q.baseDt)):
    raise verr(vfContract,
               "ka10081 base_dt is not the measured YYYYMMDD form: " &
               q.baseDt)

proc initKa10081Query*(stkCd, baseDt, updStkpcTp: string): Ka10081Query =
  result = Ka10081Query(stkCd: stkCd, baseDt: baseDt, updStkpcTp: updStkpcTp)
  validateKa10081Query(result)

proc ka10081RequestBody*(q: Ka10081Query): HcjValue =
  ## The measured request body fields — all three required. No
  ## authorization header is produced here: authentication is out of scope
  ## for this module.
  validateKa10081Query(q)
  hObj(
    ("base_dt", hStr(q.baseDt)),
    ("stk_cd", hStr(q.stkCd)),
    ("upd_stkpc_tp", hStr(q.updStkpcTp)))

proc continuationHeaders*(prev: RawHttpResp): tuple[contYn, nextKey: string] =
  ## cont-yn/next-key values for the next request, per spec: set both only
  ## when the previous response header said Y.
  if prev.contYn == "Y":
    if prev.nextKey.len == 0:
      raise verr(vfContract,
                 "cont-yn=Y without next-key cannot continue the chain")
    result = (prev.contYn, prev.nextKey)
  else:
    result = ("N", "")

# ---------------------------------------------------------------- normalization

proc objOf(ps: seq[HcjPair]): HcjValue =
  ## Object construction for dynamically built rows, with hObj's validation.
  for i in 0 ..< ps.len:
    if ps[i].k.len == 0:
      raise verr(vfContract, "empty event key")
    for chr in ps[i].k.items:
      let c = byte(chr)
      if not ((c >= 'a'.byte and c <= 'z'.byte) or
              (c >= 'A'.byte and c <= 'Z'.byte) or
              (c >= '0'.byte and c <= '9'.byte) or
              c == '_'.byte or c == '-'.byte):
        raise verr(vfContract, "event key not [A-Za-z0-9_-]: " & ps[i].k)
    for j in 0 ..< i:
      if ps[j].k == ps[i].k:
        raise verr(vfContract, "duplicate event key: " & ps[i].k)
  result = HcjValue(kind: hkObj, pairs: ps)

proc parseBodyDoc(resp: RawHttpResp): HcjValue =
  try:
    result = parseDoc(bytesText(resp.body))
  except HcjError as e:
    raise verr(vfContract, "response body is not valid HCJ JSON: " & e.msg)
  if result.kind != hkObj:
    raise verr(vfContract,
               "response body is not a JSON object: " & kindName(result))

proc rowFromMap(spec: TrSpec; item: HcjValue): HcjValue =
  var ps: seq[HcjPair] = @[]
  for p in item.pairs:
    if not inStrs(p.k, spec.rowFields):
      raise verr(vfContract,
                 "row field outside the documented schema: " & p.k)
    if p.v.kind != hkStr:
      raise verr(vfContract,
                 "row field is not a string: " & p.k & " is " & kindName(p.v))
    ps.add((p.k, p.v))
  result = objOf(ps)

proc rowFromArr(spec: TrSpec; item: HcjValue): HcjValue =
  if item.items.len != spec.rowFields.len:
    raise verr(vfContract,
               "positional row length is not the documented field count: " &
               $item.items.len & " != " & $spec.rowFields.len)
  var ps: seq[HcjPair] = @[]
  for i, v in item.items:
    if v.kind != hkStr:
      raise verr(vfContract, "positional row element is not a string at " & $i)
    ps.add((spec.rowFields[i], v))
  result = objOf(ps)

proc parsePageRows*(spec: TrSpec; resp: RawHttpResp): seq[HcjValue] =
  ## Fail closed on any response failure: api-id/path pair mismatch
  ## (swapping api-id on a shared URL fails silently at the vendor, so the
  ## pair is checked here), non-200 transport status, responses that do not
  ## affirm success, and a success body whose list key is absent — the spec
  ## does not guarantee absent-means-empty, so only an explicit empty array
  ## is a confirmed empty answer. Kiwoom business errors arrive as HTTP 200
  ## with return_code != 0; a body without return_code does not affirm
  ## success — the official client tolerates absence, but that tolerance is
  ## a client choice, not an independently confirmed production guarantee.
  if resp.apiId != spec.apiId:
    raise verr(vfContract, "response api-id does not match the spec: " &
               resp.apiId & " vs " & spec.apiId)
  if resp.status != 200:
    raise verr(vfTransport, "HTTP status " & $resp.status & " (business " &
               "errors arrive as 200 + return_code; anything else is fail-closed)")
  let doc = parseBodyDoc(resp)
  for p in doc.pairs:
    if not (p.k == spec.listKey or p.k == "return_code" or p.k == "return_msg" or
            inStrs(p.k, spec.extraBodyKeys)):
      raise verr(vfContract,
                 "response body key outside the documented schema: " & p.k)
  let rc = doc.getOpt("return_code")
  if rc.isNone:
    raise verr(vfVendorError,
               "return_code is missing: an HTTP 200 body without the success " &
               "code is not confirmed success (the official client tolerates " &
               "absence, but that is a client choice, not an independently " &
               "confirmed production guarantee); rejected (fail-closed)")
  if rc.get.kind != hkInt:
    raise verr(vfContract,
               "return_code is not an integer: " & kindName(rc.get))
  if rc.get.ival != 0:
    raise verr(vfVendorError,
               "vendor return_code " & $rc.get.ival & ": rejected (fail-closed)")
  let rm = doc.getOpt("return_msg")
  if rm.isSome and rm.get.kind != hkStr:
    raise verr(vfContract, "return_msg is not a string: " & kindName(rm.get))
  let lst = doc.getOpt(spec.listKey)
  if lst.isNone:
    raise verr(vfContract,
               spec.listKey & " is missing while return_code is 0: the " &
               "official specification does not guarantee that an absent " &
               "list means empty; only an explicit empty array is a " &
               "confirmed empty answer; rejected (fail-closed)")
  if lst.get.kind != hkArr:
    raise verr(vfContract,
               spec.listKey & " is not an array: " & kindName(lst.get))
  for item in lst.get.items:
    case item.kind
    of hkObj:
      result.add(rowFromMap(spec, item))
    of hkArr:
      result.add(rowFromArr(spec, item))
    else:
      raise verr(vfContract,
                 "row is neither an object nor a positional array: " &
                 kindName(item))

proc validateChainPages(spec: TrSpec; pages: seq[RawHttpResp]; pageCap: int;
                        truncatedOk = false) =
  ## Repeat and the cap apply only to the explicit paginated subset. A chain
  ## that ends while cont-yn=Y is never a success: below the cap a
  ## continuation page is missing (vfIncomplete); at the cap the declared
  ## subset is truncated (vfTruncated). truncatedOk is the acceptance
  ## contract's declaration (REPLAY_CONTRACT §12.1: the cap is a
  ## scanner-side declaration, the pages beyond it are "not fetched", never
  ## "no more candidates"): the caller owns the truncation fact -- the gap
  ## record and the REST_TRUNCATED event -- and consumes this chain as a
  ## declared truncated subset. The fetched pages are still fully validated;
  ## nothing about them is waived.
  if spec.paginated:
    if pageCap < 1:
      raise verr(vfContract, "page cap must be >= 1: " & $pageCap)
    if pages.len == 0:
      raise verr(vfIncomplete,
                 "page chain has no pages: a missing response is not empty data")
    if pages.len > pageCap:
      raise verr(vfContract, "page chain exceeds the declared cap: " &
                 $pages.len & " > " & $pageCap)
    for i in 0 ..< pages.len - 1:
      if pages[i].contYn != "Y":
        raise verr(vfContract, "page " & $(i + 1) & " is terminal (" &
                   pages[i].contYn & ") but more pages follow")
      if pages[i].nextKey.len == 0:
        raise verr(vfContract,
                   "page " & $(i + 1) & " says cont-yn=Y without next-key")
    let last = pages[pages.len - 1]
    if last.contYn == "Y":
      if pages.len >= pageCap:
        if not truncatedOk:
          raise verr(vfTruncated,
                     "page cap " & $pageCap & " reached while cont-yn=Y: the " &
                     "declared candidate subset is truncated — the vendor still " &
                     "has data; rejected (fail-closed, never success)")
      else:
        raise verr(vfIncomplete,
                   "page chain ended while cont-yn=Y below the cap: a declared " &
                   "continuation page is missing; rejected (fail-closed)")
  else:
    if pages.len != 1:
      raise verr(vfContract,
                 "non-paginated TR allows exactly one page, got " & $pages.len)
    if pages[0].contYn == "Y":
      raise verr(vfContract, "non-paginated TR answered cont-yn=Y: repeat is " &
                 "an explicit subset, not the whole")

proc normalizeChain*(spec: TrSpec; chain: PageChain;
                     pageCap: int = defaultPageCap;
                     truncatedOk = false): seq[VendorEvent] =  ## Pure: preserved page bytes -> normalized row events, in page then row
  ## order. Every failure raises; a partial event list is never returned.
  ## truncatedOk consumes a cap-closed chain as a declared truncated subset
  ## (the caller owns the truncation fact; see validateChainPages).
  validateKa10027Query(chain.query)
  validateChainPages(spec, chain.pages, pageCap, truncatedOk)
  for pi, resp in chain.pages:
    for ri, row in parsePageRows(spec, resp):
      var ps: seq[HcjPair] = @[
        ("api_id", hStr(spec.apiId)),
        ("page", hInt(pi + 1)),
        ("row_index", hInt(ri)),
        ("sort_tp", hStr(sortTpOf(chain.query.direction)))]
      for p in row.pairs:
        ps.add((p.k, p.v))
      result.add(VendorEvent(
        kind: evRestRow,
        label: resp.apiId,
        sourceSha256: sha256Hex(resp),
        canonical: canonical(objOf(ps)),
        payload: @[]))

proc wsEvents*(payloads: seq[RawWsPayload]): seq[VendorEvent] =
  ## Identity normalization: the vendor WS payload schema is unverified, so
  ## the payload bytes themselves are the event and are compared as bytes.
  for w in payloads:
    result.add(VendorEvent(
      kind: evWsPayload,
      label: w.channel,
      sourceSha256: sha256Hex(w),
      canonical: "",
      payload: w.payload))

proc verifyKa10080Chain*(chain: Ka10080Chain;
                         pageCap: int = defaultPageCap;
                         truncatedOk = false) =
  ## Audit one ka10080 chart chain exactly the way the ka10027 path affirms
  ## success: the declared scope against the documented enums, the
  ## cont-yn/page-cap chain rules (validateChainPages is spec-generic), and
  ## every page's rows against the documented row schema (parsePageRows:
  ## HTTP 200, return_code present + integer + 0, list key present, every
  ## row exactly the documented fields, all strings). Raises on any failure;
  ## a partial validation is never a success. truncatedOk consumes a
  ## cap-closed chain as a declared truncated subset (same owner rule as
  ## ka10027: the caller owns the truncation fact).
  validateKa10080Query(chain.query)
  validateChainPages(ka10080Spec, chain.pages, pageCap, truncatedOk)
  for resp in chain.pages:
    discard parsePageRows(ka10080Spec, resp)

proc normalizeEvents*(cap: VendorCapture;
                      pageCap: int = defaultPageCap): seq[VendorEvent] =
  ## All events of a capture in deterministic order: chains in stored order
  ## (pages then rows), then WS payloads in arrival order.
  for chain in cap.chains:
    result.add(normalizeChain(cap.spec, chain, pageCap))
  result.add(wsEvents(cap.wsPayloads))

proc chainSymbols*(spec: TrSpec; chain: PageChain;
                   pageCap: int = defaultPageCap;
                   truncatedOk = false): seq[string] =
  ## stk_cd of every row, in vendor order. A row without stk_cd cannot yield
  ## a candidate and rejects the whole chain (fail-closed). truncatedOk
  ## consumes a cap-closed chain as a declared truncated subset.
  validateKa10027Query(chain.query)
  validateChainPages(spec, chain.pages, pageCap, truncatedOk)
  for resp in chain.pages:
    for row in parsePageRows(spec, resp):
      let cd = row.getOpt("stk_cd")
      if cd.isNone:
        raise verr(vfContract,
                   "row without stk_cd cannot yield a candidate (fail-closed)")
      result.add(cd.get.asStr)

proc isCandidateCode*(cd: string): bool =
  ## The candidate universe's code shape: exactly 6 digits. The official
  ## ka10027 request enum has no value that excludes ELW (checked
  ## 2026-11-09 against the spec JSON: stk_cnd documents ETF/ETN/우선주/
  ## 관리주 exclusions only) and documents no stk_cls value table, so the
  ## code shape itself is the declared deterministic boundary between the
  ## candidate universe and everything else the ranking mixes in (the
  ## 2026-11-09 demo capture: ELW "18064K", alphanumeric ETF/ETN and mock
  ## stock codes). An out-of-shape row is out of the universe — its raw
  ## evidence stays preserved in the response bytes, and the excluded
  ## lists carry its code; it is never a candidate and never a failure.
  cd.len == 6 and allDigits(cd)

proc upDownCandidates*(upChain, downChain: PageChain;
                       pageCap: int = defaultPageCap;
                       upTruncated = false; downTruncated = false):
                       UpDownCandidates =
  ## KRX candidate universe from one up (sort_tp 1) and one down (sort_tp 3)
  ## query. Any response/page failure raises; explicitly empty arrays are a
  ## valid vendor answer and are returned as empty, never as an error.
  ## upTruncated/downTruncated declare that leg cap-closed: the caller owns
  ## that leg's truncation fact and consumes it as a declared truncated
  ## subset (the other validation of that leg is unchanged).
  ## Rows whose stk_cd is not the 6-digit candidate shape (isCandidateCode)
  ## are partitioned out of the universe into upExcluded/downExcluded in
  ## vendor order: the vendor spec offers no request value that excludes
  ## them, so the shape is the universe boundary. A row without stk_cd
  ## still rejects the whole chain (fail-closed, unchanged).
  if upChain.query.direction != dirUp:
    raise verr(vfContract, "up chain query direction is not up (sort_tp 1)")
  if downChain.query.direction != dirDown:
    raise verr(vfContract, "down chain query direction is not down (sort_tp 3)")
  if upChain.query.stexTp != krxStexTp or downChain.query.stexTp != krxStexTp:
    raise verr(vfContract,
               "candidate queries are KRX-only: stex_tp must be " & krxStexTp)
  for cd in chainSymbols(ka10027Spec, upChain, pageCap, upTruncated):
    if isCandidateCode(cd): result.up.add(cd) else: result.upExcluded.add(cd)
  for cd in chainSymbols(ka10027Spec, downChain, pageCap, downTruncated):
    if isCandidateCode(cd): result.down.add(cd)
    else: result.downExcluded.add(cd)

# ---------------------------------------------------------------- verification

proc sameEvent*(a, b: VendorEvent): bool =
  ## Byte/value equality of two events: canonical bytes for REST rows, exact
  ## payload bytes for WS messages, plus kind, label and raw-source hash.
  if a.kind != b.kind or a.label != b.label or a.sourceSha256 != b.sourceSha256:
    return false
  case a.kind
  of evRestRow: a.canonical == b.canonical
  of evWsPayload: a.payload == b.payload

proc verifyEvents*(cap: VendorCapture; stored: seq[VendorEvent];
                   pageCap: int = defaultPageCap): seq[string] =
  ## Recompute the events from the raw capture and compare them with the
  ## stored events byte- and value-wise. Empty result means verified; any
  ## issue means the stored events are wrong and must be rejected.
  var recomputed: seq[VendorEvent] = @[]
  try:
    recomputed = normalizeEvents(cap, pageCap)
  except CatchableError as e:
    result.add("recomputation rejected the capture: " & e.msg)
    return
  if stored.len != recomputed.len:
    result.add("event count differs: stored " & $stored.len &
               " vs recomputed " & $recomputed.len)
  let n = if stored.len < recomputed.len: stored.len else: recomputed.len
  for i in 0 ..< n:
    if not sameEvent(stored[i], recomputed[i]):
      result.add("event " & $i & " (label=" & stored[i].label &
                 ") differs from the recomputation")
