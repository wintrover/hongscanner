# Hong Scanner — Runs Retention (runs/ 디스크 보존 정책)

이 문서는 `runs/` 디스크 보존 정책의 **커밋되는 계약**이다. 집행 도구는
`tools/runs_retention.sh`(판정·압축·쿼터)과 `tools/run_session.sh`의 Storage
Preflight이며, 구현이 이 문서와 어긋나면 구현이 틀린 것이다. 계약 테스트는
`tests/test_retention_contract.sh`(14행 테스트 표 전부, 전부 합성·stub —
실 FCM·실 systemd·실 df에 의존하지 않는다).

- 상위 계약: AGENTS.md(§2.1 HARD — 실패한 런과 그 증거 보존), docs/GATES.md
  (P14), docs/REPLAY_CONTRACT.md(마커·런처 로그의 의미), docs/ASSUMPTIONS.md
  (P25 달력 승인 3층 증거).
- 대상: 운영 노트북(`hongscanner-srv`, `~/hongscanner`)의 `runs/`. 개발
  노트북의 `runs/`는 운영에 쓰이지 않으므로 논외.
- 목적: 무인 수집 도중 디스크가 고갈되어 Hong Scanner가 아무도 모르게
  중단되는 일을 사전에 차단하면서, 검증·감사에 필요한 원본 증거는 절대
  잃지 않는 것.

## MUST (요구사항 — AGENTS.md §0.4 등급)

| id | requirement | enforced by |
|---|---|---|
| R1 | 실패한 런과 그 증거는 삭제·덮어쓰기하지 않는다(AGENTS.md:59, §2.1 HARD) — FAILED(COLLECTOR_EXIT≠0, 마커 INVALID) 등급의 원본은 무조건 유지 | 판정표 2행; `tests/test_retention_contract.sh` 2·8 |
| R2 | GATES·서비스가 인용하는 런은 보존한다(GATES_REFERENCED·SERVICE_DEPENDENCY). GATES 파일 부재 시 전체 보호 | 판정표 3·4행; 계약테스트 3·4 |
| R3 | 재현은 항상 새 디렉터리 — 아카이브는 이동·압축일 뿐 재현이 아니며, 아카이브된 런은 `runs/`에 되돌리지 않는다 | 압축 절차 g; 원본 제거는 검증 통과 후에만 |
| R4 | fail-closed: 판정 불능(UNKNOWN)·달력 불신·df 무응답은 보호·거부로 이어진다 — 미확정을 정리로 승격하는 경로는 없다 | 판정표 6행·CALENDAR_UNUSABLE·preflight exit 2 |
| R5 | 압축은 무손실 round-trip이 증명된 뒤에만 원본을 정리한다 — 전 단계 실패 시 원본 유지 | 압축 7단계; 계약테스트 9·10 |

## POLICY (판정표 v2 — 결정으로 변경 가능)

하나의 런(`runs/<name>/` + 형제 `runs/<name>.launcher.log`)은 아래 우선순위
순서로 정확히 하나의 등급을 받는다. 어느 것도 확정 못 하면 아래 단계는
전부 보호다.

| 등급 | 기계적 조건 | 조치 |
|---|---|---|
| ACTIVE | `hsnotify-<basename>` 유닛 active(`HS_SYSTEMCTL is-active --quiet` 성공), 또는 런 디렉터리 내 임의 파일 mtime < 26h | 원본 유지, 읽기 외 미접근 |
| FAILED | 런처 로그의 `COLLECTOR_EXIT=<n>`이 n≠0(exit 4 honest INCOMPLETE 포함), 또는 마커 존재하지만 INVALID(스키마·전체 `input.hcj.jsonl` sha256 재계산 불일치) | 원본 유지 + 보고 |
| SERVICE_DEPENDENCY | `HS_START_SCRIPTS_DIR`의 `hongscanner-*-start.sh` 파일 내용에 basename 부분 문자열(git 밖 래퍼·serve 게이트 의존) | 원본 유지 |
| GATES_REFERENCED | `HS_GATES_FILE`(docs/GATES.md)에 basename 부분 문자열(grep -F; 보수적 매칭). 파일 부재 시 전체 보호 | 원본 유지 |
| RECENT_RAW | 런 이름의 `YYYY-MM-DD`가 최근 20거래일 집합(KRX 달력 설치 사본, INDEX sha256 대조)에 포함 | 원본 유지 |
| UNKNOWN | 런처 로그 부재 전체·로그 존재하나 `=== run_session end` 라인 부재·마커 부재(smoke/replay 스타일)·마커↔exit 모순·이름 날짜 파싱 불가 | 원본 유지 |
| ARCHIVE_ELIGIBLE | 마커 VALID **+** 런처 로그 존재 **+** `COLLECTOR_EXIT=0` **+** end 라인 존재 **+** 상위 등급 전부 해당 없음 **+** 20거래일 밖 | tar+zstd 무손실 압축 후 원본 정리 |
| DELETE_ELIGIBLE | retention-log.jsonl에 ARCHIVE 기록된 검증 아카이브 중 쿼터 초과분 | 오래된 것(mtime)부터 제거 |

- **교집합 판정 채택 사유(2026-11 2차 교정 ①)**: 마커 VALID만으로
  내구 완료를 증명하는 계약은 존재한다(`src/hs/recorder.nim` — 마커
  VALID가 내구 완료의 유일한 증거, docs/REPLAY_CONTRACT.md §"a COMMITTED
  run ends the day"). 그러나 보존 판정의 무모순·완전성이 우선이므로
  판정은 **두 증거의 교집합만** 허용한다: 마커 VALID + 런처 로그 +
  exit 0 + end 라인. 하나라도 없으면 UNKNOWN(보호)이다.
- **20거래일 창**: 달력 파일을 병합·정렬해 `open` non-null인 날짜만
  거래일로 취급하고, 오늘 이하 최근 `HS_RECENT_TRADING_DAYS`(기본 20)일의
  집합을 만든다. 달력 파일 부재·INDEX sha256 불일치·오늘이 날짜 키
  span 밖·집합이 20일 미만(커버리지 부족)이면 **달력 불신
  (CALENDAR_UNUSABLE) → 전체 보호**다. 달력 승인의 3층 거 규칙
  (ASSUMPTIONS P25)을 그대로 준수한다.
- **100 GiB 소프트 쿼터**: `du(runs/) + du(runs-archive/)` 합산이
  `HS_QUOTA_BYTES`(기본 107374182400)를 초과하면 검증 아카이브를 오래된
  것부터 제거하고, 제거 가능 아카이브가 없는데도 초과하면
  **RETENTION_BLOCKED**: retention-log.jsonl 기록 + FCM 알림 1통 + exit 0
  (정직한 보고이지 운영 중단이 아니다). 검증 기록 없는 `.tar.zst`(외부
  산출물)는 제거 대상이 아니다 — 보호다.
- **주기·충돌 회피**: 토요일 12:00 KST 주간 timer. 활성 세션
  (`hongscanner-session.service`가 active/activating)이면 전체 스킵
  (exit 0, `SKIPPED_ACTIVE_SESSION`, runs/ 무접근) — 세션 진행 중 쓰기가
  판정보다 우선한다. `Persistent=true`의 평일 catch-up도 이 방어로
  순연된다(다음 토요일 자연 실행).
- **Storage Preflight**: `tools/run_session.sh`는 LOG_DIR 확정 후
  `df -B1 --output=avail`이 `HS_PREFLIGHT_MIN_AVAIL`(기본 21474836480 =
  20 GiB = 관측된 하루 원본 ~4 GiB + 봉인·검증 여유 16 GiB) 미만이거나
  df 자체가 실패하면 stderr·런처 로그에 `STORAGE_PREFLIGHT_FAILED`를
  기록하고 exit 2 — 무엇도 시작하지 않는다(fail-closed). 통과 시
  `PREFLIGHT_OK avail=<값>` 1행.
- **retention의 ops 알림은 두 상황만**: `RETENTION_BLOCKED`(retention
  스크립트)와 `STORAGE_PREFLIGHT_FAILED`(preflight). 정상 상황은
  알림 팩트 자체를 생산하지 않는다(무알림이 성립한다 — 발송 여부를
  판단해 억제하는 것이 아니라 아예 만들지 않는다). 발송은 **ops
  side-channel**(`tools/notify/ops_alert.py`): notify 이벤트 원장·전달
  원장 기록 없는 일회성 발송, 재시도 없음. 시도와 결과(exit code·기기별
  결과 라인)는 호출부 기록에만 남는다 — 2026-11-18(S1) 이후 ops
  side-channel의 **자동 호출부는 둘**이다: retention 스크립트
  (`RETENTION_BLOCKED` — retention-log.jsonl의 NOTIFY 행)와 API 서비스
  `serve.py`(readiness FAILED 전환 시 프로세스당 1회, `HS_OPS_ALERT_CMD`가
  빈 값이면 `OPS_ALERT_SKIPPED reason=disabled`만 남기고 미실행 —
  tools/api/README.md §8.1). 세션 런처(`tools/run_session.sh`)와 세션
  래퍼(`hongscanner-session-start.sh`)는 **이 도구를 호출하지 않는다**:
  런처는 `OPS_ALERT`·`OPS_ALERT_SUPPRESSED reason=consumer_push_removed`를
  런처 로그에만, 래퍼의 EXIT 트랩은 `OPS_ALERT_SUPPRESSED` journal 한 줄만
  남긴다 — 운영 경보를 소비자 기기로 보내지 않는다는 P27 경계의 집행이며,
  운영자 전용 경보 채널은 P1이다. 기록 위치는 **systemd
  journal/stderr**(OPS_ALERT_* 저널 라인)이며 파일 쓰기는 없다.
  accepted ≠ delivered
  (tools/notify/README.md §6). 향후 ops 경보에 지속 알림(재시도·
  전달 기록)이 필요하면 신규 인프라를 만들지 않고
  **AGGREGATION_STARTED 선례의 이벤트 계약 확장**(contracts/events +
  dispatcher 어드미션)으로 전환한다.
- **API 노출 정책(2026-11 2차 교정 ④)**: 아카이브된 런은 API가 노출하지
  않는다. 모바일 History는 최근 20거래일의 원본 창만 본다. archive-aware
  API(아카이브 열람·복원 서비스)는 별도 제품 결정으로 이 문서의 범위 밖이다.

## IMPLEMENTATION (구현 계약 — 자유 변경 가능하나 이 문서와 동기화)

### tools/runs_retention.sh

- `bash tools/runs_retention.sh` = **dry-run**(기본): 각 런의 등급·사유·
  크기·조치, 등급별 요약, df avail, 쿼터 현황을 출력하고 파일시스템에
  **아무 것도** 쓰지 않는다(retention-log.jsonl 포함). `--apply`만 실작업.
- flock: `HS_STATE_DIR/retention.lock` 배타 non-blocking — 이미 잠겨 있으면
  exit 0 "already running".
- 상태: `HS_STATE_DIR`(기본 repo 루트/runs-retention)에
  `retention-log.jsonl`(append-only, 라인당 JSON 객체 1개: `t`, `action`,
  `run`/`archive`, `reason`, `bytes_*`, `archive_sha256` 등; action 종류 =
  SKIPPED_ACTIVE_SESSION·CALENDAR_UNUSABLE·ARCHIVE·ARCHIVE_DEFERRED·
  ARCHIVE_FAILED·DELETE·RETENTION_BLOCKED·NOTIFY)과 임시 `tmp/`.
- 아카이브·상태 디렉터리는 `runs/`와 **형제** 경로(`runs-archive/`,
  `runs-retention/`)에 둔다 — serve.py가 요청마다 `os.listdir(runs)`를
  재스캔하므로 runs/ 안에 두면 스캔을 오염시킨다.
- 압축 7단계(ARCHIVE_ELIGIBLE 각각, 전 단계 실패 시 해당 런 건너뛰고
  원본 유지):
  1. `df avail ≥ 런 크기×2` 확인(같은 파티션 이중분 방지) — 부족하면
     연기(ARCHIVE_DEFERRED) 기록.
  2. 원본 전체 파일(런 디렉터리 내 파일 + 형제 런처 로그)의 SHA-256
     manifest 생성(`HS_STATE_DIR/tmp/`).
  3. `tar -C HS_RUNS_DIR -c <name> <name>.launcher.log`(로그 존재 시 두
     멤버) | `zstd -$HS_ZSTD_LEVEL` → `tmp/<name>.tar.zst`.
  4. `zstd -t` 무결성 검사.
  5. 새 임시 디렉터리에 복원(`tar --zstd -xf`) 후 `sha256sum -c`로 전 파일
     sha256 대조 + 파일 수 일치 — 바이트 일치 증명.
  6. 통과 시에만 `HS_ARCHIVE_DIR/<name>.tar.zst`로 mv(기존 파일 있으면
     덮어쓰기 거부·연기)하고 retention-log.jsonl에 ARCHIVE 기록(t, run,
     action=ARCHIVE, bytes_before, bytes_after, archive_sha256,
     reason="sealed COMMITTED marker VALID").
  7. 이후에만 원본 `runs/<name>`·`runs/<name>.launcher.log` 제거. 실패 시
     임시 산출물(manifest·tar.zst·verify)만 정리.
- 환경변수 오버라이드(전부 계약 테스트가 stub으로 교체):
  `HS_RUNS_DIR`·`HS_ARCHIVE_DIR`·`HS_STATE_DIR`·`HS_CALENDAR_DIR`·
  `HS_CALENDAR_INDEX`·`HS_GATES_FILE`·`HS_START_SCRIPTS_DIR`·
  `HS_SYSTEMCTL`(기본 `systemctl --user`)·`HS_ZSTD_LEVEL`(기본 10, VS-0
  실측)·`HS_QUOTA_BYTES`·`HS_RECENT_TRADING_DAYS`·`HS_NOTIFY_CMD`·
  `HSNOTIFY_CONFIG`.
  캘린더 days 계산·마커 검증·로그 기록은 `python3` 단발 명령이고, 알림
  발송(ops_alert.py)은 run_session.sh와 같은 해석 순서의 Python 3.13
  인터프리터로 실행한다(tools/notify/README.md §11).
- exit 0 = 보고 완료(스킵·연기·실패·RETENTION_BLOCKED 포함 — 정직한
  보고는 운영 중단이 아니다), exit 2 = 사용법 오류.

### ops side-channel — tools/notify/ops_alert.py

이 절은 **retention 스크립트의** 경보 경로다. `HS_NOTIFY_CMD`가 설정돼
있으면 `<title> <body>` 두 인자로 호출하고 그 exit code를 NOTIFY 기록에
남긴다(계약테스트의 stub 경로). **미설정 시 기본 발송 경로**는
`tools/notify/ops_alert.py`다 — "작업 특화 CLI"
(notify_register.py 선례). 세션 런처(`tools/run_session.sh`)는 이 경로를
쓰지 않는다(기록 전용, 위 "retention의 ops 알림" 절).

```
<Python 3.13 해석: $HSCOLLECTOR_PYTHON → collector venv → python3.13 → uv>
tools/notify/ops_alert.py --config $HSNOTIFY_CONFIG(기본
~/.local/share/hongscanner/notify/notify_config.json) <title> <body>
```

구현은 tools/notify 라이브러리를 직접 재사용한다:
`notify_config.load_config(..., "dispatch")` → `TokenSource`(서비스계정
JSON 또는 token_command — 토큰 출처는 tools/notify/README.md §8 그대로)
→ `Registry(lock=False).devices()`의 활성 기기 각각에
`notify_fcm.send_message` 1통(notification+data, 명시적
`android.priority`·`market_rank_changes` 채널, 4096바이트 한도
fail-closed). exit 0 = 전 기기 accepted, 2 = 사용법·설정·페이로드 위반,
3 = 활성 기기 없음·자격 실패·미수용 응답. **원장 부수효과 없음**: ops
경보는 이벤트 팩트가 아니므로 dispatcher의 어드미션 게이트·전달 원장을
거치지 않는다(P27/P28의 발송 정책 위반이 아니라 그 밖의 경로다 — 합성
계약테스트는 이 경로를 실번호출 없이 stub으로만 검증한다). 인터프리터를
3.13 계약으로 올린 이유: 이전 구현이 시스템 `python3`(3.12)로
라이브러리를 임포트했는데 tools/notify는 3.13 계약이므로 계약 위반이었다.

### tools/run_session.sh — Storage Preflight

`--out` 인자 파싱 후 `mkdir -p "$LOG_DIR"`·`touch "$LAUNCHER_LOG"` 직후,
`start_worker`·collector 기동 **전에** 실행한다. 미달·df 실패 시 stderr +
런처 로그 `STORAGE_PREFLIGHT_FAILED: avail=<값> required=<값>` + 기록
전용 경보(`OPS_ALERT`·`OPS_ALERT_SUPPRESSED reason=consumer_push_removed`
런처 로그 2행 — `HS_NOTIFY_CMD`가 설정된 경우에만 그 명령을 실행하며,
미설정 시 외부 호출은 0회다) + exit 2(기존
usage 오류 exit 2와 같은 코드 — "아무 것도 시작하지 않은" 거부). 통과 시
`PREFLIGHT_OK avail=<값>` 1행. 기존 인자·순서·동작은 그대로다.

### systemd 유닛 (서버 배포 전문 — git 밖, 여기 보관이 재현성 계약)

```ini
# ~/.config/systemd/user/hongscanner-retention.timer
[Unit]
Description=Hong Scanner runs retention (weekly, Sat 12:00 KST)

[Timer]
OnCalendar=Sat 12:00
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# ~/.config/systemd/user/hongscanner-retention.service
[Unit]
Description=Hong Scanner runs retention (oneshot)

[Service]
Type=oneshot
ExecStart=bash /home/wintrover/hongscanner/tools/runs_retention.sh --apply
```

### 서버 배포 절차 (이 문서가 tools/ bash의 서버 반영 계약을 처음 명문화)

기존 유닛(`hongscanner-session.timer`·`hongscanner-serve.service`)과
git 밖 래퍼(`~/.local/bin/hongscanner-*-start.sh`)은 **참조만** 한다
(SERVICE_DEPENDENCY 판정). 예외는 2026-11-18 S1의 소비자 발송 차단이다:
래퍼 `hongscanner-session-start.sh`의 EXIT 트랩은 journal 한 줄만 남기도록
바뀌었고(백업 `.bak-20261118-s1`), `hongscanner-serve.service`에는
`Environment=HS_OPS_ALERT_CMD=`(빈 값), `hongscanner-retention.service`에는
`Environment=HS_NOTIFY_CMD=/bin/echo` 드롭인이 붙는다. 배포는:

1. `cd ~/hongscanner && git pull --ff-only` (main merge 커밋 일치 확인)
2. 위 유닛 전문 2개를 `~/.config/systemd/user/`에 작성
3. `systemctl --user daemon-reload`
4. `systemctl --user enable --now hongscanner-retention.timer`
5. 수동 트리거 1회 검증: `systemctl --user start
   hongscanner-retention.service` → exit 0·journal 실행 기록·
   retention-log.jsonl 추가·`runs/` 무변경(현 시점 전 런 보호) 관측

preflight 알림(`STORAGE_PREFLIGHT_FAILED`)은 **기록 전용**이다 — 런처
로그에 `OPS_ALERT`와 `OPS_ALERT_SUPPRESSED reason=consumer_push_removed`
두 줄을 남기고 외부 발송을 하지 않는다(2026-11-18 S1). 소비자 기기로
운영 경보를 보내지 않는다는 P27 경계의 집행이며, 세션 유닛·래퍼에
환경변수를 주입할 필요가 없다(정책이 스크립트 본문에 있다). retention
스크립트의 `RETENTION_BLOCKED` 알림은 여전히 ops side-channel을 기본으로
하며, 서버는 `HS_NOTIFY_CMD=/bin/echo` 드롭인으로 journal 기록만 남긴다.

## 알려진 한계

- **무마커 런(smoke/replay)과 무로그 수동 런(fidelity 스타일)은 영구
  보호다**: 로그 부재는 UNKNOWN이고, 마커 부재도 UNKNOWN이다. 이 런들은
  절대 ARCHIVE_ELIGIBLE이 되지 않는다 — 대형화 시 별도 정책 결정이
  필요하다(판정표 교체, 이 문서 수정).
- **RECENT_RAW 집합은 거래일 집합이다**: 비거래일(주말·휴장) 날짜를 가진
  봉인·정상종료 런은 집합 밖이므로 거래일 기준 오래된 런으로 판정된다.
  최근성은 mtime 26h(ACTIVE)이 1차 방어다.
- **ACTIVE의 mtime 판정은 런 디렉터리 내 파일만 본다**(형제 런처 로그의
  mtime은 판정에 들지 않는다) — 판정표 문언 그대로의 기계적 조건이다.
- **쿼터의 du는 apparent size다**: df avail(블록 단위)과 단위가 다르다.
  소프트 쿼터는 운영 가드레일이지 물리적 보장이 아니다.
- **dry-run은 락파일이 이미 존재할 때만 flock을 취한다**: 상태 디렉터리가
  없는 첫 dry-run은 무변경 원칙(디렉터리·파일 생성 금지) 때문에 락 없이
  관측한다.

## VS-0 — 압축 실측표 (2026-11-16, 운영 노트북 사본 측정)

운영 런 사본(`/tmp`에서 원본 무접근)으로 tar+zstd 압축률·시간·복원
sha256을 측정했다. 대상: 2026-11-11·11-12 완주(ARCHIVE_ELIGIBLE 조건)
런 2개, 합계 2,121,328,143바이트. `zstd -t` 양측 통과, 복원 round-trip
sha256 전 파일 일치(3/3).

| level | bytes_before | bytes_after | ratio | 압축 시간 | zstd -t | 복원 sha256 일치 |
|---|---|---|---|---|---|---|
| 3  | 2,121,328,143 | 146,797,631 | 14.45× | 5.2s  | 통과 | 일치 (3/3) |
| 10 | 2,121,328,143 | 111,364,759 | 19.05× | 42.9s | 통과 | 일치 (3/3) |

**채택: `HS_ZSTD_LEVEL` 기본 10**. 주간 배치(토요일 12:00 timer, 활성
세션 스킵 방어 포함) 관점에서 37.7초의 추가 압축 시간은 무의미하고
아카이브 장기 보관 크기가 약 24% 감소한다. 일회성 대량 백로그 압축
시에는 `HS_ZSTD_LEVEL` 오버라이드로 낮출 수 있다.
