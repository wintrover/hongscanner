# Hong Scanner — Assumptions: MUST vs everything else

Only **MUST** rows are requirements. Every other row is a verifiable or
changeable assumption; treating one as a requirement is what stalled v1–v5.

## MUST

| id | requirement | enforced by |
|---|---|---|
| M1 | same Core input + code + calendar ⇒ byte-identical `bars` and `signals` | `NO_EFFECT`, `CLOCK_INVARIANT`, `verify` |
| M2 | the run date comes only from `config.session_date` | `replay.runCore` signature (no date parameter) |
| M3 | normal end is declared by `session_end`, never by EOF | `VERDICT INCOMPLETE` (exit 4) |
| M4 | a tick into a closed bar invalidates the run | `LATE_TICK_INTO_CLOSED_BAR` (exit 5) |
| M5 | unknown record kinds and seq discontinuity are rejected | `REJECT` tests (exit 2) |
| M6 | session bounds and alignment come from the calendar | `SESSION_NOT_BAR_ALIGNED`, `CALENDAR_COVERAGE_UNKNOWN` (exit 3) |
| M7 | every signal references a closed bar | `no_signal_for_open_bar` test |
| M8 | canonical main build must be clean, on main, equal to origin/main | `tools/build.sh` |
| M9 | `MATCH` requires all five provenance comparisons | `verifyRun` |
| M10 | CI must not fetch market data | fixtures are committed, tests closed-book |
| M11 | the container runtime preserves Core determinism and the Replay contract — the supervisor judges nothing and writes no run directory | REPLAY_CONTRACT §14; `verify` byte-comparison unchanged |
| M12 | the recorder and the event ledger each have exactly one writer | collector `O_EXCL` journal (§13.8); notify ledger append-only single-writer |
| M13 | no secret or token enters git, the image, HCJ records, or plain logs — the init line records `token_source`, never a credential value | `.dockerignore` whitelist (tools/container/README.md §2); §12.2 "never preserve credentials" |
| M14 | only the canonical main attest-verified binary runs in operation | GATES P13 (attest → install → digest match) |
| M15 | mobile stays read-only against the API | GET-only server (tools/api/README.md); §13.7 "mobile is read-only" |
| M16 | no incomplete or failed session is ever promoted to success | `VERDICT INCOMPLETE` (exit 4); tools/container/README.md §7.3 — no exit is promoted |

## POLICY (a chosen contract, changeable by decision)

| id | policy | alternative |
|---|---|---|
| P1 | single `seq` gauge; diagnostic records may be inserted/deleted after record 2 and renumbered | dual counter (rejected: more coupling, no stronger guarantee) |
| P2 | 290 conflict ⇒ exclude + degrade, abort round above 0.5% | trust the window (rejected: v3 contradiction) |
| P3 | first observed cumulative volume contributes 0 and marks `vol_partial` | treat first value as volume (unproven) |
| P4 | `gap` is the authority for untrusted data; `ws_conn` is diagnostic | infer gaps from 180 s silence only (rejected: misses short drops) |
| P5 | exit codes 0/2/3/4/5/6/7 | separate codes per command |
| P6 | no `--allow-dirty`; debugging builds stay non-canonical | escape hatch (rejected) |
| P7 | public repo + synthetic CI; calendars gitignored | private repo (not needed for CI minutes) |
| P8 | candidates are queried via `ka10027` with `stex_tp="1"` and one query per direction (`sort_tp="1"`/`"3"`); query scope and page upper limit are declared and recorded (VS-2 target, no producer yet); the candidate universe is the 6-digit-code-shaped rows (`isCandidateCode`, 2026-11-09: the official enum has no ELW exclusion and no stk_cls value table, so the code shape is the boundary — out-of-shape rows are partitioned out at derivation, preserved in raw bytes, never candidates); `stk_cnd` is pinned `"16"` (documented ETF+ETN exclusion, honored by demo 2026-11-09); the subscription set is each direction's first 100 confirmed candidates in vendor response order — never re-ranked (policy `kiwoom_response_order_first_100_v1`, user-approved 2026-11-03; exclusions recorded as `subscription_truncated`/SUBSCRIPTION_TRUNCATED, cross-direction duplicates rejected) | any other universe, uncapped pagination, re-scoring the vendor's order (unapproved), or filtering by undocumented stk_cls values (rejected) |
| P9 | approval is a separate decision with its own conditions (GATES); `session_end` and `VERDICT MATCH` never imply approval | treat MATCH as approval (rejected) |
| P10 | `NO_TRIGGER_OBSERVED` is only for complete, valid runs, and only describes the observed stream | read zero signals as market-level absence (rejected: tick completeness is not guaranteed) |
| P11 | the config record may declare `environment` (`demo` or `prod`); verify enforces the commit-marker gate only for a declared environment, and synthetic streams report the marker state without enforcing it | enforcing the marker gate on synthetic streams (rejected: CI has no recorder) |
| P12 | durable completion = sealed artifacts + a valid commit marker (`hong-scanner-commit/1`); "recorded" never implies "committed" | trusting the seal alone (rejected: the fsync window leaves the state ambiguous) |
| P13 | the commit marker's `t` is the only wall-clock input at the recorder adapter boundary; Core still has none | timestamps in Core (rejected: M1) |
| P14 | subscription REGs are single-type in the official example form, refresh `"1"`, grp_no `"1"`; `0s` is registered by its own REG and never enters a 0B replacement request; a swap is REMOVE(outgoing) → ack → REG(incoming, refresh `"1"`) → ack; refresh `"0"` is never sent | multi-type REG with 0s auto-added (rejected: no official precedent, V1) |
| P15 | subscription confirmation records REG/REMOVE acks; `activeSets` reflects ack `return_code` 0 only | trusting requests alone (rejected: a request is not evidence) |
| P16 | the Northflank deployment is one container (Replica 1) with a Single Read/Write Volume for `/var/lib/hongscanner` | multiple replicas/HA (rejected: M12 needs exactly one writer) |
| P17 | the session window is scanner-side clock policy: KST 08:50 start, 15:30 last start, 15:40 watchdog | vendor-close-driven scheduling (rejected: FID 215 is close evidence, not a start authority — §12.4) |
| P18 | candidates are re-queried every 300 s during the session (`repollSeconds`, approved PH-1 value) | another cadence (unapproved: §12.1 requires the cadence declared and recorded) |
| P19 | the cloud path targets demo first: the sidecar refuses any base other than demo/mockapi | prod from day one (rejected: the mock is the documented test stage; prod is a separate confirmation) |
| P20 | liveness covers the supervisor itself only; startup/readiness/liveness stay three separate probes (tools/container/README.md §7.2) | child-aware liveness (rejected: contract A — child state must not trigger container restarts) |
| P21 | data provenance is a bar-level `origin` axis with exactly two values: `LIVE` (bars derived from WS ticks) and `BACKFILL` (bars derived from REST ka10080 records). The field is optional on `bars.hcj.jsonl`; absent means `LIVE`, so pre-contract streams recompute byte-identically. `origin` never enters event facts (closed schema, REPLAY_CONTRACT §13.4) or the record envelope. Close-reconciliation acquisitions are `origin:"BACKFILL"` with the purpose recorded in the attempt record — not a third origin value. `data_quality` (OBSERVING/INCOMPLETE/UNKNOWN) stays an orthogonal trust axis | three origin values (rejected: overlaps the session-mode axis); origin on event facts (rejected: mutates fact bytes and breaks replay byte-identity) |
| P22 | session modes (`FULL_SESSION`, `LATE_START`, `CLOSE_RECONCILIATION`) are declared in the config record; dispatcher outcomes (`STARTED`, `HOLIDAY`, `ALREADY_COMMITTED`, `UNRECOVERABLE`, `BLOCKED`) are recorded in delivery/operational records (REPLAY_CONTRACT §13.6 three-homes rule). A late-started session never auto-promotes to `FULL_SESSION`; backfilled bars never masquerade as live ticks | auto-promotion or mode-less recording (rejected: partial observation would be indistinguishable from complete) |
| P23 | up and down verdicts come from one symmetric judgment: `S_d = d × (P − P_ref)/P_ref × 10⁴ ≥ τ` with `d=+1` (up) and `d=−1` (down), identical observation windows (`warmup_bars`, `lookback_bars`), identical reference series (close), identical pivot selection and tie rules, identical taint handling, and shared absolute thresholds (`trend_min_bp`, `countermove_min_bp`, `directional_trigger_bp`). Per-direction thresholds are a contract violation (frozen 2026-11-06, REPLAY_CONTRACT §6) | asymmetric windows, close/high pivot mixing, or per-direction thresholds (the pre-rewrite engine's state) |
| P24 | contract evolution rule: every new input/artifact field is optional with a declared default meaning "pre-contract" (the `environment`/`repoll_seconds` precedent); `run.json` gains a non-checksummed `contract_version`; replay stays same-commit — a sealed run verifies only under its own recorded commit's binary, and no provenance weakening is introduced for old runs | re-verifying old runs under new binaries by relaxing REPLAY_CONTRACT §8 check 1 (rejected: fail-closed by design) |
| P25 | calendar approval is the operator's explicit decision recorded with three separable evidences: source match (`tools/check_calendar_source.py` output), integrity (`CALENDAR_INDEX.sha256` match), and the approved scope (first/last trading day). The INDEX commit is not a cryptographic signature; byte equality is not authority | treating INDEX hash equality or a restored copy's byte match as approval (rejected) |
| P26 | event ids are namespaced by the run's own identity: a config record with `run_id` (the run directory's basename, the recorder COMMITTED convention) joins the `x-event-id-rule` digest between `rule_id` and `session_id`; a config without `run_id` (every sealed pre-2026-11-09 run) keeps the legacy five-key digest byte-identically. One date may hold more than one run — a failed run's immutable ledger facts and its same-day restart's facts must coexist, not collide (2026-11-09 incident: the date-only id space made the ledger refuse the restart's whole batch) | a date-only id space (rejected: same-day restarts cannot record their facts); rewriting or deleting the failed run's ledger facts to make room (rejected: the ledger is immutable) |
| P27 | notification delivery gates on an event-type allowlist, exactly `TOP10_ENTERED`, `TOP10_EXITED`, `RANK_CHANGED` (user decision 2026-11-11; resolves U16). A fact's severity is operational importance only and never gates delivery; `min_severity` is removed from the dispatcher contract and the live config. System-fault facts (FEED_DISCONNECTED, DATA_GAP_SUSPECTED, REST_TRUNCATED, SUBSCRIPTION_TRUNCATED, MARKET_STATE_UNKNOWN, SESSION_INCOMPLETE) stay recorded in the ledgers and are never pushed — the user chose silence over fault alarms | severity-gated delivery (rejected: severity measures system impact, not user interest); fault events pushed (rejected: user decision) |

## IMPLEMENTATION CHOICE (free to change without breaking the contract)

| id | choice |
|---|---|
| I1 | pure-Nim SHA-256 (`src/hs/digest.nim`); no Nimble dependency |
| I2 | Nim 2.2.10 pinned exactly |
| I3 | VS-1 implements a Core, Replay and CLI; a standalone recorder exists, but live collection and supervision remain unimplemented VS-2 work |
| I4 | `-d` injection for build provenance instead of a generated source file |
| I5 | checksum manifest is three sorted lines |
| I6 | `bar_position` and `session_class` stored on the bar record |
| I7 | the container's always-on process is `tools/container/cloud_supervisor.py` — execution adapter: child lifecycle + session scheduling, stdout log only |
| I8 | cloud OAuth via the sidecar EnvTokenProvider (`token_source=env`); the kiwoomcli Secret Service path stays the default outside the container |
| I9 | GHCR images are tagged with the immutable convention `main-<sha7>`, one push per exact main sha; tag overwrite and `latest` are forbidden |
| I10 | mobile keeps its API credential in Android secure storage (Keystore-backed); the API front is Northflank ingress HTTPS + Basic Auth |

## UNKNOWN (must be measured, not assumed)

| id | unknown | resolution gate |
|---|---|---|
| U1 | live WebSocket behaviour vs the documented client semantics (vendor facts below) | G2 (credentials) |
| U2 | meaning and reset window of cumulative volume `13` | G4 |
| U3 | start/end timestamp convention of REST bars | G4 |
| U4 | `290` behaviour at the closing auction | G4 |
| U5 | fixed egress IP availability and cost on the target account | NF-1 (GATES) |
| U6 | real signal frequency and false-positive rate | PH-1/PH-2 |
| U7 | durability under power loss | VS-2 drill |
| U8 | whether the live feed drops ticks silently (0B delivery completeness) — no provider sequence or completeness contract exists (full-text search of all 337 API specs: zero hits), so client logs alone cannot prove absence | G2: WS-derived volume vs REST `acc_trde_qty` |
| U9 | an adequate ka10027 page upper limit (candidates missed by the cap); with the top-100 selection the subscription needs only the first 100 per direction in response order, so the cap now bounds observation completeness — not subscription validity — but whether the vendor's response order is the operationally right ranking stays unmeasured | PH-1 / G2 |
| U10 | refresh=0's termination scope, grp_no scope semantics, REMOVE partial-removal behavior, multi-type REG acceptance (official wording absent for all four) | G2 mock subscription experiments |
| U11 | Kiwoom PING period and no-response policy | G2 (ws_raw PING records) |
| U12 | the full FID 215 value table beyond the evidenced close subset {2, 4, 8, 9} | G2 observation |
| U13 | whether Kiwoom accepts (registering) a Northflank dedicated egress IP | NF-1 |
| U14 | APAC region latency (Kiwoom and device push) — not yet measured | NF-3 |
| U15 | actual volume usage and required size (1 GiB provisional from the 2026-11-02 runs/ measurement — GATES Phase-0 evidence log) | NF-4 |
| U16 | RESOLVED 2026-11-11 (P27): the severity-gate question is superseded by the event-type allowlist; nothing remains to measure | — |
| U17 | FCM and API end-to-end from a cloud deployment to a real device | NF-8 |
| U18 | GHCR package visibility handling (first push is private by default; the operator read:packages PAT path) | NF-9 (tools/container/README.md §8.3) |

## Vendor facts (official sources, 2026-10-30)

Verified from the official Kiwoom OpenAPI repository (spec JSON, client
sources), PyPI metadata, and websockets/keyring documentation. These are
trust facts: cite them, do not re-derive them. Live confirmation of each
still requires G2 credentials.

- REG/REMOVE wire form (official spec JSON, SDK `packets.py`, portal
  guide): REG = `{trnm:"REG", grp_no, refresh, data:[{item, type}]}`;
  REMOVE is the same structure without refresh (SDK
  `build_remove_packet`; no official REMOVE example exists). refresh
  (한글명 기존등록유지여부, required) 원문: "등록(REG)시 0:기존유지안함
  1:기존유지(Default) 0일경우 기존등록한 item/type은 해지, 1일경우
  기존등록한 item/type 유지 해지(REMOVE)시 값 불필요". The termination
  scope of refresh=0 (전역 / 같은 grp_no / 같은 type) has no official
  wording (UNVERIFIED). grp_no (그룹번호) has an empty description; all
  46 official examples (국내 38 + 미국 8) pin "1". Every official
  example is a single-type REG (one `{item, type}` entry, refresh "1");
  a multi-type REG has no official precedent and no official prohibition
  (UNVERIFIED). REMOVE partial removal is undocumented (UNVERIFIED).
- REG/REMOVE ACK exists (`return_code` 0 normal / 1 error, sent only on
  register/remove); the official client does not wait for it — only LOGIN
  has a dedicated ack wait. Subscription confirmation is therefore possible
  in principle, but waiting for it is a scanner-side policy decision.
- The `0s` channel (registered with no symbols) delivers market-state
  FID 215. The evidenced values are the close subset 2 (pre-close notice
  15:20), 4 (close 15:30), 8 (regular close), 9 (full close, only after
  18:00); the full value table is larger and UNVERIFIED. It is the only
  documented normal-close signal; no ordering guarantee vs `0B` frames.
- Kiwoom application-level PING: the server sends `trnm:"PING"` and the
  official clients echo it back (portal samples in three languages,
  "수신값 그대로 송신"; the SDK `_receive_non_ping_message` re-sends the
  parsed message — a logical echo re-serialized via json.dumps). The
  evidence is the samples and SDK code only: the 337-API spec JSON has
  zero "ping" mentions. The SDK connects with `ping_interval=None`
  (client-initiated RFC 6455 pings off; the library still answers
  server-side protocol pings). The PING period and no-response policy
  are undocumented (UNVERIFIED). `trnm=SYSTEM` terminates the stream in
  the official client; its meaning is undocumented. A server close has
  no documented semantics.
- Mock vs real (portal 모의투자 이용안내 · 서비스 이용안내 · notices ·
  spec JSON · SDK): 모의투자 is a "가상 매매 시스템" and Kiwoom
  recommends "디버깅과 테스트를 위하여 실제 환경 적용 전에 모의투자로
  접속하여 충분한 테스트" — a test stage, not an equivalent feed. No
  official statement claims mock-feed identity with the production feed
  (UNVERIFIED); the opposite direction is documented — notice #48:
  "(단, 모의투자의 경우 제공 기능 및 데이터에 일부 차이가 있을 수
  있습니다.)". NXT trading is mock-unsupported (시세만 제공). Error
  codes: 8104 "모의투자에서 지원하지 않는 API 입니다.", 8030/8031
  투자구분(실전/모의) mismatch. Domains: mock REST
  `https://mockapi.kiwoom.com`; mock WS `wss://mockapi.kiwoom.com:10000`
  (SDK `DEFAULT_WS_BASE_URLS["demo"]`). WS connect URI는 베이스에 공식
  WS API 경로를 붙인 것이다: SDK `ws_client.connect`가
  `uri = base + api_url`로 합성하고, kwcli `api_commands.csv`의 WS
  기반 명령(ka10171~73) 경로가 `/api/dostk/websocket`이라
  `wss://mockapi.kiwoom.com:10000/api/dostk/websocket`이 실제 접속
  URI다. 2026-11-02 14:3x KST(월 정규장 중) 실측: 루트(`/`)로 보낸
  opening handshake는 TCP·TLS 1.3(Kiwoom EV 인증서) 완료 후에도 서버
  무응답(TimeoutError), `/api/dostk/websocket` 경로는 업그레이드
  완료 — 루트 무응답 자체는 공식 문서에 없는 관측 사실이고 2026-10-31
  금·토 프로브 타임아웃의 원인(경로 없이 프로브했음). "실제 투자와
  모의투자 App Key를
  별도로 관리합니다." Mock rate limit: TR 1초 1회 per account/토큰
  (notice #49) — 2026-11-02 라이브 실측 확인: 페이지 2를 1초 내 재요청하면
  HTTP 429 `"허용된 요청 개수를 초과하였습니다[1700: …유량=1,
  API ID=ka10027]"` + return_code 5, 요청 간격 1초로 두면 통과(창 해석은
  무문서 — 1초 간격이 문서화된 상한의 준수). The 모의투자 운영규정 text itself is UNVERIFIED (SPA, not
  statically retrievable).
- Kiwoom REST token–IP binding (2026-11-03, official error-code table):
  error 8010 — "Token을 발급받은 IP와 서비스를 요청한 IP가 동일하지
  않습니다" (`GET openapi.kiwoom.com/errorcode/getErrorCodeListAjax`,
  public, no login; the official SDK `kiwoom/core/errors.py` places 8010
  in `DEVICE_AUTH_CODES`). It is the only IP-dedicated code of the
  official 37-code table (full enumeration), and token issuance (au10001
  `POST /oauth2/token`) takes appkey/secretkey only — no IP parameter,
  zero IP mentions across the 356 public API spec groups. A token is
  bound to the IP that requested it; reuse from another source IP fails
  closed — the official basis for requiring a stable egress IP on any
  cloud REST path (NF-1). It does NOT establish: overseas-IP acceptance
  (UNKNOWN, U13), 8010's applicability to WS sessions (no official
  statement), or the circulating "허용 IP 필수·최대 10개" wording
  (origin: third-party autoStock docs, not Kiwoom — UNVERIFIED; the
  portal 개발정보 screen is login-walled and stays a user-side
  verification step). Single-shot observation: a KR residential IP
  reaches credential validation on the mock token endpoint (8001 on
  dummy keys) — no KR-side IP block; no evidence either way for
  datacenter/overseas IPs.
- Durability evidence (man-pages, POSIX.1-2024, SQLite, LevelDB,
  PostgreSQL): fsync(2) flushes file data and metadata, but "Calling
  fsync() does not necessarily ensure that the entry in the directory
  containing the file has also reached disk. For that an explicit fsync()
  on a file descriptor for the directory is also needed"; POSIX adds
  "If the fsync() function fails, outstanding I/O operations are not
  guaranteed to have been completed". write(2): "A successful return
  from write() does not make any guarantee that data has been committed
  to disk." Completed-work markers are separate from the data in SQLite
  (rollback-journal deletion is the commit instant; WAL's "last valid
  commit record"), LevelDB (CURRENT names the committed MANIFEST) and
  PostgreSQL (WAL records protected by CRC-32C). Marker creation is
  atomic via open(2) `O_CREAT|O_EXCL`. Wording rule: no official
  document approves the recorder's whole finish order — each component
  (file fsync, directory fsync, separate marker, atomic marker
  creation, marker validation) carries its own official basis, and
  "marker mismatch = INVALID" is this design's application of the
  trust-only-a-valid-commit-marker principle, not a quoted rule. Data
  written between the 60 s fsyncs can still be lost, and no absolute
  power-loss guarantee exists.
- The official `kwcli` (PyPI) requires Python >= 3.13 (this system has 3.12;
  `uv python install 3.13` is the official path) and stores credentials in
  the Secret Service, which needs a D-Bus session bus — a systemd `--user`
  unit must set `DBUS_SESSION_BUS_ADDRESS` explicitly. Token cache:
  `~/.cache/kiwoom/<mode>-token.json`; env fallbacks exist.
- Kiwoom SDK license: use is permitted for OpenAPI service purposes, but
  copying, distributing, modifying or bundling the SDK in this repository is
  not. Vendor code stays an external local installation, never repo content.
- `websockets` `recv(decode=False)` returns the application payload bytes
  (text included) after fragment reassembly — the evidence boundary of
  REPLAY_CONTRACT.md §12.2.
- Server split and separate credentials (official docs, collected
  2026-11-06): ka10080 document — "운영 도메인 https://api.kiwoom.com /
  모의투자 도메인 https://mockapi.kiwoom.com (KRX만 지원가능)"; WS 0B
  document — "wss://api.kiwoom.com:10000 / wss://mockapi.kiwoom.com:10000
  (KRX만 지원가능)"; the official `.env.example` names the four endpoints
  PRD/MOCK/W_PRD/W_MOCK. 서비스 이용안내 — "키움증권은 실제 투자와
  모의투자 App Key를 별도로 관리합니다." Operational and mock servers,
  and their credentials, are separate by design.
- Demo/real data-fidelity wording (official guide quotes, collected
  2026-11-06 — the VS-F comparison basis): MCP guide (guideIndex/07) —
  "이 글은 모의투자 환경을 기준으로 하며 조회 기능과 주문을 다룁니다.
  **조회 데이터는 모의투자와 실전이 같습니다.**" Plugin guide
  (guideIndex/09) — "…시세는 모의 서버 값이라 실제 시장 수치와 다를 수
  있습니다." The two sentences have different subjects ("조회 데이터" vs
  "시세"): reading 1 — 조회 데이터 as the REST snapshot scope with 시세 as
  the narrower quote-value scope — is the best-supported reading of the
  original structure, and no official document anywhere defines the scope
  coordination of the two terms. Fidelity is therefore an API-by-API
  experimental question and must never be settled from documentation
  alone. 모의투자 이용안내 — "시세의 경우 고객 편의를 위해 모의투자
  환경에서도 NXT 시세까지 제공드리고 있습니다"; an explicit guarantee that
  the mock server's real-time 체결 (0B) is the actual market data verbatim
  does not exist in any official document (checked — absent).
- Official SDK demo constraint (2026-11-06): `DemoUnsupportedError`
  (return code 8104) — the API exists but is unserved in demo; evidenced
  examples: 환율 and 주문가능금액 queries rejected on demo.
- ka10080 spec (official, collected 2026-11-06): POST /api/dostk/chart;
  request stk_cd / tic_scope ("1:1분,3:3분,5:5분,10,15,30,45,60") /
  upd_stkpc_tp (0 or 1) / base_dt (optional, YYYYMMDD); continuous paging
  through the cont-yn / next-key headers; response `stk_min_pole_chart_qry`
  LIST — cur_prc (sign included) · trde_qty · cntr_tm (YYYYMMDDHHmmss) ·
  open/high/low_pric · pred_pre · pred_pre_sig · acc_trde_qty.
- ka10027 spec (official, collected 2026-11-06): 국내주식>순위정보>
  전일대비등락률상위요청, POST /api/dostk/rkinfo; request mrkt_tp
  (000전체/001코스피/101코스닥) / sort_tp (1상승률~5보합) / trde_qty_cnd /
  stk_cnd / crd_cnd / updown_incls / pric_cnd / trde_prica_cnd / stex_tp;
  response `pred_pre_flu_rt_upper` LIST — stk_cls / stk_cd / stk_nm /
  cur_prc / pred_pre_sig / pred_pre / flu_rt / sel_req / buy_req /
  now_trde_qty / cntr_str / cnt; the response carries **no query-time
  field**.
- ka10027 stk_cnd enum and ELW exclusion (official spec JSON, collected
  2026-11-09 from
  raw.githubusercontent.com/Kiwoom-Securities/Kiwoom-REST-API/main/kiwoom/_data/kiwoom_api_spec.json):
  stk_cnd (한글명 종목조건) 원문 — "0:전체조회, 1:관리종목제외,
  4:우선주+관리주제외, 3:우선주제외, 5:증100제외, 6:증100만보기,
  7:증40만보기, 8:증30만보기, 9:증20만보기, 11:정리매매종목제외,
  12:증50만보기, 13:증60만보기, 14:ETF제외, 15:스펙제외, 16:ETF+ETN제외".
  **No value mentions ELW** — no documented query-level ELW exclusion
  exists. Response `stk_cls` (한글명 종목분류) has an **empty
  description**: the value table is undocumented, so stk_cls-based
  filtering has no official basis. ELW 6-char alphanumeric codes have no
  documented format rule (only the ka30009 example "57JBHH" and the
  조건검색 9001 prefix note "J: ELW").
- ka10027 ranking composition, demo measured (2026-11-09 10:0x KST,
  장중, probe bodies sha256 bd786673557e550f…/37dc7c293025c935…/482016e961570288…
  preserved at /tmp/hs-probe/): with stk_cnd="0" the page-1 up ranking
  mixes 200 rows of which 33 are non-6-digit codes; with "14" or "16" the
  demo server honors the documented value and the count drops to 7 — but
  **ELW "18064K" (stk_cls 17, flu_rt +29.90, top of the ranking) remains
  in every variant**, and the 7 residual non-digit rows include mock
  alphanumeric codes on real stock names (래블업 0147B0, 엘리스 0158S0,
  엠에스바이오 0013Y0, 메쥬 0088M0). The first live F-1 session
  (runs/fidelity-2026-11-09-demo-v2, 09:49) therefore died fail-closed at
  the 6-digit candidate contract. Consequence (REPLAY_CONTRACT §12.1):
  the code shape is the declared universe boundary; `stk_cnd="16"` is the
  pinned default (documented ETF+ETN exclusion, honored by demo). Whether
  the real server honors stk_cnd="16" identically: UNKNOWN until F-4.
- ka10027 stock names for the mobile projection (official spec + terms
  of use, recorded 2026-11-09): `stk_nm` (한글명 종목명) is a documented
  row field of the official ka10027 response spec (`pred_pre_flu_rt_upper`
  LIST, same source as the entries above). serve.py projects names only
  from RECORDED input.hcj.jsonl bodies (folded stk_cd→stk_nm at
  serve-time; no vendor call, AGENTS §0.3). Kiwoom terms of use 제5조③
  restricts query results obtained through this service to use on the
  querying device itself (자기기기 내 이용) — serving the operator's own
  recorded results to the operator's own mobile app stays inside that
  boundary. Whether a BARE stock name (stk_nm alone, no price/quote
  field) is 시세정보 has no official definition (interpretation limit,
  recorded fail-closed — the projection carries the name only as a
  recorded-verbatim dictionary value and never re-queries the vendor).
- WS 0B spec (official, collected 2026-11-06): LOGIN
  {"trnm":"LOGIN","token":…} · REG {"trnm":"REG","grp_no","refresh",
  "data":[{item,type}]} · REMOVE; inbound {"trnm":"REAL","data":[{type:
  "0B",name:"주식체결",item,values}]} — values: '10' 현재가 (부호포함) ·
  '15' 거래량 ("+매수체결,-매도체결") · '20' 체결시간 (HHmmss) · '13'
  누적거래량 · '14' 누적거래대금 · '290' 장구분 · '9081' KRX/NXT 구분;
  the value set carries **no per-trade unique identifier field** (checked).
- ka10081 주식일봉차트조회요청 (demo measured 2026-11-10, transcripts
  preserved at /tmp/hs-ka10081/REPORT.md·attempts.jsonl, agent-59; ka10081
  is **absent from the official kiwoom_api_spec.json** — every fact below
  is mock-measured, never official): `POST
  https://mockapi.kiwoom.com/api/dostk/chart` (the same path as ka10080;
  the real-domain behavior is UNVERIFIED), api-id header `ka10081`, body
  `{"stk_cd","base_dt","upd_stkpc_tp"}` — **all three fields required**
  (any missing → HTTP 200 + return_code 2). base_dt is the measured
  YYYYMMDD form; the mock answers the session date and past dates alike
  (당일 진행 봉 포함). upd_stkpc_tp "0" and "1" both answer 200 OK (the
  **difference between them is UNVERIFIED**: the mock's upd_rt is 0.00 in
  every row, so adjusted-vs-unadjusted behavior cannot be distinguished —
  the implementation pins the declared capture scope "1" and rejects the
  other value at the schema layer). Response top level: `return_code`/
  `return_msg`/`stk_cd` (an echo of the requested code — ka10080/ka10027
  bodies carry no such key)/`stk_dt_pole_chart_qry` (LIST, 600 rows per
  page, cont-yn=Y + next-key continuation present on a normal success; the
  recent-20+-completed-trading-days need fits in one page, so the declared
  capture scope never requests a continuation). Rows are 12 all-string
  fields in this order: cur_prc, trde_qty, trde_prica, dt, open_pric,
  high_pric, low_pric, pred_pre, pred_pre_sig, trde_tern_rt, upd_stkpc_tp,
  upd_rt; dt is YYYYMMDD **descending** (first row = the base_dt day's
  in-progress bar). **cur_prc carries no sign** (unlike ka10027's cur_prc)
  and closing price = cur_prc. trde_prica's unit (백만원 suspected) and
  pred_pre/pred_pre_sig's self-consistency are UNKNOWN (not cross-checked).
  TR flow ~1/s: sleepless consecutive requests → HTTP 429 + body
  return_code 5, recovered after ~1 s; 1.5 s pacing saw zero 429s (the
  sidecar paces daily_req through the shared REST pacer and retries 429
  once after 1 s, then reports the final response). At 1 TR/s a full
  ~2,500-symbol universe sweep takes ≈ 41.7 min. Production-environment
  behavior: UNVERIFIED (G2/G4).
- FCM / Android notification behavior (official Firebase + FlutterFire
  docs and plugin source, collected 2026-11-11 — the basis of the market
  alert slice): notification messages on Android are **not displayed while
  the app is in the foreground** (FlutterFire receive.md: "won't display a
  visible notification by default"; FirebaseMessagingService.onMessageReceived
  reference: "also called when a notification message is received while the
  application is in the foreground"); the app must post them itself.
  Background/terminated: the system tray displays notification messages
  automatically (onMessageReceived is not called). `android.notification.
  channel_id` applies only when "the app must create a channel with this
  channel ID before any notification with this channel ID can be received";
  without it (or an uncreated channel) FCM falls back to the manifest's
  `default_notification_channel_id` and then to the fallback channel.
  `android.priority: HIGH` means FCM "attempts to deliver high priority
  messages immediately even if the device is in Doze mode" — an attempt,
  never a delivery-time guarantee; high-priority messages that repeatedly
  fail to result in user-facing notifications are deprioritized after ~7
  days of observed behavior. Per-device throttle: 240 messages/min, 5,000/hr
  (no documented daily cap). An FCM HTTP 200 acknowledges acceptance by
  FCM, not delivery to the device. Android 8+ channel importance is fixed
  at creation; the app cannot change it afterwards (users can). The
  firebase_messaging 17.0.1 plugin source (pub-cache, read directly) posts
  foreground messages to the Dart stream only — the app posting a
  server-composed notification via the platform's NotificationManager
  cannot double-display. Delivery priority (FCM `android.priority`) and
  display intrusiveness (channel importance) are separate settings.

## Trust boundary

Facts about the platform (GitHub rules, GitHub Actions workflow semantics,
systemd timer syntax, RFC 6455 text) are **trust facts**: cite them, do not
re-derive them. What a CI run certifies is bounded to its runner and the
workflow file at that sha; it cannot see what is installed on the host, so
attestation (not CI green) has to bridge that gap. Actions the platform
already performs (branch protection, timer scheduling, TLS, SHA-256 in the
vendor docs) are **execution adapters**: delegate, do not reimplement. The
only thing Hong Scanner implements itself is the part no platform provides:
the deterministic verdict over a recorded input stream.