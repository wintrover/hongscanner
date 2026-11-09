# VS-3 Read-only API — 기록 사실 투영 계약 (PR-6)

이 문서는 `tools/api/`의 **커밋되는 계약**이다. Python 서버
(`serve.py`)는 이 문서의 엔드포인트·응답·경계 의미를 그대로 구현하며,
구현이 이 문서와 어긋나면 구현이 틀린 것이다.

- 상위 계약: docs/REPLAY_CONTRACT.md §13 (이벤트 계약·결정론 경계),
  contracts/events/event.schema.json (불변 이벤트 팩트),
  contracts/events/delivery.schema.json (운영 전달 기록),
  tools/notify/README.md (ledger·delivery 파일 규약), docs/GATES.md.
- 설계 원칙 §13.7의 "사실은 서버 소유 · 모바일은 읽기 전용 · 불확실성을
  숨기지 않음"이 이 디렉터리의 존재 이유다.

## 0. 아키텍처와 경계 (변경 불가)

```
run 디렉터리들 (runs/<dir>/, recorder·verify가 쓴 기록)
  run.json · input/bars/signals/events.hcj.jsonl · CHECKSUMS.sha256
  input.hcj.jsonl.committed · (운영자가 남긴) verify.stdout
event ledger (--ledger, notify_ledger가 단일 작성자)
  ledger.hcj.jsonl — 이벤트 팩트, append-only
delivery ledger (--delivery, dispatcher가 단일 작성자)
  delivery.hcj.jsonl — (event_id, device_id) 전달 상태, append-only
        ↓ 읽기 전용 투영 (이 디렉터리, 유일한 역할)
HTTP 서버 (serve.py, 기본 127.0.0.1 바인드, GET 전용)
```

- 이 API는 **기록된 사실의 읽기 전용 투영**이다. 판정하지 않고,
  재생하지 않고, 어떤 값을 새로 계산해 사실로 만들지 않는다. 응답은
  (1) 기록된 레코드의 투영, (2) 계약이 명시한 저렴한 재도출 —
  CHECKSUMS.sha256 대조용 sha256 재계산, 마커·기록 존재 확인 — 과
  (3) §3.7이 명시한 **유계 폴딩 투영** — 선택된 하나의 런에 기록된
  이벤트 팩트를 접고, 기록된 필드로 정렬·선출·계수하는 순수 계산 —
  만 담는다. 폴딩도 새 사실을 만들지 않는다: 랭크·순서·카운트는
  전부 기록된 값이다.
- **Nim verify 바이너리 실행은 이 API 프로세스의 범위 밖이다.** API는
  replay·verify를 실행하지 않으며, `VERDICT` 판정은 운영자가 런
  디렉터리에 남긴 기록 파일(`verify.stdout`)을 **원문 그대로 인용**할
  뿐이다. 기록이 없으면 "기록 안 됨"으로 응답한다 — 위조·추정은
  없다(REPLAY_CONTRACT §0.2: 실패·미확정을 성공·확정으로 표현하지
  않는다).
- 이 프로세스는 어떤 파일의 단일 작성자도 아니다: 아무 것도 쓰지
  않는다. ledger·delivery는 읽기 전용으로 소비하며, notify와 동일한
  읽기 규약을 따른다 — 미완료(비-LF 종단) 꼬리 라인은 "아직 커밋되지
  않은 기록"으로 건너뛴다. 반대로 **커밋된 라인이 불량이면
  fail-closed**로 해당 엔드포인트가 HTTP 500을 낸다(조용한 스킵으로
  오염을 숨기지 않는다).
- 구동은 명시적 시작뿐이다: 데몬화·systemd·자동 기동·상주 감시는 범위
  밖이다.

## 1. 구동

```sh
python3.13 tools/api/serve.py \
  --runs  /abs/runs \
  --ledger /abs/ledger.hcj.jsonl \
  --delivery /abs/delivery.hcj.jsonl   # 선택
  --port 8080                          # 0 = 임시 포트
  --bind 127.0.0.1                     # 선택, 기본 127.0.0.1
```

- 바인딩 기본값은 **127.0.0.1**이며 옵션 없이 붙는다. `--bind <IPv4>`는
  기본값을 바꾸는 유일한 창구다. 허용 값은 구체적 IPv4 유니캐스트
  주소(루프백·사설·링크로컬 포함)와 **0.0.0.0**뿐이다. 멀티캐스트
  (224.0.0.0/4), 브로드캐스트 255.255.255.255, 예약 블록
  (240.0.0.0/4, 0.0.0.0/8의 나머지), IPv4 형식 밖의 모든 문자열은
  **소켓이 생기기 전 사용법 오류(exit 2)**로 거부된다. 형식이 맞는
  주소를 OS가 열지 못하면 기존 바인드 실패 경로(exit 4)다.
- **기본 호출의 동작은 완전히 불변이다**: `--bind`를 주지 않으면
  바인드 주소·SERVE 줄·종료 코드가 옵션 도입 이전과 다르지 않다.
- **`--bind 0.0.0.0`은 Northflank ingress 뒤 컨테이너 전용이다.**
  0.0.0.0은 접근 통제가 아니다: 이 API에는 인증이 없고, 0.0.0.0
  바인드의 접근 통제는 플랫폼(Northflank ingress Basic Auth)에
  위임된다. 플랫폼 ingress 뒤가 아닌 0.0.0.0(또는 그 외 비루프백
  인터페이스 주소)의 인터넷 직접 노출은 이 계약 위반이다. 로컬
  운영은 기본값을 쓴다(옵션 없음 = 루프백만).
- 기동에 성공하면 stdout에 한 줄 `SERVE <바인드주소>:<port>`를 찍고
  flush한다 — 주소는 OS가 확인한 실제 바인딩이다. 스크립트는 이 줄로
  실제 주소와 포트를 읽는다.
- 종료는 SIGTERM/SIGINT로 한다: 서버가 조용히 드레인하고 exit 0으로
  끝난다. 기동 실패는 exit 코드로 끝난다: 2 = 사용법·설정 위반
  (존재하지 않는 --runs, 포트 범위 위반, --bind 거부), 4 = 바인드
  실패. 실패를 exit 0으로 꾸미는 경로는 없다.
- 데이터는 요청마다 파일에서 다시 읽는다: 상태 캐시가 없고, 서버
  재시작 없이 ledger·런 디렉터리의 갱신이 응답에 반영된다. **유일한
  예외는 §3.7의 종목명 사전이다**: 입력 바이트의 순수 파생(기록된
  ka10027 본문의 stk_nm)이라 (path, size, mtime_ns) 키로 프로세스 내
  메모이제이션된다(§3.7의 게시 조건·한계 참조). 이벤트 폴드와 응답
  본체는 여전히 매 요청 재계산이다.

## 2. JSON 규약

- 모든 응답 본문(성공·오류 모두)은 **canonical JSON**이다: UTF-8,
  compact 구분자, **키 코드포인트 오름차순 정렬**(HCJ canonical과 같은
  규율), 끝에 LF 1개. float은 어디에도 없다(문자열·정수·불리언·null·
  배열·객체만).
- `Content-Type: application/json; charset=utf-8`, GET 전용, HTTP/1.1,
  응답마다 연결을 닫는다.
- **null의 의미**: 값이 아니라 "기록 부재"다. 0과 다르다. 예: ledger
  파일이 아직 없을 때 `/status`의 `events.count`는 0이 아니라 null이다.
- 이벤트 배열의 순서는 **ledger 파일 순서**(단일 작성자 append 순서)다.
  API가 재정렬하지 않는다. 세션 목록은 런 디렉터리 이름 코드포인트
  오름차순이다. 유일한 예외는 `/mobile/market-view`(§3.7)이다: 그
  배열의 순서는 §3.7이 직접 규정한다 — `history`는 선택된 런의
  events 파일 순서, top10은 폴드 규칙(rank 오름차순)이다.
- 오류 본문: `{"error": {"code", "message"}}`. message는 요청 값을
  재출력하지 않고, 파일 이름만 담는다(절대 경로 비노출).

## 3. 엔드포인트 (전부 GET, 쓰기 경로 전무)

식별자 두 가지를 구분한다:

| 이름 | 뜻 | 예 |
|---|---|---|
| `session` | **런 디렉터리 이름**(파일시스템의 기록 단위) | `smoke-2026-11-02-885b009` |
| `session_id` | 레코드 안 세션 스킴 id (VS-1에서 session_date) | `2026-10-29` |

이벤트 계열 엔드포인트(`/candidates`, `/events`)의 권위는 **event
ledger**다. 런 디렉터리의 `events.hcj.jsonl`은 검증 엔드포인트에서
해시 대상 아티팩트로만 다룬다. **예외 §3.7**: `/mobile/market-view`는
run-범위 원천 — 선택 규칙이 고른 하나의 런 디렉터리의
`events.hcj.jsonl` — 을 읽는다. 이벤트에는 run_id가 기록되지
않으므로(스키마 x-event-id-rule: run_id는 event_id 다이제스트에만
들어간다) 같은 날짜의 재시작 런들이 섞인 ledger를 session_id로 접으면
유령 오염이 생긴다 — run-범위 파일은 그 오염을 갖지 않는다.

### 3.1 `GET /status` — 최신 세션·이벤트·전달 요약

```json
{
  "delivery": {"by_state": {"ACCEPTED": 1, "FAILED": 1, "PENDING": 1},
               "configured": true, "devices": 2, "pairs": 3, "present": true},
  "events": {"by_severity": {"HIGH": 1, "INFO": 3},
             "by_type": {"CANDIDATE_ENTERED": 2, "CANDIDATE_EXITED": 1,
                         "SESSION_ENDED": 1},
             "count": 4,
             "latest_event": {"event_id": "e4…", "event_type":
                              "CANDIDATE_EXITED", "observed_at": "…"},
             "latest_session_id": "2026-10-30",
             "ledger_present": true},
  "sessions": {"count": 4,
               "latest": {"code_commit": "885b…", "run_id": "…",
                          "run_json_present": true, "session": "run-…",
                          "session_date": "2026-10-31", "started_at": "…"}}
}
```

- `delivery.by_state`는 (event_id, device_id) 쌍의 **마지막 기록**
  상태의 합계다(delivery ledger 문서와 같은 last-record-wins 규칙).
  `configured`는 `--delivery` 지정 여부, `present`는 파일 존재다.
- `events.latest_*`는 ledger 파일 순서의 마지막 이벤트에서 온다.
- **존재하지만 커밋된 레코드가 0개인 ledger**(단일 작성자가 `O_CREAT`로
  파일을 연 뒤 첫 기록 전 — notify 워커 기동 직후가 정확히 이 상태다)는
  `ledger_present: true`·`count: 0`·빈 `by_type`/`by_severity`·
  `latest_*: null`로 투영한다. 크래시도, 파일 부재(`ledger_present:
  false`, `count: null`)와의 혼동도 아니다: 기록 권위 파일은 존재하고
  이벤트가 아직 없다는 정직한 상태다.

### 3.2 `GET /candidates` — 최신 세션의 CANDIDATE_* 이벤트

"최신 세션"은 **ledger 마지막 이벤트의 session_id**다. 응답은 그
session_id의 `CANDIDATE_ENTERED|UPDATED|EXITED` 팩트만 담는다. 빈
ledger(§3.1의 0레코드 상태)에서는 `session_id: null`·`count: 0`·빈
목록이다 — "최신 세션"이 없는 것이지 오류가 아니다:

```json
{"count": 2, "events": [ {…팩트 원문 필드…}, … ],
 "ledger_present": true, "session_id": "2026-10-30"}
```

### 3.3 `GET /events[?session_id=<id>]` — 이벤트 기록 + 전달 상태

```json
{"count": 4,
 "delivery": {"<event_id>": [{"attempts": 1, "device_id": "dev-1",
                              "provider_message_id": "projects/…/m-1",
                              "state": "ACCEPTED", "updated_at": "…"}]},
 "events": [ {…팩트 원문(레코드 그대로, 키만 정렬)…}, … ],
 "ledger_present": true}
```

- 팩트와 전달 기록은 **두 개의 키로 분리**되어 들어간다 — 3상태 3보금
  (REPLAY_CONTRACT §13.6)을 응답 모양에서도 유지한다. API는 팩트에
  전달 상태를 절대 병합하지 않는다.
- `delivery` 맵은 **응답의 events에 대응하는 event_id**만 담고, 각
  값은 device_id 오름차순의 마지막 기록들이다. 전달 기록이 없는
  이벤트는 맵에 키가 없다("전달 없음"은 빈 배열이 아니라 키 부재로
  표현된다).
- `?session_id=`는 정확-일치 필터다(선택). 값이 URL 디코딩된 뒤
  문자열 비교에만 쓰인다 — 파일시스템 접촉이 없어 경로 위험이 없다.

### 3.4 `GET /events/{event_id}` — 이벤트 1건 + 전달 기록

`{event_id}`는 64자 소문자 hex여야 한다. ledger에 없으면 404다.

```json
{"delivery": [ {…마지막 기록(필드 원문, event_id 제외)…} ],
 "event": {…팩트 원문…}}
```

전달 기록이 전무하면 `delivery`는 빈 배열이다(기록 부재의 정직한
표현).

### 3.5 `GET /sessions` — 런 디렉터리 목록

runs 루트의 **디렉터리만**, 이름 오름차순으로:

```json
{"count": 4,
 "sessions": [{"code_commit": null, "run_id": null,
               "run_json_present": false, "session": "dir-…",
               "session_date": null, "started_at": null}, …]}
```

- `run.json`이 있는 런은 화이트리스트 필드만 투영한다:
  `session_date`·`run_id`·`started_at`·`code_commit`. 나머지 기록
  필드(`host`, `pid`, `egress_ip`, `build`, 해시들…)는 **의도적으로
  비투영**이다 — 소비자가 필요로 하는 최소만 서빙한다. 값이
  문자열이 아니면 null로 서빙한다(채우지 않는다).

### 3.6 `GET /sessions/{session}/verification` — 검증 상태의 솔직 경계

기록된 사실과 저렴한 재도출만 서빙한다:

```json
{
  "code_commit": "885b…",
  "committed_marker": {"file": "input.hcj.jsonl.committed", "present": true},
  "checksums": {"artifacts": [
      {"computed_sha256": "aa…", "file": "input.hcj.jsonl",
       "match": true, "recorded_sha256": "aa…"},
      … ],
    "present": true},
  "events_file": {"present": true, "sha256": "6a…"},
  "replay_verdict": {"recorded": false},
  "run_json_present": true,
  "session": "smoke-2026-11-02-885b009",
  "session_date": "2026-10-29",
  "session_end_recorded": true
}
```

| 필드 | 원천 | 성격 |
|---|---|---|
| `session_date`·`code_commit` | run.json (화이트리스트) | 기록 |
| `committed_marker.present` | `input.hcj.jsonl.committed` 파일 존재 | 기록 |
| `session_end_recorded` | input.hcj.jsonl 안 `kind=session_end` 레코드 존재 | 기록(꼬리 미완료 라인 제외) |
| `checksums` | CHECKSUMS.sha256의 기록 해시 **vs** 각 아티팩트의 sha256 재계산 | 기록 + 계약이 허용한 유일한 재도출 |
| `events_file.sha256` | events.hcj.jsonl 바이트의 sha256 | 저렴한 재도출 |
| `replay_verdict` | 운영자가 남긴 `verify.stdout`의 첫 `VERDICT` 줄 **원문 인용** | 기록 인용 — API가 만든 판정이 아니다 |

- **replay verdict가 기록에 없으면** `{"recorded": false}`로
  응답한다. 파일이 있어도 `VERDICT` 줄이 없으면
  `{"recorded": false, "note": "verify.stdout present but no VERDICT
  line recorded"}`다. 추정·재실행·성공 가정은 없다 — §0.2 fail-closed.
- `checksums.artifacts[].match`는 재계산 해시와 기록 해시의 byte
  일치다. 파일이 없으면 `computed_sha256` null·`match` false다.
  CHECKSUMS.sha256 자체가 없으면 `{"present": false, "artifacts": []}`다.
  **기록된 아티팩트 이름은 신뢰 입력이 아니다**: 안전한 단일 경로
  구성요소가 아닌 이름은 열지 않고 `match: false` + note로 거부한다
  (CHECKSUMS가 `../../secrets`를 가리켜도 열리지 않는다).
- 이 엔드포인트는 세션의 "승인"이나 데이터 완전성을 판정하지 않는다.
  승인 권위는 GATES P12다. 응답은 세션이 지금 기록에 갖고 있는 검증
  관련 사실의 목록일 뿐이다.

### 3.7 `GET /mobile/market-view` — 최신 적격 시장 수집 런의 유계 투영 (VS-1)

모바일 단일 화면을 위한 하나의 읽기다. 이 라우트는 판정하지 않는다:
랭크는 기록된 팩트에서 오고, 여기서 하는 일은 기록된 이벤트를
**접고·기록 필드(rank)로 정렬해 선출하고·계수**하는 것뿐이다(§0 세
번째 항목의 유계 폴딩 투영). 쿼리 파라미터·정렬 옵션·페이지네이션은
없다. `--ledger`·`--delivery`는 읽지 않는다 — 원천은 아래 선택 규칙이
고른 **런 디렉터리 하나**다.

**적격 판정(기록 바이트만, 벽시계 없음)** — runs 루트의 top-level
디렉터리가 다음 세 조건을 모두 만족하면 적격 시장 수집 런이다:

1. `input.hcj.jsonl`과 `events.hcj.jsonl`이 모두 존재한다.
2. input.hcj.jsonl의 **커밋된 config 레코드**(수집기 프리앰블의 둘째
   레코드)의 `environment`가 `"demo"` 또는 `"real"`이다. 실제 수집 런은
   run.json이 없고 이 config 레코드가 신원이다. `environment`는
   수집기 전용 필드라 smoke·gen_fixture 산출물과 drill·observe
   디렉터리는 여기서 탈락한다.
3. 같은 config 레코드의 `session_date`가 `^\d{4}-\d{2}-\d{2}$`
   (수집기 자체 검증 형상)이다.

config 레코드 읽기는 유계다: input.hcj.jsonl 전체(개장 중 하루 종일
커지는 파일)는 **여기서는** 절대 읽지 않고 **첫 16 KiB 윈도**만 읽고,
그 안의 LF-종단 커밋 라인(비-LF 꼬리는 §0 규약대로 미커밋으로 건너뛴다)에서
첫 `kind:"config"` 레코드까지만 파싱한다. 파싱한 커밋 라인이 불량
JSON·빈 줄이면 DataFault(§4). 창 안에 config 레코드가 없으면 그 런은
비적격이다 — 부재는 부재로 서빙한다. **예외**: 아래의 종목명 사전 폴드는
같은 파일을 전체 스캔한다(그 규칙과 메모이제이션이 이 절의 전체-입력
읽기 유일 예외다).

**선택(결정적 3단계)** — 적격 런들 중 (1) `session_date` 최대(사전식),
(2) 동률이면 그 런의 `events.hcj.jsonl` **마지막 커밋 이벤트의
`observed_at`** 최대(기록 문자열 비교; 커밋된 이벤트가 없으면 이
단계에서 최하위), (3) 그래도 동률이면 디렉터리 이름 코드포인트 최대.
마지막 이벤트 관찰도 유계다: 파일 끝 **64 KiB 윈도**에서 마지막
LF-종단 라인만 파싱해 `observed_at`을 읽는다(전체 파일을 읽지
않는다). 커밋된 마지막 라인이 불량이면 DataFault.

**폴드** — 선택된 런의 `events.hcj.jsonl`을 `read_committed_lines`
규약(§0)으로 한 번 패스한다. `(symbol, direction)` 상태는
last-record-wins: `CANDIDATE_ENTERED`/`CANDIDATE_UPDATED`는
`{rank, event_id, event_type, observed_at, data_quality}`를 덮어쓰고
`CANDIDATE_EXITED`는 상태에서 제거한다. 패스 후 방향별(UP/DOWN)로
**rank 오름차순** 정렬해 앞 10개가 `rising_top10`/`falling_top10`이다.
정규 기록의 랭크는 조밀 1..N이라 동률이 없어야 한다 — 불량 기록으로
동률이 나타나면 **레저 순서(파일 순서) 위치**가 동률을 깬다(이 계약이
명시하는 유일한 동률 규칙). `history`는 파일 순서 그대로 **최근
`CANDIDATE_*` 이벤트 최대 100건**. `status.by_data_quality`는 그 런의
**모든** 이벤트에 대한 data_quality 합계(키 오름차순). `as_of`·
`latest`는 그 런의 마지막 커밋 이벤트가 기록한 필드에서 온다. 폴드가
유지하는 메모리는 상태 + 최근 100 링 + 카운터뿐이다(이벤트별 복사본
없음). 폴드가 의존하는 필드(event_id·event_type·observed_at·
data_quality, 후보 이벤트의 symbol·direction, ENTERED/UPDATED의 1 이상
정수 rank)의 커밋된 기록이 형상을 벗어나면 DataFault다.

**종목명 사전(name) 폴드** — 아이템의 8번째 필드 `name`은 선택된 런의
`input.hcj.jsonl`에 기록된 ka10027 응답 본문에서 온다(serve-time 벤더
호출 없음 — 기록된 바이트만). 규칙:

1. **스캔 범위**: 같은 파일의 config 판정(첫 16 KiB)과 달리 이 폴드가
   input.hcj.jsonl **전체**를 라인 스트림으로 훑는다 — 이 문서의 유일한
   전체-입력 읽기 예외다. 라인 규약은 §0와 같다: 비-LF 꼬리는
   미커밋이라 스캔을 멈추고, 커밋된 라인이 불량 JSON·빈 줄이면
   DataFault. 대상 레코드는 `kind:"rest_resp"`·`raw.api_id:"ka10027"`
   둘 다 만족하는 것뿐(ka10080 등 다른 레코드는 스캔만 하고 이름
   원천으로 안 쓴다).
2. **레코더가 보장하는 인벨로프**(`raw` 객체·문자열 api_id·hex
   body_hex)가 깨진 커밋 레코드는 오염이다 — DataFault, 조용한 스킵
   없음. **본문 내용은 레코더가 보장하지 않는다**(성공·실패 응답을
   원문 그대로 보존): 본문이 JSON 객체로 디코드되지 않거나 순위 리스트
   키(`pred_pre_flu_rt_upper`)가 없으면 그 레코드는 이름을 기여하지
   않는다 — 기록된 비성공 응답에는 접을 순위가 없다(부재 서빙).
   디코드된 리스트의 각 행은 객체·문자열 `stk_cd`·문자열 `stk_nm`이어야
   한다 — 폴드가 의존하는 기록 형상이므로 위반은 DataFault(이벤트
   폴드의 symbol·rank 규율과 같다).
3. **맵 규칙**: `stk_cd → stk_nm`, **파일 순서 최신 승리**. 이벤트
   심볼이 사전에 없으면 `name: null`(기록 부재 — 앱이 심볼로
   폴백한다). 사전의 심볼이 이벤트에 없어도 응답에 나오지 않는다.
4. **메모이제이션**(§1의 유일한 캐시 예외): 사전은 기록 바이트의 순수
   파생이라 프로세스 내에 캐시된다. 키는 **(path, size, mtime_ns)** —
   실용적 무효화 키이지 암호학적 지문이 아니다(같은 size·mtime_ns를
   회복하는 재작성은 스테일 서빙). **스캔 전후 stat이 일치할 때만
   게시**한다: 읽는 동안 파일이 바뀌면 접힌 결과(일관된 프리픽스)는
   서빙되지만 캐시되지 않는다. 슬롯은 1개(직전 게시분)라 선택 규칙이
   다른 런을 고르면 재스캔한다. DataFault는 캐시되지 않는다 — 불량
   파일은 고칠 때까지 매 요청 500이다. **개장 중 최악 비용**: 실거래
   세션의 input.hcj.jsonl은 상시 증가해 stat이 계속 바뀌므로 캐시가
   자주 무효화되고 요청마다 전체 스캔을 지불할 수 있다(실측 기준
   1.4 GiB 파일 약 4~7초, 스트리밍이라 메모리는 라인 1개 수준).

```json
{
 "as_of": "2026-11-09T13:45:58+09:00",
 "falling_top10": [ {"data_quality": "OBSERVING", "direction": "DOWN",
                     "event_id": "…", "event_type": "CANDIDATE_UPDATED",
                     "name": "SK하이닉스", "observed_at": "…",
                     "rank": 2, "symbol": "000660"} ],
 "history": [ {"data_quality": "OBSERVING", "direction": "UP",
               "event_id": "…", "event_type": "CANDIDATE_ENTERED",
               "name": "삼성전자", "observed_at": "…", "rank": 1,
               "symbol": "005930"}, … ],
 "latest": {"data_quality": "INCOMPLETE", "event_id": "…",
            "event_type": "SUBSCRIPTION_TRUNCATED",
            "observed_at": "…"},
 "rising_top10": [ {"data_quality": "OBSERVING", "direction": "UP",
                    "event_id": "…", "event_type": "CANDIDATE_ENTERED",
                    "name": "LG전자", "observed_at": "…", "rank": 3,
                    "symbol": "006660"}, … ],
 "run": {"environment": "demo", "run_id": "fidelity-…-v4",
         "session": "fidelity-…-v4", "session_date": "2026-11-09"},
 "runs_present": true,
 "status": {"by_data_quality": {"INCOMPLETE": 2, "OBSERVING": 705}}
}
```

- **아이템(top10·history 공용)은 화이트리스트 8 필드**: data_quality·
  direction·event_id·event_type·**name**·observed_at·rank·symbol.
  `name`을 뺀 7필드는 이벤트 기록에서, `name`은 위 종목명 사전에서 온다.
  후보 전이 이외의 기록 필드(rule_id·severity·evidence_ref·…)는
  투영되지 않는다. `CANDIDATE_EXITED` history 아이템의 `rank`는 **null**이
  고 심볼이 사전에 없는 아이템의 `name`도 **null**이다(기록 부재,
  0이나 빈 문자열이 아니다 — §2). 아이템 수는 최대 120(10+10+100)이고
  필드가 기록 형상(이벤트 스키마의 enum·고정 패턴·6자리 심볼, 그리고
  벤더가 기록한 stk_nm 문자열)으로 유계라 **응답 크기는 계약상 64 KiB를
  넘지 않는다** — 모바일 규모의 단일 응답이다(§7). 실측(2026-11-09
  demo-v4, 이름 120/120 부착): 30,954 바이트.
- **빈 상태**: runs 루트에 디렉터리가 없으면 `runs_present:false`·
  `run:null`·나머지 전부 null/빈 배열·`status:null`. 디렉터리는
  있어도 적격 런이 없으면 `runs_present:true`에 같은 null/빈값.
  선택된 런에 커밋된 이벤트가 0개면 `run`은 채워지고 `as_of`·
  `latest`는 null, 세 목록은 빈 배열, `status.by_data_quality`는
  `{}`다(§3.1의 present-but-empty 규율과 같다).
- **배열 순서는 §2에 대한 명시된 예외다**: `history`는 선택된 런의
  events 파일 순서, top10 순서는 이 §의 폴드 규칙(rank 오름차순)이다.
- **캐비앗**: (1) 이중 방향 코드는 event_gen이 UP 방향으로 한 번만
  판정하므로(중복 제거) DOWN 목록에서 누락될 수 있다. (2) `history`는
  최근 후보 이벤트 최대 100건이다 — 피크 이벤트율에서 이 창은 몇 분
  치고 하루 전체 이력이 아니다. 하루 이력·더 큰 창·새 쿼리 파라미터는
  **이 §을 고치는 계약 변경** 없이는 생기지 않는다.

## 4. 오류 응답 (fail-closed)

| 상황 | 응답 |
|---|---|
| 미지 경로·미지 이벤트 id·미지 세션·경로 순회 시도 | 404 `not_found` (요청 값 재출력 없음) |
| GET 이외의 메서드 (POST/PUT/DELETE/PATCH/HEAD/OPTIONS) | 405 `method_not_allowed`, `Allow: GET` |
| 기록 파일 불량(커밋된 라인이 불량 JSON·불량 체크섬 줄 등) | 500 `data_fault` — 조용한 스킵 없음 |
| http.server 내부 오류(불량 요청 줄 등) | JSON 본문 (HTML 없음) |

## 5. 보안 경계

1. **바인딩**: 기본 127.0.0.1(옵션 없음 = 루프백만). `--bind`는 IPv4
   유니캐스트와 0.0.0.0만 수용하고 멀티캐스트·브로드캐스트·예약
   블록·비IPv4 문자열은 사용법 오류(exit 2)로 거부한다. `0.0.0.0`은
   Northflank ingress 뒤 컨테이너 전용이며 접근 통제는 플랫폼 Basic
   Auth에 위임한다 — 직접 공개 금지. 이 API 자체는 인증을 갖지
   않는다.
2. **GET 전용**: 쓰기 경로·POST·PUT·DELETE·PATCH·HEAD·OPTIONS는 전부
   405다. 쓰기 엔드포인트는 존재하지 않는다.
3. **식별자 검증**: `{event_id}`는 `^[0-9a-f]{64}$`, `{session}`은
   `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` + `..`·구분자 명시 거부 +
   **실제 런 디렉터리 이름과의 정확-일치** + realpath 격납 검사.
   `%2e%2e` 같은 인코딩 우회는 디코딩 뒤 같은 검증에 걸린다.
4. **파일시스템 비노출**: 응답에 절대 경로가 없다. 파일시스템에서
   노출되는 것은 런 **디렉터리 이름**뿐이다. 오류 메시지도 파일
   basename만 담는다.
5. **비밀 비서빙**: 응답은 기록 화이트리스트에서만 온다. run.json의
   `host`·`pid`·`egress_ip` 등은 투영하지 않고, ledger·delivery는
   스키마가 닫혀 있어(추가 속성 거부) 자격증명 필드가 애초 기록되지
   않는다. 기기 레지스트리(FCM 토큰 보관)는 애초에 API 원천이
   아니다 — 저장소 밖 파일이며 `--delivery`와 다른 파일이다.
6. **기록 입력 무신뢰**: CHECKSUMS.sha256의 아티팩트 이름은 안전
   패턴 밖이면 열지 않는다.

## 6. 테스트·게이트

- `bash tools/api/test_api.sh`: unittest 계약 스위트. mktemp 샌드박스에
  합성 런 디렉터리·ledger·delivery를 만들고, 실제 서버를 127.0.0.1
  **임시 포트(port 0)**로 띄워 엔드포인트별 상태코드·본문 바이트를
  단언한다. 네트워크는 루프백뿐, 실데이터·실자격 0. 서버는 스위트가
  SIGTERM으로 종료·회수하며 잔류 프로세스 0을 단언한다. 커버 시나리오:
  엔드포인트 전부, canonical 바이트 일치, last-record-wins 전달 상태,
  체크섬 불일치·부재, 기록된 VERDICT 인용 vs "기록 안 됨", torn-tail
  ledger(미커밋 꼬리 스킵), 경로 순회·인코딩 우회 404, 메서드 405,
  비밀·은닉 필드 비노출, 기동 fail-closed(미지 --runs·포트 범위·미지
  옵션), SIGTERM 종료 코드 0, --bind 계약(127.0.0.2 기동 시 SERVE 줄과
  리스너 단언, 0.0.0.0 인자 검증 수용, 멀티캐스트·브로드캐스트·예약
  블록·비IPv4 문자열의 exit 2 거부), §3.7 종목명(ka10027 사전 fold —
  최신 승리·불량 라인·인벨로프 위반 DataFault·비성공 본문 부재 서빙,
  name null 폴백, (path, size, mtime_ns) 캐시 히트·무효화).
- 인터프리터 해석 순서는 collector·notify 스위트와 같다:
  `$HSCOLLECTOR_PYTHON` → `python3.13` → `uv python find 3.13`.
- 게이트: `bash tools/run_tests.sh`에 등록된 스위트(`run bash
  tools/api/test_api.sh`)의 exit 0. 단독 통과는 게이트가 아니다.

## 7. 범위 밖

- 인증·TLS·WireGuard 앞단 — 별도 계획 없이는 없다(기준안 §8). 원격
  노출은 이 API 프로세스의 기능이 아니라 플랫폼 ingress(§1)의
  역할이며, 그 계약 없는 직접 노출은 금지다.
- 페이지네이션·정렬 옵션·커서 — 개인용 규모에서 요청 시 재검토.
  모바일 규모의 답은 이미 계약돼 있다: §3.7의 유계 투영(아이템 수·
  필드가 유계라 응답 ≤ 64 KiB)이다. 다른 라우트의 페이지네이션은
  계속 유예다.
- 캐시·ETag·압축 — 없다(기록 재독이 권위다). **유일한 예외**: §3.7의
  종목명 사전은 기록 바이트의 순수 파생이라 (path, size, mtime_ns) 키로
  프로세스 내 메모이제이션된다(§1·§3.7의 게시 조건과 한계 참조). ETag·
  압축은 여전히 없다.
- 데몬화·systemd·자동 기동·헬스체크 인프라 — 명시적 시작만 계약이다.
- 판정·replay·verify 실행 — 이 프로세스의 역할이 영원히 아니다.
