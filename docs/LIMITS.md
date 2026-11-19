# Hong Scanner — Limits of the current evidence

What the VS-1 result does **not** prove. Each line names who owns the proof.

| limit | why it matters | owner |
|---|---|---|
| `sha256` equality is byte identity, not correctness | a wrong price recorded consistently still matches | G4 |
| CI uses synthetic fixtures only | CI proves algorithm stability, not market behaviour | PH-1 |
| `13` (cumulative volume) semantics are unconfirmed | `bar_position` marks suspicion; it does not prove session-cumulative | G4 experiment (REST `acc_trde_qty` vs first `13`) |
| REST bar timestamp interpretation needs source and live cross-check | the local official extract describes `cntr_tm` as the bar start; alignment with the WS feed is not yet measured | G4 |
| `290` boundary behaviour at 15:30 is undocumented | conflicts are counted, not resolved | G4 |
| SIGKILL drills do not prove power-loss durability | page cache survives process death; data written between the 60 s fsyncs can be lost and no absolute power-loss guarantee exists | VS-2 recorder drill |
| the standalone recorder is not a live collector | it is not wired to transport or the CLI; it does implement seal + commit marker + periodic fsync, but a live producer is VS-2 work | VS-2 |
| a recorded `session_end` is not proof of durable completion | verify requires a valid commit marker only for a declared `environment`; synthetic streams report the marker state without enforcing it | VS-2 approval |
| no WebSocket client exists in VS-1 | handshake, framing, masking, close codes are VS-2 work | VS-2 |
| the consumption check has a no-sub boundary | it applies to `0B` `ws_raw` ticks only; a stream with `0B` ticks but no subscription evidence at all has every tick quarantined (an honest result), and `ws_frame` synthetic ticks (VS-1) are not checked — the existing synthetic gate passes unharmed | tools/collector/README.md §10 |
| strategy validity is not established | synthetic fixtures are not evidence of market behavior or profitability | PH-2 |
| strategy evidence windows are not a market-validity proof | tainted evidence is held within the shared dependency window, but thresholds and actual vendor field semantics still require validation | PH-1/PH-2 |
| a late session-flag conflict can degrade a closed bar in batch replay | live emissions need a finality or retraction contract before they are published | VS-2 live output contract |
| thresholds come from a synthetic fixture | PH-1 calibrates them on a real capture; that same session cannot also prove detection | PH-1/PH-2 |
| signals == 0 on a real day is not a bug | `NO_TRIGGER_OBSERVED` is a valid outcome | PH-2 |
| one market (KRX) only | the global goal needs a second adapter and the same acceptance evidence | V2 |
| `rest_resp` is schema-audited, not live-verified | a record that fails the declared §12.1 schema still rejects the run (exit 2); a verified page changes no output byte, and whether production responses match this shape is unmeasured | G2/G4 |
| the vendor provides no message-sequence or completeness contract | verified by full-text search of all 337 API specs (zero hits); a silent drop and a quiet market are indistinguishable from the client stream | G2 spot-check |
| the Kiwoom SDK is license-restricted | local install and use for the service are permitted; copying, modifying or bundling it in this repo is not — the adapter boundary must keep vendor code external | VS-2 adapter |
| the credential runtime has hard requirements | kwcli needs Python >= 3.13 (system has 3.12) and a D-Bus session bus for the Secret Service; bus resolution is `DBUS_SESSION_BUS_ADDRESS` (set → wins, avoids autolaunch) then the `$XDG_RUNTIME_DIR/bus` user-bus fallback — a systemd `--user` unit always gets `XDG_RUNTIME_DIR` but never the address variable automatically, so actual availability is proven only by runtime measurement (V-1~V-17); setting the variable explicitly stays a safe practice | VS-2 runtime |
| `run.json` is excluded from checksums | determinism covers the three data artifacts only | inherent |
| `provenance=OK` is self-declared consistency, not independent authenticity | compiler `-d` values and run metadata can be forged together; a match cannot prove the source tree was clean | trusted build and independent attestation design |
| previous runs require their original executable and calendar | the build gate builds the current main, while the run directory does not preserve the executable | run archive and retention design |
| the 0.5% conflict threshold is a policy choice | small samples can trip it; it is fail-closed by design | plan §3.2 |
| manager can still edit branch protection | GitHub cannot prevent a repo admin from changing the rules | P6 audit |
| Northflank fixed egress IP is unverified | no account in scope; U5 stays open | NF-1 |
| provider tick completeness is unverified | a silent feed drop and a quiet market can produce the same stream; `NO_TRIGGER_OBSERVED` speaks only about the observed stream | G2 spot-check (WS bars vs REST `acc_trde_qty`) |
| the ka10027 page cap is scanner-side | if more pages remain when the cap is reached, they are "not fetched", not "no more candidates"; the subscription additionally truncates at the top-100 selection — even a fully fetched universe registers only the first 100 per direction, and that exclusion is a recorded fact (subscription_truncated gap, SUBSCRIPTION_TRUNCATED event), never silence | VS-2 recorder contract |
| refresh=0's termination scope is undocumented | the official wording ("0일경우 기존등록한 item/type은 해지") does not say 전역/같은 grp_no/같은 type, so the scanner never sends refresh "0" | G2 mock subscription experiments |
| grp_no has no documented semantics | its description is empty; all 46 official examples pin "1" | G2 |
| REMOVE partial removal is undocumented | the scanner always REMOVEs a full generation, never a subset | G2 |
| multi-type REG acceptance is undocumented | all official examples are single-type; the composition cannot produce a mixed REG | G2 |
| the `0s` removal form is undocumented | the market-state channel ends with the connection; no REMOVE record exists for 0s | G2 |
| the Kiwoom PING period and no-response policy are undocumented | received PINGs are recorded as ws_raw so the period becomes observable | G2 |
| FID 215's full value table is unconfirmed | only the close subset {2, 4, 8, 9} is evidenced; 9 (전체장마감) occurs only after 18:00 | G2 observation |
| the 200-code subscription total is unreachable through the composition | the direction caps (≤100) bind first — 100+100 is the reachable boundary; the selection policy (first 100 per direction, recorded as `selection_policy`) is that boundary's upstream producer, while `composeRemoveData` has no direction split, so its total cap is independently enforced and tested; the composeRegData checks stay as unchanged defense (a raw 101-code set still rejects) | inherent |
| demo observation success is not production evidence | Kiwoom documents the mock as a "가상 매매 시스템" test stage with "제공 기능 및 데이터에 일부 차이" possible, and claims no feed identity (UNVERIFIED) | PH-1 (separate production confirmation) |
| byte evidence excludes TLS, TCP framing and WS control frames | application payloads and non-secret pagination metadata do not expose every transport-level anomaly; the payload boundary is implementable as `websockets` `recv(decode=False)` (official docs, returns payload bytes after fragment reassembly) | VS-2 recorder contract |
| attestation evidence is per-merge, not standing | the attest→verify→install path is implemented and measured repeatedly (GATES P13 evidence log — 19 installed versions, 4 attest-gate failures as of 2026-11-03); it must be re-measured after every behavior-changing main merge, and the verify line `provenance=OK` itself stays self-declared metadata — the digest chain, not that line, is what ties the installed binary to the exact main sha | P13 re-measurement |
| CI green is bounded trust | the workflow file and repo-admin actions sit inside the trust boundary; GitHub Actions cannot attest what is installed on the host | attestation design |
| strategy intervals and thresholds are held before approval | `warmup`/`lookback` windows and bp thresholds come from a synthetic fixture; signals before the PH-1 freeze are not acceptance evidence | PH-1 |
| no cloud Kiwoom connection exists | every cloud-side vendor behaviour — egress-IP acceptance (U13), APAC region latency (U14), live session behaviour under the container runtime — is unmeasured; all live evidence so far came from the operator machine | NF-1/NF-3 |
| the Northflank deployment and probe mapping are unmeasured | the probe mapping (startup→`/startup`, readiness→`/ready`, liveness→`/live`, port 8081) is a console-side manual step (tools/container/README.md §7.2) that has never been exercised on the platform | NF-5/NF-7 |
| image attestation is still GitHub-signed | the image digest provenance, like the binary attestations, is signed inside GitHub's infrastructure — it is not independent of GitHub and does not remove the admin trust root (tools/container/README.md §8.4) | NF-9 |
| local `gh attestation verify oci://` is refused | the local token lacks the `read:packages` scope, so the CLI verification path fails; only the operator-PAT path verifies the image attestation (tools/container/README.md §8.3) — the 2026-11-02 re-check used the repository attestations API out-of-workflow | NF-9 |
| the attest.yml image staging list is manually synchronized with the Dockerfile | the drift broke image builds at `7eefd0d` and again at `06f4208` (a docs-only merge that landed before the fix); the contract suites passed on both failing merges, so no current test catches this drift class — PR #43 (`bdc697e`) fixed it and every main push since has an image (`main-bdc697e`·`main-8a3e74a`·`main-bd28355`), but the Dockerfile COPY-list ↔ attest.yml staging-list match remains a manually maintained invariant | NF-9 staging invariant |
| a single Pod is not HA | redeploys and container restarts stop the API and the probes for the restart window; the single-writer policy (P16) forbids scale-out redundancy | NF-5 |
| no backup/restore drill exists | the volume holds the only durable copy of `runs/` and `notify/`; its loss and restore behaviour are unmeasured | NF-11 |
| supervisor SIGKILL escalation and run-id suffix exhaustion are untested live | the supervisor suite covers the contract surface with fake children and an injected clock; SIGKILL after the grace window and the attempt-cap-exhausted path (`-a`·`-b`·`-c` all present, day uncommitted) have no live observation | NF-7 |
| the cloud sidecar is demo-only | it refuses any base other than demo/mockapi (P19); production Kiwoom over a cloud egress is unmeasured and needs a separate confirmation | NF-3 |
| a late start recovers bars, not observation | a ka10080 backfill reconstructs 3-minute bars, never the live stream: the 300 s candidate churn, the WS tick order and every unobserved event of the downtime are unrecoverable — a `LATE_START` session never becomes `FULL_SESSION` (P22) | VS-2C |
| pre-rewrite sealed runs carry legacy semantics | runs sealed before the VS-1 symmetric rewrite (2026-11-06) were produced by the legacy asymmetric engine; §8 check 1 replays each run only under its own commit's binary, so those runs never re-verify under the symmetric engine | inherent (§8 check 1) |
| `origin`, `contract_version`, `session_mode` are declared, not produced | the fields exist as contract text (REPLAY_CONTRACT §7/§12.8; P21/P22/P24) until VS-2B/VS-2C emit them; absent fields keep pre-contract semantics | VS-2B/VS-2C |
| `events_contract` gates display paths, not judgment | the marker (`"top10-v1"`) is a config-record declaration new collectors write; TOP10 judgment itself is code-level and fires on any stream replayed by the new binary (the legacy smoke fixture gains TOP10 facts under the new engine), while serve branches to the fact-translate history only for runs that declare it — a quiet new run (zero TOP10 facts) is not confused with a legacy run | inherent (§8 check 1) |
| TOP10 alert delivery is observed, not guaranteed | FCM HIGH is a delivery attempt (Doze wake, no time guarantee), Android channel importance is user-changeable after creation, and an FCM 200 is acceptance not arrival — acceptance evidence is the observed device display (ASSUMPTIONS Vendor facts 2026-11-11) | P12 device acceptance |
| admission bounds are per observation group, not per hour | the dispatcher guarantees ≤1 sound-channel + ≤1 silent message per (observed_at group × device); ten busy groups can still mean up to 20 messages in a session, the device's actual sound is user-owned channel state, and cross-group round-trips (a→b then b→a) remain two separate delivered facts | P28 policy |
| digest coverage rides in the message payload | every covered event_id travels in `data.event_ids` (≤4096-byte FCM payload, enforced fail-closed); tap-to-all-events is a client rendering obligation — the server can only prove it sent the ids, the observed list view is the acceptance evidence | P12 device acceptance |
| the foreground MethodChannel posting path is unconfirmed | posting and display are proven (EdgeLighting ×4, summary reject, dispatch ledger 1:1) but the poster's identity — app channel (`tag=null`, id=eventId.hashCode) vs FCM auto-display (`FCM-Notification:<id>`) — became unverifiable: the 14:04:17 batch arrived while Brave held the foreground (background auto-display dominant), the 13:54:19 candidate batch's NotificationRecords were destroyed by the 14:19:31 uninstall and logcat rotation; the remeasure procedure (sole foreground, immediate `dumpsys notification --noredact` + logcat capture — buffer rotates in ~2.5 h) is recorded in GATES 2026-11-11 낮 | P12 device acceptance (re-observation) |
| the system auto-group summary tap does not route | Android auto-groups 4+ un-grouped notifications per app and posts its own summary without the app's contentIntent — tapping the summary expands the group instead of opening the event detail; only child-notification taps route to `openEvent` | inherent (explicit-group design decision, not implemented) |
| alert latency and burst are structural | a notification fires only after an observation group is confirmed by the next group or session end (300 s poll → 300 s+ latency is possible) and one group can carry up to ~40 facts at once; Samsung throttling was observed in practice ("Muting recently noisy", numAlertViolations=85, the 13:49 batch posted with no alert) | P27 policy (volume policy decision pending) |
| mid-session device removal leaves facts unpushed | the 14:19:28 user uninstall retired the token (3× FCM 404, token_retired=3) and the final 43 facts stayed recorded-but-undelivered — device presence is a delivery precondition, not a system defect | operator device lifecycle |
| dispatcher aggregate counters are tick artifacts | `events_total` is re-assigned each tick as the size of the shared cumulative ledger (all runs, not the watched run's file) and `dedup_suppressed` re-counts already-ACCEPTED pairs every tick, so neither matches the run's event file line count; delivery truth is the delivery ledger records | inherent (dispatch_tick re-reads the whole ledger) |
| `PROVIDER_COMPLETENESS` is unmeasurable and stays UNKNOWN forever | even a MATCH on all three compared APIs proves parity of the delivered data only — it cannot prove Kiwoom delivers the actual market completely; VS-F measures `DEMO_REAL_PARITY` only (GATES VS-F F-0) | VS-F F-4 (bounded claim) |
| demo/real fidelity is not settleable from documentation | the official quotes name different subjects ("조회 데이터는 모의투자와 실전이 같습니다" vs "…시세는 모의 서버 값이라 실제 시장 수치와 다를 수 있습니다") and no official document coordinates the two scopes; an explicit mock-0B-equals-market guarantee is absent (checked — ASSUMPTIONS Vendor facts 2026-11-06) | VS-F F-1/F-4 experiments |
| 0B carries no per-trade unique identifier | the official value set ('10','13','14','15','20','290','9081') has no id field, so pair comparison uses the multiset of (체결시각, 현재가, 부호 포함 거래량) tuples; time-only and price/volume-circular matching are forbidden — identical multisets do not prove identical arrival order | VS-F F-4 |
| ka10027 responses carry no query-time field | the client-recorded request time is the only evidence; the 5 s max time-difference allowance is a proposal — no direct round-trip latency measurement exists in current evidence (rate limit 1 s/call, the 1.5 s pacing, and a chain-derived bound are the only cited grounds) and re-freezing is allowed only after F-1 data | VS-F F-1 |
| VS-F minimum sample sizes are unfrozen | the 0B matching-window minimum trade count, ka10080 minimum bar count and ka10027 minimum symbol count have no existing observational basis; freezing arbitrary numbers would corrupt determinism — they freeze after F-1 observation (fail-closed) | VS-F F-1 |
| environment naming is declared but not yet unified in code | the VS-F contract names environments demo/real (official SDK `KIWOOM_MODE` values); the current replay.nim acceptance set still contains "prod" (P11 wording) — unification is announced for F-3; every sealed run to date is demo-only, so there is no impact | VS-F F-3 |
| F-2 completion requires a real demo capture | passing the synthetic ka10080 contract tests proves implementation correctness only; F-2 is complete only with an actual demo-server ka10080 raw capture plus checksum verification (GATES VS-F F-0) | VS-F F-2 |
| VS-A 60s failure alert is a server-side acceptance SLO, not device arrival | `T_detect` (<1s collector exit / <=15s watchdog) + `T_dispatch` (<=30s FCM HTTP v1 timeout) <= 45s covers FCM server acceptance; physical Android arrival (`T_delivery`) remains external/best-effort (P12) | VS-A runtime |
| VS-C `<1s` market-view latency is conditional on the `READY` state of the serve readiness contract | the contract is `WARMING` (HTTP `503` + `Retry-After: 5`) while the startup pre-warm folds the latest eligible run in a background thread, `READY` once warm, `FAILED` on a data fault (HTTP 500 `data_fault`); until pre-warm completes the honest answer is `503` + `Retry-After: 5`, not a slow 200. Measured on the production server (`hongscanner-srv`, 7.9 GiB runs, 3.4 GiB latest input): cold window 15.7 s after a manual restart and 18.0 s from boot-probe start, warm `/mobile/market-view` P95 432–435 ms over loopback. The earlier 13.250 s / 745.21 ms figures were the workstation instance (2.0 GiB). A `<1s` budget assumes `READY` and a client that honors `Retry-After` rather than reading `WARMING` as failure | VS-C runtime |
| the production LAN IP (`192.168.0.82`) is DHCP and its post-router-reboot persistence is UNKNOWN | the mobile path uses the tailnet MagicDNS name (`https://hongscanner-srv.tail10d26b.ts.net` → `100.125.164.8`), which is independent of the LAN lease; the LAN address (`wlo1`, MAC `ac:d1:b8:9b:60:bd`, DHCP via `192.168.0.1`) is used for SSH/ops only and is re-checked each session. No router-reboot observation exists | VS-3 E2E preflight / OC-1 ops |
| live `T0..T5` end-to-end latency is UNKNOWN | every hop is defined on the observing device's monotonic clock (GATES VS-3 E2E) and no live market-hours drill has stitched the chain; cross-device wall-clock subtraction is forbidden (clock skew), so the whole-chain figure exists only once the Step 3 controlled drill measures it | VS-3 E2E acceptance (Step 3 drill) |
| the host API is the canonical main checkout, not an attested artifact | on `hongscanner-srv`, systemd runs the checkout's `tools/api/serve.py` through a wrapper that first verifies an installed attested binary against a host-side smoke run; the startup `SERVE_PROVENANCE` line (branch, commit, `HEAD:tools/api/serve.py` blob = on-disk blob, sha256, `provenance=OK` only when branch is `main` and both blobs match) is a bounded statement about that checkout, not a GitHub attestation — the attestation chain covers the hongscanner/collector binaries only, and the wrapper gate is separate host configuration | P13 host service (OC-0/OC-1) |
| a stale smoke-run gate in the service wrapper turns the next boot into a permanent startup failure | measured 2026-11-17: the wrapper verified `smoke-2026-11-12-6e3ad32` while the installed binary was `e6fbdda`, so `verify` exited 7; the already-running service was unaffected until restart. Fixed by creating `smoke-2026-11-17-2735dae` with the installed binary and changing only `SMOKE_RUN` (backup kept). Every future binary install must regenerate the smoke run and update the gate before restart | P13/OC-1 deploy contract |
| the production cold start serves `WARMING` for ~16–18 s | on 7.9 GiB of runs with a 3.4 GiB latest input, pre-warm took 15.7 s after a manual restart and 17.8 s from probe start after boot; clients must honor `Retry-After` and re-poll. A client that treats `503` as terminal sees an outage. The Android warming path is source-verified (fixed 5 s wait, 5 retries ≤25 s since PR #107, then an honest "데이터 준비 중" error) but has no physical-device observation; the earlier 15 s budget could expire just before READY | VS-C runtime / OC-3 Step 4 |
| server-side HTTPS 200 proves ingress, not phone delivery | the post-boot probe curled `https://hongscanner-srv.tail10d26b.ts.net` from the server itself (200, 4.1 s) — this proves the Tailscale serve proxy, DNS and certificate, not that the physical phone received or posted anything (T4/T5 remain UNKNOWN) | VS-3 E2E device observation |
| `OPS_ALERT_CALLED` is not delivery | the API `FAILED` path invokes `tools/notify/ops_alert.py` exactly once per process (latched under the readiness lock); a timeout or nonzero rc is journaled (`OPS_ALERT_FAILED_ERROR`/`OPS_ALERT_STDERR`) with no retry and no fallback channel, and even `result=accepted` is FCM acceptance, not device arrival | VS-3 E2E device observation |
| an alive-but-stalled API process is outside systemd's view | serve.py sends no `WATCHDOG=1`, `WatchdogSec` is unset, and no independent timer probes `/status`; a hang after `READY` leaves the unit `active (running)`. The launcher's `SESSION_STALL_DETECTED` (default 900 s) watches session progress, not API health | VS-2 follow-up (heartbeat contract) |
| `/status.readiness` speaks only for the projection | `WARMING`/`READY`/`FAILED` describe the pre-warm of the latest eligible run; collector progress and data recency are separate authorities and are not composited into this endpoint (no single `HEALTHY` boolean) | OC-2 scope boundary |
| the 08:50 session died on a candidate duplicate (2026-11-17) | the stale `e6fbdda` binary exited `2` on `candidate contains a duplicate code: 016800` at the open; the preserved input keeps only the up page (one occurrence) because the process died before the down response was written, so whether `016800` was cross- or intra-direction cannot be decided from the recorded bytes. Both shapes are absorbed now: cross-direction codes by `up_wins_dedup` (`cross_duplicate`), same-direction repeats by deterministic first-appearance dedup (`duplicate_code`), and `composeRegData` still rejects any duplicate that reaches it as a defensive contract | none — recorder contract closed 2026-11-18 (dedup is recorded, not silent) |
| session-failure alerts are record-only on the host | since S1 (2026-11-18) the launcher's `COLLECTOR_FAILED` alert and the wrapper's early-exit trap write `OPS_ALERT` / `OPS_ALERT_SUPPRESSED reason=consumer_push_removed` to the launcher log and journald and invoke no external command (measured 2026-11-18: 0 runs when `HS_NOTIFY_CMD` is unset, 1 when set). Detecting a session that never started therefore depends on the independent observer timer (`tools/observe_session.sh`, 08:45/08:55 checkpoints), not on a push; a separate operator channel is P1 | OC-3 device observation / P1 operator channel |
| no standing probe verifies that a session produced data | the session unit's exit state is not polled; the launcher's `SESSION_STALL_DETECTED` (default 900 s) watches progress only while the launcher runs. A session that exits 0 with a thin or empty capture is not distinguished from a healthy one by any current automated check, and the next 08:50 firing has no observation yet | VS-A follow-up (post-session acceptance check) |
| the serve start gate's `SMOKE_RUN` must be re-pointed after every code-changing install | `verify` pins `code_commit`/`origin_main_sha`, so a smoke run made by an older binary makes the wrapper's gate exit 7 and blocks service start. The fix is a manual one-line edit (backups kept) and has already bitten twice: `smoke-2026-11-12-6e3ad32` under `e6fbdda`, then `smoke-2026-11-17-2735dae` under `03704ac`. Nothing in CI catches the stale pointer because it lives only on the host | host operator / installer automation |
| the first ledger-reading request after a process start pays a full validation | `/status` and `/events/{id}` read only bytes appended since the last call, but the first such call after a (re)start validates the whole notify ledger once — 4.16 s at 206 MB / 579,917 lines on 2026-11-17. A restart during market hours therefore makes the very first tap the slowest one, and the ledger grows every trading day (579,917 events on 2026-11-17) | host operator (restart timing) / future prewarm |
| the `/events` list still materializes the whole ledger | the list response itself contains every event, so it remains O(ledger) and did not return within 30 s at 206 MB; the incremental contract covers `/status` and one-event detail only | API contract follow-up (pagination) if the list is needed operationally |
| old or absent event ids scan the ledger backward | the tail-first lookup is O(1) for recent ids but O(ledger) for an id near the head or absent — 2.73 s at 206 MB; the app's 5 s tap timeout bounds how old a notification tap may be | VS-3 device observation |
| a tailnet render outside market hours is not E2E acceptance | the 2026-11-17 19:31 KST observation proves the client path (ACL, HTTPS proxy, APK define) renders recorded facts, not that a live 09:00–15:30 session's facts reach the phone; `E2E Accepted` stays 0 and PH-1/PH-2 stay BLOCKED | VS-3 E2E acceptance (Steps 3–4) |
| the T0..T5 60 s chain is still unmeasured as a whole | the phone acceptance recorded no clock offsets, so the server-side 60 s SLO (`T0`→`T3`) and the phone hops (`T4`/`T5`) remain separate clock domains — cross-device wall-clock subtraction is forbidden, and the whole-path figure exists only after the live controlled drill | VS-3 E2E acceptance (Step 3 drill) |
| the rendered market view is a projection, not a freshness signal | the app shows whatever the latest eligible run records; neither the phone acceptance nor `/status.readiness` composites collector progress or data recency, and no standing check compares the served run's age with the market clock | VS-A follow-up (post-session acceptance check) |
| FCM acceptance is not delivery and the phone posts no ACK | the registry stores device ids and the server records FCM 200 responses, but no device-originated acknowledgement exists — an accepted message never displayed and a token that is never used are indistinguishable server-side; device display/tap observations remain the only delivery evidence | P12 device acceptance |
| the phone acceptance says nothing about the LAN DHCP lease | the client path is the tailnet MagicDNS name, so `192.168.0.82` (DHCP via `192.168.0.1`) was not exercised; a DHCP reservation is not recorded and post-router-reboot persistence is unmeasured | OC-1 ops / VS-3 E2E preflight |
| the second phone (`s25-ultra`) has never registered for push | the server's FCM registry contains only `wuyoni-sm-g977n`; an s25-ultra install receives no notification until the operator registers its token, and its app/API path has no observation | operator device lifecycle |
| `tailscale serve` masks the client identity from the API | the proxy connects to `127.0.0.1:8080`, so serve.py logs `127.0.0.1` for every tailnet request — attributing a request to one phone (or proving it was not the phone) needs device-side evidence (screen dump, `tailscale status`, logcat), never the server log | VS-3 E2E device observation |
| the operating APK is a debug build | both 2026-11-17 acceptances ran the debug APK (DEBUG band on screen, debug signing, debuggable); whether production ships a release build is undecided, and a debug-signed artifact is a distribution trust problem, not just a UI badge | release build/keystore decision (operator) |
| 09:30 벽시계 교차는 실제 거래일의 실측 관측으로만 증명된다 | replay `?as_of=`는 판정 함수의 결정론을 증명하지만, 실제 시계가 그 경계를 지나며 화면이 바뀌는 것은 별개다 | VS-3 E2E acceptance (live 09:30 boundary observation) |
| 모바일 60초 표시 SLO는 두 기기에서 측정하는 운영 SLO다 | Dart `Timer.periodic`과 OS 스케줄링은 주기를 보장하지 않는다(공식 문서: 연속 콜백 간격은 duration보다 짧거나 길 수 있다) | P12 device acceptance (s25-ultra · s10) |
| 피크 알림의 "그룹당 정확히 1통"은 서버 판정이며 기기 소리를 보장하지 않는다 | 서버는 그룹당 FCM 발송 1회를 보장하지만 FCM 도착·Android 게시·스피커 출력은 Android/OEM/사용자 설정(방해 금지·볼륨·채널 무음)의 권한이다. FCM HIGH도 즉시 도착 보증이 아니다(공식 문서) | P12 device acceptance (S10) |
| 발송 성공과 delivery record append 사이의 크래시 창은 중복 발송을 만들 수 있다 | `_attempt_unit`은 `send_message` 반환 뒤에만 `record_all`을 호출한다(send → record). 그 사이에 프로세스가 죽으면 재시작 후 같은 그룹이 다시 발송되어 소리가 2회 날 수 있다. 누락보다 중복을 택한 의도된 트레이드오프이며 exactly-once를 주장하지 않는다 | dispatcher crash semantics |
| 세션 개장이 UNKNOWN이면 피크 특권이 없다 | 달력 레코드 부재·휴장(`open: null`)·비정규 타임스탬프에서 `session_open=None`이면 API는 `core`, dispatcher는 P28 60분 예산을 쓴다. 09:00을 추측하지 않는다 — 실패 방향은 "피크에 조용해짐"이고 오발송이 아니다 | P30 fail-closed |
| 2026-11-19 시각의 1차 출처 본문은 확보되지 않았다 | KRX 공지(`noti_no=261115880`, `noti_dd=20261105`)는 "대학수학능력시험일(11.19) 증시장 등 거래시간 임시 변경" 제목과 함께 첨부 참조만 제공하고 첨부 본문이 0바이트로 차단됐다. 10:00/16:30은 2차 보도 3곳 일치로 기록했고 운영 달력은 `CAL-2026Q4-KRX-4150e8a04230`(open 10:00, close 16:30)으로 개정했다. `tools/check_calendar_source.py`는 특별 개·폐장시간 변경을 증명하지 못하므로 이 개정은 운영자 승인(P25) 근거다 | P25 operator approval |

## Independent session observer (`tools/observe_session.sh`)

세션 내부에서 관측하면 관측 대상이 죽을 때 관측자도 죽는다(08:45에는 08:50
타이머가 아직 발화하지 않았고, 15:45에는 세션이 이미 끝난다). 그래서 관측은
세션과 분리된 systemd **user** 타이머
`tools/systemd/hongscanner-observe.timer`가 맡는다.

- 체크포인트는 런 달력의 `open`에서 계산한다(`tools/observe_schedule.py`):
  고정 `08:45` · `08:55` · `15:45` + open−5/+5/+15/+25/+35분. 10:00 개장일이면
  `08:45` · `08:55` · `09:55` · `10:05` · `10:15` · `10:25` · `10:35` · `15:45`,
  09:00 개장일이면 `08:45` · `08:55` · `09:05` · `09:15` · `09:25` · `09:35` ·
  `15:45`다. 달력 open을 읽지 못하면 10:00 기준 LEGACY 목록으로 후퇴하며,
  그 목록은 다른 개장 시각의 피크를 증명하지 않는다.
- 증거 파일: `~/.local/share/hongscanner/observe/observe-<KST session_date>.hcj.jsonl`
  — 실행마다 한 줄 JSON을 append한다(덮어쓰지 않는다).
- **이 타이머는 세션과 독립이다** — 세션 서비스가 죽거나 끝나도 체크포인트는
  남는다. 세션 유닛과의 `After=`/`Requires=` 의존성은 없다.
- **`Persistent=false`라 꺼져 있던 시간은 기록하지 않는다.** 놓친 체크포인트는
  소급 생성되지 않으며, 파일에 없는 것 자체가 그 시간의 증거다.
- 한계: 체크포인트는 표본이고 연속 감시가 아니다 — 8줄 사이의 상태 변화는
  기록되지 않는다. 각 줄의 `null`은 "0"이 아니라 "측정 실패"이고 `errors`가
  이유를 적는다. 08:45에는 당일 런 디렉터리가 아직 없으므로 `run_dir`과
  `calendar_open`은 정직한 null이다.

## Post attestation (`tools/attest_notifications.py`)

서버가 "보냈다"고 기록한 알림과 S10 트레이에서 관측된 알림을 같은 tag
(`hs-g|<observed_at>|<device_id>`)로 조인한다. 판정 축은 서로 다른 네 가지다.

- `expected` — 피크(`[open, open+30m)`) 이벤트이면서 **관측 창 안에서** 발송된
  가청(`single`/`summary`) 그룹. coverage의 분모이며 전부 관측되어야 한다.
- `accounted` — 세션 원장이 주장하는 모든 가청 그룹. 기기에만 보이는 tag를
  가려내는 기준이다. 피크 밖 그룹이 여기 속하는 것은 실패가 아니다.
  `unaccounted = observed − accounted`만 `COVERAGE_INCOMPLETE`다.
- `late` — 피크 그룹인데 ACCEPTED 발송이 관측 창 밖인 tag. 관측자가 증명할
  수 없는 구간이므로 분모에서 조용히 빼지 않고 실패로 남긴다.
- `undelivered` — 피크 그룹인데 ACCEPTED 발송이 하나도 없는 tag(FCM 실패·미완료).
  이 집합이 없으면 실패한 그룹이 분모에서 빠져 0/0 통과가 된다.
- `preopen_delivered` — 개장 전 관측 이벤트가 피크 중에 발송된 증거.
  `PREOPEN_CONTAMINATION`이다.

관측 창 종료는 피크 종료가 아니라 전달 지연의 실측 상한을 덮는다. 2026-11-19
피크 이벤트 114건의 관측→전달 지연은 최소 5.6 / 중앙 5.7 / 최대 5.8분이었고,
09:29:59 이벤트는 09:35:45에 도착했다. 그래서 2026-11-20 창은 `08:58~09:45`다.

피크 그룹이 0건이면 `vacuous: true` + `coverage: null`로 수용한다 — 시장이
그룹을 만들지 않은 날 소리가 0번 나는 것은 정상이다. 다만 조용한 통과를
숨기지 않도록 리포트에 남긴다.

`OBSERVED_ACTIVE`는 "그 시각에 트레이에 있었다"는 뜻이지 "게시된 모든 순간을
놓치지 않았다"가 아니다. 소리 발생은 별도의 사람 확인 증거다.

조인과 수용의 경계:

- **포그라운드 재게시는 tag를 잃는다.** 앱이 화면에 떠 있을 때 FCM 메시지는
  콜백으로 전달되고, Dart가 MethodChannel로 다시 게시하는 경로는
  `notify(null, id, …)`를 쓴다(`mobile/android/.../MainActivity.kt:232,267`).
  그래서 수용 창 동안 앱은 백그라운드여야 한다 — 화면 꺼짐/잠금이 그 조건이다.
  포그라운드 게시는 tag가 없어 어떤 그룹과도 조인되지 않고 `missing`으로 남는다.
- **FCM HTTP 200은 기기 도달이 아니다.** 문서상 "accepted for delivery"이고,
  알림 메시지는 항상 collapsible이라 기기가 오프라인인 동안의 미전달분은 더
  새로운 메시지로 대체될 수 있다. 이것이 관측 결과에 나타나면 `missing`이며,
  기기 오프라인이 원인이면 그대로 수용 실패다.
- **관측 기록은 `id`를 남기지 않는다.** Android의 정체성은 `(tag, id)`지만
  백그라운드 FCM은 id=0으로 게시하므로 tag 단독 조인이 성립한다. 같은 tag의
  서로 다른 id를 구분해야 하는 경로(포그라운드·다른 게시자)는 이 계약 밖이다.
- **늦게 시작한 관측은 수용되지 않는다.** 관측기는 창 시작 + 90초 이후 시작을
  `exit 2`로 거부한다. 절전에서 09:10에 깨어난 런은 09:10–09:45만 표본이므로
  전 구간 관측의 증거가 될 수 없다.
- **두 기기 비교는 tag가 아니라 논리 그룹으로 한다.** tag에는 `device_id`가
  들어가므로 기기별 tag 문자열은 정상적으로 다르다. 비교 축은 device_id를 뗀
  `observed_at` 그룹과 고정 슬롯(digest)이다. `CROSS_DEVICE_MISMATCH`는
  "각 기기는 자기 기준으로 완전하지만 받은 집합이 다르다"를 잡는다.
- **같은 FID를 가진 두 설치는 '두 기기'가 아니다.** 앱 데이터 복제(Smart
  Switch 등)로 Firebase 설치 ID가 복제되면 두 기기가 같은 FCM 토큰을 쓰게 되고,
  서버는 두 대에 보냈다고 기록하지만 실제 라우팅 주소는 하나다. 등록 전에
  레지스트리의 토큰 지문이 서로 다른지 확인해야 한다(2026-11-19 S25에서 실측).
- **수용된 digest 전달만 슬롯을 면제한다.** 무음 digest는 `market_rank_digest`
  슬롯 하나를 재사용하므로 가청 그룹과 같이 취급하면 피크 중 digest 1통으로
  수용이 실패한다. 전달 주장이 없는 슬롯 관측은 여전히 미계상이다.
- **게시 관측은 소리 관측이 아니다.** `mode_ringer=1`(진동)이나 알림 스트림
  음량 0이면 트레이 관측이 100%여도 소리는 나지 않는다. 기기별 ringer·음량은
  별도 실측 항목이다(2026-11-19 S10은 NORMAL·9/15로 복구, S25는 잠금으로 미실시).

## Explicit non-goals

- No order execution, no shorting, no position sizing.
- No data in the repository: `calendars/*.json`, `runs/`, vendor extracts are
  gitignored; only `calendars/CALENDAR_INDEX.sha256` is committed.
- No claim that "22 selected RFC 6455 requirements" equals the whole RFC.
- No claim that a passing timer means the next KRX trading day; systemd only
  knows weekdays. The program decides trading days and SKIPs holidays.