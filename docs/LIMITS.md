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
| `PROVIDER_COMPLETENESS` is unmeasurable and stays UNKNOWN forever | even a MATCH on all three compared APIs proves parity of the delivered data only — it cannot prove Kiwoom delivers the actual market completely; VS-F measures `DEMO_REAL_PARITY` only (GATES VS-F F-0) | VS-F F-4 (bounded claim) |
| demo/real fidelity is not settleable from documentation | the official quotes name different subjects ("조회 데이터는 모의투자와 실전이 같습니다" vs "…시세는 모의 서버 값이라 실제 시장 수치와 다를 수 있습니다") and no official document coordinates the two scopes; an explicit mock-0B-equals-market guarantee is absent (checked — ASSUMPTIONS Vendor facts 2026-11-06) | VS-F F-1/F-4 experiments |
| 0B carries no per-trade unique identifier | the official value set ('10','13','14','15','20','290','9081') has no id field, so pair comparison uses the multiset of (체결시각, 현재가, 부호 포함 거래량) tuples; time-only and price/volume-circular matching are forbidden — identical multisets do not prove identical arrival order | VS-F F-4 |
| ka10027 responses carry no query-time field | the client-recorded request time is the only evidence; the 5 s max time-difference allowance is a proposal — no direct round-trip latency measurement exists in current evidence (rate limit 1 s/call, the 1.5 s pacing, and a chain-derived bound are the only cited grounds) and re-freezing is allowed only after F-1 data | VS-F F-1 |
| VS-F minimum sample sizes are unfrozen | the 0B matching-window minimum trade count, ka10080 minimum bar count and ka10027 minimum symbol count have no existing observational basis; freezing arbitrary numbers would corrupt determinism — they freeze after F-1 observation (fail-closed) | VS-F F-1 |
| environment naming is declared but not yet unified in code | the VS-F contract names environments demo/real (official SDK `KIWOOM_MODE` values); the current replay.nim acceptance set still contains "prod" (P11 wording) — unification is announced for F-3; every sealed run to date is demo-only, so there is no impact | VS-F F-3 |
| F-2 completion requires a real demo capture | passing the synthetic ka10080 contract tests proves implementation correctness only; F-2 is complete only with an actual demo-server ka10080 raw capture plus checksum verification (GATES VS-F F-0) | VS-F F-2 |

## Explicit non-goals

- No order execution, no shorting, no position sizing.
- No data in the repository: `calendars/*.json`, `runs/`, vendor extracts are
  gitignored; only `calendars/CALENDAR_INDEX.sha256` is committed.
- No claim that "22 selected RFC 6455 requirements" equals the whole RFC.
- No claim that a passing timer means the next KRX trading day; systemd only
  knows weekdays. The program decides trading days and SKIPs holidays.