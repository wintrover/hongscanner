import 'dart:async';
import 'dart:convert';

import 'package:hongscanner/api/api_client.dart';
import 'package:hongscanner/services/credential_store.dart';
import 'package:hongscanner/services/noop_push_service.dart';
import 'package:hongscanner/services/push_permission.dart';
import 'package:hongscanner/services/push_service.dart';
import 'package:hongscanner/state/app_store.dart';

/// Synthetic recorded-fact fixtures for the mobile suite. Shapes mirror
/// tools/api/README.md and the real fixture in
/// fixtures/events/valid_event.hcj.jsonl — no real market data anywhere
/// (repo rule). Event ids are invented 64-hex strings.

const String evUpEnterId =
    'a5e99fe72be4f3b8ef4cda2ad8a14a60da8ffadccba2b33fa885831604aef85f';
const String evDownEnterId =
    'b23d1c4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e';
const String evUpUpdateId =
    'c3aa2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e1f2';
const String evDownExitId =
    'e5cc3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e';

const String fixtureSession = 'smoke-2026-11-02-885b009';

Map<String, Object?> fixtureEvent(
  String eventId, {
  required String eventType,
  required String observedAt,
  String? direction,
  int? rank,
  String? symbol,
  String severity = 'INFO',
  String dataQuality = 'OBSERVING',
}) =>
    {
      'data_quality': dataQuality,
      'direction': ?direction,
      'event_id': eventId,
      'event_type': eventType,
      'evidence_ref': 'ka10027:stex_tp=1:sort_tp=1',
      'observed_at': observedAt,
      'rank': ?rank,
      'rule_id': 'candidate-enter-v1',
      'rule_version': 1,
      'session_id': '2026-11-02',
      'severity': severity,
      'symbol': ?symbol,
    };

final Map<String, Object?> evUpEnter = fixtureEvent(evUpEnterId,
    eventType: 'CANDIDATE_ENTERED',
    observedAt: '2026-11-02T09:00:05+09:00',
    direction: 'UP',
    rank: 1,
    symbol: '005930');

final Map<String, Object?> evDownEnter = fixtureEvent(evDownEnterId,
    eventType: 'CANDIDATE_ENTERED',
    observedAt: '2026-11-02T09:01:12+09:00',
    direction: 'DOWN',
    rank: 1,
    symbol: '000660');

final Map<String, Object?> evUpUpdate = fixtureEvent(evUpUpdateId,
    eventType: 'CANDIDATE_UPDATED',
    observedAt: '2026-11-02T09:02:41+09:00',
    direction: 'UP',
    rank: 2,
    symbol: '005930',
    severity: 'HIGH');

final Map<String, Object?> evDownExit = fixtureEvent(evDownExitId,
    eventType: 'CANDIDATE_EXITED',
    observedAt: '2026-11-02T09:03:30+09:00',
    direction: 'DOWN',
    symbol: '000660',
    dataQuality: 'INCOMPLETE');

final List<Map<String, Object?>> fixtureLedgerEvents = [
  evUpEnter,
  evDownEnter,
  evUpUpdate,
  evDownExit,
];

final Map<String, Object?> fixtureDeliveryRecord = {
  'attempts': 1,
  'device_id': 'dev-1',
  'provider_message_id': 'projects/hs/messages/m-1',
  'state': 'ACCEPTED',
  'updated_at': '2026-11-02T09:00:06+09:00',
};

/// One `/mobile/market-view` item: exactly the frozen item fields. When
/// [rank] is null the key is present with a JSON null — the contract's
/// honest-absence shape for CANDIDATE_EXITED history items.
Map<String, Object?> fixtureMarketItem(
  String eventId, {
  required String eventType,
  required String observedAt,
  required String direction,
  int? rank,
  String symbol = '005930',
  String dataQuality = 'OBSERVING',
}) =>
    {
      'data_quality': dataQuality,
      'direction': direction,
      'event_id': eventId,
      'event_type': eventType,
      'observed_at': observedAt,
      'rank': rank,
      'symbol': symbol,
    };

/// `/mobile/market-view` fixture: the single bounded projection the phone
/// renders — rising/falling top 10 in ascending rank, the retained
/// candidate history (oldest→newest, rank null on the EXITED row), and
/// the run/as_of context. Same synthetic world as the ledger fixtures.
final Map<String, Object?> fixtureMarketView = {
  'as_of': '2026-11-02T15:30:58+09:00',
  'falling_top10': [
    fixtureMarketItem(evDownEnterId,
        eventType: 'CANDIDATE_ENTERED',
        observedAt: '2026-11-02T09:01:12+09:00',
        direction: 'DOWN',
        rank: 1,
        symbol: '000660'),
  ],
  'history': [
    fixtureMarketItem(evUpEnterId,
        eventType: 'CANDIDATE_ENTERED',
        observedAt: '2026-11-02T09:00:05+09:00',
        direction: 'UP',
        rank: 1,
        symbol: '005930'),
    fixtureMarketItem(evDownEnterId,
        eventType: 'CANDIDATE_ENTERED',
        observedAt: '2026-11-02T09:01:12+09:00',
        direction: 'DOWN',
        rank: 1,
        symbol: '000660'),
    fixtureMarketItem(evUpUpdateId,
        eventType: 'CANDIDATE_UPDATED',
        observedAt: '2026-11-02T09:02:41+09:00',
        direction: 'UP',
        rank: 2,
        symbol: '005930'),
    fixtureMarketItem(evDownExitId,
        eventType: 'CANDIDATE_EXITED',
        observedAt: '2026-11-02T09:03:30+09:00',
        direction: 'DOWN',
        rank: null,
        symbol: '000660',
        dataQuality: 'INCOMPLETE'),
  ],
  'latest': {
    'data_quality': 'INCOMPLETE',
    'event_id': evDownExitId,
    'event_type': 'CANDIDATE_EXITED',
    'observed_at': '2026-11-02T09:03:30+09:00',
  },
  'rising_top10': [
    fixtureMarketItem(evUpEnterId,
        eventType: 'CANDIDATE_ENTERED',
        observedAt: '2026-11-02T09:00:05+09:00',
        direction: 'UP',
        rank: 1,
        symbol: '005930'),
    fixtureMarketItem(evUpUpdateId,
        eventType: 'CANDIDATE_UPDATED',
        observedAt: '2026-11-02T09:02:41+09:00',
        direction: 'UP',
        rank: 2,
        symbol: '005930'),
  ],
  'run': {
    'session': fixtureSession,
    'session_date': '2026-11-02',
    'run_id': 'run-2026-11-02-1',
    'started_at': '2026-11-02T09:00:00+09:00',
  },
  'runs_present': true,
  'status': {
    'by_data_quality': {'INCOMPLETE': 1, 'OBSERVING': 3},
  },
};

/// HCJ-canonical encoding (keys codepoint-ascending, compact, trailing LF)
/// so fake responses have the byte shape the real server produces.
String canonicalJson(Object? o) {
  if (o is Map) {
    final keys = o.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonicalJson(o[k])}').join(',')}}';
  }
  if (o is List) return '[${o.map(canonicalJson).join(',')}]';
  if (o is String) return jsonEncode(o);
  if (o is num || o is bool || o == null) return '$o';
  throw ArgumentError.value(o, 'o', 'not canonical-JSON encodable');
}

class FakeTransport implements HttpTransport {
  /// Uri-only handler — the shape every pre-existing test closure uses.
  FakeTransport(Future<TransportResponse> Function(Uri uri) handler)
      : _handler = ((uri, [headers]) => handler(uri));

  /// Header-aware handler for auth tests: the closure sees the exact
  /// headers the client put on the wire.
  FakeTransport.withHeaders(
      Future<TransportResponse> Function(Uri uri,
              [Map<String, String>? headers])
          handler)
      : _handler = handler;

  final Future<TransportResponse> Function(Uri uri,
      [Map<String, String>? headers]) _handler;

  final List<Uri> requests = <Uri>[];

  /// The headers each recorded request carried, index-aligned with
  /// [requests] — how auth-header assertions observe the wire.
  final List<Map<String, String>?> headersSeen = <Map<String, String>?>[];
  bool closed = false;

  @override
  Future<TransportResponse> get(Uri uri,
      {Map<String, String>? headers}) async {
    requests.add(uri);
    headersSeen.add(headers);
    return _handler(uri, headers);
  }

  @override
  void close() {
    closed = true;
  }
}

TransportResponse okJson(Object body) => TransportResponse(
      statusCode: 200,
      body: utf8.encode('${canonicalJson(body)}\n'),
    );

TransportResponse errorJson(int status, String code, String message) =>
    TransportResponse(
      statusCode: status,
      body: utf8.encode('${canonicalJson({'error': {'code': code, 'message': message}})}\n'),
    );

/// Fake API: routes by path with the fixture payloads. `/mobile/market-view`
/// answers the projection fixture; `events/<id>` answers 404 for unknown
/// ids, mirroring the server contract.
FakeTransport fixtureTransport({Map<String, TransportResponse>? extra}) {
  final overrides = extra ?? const <String, TransportResponse>{};
  return FakeTransport((uri) async {
    final override = overrides[uri.path];
    if (override != null) return override;
    final path = uri.path;
    if (path.endsWith('/mobile/market-view')) return okJson(fixtureMarketView);
    if (path.contains('/events/')) {
      final id = path.split('/events/').last;
      final known = {
        evUpEnterId,
        evDownEnterId,
        evUpUpdateId,
        evDownExitId,
      };
      return known.contains(id)
          ? okJson({
              'delivery': id == evUpEnterId ? [fixtureDeliveryRecord] : [],
              'event': fixtureLedgerEvents.firstWhere((e) => e['event_id'] == id),
            })
          : errorJson(404, 'not_found', 'no such event id in the ledger');
    }
    return errorJson(404, 'not_found', 'unknown route');
  });
}

/// PushService fake for flow tests: records asks, returns the scripted
/// decision, and reports ready only when asked to.
class FakePushService implements PushService {
  FakePushService({
    this.ready = false,
    this.decision,
    this.throwOnAsk = false,
  });

  final bool ready;
  PushPermissionDecision? decision;
  final bool throwOnAsk;
  int askCount = 0;

  @override
  bool get isReady => ready;

  @override
  Future<PushPermissionDecision?> requestPermission() async {
    askCount += 1;
    if (throwOnAsk) throw StateError('platform error during ask');
    return decision;
  }
}

/// PushTokenSource fake mirroring the firebase_messaging 17.x
/// register()/onRegistered surface: register() emits the scripted FID on
/// the broadcast stream (as the plugin delivers the Firebase Installation
/// ID after registration), and a scripted registerError stands in for a
/// failed registration call.
class FakeTokenPushService extends FakePushService
    implements PushTokenSource {
  FakeTokenPushService({
    super.ready = true,
    super.decision = PushPermissionDecision.granted,
    this.fid,
    this.registerError,
  });

  final String? fid;
  final Object? registerError;
  int registerCount = 0;
  final registeredController = StreamController<String>.broadcast();

  @override
  Future<void> register() async {
    registerCount += 1;
    final error = registerError;
    if (error != null) throw error;
    final value = fid;
    if (value != null) registeredController.add(value);
  }

  @override
  Stream<String> get onRegistered => registeredController.stream;
}

/// PushMessageSource fake: stub streams driven by tests, mirroring the
/// firebase_messaging surface (initial/tap/foreground/deleted).
class FakeMessagePushService extends FakePushService
    implements PushMessageSource {
  FakeMessagePushService({
    super.ready = true,
    super.decision = PushPermissionDecision.granted,
    this.initial,
  });

  PushMessage? initial;
  final tapController = StreamController<PushMessage>.broadcast();
  final foregroundController = StreamController<PushMessage>.broadcast();

  @override
  Stream<PushMessage> get foregroundMessages => foregroundController.stream;

  @override
  Stream<PushMessage> get tapMessages => tapController.stream;

  @override
  Future<PushMessage?> initialMessage() async => initial;

  void disposeStreams() {
    tapController.close();
    foregroundController.close();
  }
}

/// Store factory with a zero-cost backoff clock so tests stay synchronous
/// and fast while still exercising the retry path. Credentials default to
/// the in-memory store so tests never touch a platform channel.
AppStore makeStore({
  required HttpTransport transport,
  PushService push = const NoopPushService(),
  KeyValueStore? kv,
  CredentialStore? credentialStore,
  List<Duration>? backoffs,
}) {
  return AppStore(
    apiClient: ApiClient(
        baseUrl: 'http://10.0.2.2:8080', transport: transport),
    pushService: push,
    keyValueStore: kv,
    credentialStore: credentialStore ?? MemoryCredentialStore(),
    delay: (d) async {
      backoffs?.add(d);
    },
    now: () => DateTime(2026, 11, 2, 9, 0, 0),
  );
}
