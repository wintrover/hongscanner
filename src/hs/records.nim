## Record envelope, kind classification and the single-seq contract.
## Contract: plan §3.0 (kinds) and §3.1 (one counter, gauge semantics).
## VS-2 adds two consumed subscription-evidence kinds (sub, ws_raw,
## schemas in sub_input.nim). The 12th kind is the P-run seal
## (daily_seed_manifest, REPLAY_CONTRACT §12.10): the record layer ignores
## it like the diagnostic kinds; replay audits it when
## config.preopen_universe declares a P-run.
import std/strutils
import hcj

type
  Kind* = enum
    kCalendar, kConfig, kWsFrame, kRestResp, kGap, kSessionEnd, kSub, kWsRaw,
    kOutFrame, kWsConn, kPong, kDailySeedManifest

  Record* = object
    seq*: int
    kind*: Kind
    raw*: HcjValue

  RecordError* = object of CatchableError

const
  consumedKinds* = {kCalendar, kConfig, kWsFrame, kRestResp, kGap, kSessionEnd,
                    kSub, kWsRaw}
  ignoredKinds* = {kOutFrame, kWsConn, kPong, kDailySeedManifest}

proc rerr(msg: string): ref RecordError = newException(RecordError, msg)

proc kindName*(k: Kind): string =
  case k
  of kCalendar: "calendar"
  of kConfig: "config"
  of kWsFrame: "ws_frame"
  of kRestResp: "rest_resp"
  of kGap: "gap"
  of kSessionEnd: "session_end"
  of kSub: "sub"
  of kWsRaw: "ws_raw"
  of kOutFrame: "out_frame"
  of kWsConn: "ws_conn"
  of kPong: "pong"
  of kDailySeedManifest: "daily_seed_manifest"

proc parseKind*(s: string): Kind =
  case s
  of "calendar": kCalendar
  of "config": kConfig
  of "ws_frame": kWsFrame
  of "rest_resp": kRestResp
  of "gap": kGap
  of "session_end": kSessionEnd
  of "sub": kSub
  of "ws_raw": kWsRaw
  of "out_frame": kOutFrame
  of "ws_conn": kWsConn
  of "pong": kPong
  of "daily_seed_manifest": kDailySeedManifest
  else: raise rerr("unknown kind: " & s)

proc makeRecordLine*(seqNo: int; kind: Kind; raw: HcjValue): string =
  let obj = hObj(("kind", hStr(kindName(kind))), ("raw", raw), ("seq", hInt(seqNo)))
  canonical(obj)

proc parseRecord*(line: string; expectedSeq: int): Record =
  let v = parseLine(line)
  if v.kind != hkObj:
    raise rerr("record is not an object at seq " & $expectedSeq)
  let seqNode = v.get("seq")
  if seqNode.kind != hkInt:
    raise rerr("seq is not an integer at record " & $expectedSeq)
  let gotSeq = int(seqNode.ival)
  if gotSeq != expectedSeq:
    raise rerr("seq discontinuity: expected " & $expectedSeq & " got " & $gotSeq)
  if not v.has("kind") or not v.has("raw"):
    raise rerr("record missing kind/raw at seq " & $expectedSeq)
  result = Record(seq: gotSeq, kind: parseKind(v.get("kind").asStr), raw: v.get("raw"))

proc loadRecords*(path: string): seq[Record] =
  let lines = readHcjTextLines(path)
  for i, line in lines:
    result.add(parseRecord(line, i + 1))

proc validateRecords*(recs: seq[Record]) =
  ## Fixed preamble, contiguous seq, and session_end (when present) exactly
  ## once as the last record. A missing session_end is *not* a contract
  ## violation: it means the run is INCOMPLETE (exit 4), not REJECT (exit 2).
  if recs.len < 2:
    raise rerr("input stream too short: " & $recs.len)
  if recs[0].kind != kCalendar:
    raise rerr("seq 1 must be calendar")
  if recs[1].kind != kConfig:
    raise rerr("seq 2 must be config")
  var endCount = 0
  for i, r in recs:
    if r.seq != i + 1:
      raise rerr("seq discontinuity at index " & $i)
    if i >= 2 and (r.kind == kCalendar or r.kind == kConfig):
      raise rerr("preamble record at index " & $i & " (only seq 1/2 allowed)")
    if r.kind == kSessionEnd:
      inc endCount
      if i != recs.len - 1:
        raise rerr("session_end must be the last record")
  if endCount > 1:
    raise rerr("session_end must appear at most once, found " & $endCount)