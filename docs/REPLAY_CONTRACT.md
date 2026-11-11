# Hong Scanner — Replay Contract (VS-1 baseline, VS-2/VS-3 targets, v6.5)

This document states the intended VS-1 contract. Tests cover selected cases;
passing them does not prove every statement or replace review of the actual
implementation.

## 1. Purpose

Given the same input stream, the same binary and the same calendar, Core must
produce byte-identical `bars.hcj.jsonl` and `signals.hcj.jsonl`. Provenance
checks consistency with the binary's self-declared build metadata; it does not
independently prove that the binary came from canonical main.

## 2. Input stream

One file, `input.hcj.jsonl`, one HCJ document per line.

- Encoding: UTF-8, LF line endings, every line ends with LF. BOM, CRLF and
  blank lines are rejected (`hcj.readHcjTextLines`).
- Envelope: `{"kind":<string>,"raw":<value>,"seq":<int>}`, canonical key order.
- `seq` is a **gauge**: it proves physical order and detects loss, reordering
  and duplication. Its absolute value is never emitted in any artifact.
- Rule 1: `seq` must be `1..N` in physical file order (`REJECT`, exit 2).
- Rule 2: records 1 and 2 are always `calendar` and `config`. No other
  `calendar`/`config` record is allowed (`REJECT`, exit 2).
- Rule 3: diagnostic records may be inserted or deleted **after record 2**
  and the remaining records renumbered. This operation must not change one
  output byte (`NO_EFFECT`).

## 3. Record kinds

Exactly eleven kinds exist. Unknown kinds are rejected (exit 2).

Consumed by Core (eight):

| kind | role |
|---|---|
| `calendar` | session days; `days[date].open/close` are the only source of session bounds |
| `config` | `session_date` (required) + `params`; `run_id` (optional) — the run directory's basename; the only source of the run date |
| `ws_frame` | one trade tick: `symbol`, `t` (`HH:MM:SS+09:00`), `price` (int), `vol` (cumulative int), `m` (field 290, optional) |
| `rest_resp` | terminal record of one REST attempt (success, HTTP/vendor error, or transport failure) |
| `sub` | one subscription request or acknowledgement (validated acceptance) |
| `ws_raw` | one preserved WebSocket application payload, hex-encoded (validated acceptance) |
| `gap` | `symbol` (string or null) — a period whose data cannot be trusted |
| `session_end` | explicit normal close; `raw` is `null` |

Ignored by Core (three, diagnostic only):

`out_frame`, `ws_conn`, `pong`.

`ws_conn` describes how a connection changed; `gap` describes which data is
untrustworthy. They are recorded separately and only `gap` has authority.

Until a live producer is measured, `rest_resp`, `sub` and `ws_raw` follow a
**validated acceptance path**: each record parses against its declared
schema (§12.1 for `rest_resp`; the `sub_input` rules for `sub`/`ws_raw`,
documented in §12.6/§12.7) and the complete stream's declared page chains
are audited. A record that fails its schema rejects the run at its own seq
(exit 2); a chain-level failure rejects the whole stream. Verified records
are counted (`restVerified`, `subCount`, `wsRawCount`) and change no output
byte. The live wire format itself is still unmeasured (G2/G4).

## 4. Session-class (field 290)

`m` carries the vendor session flag (`1` pre-market, `2` regular, `3` post).
The calendar window is a fail-closed detector, not a fallback.

| condition | class | effect |
|---|---|---|
| `m=="2"` and `open <= t <= close` | `in_session` | tick enters a bar |
| `m in {"1","3"}` and (`t < open` or `t > close`) | `out_of_session` | excluded, counted |
| any other combination | `conflict` | excluded, counted, affected interval degraded |
| `m` missing or unknown | `unknown` | excluded, counted, affected interval degraded |

A conflict never picks a side. If `conflicts / frames > 0.5%`, the round is
aborted: `VERDICT INVALID provenance=UNRELIABLE` (exit 5). The affected
interval is marked degraded only when a bar exists for it; no bar is invented.

## 5. Bars

```
i(t) = floor((t - open) / 180s)          interval [open+180i, open+180(i+1))
t == close  -> i = n_bars-1, close_boundary = true
t < open or t > close -> out_of_session (excluded)
(close - open) mod 180 != 0 -> SESSION_NOT_BAR_ALIGNED (exit 3)
```

`n_bars = (close - open) / 180` comes from the calendar; no 09:00/15:30
constant exists in code. `09:03:00` is bar 1; `15:30:00` is the last bar with
`close_boundary`; `15:30:01` is out of session (or a conflict if `m=="2"`).

Volume is a **boundary difference** of the cumulative field, not a sum:
`vol(bar n) = cum(last frame of bar n) - cum(last frame of bar n-1)`.
A negative delta is clamped to 0 and marks the bar degraded. The first
observation of a symbol contributes 0 and marks the bar `vol_partial`.

`bar_position` values: `first_after_sub`, `steady`, `after_gap`, `empty_gap`.
`first_after_sub` and `after_gap` are always `vol_partial` and `degraded`.

Bars are closed by the next bar's first frame, by a `gap`, or by
`session_end`. An in-session tick that belongs to an already closed bar
invalidates the whole run: `LATE_TICK_INTO_CLOSED_BAR` (exit 5). A backwards
tick inside the open bar only marks that bar `out_of_order` + `degraded`.
A conflicting or unknown session flag can currently mark an already-closed
bar degraded; this batch replay behavior does not establish a live signal
finality or retraction policy.

A `gap` closes the open bar as `gap_edge:"before"` and makes the next bar of
**each affected symbol** `after_gap`. A connection-wide gap (`symbol:null`)
marks each previously observed symbol; release is per symbol at that symbol's
own first later valid frame. An unresolved gap at session end is INCOMPLETE.
The current input contract does not include a subscription list, so symbols
that never produced a frame cannot be checked; live approval remains blocked.
(The target §12.6 `activeSets` derivation over `sub` records is the
basis the live subscription-set check will use.)

## 6. Signals

One symmetric judgment function serves both directions (frozen VS-A,
2026-11-06). `d=+1` is up, `d=−1` is down; the output vocabulary is
`bullish_pullback_reversal`, `bearish_rebound_failure`, and `SIGNAL_HELD`.
There is no `short`.

- Directional movement is `S_d = d × (P − P_ref)/P_ref × 10⁴` in bp against
  the declared reference price. Both directions share one absolute threshold
  family: `trend_min_bp` (trend confirmation), `countermove_min_bp`
  (pullback/rebound confirmation), `directional_trigger_bp` (final trigger).
  Per-direction thresholds are a contract violation.
- The structure is identical in both directions: (1) trend confirmation over
  the shared observation window (`warmup_bars`, `lookback_bars` — the same
  window for both directions), (2) counter-move confirmation from the
  direction's pivot, (3) resumption confirmation of at least
  `directional_trigger_bp` from the counter-move extreme. The reference
  series is close for both directions; pivot selection, tie-breaking when
  equal extremes repeat, and bar-eligibility rules are direction-symmetric.
- A tainted bar cannot support a verdict — identically in both directions.
  A verdict that depends on degraded, partial-volume, empty, out-of-order
  or gap-marked evidence is held until the affected bar leaves its window.
  With `hold_on_degraded`, `SIGNAL_HELD` reports the most recent tainted
  bar's reason; otherwise the verdict is suppressed. Real signals carry
  `reason:""`.
- Symmetry is testable: mirroring an input stream's prices around a fixed
  reference (P → 2·P_ref − P, equal-magnitude opposite moves) must produce
  the opposite-direction signal at the same bar indices under the same
  absolute thresholds. This mirror test is the acceptance test of the
  rewrite; a direction-exceptional success path is forbidden.
- Every signal references `(session_date, symbol, bar_index)` present in
  `bars.hcj.jsonl` with `closed:true`. A signal for an open bar is a contract
  violation (exit 2).
- Sort order is `(symbol, bar_index, signal)`; iteration order never leaks.

Runs sealed before the VS-1 symmetric rewrite (2026-11-06) were produced by
the legacy asymmetric engine; §8 check 1 replays each run only under its own
commit's binary, so those runs keep their legacy semantics and every run
sealed after the rewrite must satisfy §6.

## 7. Artifacts

`runs/<date>/` contains:

| file | deterministic | checksummed |
|---|---|---|
| `input.hcj.jsonl` | yes | yes |
| `bars.hcj.jsonl` | yes | yes |
| `events.hcj.jsonl` | yes | yes |
| `signals.hcj.jsonl` | yes | yes |
| `run.json` | no | no |
| `CHECKSUMS.sha256` | yes | — |

`CHECKSUMS.sha256` has exactly four lines, sorted by file name:
`<sha256hex>  <name>`, where the hash is over the file bytes.

`bars.hcj.jsonl` fields: `bar_index, bar_position, close, close_boundary,
closed, degraded, empty, gap_edge, high, low, open, out_of_order,
session_class, symbol, ticks, vol, vol_partial`.

`origin` is an optional bar field (P21, target §12.8): present only as
`origin:"BACKFILL"` on bars derived from ka10080 records; absent means
`LIVE`. Pre-contract streams and live-only runs stay byte-identical to the
old format.

`events.hcj.jsonl` fields: `data_quality, event_id, event_type, evidence_ref,
observed_at, rule_id, rule_version, session_id, severity` — plus `direction`
and `rank` on candidate-transition facts (EXITED carries no rank), `symbol`
on symbol-scoped facts, and on top10-transition facts (rule
`top10-transition-v1`) the previous confirmed group's rank as
`previous_rank` (absent when the symbol was not a candidate before) and the
vendor row's stock name as `name` (absent when the row carried none). Closed
facts: no record position, no verification or delivery state. See §13.

`signals.hcj.jsonl` fields: `bar_index, price, reason, session_date, signal,
symbol`.

`run.json` fields: `bar_count, build{build_time,dirty,nim_version,
origin_main_sha,source_ref}, calendar_sha256, code_commit, config_sha256,
contract_version, egress_ip, host, pid, run_id, session_date, signal_count,
started_at`. `contract_version` (added VS-A, 2026-11-06; P24) identifies
the input-stream contract generation; it is non-checksummed and absent on
pre-VS-A runs.

`config_sha256`/`calendar_sha256` are SHA-256 over the canonical bytes of
record 2 / record 1 **without** a trailing LF.

## 8. Provenance (five checks before any MATCH)

`verify` runs these against the verifying binary's embedded build info:

| # | check | failure |
|---|---|---|
| 1 | `run.json.code_commit` == binary `code_commit` | INVALID_PROVENANCE |
| 2 | `run.json.build.dirty == false` and binary `dirty == false` | INVALID_PROVENANCE |
| 3 | `run.json.build.nim_version` == binary `nim_version` | INVALID_PROVENANCE |
| 4 | `config_sha256` / `calendar_sha256` match records 2 / 1 | INVALID_PROVENANCE |
| 5 | `build.source_ref == "main"`, binary `source_ref == "main"`, and `origin_main_sha == code_commit` on both sides | INVALID_PROVENANCE |

The build gate (`tools/build.sh`) refuses to build unless the checkout is
`main`, clean, and `HEAD == origin/main`, then injects `code_commit`,
`source_ref`, `origin_main_sha` and `build_time` with `-d` switches. Any
plain `nim c` / `nimble build` keeps the dev marker (`dirty:true`,
`source_ref:"dev"`) and can never produce `provenance=OK`.

## 9. Exit codes

| code | meaning |
|---|---|
| 0 | `VERDICT MATCH provenance=OK` / command OK |
| 2 | contract violation (HCJ, record envelope, unknown kind, open-bar signal) |
| 3 | calendar (`CALENDAR_COVERAGE_UNKNOWN`, `SESSION_NOT_BAR_ALIGNED`) |
| 4 | `VERDICT INCOMPLETE` (no `session_end` or unresolved known-symbol gap) |
| 5 | invalid run (`LATE_TICK_INTO_CLOSED_BAR`, `SESSION_FLAG_UNRELIABLE`) |
| 6 | artifact mismatch (bytes or checksum manifest differ from replay) |
| 7 | invalid provenance |

## 10. Refutation classes (all covered by tests)

- `REJECT`: seq swap/duplicate, unknown kind, preamble violation,
  `session_end` not last.
- `EXPECTED_DELTA`: price change changes bars; volume regression holds the
  bar; 290 conflict holds the affected bar; `gap` degrades both edges.
- `NO_EFFECT`: inserting or rewriting `out_frame`/`ws_conn`/`pong` after
  record 2, with full renumbering, changes no output byte.
- `CLOCK_INVARIANT`: `TZ` does not affect output; Core has no clock input.

## 11. Two layers of reproducibility

**CI reproducibility** uses synthetic fixtures only and proves algorithm and
serialization stability. It never contacts a vendor or the network.

**Measured reproducibility** uses a real run directory: the input stream,
`run.json`, the calendar file that was in force (hash-pinned in
`calendars/CALENDAR_INDEX.sha256`) and the canonical binary. A third party
reproducing a measured run needs those files; the repository intentionally
does not contain market data.

Calendar authority is three separable evidences (P25): source match
(`tools/check_calendar_source.py`), integrity (the INDEX hash), and the
operator's explicit approval of the scope (first/last trading day). Byte
equality — an INDEX match or a restored copy's identical hash — is never
approval by itself.

`sha256` is a byte-identity tool. It is not evidence that prices are correct
(G4) or that the strategy is sound (PH-2).

## 12. Target additions beyond VS-1 (not implemented)

Everything in this section is **target contract**. VS-1 has no live REST or
WebSocket producer; `rest_resp` records are schema-audited (§3), not
live-verified. Passing VS-1 proves none
of the statements below, and none describes current live behavior.

### 12.1 Candidate selection (ka10027)

VS-2 candidate selection declares its query scope so that "candidate" stays
auditable:

- API: Kiwoom REST `ka10027` (전일대비등락률상위), `POST /api/dostk/rkinfo`.
- Exchange: `stex_tp="1"` (KRX). `2` (NXT) and `3` (통합) are outside the
  candidate universe.
- Code shape: the candidate universe is the rows whose `stk_cd` is exactly
  6 digits (`vendor_input.isCandidateCode`). The ranking mixes rows whose
  code is not that shape — ELW-style "18064K" at the TOP of the 2026-11-09
  demo up ranking, mock alphanumeric stock/ETF codes — and the official
  request enum documents no ELW exclusion while `stk_cls` has no documented
  value table, so the code shape itself is the declared deterministic
  boundary. An out-of-shape row is partitioned out of the universe at
  derivation (`upExcluded`/`downExcluded`, vendor order): it is never a
  candidate, never a candidate event, and never a failure — the raw
  response bytes keep it verbatim and replay recomputes the identical
  partition. This is a declared universe boundary, not a data gap. A row
  without `stk_cd` still rejects the whole chain (fail-closed, unchanged).
- Direction: one query per direction — `sort_tp="1"` (rise-rate) and
  `sort_tp="3"` (fall-rate). Direction comes from the query itself, not
  from a sign convention on thresholds.
- The remaining body fields (`mrkt_tp`, `trde_qty_cnd`, `stk_cnd`,
  `crd_cnd`, `updown_incls`, `pric_cnd`, `trde_prica_cnd`) are pinned at
  approval time and recorded verbatim in the run's config record; before
  approval no value is fixed.
- The refresh cadence and candidate time-to-live are explicitly fixed in
  the approved configuration; until then live candidate decisions are held.
- Pagination follows the response headers `cont-yn`/`next-key` and is
  capped by a declared page upper limit. If more pages remain when the cap
  is reached, the result is `truncated`: those pages are "not fetched",
  never "no more candidates". The cap is a scanner-side declaration.
  A cap-closed chain is consumed by the acceptance path as a *declared
  truncated subset*: the collector records the `rest_truncated` gap and
  proceeds with the fetched pages (a truncated initial chain still derives
  and registers — the session is not INCOMPLETE for the truncation
  alone), the replay stream audit accepts the cap-closed round as
  declared (below-cap `cont-yn=Y` stays a REJECT), and the event layer
  never judges a partial universe into candidate events — the
  `REST_TRUNCATED` fact (rest-truncated-v1) carries the truncation.
- Subscription selection is deterministic (user-approved policy
  `kiwoom_response_order_first_100_v1`): each direction's confirmed
  candidates are consumed in vendor response order — page then row,
  exactly the recorded order, never re-ranked and never re-scored from
  a parsed field — and the first 100 per direction (notice #49) become
  the subscription set. A candidate beyond the kept prefix is excluded
  from the session's subscription; that exclusion is recorded and
  judged (the collector's `subscription_truncated` gap — symbol null,
  detail carrying the direction, the confirmed counts (never an
  estimate of unfetched pages), whether unverified pages may remain on
  the leg, and the policy id — judged `SUBSCRIPTION_TRUNCATED`,
  subscription-truncated-v1, HIGH/INCOMPLETE; the
  `DATA_GAP_SUSPECTED` fact of the same record stays): an exclusion is
  never "no candidate", and the candidate events keep judging the FULL
  recorded in-scope universe (out-of-shape rows were partitioned out of
  the universe at derivation — the code-shape provision above — and are
  never candidates). The cap is a declared scope limit, mirroring the
  pagination provision above: the session is not INCOMPLETE for the
  subscription truncation alone — what stays blocking for approval is an
  unresolved data gap (pages not fetched below the cap, unconfirmed
  mandatory subscriptions, connection loss; GATES Approval condition 3).
  The policy id is recorded in the config record
  (`selection_policy`). The `subscription_truncated` gap detail carries
  `scope_excluded_count` per direction: the count of rows the derivation
  partitioned out by code shape (a universe boundary, never a data gap).
  Cross-direction duplicates (a code in both
  kept sets) are still a rejection (fail-closed; no auto-dedup), and
  the composition caps (`checkDirectionCaps`) stay as unchanged
  defense.
- Each attempt is recorded as a `rest_resp` record that carries the
  declared request scope and the page index, so replay can audit what was
  asked for and what came back.

### 12.2 Byte evidence (recorder scope)

The bytes preserved as evidence are exactly:

- REST: the HTTP response **body** bytes.
- WebSocket: the **application payload** bytes — RFC 6455 application data
  after de-framing and unmasking — not raw TCP bytes, not the frames, not
  control frames. In the `websockets` library this boundary is
  `recv(decode=False)` (official docs confirm text messages also arrive as
  bytes, after fragment reassembly).

Preserve request metadata, response status, and the non-secret pagination
headers required to replay candidate selection. Never preserve credentials,
tokens, Authorization headers, or login payloads; control messages are
separate from market data. TLS, TCP framing and WS control frames are outside
the raw evidence scope, so transport-level anomalies require explicit gap
or failure records rather than inference from the payload alone. Each
preserved WebSocket payload is recorded as one `ws_raw` record whose
`payload_hex` is exactly these bytes.

### 12.3 Normalization cross-check

HCJ records are normalized views (`price` int, cumulative `vol` int, `t`
timestamp). The target contract: every normalized record must be
re-derivable from the preserved bytes of §12.2, and the recorder checks
this before the record is accepted; a mismatch aborts the round. No
cross-check exists today because no producer exists.

### 12.4 `session_end`, approval and `NO_TRIGGER`

- `session_end` (M3) closes the stream and only that. It is not an
  approval; approval conditions are separate and live in GATES.md.
- Minimum close evidence (scanner termination policy): at least one
  observed `0s` FID 215 value in `{4, 8}` and a successful 0B REMOVE
  acknowledgement (§12.6). FID 215 = 9 (전체장마감) occurs only after
  18:00 and is recorded when observed but is never the minimum
  evidence; a run reaching the scanner's post-close watchdog (15:40
  KST) without a `{4,8}` observation ends INCOMPLETE, not normal.
- `NO_TRIGGER_OBSERVED` applies only when every run approval condition in
  GATES.md is met and means "no trigger in the observed stream".
- Without a verified provider sequence or completeness contract, absence in
  the stream is not evidence of absence in the market. Tick completeness
  is not claimed and cannot be verified from the client stream alone.

### 12.5 Vendor facts that constrain the VS-2 design

Verified facts (see ASSUMPTIONS.md "Vendor facts"); none is implemented yet:

- The only documented normal-close signal is the `0s` channel FID 215
  (market-state notifications). The evidenced values are the close
  subset 2 (pre-close notice 15:20), 4 (close 15:30), 8 (regular
  close), 9 (full close, only after 18:00); FID 215 carries further
  operation-state values that are not yet evidenced (full value table
  UNVERIFIED). Choosing it — or a scanner-side clock — as the
  `session_end` authority is an open policy decision; whatever is
  chosen must be a deterministic input record.
- REG/REMOVE ACK exists (`return_code` 0/1). Waiting for it would make
  subscription confirmation an auditable input; the official client does
  not wait. This is a scanner-side policy choice, not a vendor constraint.
- No provider sequence or completeness contract exists, so approval
  condition 3 (subscription confirmation) and U8 can only be closed by
  scanner-side evidence, never by trusting the stream.
- The vendor SDK stays an external local installation (license); the
  recorder adapter boundary must not copy or modify vendor code.

### 12.6 Subscription lifecycle (`sub` records: REG/REMOVE)

The wire envelope follows the official example form — all 46 official
examples (국내 38 + 미국 8) are exactly this shape: one REG request
carries exactly one `{item, type}` entry whose `type` list has a single
element, `refresh` `"1"` (the documented default), and `grp_no` `"1"`
(every official example; the field's own description is empty, so its
scope is UNVERIFIED). REMOVE is the same structure without `refresh`
("해지(REMOVE)시 값 불필요"; official SDK `build_remove_packet`; no
official REMOVE example exists). The `sub`/`ws_raw` record schemas and
the composition functions are the single source of truth in
`src/hs/sub_input.nim`; a `sub` record that fails its `(action, phase)`
schema rejects the run at its own seq (§3).

Scanner composition policy (`composeRegData`, `composeMarketStateReg`,
`composeRemoveData`, `activeSets` in the same module):

- The candidate REG is single-type: item = up then down codes (vendor
  order — the selected first-100-per-direction sets, §12.1 policy
  `kiwoom_response_order_first_100_v1`), type `["0B"]`, caps ≤100 per
  direction and ≤200 total (notice #49). The market-state REG is its
  own request: item = [],
  type `["0s"]` (the official 0s example's channel-only form). A REG
  mixing `0s` into a candidate replacement cannot be composed — the
  composition makes the invariant "0s never appears in a 0B replacement
  request" structural.
- Candidate swap = REMOVE(outgoing 0B generation) →
  ack(`return_code` 0) → REG(incoming 0B generation, refresh `"1"`) →
  ack. `refresh: "0"` is never sent: the official wording ("0일경우
  기존등록한 item/type은 해지") does not define the termination scope
  (전역 / 같은 grp_no / 같은 type), so its effect is UNVERIFIED.
- The end-of-session teardown REMOVE names the active 0B codes
  (non-empty, the full generation — the same rule as the `(remove,req)`
  record schema). `0s` is never a REMOVE target: its removal form is
  undocumented, so the market-state channel ends with the connection
  and its records stay available as close evidence.
- `activeSets` derives the active subscription state from the recorded
  stream deterministically: only acks with `return_code` 0 change state
  (requests alone never do — fail-closed), an ack pairs with the oldest
  unmatched request of the same `(gen, action)`, unmatched records are
  no-ops, and a `refresh: "0"` request makes the set underivable
  (rejected at its own seq). This is scanner-side bookkeeping, not a
  vendor-behavior claim.

UNVERIFIED (G2 mock subscription experiments before any live use):
refresh=0's termination scope, grp_no scope semantics, REMOVE
partial-removal behavior, and multi-type REG acceptance (no official
precedent and no official prohibition).

### 12.7 Kiwoom application-level PING

- The server sends an application message with `trnm: "PING"`; the
  official clients (portal samples in Python/Java/JavaScript and the
  SDK's `_receive_non_ping_message`) respond by echoing the received
  message back. The scanner sidecar echoes the received payload
  **bytes** — stricter than the SDK, which re-serializes the parsed
  dict (a logical echo).
- Client-initiated RFC 6455 pings are disabled (`ping_interval=None`,
  the official SDK's own `websockets` setting); the library still
  answers server-side protocol pings. The Kiwoom PING is an
  application message, distinct from RFC 6455 control frames, which are
  outside the §12.2 evidence scope.
- Every received PING is recorded as a `ws_raw` record (its `channel`
  distinguishes it from `0B`/`0s` traffic), so the keep-alive period
  becomes an observable. The period and the no-response policy are
  officially undocumented — the 337-API spec JSON contains zero "ping"
  mentions; the samples and SDK code are the only evidence — so both
  are G2 observation items, never assumed.

### 12.8 Data lifecycle: origin, session modes (target contract — VS-2B/VS-2C, no producer yet)

Target contract for P21/P22; no producer exists yet.

- `origin` (P21): bars derived from `ws_frame` ticks carry no `origin` field
  (`LIVE`). Backfill enters as preserved REST evidence of `ka10080`
  (3-minute bars): the raw response body and the declared request scope are
  recorded (the §12.2 byte-evidence rules apply verbatim), and bars derived
  from those records carry `origin:"BACKFILL"` in `bars.hcj.jsonl` (§7).
  Backfill bars never masquerade as live ticks: no synthetic `ws_frame` is
  fabricated from a REST bar.
- Session modes (P22) are declared in the config record (`session_mode`):
  `FULL_SESSION` (live collection from before the open through close),
  `LATE_START` (past intervals covered by backfill only, live from start
  onward), `CLOSE_RECONCILIATION` (post-close acquisition reconciling the
  final bars and closes). A `LATE_START` run never auto-promotes to
  `FULL_SESSION`: the 300 s candidate churn, the WS tick order and every
  unobserved event of the downtime are unrecoverable, and the run's
  approval scope is bounded by what was actually observed live plus the
  verified recovery range.
- Close-reconciliation acquisitions are `origin:"BACKFILL"` records whose
  purpose (reconciliation) is recorded in the attempt record; reconciliation
  compares the reconciled bars against the live-built bars and records the
  comparison — it is never proof of full live collection.
- Dispatcher outcomes (`STARTED`, `HOLIDAY`, `ALREADY_COMMITTED`,
  `UNRECOVERABLE`, `BLOCKED`) are operational state recorded outside facts
  (the §13.6 three-homes rule); `HOLIDAY`/`UNRECOVERABLE` are dispatcher
  outcomes, not session modes.

### 12.9 Opening-MA20 daily capture (ka10081)

The opening MA20 mode's daily-bar evidence (VS-1) declares its own capture
contract on the same `rest_resp` envelope as §12.1/§12.8:

- API: Kiwoom REST `ka10081` (주식일봉차트조회요청), `POST /api/dostk/chart`.
  All vendor behavior here is mock-measured (ASSUMPTIONS "Vendor facts",
  ka10081 entry); the TR is absent from the official spec JSON.
- Query scope: exactly `stk_cd`, `base_dt` (REQUIRED, YYYYMMDD, the session
  date without dashes) and `upd_stkpc_tp`, pinned to the declared capture
  scope `"1"` (the other measured value `"0"` is a valid vendor value but a
  declared-scope mismatch — the `declaredTicScope` pattern of §12.8,
  rejected fail-closed at the schema layer).
- The declared capture scope is **exactly one page per symbol** (600 rows
  cover the recent-20+-completed-days need). The vendor does offer
  cont-yn/next-key continuation — a measured success page legitimately
  carries `cont-yn=Y` — so the paginated chain rules of §12.1/§12.8
  (validateChainPages, cont-yn obligations, the page cap) do NOT apply:
  cont-yn/next-key stay preserved response evidence, never a ka10081
  obligation. A second page or a repeat of the same scope in one stream is
  outside the declared scope — REJECT, including under a declared re-poll
  cadence (`config.repoll_seconds` never licenses a second capture of the
  same symbol's daily page).
- **Record divergence from §12.1's record-first rule (intended)**: only a
  response that affirms success (the §12.3-class parse: HTTP 200,
  `return_code` 0, the documented list key, every row inside the documented
  12-field schema) becomes a `rest_resp` record. The stream-level
  acceptance path of §12.1 rejects any non-affirming attempt, so a
  per-symbol skip policy could otherwise turn one symbol's failed capture
  into a whole-stream REJECT. A failed capture (affirmation failure or
  transport failure) is instead the collector's `daily_capture_failed` gap
  record — the symbol is skipped, excluded from this session's daily-bar
  evidence, never marked captured — and the session continues
  (fail-closed per symbol, not per session).
- The sweep runs exactly once per session, started when the session's
  initial chain pair (§12.1, first completion only — a re-poll round never
  restarts it) completes. The universe is the initial pair's row `stk_cd`
  union in vendor order (up chain rows then down chain rows, deduped,
  candidate-shaped and non-candidate-shaped codes alike — the whole
  recorded in-scope universe, not the selected subscription set). A symbol
  that appears only in a later poll round stays uncaptured: no re-issue.
- `base_dt` is the session date (the day's in-progress first row included);
  the descending `dt` order, the unsigned `cur_prc` (closing price) and
  the `stk_cd` echo of the measured shape are preserved verbatim in
  `body_hex` (§12.2 rules apply unchanged).

## 13. Events (VS-3 contract)

The judgment layer described in this section is implemented
(`src/hs/event_gen.nim`; §13.8 states exactly what exists and what does
not). The push transport, mobile client and delivery path are not
implemented, and nothing in this repository proves operational approval —
GATES P12 remains the only such authority. The record schemas are the
single source of truth: `contracts/events/event.schema.json` (the immutable
event fact) and `contracts/events/delivery.schema.json` (the operational
delivery record). The event contract suite (`tests/test_event_contract.nim`)
covers the schemas' structure, vocabularies, the committed fixture, the
deterministic id rule and the state separation; the judgment suite
(`tests/test_event_gen_contract.nim`) covers the implemented judgment
layer. Passing either proves no live producer and no delivery path exists.

### 13.1 One judgment function

Events are produced by exactly one deterministic function,
`step(state, record) -> (state', events)`, shared by the live and replay
paths. Separate live/replay event code is contractually forbidden: a second
judgment path would be a second definition of the facts. Delivery and
notification code may filter, order or translate events for transport; it
may never judge, upgrade, or rewrite them. Read-only presentation
projections may additionally derive deterministic display views by
translating recorded facts, or — for runs whose config record predates
`events_contract:"top10-v1"` — by comparing recorded states (the legacy
market-view change history, tools/api README §3.7); such views are not
events, mint no ids of their own, never enter a journal, and never flow back
into a fact, an id, or a judgment (§13.5). TOP10 membership, entry, exit and
in-group rank changes are judged facts (§13.8, `top10-transition-v1`); a
presentation layer never re-derives them for runs that declare the
`events_contract` marker.

### 13.2 Record-first (write-ahead judgment)

Event judgment consumes RECORDED records: `step` sees only records already
in `input.hcj.jsonl` (§2). The input log precedes judgment (the WAL
principle), so after a crash the complete event history is reconstructible
by replaying the log. An event that cannot be derived from the log is not
a fact.

Record-first is a durability ordering, not only a write ordering: before
the live collector appends an event to the events journal — the file a
notification consumer reads — it fsyncs the input log, so a published
event never outruns the durability of the recorded input it was judged
from. An event whose evidence cannot be made durable is not published;
the session is preserved and ends INCOMPLETE.

### 13.3 Single-writer order

Live consumers feed records to `step` strictly in recorder seq order — the
physical order §2 Rule 1 pins (`seq` 1..N). There is one writer and one
order, so live and replay see identical input sequences and therefore
identical events. No consumer may judge from a side channel or reorder
records before judgment.

### 13.4 Replay and byte-identity

Replay regenerates `events.hcj.jsonl` byte-identically, and `verify`
byte-compares the live-produced events file against the replayed one
before any MATCH is reported. The event id binds each fact to its recorded
position: `event_id` is the sha256 hex of the canonical serialization of
`(session_id, event_type, rule_id, entity, transition_seq)`, where entity
is the symbol or `*` and `transition_seq` is the input record seq at which
the transition was observed (the full rule is `x-event-id-rule` in the
schema). The seq value itself is never emitted (§2); it enters only this
one-way digest, and the record carries no position field.

Because ids bind to recorded positions, a §2 Rule 3 diagnostic
insert/delete (with renumbering) yields a different `events.hcj.jsonl` by
design; the NO_EFFECT class of §10 is stated over the Core artifacts of
§1 (`bars.hcj.jsonl`, `signals.hcj.jsonl`). Event byte-identity is defined
between the live-produced file and the replay of the same input bytes:
same input bytes, same event bytes.

The id tuple carries the run's own identity when the config record
declares one: `run_id` (the run directory's basename, the same value the
recorder's COMMITTED marker carries) joins the digest object between
`rule_id` and `session_id`. One date may hold more than one run — a
failed run's recorded facts are immutable and its same-day restart is a
different run whose facts must coexist in the notify ledger; the
`run_id` namespace keeps the two id spaces disjoint (2026-11-09
incident: the legacy date-only id space collided and the ledger refused
the restart's whole batch). A config record without `run_id` (every
sealed pre-2026-11-09 run) keeps the legacy five-key digest
byte-identically — old sealed runs replay with their recorded ids.

### 13.5 Determinism boundary

Guaranteed — computation over the same recorded input:

- event generation (which events exist, in what order);
- event ids (the deterministic rule of §13.4);
- replay results (byte-identical `events.hcj.jsonl`).

Not guaranteed — everything downstream of the provider boundary:

- FCM (or any provider) arrival time;
- delivery order across devices or events;
- the device's display time;
- whether and when the user read the notification.

None of the unguaranteed outcomes may flow back into a fact, an id, or a
judgment.

### 13.6 Operational state is never fact state

Three states, three homes, never mixed in one record:

| state | home | mutable |
|---|---|---|
| importance / trust (`severity`, `data_quality`) | the event fact | no |
| verification | the session-level verify output | per session run |
| delivery (`state`, `attempts`, `error_code`) | delivery records | yes |

A fact never carries `verification_status` or delivery fields; adding them
would mutate the fact bytes and break replay byte-identity (§13.4). The
schemas enforce this structurally (`additionalProperties` false); the
event contract suite rejects both families by name.

### 13.7 Design principles

The six VS-3 design principles govern this contract and are referenced,
not duplicated: facts live on the server; one judgment logic;
notifications are transport; mobile is read-only; uncertainty is not
hidden; existing platform features are leveraged.

### 13.8 Implementation note (what exists, what does not)

Implemented — one judgment function, two drivers, one byte comparison:

- `step(state, record) -> (state', events)` and the end-of-stream judgment
  `finish(state)` live in `src/hs/event_gen.nim`. The replay path folds
  `eventsOfRecords` once over the consumed stream (`src/hs/replay.nim`);
  the live collector (`tools/collector/collector.nim`) appends the same
  `step` judgments per consumed record. There is no other judgment code.
- The live journal is `<out>/events.hcj.jsonl`, created exclusively
  (`O_CREAT|O_EXCL|O_NOFOLLOW`): an existing judgment log is never
  reopened or appended to. Events are appended at consume time (§13.2)
  and the seal's session_end record is judged through the same `step`.
- Replay writes `events.hcj.jsonl` as the fourth checksummed artifact
  (§7). `verify` byte-compares the run directory's file against the
  recomputation — a missing or differing file is a named MISMATCH issue,
  never a pass — and prints the recomputation hash as `EVENTS=<sha256>`
  on every verdict past the run-status gate. A drill carries the live
  bytes into the run directory byte-exact (the same staging the commit
  marker gets) so verify audits the artifact the collector wrote.
- Death/restart recovery is record-first reconstruction: the state is
  `stateAt(records consumed so far)`, and resuming the recorded stream
  from there reproduces exactly the missing events (covered by the
  judgment suite's recovery block).

Rules (all `rule_version: 1`; `evidence_ref` is the declared vendor scope
for candidate transitions, otherwise the content address of the consumed
record's canonical line):

| rule_id | event_type(s) | judged from | severity / data_quality |
|---|---|---|---|
| `candidate-transition-v1` | CANDIDATE_ENTERED / UPDATED / EXITED | completed ka10027 up+down chains (`evidence_ref` = `ka10027:stex_tp=1:sort_tp=1` or `…:sort_tp=3`); a code in both directions is judged once, up first; EXITED carries no rank | INFO / OBSERVING |
| `top10-transition-v1` | TOP10_ENTERED / TOP10_EXITED / RANK_CHANGED | the previous confirmed observation group vs the pending group's final generation, per direction: outside-or-absent → rank 1-10 is TOP10_ENTERED (`previous_rank` present when the symbol was a ranked candidate), rank 1-10 → 11+ is TOP10_EXITED, rank 1-10 → candidate gone is TOP10_EXITED with no `rank`, rank 1-10 → a different rank 1-10 is RANK_CHANGED, all else judges nothing. A group is confirmed only when a pair with a different `observed_at` stamp completes, or at the kSessionEnd record (flushed before SESSION_ENDED); an unsealed stream that never consumed session_end confirms nothing. Same-stamp consecutive pairs merge into one group (intra-group states are never judged). The first confirmed group is the baseline and emits nothing. `observed_at` is the group's own stamp, `transition_seq` is the pending group's pair completion seq, `name` is the vendor row's stk_nm. A symbol in both directions with the same event_type at the same transition is judged once, up first (inherited from the id rule: direction is not in the digest) | INFO / OBSERVING |
| `feed-disconnected-v1` | FEED_DISCONNECTED | ws_conn `closed_ok` (INFO) / `closed_error` (HIGH); `open` judges nothing | INFO or HIGH / INCOMPLETE |
| `gap-suspected-v1` | DATA_GAP_SUSPECTED | every gap record | HIGH / INCOMPLETE |
| `rest-truncated-v1` | REST_TRUNCATED | a gap record whose `what` is `rest_truncated` (second fact of the same record, distinct by event_type) | HIGH / INCOMPLETE |
| `subscription-truncated-v1` | SUBSCRIPTION_TRUNCATED | a gap record whose `what` is `subscription_truncated` (second fact of the same record, distinct by event_type); the fact's direction is the gap detail's pinned `direction=up\|down` token | HIGH / INCOMPLETE |
| `market-state-unknown-v1` | MARKET_STATE_UNKNOWN | a 0s ws_raw payload whose FID 215 value is outside the evidenced set {2,4,8,9}; at most one per record | HIGH / UNKNOWN |
| `session-close-v1` | SESSION_ENDED | the session_end seal record | INFO / OBSERVING |
| `session-incomplete-v1` | SESSION_INCOMPLETE | `finish` on a consumed stream that never sealed; binds to the last consumed record | HIGH / INCOMPLETE |

Not implemented — vocabulary only (the schema defines the full
vocabulary; the implementation lags it):

- `REPLAY_MATCH`, `REPLAY_MISMATCH`, `SESSION_APPROVED` are session-level
  verify outputs, not `step` facts; the judgment layer emits none of them.
- Delivery records (`contracts/events/delivery.schema.json`), the push
  transport and the mobile client: none exist.

What the current evidence does not prove: byte-identity proven on
synthetic fixtures and a dev-build drill is mechanism, not operation — no
live market data, no real vendor stream, no delivery path, no GATES P12
observation. Any `NO_TRIGGER_OBSERVED`-style claim remains impossible
until a real observed stream exists.

## 14. Container runtime contract (Northflank Phase-0)

The Phase-0 container layer — image layout, supervisor, supply chain — is
contracted in `tools/container/README.md`; this section states only what
touches the replay contract. What exists is the code and its contract
suites (README §6, §7.4). No Northflank deployment and no cloud Kiwoom
connection exist yet, so nothing in this section is live-measured.

### 14.1 Path contract: image vs volume

| path | supplied by | content |
|---|---|---|
| `/opt/hongscanner` | the image (read-only fate) | code: `serve.py`, `cloud_supervisor.py`, `bin/hongscanner`, `bin/collector`, `bin/sidecar.py`, notify modules, baked `CALENDAR_INDEX.sha256` |
| `/var/lib/hongscanner` | the Northflank Single Read/Write Volume (deployment Replica 1 — ASSUMPTIONS P16) | `runs/` (run directories), `notify/` (ledger, notify config), `calendars/*.json` (user data, gitignored) |

Everything the replay contract reads or writes at runtime lives under the
volume root. The image contributes code and the baked calendar INDEX only —
no market data, no credentials, no ledger bytes are baked (README §2, §8.4).

### 14.2 The supervisor is an execution adapter

`cloud_supervisor.py` owns child-process lifetime and session scheduling
only. It performs no market judgment and writes nothing into any run
directory: §13.3's single-writer order extends to this boundary — the
recorder stays the only writer of a session's records. The supervisor's
observable surface is its stdout log (`SUPERVISOR`-prefixed lines): like
`ws_conn` (§3) it is diagnostic, carries no judgment, and nothing in the
replay path reads it.

### 14.3 Session idempotency (boot and restart agree)

Any container (re)start lands on the same conclusion for the day:

- a COMMITTED run for today (`input.hcj.jsonl.committed`) ends the day —
  no new session;
- an unsealed run is preserved as prior evidence: never resumed, never
  overwritten; a new observation attempt gets a fresh `run_id`
  (`ph1-<date>-a`, `-b`, …) inside the remaining window;
- the run directory is created exclusively (`O_EXCL`) as a second defense
  behind the supervisor's single-session control; attempts are capped at
  3 per day (the count of existing run directories is the attempt count);
- collector exit 0 = sealed (COMMITTED), exit 4 = honest INCOMPLETE, any
  other exit (2, 3, signal) = preserved. No exit is promoted to success.

### 14.4 Calendar supply separation (fail-closed)

Two sources, and neither is trusted blindly:

- the image carries the git-tracked `CALENDAR_INDEX.sha256` (canonical
  main origin);
- the volume supplies the actual `calendars/*.json`.

The supervisor's startup latch (`/startup`) cross-verifies the volume
calendars against the baked INDEX and holds 503 — no sessions start —
until the verification passes. A volume calendar that fails the
cross-check fails closed: initialization never completes, and the
hash-pinned calendar provenance of §11 is never silently bypassed.

### 14.5 `token_source` in the recorded stream

The collector child may be started with `--token-source=env`: the OAuth
token then comes from runtime-injected environment variables, and the
credential values themselves are never recorded. What the init line (the
`config` record, §2 record 2) carries is the declaration
`token_source: "env"` — which provider supplied the token, not the token.
An undecorated init line keeps the default `kiwoomcli` path unchanged.
This is the §12.2 rule ("never preserve credentials") applied to the
cloud path, and it keeps §8's provenance checks meaningful: the recorded
stream still contains every input Core consumed.