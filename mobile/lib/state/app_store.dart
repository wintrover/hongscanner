import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_models.dart';
import '../api/credentials.dart';
import '../app_routes.dart';
import '../services/credential_store.dart';
import '../services/push_permission.dart';
import '../services/push_service.dart';

/// Per-section load state. Phases are exhaustive and honest: `loading` is
/// a real fetch in flight, `error` keeps the failure reason (including
/// whether it looks like offline), and `loaded` with null data means the
/// API answered "no record" — never rendered as success-with-content.
enum LoadPhase { idle, loading, loaded, error }

class Section<T> {
  const Section({
    this.phase = LoadPhase.idle,
    this.value,
    this.errorMessage,
    this.offline = false,
  });

  const Section.loading() : this(phase: LoadPhase.loading);

  const Section.loaded(T value) : this(phase: LoadPhase.loaded, value: value);

  const Section.error(String message, {bool offline = false})
      : this(phase: LoadPhase.error, errorMessage: message, offline: offline);

  final LoadPhase phase;
  final T? value;
  final String? errorMessage;
  final bool offline;

  bool get hasProblem => phase == LoadPhase.error;
}

/// UI-visible push state, derived from the service readiness plus the
/// persisted permission ledger — never from assumptions.
class PushUiState {
  const PushUiState({
    required this.phase,
    this.askedCount = 0,
    this.lastAskedAt,
    this.lastResponse,
    this.token,
    this.tokenError,
    this.notice,
  });

  final PushPhase phase;
  final int askedCount;
  final DateTime? lastAskedAt;
  final PushPermissionDecision? lastResponse;
  final String? token;
  final String? tokenError;

  /// A push-flow problem that is neither a decision nor a token issue —
  /// e.g. the platform raised an error during the permission ask.
  final String? notice;

  PushUiState copyWith({
    PushPhase? phase,
    int? askedCount,
    DateTime? lastAskedAt,
    PushPermissionDecision? lastResponse,
    String? token,
    String? tokenError,
    String? notice,
    bool clearToken = false,
    bool clearTokenError = false,
    bool clearLastAskedAt = false,
    bool clearLastResponse = false,
    bool clearNotice = false,
  }) {
    return PushUiState(
      phase: phase ?? this.phase,
      askedCount: askedCount ?? this.askedCount,
      lastAskedAt: clearLastAskedAt ? null : (lastAskedAt ?? this.lastAskedAt),
      lastResponse:
          clearLastResponse ? null : (lastResponse ?? this.lastResponse),
      token: clearToken ? null : (token ?? this.token),
      tokenError: clearTokenError ? null : (tokenError ?? this.tokenError),
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}

/// Central app state: the market-view projection, event selection/routing
/// (the detail route, pushed through the global navigator key), push
/// permission flow and resync scheduling.
///
/// Honest by contract: this store never synthesizes content. The
/// projection shows exactly what the API recorded; missing records stay
/// "기록 없음", offline stays "오프라인", and retries are bounded with a
/// restrained backoff so a dead server ends in a visible error state,
/// not an eternal spinner.
class AppStore extends ChangeNotifier {
  AppStore({
    required ApiClient apiClient,
    required PushService pushService,
    KeyValueStore? keyValueStore,
    CredentialStore? credentialStore,
    Future<void> Function(Duration delay)? delay,
    DateTime Function()? now,
    this._maxSyncAttempts = 3,
    this._backoffBase = const Duration(seconds: 1),
  })  : _api = apiClient,
        _push = pushService,
        _ledger = PushPermissionLedger(store: keyValueStore),
        _credentialStore = credentialStore ?? SecureCredentialStore(),
        _delay = delay ?? _defaultDelay,
        _now = now ?? DateTime.now;

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);

  final ApiClient _api;
  final PushService _push;
  final PushPermissionLedger _ledger;
  final CredentialStore _credentialStore;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;
  final int _maxSyncAttempts;
  final Duration _backoffBase;

  bool _bootstrapped = false;
  bool _syncing = false;
  bool _disposed = false;

  /// Set when any fetch in the current sync pass ended 401 — the signal
  /// for the one re-entry prompt per pass.
  bool _sawUnauthorized = false;

  /// Whether the 401 re-entry prompt already ran in the current resync —
  /// one prompt, one retry, never a loop.
  bool _authPromptShown = false;

  /// Set when reading the stored credentials failed (platform error,
  /// corrupted storage). Fail-closed: treated exactly like "no stored
  /// credentials" — the 401 path will ask for re-entry. Never carries
  /// credential values.
  Object? credentialLoadError;

  Section<MarketViewResponse> marketView = const Section();

  String? selectedEventId;
  Section<EventDetailResponse> eventDetail = const Section();

  /// Shell tab index: 0 = 후보 (top 10 cards), 1 = 히스토리 (candidate
  /// events). Tab switches never refetch — both tabs read the single
  /// [marketView] section.
  int tabIndex = 0;

  /// Event id routed before the navigator existed (a cold-start tap that
  /// landed ahead of the app's first frame): the shell's post-frame
  /// callback turns it into the detail route via [flushPendingEvent].
  String? pendingEventId;

  PushUiState pushState = const PushUiState(phase: PushPhase.unwired);

  /// True while a sync pass (including its bounded retries) is running.
  bool get syncing => _syncing;

  /// Sync passes started since construction — a small observable counter
  /// tests use to prove resync triggers fired.
  int syncCount = 0;

  /// Backoff durations the current/last sync requested — observable
  /// proof that retries back off instead of hammering.
  final List<Duration> recordedBackoffs = <Duration>[];

  StreamSubscription<PushMessage>? _tapSub;
  StreamSubscription<PushMessage>? _foregroundSub;
  StreamSubscription<String>? _fidSub;
  void Function(PushMessage message)? onForegroundMessage;

  /// The 401 re-entry path, wired by the shell: shows the credential
  /// dialog, persists what the operator submitted, and answers whether
  /// the failed pass may be retried once. Absent (null) = no dialog path
  /// wired; a 401 then just stays a visible error.
  Future<bool> Function()? onUnauthorized;

  // ---- bootstrap --------------------------------------------------------

  /// One-time startup: credential load, permission flow, push wiring,
  /// first sync.
  ///
  /// Auto-ask policy: the app asks exactly once, on the first run
  /// (ledger says never asked). Denied stays denied until the operator
  /// re-asks from the Overview card — Android 13+ makes silent re-asks
  /// both nagging and unverifiable. [onUnauthorized] is the 401 re-entry
  /// path (credential dialog); see [resync] for the one-prompt-one-retry
  /// contract.
  Future<void> bootstrap({
    void Function(PushMessage message)? onForegroundMessage,
    Future<bool> Function()? onUnauthorized,
  }) async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    this.onForegroundMessage = onForegroundMessage;
    this.onUnauthorized = onUnauthorized;
    await _loadCredentials();
    await _initPushState();
    await resync();
  }

  /// Arms the API client with the stored credential pair, if one exists.
  /// A read failure is fail-closed: recorded in [credentialLoadError] and
  /// treated as "no stored credentials" — the first 401 will prompt for
  /// re-entry instead of the failure being silently swallowed.
  Future<void> _loadCredentials() async {
    Credentials? credentials;
    try {
      credentials = await _credentialStore.load();
    } on Object catch (e) {
      credentialLoadError = e;
    }
    if (credentials != null) _api.authCredentials = credentials;
  }

  /// Persists re-entered credentials to the secure store and arms the API
  /// client with them. The 401 dialog's submit path calls this before the
  /// single retry. Storage failures propagate — the caller surfaces no
  /// fake success and the visible 401 states remain.
  Future<void> saveCredentials(Credentials credentials) async {
    await _credentialStore.save(credentials);
    _api.authCredentials = credentials;
  }

  Future<void> _initPushState() async {
    if (!_push.isReady) {
      pushState = const PushUiState(phase: PushPhase.unwired);
      notifyListeners();
      return;
    }
    final record = await _ledger.load();
    final phase = switch (record.lastResponse) {
      PushPermissionDecision.granted => PushPhase.granted,
      PushPermissionDecision.denied => PushPhase.denied,
      PushPermissionDecision.provisional => PushPhase.provisional,
      null =>
        record.neverAsked ? PushPhase.notAsked : PushPhase.unknown,
    };
    pushState = PushUiState(
      phase: phase,
      askedCount: record.askedCount,
      lastAskedAt: record.lastAskedAt,
      lastResponse: record.lastResponse,
    );
    notifyListeners();
    if (record.neverAsked) {
      await requestPushPermission();
    }
    await _wireTokenSource();
    _wirePushRouting();
  }

  Future<void> requestPushPermission() async {
    if (!_push.isReady) return;
    pushState = pushState.copyWith(phase: PushPhase.asking);
    notifyListeners();
    final PushPermissionDecision? decision;
    try {
      decision = await _push.requestPermission();
    } on Object catch (e) {
      // The ask failed before any recorded answer exists: honest unknown,
      // with the error surfaced. Not recorded as a decision it never got.
      // StateError/PlatformException 모두 여기서 잡는다 — 부트스트랩이
      // 죽는 대신 UI가 "권한 상태 미확정"을 보여준다.
      await _ledger.recordAsk(at: _now());
      final record = await _ledger.load();
      pushState = PushUiState(
        phase: PushPhase.unknown,
        askedCount: record.askedCount,
        lastAskedAt: record.lastAskedAt,
        lastResponse: record.lastResponse,
        token: pushState.token,
        notice: '권한 요청 실패: $e',
      );
      notifyListeners();
      return;
    }
    if (decision == null) {
      // "Nothing was asked" from a service that reported ready — do not
      // invent a decision; surface it as unknown.
      pushState = pushState.copyWith(phase: PushPhase.unknown);
      notifyListeners();
      return;
    }
    await _ledger.recordAsk(at: _now(), response: decision);
    final record = await _ledger.load();
    pushState = PushUiState(
      phase: switch (decision) {
        PushPermissionDecision.granted => PushPhase.granted,
        PushPermissionDecision.denied => PushPhase.denied,
        PushPermissionDecision.provisional => PushPhase.provisional,
      },
      askedCount: record.askedCount,
      lastAskedAt: record.lastAskedAt,
      lastResponse: record.lastResponse,
      token: pushState.token,
    );
    notifyListeners();
  }

  /// Wires the token-registration flow (firebase_messaging 17.x FID
  /// APIs). Subscribes [PushTokenSource.onRegistered] *before* calling
  /// [PushTokenSource.register] so the delivered FID cannot race the
  /// listener, and records exactly what the source delivered: no FID
  /// means no recorded token, never a fabricated one. The identifier is
  /// never displayed — it is logged once (logcat) for the operator to
  /// register with the server CLI.
  Future<void> _wireTokenSource() async {
    if (!_push.isReady) {
      pushState = pushState.copyWith(
          tokenError: '푸시 미연결 — Firebase 미설정 (mobile/README.md 참조)');
      notifyListeners();
      return;
    }
    final tokenSource =
        _push is PushTokenSource ? _push as PushTokenSource : null;
    if (tokenSource == null) return;
    _fidSub = tokenSource.onRegistered.listen(
      (fid) {
        pushState = pushState.copyWith(token: fid, clearTokenError: true);
        // Operator path: the FID never renders on screen. It is logged
        // here once for `adb logcat -s flutter` pickup and registered
        // server-side with tools/notify/register (the workflow the token
        // card used to document).
        debugPrint('[HS-OPS] fcm registration id: $fid');
        notifyListeners();
      },
      onError: (Object e) {
        // Keep any previously delivered FID; the error is surfaced, not
        // swallowed and not mistaken for a token.
        pushState = pushState.copyWith(tokenError: '토큰 획득 실패: $e');
        notifyListeners();
      },
    );
    try {
      await tokenSource.register();
    } on Object catch (e) {
      pushState = pushState.copyWith(tokenError: '토큰 획득 실패: $e');
      notifyListeners();
    }
  }

  void _wirePushRouting() {
    final source = _push is PushMessageSource ? _push as PushMessageSource : null;
    if (source == null) return;
    // Cold start: the notification that launched the app routes to its
    // event detail. Messages without a usable event_id are not routed —
    // inventing a target would be worse than ignoring one bad payload.
    source.initialMessage().then((message) {
      final eventId = message?.eventId;
      if (eventId != null) openEvent(eventId);
    });
    _tapSub = source.tapMessages.listen((message) {
      final eventId = message.eventId;
      if (eventId != null) openEvent(eventId);
    });
    _foregroundSub = source.foregroundMessages.listen((message) {
      onForegroundMessage?.call(message);
    });
  }

  // ---- routing ----------------------------------------------------------

  void selectTab(int index) {
    tabIndex = index;
    notifyListeners();
  }

  /// Routing target for notification taps and list selections: selects the
  /// event, fetches the recorded fact, and shows the detail route (a
  /// mounted detail route updates in place). When the navigator does not
  /// exist yet — a tap that lands before the app's first frame — the id is
  /// kept in [pendingEventId] for the shell's post-frame flush; the
  /// selection and fetch still run immediately either way.
  Future<void> openEvent(String eventId) async {
    selectedEventId = eventId;
    eventDetail = const Section.loading();
    pendingEventId = showEventDetail() ? null : eventId;
    notifyListeners();
    try {
      final detail = await _api.fetchEvent(eventId);
      if (selectedEventId != eventId) return; // superseded by a newer selection
      eventDetail = Section.loaded(detail);
    } on ApiClientException catch (e) {
      if (selectedEventId != eventId) return;
      eventDetail = Section.error(_describe(e), offline: e.isConnectivityProblem);
    }
    notifyListeners();
  }

  /// First-frame flush: turns a pre-frame routed event into the detail
  /// route. [openEvent] already ran the selection and fetch — this only
  /// performs the deferred screen transition.
  void flushPendingEvent() {
    final pending = pendingEventId;
    if (pending == null) return;
    if (showEventDetail()) pendingEventId = null;
  }

  // ---- sync -------------------------------------------------------------

  /// Startup, foreground resume, and FCM message-discard recovery all land
  /// here: one full refresh of the market-view projection, with bounded
  /// backoff on failure.
  ///
  /// 401 contract (Basic Auth): when a pass hit a 401 and the re-entry
  /// callback is wired, the prompt runs once per resync and a submission
  /// triggers exactly one retry pass. Cancelling or a failing prompt ends
  /// in the visible 401 error states — no further auth retries, no
  /// backoff against the auth failure beyond the pass loop that already
  /// exists.
  Future<void> resync() async {
    if (_syncing) return;
    _syncing = true;
    notifyListeners();
    try {
      syncCount += 1;
      _authPromptShown = false;
      for (var attempt = 1; attempt <= _maxSyncAttempts; attempt++) {
        _sawUnauthorized = false;
        var ok = await _fetchOnce();
        if (!ok &&
            _sawUnauthorized &&
            !_authPromptShown &&
            onUnauthorized != null) {
          _authPromptShown = true;
          bool submitted;
          try {
            submitted = await onUnauthorized!();
          } on Object {
            // A prompt/storage failure is not a retry trigger: the
            // visible 401 states stay, fail-closed.
            submitted = false;
          }
          if (submitted) ok = await _fetchOnce(); // the single retry
        }
        if (ok) break;
        if (attempt == _maxSyncAttempts) break;
        final backoff = _backoffBase * (1 << (attempt - 1));
        recordedBackoffs.add(backoff);
        await _delay(backoff);
      }
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// One pass: the single `/mobile/market-view` projection fetch. Returns
  /// true when nothing failed.
  Future<bool> _fetchOnce() async {
    marketView = const Section<MarketViewResponse>.loading();
    try {
      marketView = Section.loaded(await _api.fetchMarketView());
    } on ApiClientException catch (e) {
      if (e.statusCode == 401) _sawUnauthorized = true;
      marketView =
          Section.error(_describe(e), offline: e.isConnectivityProblem);
      notifyListeners();
      return false;
    }
    notifyListeners();
    return true;
  }

  String _describe(ApiClientException e) {
    if (e.isConnectivityProblem) return '서버에 연결할 수 없음 (${e.message})';
    if (e.code == ApiErrorCode.http) {
      if (e.statusCode == 401) {
        return '인증 필요 (401) — 자격증명이 없거나 거부됨';
      }
      return switch (e.serverCode) {
        'not_found' => '기록에 없음 (404 not_found)',
        'data_fault' => '기록 파일 불량 (500 data_fault)',
        _ => '서버 오류 (${e.statusCode ?? '?'} ${e.serverCode ?? ''})',
      };
    }
    return '응답 해석 실패 (${e.message})';
  }

  @override
  void dispose() {
    _disposed = true;
    _tapSub?.cancel();
    _foregroundSub?.cancel();
    _fidSub?.cancel();
    _api.close();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}
