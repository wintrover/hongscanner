# hongscanner (mobile)

Flutter Android app for Hong Scanner (VS-3, PR-7): a **read-only
projection of recorded facts** served by the local API
(`tools/api/README.md` is the contract). The app judges nothing, caches
no authority, and has no write path — it renders what the API records
and honestly says "기록 없음 / 오프라인" when there is nothing recorded
or no connection. No real market data enters the app or the repository
(repo rule).

## Layout

- `lib/main.dart` — app root, bottom-navigation shell (2 tabs),
  `defaultAppStore()` / `defaultPushService()` composition points
- `lib/screens/` — Market View · Event Detail (all data-driven), plus
  `app_scope.dart` (InheritedNotifier) and shared honest-state widgets in
  `widgets.dart`
- `lib/state/app_store.dart` — the single `ChangeNotifier` store: the
  market-view projection section, event selection/routing, push
  permission flow, bounded-backoff resync
- `lib/api/api_client.dart` · `lib/api/api_models.dart` — typed GET-only
  client matching `tools/api/README.md` (identifier validation mirrors
  the server's; `null` = "no record" is preserved, never coerced to 0)
- `lib/api/credentials.dart` — the Basic-auth credential pair value type
  (header generation; toString never carries either half)
- `lib/services/credential_store.dart` — `CredentialStore` abstraction:
  `SecureCredentialStore` (flutter_secure_storage, Android Keystore) and
  the in-memory fake for tests
- `lib/screens/auth_dialog.dart` — the one re-entry dialog for API
  credentials (shown on 401)
- `lib/services/push_service.dart` — `PushService` +
  `PushMessageSource` abstractions, `PushMessage` payload type
- `lib/services/noop_push_service.dart` — `NoopPushService` (default;
  reports not-ready, answers null "nothing was asked")
- `lib/services/fcm_push_service.dart` — `FcmPushService`
  (fail-closed until Firebase is initialized)
- `lib/services/push_permission.dart` — persisted ask history
  (KeyValueStore over `shared_preferences`) for the Android 13+
  denied-ambiguity problem

## Requirements

- Dart ^3.6.0 / Flutter ≥ 3.27 — pinned local toolchain: Flutter
  3.47.9 stable / Dart 3.13.7 (`~/sdk/flutter`)
- Android `minSdk 24` — set in `android/app/build.gradle.kts`
- Dependencies: `firebase_core`, `firebase_messaging: ^17.0.1`,
  `shared_preferences` (ask-history persistence only),
  `flutter_secure_storage: ^11.2.0` (API Basic-auth credentials only —
  Android Keystore-backed storage; deliberately NOT routed through
  `shared_preferences`, which stays the ask-history store)

## Running against the local API

The API's default bind is **127.0.0.1**; `--bind <IPv4 unicast>` is the
only way to change it — private/link-local addresses included
(`tools/api/README.md` §1). `0.0.0.0` is container-only (behind the
platform ingress), and direct internet exposure of any non-loopback
address is a contract violation (§1/§5). Start it, then point the app
at it:

```sh
python3.13 tools/api/serve.py --runs /abs/runs --ledger /abs/ledger.hcj.jsonl --port 8080
flutter run --dart-define=HS_API_BASE=http://10.0.2.2:8080   # Android emulator
```

- `10.0.2.2` is the emulator's host-loopback alias — no extra setup.
  This is the `HS_API_BASE` default.
- Physical device over USB: `adb reverse tcp:8080 tcp:8080`, then
  `--dart-define=HS_API_BASE=http://127.0.0.1:8080`.
- Physical device over Wi-Fi (measured 2026-11-03, SM-G977N / Android
  12): bind the API to the PC's LAN address (`--bind 192.168.0.7`,
  port 8080), then build with
  `--dart-define=HS_API_BASE=http://192.168.0.7:8080`. dart:io
  HttpClient does not go through Android's Java-layer cleartext
  policy, so plain `http://` to a LAN IP literal worked with **no**
  `network_security_config` / `usesCleartextTraffic` change — every
  endpoint returned 200 from the physical device. This path is
  **plaintext and unauthenticated** (the API has no auth, §5): it is
  an accepted risk for a trusted home Wi-Fi only, and any device on
  the same LAN can read the records. The PC's address is DHCP-leased:
  reserve it at the router or rebuild the APK when it changes —
  `HS_API_BASE` is compile-time only (no runtime setting).
- `https://` origins work as-is: dart:io HttpClient performs standard
  certificate validation (no `badCertificateCallback` override — the
  default trust evaluation stays untouched). Plain `http://` local
  development paths behave exactly as before.

## Basic Auth & HTTPS (Northflank front)

The API server itself has no authentication (`tools/api/README.md` §5);
remote reachability comes from a deployment front (Northflank HTTPS with
Basic Auth), which the app supports as follows:

- **Every API request** carries `Authorization: Basic
  <base64(user:password)>` once a credential pair is armed; with no pair
  stored, requests go out header-less and behave as before.
- **Storage**: the pair is entered once via the re-entry dialog and kept
  only in flutter_secure_storage (Android: Keystore-wrapped RSA-OAEP key,
  AES-GCM data). There is no `shared_preferences` path for credentials,
  and the values are never logged (`Credentials.toString` masks them).
- **401 handling**: the first 401 in a resync pass opens the credential
  dialog (whether the stored pair was refused or never existed). A
  submitted pair is saved and the pass retries **exactly once**;
  cancelling — or a failing prompt/storage write — leaves the visible
  "인증 필요 (401)" error states with no further auth retries. The
  existing bounded resync backoff is unchanged.
- The stored pair is used for whatever origin `HS_API_BASE` points at;
  pointing the app at a different (unauthenticated) origin, such as the
  local loopback API, still works — no 401, no dialog, no header needed.

## Screens — recorded facts only

- **Market View** — the single `GET /mobile/market-view` projection,
  exactly three market elements: 상승 TOP 10, 하락 TOP 10, and the
  retained 최근 후보 이벤트 (≤100, server order oldest→newest). A run
  header (`session_date`, `as_of`) and `status.by_data_quality` render
  verbatim (INCOMPLETE/UNKNOWN stay visible, never flattened to normal),
  and per-item `data_quality` shows on every row. The server projection
  is authoritative: the app never recomputes ranks or filters events
  into candidates, and `runs_present:false` / `run:null` renders as
  "기록 없음" — never zero-filled rows. Market prices are not served by
  the API and are not shown.
- **Event Detail** — the selected fact verbatim (canonical field order),
  its `evidence_ref` (근거) highlighted, and its delivery records.
  Reached from Market View rows (top-10 / history) and notification
  taps.

Loading (skeleton), "기록 없음", and offline/error states are rendered
as distinct UI states — the app never renders absence as success.

## Resync policy

A single fetch of `/mobile/market-view` (plus the on-demand
`/events/{event_id}` drill-down when a row or notification is selected)
runs on startup and on foreground resume, with a restrained backoff
(1s, 2s, capped by 3 attempts) that ends in a visible error state —
never an infinite spinner. This is also the recovery path for missed
messages: firebase_messaging 17.x removed the `onDeletedMessages` Dart
callback upstream, so FCM queue-discard recovery is guaranteed by the
resume resync instead of a callback (documented delta, not a hidden
behavior).

## Push flow (notification+data only)

The dispatcher (tools/notify) sends **notification+data** messages with
data `{event_id, event_type, severity}`. Data-only payloads plus local
notification re-synthesis are forbidden by design.

- **Permission**: one automatic ask on the first run; the ask count,
  timestamp and decision are persisted (Android 13+ cannot distinguish
  "denied" from "asked before", so the app's own recorded history is the
  only fact). Denied keeps the app fully functional and shows 푸시
  비활성 with an explicit "다시 요청" button — no silent re-nagging.
- **Foreground**: the OS does not display notification messages while
  the app is foregrounded; the app shows an in-app banner (chosen,
  documented policy). Banners dedup by `event_id` (a bounded history of
  64 shown ids — a burst of repeated deliveries for one event shows one
  banner), and a new banner replaces the current one instead of queueing
  behind it. The dispatcher's `min_severity` policy already bounds what
  reaches the phone (default INFO; the operator can set HIGH/CRITICAL
  server-side), so banner volume has two bounds.
- **Background tap** → `onMessageOpenedApp` → data `event_id` → Event
  Detail tab with a `/events/{id}` fetch. **Cold start** →
  `getInitialMessage()`, same routing. Payloads without a usable
  `event_id` are not routed (nothing is invented).
- **Terminated state display** is the OS notification itself — the
  official path.

### Firebase handoff checklist (updated for PR-7)

The Firebase project is wired (steps 1–4 are done): `flutterfire
configure` generated `lib/firebase_options.dart` and the Gradle plugin
markers, and `defaultPushService()` composes `const FcmPushService()`.
`FcmPushService` still fails closed (throws `StateError`) on any device
where `Firebase.initializeApp` has not run. Remaining live steps:

1. **google-services.json** — place it at
   `android/app/google-services.json` (Firebase console, package
   `com.hongscanner.hongscanner`). Never commit it — the path is
   gitignored (`android/.gitignore`). CI restores it on every run from
   the `GOOGLE_SERVICES_JSON` repo secret (`gh secret set
   GOOGLE_SERVICES_JSON < mobile/android/app/google-services.json`);
   without the secret the mobile workflow fails closed.
2. **Gradle plugin** — `flutterfire configure` (step 3) inserts the
   google-services Gradle plugin automatically and idempotently, inside
   the `START/END: FlutterFire Configuration` markers:
   `id("com.google.gms.google-services") version("…") apply false` in
   `android/settings.gradle.kts` and the plugin id in
   `android/app/build.gradle.kts`. Declare it manually only if the CLI
   patch fails — and then with `version("…") apply false`. A build that
   refuses to run because the plugin is applied before the JSON exists
   is intended fail-closed behavior, not a bug.
3. **firebase_options.dart** — run `flutterfire configure`, then call
   `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`
   before any FCM usage.
4. **Swap the push service** — replace `defaultPushService()` /
   `defaultAppStore()` in `lib/main.dart` with `const FcmPushService()`.
   It still fails closed (throws `StateError`) until step 3 succeeds.
5. **Token registration** — the app has NO write path to the server.
   `FcmPushService` registers the app instance (`register()`) and the
   Market View push card displays the delivered Firebase Installation ID
   (`onRegistered`) in full, selectable for copying — no truncation.
   The operator registers it with the server-side
   `tools/notify/notify_register.py` CLI via `--token-file` (or stdin):
   bearer-authenticated, the token value never touches argv or logs and
   is stored outside the repo. The identifier the card shows — the FID
   after the token-API migration — is exactly what gets registered.
   The card also shows the ask history so the operator can see why push
   is active or disabled.
6. **Token API migration** — DONE (code-only; no Firebase project
   needed). firebase_messaging 17.x deprecates `getToken()` /
   `onTokenRefresh` in favor of the FID registration APIs added in
   17.0.0 (flutterfire #18482): `register()` (`Future<void>`, initiates
   registration), `onRegistered` (`Stream<String>` of Firebase
   Installation IDs — the direct-send target), plus
   `unregister()`/`onUnregistered`. Verified against the pinned
   firebase_messaging 17.0.1 sources (`lib/src/messaging.dart`,
   `@Deprecated('Use register() and onRegistered instead.')`).
   `FcmPushService` now exposes `register()`/`onRegistered` through the
   `PushTokenSource` capability interface in `lib/services/push_service.dart`
   (same fail-closed guards: unwired access throws `StateError`); the
   deprecated calls and their suppressed lint are gone.
   Android opt-in: FID registration requires
   `<meta-data android:name="firebase_messaging_installation_id_enabled"
   android:value="true"/>` inside `<application>` in
   `android/app/src/main/AndroidManifest.xml` (added; without it
   `register()` throws `IllegalStateException` and no FID events are
   delivered —
   `https://firebase.google.com/docs/cloud-messaging/android/get-started`).
   Server contract: the FCM HTTP v1 `Message.token` field accepts a FID
   during the transition period, but the field is deprecated in favor
   of the `fid` field
   (`https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages`);
   `tools/notify/notify_fcm.py` currently sends `message.token` — that
   still reaches FID targets, and migrating the sender to `fid` is a
   separate server-side task. Handoff-time verification: register the
   displayed FID, dispatch a test message to it, and observe delivery
   plus tap routing (step 7).
7. **Real-device receipt drill** — dispatch a synthetic event, observe
   notification tap → Event Detail on a physical device (or via adb).
   Prerequisites: the device has Google Play services (GMS), the
   notification permission is granted (Android 13+ runtime prompt), and
   Play Protect may warn on a sideload install (allow manually).
   Official guide:
   `https://firebase.google.com/docs/cloud-messaging/android/client`.
   This is a GATES-evidence item, not a CI check.

## Release signing (fail-closed)

The keystore lives **outside the repository** and must never be
committed. The Gradle config has no quiet fallback: without signing
config a release build **refuses to run** instead of shipping
debug-signed.

```sh
# 1. Create the keystore outside the repo (once).
mkdir -p ~/.local/share/hongscanner/mobile
keytool -genkeypair -v -keystore ~/.local/share/hongscanner/mobile/release.keystore \
  -alias hongscanner -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Hong Scanner, OU=Personal, O=HongScanner, L=Seoul, C=KR"

# 2. Create mobile/android/key.properties (gitignored) — absolute path.
#    storeFile=/home/<user>/.local/share/hongscanner/mobile/release.keystore
#    storePassword=...
#    keyAlias=hongscanner
#    keyPassword=...

# 3. Build the signed release APK.
flutter build apk --release   # → mobile/build/app/outputs/flutter-apk/app-release.apk
```

`mobile/.gitignore` blocks `key.properties`, `*.keystore`, `*.jks`.
APK artifacts are gitignored (`/build/`) and never committed.

## Tests & CI

- `flutter test` — the mobile suite: API client against fake transports
  (market-view contract shapes, null/absence semantics, error
  classification), fixture-driven widget tests for the market view (the
  three elements, rank-1 row, history drill-down into Event Detail,
  honest-absence and offline states), permission flow (first-run ask
  once, denial persistence, manual re-ask, unwired), stub-message tap
  routing (cold start, background tap, foreground banner, bad payloads),
  and resync (single-fetch backoff, recovery, lifecycle resume,
  pull-to-refresh).
- `flutter analyze` — clean. NOTE: in this repo's non-ASCII checkout path
  `flutter analyze` crashes (LSP tool bug, exit 255); run it from an
  ASCII-path copy (`rsync -a --exclude .git mobile/ /tmp/hs-mobile-ascii/`).
  CI runs on ASCII paths and is unaffected. `flutter test` / `flutter
  build` work in the non-ASCII path.
- `.github/workflows/mobile.yml` — runs on `mobile/**` or workflow
  changes only: analyze + test + `flutter build apk --debug` (no
  keystore in CI by design), prints `MOBILE SUITE PASSED`.
  **It is not a required check**: the merge authority stays the ruleset's
  required `ci` check plus the `ALL CONTRACT SUITES PASSED` gate marker
  (AGENTS.md §2.1). The main agent reads the mobile run's marker from the
  run log before merging; a missing run is UNKNOWN, not SUCCESS.
- Local APK builds need the gitignored `google-services.json` next to
  `mobile/android/app/` (the google-services Gradle plugin **is** applied
  and fails the build without it — `processDebugGoogleServices`). CI
  restores it from the `GOOGLE_SERVICES_JSON` secret; a bare worktree or
  an ASCII-path scratch copy does not carry untracked files, so copy the
  real one in before building (measured 2026-11-03: first build exit 1
  "File google-services.json is missing", rebuild after copying it from
  the main checkout: exit 0).

## Local toolchain used for this scaffold

- Flutter SDK: `~/sdk/flutter` (stable 3.47.9)
- Android SDK: `~/sdk/android-sdk` (platform-tools, build-tools;34.0.0,
  platforms;android-34/35/36)
- JDK: OpenJDK 21
