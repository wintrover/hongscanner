# VS-3 Event Ledger + Notification Dispatcher — 운영 기록 계약 (PR-5)

이 문서는 `tools/notify/`의 **커밋되는 계약**이다. Python 모듈
(`notify_ledger.py`·`notify_fcm.py`·`notify_dispatcher.py`·
`notify_register.py`·`notify_config.py`)은 이 문서의 상태·파일·오류
의미를 그대로 구현하며, 구현이 이 문서와 어긋나면 구현이 틀린 것이다.

- 상위 계약: docs/REPLAY_CONTRACT.md §13 (이벤트 계약),
  contracts/events/event.schema.json (불변 이벤트 팩트),
  contracts/events/delivery.schema.json (운영 전달 기록),
  docs/GATES.md, docs/ASSUMPTIONS.md "Vendor facts".
- 벤더 근거(2026-11-01 열람, 페이지 갱신 2026-10-28, AGENTS.md §0.3
  절차대로 공식 소스 대조): FCM 오류 코드 표
  (firebase.google.com/docs/cloud-messaging/admin/errors),
  전송·인증 가이드 (/docs/cloud-messaging/send-message,
  /docs/cloud-messaging/auth-server), FCM 서버 환경 요건
  (/docs/cloud-messaging/http-server-ref). 실 FCM 전송은 실측
  사전검증 단계 전까지 금지(개발 중 라이브 호출 금지 — collector와
  동일 규칙). §12의 UNVERIFIED 목록이 그 한계를 정직하게 적는다.

## 0. 아키텍처 (변경 불가)

```
Nim Core (src/hs/*, PR-4의 단일 판정 함수 step)
  이벤트 팩트의 유일한 판정 권위 — 이 디렉터리는 Core를 건드리지
  않는다. 전달 코드는 팩트를 필터·정렬·번역할 수 있으나 판정·승급·
  재작성은 금지 (REPLAY_CONTRACT §13.1)
        ↓ runs/<dir>/events.hcj.jsonl 등 생산자의 이벤트 파일
상주 notification worker (notify_dispatcher.py --watch, README §1·§11)
  ledger.hcj.jsonl과 delivery.hcj.jsonl을 **각각 단독 작성**한다:
  두 파일 모두 이 프로세스 하나가 쓰되 파일별로 배타 flock을 따로
  잡는다. 생산자 파일을 바이트 오프셋으로 tail해 LF 완결 라인 배치를
  팩트 그대로 검증·추가하고(중복 event_id는 동일 바이트만 멱등 스킵,
  불일치 중복은 거부), 같은 틱 안에서 정책 판정(§0의 어드미션
  게이트) → 중복 억제 → 관측 그룹 조립(§0·§6) → FCM HTTP v1 전송 →
  전달 기록 append(append-only + fsync)까지 수행한다.
  **실행 범위(run scope)**: worker는 감시 파일의 ingest된 바이트에서
  session_id를 학습해 그 세션의 팩트만 발송한다(§1). scope를 알기
  전(파일 부재·빈 파일·미완결 라인)에는 worklist가 비어 있다 — 과거
  ledger를 훑지 않는다(fail-closed).
  시작·종료는 세션 런처(`tools/run_session.sh`)가 명시적으로 관리하고,
  프로세스 감시·재시작은 systemd에 위임한다(§11).
        ↓ 기기 등록 (별도 프로세스)
Python register 프로세스 (notify_register.py)
  devices.jsonl(레지스트리)의 단일 작성자: bearer 인증 등록
```

- **발송 정책은 어드미션 게이트다** (사용자 결정 2026-11-11,
  docs/ASSUMPTIONS.md P27·P28). 판정은 사건마다 정확히 하나다:
  - 유니버스: `NOTIFIABLE_EVENT_TYPES` = `TOP10_ENTERED` ·
    `TOP10_EXITED` · `RANK_CHANGED` 3종. 유니버스 밖의 팩트(장애·
    replay·세션 수명·후보 계열 전부)는 ledger에 기록되지만 **절대
    발송되지 않는다** — 사용자는 고장 경보 대신 침묵을 선택했다.
    severity는 팩트의 운영 심각도 표기일 뿐 발송 여부를 결정하지
    않는다: CRITICAL 장앜 팩트도 INFO 순위 변화와 똑같이 유형으로만
    판정된다.
  - 모드(기본 = 안B): TOP10_ENTERED/TOP10_EXITED → "immediate"
    (사운드), RANK_CHANGED → "digest"(무음). 설정의 `admission`
    섹션이 이 매핑을 엄격하게 오버라이드한다(§7). "suppress" 모드는
    유니버스 밖과 같은 취급이다: `type_skipped`로만 세고 전달 기록을
    만들지 않는다(§7).
  - 판정 함수(`notify_config.admission_mode`)와 조립 함수
    (`compose_admission_units`)는 발송 경로와 재생 도구
    (`--admission-report`, §9)가 **같이 쓴다** — 재생의 판정·조립이
    실운용과 같은 코드에서 나온다.
- **관측 배치(같은 observed_at·같은 기기)당 발송은 사운드 1통 +
  무음 1통이 상한이다**: immediate로 판정된 사건들은 한 메시지로
  묶인다 — 1건이면 single(기존 개별 메시지 형식 그대로), 2건 이상이면
  summary 1통(§6). digest로 판정된 사건들은 digest 1통(§6). 사운드가
  무음보다 먼저 간다. 재시도 대기 중인 유닛은 멤버 전원이 같은
  next_due로 이연돼 다음 패스에서 **같은 멤버로 재조립**된다 — 그룹의
  부분 전달은 불가능하다. 같은 observed_at의 사건들이 서로 다른
  배치로 도착하면(앞 멤버가 이미 ACCEPTED) dedup이 우선이다: 늦은
  멤버는 자기 자신의 메시지로 간다 — 관측 그룹 상한이 중복 재전송을
  이기지 않는다(정직한 경계, test_notify가 핀).

- 3상태 3보금(전달 상태는 이벤트 팩트에 절대 병합되지 않는다,
  스키마 x-separation-rule): 중요도/신뢰는 팩트의 필드, 검증은 세션
  verify 산출물, 전달(PENDING/ACCEPTED/FAILED)은 delivery 기록이다.
  물리적 분리는 **파일·스키마 기준**이다 — ledger와 delivery는 상주
  worker 하나가 쓰더라도 서로 다른 파일·서로 다른 flock·서로 다른
  스키마로 분리되며, 팩트 recorder(Nim)와 register는 별도 프로세스다.
- 1회성 CLI 모드(`notify_ledger.py ingest`/`check`,
  `notify_dispatcher.py` 스위프)는 하위 호환으로 본문에 남는다. 이때
  dispatcher는 이벤트 ledger를 **읽기 전용**으로 소비한다: 동시
  append 중인 미완료 꼬리 라인(비-LF 종단)은 "아직 커밋되지 않은
  기록"으로 건너뛴다 — 절대 반쪽만 소비하지 않는다. 상주 worker 실행
  중에 ledger·delivery는 worker의 flock에 걸리므로 1회성 CLI의 동시
  기동은 LedgerBusy(exit 4)로 거부된다 — 단일 작성자 강제가 의도한
  동작이다.
- 모든 쓰기 파일에는 배타적 비블로킹 flock(`.lock`)이 있고 프로세스
  수명 동안 유지된다. 두 번째 작성자는 시작을 거부한다(단일 작성자
  강제, 조용한 병기 없음).
- append는 O_APPEND + fsync다: 프로세스 사망(전원 상실 제외) 후에도
  기록된 바이트는 남고, 재시작 복구는 그 위에서 성립한다.

## 1. 라인 규약 · 배치 ingest · tail 계약

- 모든 ledger·registry 파일은 UTF-8, **라인당 JSON 객체 1개, LF
  종단**이며 값은 HCJ-safe(문자열·정수만)다. float은 어디에도 없다.
- 레코드는 스키마 검증 통과 직후에만 디스크에 도달한다: 잘못된 레코드는
  중단을 낳는다(fail-closed — 조용한 스킵, 부분 append 없음).
- ingest는 소스 **전체를 먼저 검증**한 뒤 append한다: 무결한
  소스만 ledger에 들어오고, 불량 라인이 있는 소스는 아무 바이트도
  남기지 않는다. 1회성 CLI(`ingest_source`)와 상주 worker
  (`ingest_lines`)는 같은 검증·dedup 코드 경로를 쓴다.
- **상주 worker의 배치 ingest(all-or-nothing)**: tail이 모은 LF 완결
  라인 배치는 전부 검증·차등 검사를 마친 뒤에야 append된다. 배치 안에
  불량·공란·갈라진 중복(같은 event_id, 다른 바이트)이 하나라도
  있으면 아무 바이트도 append하지 않고 **오프셋도 전진하지 않으며**,
  그 배치(및 그 뒤의 모든 라인)의 전달은 중단된다 — stderr에 경보를
  낸 뒤 다음 틱에 같은 배치를 재시도한다. 조용한 스킵은 없고, 부분
  append도 없다. 해소는 생산자(세션 런처)의 책임이다.
- **tail 계약(상주 worker)**: 커밋 마커는 LF다. worker는 바이트
  오프셋을 유지하고 마지막 LF 다음 바이트부터 읽는다. 비-LF 꼬리는
  절대 소비하지 않으며 오프셋은 전진하지 않는다. 감시 파일의
  (st_dev, st_ino)가 직전 틱과 다르면 재생성·교체로 보고 오프셋 0으로
  **전체 재스캔**한다 — ledger의 event_id 멱등(동일 바이트 스킵)이
  재스캔을 안전하게 만든다. worker 크래시 후 재시작도 같다: 전체
  재스캔 + event_id dedup. `st_size < 오프셋`은 append-only 위반이며
  **LedgerFault로 종료한다(exit 4)** — 소실을 삼켜 정상처럼 보이지
  않는다. 파일 부재(FileNotFoundError)는 대기 대상이지 오류가 아니다.
  worker는 파일 규모가 작으므로 매 틱 registry·delivery·ledger 상태를
  재읽는다.
- **실행 범위(run scope) — 상주 worker의 worklist는 감시 중인 실행의
  세션으로 한정된다**: worker는 감시 파일에서 ingest한 바이트의
  `session_id`로 scope를 학습하고, 첫 검증 배치가 그 값을 프로세스
  수명 동안 고정한다(파일은 한 세션이다 — 계약). scope를 알기 전
  (파일 부재·빈 파일·아직 LF 완결 라인 없음)에는 worklist가 **0쌍**이며
  과거 ledger를 스윕하지 않는다. 다른 세션의 팩트는 `scope_skipped`로만
  세고 pair·전달 기록·재시도 스케줄을 만들지 않는다 — 그 팩트는 다른
  실행의 ledger-only 산출물이고, 오래된 시장 팩트는 실행 가능하지
  않으며(fail-closed timely delivery 위반) 재분류된 과거 팩트가 오늘의
  버스트로 나가는 것을 막는다. **cross-session grace window는 기본
  0이다**: 넓히는 것은 사용자 정책 결정이지 dispatcher 기본값이 아니다.
  배치가 여러 session_id를 담으면(파일=한 세션 계약 위반) scope를
  학습하지 않는다 — scope 미확인 상태면 stderr 경고 후 무발송
  (fail-closed), 이미 고정된 scope가 있으면 그 scope의 팩트만 발송하고
  나머지는 `scope_skipped`다. 재시작은 같은 세션 파일을 전체 재스캔해
  scope를 다시 학습하고 **이 세션의 미전달 쌍**을 재시도한다
  (ACCEPTED dedup·FAILED terminal·PENDING 재시도
  의미 불변). 감시 경로가 다른 세션 파일로 교체되면 그 팩트는
  scope_skipped로 남는다 — 새 세션은 새 worker 기동이 계약이다.
  1회성 스위프와 `--admission-report`는 unscoped다(하위 호환·주어진
  파일 그대로의 재생).

## 2. 이벤트 ledger (notify_ledger.py)

- 팩트는 생산자 파일에서 **바이트 그대로** 복사된다: ledger는 팩트를
  재작성·재정렬·보강하지 않는다. 팩트 바이트의 변형은 replay
  byte-일치를 깬다(REPLAY_CONTRACT §13.4).
- 동일 `event_id` 재-ingest: **바이트가 동일하면** 멱등 스킵(재실행
  안전), **바이트가 다르면** LedgerError로 거부 — 사실은 불변이고,
  갈라진 중복은 변형 시도다.
- `check` 서브커맨드: 전 라인 스키마 검증(엄격, 비-LF 꼬리도 위반).
- 검증은 event.schema.json의 구조적 거울이다: 닫힌 필드 집합
  (additionalProperties false), **16종 event_type 열거**(후보 3종 +
  시장 TOP10 전환 3종 TOP10_ENTERED/TOP10_EXITED/RANK_CHANGED +
  장애 5종 + replay 2종 + 세션 3종), severity/ data_quality/direction
  열거, event_id 64-lowercase-hex, observed_at 캐논 타임스탬프,
  symbol 6자리, name 문자열(최소 1자, 없어도 됨), rule_version/
  rank/previous_rank ≥ 1. previous_rank는 직전 확정 관측군의 같은
  방향 순위(없어도 됨)다.
  verification_status·전달 계열 필드는 이름으로 거부된다.

## 3. 전달 ledger (delivery.hcj.jsonl)

- delivery.schema.json의 구조적 거울 + 문서화된 상태 짝: ACCEPTED는
  `provider_message_id` 필수·`error_code` 금지, FAILED는 `error_code`
  필수·`provider_message_id` 금지, PENDING은 둘 다 금지.
- (event_id, device_id) 쌍의 상태 = 파일 순서에서 그 쌍의 **마지막
  기록**. 이전 기록은 역사로 남는다(append-only; 덮어쓰기 없음).
- `attempts`는 그 쌍의 기록된 전송 시도 수(0 = 아직 아무 것도 보냈던
  적 없음). 전송 후 기록 전 사망한 시도는 기록이 없어 attempts에
  들지 않는다 — ledger는 기록된 상태만 정직하게 센다.
- **`message_kind`(선택, 닫힌 열거 `single|summary|digest`)**: 그 쌍을
  덮은 메시지의 조립 형식(§0·§6). summary·digest도 **멤버 사건마다
  1줄씩** 기록된다 — 같은 메시지에 덮인 멤버들은 같은
  `provider_message_id`를 공유하고, 유닛의 성공·실패·재시도가 멤버
  전원의 같은 상태로 기록된다(부분 성공 상태는 존재하지 않는다).
  그룹화 이전 기록(키 없음)은 그대로 유효하다. 읽기·dedup 판정은
  이 키를 읽지 않는다 — 상태는 어디까지나 (event_id, device_id)의
  마지막 기록이 소유한다.
- `updated_at`은 dispatcher 소유 시계(ISO 8601 숫자 오프셋 KST)다.

## 4. 기기 레지스트리 (devices.jsonl, 저장소 밖)

- FCM 등록 토큰은 자격 증명이다: 레지스트리는 **저장소 밖**에만
  존재하며, notify_config가 저장소 루트 아래로 resolve되는
  registry_path·service_account_path·register_bearer_file을 하드
  거부한다(시나리오 D가 이 가드를 실프로세스로 관측한다). 새 파일은
  0600으로 생성된다.
- 레코드 2종: `{"kind":"device","device_id","fcm_token","at"}`와
  `{"kind":"token_invalid","device_id","fcm_token_hash","at"}`.
  최신 기록이 이긴다. token_invalid는 토큰의 sha256 접두어만 담는다 —
  원시 토큰은 절대 재기록되지 않는다.
- 활성 기기 = 마지막 기록이 device인 기기(token_invalid가 뒤를 잇으면
  은퇴). dispatcher는 활성 기기에만 보내고, 404 응답(§5의 UNREGISTERED
  /NOT_FOUND)을 받으면 그 토큰을 은퇴시킨다.
- 등록(notify_register.py): 설정의 register_bearer_file과 `--bearer`
  (또는 $HSNOTIFY_BEARER)를 상수시간 비교(hmac.compare_digest)로
  검증한다. 불일치 시 아무 것도 기록하지 않고 토큰을 폐기한다. FCM
  토큰은 파일 또는 stdin으로만 받는다(argv 금지 — ps 노출 차단).
  device_id는 레지스트리 신원이지 FCM 토큰이 절대 아니다
  (delivery.schema.json device_id x-ref). 같은 device_id의 재등록은
  새 device 기록 append(토큰 갱신 경로, 최신이 이긴다).

## 5. 재시도 분류 (벤더 표의 코드화 — §12 UNVERIFIED 참고)

| 응답 | 분류 | 후속 |
|---|---|---|
| 200 + `{"name": "projects/..."}` | accepted | ACCEPTED 기록 (message_id = name 원문) |
| 200 + name 없음 | permanent | FAILED `HS_NO_PROVIDER_MESSAGE_ID` — 증명 불가한 성공은 성공이 아니다 |
| 429 QUOTA_EXCEEDED | retry | PENDING 기록, 대기 ≥ max(retry_min_seconds, Retry-After) — 벤더 최초 지연 최소 1분이 라이브 기본값 |
| 503 UNAVAILABLE / 500 INTERNAL | retry | PENDING 기록, Retry-After 존중 (Retry-After 헤더가 있으면 그 값) |
| 전송 실패(응답 자체가 없음) | retry | PENDING 기록 `HS_TRANSPORT` |
| 404 UNREGISTERED **또는** NOT_FOUND | terminal | FAILED 기록(error_code 원문 보존) + 레지스트리 token_invalid(해시만) — 벤더 지시: 토큰을 제거하고 전송을 멈춘다 |
| 403 SENDER_ID_MISMATCH | terminal | FAILED 기록 + stderr 명시 오류 + **exit 3** — 설정 오류는 fail-closed, 재시도 없음, 나머지 기기는 계속 서빙 |
| 그 외 전부 (400, 401, 418, …) | permanent | FAILED, 오류 코드 **원문 보존** (집합은 열려 있고, 알 수 없는 코드는 성공·재시도로 지도되지 않는다) |
| 페이로드 > 4096바이트 | permanent | 전송 전 거부, FAILED `HS_PAYLOAD_OVER_LIMIT` |

- **404의 두 이름은 같은 상태다**: FCM 오류 표(firebase.google.com/
  docs/cloud-messaging/admin/errors)는 무효 토큰을 UNREGISTERED
  (HTTP 404, "remove this registration token from the app server and
  stop using it")로 부르고, REST wire의 error 객체는 google.rpc
  코드명을 쓴다 — 404의 canonical 코드명은 NOT_FOUND다. 실측
  wire(2026-11-03 delivery ledger, docs/GATES.md 증거 로그): 무효
  토큰 전송에 **HTTP 404 + `error.status "NOT_FOUND"`**로 답했고
  "UNREGISTERED" 문자열은 wire에 오지 않았다. 따라서 404는 두 코드명
  어느 쪽이든 은퇴 경로로 분류한다. **NOT_FOUND가 404가 아닌 다른
  HTTP 상태와 함께 오면 이 상태가 아니다** — 그 외 전부 행의 원문
  permanent 분류를 유지한다(잘못된 은퇴 추측 금지).
- `HS_` 접두사는 스캐너 합성 코드다(전송 전 거부·전송 불능). 그 외
  error_code는 벤더 응답의 `error.status` 원문이며, 없으면
  `HTTP_<status>`다.
- 백오프 대기가 backoff_cap_seconds를 넘으면 그 쌍은 **보류(PENDING)
  로 남고** 1회성 스위프는 끝난다(외부 스케줄러가 재개). 영구 실패로
  포장되지 않는다.
- 1회성 스위프의 in-sweep 재시도: 스위프는 due가 없어도 보류 쌍이
  남아 있으면 (cap 이내의) 다음 due까지 대기 후 재시도한다.
- **상주(--watch) 모드의 재시도는 틱 사이 이연이다**: 재시도 대기는
  `next_due[pair] = now + wait`로 기록될 뿐, 그 틱 안에서 잠들지
  않는다(in-sweep sleep 없음). 429 Retry-After 60초 대기 중에도 다음
  틱의 새 이벤트 전송은 막히지 않는다. PENDING 쌍은 due가 도래한 틱에
  재시도된다. "backoff_cap 초과 시 외부 스케줄러에 park" 개념은
  상주 모드에 적용되지 않는다 — worker 자신이 재개 주체이므로 대기
  값에 cap을 적용하지 않고 그대로 이연한다.

## 6. FCM 메시지와 정직성

- 공식 경로인 **notification+data 메시지**만 보낸다(데이터 전용+로컬
  표시는 비공식 패턴으로 금지):
  `POST https://fcm.googleapis.com/v1/projects/<project>/messages:send`,
  본문 `{"message": {"token", "notification": {"title","body"},
  "android": {"priority", "notification": {"channel_id"}},
  "data": {str: str}}}`. dispatcher가 허용목록 밖 유형을 먼저 차단하므로
  실제 도달하는 이벤트는 TOP10 3종이고, 그 조립은:
  - title = `"홍스캐너 TOP10 변화"`;
  - body = `<name 또는 symbol> <상승|하락> TOP10 <순위 문안>` — name이
    없으면 symbol, 둘 다 없으면 event_type(번역은 이름을 발명하지
    않는다). direction UP→"상승"·DOWN→"하락", direction이 없으면 그
    단어를 뺀다. 순위 문안은 팩트가 담은 그대로: previous_rank와 rank
    모두 있으면 `<prev>위 → <rank>위`(기존진입·순위변경·밖이탈),
    rank만 있으면 `신규 진입 <rank>위`(신규진입), previous_rank만
    있으면 `<prev>위 → 후보 제외`(후보제외), 둘 다 없으면 순위 문안
    없음(순위도 발명하지 않는다);
  - `android.priority` = `"high"`(3종 전용 경로, 심각도와 무관)와
    `android.notification.channel_id` = `"market_rank_changes"`;
  - data는 event_id/event_type/severity + direction/symbol/
    previous_rank(있을 때)/rank(있을 때) — 값은 전부 문자열(공식
    요건; 정수는 문자열화).
  허용목록 밖 유형이 build_message에 도달하는 일은 없지만(§0), 방어
  분기로 종래의 최소 조립(title `"Hong Scanner <severity>"`, body
  `<event_type>[ <symbol>]`, severity 매핑 priority)을 유지한다 —
  정책 게이트는 dispatcher 하나뿐이고 전송 계층은 일반형을 유지한다.
- **관측 그룹 조립(§0의 상한을 만드는 두 형식)**: 배치의 immediate
  사건이 2건 이상이면 **summary 1통**이 사운드를 대신한다 — title
  `"홍스캐너 TOP10 변화"`, body는 앞 2사건(ledger 순서)의
  `<종목명|심볼> <진입|이탈>`을 "·"로 잇고 나머지는 ` 외 N건`,
  priority "high"·channel `market_rank_changes`(single과 같은 사운드
  경로). 배치의 digest 사건들은 **digest 1통**(무음) — title
  `"홍스캐너 TOP10 순위 요약"`, body는 첫 사건의 `<종목명|심볼>
  <prev>위→<rank>위`(rank만 있으면 `신규 진입 <rank>위`,
  previous_rank만 있으면 `<prev>위→후보 제외`, 둘 다 없으면 순위
  문안 없음 — single과 같은 정직성 규칙, 발명 금지) + ` 외 N건`,
  priority **"normal"**·channel `market_rank_digest`.
- **data 계약은 형식별로 다르다**: single은 개별 필드(event_id/
  event_type/severity/direction/symbol/previous_rank/rank, §6 첫
  항목)만 실는다. 그룹 메시지(summary·digest)는 **kind / event_ids
  (쉼표 결합, ledger 순서, 전체 멤버) / count(문자열)**만 실는다 —
  kind·event_ids·count는 single에 없고, 개별 필드는 그룹에 없다.
  앱은 다이제스트 1통의 event_ids로 그 배치의 전체 사건에 접근한다
  (탭 → 전체 사건 목록).
- **페이로드 한도 4096바이트(키·값 포함, 벤더 명시)는 그룹 조립에도
  똑같이 적용된다**: 전송 전 검사이며 초과는 전송 전 거부(FAILED
  `HS_PAYLOAD_OVER_LIMIT`, 멤버 전원 기록, §5) — 잘린 조립을
  보내지 않는다. 40사건 그룹은 수용되고(합성 게이트 핀) 100사건
  그룹은 거부된다.
- **Android 우선순위**: 메시지는 `android.priority`를 항상 명시한다 —
  사운드 경로(single·summary)는 **"high"**, 무음 다이제스트는
  **"normal"**이고 둘 다 `channel_id`를 지정한다. 기본값에
  대해서는 공식 문서가 **상충한다**: REST v1 reference는 HIGH가
  "Default priority for notification messages"라고 쓰고, 가이드는
  "Normal priority. This is the default priority for data and
  notification messages"라고 쓴다(둘 다 2026-11-11 대조, 가이드
  2026-11-10 갱신분). 미설정 시 실효 priority는 공식 산문만으로는 확정
  불가이므로 **명시가 유일한 확실 경로**다 — 어느 쪽 기본값 주장도
  하지 않는다.
- **HIGH는 전달 시도이지 표시 보장이 아니다**(공식 가이드, 2026-11-10
  갱신분 2026-11-11 대조): "If FCM detects a pattern in which messages
  don't result in user-facing notifications, your messages may be
  deprioritized to normal priority or delegated for handling by
  Google Play services" — 앱 인스턴스별 최근 7일 행동으로 판정한다.
  TOP10 알림은 사용자에게 보이는 notification이므로 이 요건에 부합
  한다. `channel_id`는 앱이 그 채널을 **수신 전에 생성**해야 한다
  (공식: 생성되지 않은 채널 id면 manifest의 값으로 폴백) — 채널
  생성은 앱 측 책임이다(PR-7, §12).
- **accepted ≠ delivered**: HTTP 200은 FCM의 접수 증명일 뿐이다.
  도착 시각·순서·기기 표시·열람은 어떤 보장도 없고(REPLAY_CONTRACT
  §13.5) 어떤 기록에도 도착으로 쓰지 않는다.
- **전송 도중 사망의 정직한 중복**: dispatcher가 전송(또는 전송 중)에
  죽으면 전달 기록이 없으므로 재시작 후 그 쌍은 재전송된다 — 기기가
  같은 알림을 두 번 받을 수 있다. 이것은 FCM 현실이며 숨기지 않고
  기록한다; 앱 측 event_id 중복 식별이 전제다(드릴 시나리오 B).
- **중복 억제**: ACCEPTED인 쌍은 정책·기기가 같아도 절대 재전송하지
  않는다(드릴 시나리오 A). FAILED는 단말이다(재시도 금지).

## 7. 설정 (저장소 밖, --config 또는 $HSNOTIFY_CONFIG)

```json
{
  "project_id": "<firebase project>",
  "ledger_path":    "/abs/ledger.hcj.jsonl",
  "delivery_path":  "/abs/delivery.hcj.jsonl",
  "registry_path":  "/abs/outside-repo/devices.jsonl",
  "register_bearer_file": "/abs/outside-repo/bearer.secret",
  "retry_min_seconds": 60,           // 라이브 기본 = 벤더 최소 1분
  "backoff_cap_seconds": 900,
  "watch_poll_seconds": 1.0,         // 상주 worker 틱 간격, 0 < x <= 60
  "service_account_path": "/abs/outside-repo/sa.json",  // 또는 아래
  "token_command": ["gcloud", "auth", "application-default",
                    "print-access-token"],
  "admission": {"RANK_CHANGED": "digest"}     // 선택: 안B 위 오버라이드
}
```

- **`admission` 섹션(선택)**: 유니버스 3종(TOP10_ENTERED/
  TOP10_EXITED/RANK_CHANGED)의 모드 매핑 오버라이드. 값은
  `{"<event_type>": "immediate"|"digest"|"suppress"}` 객체다.
  검증은 엄격하다 — 객체가 아니거나, 유니버스 밖 event_type 키거나,
  모드 어휘 밖 값이면 ConfigError(exit 2). **부분 매핑은 거부가
  아니다**: 명시된 유형만 안B 기본값을 덮고 나머지는 기본값을
  유지한다(P28 문언: 섹션은 기본 정책의 오버라이드). 섹션이 없으면
  기본값(안B)으로 동작하고 `--admission-report`(§9)가 그 사실을
  출력 첫 줄에 명시한다(`admission policy source=default`) — 섹션
  없음이 설정된 정책과 혼동되지 않는다.

- **`min_severity`는 제거됐다** — 발송 정책은 §0의 어드미션 게이트로
  옮겨갔다. 설정 파일에 키가 남아 있으면 **무시된다**
  (검증하지도 않는다): 알 수 없는 키 관용 정책은 그대로다. 라이브
  설정 편집은 운영 단계의 몫이다.

- dispatch는 두 자격 경로 중 **정확히 하나**를 요구한다:
  서비스 계정 JSON(저장소 밖 경로에서 로드, RS256 JWT 교환) 또는
  token_command(플랫폼 위임 — 공식 클라이언트가 자기 네이티브
  저장소를 다룬다, collector의 kiwoomcli 선례). 토큰 만료 60초 전에
  재발급한다.
- `watch_poll_seconds`(상주 worker 틱 간격, 기본 1.0)는
  `0 < x <= 60` 실수여야 한다 — 위반은 ConfigError(exit 2)다. 0 이하는
  스핀, 상한 초과는 전달 지체를 낳는다. §1의 배치·tail 계약이 주기의
  정확성에 의존하지 않는다(오프셋·LF·dedup이 정확성을 소유한다).
- suppress로 판정된 사건(유니버스 밖, 또는 `admission`의 suppress
  모드)은 **전달 기록을 만들지 않는다** — 차단은 `type_skipped`
  요약 카운터로만 센다(§9). 정책은 전송 계층의 결정이지 사실의
  변경이 아니다. 기록 없는 스킵은 가짜 PENDING을 만들지 않는다.
- 엔드포인트 오버라이드는 존재하지 않는다: FCM/OAuth URL은 공식
  값으로 고정(fail-closed, collector의 도메인 고정 선례).

## 8. 자격 증명과 마스킹

- 토큰 값(FCM 등록 토큰, OAuth 액세스 토큰, bearer 시크릿)은 프로세스
  메모리와 저장소 밖 파일에서만 존재한다. 로그·stdout·delivery
  기록·ledger·이벤트 팩트 어디에도 쓰이지 않는다 — 필요한 곳엔
  `sha256:` 접두어 마스크만 간다.
- RS256 구현은 순수 표준 라이브러리다(RFC 8017 RSASSA-PKCS1-v1_5
  over SHA-256, PKCS#8/PKCS#1 PEM 파서 포함). 외부 crypto 의존성은
  추가하지 않는다(collector 의존성 규율: 새 pip 의존성 금지). 정확성은
  RFC 7515 A.2 **공식 벡터**로 게이트에서 핀된다(그 JWK는 RFC가
  공개·폐기 선언한 테스트 전용 키이며 자격 증명이 아니다).

## 9. exit 코드 (이 문서가 정의한다)

| 코드 | 의미 |
|---|---|
| 0 | 스위프 정상 완료 (보류 PENDING·외부 재개 포함), 상주 worker의 정상 종료(SIGTERM/SIGINT) 또는 admission report 출력 완료 — 정상이 보류를 숨기지 않는다: 요약 라인이 세어 보인다 |
| 2 | 사용법·설정 계약 위반 (설정 거부, bearer 거부, 잘못된 device_id, --admission-report 상대경로·부재 파일·--watch 병용) |
| 3 | 자격 경로 실패 또는 fail-closed SENDER_ID_MISMATCH — 설정 오류는 절대 깨끗한 성공이 아니다 |
| 4 | 단일 작성자 충돌(다른 프로세스가 lock 보유) / 내부 결함 / ledger 계약 위반 (톰 보고 입력 포함) |

- 실패를 성공으로 꾸미는 경로는 존재하지 않는다. dispatcher의 스위프
  요약(`sweep {...}` JSON 라인)은 세친 사실만 보고한다 — 이벤트
  총수(`events_total`), 정책이 suppress로 판정한 수(`type_skipped`),
  전송 후보 쌍(`pairs_to_send`)과 outcome 카운터가 모두 그 안에
  있다. 상주 모드의 누적 카운터 `messages_sent`는 **시도한 메시지
  수**다(사건 수 아님 — 관측 그룹 유닛 1통이 여러 사건을 덮는다).
  `scope_skipped`는 마지막 틱에서 실행 범위 밖(다른 세션)으로 걸러진
  팩트 수다(전달 기록 없음, §1). `type_skipped`는 scope 안에서 정책이
  suppress로 판정한 수만 센다 — 범위 밖 팩트는 어드미션 판정 전에
  제외된다.
- **`--admission-report <abs events 파일>` — 재생 도구**: 발송도
  원장 기록도 없이(Dispatcher를 만들지도 않는다) 파일의 모든 사건을
  실운용과 **같은 어드미션 코드**(admission_mode·
  compose_admission_units)로 판정해 stdout에 출력한다. 출력 구조:
  첫 줄 `admission policy source=<default|config>` + 전체 매핑(섹션
  없음이 설정 정책과 혼동되지 않게), 사건별 판정 1줄씩(`verdict=
  ADMIT|DIGEST|SUPPRESS`, form=single|summary|digest|suppress|
  not_in_admission, 파일 순서), 관측 그룹별 발송 요약
  (`admission group ... events=N sound=S silent=D`)과 조립 플랜
  (`admission plan ... kind=K count=N title=... body=...
  event_ids=...` — 4096 초과 조립은 `refused=HS_PAYLOAD_OVER_LIMIT`),
  총계 라인. 시계가 없으므로 **같은 입력·같은 config면 바이트 단위로
  동일**하다. config 검증은 "dispatch" 역할로 실운용과 같은 경로를
  지난다(재생==실운용 정책).

### 상주(--watch) 모드의 종료·시그널

- **SIGTERM/SIGINT는 정상 종료다**: 플래그만 set하고 현재 틱을 마친
  뒤(반쪽 배치·반쪽 전송 없음) flock을 해제하고 **exit 0**을 낸다.
  systemd `Restart=on-failure`는 exit 0을 재시작하지 않는다.
- 시작 오류는 기존 코드 그대로다: 설정 거부 2, 자격 실패 3, 단일
  작성자 충돌(이미 떠 있는 worker·CLI) 4.
- 실행 중 계약 위반은 종료다: 감시 파일 축소(`st_size < 오프셋`)·
  I/O 결함은 LedgerFault로 **exit 4**. 배치 검증 실패는 종료가 아니라
  stderr 경보 + 다음 틱 재시도다(§1) — 로그에 refused가 계속 보이는
  것이 의도된 관측이다.
- 상주 모드의 모든 stdout 라인은 ISO 타임스탬프 접두를 갖는다
  (`watch start`·`watch open`·`watch tick ...`·`dispatch
  attempt_start ...`·`dispatch result=...`·`watch stop {...}`).

## 10. 드릴과 테스트 (모두 합성 — 네트워크 0, 실자격 0)

- `bash tools/notify/test_notify.sh`: unittest 계약 스위트. 실제
  모듈을 가짜 urllib 전송과 temp ledger로 in-process 구동. RFC 7515
  A.2 벡터(서명·키 파싱·JWT 형상), 스키마 검증 전표(16종 event_type,
  previous_rank/name, delivery `message_kind` 닫힌 열거·선택성),
  ledger 멱등·거부 규칙(1회성 ingest와 상주 배치 `ingest_lines` 모두),
  dispatcher 상태기계 전체(정상·중복 억제·429/404/403·영구·전송
  실패·기록 소실 복구·유형 필터·ledger 순서 소비), **admission 섹션
  검증**(부재 시 안B 기본·출처 명시, 엄격 거부, 부분 매핑 병합),
  **관측 그룹 상태기계**(다이제스트 1통 전체 event_id 커버·멤버별
  기록·같은 provider_message_id, 혼합 배치 summary+digest, single
  형식 불변, dedup 우선·재스윕 무전송, 429 재조립·같은 event_ids,
  404 유닛 실패·토큰 1회 은퇴, suppress 모드=type_skipped,
  observed_at 경계, 같은 입력·정책 바이트 재현), **그룹 조립**
  (summary/digest 문안·data 계약(kind/event_ids/count)·4096 그룹
  한도(40 수용·100 거부)·결정론·순서 결속), TOP10 문안 5케이스
  (신규진입·기존진입·순위변경·밖이탈·후보제외)+심볼 폴백+channel_id·
  priority(single/summary=high, digest=normal)·data 필드 단언과
  방어용 일반 조립, min_severity 미검증, watch_poll_seconds 경계,
  상주 watch 틱 계약(비-LF 꼬리 미소비·배치 all-or-nothing·(dev,ino)
  전체 재스캔·틱 사이 재시도 이연·shrink LedgerFault·관측 그룹 경계),
  **실행 범위**(과거 세션 팩트 무발송·scope 미확인 틱 0발송·재시작 후
  같은 세션 미전달 쌍 재전송·세션 내 suppress 유지),
  **admission report**(사건별 판정 전표·첫 줄 policy source·플랜
  미러·바이트 동일 재생·발송 경로와 같은 compose 증명·거부 플랜·CLI
  exit 0/2/4·ledger 미생성), 그리고 실 OS 프로세스 1건(SIGTERM 정상
  종료 exit 0 + 재기동 전체 재스캔 멱등 — 같은 events 파일로 중복
  append 없음).
- `bash tools/notify/drill/drill_fcm.sh`: 프로세스쌍 드릴(collector의
  drill_pair 패턴 재사용). REAL CLI들을 별도 OS 프로세스로,
  `fakesite/sitecustomize.py`가 HSDRILL=1일 때만 urllib.urlopen을
  가짜 FCM 백엔드로 패치(공식 URL·bearer 강제, device별 응답
  스크립트, SEND 마커 후 지연 삽입으로 SIGKILL 창 결정화,
  wirelog는 토큰 해시만). 시나리오:
  - **A** 정상 전달(ingest→register→dispatch→ACCEPTED) + 두 번째
    dispatch 0 재전송(ACCEPTED 중복 억제) + ledger 바이트 불변;
  - **B** SEND 마커 관측 후 SIGKILL → 전달 기록 부재 확인 → 재시작
    재전송 → ACCEPTED (솔직한 중복의 와이어 증거: 동일 쌍 SEND 2회);
  - **C** 429(Retry-After 존중, 와이어 타임스탬프 간격 ≥1s, PENDING
    →ACCEPTED attempts 1→2) / 404 두 코드명 모두(실측 wire 형태
    NOT_FOUND와 오류 표 형태 UNREGISTERED 각 1기기 — FAILED 기록 +
    레지스트리 token_invalid 해시만, 재실행 무전송) / 403(FAILED
    SENDER_ID_MISMATCH + exit 3, 타 기기 계속 서빙) + 재실행 0 전송;
  - **D** 저장소 안 registry_path 거부(exit 2), 잘못된 bearer 등록 0건.
  증거는 `runs/drill-fcm-<ts>/`(gitignored): wire 로그, dispatcher
  stdout/stderr, delivery·이벤트 ledger, 레지스트리 **마스크드**
  프로젝션. 드릴은 증거 트리에 자격증명 값이 하나라도 나오면 실패한다.
  wall-clock 제약 없음(watchdog 없음).
- `bash tools/notify/drill/drill_watch.sh`: 상주 worker 프로세스쌍
  드릴(drill_fcm의 fakesite·증거·자격 누출 검사 패턴 재사용). REAL
  `notify_dispatcher.py --watch`를 백그라운드 OS 프로세스로 띄워
  생산자 파일(watch_poll_seconds=0.2)을 tail하게 한다. 시나리오:
  - **W1** 증분 tail: 완결 라인 N틱 내 발송, 반쪽 라인(비-LF) 미소비
    (SEND·ledger 카운트 불변), LF 도달 후 발송, 5건 1회 write 폭주는
    **다이제스트 1통**으로 전달(누락 0, 와이어 `SEND digest
    count=5`), 혼합 배치(진입+이탈+순위변화 2건, 같은 observed_at)는
    **summary 1통 + digest 1통** — delivery 기록 11행(single 2·
    summary 2·digest 7, provider_message_id 그룹 크기 1,1,2,2,5,
    전부 ACCEPTED);
  - **W2** SIGKILL 후 재시작: 전체 재스캔 멱등(appended=0 dup=2,
    재전송 0, ledger 불변; 살해 전 두 사건은 summary 1통이었음) +
    재시작한 worker가 신규 이벤트 tail 지속;
  - **W3** 429 Retry-After 3s 이연은 비블로킹: 직후 신규 이벤트 즉시
    발송(와이어 ts 간격 <1.5s), 지연된 재시도는 스케줄대로(≥2s,
    PENDING→ACCEPTED attempts 1→2) — single 와이어 형식 유지;
  - **W4** 감시 파일 축소(st_size < offset) → LedgerFault exit 4,
    재전송 없음(두 사건 = summary 1통이므로 SEND 1회).
  증거는 `runs/drill-watch-<ts>/`(gitignored). systemd 유닛 생명주기
  (run_session.sh)는 여기 없다 — 라이브 세션 증거다(§12).

## 11. 빌드·게이트 통합

- Python 3.13 표준 라이브러리만(의존성 추가 없음, venv 불필요).
  인터프리터 해석 순서는 collector 스위트와 같다:
  `$HSCOLLECTOR_PYTHON` → `python3.13` → `uv python find 3.13`.
- 게이트: `bash tools/run_tests.sh` exit 0 + `ALL CONTRACT SUITES
  PASSED`. 등록 라인: `run bash tools/notify/test_notify.sh`,
  `run bash tools/notify/drill/drill_fcm.sh`,
  `run bash tools/notify/drill/drill_watch.sh`.
- 실행(live, 별도 사전검증 단계에서만): 전달은 **상주 notification
  worker 하나**가 담당한다(`notify_dispatcher.py --watch
  <abs events 파일>`). 세션 런처 `tools/run_session.sh`가 collector
  인자를 그대로 전달하며 worker에 이 세션의 events 파일 경로를
  넘기고 시작·종료를 명시적으로 관리한다: collector는 포그라운드,
  worker는 `systemd-run --user --unit=hsnotify-<session>`(Type=exec,
  Restart=on-failure, RestartSec=2, —collect 없이 — failed 상태
  관측 보존)의 transient unit이고, 런처 trap EXIT에서 유닛을 명시적
  stop한 뒤 ActiveState·ExecMainStatus를 런처 로그
  (`runs/<session>.launcher.log`, collector exit 4의 사유 캡처 포함)에
  기록하고 reset-failed로 정리한다 — transient unit의 부모는 service
  manager라 런처 종료만으로 worker가 죽지 않기 때문에 명시적 stop이
  계약이다. worker의 프로세스 감시·재시작은 systemd에 위임한다:
  SIGTERM 정상 종료(exit 0)은 재시작을 유발하지 않고, 계약
  위반·결함 종료(3·4)만 재시작한다. systemd 미사용 폴백(백그라운드
  프로세스)은 **개발·시험 모드로만** 런처 로그에 마킹한다 — 운영
  성공이 아니며, 실운영 승인 조건에 systemd 사용은 필수다.

## 12. UNVERIFIED·사전 검증 목록 (merge 후 실측 항목)

- 합성 테스트로 계약을 핀한 것(이 슬라이스, 실측 아님): 상주 watch의
  틱 계약 전반 — 비-LF 꼬리 미소비, 배치 all-or-nothing·멱등,
  (dev,ino) 전체 재스캔, 틱 사이 재시도 이연(429 중 신규 이벤트
  지속), shrink LedgerFault, watch_poll_seconds 검증, SIGTERM 정상
  종료 + 재기동 멱등(서브프로세스), **실행 범위**(scope 미확인 0발송·
  과거 세션 scope_skipped·재시작 미전달 재전송·세션 내 suppress);
  **admission 게이트**(기본 안B·
  admission 섹션 엄격 검증·부분 병합·suppress=type_skipped·전달 기록
  미생성); **관측 그룹 발송**(배치당 사운드 1+무음 1 상한·summary/
  digest 조립 문안·그룹 data 계약 kind/event_ids/count·멤버별 기록·
  같은 provider_message_id·4096 그룹 한도(40 수용·100 거부)·재시도
  재조립·dedup 우선의 분할 도착 경계·같은 입력·정책 바이트 재현);
  **--admission-report**(사건별 판정 전표·policy source 첫 줄·플랜
  미러·바이트 동일 재생·발송 경로와 같은 compose·CLI exit 0/2/4);
  TOP10 문안 5케이스·channel_id·priority(single/summary=high,
  digest=normal)·data 필드(single 개별 필드·그룹 kind/event_ids/
  count), min_severity 미검증.
- **범위 밖(문서로만 명시, 구현 없음)**: 시간당 총 발송량 제한,
  왕복(진입↔이탈) 상쇄, 다른 observed_at 배치의 병합 —
  docs/LIMITS.md가 그 한계를 적는다. 이 슬라이스의 상한은 관측
  배치 단위다.
- 실 FCM 실측 전체: 실 프로젝트에서의 429 Retry-After 실측 값,
  403 실측 본문 형상, message_id 실측 형상, 실 토큰 수명. 404 본문
  형상은 2026-11-03 실측됐다(HTTP 404 + `error.status "NOT_FOUND"`,
  docs/GATES.md 증거 로그 — §5의 두 코드명 은퇴 분류 근거; 404
  이외 상태의 NOT_FOUND는 실측된 바 없고 permanent로 남는다).
- OAuth 실측: 서비스 계정 JWT 교환의 실측 응답(expires_in 형상),
  token_command 경로의 실제 gcloud 출력 형상.
- 상주 worker의 실측: 세션 런처(`tools/run_session.sh`) 경유 기동·
  종료·유닛 상태 기록, systemd unit(Type=exec, Restart=on-failure)
  아래의 장시간 상주 관측, 실 세션 이벤트의 observed_at→ingest→POST
  지연 분포. watch 모드의 프로세스쌍 드릴(SIGKILL 재시작 무중복
  포함)은 `tools/notify/drill/drill_watch.sh`가 게이트에 등록돼
  있고, 실측 라이브 관측이 남아 있다.
- android.priority: 미설정 시 실효값은 벤더 문서 상충으로 확정 불가
  (§6) — 명시값의 실기기 동작도 실측 항목이다. 사운드 경로(single·
  summary)가 high로 가는 경로의 실기기 도달율·Doze 지연과 무음
  다이제스트(normal)의 실기기 표시 경로, HIGH 강등 규칙(§6,
  표시로 이어지지 않는 메시지의 7일 관찰)이 실 트래픽에서 발동하는지,
  `channel_id market_rank_changes`·`market_rank_digest`의 실기기
  표시(앱이 채널을 생성했는가 — 없으면 manifest 폴백)와 TOP10
  문안의 실기기 렌더링도 실측 항목이다(앱 측 PR-7과 공유).
- 앱 측 전제(앱의 event_id 중복 식별)는 PR-7의 구현·실측 대상이다 —
  이 계약은 그 전제를 문서로 요구할 뿐 증명하지 않는다.
- accepted≠delivered의 실측 경계(접수 후 유실 가능성)는 벤더 문서가
  보장하지 않는 영역이며, 관측 수단은 이 슬라이스에 없다.
