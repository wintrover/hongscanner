# 단일 컨테이너 계약 (Northflank Phase-0, PR-2)

이 문서는 루트 `Dockerfile`·`.dockerignore`·`tests/test_container_contract.sh`가
함께 구성하는 **커밋되는 컨테이너 계약**이다. 이미지 구성·빌드 절차·신뢰
경계가 이 문서와 어긋나면 구현이 틀린 것이다.

- 상위 계약: tools/api/README.md §1·§5 (serve.py 구동·보안 경계,
  `--bind 0.0.0.0` 컨테이너 전용), docs/REPLAY_CONTRACT.md §13,
  docs/GATES.md.
- Phase-0 범위: **API 서버 상시 실행형 단일 컨테이너**. 그 위에 런타임
  supervisor(PR-4, §7)와 공급망·증명(PR-5, §8 — 구현됨)이 확장된다.

## 1. 이미지 구성 (변경 불가)

| 항목 | 값 |
|---|---|
| base | `python:3.13-slim` — serve.py는 표준 라이브러리만 사용(http.server), **serve.py를 위한 pip 설치 금지**; 유일한 pip 설치는 collector sidecar의 버전 고정 의존성(websockets==17.3, `tools/collector/requirements.txt`) |
| 사용자 | 비루트 `hongscanner` (system user, nologin) |
| 코드 | `/opt/hongscanner/` — `serve.py` · `tools/market_time.py`(세션 시간 권위, P30) · `cloud_supervisor.py` · `bin/hongscanner` · `bin/collector` · `bin/sidecar.py`(collector 바이너리 옆) · `tools/collector/requirements.txt` · `tools/notify/{notify_dispatcher,notify_clock,notify_config,notify_fcm,notify_ledger}.py` · `CALENDAR_INDEX.sha256` |
| 데이터 | `/var/lib/hongscanner/` — `runs/` · `notify/` (볼륨 마운트 지점, 빈 상태로 이미지에 존재) |
| 환경 | `ENV HSCOLLECTOR_PYTHON=python3` — sidecar 인터프리터 탐색(`$HSCOLLECTOR_PYTHON` → 바이너리 옆 `.venv/bin/python` → `python3`)의 첫 경로를 고정. + supervisor 핀 6건: `HS_API_BIND=0.0.0.0` · `HS_API_PORT=8080` · `HS_SUPERVISOR_PROBE_PORT=8081` · `HS_DATA_ROOT=/var/lib/hongscanner` · `HS_CALENDAR_DIR=/var/lib/hongscanner/calendars` · `HS_CALENDAR_INDEX=/opt/hongscanner/CALENDAR_INDEX.sha256` — §7.4 코드 기본값과 동일한 값으로 이미지 표면을 자기완결적으로 만든다 |
| 노출 | `EXPOSE 8080 8081`, `STOPSIGNAL SIGTERM` |
| ENTRYPOINT | `python3 /opt/hongscanner/cloud_supervisor.py` — 상시 실행 프로세스는 supervisor다(§7). API 자식(serve.py)의 바인드·포트·runs·ledger는 위 ENV 핀과 §7.4 기본값에서 온다 |

- **`--bind 0.0.0.0`은 Northflank ingress 뒤 컨테이너 전용이다.** 이 API에는
  인증이 없고, 0.0.0.0 바인드의 접근 통제는 플랫폼(Northflank ingress Basic
  Auth)에 위임된다. 플랫폼 ingress 뒤가 아닌 0.0.0.0(그 외 비루프백 포함)의
  인터넷 직접 노출은 tools/api/README.md §1·§5의 계약 위반이다. 로컬 운영은
  기본값(127.0.0.1)을 쓴다.
- serve.py 실행 계약(README §1과 동일): 기동 성공 시 stdout에 `SERVE
  <bind>:<port>` 한 줄 flush — 스크립트·supervisor가 기동 증거로 쓴다.
  SIGTERM/SIGINT로 조용히 드레인 후 exit 0. exit 2 = 사용법·설정 위반,
  exit 4 = 바인드 실패. 실패를 exit 0으로 꾸미는 경로는 없다.
- **ENTRYPOINT는 PR-4 값이다**: 상시 프로세스는 cloud_supervisor다(§7).
  이미지 레이아웃(경로·사용자·볼륨)과 ENV 핀이 안정 표면이다.
- **sidecar·notify 배선**: collector.nim은 sidecar **스크립트**를 자기
  바이너리 옆(`getAppDir()/sidecar.py`)에서, 인터프리터를
  `$HSCOLLECTOR_PYTHON`에서 먼저 찾는다. 이미지는 그 두 첫 경로에 맞춰
  `bin/sidecar.py`와 `ENV HSCOLLECTOR_PYTHON=python3`를 공급한다.
  notify_dispatcher는 형제 모듈을 flat import하므로 네 파일이 한
  디렉터리에 함께 있다. **collector·sidecar·notify를 어떤 프로세스로
  띄우는가**(실행 인자·env)는 supervisor 표면이다 — §7.4 env 기본값이
  이 경로들로 배선한다(§8.4 기록).
- 데이터는 요청마다 볼륨에서 다시 읽는다(상태 캐시 없음 — README §1).
- ledger(`notify/ledger.hcj.jsonl`)는 **볼륨 공급이지 이미지에 구운 것이
  아니다**: 이미지는 비어 있는 `notify/`만 만든다. `runs/`도 마찬가지다.

## 2. 빌드 컨텍스트 스테이징 (외부 경로 COPY 금지)

Docker의 일반 COPY는 **빌드 컨텍스트 밖 파일에 도달할 수 없다** — 컨텍스트
밖 경로의 `..` 성분은 정규화 과정에서 제거된다(docs.docker.com 공식
동작). 특히 attest 잡의 `$CI_BUILD_OUT/hongscanner`는 저장소 밖 절대
경로라서 컨텍스트에 직접 넣을 수 없다. 그래서:

1. 이미지를 빌드하는 주체가 **스테이징 디렉터리(mktemp)를 만들고 필요한
   파일을 그 안으로 복사**한다.
2. 그 디렉터리를 컨텍스트로 `docker build`한다.
3. Dockerfile은 **컨텍스트 내 상대 경로만** COPY한다: `bin/hongscanner`,
   `bin/collector`, `tools/api/serve.py`, `tools/market_time.py`,
   `tools/container/cloud_supervisor.py`,
   `tools/collector/{sidecar.py,requirements.txt}`,
   `tools/notify/{notify_dispatcher,notify_clock,notify_config,
   notify_fcm,notify_ledger}.py`, `calendars/CALENDAR_INDEX.sha256`.
   `market_time.py`는 이미지에서도 `tools/` 상대 경로를 유지한다 —
   디스패처의 `_TOOLS_DIR` import가 체크아웃과 동일하고, 평면 배치된
   `serve.py`는 부트스트랩이 `./tools/market_time.py`를 찾는다.
   이 목록은 신뢰 대상이 아니다: 계약 테스트가 `serve.py`·
   `notify_dispatcher.py`의 import 폐포에서 복사 집합을 유도해 누락을
   기계적으로 검출한다.

스테이징 절차(운영·테스트 공통):

```sh
CTX="$(mktemp -d)"
mkdir -p "$CTX/bin" "$CTX/tools/api" "$CTX/tools/collector" \
         "$CTX/tools/container" "$CTX/tools/notify" "$CTX/calendars"
cp Dockerfile                      "$CTX/Dockerfile"
cp .dockerignore                   "$CTX/.dockerignore"
cp tools/api/serve.py              "$CTX/tools/api/serve.py"
cp tools/market_time.py            "$CTX/tools/market_time.py"
cp tools/container/cloud_supervisor.py "$CTX/tools/container/cloud_supervisor.py"
cp calendars/CALENDAR_INDEX.sha256 "$CTX/calendars/CALENDAR_INDEX.sha256"
cp tools/collector/sidecar.py      "$CTX/tools/collector/sidecar.py"
cp tools/collector/requirements.txt "$CTX/tools/collector/requirements.txt"
cp tools/notify/notify_dispatcher.py "$CTX/tools/notify/notify_dispatcher.py"
cp tools/notify/notify_clock.py      "$CTX/tools/notify/notify_clock.py"
cp tools/notify/notify_config.py     "$CTX/tools/notify/notify_config.py"
cp tools/notify/notify_fcm.py        "$CTX/tools/notify/notify_fcm.py"
cp tools/notify/notify_ledger.py     "$CTX/tools/notify/notify_ledger.py"
cp <hongscanner 바이너리>             "$CTX/bin/hongscanner"
cp <collector 바이너리>               "$CTX/bin/collector"
docker build -t <tag> [--label org.hongscanner.image-purpose=ci-test] "$CTX"
```

- `<hongscanner 바이너리>`·`<collector 바이너리>`가 무엇인지는 §3이
  규정한다(테스트와 운영이 다르다). 운영 스테이징은 두 바이너리가
  증명된 CI_BUILD_OUT 바이너리와 **바이트 일치함을 단언**한 뒤 build한다
  (attest.yml 스테이징 단계가 sha256 비교로 실측한다).
- `.dockerignore`는 **스테이징할 때 컨텍스트에 함께 복사해야 효력이
  있다**(docker는 컨텍스트 루트의 `.dockerignore`를 읽는다). 스위트는
  같은 `.dockerignore`를 쓰는 프로브 컨텍스트에 합성 decoy
  (`calendars/krx-fake.json`, 내용은 테스트가 만든 CAL-DECOY 바이트 —
  실제 데이터가 아니다)를 넣고 COPY가 실패함을 관측해 이 효력을
  **가정이 아니라 실측**한다.
- `.dockerignore`는 컨텍스트 화이트리스트다: 위 파일들만 통과시키고
  나머지 전부를 제외한다. **실제 `calendars/*.json`(gitignore된 사용자
  데이터)은 컨텍스트에 들어올 수 없다** — INDEX(`CALENDAR_INDEX.sha256`,
  git 추적·canonical main 출처)만 통과한다(§4). **어떤 자격증명
  (APP_KEY_MOCK·APP_SECRET_MOCK·FCM 서비스계정 JSON)에도 화이트리스트
  항목은 없다** — 시크릿은 런타임 Northflank Secret Group 주입이다(§8).
- **운영 빌드는 attest 잡이 같은 절차로 수행한다**: attest 산출 두
  바이너리(`$CI_BUILD_OUT/hongscanner`·`$CI_BUILD_OUT/collector`)를
  스테이징 컨텍스트로 복사한 뒤 build한다(§8). 이 Dockerfile은 그 빌드와
  테스트 빌드의 공유 계약이다.

## 3. 테스트 바이너리와 운영 바이너리의 산출물 분리

- **테스트 경로** (`tests/test_container_contract.sh` — CI·게이트 포함):
  tests/test_cli_contract.sh와 같은 패턴으로 mktemp 샌드박스에
  `nim c ... -o:"$SANDBOX/hongscanner" src/hongscanner.nim`로 **직접
  컴파일한 테스트 전용 바이너리**만 쓴다. `tools/build.sh` 산출도,
  저장소 루트의 `./hongscanner`도 절대 쓰지 않는다.
- **배치 불가 표식**: 테스트 이미지는 반드시
  `docker build --label org.hongscanner.image-purpose=ci-test` 라벨을
  갖는다. 이 라벨은 **배치 금지 표식**이다 — 라벨이 붙은 이미지는
  Northflank에 배치해서는 안 되며, 향후 배치 경로(PR-4·PR-5)는 이 라벨을
  단 이미지를 거부해야 한다. 테스트 스위트가 라벨을 단언한다.
- **운영 경로**: attest 잡의 CI_BUILD_OUT 두 바이너리(`hongscanner`·
  `collector`), **표식 없음**. 운영 이미지는 attest.yml의 이미지 페이즈에서
  만든다(§8). 두 산출물의 혼용 경로는 존재하지 않는다 — 테스트 스크립트는
  테스트 바이너리만 다루고, 운영 이미지는 attest 잡이 증명과 함께 만든다.
- 저장소 루트의 `./hongscanner`은 과거 사고로 남은 개발 빌드다 —
  **사용·삭제·덮어쓰기 금지**(AGENTS.md §-1; gitignore 대상).

## 4. 캘린더 신뢰 분리

- `calendars/CALENDAR_INDEX.sha256`는 git 추적 파일(canonical main
  출처)이다 — **이미지에 COPY해 구운다**(/opt/hongscanner/). 테스트는
  이미지 속 INDEX가 git 추적 파일과 바이트 일치함을 단언한다.
- 실제 `calendars/*.json`은 gitignore된 사용자 데이터다 — **이미지에도,
  빌드 컨텍스트에도, 테스트 픽스처에도 실제 파일을 넣지 않는다**
  (.dockerignore로 제외, INDEX만 통과; 스위트가 컨텍스트에 json이
  없음을 단언).
- 운영에서는 **Northflank 영구 볼륨이 캘린더 JSON을 공급**하고, 그 내용을
  이미지에 구운 INDEX와 **교차 검증**한다. 이 교차 검증의 실행은 PR-4
  범위다(Phase-0은 INDEX 구움과 컨텍스트 배제까지만 계약).

## 5. 볼륨 레이아웃

```
/opt/hongscanner/              # 이미지 레이어 (코드, 읽기 전용 운명)
  serve.py
  cloud_supervisor.py          # ENTRYPOINT — 상시 실행 supervisor (§7)
  bin/hongscanner
  bin/collector
  bin/sidecar.py               # collector 바이너리 옆 (collector.nim 탐색 경로)
  tools/collector/requirements.txt
  tools/notify/                # notify_dispatcher + config/fcm/ledger (flat import)
  CALENDAR_INDEX.sha256
/var/lib/hongscanner/          # 영구 볼륨 마운트 지점 (Northflank)
  runs/                        #   recorder·verify가 쓴 런 디렉터리들
  notify/
    ledger.hcj.jsonl           #   이벤트 ledger (append-only)
```

- 이미지는 두 디렉터리를 **비어 있는 상태로** 만들어 둔다(serve.py가
  `--runs` 디렉터리 부재에 exit 2로 끝나지 않도록 runs/는 필수). 내용은
  전부 볼륨에서 온다.
- 컨테이너는 비루트로 실행되므로 볼륨 마운트 내용은 `hongscanner`
  사용자(uid = 이미지의 system uid)가 읽을 수 있어야 한다. 이 API는
  어떤 파일도 쓰지 않는다(읽기 전용 투영 — tools/api/README.md §0).

## 6. 테스트·게이트

- `bash tests/test_container_contract.sh`: 실측 스모크. mktemp 샌드박스 →
  테스트 바이너리 두 개(hongscanner·collector) nim 직접 컴파일 →
  스테이징 컨텍스트(Dockerfile·.dockerignore·serve.py·market_time.py·
  cloud_supervisor.py·INDEX·두 바이너리·sidecar·requirements·
  notify 5모듈, import 폐포 유도 검사) →
  `docker build --label org.hongscanner.image-purpose=ci-test` →
  .dockerignore 효력 실측(decoy calendar json의 COPY 실패) →
  이미지 내부 검증(레이아웃·실행 비트·바인드 바이트 일치·INDEX·라벨·비루트·
  supervisor ENTRYPOINT·supervisor env 핀 6건·`HSCOLLECTOR_PYTHON=python3`·
  EXPOSE 8080+8081·collector sha256 일치·sidecar/notify 경로·
  `python3 -c "import websockets"` + 버전 17.3·collector usage exit 2) →
  합성 fixture(runs 루트 + 2-레코드 ledger, tools/api/test_api.py의
  구성 방식)를 `-v` 마운트해 `docker run -d -p 127.0.0.1::<임시포트>:8080`
  (ENTRYPOINT는 supervisor다. fixture에는 캘린더 볼륨이 없으므로
  supervisor는 초기화 미완료 /startup 503·세션 없음 — API 자식은
  언제나 뜬다) → 로그에서 `SERVE 0.0.0.0:8080` 대기(supervisor가 자식
  stdout을 무접두어 전달하므로 serve.py 계약 줄이 그대로 관측된다) →
  `GET /status` 200·본문 JSON 검증 → `POST /status` 405(`Allow: GET`) →
  미지 경로 404 → `docker stop`(SIGTERM → supervisor가 자식 드레인) →
  exit 0·비-OOM 관측 → 컨테이너·이미지 제거와 잔류 0 단언.
- **docker가 없으면 fail-closed**: docker CLI 부재·데몬 불도응은
  exit 1 + 명확한 메시지다. 게이트(`tools/run_tests.sh`)가 이 스위트를
  포함하므로 **docker 없는 환경에서 게이트는 실패한다 — 의도된 계약**이다.
  재시도·우회 경로는 없다. 베이스 이미지 pull 실패도 그대로 실패다.
- Python 해석 순서는 collector·notify·api 스위트와 같다:
  `$HSCOLLECTOR_PYTHON` → `python3.13` → `uv python find 3.13`.
  스위트는 합성 fixture 바이트와 응답 JSON 검증에만 호스트 Python을
  쓴다.
- 게이트: `bash tools/run_tests.sh`에 등록된 스위트(`run bash
  tests/test_container_contract.sh`)의 exit 0. 단독 통과는 게이트가
  아니다. 전체 게이트에 이 스위트로 몇 분이 더해진다(이미지 빌드·pull).

## 7. Cloud Runtime Supervisor (PR-4)

컨테이너의 상시 실행 프로세스는 `tools/container/cloud_supervisor.py`(표준
라이브러리만)다 — `Dockerfile`의 ENTRYPOINT. 역할은 **실행 어댑터에만 묶여
있다**: 자식 프로세스 수명과 세션 스케줄링. 시장 판단은 Nim core가,
기록은 Collector/Recorder가 한다 — supervisor는 판단하지 않고 run
디렉터리에 아무것도 쓰지 않는다. 모든 실패는 fail-closed다: 검증 실패·
전제 부재는 세션 거부이지 완화된 실행이 아니다.

### 7.1 자식 프로세스와 재시작 소유권

| 자식 | 역할 | 재시작 규칙 |
|---|---|---|
| API (`serve.py`) | 상시 실행. stdout의 `SERVE <bind>:<port>` 한 줄이 기동 증거(tools/api/README.md §1) — supervisor가 자식 stdout을 **무접두어 그대로 전달**하므로 컨테이너 로그는 원래 계약 줄을 그대로 유지한다 | 죽으면 짧은 백오프 뒤 **항상** 재시작. exit 2(설정 위반)도 재시작하며 /ready는 503을 유지한다 — 실패를 성공으로 바꾸는 경로는 없다 |
| collector | 하루 최대 시도 3, 세션당 1개, **활성 collector는 언제나 정확히 1개**(단일 스레드 세션 제어 + collector 자체 O_EXCL이 2차 방어) | 세션 수명은 supervisor 내부 소유 — 15:40 watchdog SIGTERM·세션 종료 처리 |
| notify worker | 세션 상주, run의 `events.hcj.jsonl` 감시 | 비정상 종료는 세션 중 재시작(worker의 full-rescan event_id dedup이 멱등성 보장); SIGTERM→exit 0은 정상 종료라 재시작 없음 |

- **재시작 소유권 분리: supervisor는 자식을, Northflank는 컨테이너를
  재시작한다.** 자식 수명은 supervisor의 내부 책임이고 어떤 프로브에도
  노출되지 않는다(아래 계약 A). 컨테이너 재시작 신호는 /live 503뿐이다.
- API 자식은 **자기 세션/프로세스 그룹**에서 실행된다(`start_new_session`
  스폰). 모든 정리 경로(정지·살아있는 자식 위의 재기동)는 그룹 전체에
  SIGTERM → 유한 시간 대기 → 잔존 시 SIGKILL을 보내고 종료를 기다린다
  — 살아있는 자식을 참조만 교체해 버리는 경로는 없다(2026-11-06 고아
  누수: 버려진 serve.py가 ppid=1로 살아남아 상속한 stderr fd를 계속
  붙잡아 테스트 게이트 파이프라인을 정체시켰다).
- STOPSIGNAL SIGTERM: supervisor가 자식들을 드레인하고 exit 0으로
  끝난다(`docker stop` = 이 경로, 스위트가 실측한다).

### 7.2 프로브 (supervisor 자체 stdlib HTTP 서버 — serve.py가 아니다; 포트 8081)

| 경로 | 200 조건 | 503 의미 | Northflank 매핑 |
|---|---|---|---|
| `/startup` | 초기화 완료 **래치** — config + 캘린더 볼륨 vs 구운 INDEX 교차 검증 성공 **그리고** API 자식 서빙 중. 한 번 200이면 래치된다 | 초기화 미완료 | Startup probe → `/startup` |
| `/ready` | API 자식이 서빙 중(`state=serving`) | API 자식 부재 — **트래픽 게이팅 전용, 절대 컨테이너 재시작 신호가 아니다** | Readiness probe → `/ready` |
| `/live` | supervisor 루프 하트비트 신선(임계 `max(2×HS_TICK_SECONDS, 10s)`) | 루프 정지 — **컨테이너 재시작 신호** | Liveness probe → `/live` |

- **계약 A — 자식 업무 상태 미노출**: collector/worker 상태는 어떤 프로브에도
  나오지 않는다. 세션 종료 이후의 collector/worker 부재는 정상이지 재시작
  사유가 아니다.
- **Northflank에는 저장소가 설정을 담지 않는다**: 프로브 설정은 플랫폼
  콘솔의 수동 단계이며 startup→`/startup`, readiness→`/ready`,
  liveness→`/live`, 포트 8081이다. GET 전용 — 그 외 메서드는 405,
  미지 경로는 404.

### 7.3 세션 멱등성 (부팅·재시작 어디에서든 같은 결론)

- 오늘 날짜의 **COMMITTED run**(input.hcj.jsonl.committed 마커)이 있으면
  그날은 끝 — 새 세션 없음.
- **미봉인(unsealed) run은 사전 증거다 — 재개하지 않고, 덮어쓰지 않고,
  보존한다**; 남은 시간 안이면 새 run_id(`ph1-<date>-a`, `-b`, …)로
  시도한다.
- 시도 상한 3(오늘 존재하는 run 디렉터리 수가 시도 수), 시작 08:50,
  최종 시작 15:30, watchdog 15:40 KST(기본값 — §7.4).
- collector 종료 판정: exit 0 = 봉인(COMMITTED), exit 4 = 정직한
  INCOMPLETE, 그 외(exit 2·3·시그널) = preserved. **어떤 종료도
  성공으로 승격되지 않는다.**
- 세션 종료 시 worker를 SIGTERM으로 정상 종료한다. 기록의 권위는
  events.hcj.jsonl이므로 어느 쪽 종료든 기록은 보존된다.

### 7.4 환경변수 (전부 env-only, 기본값 = 이미지 핀값)

| 변수 | 기본값 | 의미 |
|---|---|---|
| `HS_API_BIND` | `0.0.0.0` | API 자식 바인드(§1 — 컨테이너 전용) |
| `HS_API_PORT` | `8080` | API 포트 |
| `HS_SUPERVISOR_PROBE_PORT` | `8081` | 프로브 포트(호스트는 `HS_SUPERVISOR_PROBE_HOST`, 기본 `0.0.0.0`) |
| `HS_DATA_ROOT` | `/var/lib/hongscanner` | 데이터 루트 — `runs/`·`notify/ledger.hcj.jsonl`가 여기서 파생 |
| `HS_CALENDAR_DIR` | `/var/lib/hongscanner/calendars` | 캘린더 볼륨(볼륨 공급, §4) |
| `HS_CALENDAR_INDEX` | `/opt/hongscanner/CALENDAR_INDEX.sha256` | 이미지에 구운 INDEX(§4) |
| `HS_SERVE_SCRIPT` | `/opt/hongscanner/serve.py` | API 자식 스크립트 |
| `HS_COLLECTOR_BIN` | `/opt/hongscanner/bin/collector` | collector 바이너리 |
| `HS_NOTIFY_SCRIPT` | `/opt/hongscanner/tools/notify/notify_dispatcher.py` | notify worker 스크립트(flat import 형제와 동일 디렉터리) |
| `HS_NOTIFY_CONFIG` | `/var/lib/hongscanner/notify/notify_config.json` | notify 설정(볼륨 공급) |
| `HS_API_PYTHON` · `HS_WORKER_PYTHON` | supervisor 자신의 인터프리터 | 자식 인터프리터 |
| `HS_SESSION_START` · `HS_SESSION_LAST_START` · `HS_SESSION_WATCHDOG` | `08:50` · `15:30` · `15:40` (KST) | 세션 창·watchdog |
| `HS_SESSION_MAX_ATTEMPTS` | `3` | 하루 시도 상한 |
| `HS_TICK_SECONDS` | `30` | 루프 틱 |
| `HS_API_RESTART_SECONDS` · `HS_WORKER_RESTART_SECONDS` | `2.0` | 자식 재시작 백오프(초) |
| `HS_WORKER_MAX_RESTARTS` | `5` | 세션당 worker 재시작 한계(초과 시 push 중단·수집 계속) |
| `HS_SESSION_TAIL_GRACE` · `HS_KILL_GRACE_SECONDS` | `3.0` · `10.0` | 세션 종료 유예·SIGKILL 전 유예(초) |
| `HS_PROBE_STARTUP_PATH` · `HS_PROBE_READY_PATH` · `HS_PROBE_LIVE_PATH` | `/startup` · `/ready` · `/live` | 프로브 경로 |
| `HS_KIWOOM_PROFILE` | `demo` | collector `--profile` |

- **HSCOLLECTOR_PYTHON 배선**: supervisor는 자식 env를 만지지 않고
  상속시킨다 — collector의 sidecar 인터프리터 탐색은 이미지의
  `ENV HSCOLLECTOR_PYTHON=python3`(§1)을 그대로 따른다.
- collector 자식은 `--token-source=env`로 띄운다 — 자격증명은 런타임
  Northflank Secret Group 주입이고(§8.4) supervisor 코드는 자격증명을
  읽지 않는다.
- supervisor의 stdout(`SUPERVISOR` 접두·KST 타임스탬프, 결정마다 1줄)이
  컨테이너 로그다. 종료 코드: 0 = 정상(SIGTERM/SIGINT 드레인), 2 = 설정
  오류, 4 = 프로브 바인드 실패, 1 = 내부 결함 — 컨테이너 재시작은
  플랫폼 몫이다.
- 계약 스위트: `bash tools/container/test_supervisor.sh`(게이트는
  `tools/run_tests.sh` 경유) — 가짜 자식·주입 클록·루프백 프로브만으로
  이 §7 표면을 실측한다(실 collector·실세션·시장 데이터 없음).

### 7.5 범위 밖

- 이미지 서명(cosign 등 추가 서명 체계)·배치 자동화(CD) — 범위 밖.
- 인증·TLS·헬스체크 인프라 — tools/api/README.md §7과 동일하게 범위 밖.

## 8. 공급망 — attest 확장·운영 이미지·GHCR·이미지 digest 증명 (PR-5)

### 8.1 증명 사슬 (main push 전용 attest.yml)

main push 하나가 **세 개의 SLSA 증명 대상**을 만든다. 모두 동일한 한 번의
`tools/ci_build.sh` 호출에서 나온 같은 SHA의 산출물이다:

| 대상 | subject-name | 증명 |
|---|---|---|
| hongscanner 바이너리 | `hongscanner-linux-<arch>` | attest-build-provenance (OIDC 서명, 저장소 기록) |
| collector 바이너리 | `collector-linux-<arch>` | 동일 — ci_build.sh가 같은 호출에서 두 바이너리를 생산(같은 가드·fail-closed·별도 nimcache). collector는 hsBuild* 정의를 소비하지 않는다(import 그래프에 binfo가 없음) — collector의 provenance 근거는 이 증명이다 |
| 운영 이미지 digest | `ghcr.io/wintrover/hongscanner` (FQDN·태그 없음 — 태그는 mutable, digest가 불변 신원) | subject-digest = build-push-action의 digest 출력 + `push-to-registry: true` |

- **페이즈 순서 불변식**: 모든 이미지/GHCR 단계는 두 바이너리의 증명과
  아티팩트 업로드 **뒤에** 온다. 이미지 경로 실패가
  tools/install-attested.sh의 로컬 재설치 경로(바이너리 아티팩트 + 저장소
  증명)를 막지 않게 하기 위해서다. 실패는 여전히 잡 실패다 — 삼키지
  않는다. 이미지 단계 실패 시 증명은 이미 기록돼 있다.
- **바이너리 아티팩트**: `hongscanner-<arch>`·`hongscanner-<arch>-attestation`
  ·`collector-<arch>`·`collector-<arch>-attestation`·
  `hongscanner-image-attestation` (90일 보존, 주체별 별도 이름).
- **collector 검증**: `gh attestation verify collector --repo
  wintrover/hongscanner` (다운로드한 collector 바이너리 경로에 대해).
  tools/install-attested.sh는 두 바이너리(hongscanner·collector)를
  **같은 versions/<버전> 디렉터리에 원자적으로 함께 설치**한다 — 두
  바이너리 모두 각자 증명 검증을 통과해야 `current` 심볼릭 링크가 한 번만
  교체되고, 한쪽이라도 실패하면 새 버전 전체가 선택되지 않는다
  (fail-closed). 컨테이너 운영 경로는 여전히 이미지 내부 바이너리다.

### 8.2 운영 이미지 빌드·push (immutable main-<sha7>)

- **스테이징**(§2 계약 그대로, attest.yml의 이미지 페이즈): mktemp 컨텍스트 =
  CI_BUILD_OUT 두 바이너리(**sha256 바이트 일치 단언**) + git 추적 파일
  (Dockerfile·.dockerignore·serve.py·market_time.py·cloud_supervisor.py·
  INDEX·sidecar·requirements·notify 5모듈). 스테이징 calendars 디렉터리에
  `*.json`이 나타나면 거부(단언).
- **표식 없음**: 운영 이미지는 `org.hongscanner.image-purpose` 라벨을
  갖지 않는다(§3 — 라벨이 있으면 배치 금지 대상). BuildKit 내장
  provenance/sbom 매니페스트도 생성하지 않는다 — 이미지의 SLSA 증명은
  저장소 수준의 digest 증명이며, 단일 구성 매니페스트로 digest의 모호함을
  없게 유지한다.
- **태그 규약**: `ghcr.io/wintrover/hongscanner:main-<sha7>` — 정확한
  main SHA당 한 번 push하는 **불변 관례 태그**다. **버전 태그
  덮어쓰기 금지·`latest` 태그 금지**. 두 태그가 같은 digest를 가리키는
  사례는 공급망 결함이다.
- **검증 명령** (레지스트리 인증 필요):
  ```sh
  gh attestation verify \
    oci://ghcr.io/wintrover/hongscanner@sha256:<digest> \
    --repo wintrover/hongscanner
  ```
  바이너리는 다운로드 후 `gh attestation verify <바이너리> --repo
  wintrover/hongscanner` (tools/install-attested.sh가 signer workflow·
  source ref·digest·github-hosted runner까지 핀한다).
- **CD 자동 배포 없음**: attest.yml에는 배포 단계가 존재하지 않는다.
  Northflank 배치는 아래 절차의 **수동 단계**다.

### 8.3 Northflank Image Library 배치 절차 (문서만 — 실행은 NF 단계·계정 필요)

이 저장소는 이 절차를 문서로만 담는다. 실행에는 Northflank 콘솔·계정
자격이 필요하며, 저장소가 수행하지 않는다.

1. **classic PAT 발급** — GitHub 계정 Settings → Developer settings →
   Personal access tokens (classic) → Generate; 스코프는
   **read:packages** 만.
2. **이미지 import** — Northflank 콘솔 → Image library → Add image →
   GHCR 선택 → 인증에 PAT 입력 → image path
   `ghcr.io/wintrover/hongscanner` → import 실행.
3. **READY 대기** — import 상태가 READY가 될 때까지 기다린다. FAILED면
   PAT 스코프와 패키지 가시성(아래 5)을 확인하고 재시도한다.
4. **수동 배치** — service 생성/갱신 시 **특정 버전 태그
   (`main-<sha7>`)을 수동으로 선택**한다. 새 main SHA마다 attest 런이
   만든 새 태그를 import·선택한다. **태그 덮어쓰기 금지·`latest` 금지** —
   배치 대상 태그는 digest 검증(`gh attestation verify oci://…`)을
   통과한 것만 사용한다.
5. **패키지 가시성** — GITHUB_TOKEN으로 처음 push된 GHCR 패키지는 기본
   **private**이다. 패키지 소유 계정의 PAT(read:packages)면 읽을 수
   있다. 공개 전환은 패키지 Settings에서 수동으로만.

### 8.4 이미지 내용물·시크릿 경계·배선 기록

- **시크릿 불변**: 이미지와 빌드 컨텍스트에 어떤 자격증명도 존재하지
  않는다. `APP_KEY_MOCK`·`APP_SECRET_MOCK`·FCM 서비스계정 JSON은
  **런타임에 Northflank Secret Group env로 주입**되며, `.dockerignore`
  화이트리스트에는 그 어떤 항목도 없다(§2).
- **HSCOLLECTOR_PYTHON**: 이미지는 `ENV HSCOLLECTOR_PYTHON=python3`로
  sidecar 인터프리터의 첫 탐색 경로를 고정하고, pip은
  `tools/collector/requirements.txt`(websockets==17.3 유일·버전 고정 —
  계약 측정 근거)를 그 인터프리터로 설치한다. 테스트 스위트가 이미지
  내부에서 `import websockets`와 버전 17.3을 실측한다.
- **프로세스 배선**: collector·sidecar·notify를 어떤 프로세스로 띄우는가
  (실행 인자·환경변수·watch 모드)는 cloud_supervisor 표면이다 — §7.4의
  env 기본값이 §5의 경로들로 배선하며, 이미지는 그 기본값을 ENV로 핀한다
  (§1). 이 Dockerfile은 경로·사용자·볼륨의 안정 표면만 약속한다(§1).
- **신뢰 한계**(docs/LIMITS.md bounded trust): 이미지 digest 증명도
  GitHub가 서명한 증명이다 — GitHub 인프라와 분리된 독립 증명은 아니며,
  관리자 신뢰 뿌리를 제거하지 않는다. `gh attestation verify`는 언제든
  재확인을 제공한다.
