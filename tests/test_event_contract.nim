## event contract tests (REPLAY_CONTRACT §13, VS-3 target): the immutable
## event fact record (contracts/events/event.schema.json) and the separate
## operational delivery record (contracts/events/delivery.schema.json).
## Covered: the closed field set (any verification or delivery field is
## rejected — the immutability rule), the full contract vocabularies, the
## committed valid fixture (canonical bytes + structure + id binding),
## structural rejections, the deterministic x-event-id-rule (pinned
## canonical serialization and sha256), and the three-state separation
## (importance/trust are fact fields, verification is session-level,
## delivery is operational — no field encodes two of them).
##
## Hand-rolled validation: no jsonschema dependency; the schemas are read
## with the repo's own strict HCJ parser.
## Synthetic only: no network, no vendor data, no wall clock.
## Run: nim c -r --hints:off --warnings:off --path:src tests/test_event_contract.nim
import std/[os, strutils]
import hs/[hcj, digest, sub_input]

var failures = 0
var passes = 0

proc check(name: string; cond: bool) =
  if cond:
    inc passes
    echo "ok   ", name
  else:
    inc failures
    echo "FAIL ", name

# ---------------------------------------------------------------- contract

const
  ## The full contract vocabularies. The contract defines all of them; an
  ## implementation may lag, the vocabulary never depends on it.
  eventTypes = @["CANDIDATE_ENTERED", "CANDIDATE_UPDATED",
                 "CANDIDATE_EXITED", "TOP10_ENTERED", "TOP10_EXITED",
                 "RANK_CHANGED", "FEED_DISCONNECTED",
                 "DATA_GAP_SUSPECTED", "REST_TRUNCATED",
                 "SUBSCRIPTION_TRUNCATED", "MARKET_STATE_UNKNOWN",
                 "REPLAY_MATCH", "REPLAY_MISMATCH",
                 "SESSION_ENDED", "SESSION_INCOMPLETE", "SESSION_APPROVED"]
  dataQualities = @["OBSERVING", "INCOMPLETE", "UNKNOWN"]
  severities = @["INFO", "HIGH", "CRITICAL"]
  directions = @["UP", "DOWN"]
  deliveryStates = @["PENDING", "ACCEPTED", "FAILED"]
  eventFields = @["data_quality", "direction", "event_id", "event_type",
                  "evidence_ref", "name", "observed_at", "previous_rank",
                  "rank", "rule_id", "rule_version", "session_id",
                  "severity", "symbol"]
  requiredEventFields = @["data_quality", "event_id", "event_type",
                          "evidence_ref", "observed_at", "rule_id",
                          "rule_version", "session_id", "severity"]
  deliveryFields = @["attempts", "device_id", "error_code", "event_id",
                     "provider_message_id", "state", "updated_at"]
  requiredDeliveryFields = @["attempts", "device_id", "event_id", "state",
                             "updated_at"]
  ## The x-event-id-rule pinned at the committed fixture's tuple:
  ## (2026-10-29, CANDIDATE_ENTERED, candidate-enter-v1, 005930, seq 7).
  pinnedIdTupleCanonical = "{\"entity\":\"005930\"," &
    "\"event_type\":\"CANDIDATE_ENTERED\",\"rule_id\":" &
    "\"candidate-enter-v1\",\"session_id\":\"2026-10-29\"," &
    "\"transition_seq\":7}"
  pinnedEventId = "a5e99fe72be4f3b8ef4cda2ad8a14a60da8ffadccba2b33fa885831604aef85f"

# ----------------------------------------------------------------- helpers

proc dropKey(v: HcjValue; key: string) =
  var keep: seq[HcjPair]
  for p in v.pairs:
    if p.k != key: keep.add(p)
  v.pairs = keep

proc setType(v: HcjValue; key: string; val: HcjValue) =
  for p in v.pairs.mitems:
    if p.k == key: p.v = val

proc eventIdOf(sessionId, eventType, ruleId, entity: string;
               transitionSeq: int64): string =
  ## x-event-id-rule: sha256 (lowercase hex) over the HCJ canonical
  ## serialization of the id tuple; keys in canonical codepoint order.
  let t = hObj(("entity", hStr(entity)),
               ("event_type", hStr(eventType)),
               ("rule_id", hStr(ruleId)),
               ("session_id", hStr(sessionId)),
               ("transition_seq", hInt(transitionSeq)))
  result = sha256Hex(canonical(t))

proc validateEvent(v: HcjValue): seq[string] =
  ## Hand-rolled structural validation of one event fact record against
  ## contracts/events/event.schema.json: closed field set, required
  ## fields, types, enums, formats. Empty result = valid. An unknown
  ## field is the immutability rule (x-immutability-rule): any
  ## verification or delivery field is rejected by name.
  if v.kind != hkObj:
    return @["event: not an object: " & v.kindName]
  for p in v.pairs:
    if not eventFields.contains(p.k):
      result.add("event: unknown field: " & p.k)
  for k in requiredEventFields:
    if not v.has(k):
      result.add("event: missing field: " & k)
  if v.has("event_id"):
    let x = v.get("event_id")
    if x.kind != hkStr:
      result.add("event: event_id is not a string")
    elif not validSha256Hex(x.strVal):
      result.add("event: event_id is not 64 lowercase hex: " & x.strVal)
  if v.has("event_type"):
    let x = v.get("event_type")
    if x.kind != hkStr or not eventTypes.contains(x.strVal):
      result.add("event: event_type is not a contract event type")
  if v.has("observed_at"):
    let x = v.get("observed_at")
    if x.kind != hkStr:
      result.add("event: observed_at is not a string")
    elif not validIso8601Offset(x.strVal):
      result.add("event: observed_at is not YYYY-MM-DDTHH:MM:SS+HH:MM")
  for k in ["session_id", "rule_id", "evidence_ref"]:
    if v.has(k):
      let x = v.get(k)
      if x.kind != hkStr or x.strVal.len == 0:
        result.add("event: " & k & " is not a non-empty string")
  if v.has("rule_version"):
    let x = v.get("rule_version")
    if x.kind != hkInt:
      result.add("event: rule_version is not an integer")
    elif x.ival < 1:
      result.add("event: rule_version must be >= 1")
  if v.has("symbol"):
    let x = v.get("symbol")
    if x.kind != hkStr or not validCode(x.strVal):
      result.add("event: symbol is not a 6-digit code")
  if v.has("direction"):
    let x = v.get("direction")
    if x.kind != hkStr or not directions.contains(x.strVal):
      result.add("event: direction is not UP|DOWN")
  if v.has("rank"):
    let x = v.get("rank")
    if x.kind != hkInt:
      result.add("event: rank is not an integer")
    elif x.ival < 1:
      result.add("event: rank must be >= 1")
  if v.has("previous_rank"):
    let x = v.get("previous_rank")
    if x.kind != hkInt:
      result.add("event: previous_rank is not an integer")
    elif x.ival < 1:
      result.add("event: previous_rank must be >= 1")
  if v.has("name"):
    let x = v.get("name")
    if x.kind != hkStr or x.strVal.len == 0:
      result.add("event: name is not a non-empty string")
  if v.has("data_quality"):
    let x = v.get("data_quality")
    if x.kind != hkStr or not dataQualities.contains(x.strVal):
      result.add("event: data_quality is not OBSERVING|INCOMPLETE|UNKNOWN")
  if v.has("severity"):
    let x = v.get("severity")
    if x.kind != hkStr or not severities.contains(x.strVal):
      result.add("event: severity is not INFO|HIGH|CRITICAL")

proc validateDelivery(v: HcjValue): seq[string] =
  ## Same hand-rolled approach against contracts/events/delivery.schema.json.
  if v.kind != hkObj:
    return @["delivery: not an object: " & v.kindName]
  for p in v.pairs:
    if not deliveryFields.contains(p.k):
      result.add("delivery: unknown field: " & p.k)
  for k in requiredDeliveryFields:
    if not v.has(k):
      result.add("delivery: missing field: " & k)
  if v.has("event_id"):
    let x = v.get("event_id")
    if x.kind != hkStr:
      result.add("delivery: event_id is not a string")
    elif not validSha256Hex(x.strVal):
      result.add("delivery: event_id is not 64 lowercase hex: " & x.strVal)
  if v.has("device_id"):
    let x = v.get("device_id")
    if x.kind != hkStr or x.strVal.len == 0:
      result.add("delivery: device_id is not a non-empty string")
  if v.has("state"):
    let x = v.get("state")
    if x.kind != hkStr or not deliveryStates.contains(x.strVal):
      result.add("delivery: state is not PENDING|ACCEPTED|FAILED")
  if v.has("attempts"):
    let x = v.get("attempts")
    if x.kind != hkInt:
      result.add("delivery: attempts is not an integer")
    elif x.ival < 0:
      result.add("delivery: attempts must be >= 0")
  if v.has("updated_at"):
    let x = v.get("updated_at")
    if x.kind != hkStr:
      result.add("delivery: updated_at is not a string")
    elif not validIso8601Offset(x.strVal):
      result.add("delivery: updated_at is not YYYY-MM-DDTHH:MM:SS+HH:MM")
  for k in ["provider_message_id", "error_code"]:
    if v.has(k):
      let x = v.get(k)
      if x.kind != hkStr or x.strVal.len == 0:
        result.add("delivery: " & k & " is not a non-empty string")

# ---------------------------------------------------------------- builders

proc validEventHcj(): HcjValue =
  ## The committed fixture (fixtures/events/valid_event.hcj.jsonl) as an
  ## inline value: same fields, same id.
  hObj(("data_quality", hStr("OBSERVING")),
       ("direction", hStr("UP")),
       ("event_id", hStr(pinnedEventId)),
       ("event_type", hStr("CANDIDATE_ENTERED")),
       ("evidence_ref", hStr("ka10027:stex_tp=1:sort_tp=1")),
       ("observed_at", hStr("2026-10-29T09:00:05+09:00")),
       ("rank", hInt(1)),
       ("rule_id", hStr("candidate-enter-v1")),
       ("rule_version", hInt(1)),
       ("session_id", hStr("2026-10-29")),
       ("severity", hStr("INFO")),
       ("symbol", hStr("005930")))

proc acceptedDeliveryHcj(): HcjValue =
  hObj(("attempts", hInt(1)),
       ("device_id", hStr("hs-device-0001")),
       ("event_id", hStr(pinnedEventId)),
       ("provider_message_id", hStr("projects/hong-scanner/messages/8911")),
       ("state", hStr("ACCEPTED")),
       ("updated_at", hStr("2026-10-29T09:00:06+09:00")))

proc failedDeliveryHcj(): HcjValue =
  hObj(("attempts", hInt(3)),
       ("device_id", hStr("hs-device-0001")),
       ("error_code", hStr("UNREGISTERED")),
       ("event_id", hStr(pinnedEventId)),
       ("state", hStr("FAILED")),
       ("updated_at", hStr("2026-10-29T09:00:07+09:00")))

proc pendingDeliveryHcj(): HcjValue =
  hObj(("attempts", hInt(0)),
       ("device_id", hStr("hs-device-0001")),
       ("event_id", hStr(pinnedEventId)),
       ("state", hStr("PENDING")),
       ("updated_at", hStr("2026-10-29T09:00:05+09:00")))

proc eventRejected(name, needle: string; body: proc (): HcjValue) =
  let vs = validateEvent(body())
  check(name & " (rejects: " & needle & ")",
        vs.len == 1 and needle in vs[0])

proc deliveryRejected(name, needle: string; body: proc (): HcjValue) =
  let vs = validateDelivery(body())
  check(name & " (rejects: " & needle & ")",
        vs.len == 1 and needle in vs[0])

proc enumOf(schema: HcjValue; prop: string): seq[string] =
  ## The schema's declared enum values for one property, in declared order.
  let e = schema.get("properties").get(prop).get("enum")
  for x in e.items:
    result.add(x.asStr)

proc propNames(schema: HcjValue): seq[string] =
  for p in schema.get("properties").pairs:
    result.add(p.k)

proc hasSubstr(names: seq[string]; needle: string): bool =
  for n in names:
    if needle in n: return true
  false

# ------------------------------------------------------------ schema files

let repoRoot = parentDir(parentDir(getAppFilename()))
let eventSchemaPath = repoRoot / "contracts" / "events" / "event.schema.json"
let deliverySchemaPath = repoRoot / "contracts" / "events" / "delivery.schema.json"
let eventSchema = readDocFile(eventSchemaPath)
let deliverySchema = readDocFile(deliverySchemaPath)

block schemaFiles:
  check("schema: the event fact schema file exists", fileExists(eventSchemaPath))
  check("schema: the delivery schema file exists",
        fileExists(deliverySchemaPath))
  check("schema: both schema files parse as strict HCJ JSON documents",
        eventSchema.kind == hkObj and deliverySchema.kind == hkObj)
  check("schema: the schemas declare their identities",
        eventSchema.get("x-schema-id").asStr == "hong-scanner-event-fact/1" and
        deliverySchema.get("x-schema-id").asStr ==
        "hong-scanner-event-delivery/1")
  check("schema: both schemas are closed objects (additionalProperties false)",
        eventSchema.get("additionalProperties").asBool == false and
        deliverySchema.get("additionalProperties").asBool == false)
  check("schema: the immutability rule is stated in the fact schema",
        "verification_status" in
          eventSchema.get("x-immutability-rule").asStr and
        "delivery" in eventSchema.get("x-immutability-rule").asStr)
  check("schema: the deterministic event id rule is stated in the schema",
        "sha256" in eventSchema.get("x-event-id-rule").asStr and
        "canonical" in eventSchema.get("x-event-id-rule").asStr and
        "transition_seq" in eventSchema.get("x-event-id-rule").asStr)
  check("schema: the delivery schema is declared separate and mutable",
        "separate" in deliverySchema.get("description").asStr and
        "never" in deliverySchema.get("x-separation-rule").asStr)
  check("schema: device_id never carries the provider token itself",
        "Never" in deliverySchema.get("properties").get("device_id")
          .get("description").asStr and
        "token" in deliverySchema.get("properties").get("device_id")
          .get("description").asStr)

block enumCompleteness:
  check("enum: the contract vocabulary is exactly 16 event types",
        eventTypes.len == 16)
  check("enum: event_type is the full contract vocabulary",
        enumOf(eventSchema, "event_type") == eventTypes)
  check("enum: data_quality is OBSERVING|INCOMPLETE|UNKNOWN",
        enumOf(eventSchema, "data_quality") == dataQualities)
  check("enum: severity is INFO|HIGH|CRITICAL",
        enumOf(eventSchema, "severity") == severities)
  check("enum: direction is UP|DOWN",
        enumOf(eventSchema, "direction") == directions)
  check("enum: delivery state is PENDING|ACCEPTED|FAILED",
        enumOf(deliverySchema, "state") == deliveryStates)
  check("schema: the input seq is never an emitted fact field",
        not eventSchema.get("properties").has("transition_seq"))

# ----------------------------------------------------------------- fixture

let fixturePath = repoRoot / "fixtures" / "events" / "valid_event.hcj.jsonl"

block validFixture:
  check("fixture: the committed valid fixture exists", fileExists(fixturePath))
  let rawLines = readHcjTextLines(fixturePath)
  let events = readHcjLines(fixturePath)
  check("fixture: exactly one committed event",
        rawLines.len == 1 and events.len == 1)
  check("fixture: the committed line is byte-canonical HCJ",
        canonical(events[0]) == rawLines[0])
  check("fixture: the committed fixture passes structural validation",
        validateEvent(events[0]).len == 0)
  check("fixture: the fixture's event_id equals the rule over its tuple",
        events[0].get("event_id").asStr ==
        eventIdOf("2026-10-29", "CANDIDATE_ENTERED", "candidate-enter-v1",
                  "005930", 7))
  check("fixture: the fact carries no verification or delivery field",
        not events[0].has("verification_status") and
        not events[0].has("state") and not events[0].has("attempts"))
  check("fixture: the fact carries no position field",
        not events[0].has("transition_seq"))

# -------------------------------------------------------- event rejections

block eventRejections:
  eventRejected("a wrong event_type is rejected", "is not a contract event type",
          proc (): HcjValue =
            var v = validEventHcj()
            setType(v, "event_type", hStr("CANDIDATE_REMOVED"))
            v)
  for bad in ["63chars0000000000000000000000000000000000000000000000000000",
               repeat('A', 64), "0g" & repeat('0', 62), ""]:
    eventRejected("a non-hex event_id is rejected: " &
              (if bad.len == 0: "(empty)" else: bad.substr(0, 15) & "..."),
              "is not 64 lowercase hex",
              proc (): HcjValue =
                var v = validEventHcj()
                setType(v, "event_id", hStr(bad))
                v)
  eventRejected("a verification_status field is rejected (the immutability " &
                "rule)", "unknown field: verification_status",
          proc (): HcjValue =
            var v = validEventHcj()
            v.pairs.add(("verification_status", hStr("UNVERIFIED")))
            v)
  for k in ["state", "attempts", "device_id", "delivery_state"]:
    eventRejected("a delivery-state field is rejected in the fact: " & k,
              "unknown field: " & k,
              proc (): HcjValue =
                var v = validEventHcj()
                v.pairs.add((k, if k == "attempts": hInt(1) else: hStr("x")))
                v)
  for bad in ["2026-10-29T09:00:00Z", "2026-10-29 09:00:00+09:00",
              "2026-10-29T09:00:00", "2026-13-29T09:00:00+09:00",
              "not a timestamp", ""]:
    eventRejected("a bad observed_at format is rejected: " &
              (if bad.len == 0: "(empty)" else: bad),
              "is not YYYY-MM-DDTHH:MM:SS+HH:MM",
              proc (): HcjValue =
                var v = validEventHcj()
                setType(v, "observed_at", hStr(bad))
                v)

block eventFieldRules:
  for k in requiredEventFields:
    eventRejected("a missing " & k & " is rejected", "missing field: " & k,
            proc (): HcjValue =
              var v = validEventHcj()
              dropKey(v, k)
              v)
  eventRejected("a string rule_version is rejected", "is not an integer",
          proc (): HcjValue =
            var v = validEventHcj()
            setType(v, "rule_version", hStr("1"))
            v)
  eventRejected("rule_version 0 is rejected", "must be >= 1",
          proc (): HcjValue =
            var v = validEventHcj()
            setType(v, "rule_version", hInt(0))
            v)
  eventRejected("a string rank is rejected", "is not an integer",
          proc (): HcjValue =
            var v = validEventHcj()
            setType(v, "rank", hStr("1"))
            v)
  eventRejected("rank 0 is rejected", "must be >= 1",
          proc (): HcjValue =
            var v = validEventHcj()
            setType(v, "rank", hInt(0))
            v)
  eventRejected("a data_quality outside the enum is rejected",
          "is not OBSERVING|INCOMPLETE|UNKNOWN",
          proc (): HcjValue =
            var v = validEventHcj()
            setType(v, "data_quality", hStr("TRUSTED"))
            v)
  eventRejected("a severity outside the enum is rejected",
          "is not INFO|HIGH|CRITICAL",
          proc (): HcjValue =
            var v = validEventHcj()
            setType(v, "severity", hStr("FATAL"))
            v)
  eventRejected("a direction outside UP|DOWN is rejected", "is not UP|DOWN",
          proc (): HcjValue =
            var v = validEventHcj()
            setType(v, "direction", hStr("SIDEWAYS"))
            v)
  eventRejected("a non-6-digit symbol is rejected", "is not a 6-digit code",
          proc (): HcjValue =
            var v = validEventHcj()
            setType(v, "symbol", hStr("5930"))
            v)
  for k in ["session_id", "rule_id", "evidence_ref"]:
    eventRejected("an empty " & k & " is rejected", "is not a non-empty string",
            proc (): HcjValue =
              var v = validEventHcj()
              setType(v, k, hStr(""))
              v)
  for bad in [hStr("later"), hArr(hStr("CANDIDATE_ENTERED")), hNull(),
              hInt(1)]:
    eventRejected("a non-object fact is rejected: " & bad.kindName,
            "not an object",
            proc (): HcjValue = bad)

block top10FieldRules:
  ## The top10-transition facts' optional judgment fields: previous_rank
  ## (the rank in the previous confirmed observation group) and name (the
  ## vendor row's preserved stk_nm) — closed fields of the fact record,
  ## emitted only when judged, never verified or delivered anywhere.
  proc top10EventHcj(): HcjValue =
    hObj(("data_quality", hStr("OBSERVING")),
         ("direction", hStr("UP")),
         ("event_id", hStr(pinnedEventId)),
         ("event_type", hStr("TOP10_ENTERED")),
         ("evidence_ref", hStr("ka10027:stex_tp=1:sort_tp=1")),
         ("name", hStr("삼성전자")),
         ("observed_at", hStr("2026-10-29T09:00:05+09:00")),
         ("previous_rank", hInt(11)),
         ("rank", hInt(10)),
         ("rule_id", hStr("top10-transition-v1")),
         ("rule_version", hInt(1)),
         ("session_id", hStr("2026-10-29")),
         ("severity", hStr("INFO")),
         ("symbol", hStr("005930")))
  check("a TOP10 fact with previous_rank and name passes validation",
        validateEvent(top10EventHcj()).len == 0)
  check("the schema declares both optional judgment fields",
        propNames(eventSchema).contains("previous_rank") and
        propNames(eventSchema).contains("name"))
  eventRejected("a string previous_rank is rejected", "is not an integer",
          proc (): HcjValue =
            var v = top10EventHcj()
            setType(v, "previous_rank", hStr("11"))
            v)
  eventRejected("previous_rank 0 is rejected", "must be >= 1",
          proc (): HcjValue =
            var v = top10EventHcj()
            setType(v, "previous_rank", hInt(0))
            v)
  eventRejected("an empty name is rejected", "is not a non-empty string",
          proc (): HcjValue =
            var v = top10EventHcj()
            setType(v, "name", hStr(""))
            v)
  check("previous_rank and name are optional, never required",
        (block:
           var v = top10EventHcj()
           dropKey(v, "previous_rank")
           dropKey(v, "name")
           validateEvent(v).len == 0))

# --------------------------------------------------------- event id rule

block eventIdDeterminism:
  let id = eventIdOf("2026-10-29", "CANDIDATE_ENTERED", "candidate-enter-v1",
                     "005930", 7)
  check("event_id: the canonical serialization is pinned (key order, " &
        "no whitespace, bare integer)",
        canonical(hObj(("entity", hStr("005930")),
                       ("event_type", hStr("CANDIDATE_ENTERED")),
                       ("rule_id", hStr("candidate-enter-v1")),
                       ("session_id", hStr("2026-10-29")),
                       ("transition_seq", hInt(7)))) == pinnedIdTupleCanonical)
  check("event_id: the pinned id is sha256 of the pinned canonical bytes",
        sha256Hex(pinnedIdTupleCanonical) == pinnedEventId)
  check("event_id: the rule reproduces the pinned id", id == pinnedEventId)
  check("event_id: the same tuple yields the same id (determinism)",
        id == eventIdOf("2026-10-29", "CANDIDATE_ENTERED",
                        "candidate-enter-v1", "005930", 7))
  check("event_id: a differing transition_seq yields a different id",
        id != eventIdOf("2026-10-29", "CANDIDATE_ENTERED",
                        "candidate-enter-v1", "005930", 8))
  check("event_id: a differing entity yields a different id",
        id != eventIdOf("2026-10-29", "CANDIDATE_ENTERED",
                        "candidate-enter-v1", "000660", 7))
  check("event_id: the wildcard entity differs from a symbol entity",
        eventIdOf("2026-10-29", "SESSION_ENDED", "session-close-v1", "*", 7) !=
        eventIdOf("2026-10-29", "SESSION_ENDED", "session-close-v1",
                  "005930", 7))
  check("event_id: a differing event_type yields a different id",
        id != eventIdOf("2026-10-29", "CANDIDATE_UPDATED",
                        "candidate-enter-v1", "005930", 7))
  check("event_id: a differing rule_id yields a different id",
        id != eventIdOf("2026-10-29", "CANDIDATE_ENTERED",
                        "candidate-enter-v2", "005930", 7))
  check("event_id: a differing session_id yields a different id",
        id != eventIdOf("2026-10-30", "CANDIDATE_ENTERED",
                        "candidate-enter-v1", "005930", 7))
  check("event_id: the id is 64 lowercase hex", validSha256Hex(id))

# -------------------------------------------------------- delivery record

block deliveryRecord:
  check("delivery: a PENDING record passes structural validation",
        validateDelivery(pendingDeliveryHcj()).len == 0)
  check("delivery: an ACCEPTED record with provider_message_id passes",
        validateDelivery(acceptedDeliveryHcj()).len == 0)
  check("delivery: a FAILED record with error_code passes",
        validateDelivery(failedDeliveryHcj()).len == 0)
  deliveryRejected("a state outside the enum is rejected",
             "is not PENDING|ACCEPTED|FAILED",
             proc (): HcjValue =
               var v = acceptedDeliveryHcj()
               setType(v, "state", hStr("SENT"))
               v)
  deliveryRejected("a missing state is rejected", "missing field: state",
             proc (): HcjValue =
               var v = acceptedDeliveryHcj()
               dropKey(v, "state")
               v)
  deliveryRejected("negative attempts are rejected", "must be >= 0",
             proc (): HcjValue =
               var v = pendingDeliveryHcj()
               setType(v, "attempts", hInt(-1))
               v)
  deliveryRejected("a string attempts is rejected", "is not an integer",
             proc (): HcjValue =
               var v = pendingDeliveryHcj()
               setType(v, "attempts", hStr("0"))
               v)
  deliveryRejected("a bad updated_at format is rejected",
             "is not YYYY-MM-DDTHH:MM:SS+HH:MM",
             proc (): HcjValue =
               var v = pendingDeliveryHcj()
               setType(v, "updated_at", hStr("2026-10-29T09:00:05Z"))
               v)
  deliveryRejected("an uppercase event_id is rejected",
             "is not 64 lowercase hex",
             proc (): HcjValue =
               var v = pendingDeliveryHcj()
               setType(v, "event_id", hStr(repeat('F', 64)))
               v)
  deliveryRejected("an empty device_id is rejected",
             "is not a non-empty string",
             proc (): HcjValue =
               var v = pendingDeliveryHcj()
               setType(v, "device_id", hStr(""))
               v)
  deliveryRejected("an empty provider_message_id is rejected",
             "is not a non-empty string",
             proc (): HcjValue =
               var v = acceptedDeliveryHcj()
               setType(v, "provider_message_id", hStr(""))
               v)
  deliveryRejected("an empty error_code is rejected",
             "is not a non-empty string",
             proc (): HcjValue =
               var v = failedDeliveryHcj()
               setType(v, "error_code", hStr(""))
               v)
  for k in ["severity", "data_quality", "verification_status"]:
    deliveryRejected("a fact or verification field is rejected in the " &
                     "delivery record: " & k, "unknown field: " & k,
             proc (): HcjValue =
               var v = pendingDeliveryHcj()
               v.pairs.add((k, hStr("x")))
               v)
  deliveryRejected("a non-object delivery record is rejected",
             "not an object",
             proc (): HcjValue = hStr("PENDING"))

# -------------------------------------------------- three-state separation

block threeStateSeparation:
  let factProps = propNames(eventSchema)
  let deliveryProps = propNames(deliverySchema)
  const importanceTrust = ["data_quality", "severity"]
  const deliveryFamily = ["state", "attempts", "error_code",
                          "provider_message_id", "device_id"]
  const judgmentFields = ["direction", "rank", "rule_id", "rule_version"]
  for f in importanceTrust:
    check("separation: " & f & " is a fact field and never a delivery field",
          factProps.contains(f) and not deliveryProps.contains(f))
  for f in judgmentFields:
    check("separation: " & f & " is a judgment field and never a delivery " &
          "field", factProps.contains(f) and not deliveryProps.contains(f))
  for f in deliveryFamily:
    check("separation: " & f & " is a delivery field and never a fact field",
          deliveryProps.contains(f) and not factProps.contains(f))
  check("separation: no verification field exists in the fact schema",
        not hasSubstr(factProps, "verif"))
  check("separation: no verification field exists in the delivery schema",
        not hasSubstr(deliveryProps, "verif"))
  check("separation: the schemas state the three-home rule",
        "three homes" in eventSchema.get("x-separation-rule").asStr and
        "verification" in deliverySchema.get("x-separation-rule").asStr)
  block:
    var factCarriesNoDelivery = true
    for p in validEventHcj().pairs:
      if deliveryFamily.contains(p.k): factCarriesNoDelivery = false
    check("separation: the committed fact's field set carries no delivery " &
          "state", factCarriesNoDelivery)

# ----------------------------------------------------------------- summary

if failures == 0:
  echo "EVENT CONTRACT PASSED (", passes, " checks)"
else:
  echo "EVENT CONTRACT FAILED: ", failures, " of ", passes + failures
  quit(1)
