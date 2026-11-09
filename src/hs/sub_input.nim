## sub / ws_raw: the validated acceptance path for the VS-2 subscription
## evidence records (target contract; docs/REPLAY_CONTRACT.md §12.5). Like
## rest_resp, this module is the single source of truth for these record
## schemas: a record that fails its schema rejects the run at its own seq.
##
## Pure: parses and validates one recorded sub or ws_raw record and
## composes the registration sets the subscription protocol must carry.
## No wall clock, no filesystem, no network.
##
## Vendor facts used here (official spec JSON + official client sources +
## portal, 2026-10-30; see ASSUMPTIONS.md "Vendor facts"):
##   - REG envelope (POST /api/dostk/websocket): trnm "REG"/"REMOVE",
##     grp_no (한글명 "그룹번호", description empty; every official
##     example pins "1"), refresh (String, required, 원문: "등록(REG)시
##     0:기존유지안함 1:기존유지(Default) 0일경우 기존등록한 item/type은
##     해지, 1일경우 기존등록한 item/type 유지 해지(REMOVE)시 값 불필요"),
##     data = list of items {item: codes, type: TR 명 (0A, 0B, ...)}.
##     The official 0s example registers channel-only:
##     {"trnm":"REG","grp_no":"1","refresh":"1","data":[{"item":[],
##     "type":["0s"]}]}.
##   - The termination scope of refresh "0" (전역 / 같은 grp_no / 같은
##     type) has no official wording and REMOVE's partial-removal
##     behavior is undocumented — both UNVERIFIED (G2 mock experiments).
##     All 46 official examples (국내 38 + 미국 8) are single-type REGs
##     (one {item, type} entry, refresh "1", grp_no "1"); a multi-type
##     REG has no official precedent and no official prohibition.
##     REMOVE is the REG structure minus refresh (official SDK
##     build_remove_packet); no official REMOVE example exists.
##   - channel "0s" (장시작시간) is the only documented normal-close
##     signal: FID 215 장운영구분 carries the evidenced close subset
##     2 (장마감 알림), 4 (장마감), 8 (정규장마감), 9 (전체장마감, after
##     18:00); the full value table is larger and UNVERIFIED.
##   - channel "0B" (주식체결) carries the candidate ticks.
##   - notice #49 (유량 정책 안내): 세션당 실시간 시세 200종목 — the
##     per-session cap this module enforces as 200 codes total, 100 per
##     direction (one query per direction, REPLAY_CONTRACT §12.1).
##
## sub record schema (module-internal contract; the raw is one HCJ object
## with exactly the fields its (action, phase) combination allows):
##   common (every combination):
##     gen            int      subscription generation, >= 1, monotonic
##     action         "reg" | "remove"
##     phase          "req" | "ack"
##     t              string   ISO 8601 with numeric offset, exactly
##                             "YYYY-MM-DDTHH:MM:SS+HH:MM" / "-HH:MM"
##   (reg, req) only:
##     types          array    non-empty, each element 1..4 chars of
##                             [0-9A-Za-z] ("0B", "0s", ...)
##     codes          array    each element exactly 6 digits; empty is
##                             allowed (the channel-only 0s registration)
##     refresh        "0" | "1"
##   (remove, req) only:
##     types          array    non-empty, same element rule
##     codes          array    non-empty — a removal must name its targets
##   (ack) only:
##     return_code    int      the REG/REMOVE ack code (0/1 documented)
##     return_msg     string   optional
## A field outside the combination — e.g. refresh on an ack, return_code
## on a req, types on an ack — is a schema failure, as are missing
## required fields, wrong types and value-domain violations.
##
## ws_raw record schema (exactly these fields):
##   channel      string   non-empty vendor channel label ("0B", "0s")
##   conn         int      connection generation, >= 1
##   t            string   ISO 8601, same format rule as sub
##   payload_hex  string   the preserved application payload bytes,
##                         lowercase hex, even length (the same HCJ-safe
##                         byte encoding rule as rest_resp body_hex:
##                         uppercase hex, odd length and non-hex digits
##                         are schema failures; hex is the only accepted
##                         encoding). The bytes are the RFC 6455
##                         application data after de-framing and
##                         unmasking — recv(decode=False) of the
##                         websockets library: reassembled application
##                         messages, control frames never appear here.
##
## Composition (pure; the official single-type REG contract — a REG
## carries exactly one {item, type} entry whose type list has a single
## element, the form of all 46 official examples):
##   selectTopPerDirection the deterministic subscription selection
##                         between candidate derivation (vendor_input)
##                         and REG composition (policy
##                         kiwoom_response_order_first_100_v1): each
##                         direction's first maxPerDirection codes in
##                         vendor response order, never re-ranked. An
##                         excluded candidate is a recorded exclusion
##                         (the collector's subscription_truncated gap,
##                         judged SUBSCRIPTION_TRUNCATED), never "no
##                         such candidate".
##   composeRegData        the 0B candidate REG data: one entry, item =
##                         up then down codes in vendor order, type
##                         ["0B"]. No other type can appear: the
##                         market-state channel never enters a
##                         replacement request — "0s는 0B 치환 요청에
##                         등장하지 않는다" is structural here.
##   composeMarketStateReg the 0s market-state REG data: one entry with
##                         empty codes and type ["0s"] — its own REG,
##                         never combined with the candidate REG.
##   composeRemoveData     the 0B removal data: one entry naming the
##                         codes to take out (the full outgoing
##                         generation; empty is rejected, the same rule
##                         as the (remove,req) record schema). refresh
##                         is not part of REMOVE. 0s is never a REMOVE
##                         target: its removal form is undocumented, so
##                         the market-state channel ends with the
##                         connection.
##   activeSets            deterministic ack-based active-subscription
##                         bookkeeping over sub records in stream order:
##                         acks with return_code 0 only (requests alone
##                         never change state — fail-closed), an ack
##                         pairs with the oldest unmatched request of
##                         the same (gen, action), unmatched records are
##                         no-ops; output is one item per acked type,
##                         types and codes sorted ascending. Basis of
##                         the PR-2 Core subscription-set check.
##   Swap policy (scanner-side; refresh "0" is never sent):
##   replacement = REMOVE(outgoing 0B generation) → ack →
##   REG(incoming 0B, refresh "1") → ack. Caps (notice #49): ≤100
##   codes per direction, ≤200 total. The wire envelope's fixed
##   grp_no "1" and trnm are documented in REPLAY_CONTRACT §12.6; the
##   recorded sub schema names only the fields replay needs.
##
## Failure classes reuse VendorFailure. vfSecret has no carrier in these
## record shapes: no field can hold a credential, so nothing can leak one.
## Every failure raises; an unconfirmed state is never mapped to success.
##
## Unverified by a live producer (G2/G4), hence fail-closed: whether
## production acks carry return_code 0/1 and this exact field set, what
## generation/connection numbering production actually uses, and whether
## production payloads ever exceed these caps. Nothing here proves the
## recorded payloads are true — only that what was recorded is inside
## the declared schema, and that the composition keeps the single-type
## REG form and the 0s separation. Tests are synthetic only (M10).
import std/[algorithm, strutils]
import hcj, vendor_input

type
  SubInputError* = object of CatchableError
    failure*: VendorFailure
    seqNo*: int   ## stream seq of the offending record (composition: 0)

  SubAction* = enum
    saReg      ## "reg"
    saRemove   ## "remove"

  SubPhase* = enum
    spReq      ## "req" — what the scanner asked the vendor to do
    spAck      ## "ack" — the vendor's REG/REMOVE acknowledgement

  SubRecord* = object
    ## One parsed sub record: the subscription lifecycle evidence.
    seqNo*: int
    gen*: int              ## subscription generation (>= 1, monotonic)
    action*: SubAction
    phase*: SubPhase
    t*: string             ## ISO 8601 with numeric offset
    types*: seq[string]    ## req only: channel types in request order
    codes*: seq[string]    ## req only: codes in request order
    refresh*: string       ## (reg, req) only: "0" or "1"; "" otherwise
    returnCode*: int       ## ack only
    returnMsg*: string     ## ack only, optional ("" when absent)

  WsRawRecord* = object
    ## One parsed ws_raw record: preserved application payload bytes.
    seqNo*: int
    channel*: string
    conn*: int             ## connection generation (>= 1)
    t*: string
    payload*: seq[byte]    ## decoded payload_hex, byte-exact

  SubRegItem* = object
    ## One item of a REG/REMOVE data list (official shape: item + type).
    typ*: string           ## channel type, e.g. "0B" or "0s"
    codes*: seq[string]

const
  subFields* = [
    "action", "codes", "gen", "phase", "refresh", "return_code",
    "return_msg", "t", "types"]
  wsRawFields* = ["channel", "conn", "payload_hex", "t"]

  ## The subscription lifecycle types this contract names. "0s" is the
  ## only documented normal-close signal (FID 215); "0B" carries the
  ## candidate ticks.
  marketCloseType* = "0s"
  candidateType* = "0B"

  ## Notice #49: 세션당 실시간 시세 200종목. One query per direction
  ## (§12.1), so the total splits as at most 100 per direction.
  maxPerDirection* = 100
  maxTotalSubscriptions* = 200

  ## The user-approved deterministic selection policy (REPLAY_CONTRACT
  ## §12.1): each direction's confirmed candidates are consumed in
  ## Kiwoom response order — page then row, exactly the order
  ## vendor_input.upDownCandidates returns — and the FIRST
  ## maxPerDirection become the subscription set. Nothing is re-ranked
  ## and no field is parsed into a number: the vendor's own sort
  ## (sort_tp "1"/"3") is the ranking.
  selectionPolicyId* = "kiwoom_response_order_first_100_v1"

type
  DirectionSelection* = object
    ## The selection facts of one direction. candidateCount is what the
    ## recorded pages affirm — the confirmed count, never an estimate
    ## of a truncated remainder — of the IN-SCOPE candidates (the
    ## 6-digit-shaped codes; out-of-shape rows were partitioned out at
    ## derivation and count only in scopeExcludedCount).
    direction*: string      ## "up" | "down"
    candidateCount*: int
    selectedCount*: int
    excludedCount*: int
    scopeExcludedCount*: int ## rows out of the candidate universe by code shape

  SelectionResult* = object
    ## The composition input plus the per-direction facts. facts[0] is
    ## up, facts[1] is down — the §12.1 query order.
    selected*: UpDownCandidates
    facts*: array[2, DirectionSelection]

proc serr(seqNo: int; f: VendorFailure; msg: string): ref SubInputError =
  let e = newException(SubInputError, msg)
  e.failure = f
  e.seqNo = seqNo
  e

proc inArr(v: string; xs: openArray[string]): bool =
  for x in xs:
    if v == x: return true
  false

# ------------------------------------------------------- format validators

proc validIso8601Offset*(s: string): bool =
  ## Exactly "YYYY-MM-DDTHH:MM:SS+HH:MM" (offset sign + or -), digits in
  ## every digit position and plausible ranges (month 01-12, day 01-31,
  ## hour < 24, minute/second < 60, offset < 24h). A pure format check:
  ## no calendar arithmetic (no per-month lengths, no leap days).
  if s.len != 25:
    return false
  if s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or
     s[16] != ':' or (s[19] != '+' and s[19] != '-') or s[22] != ':':
    return false
  for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 23, 24]:
    if s[i] notin {'0' .. '9'}:
      return false
  proc d2(i: int): int = (ord(s[i]) - ord('0')) * 10 + (ord(s[i + 1]) - ord('0'))
  result = d2(5) in 1 .. 12 and d2(8) in 1 .. 31 and d2(11) in 0 .. 23 and
    d2(14) in 0 .. 59 and d2(17) in 0 .. 59 and d2(20) in 0 .. 23 and
    d2(23) in 0 .. 59

proc validChannelType*(s: string): bool =
  ## 1..4 chars of [0-9A-Za-z]: the vendor TR/channel type vocabulary
  ## ("0B", "0s", ...).
  if s.len < 1 or s.len > 4:
    return false
  for c in s.items:
    let b = byte(c)
    if not ((b >= '0'.byte and b <= '9'.byte) or
            (b >= 'A'.byte and b <= 'Z'.byte) or
            (b >= 'a'.byte and b <= 'z'.byte)):
      return false
  result = true

proc validCode*(s: string): bool =
  ## Exactly 6 digits: the vendor stock code shape.
  if s.len != 6:
    return false
  for c in s.items:
    if c notin {'0' .. '9'}:
      return false
  result = true

proc validSha256Hex*(s: string): bool =
  ## 64 lowercase hex digits.
  if s.len != 64:
    return false
  for c in s.items:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  result = true

# ------------------------------------------------- HCJ-safe byte encoding

proc payloadHexOfBytes*(b: seq[byte]): string =
  ## Lowercase hex, two digits per byte: the HCJ-safe encoding of the
  ## preserved application payload bytes. Same rule as rest_resp's
  ## body_hex, module-local so this schema stays self-contained.
  const digits = "0123456789abcdef"
  result = newString(2 * b.len)
  for i in 0 ..< b.len:
    result[2 * i] = digits[int(b[i] shr 4)]
    result[2 * i + 1] = digits[int(b[i] and 0x0f)]

proc hexNibble(c: char): int =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'a' .. 'f': ord(c) - ord('a') + 10
  else: -1

proc payloadFromHex*(seqNo: int; s: string): seq[byte] =
  ## Inverse of payloadHexOfBytes. Strict: even length, lowercase hex
  ## only, byte-exact in both directions.
  if s.len mod 2 != 0:
    raise serr(seqNo, vfContract,
               "payload_hex is not a hex encoding: odd length " & $s.len)
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len:
    let hi = hexNibble(s[2 * i])
    let lo = hexNibble(s[2 * i + 1])
    if hi < 0 or lo < 0:
      raise serr(seqNo, vfContract,
                 "payload_hex is not lowercase hex at offset " & $(2 * i) &
                 ": only [0-9a-f] is the declared encoding")
    result[i] = byte(hi shl 4 or lo)

# ---------------------------------------------------------------- field access

proc strField(seqNo: int; obj: HcjValue; key, what: string): string =
  if not obj.has(key):
    raise serr(seqNo, vfContract, "missing " & what & ": " & key)
  let v = obj.get(key)
  if v.kind != hkStr:
    raise serr(seqNo, vfContract,
               what & " is not a string: " & key & " is " & kindName(v))
  v.strVal

proc intField(seqNo: int; obj: HcjValue; key, what: string): int =
  if not obj.has(key):
    raise serr(seqNo, vfContract, "missing " & what & ": " & key)
  let v = obj.get(key)
  if v.kind != hkInt:
    raise serr(seqNo, vfContract,
               what & " is not an integer: " & key & " is " & kindName(v))
  int(v.ival)

proc strArrField(seqNo: int; obj: HcjValue; key, what: string): seq[string] =
  if not obj.has(key):
    raise serr(seqNo, vfContract, "missing " & what & ": " & key)
  let v = obj.get(key)
  if v.kind != hkArr:
    raise serr(seqNo, vfContract,
               what & " is not an array: " & key & " is " & kindName(v))
  for item in v.items:
    if item.kind != hkStr:
      raise serr(seqNo, vfContract,
                 what & " element is not a string: " & kindName(item))
    result.add(item.strVal)

# ---------------------------------------------------------------- parse sub

proc combinationName(a: SubAction; p: SubPhase): string =
  "(" & (case a
         of saReg: "reg"
         of saRemove: "remove") & "," &
    (case p
     of spReq: "req"
     of spAck: "ack") & ")"

proc actionOf(seqNo: int; raw: HcjValue): SubAction =
  case strField(seqNo, raw, "action", "sub field")
  of "reg": saReg
  of "remove": saRemove
  else:
    raise serr(seqNo, vfContract,
               "sub action is not reg|remove: " &
               raw.get("action").strVal)

proc phaseOf(seqNo: int; raw: HcjValue): SubPhase =
  case strField(seqNo, raw, "phase", "sub field")
  of "req": spReq
  of "ack": spAck
  else:
    raise serr(seqNo, vfContract,
               "sub phase is not req|ack: " &
               raw.get("phase").strVal)

proc parseSub*(seqNo: int; raw: HcjValue): SubRecord =
  ## Parse and validate one sub record payload against its declared
  ## (action, phase) combination. Any schema failure raises here, at the
  ## record's own seq.
  if raw.kind != hkObj:
    raise serr(seqNo, vfContract, "sub raw is not an object: " & kindName(raw))
  for p in raw.pairs:
    if not inArr(p.k, subFields):
      raise serr(seqNo, vfContract,
                 "unknown sub field: " & p.k & " (the record schema is " &
                 "common gen/action/phase/t plus the combination fields " &
                 "types/codes/refresh for req and return_code/return_msg " &
                 "for ack)")
  let gen = intField(seqNo, raw, "gen", "sub field")
  if gen < 1:
    raise serr(seqNo, vfContract,
               "sub gen must be >= 1 (monotonic subscription generation): " &
               $gen)
  let action = actionOf(seqNo, raw)
  let phase = phaseOf(seqNo, raw)
  let t = strField(seqNo, raw, "t", "sub field")
  if not validIso8601Offset(t):
    raise serr(seqNo, vfContract,
               "sub t is not an ISO 8601 timestamp with a numeric offset " &
               "(YYYY-MM-DDTHH:MM:SS+HH:MM): " & t)
  result = SubRecord(seqNo: seqNo, gen: gen, action: action, phase: phase,
                     t: t)
  case phase
  of spReq:
    # A request carries its target list; an ack never does.
    if raw.has("return_code"):
      raise serr(seqNo, vfContract,
                 "sub field return_code is not allowed in a " &
                 combinationName(action, phase) & " record")
    if raw.has("return_msg"):
      raise serr(seqNo, vfContract,
                 "sub field return_msg is not allowed in a " &
                 combinationName(action, phase) & " record")
    result.types = strArrField(seqNo, raw, "types", "sub field")
    result.codes = strArrField(seqNo, raw, "codes", "sub field")
    for ty in result.types:
      if not validChannelType(ty):
        raise serr(seqNo, vfContract,
                   "sub types element is not 1..4 chars of [0-9A-Za-z]: " & ty)
    for c in result.codes:
      if not validCode(c):
        raise serr(seqNo, vfContract,
                   "sub codes element is not a 6-digit code: " & c)
    if result.types.len == 0:
      raise serr(seqNo, vfContract,
                 "sub types must not be empty in a " &
                 combinationName(action, phase) & " record")
    case action
    of saReg:
      result.refresh = strField(seqNo, raw, "refresh", "sub field")
      if not inArr(result.refresh, ["0", "1"]):
        raise serr(seqNo, vfContract,
                   "sub refresh is not 0|1: " & result.refresh)
    of saRemove:
      if raw.has("refresh"):
        raise serr(seqNo, vfContract,
                   "sub field refresh is not allowed in a (remove,req) " &
                   "record (REMOVE시 값 불필요, official refresh spec)")
      if result.codes.len == 0:
        raise serr(seqNo, vfContract,
                   "sub codes must not be empty in a (remove,req) record: " &
                   "a removal must name its targets")
  of spAck:
    if raw.has("types"):
      raise serr(seqNo, vfContract,
                 "sub field types is not allowed in an ack record")
    if raw.has("codes"):
      raise serr(seqNo, vfContract,
                 "sub field codes is not allowed in an ack record")
    if raw.has("refresh"):
      raise serr(seqNo, vfContract,
                 "sub field refresh is not allowed in an ack record")
    result.returnCode = intField(seqNo, raw, "return_code", "sub field")
    if raw.has("return_msg"):
      result.returnMsg = strField(seqNo, raw, "return_msg", "sub field")

# ---------------------------------------------------------------- parse ws_raw

proc parseWsRaw*(seqNo: int; raw: HcjValue): WsRawRecord =
  ## Parse and validate one ws_raw record payload: the preserved
  ## application payload bytes of one vendor WS message.
  if raw.kind != hkObj:
    raise serr(seqNo, vfContract,
               "ws_raw raw is not an object: " & kindName(raw))
  for p in raw.pairs:
    if not inArr(p.k, wsRawFields):
      raise serr(seqNo, vfContract,
                 "unknown ws_raw field: " & p.k & " (the record schema is " &
                 "exactly " & wsRawFields.join(", ") & ")")
  let channel = strField(seqNo, raw, "channel", "ws_raw field")
  if channel.len == 0:
    raise serr(seqNo, vfContract, "ws_raw channel must not be empty")
  let conn = intField(seqNo, raw, "conn", "ws_raw field")
  if conn < 1:
    raise serr(seqNo, vfContract,
               "ws_raw conn must be >= 1 (connection generation): " & $conn)
  let t = strField(seqNo, raw, "t", "ws_raw field")
  if not validIso8601Offset(t):
    raise serr(seqNo, vfContract,
               "ws_raw t is not an ISO 8601 timestamp with a numeric " &
               "offset (YYYY-MM-DDTHH:MM:SS+HH:MM): " & t)
  let payload = payloadFromHex(seqNo,
    strField(seqNo, raw, "payload_hex", "ws_raw field"))
  WsRawRecord(seqNo: seqNo, channel: channel, conn: conn, t: t,
              payload: payload)

# --------------------------------------------------- subscription selection

proc firstN(xs: seq[string]; n: int): seq[string] =
  ## The vendor-order prefix, verbatim: response order is the policy's
  ## only ranking.
  if xs.len <= n: xs else: xs[0 ..< n]

proc selectTopPerDirection*(cands: UpDownCandidates): SelectionResult =
  ## The one selection function between candidate derivation
  ## (vendor_input.upDownCandidates) and REG composition
  ## (composeRegData): keep each direction's first maxPerDirection
  ## codes in vendor response order. Pure and deterministic — same
  ## candidates, same selection. Candidates beyond the kept prefix are
  ## excluded from this session's subscription: the caller records that
  ## exclusion (the collector's subscription_truncated gap, judged
  ## SUBSCRIPTION_TRUNCATED), it is never interpreted away. The
  ## composeRegData caps stay untouched: this policy is what keeps the
  ## derived sets inside them, not a replacement for the checks — a
  ## 101-code set handed straight to composeRegData still raises.
  result.selected.up = firstN(cands.up, maxPerDirection)
  result.selected.down = firstN(cands.down, maxPerDirection)
  result.facts[0] = DirectionSelection(
    direction: "up", candidateCount: cands.up.len,
    selectedCount: result.selected.up.len,
    excludedCount: cands.up.len - result.selected.up.len,
    scopeExcludedCount: cands.upExcluded.len)
  result.facts[1] = DirectionSelection(
    direction: "down", candidateCount: cands.down.len,
    selectedCount: result.selected.down.len,
    excludedCount: cands.down.len - result.selected.down.len,
    scopeExcludedCount: cands.downExcluded.len)

# ---------------------------------------------------------------- composition

proc checkCodes(what: string; xs: seq[string]) =
  var seen: seq[string]
  for c in xs:
    if not validCode(c):
      raise serr(0, vfContract,
                 what & " code is not a 6-digit code: " & c)
    if inArr(c, seen):
      raise serr(0, vfContract,
                 what & " contains a duplicate code: " & c)
    seen.add(c)

proc checkDirectionCaps(upCodes, downCodes: seq[string]) =
  ## Notice #49: 세션당 실시간 시세 200종목; one query per direction, so
  ## at most 100 per direction and 200 total.
  if upCodes.len > maxPerDirection:
    raise serr(0, vfContract,
               "up direction exceeds the subscription cap " &
               $maxPerDirection & ": " & $upCodes.len & " codes (notice #49)")
  if downCodes.len > maxPerDirection:
    raise serr(0, vfContract,
               "down direction exceeds the subscription cap " &
               $maxPerDirection & ": " & $downCodes.len & " codes (notice #49)")
  if upCodes.len + downCodes.len > maxTotalSubscriptions:
    raise serr(0, vfContract,
               "subscription set exceeds the per-session cap " &
               $maxTotalSubscriptions & ": " & $(upCodes.len + downCodes.len) &
               " codes (notice #49)")

proc composeRegData*(upCodes, downCodes: seq[string]): seq[SubRegItem] =
  ## The 0B candidate REG data in the official single-type form: exactly
  ## one entry — item = up then down codes in vendor order, type
  ## ["0B"]. No other type can appear, so a replacement request can
  ## never carry (or drop) the market-state channel: 0s lives on its own
  ## REG (composeMarketStateReg), which is what keeps FID 215
  ## observable across any number of swaps. Caps: notice #49.
  checkDirectionCaps(upCodes, downCodes)
  checkCodes("candidate", upCodes & downCodes)
  @[SubRegItem(typ: candidateType, codes: upCodes & downCodes)]

proc composeMarketStateReg*(): seq[SubRegItem] =
  ## The 0s market-state REG data: exactly one entry with empty codes
  ## and type ["0s"] — the channel-only registration of the official
  ## example. Its own REG, never combined with the candidate REG.
  @[SubRegItem(typ: marketCloseType, codes: @[])]

proc composeRemoveData*(active0BCodes: seq[string]): seq[SubRegItem] =
  ## The 0B removal data: exactly one entry naming the codes to take
  ## out — the full outgoing generation at a swap, the active
  ## generation at the end-of-session teardown. Empty is rejected (the
  ## same rule as the (remove,req) record schema: a removal must name
  ## its targets). refresh is not part of REMOVE (해지시 값 불필요,
  ## official refresh spec). 0s is never a REMOVE target: its removal
  ## form is undocumented, so the market-state channel ends with the
  ## connection instead.
  if active0BCodes.len == 0:
    raise serr(0, vfContract,
               "removal set must not be empty: a removal must name its " &
               "targets (the full outgoing 0B generation)")
  if active0BCodes.len > maxTotalSubscriptions:
    raise serr(0, vfContract,
               "removal set exceeds the per-session cap " &
               $maxTotalSubscriptions & ": " & $active0BCodes.len &
               " codes (notice #49)")
  checkCodes("removal", active0BCodes)
  @[SubRegItem(typ: candidateType, codes: active0BCodes)]

proc activeSets*(subs: seq[SubRecord]): seq[SubRegItem] =
  ## The deterministic active-subscription bookkeeping over a sub
  ## record sequence in stream order — scanner-side bookkeeping, not a
  ## vendor-behavior claim:
  ##   - Only acks with return_code 0 change state; a request alone
  ##     never activates or deactivates anything (fail-closed).
  ##   - An ack pairs with the oldest still-unmatched request of the
  ##     same (gen, action); an unmatched ack or request is a no-op.
  ##     An ack that names a request consumes it, whatever its code.
  ##   - (reg, ack 0): the request's codes become active under each of
  ##     its types — but only with refresh "1": the effect of
  ##     refresh "0" (its termination scope) is UNVERIFIED, so such a
  ##     request makes the active set underivable and raises here at
  ##     the request's own seq.
  ##   - (remove, ack 0): the named codes leave every named type's
  ##     set. A type stays listed once a (reg, ack 0) has applied to
  ##     it, even if all its codes are later removed.
  ## Output: one item per acked type, types and codes sorted ascending.
  var
    pending: seq[tuple[gen: int; action: SubAction; rec: SubRecord]]
    sets: seq[SubRegItem]
  for rec in subs.items:
    if rec.phase == spReq:
      if rec.action == saReg and rec.refresh == "0":
        raise serr(rec.seqNo, vfContract,
                   "active set is underivable at a refresh=0 " &
                   "registration: the termination scope of refresh " &
                   "\"0\" is UNVERIFIED (the scanner policy sends " &
                   "refresh \"1\" REGs only)")
      pending.add((rec.gen, rec.action, rec))
      continue
    var match = -1
    for i in 0 ..< pending.len:
      if pending[i].gen == rec.gen and pending[i].action == rec.action:
        match = i
        break
    if match < 0:
      continue
    let req = pending[match].rec
    pending.delete(match)
    if rec.returnCode != 0:
      continue
    case req.action
    of saReg:
      for ty in req.types.items:
        var idx = -1
        for i in 0 ..< sets.len:
          if sets[i].typ == ty:
            idx = i
            break
        if idx < 0:
          var codes = req.codes
          sort(codes, cmp)
          sets.add(SubRegItem(typ: ty, codes: codes))
        else:
          for c in req.codes.items:
            if not inArr(c, sets[idx].codes):
              sets[idx].codes.add(c)
          sort(sets[idx].codes, cmp)
    of saRemove:
      for ty in req.types.items:
        for i in 0 ..< sets.len:
          if sets[i].typ == ty:
            var kept: seq[string]
            for c in sets[i].codes.items:
              if not inArr(c, req.codes):
                kept.add(c)
            sets[i].codes = kept
            break
  result = sets
  result.sort(proc (x, y: SubRegItem): int = cmp(x.typ, y.typ))
