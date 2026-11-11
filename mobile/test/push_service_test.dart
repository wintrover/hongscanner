import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/main.dart';
import 'package:hongscanner/services/fcm_push_service.dart';
import 'package:hongscanner/services/market_alert_channel.dart';
import 'package:hongscanner/services/noop_push_service.dart';
import 'package:hongscanner/services/push_permission.dart';
import 'package:hongscanner/services/push_service.dart';

import 'test_kit.dart';

void main() {
  group('NoopPushService', () {
    test(
        'is a no-op: not ready, no token registration, permission answers nothing-was-asked',
        () async {
      final PushService service = const NoopPushService();

      expect(service.isReady, isFalse);
      expect(await service.requestPermission(), isNull);
    });

    test('does not implement PushMessageSource or PushTokenSource (no fakes)',
        () {
      expect(const NoopPushService(), isNot(isA<PushMessageSource>()));
      expect(const NoopPushService(), isNot(isA<PushTokenSource>()));
    });
  });

  group('FcmPushService', () {
    test('instantiates without any Firebase initialization', () {
      const PushService service = FcmPushService();

      expect(service, isA<FcmPushService>());
      expect(service.isReady, isFalse, reason: 'Firebase.apps is empty');
    });

    test('fails closed when used before Firebase.initializeApp', () {
      const FcmPushService service = FcmPushService();

      expect(service, isA<PushTokenSource>(),
          reason:
              'token registration uses the 17.x register()/onRegistered APIs');
      expect(() => service.register(), throwsStateError);
      expect(() => service.onRegistered, throwsStateError);
      expect(() => service.requestPermission(), throwsStateError);
    });

    test('message source fails closed before initialization too', () {
      const FcmPushService service = FcmPushService();

      expect(() => service.foregroundMessages, throwsStateError);
      expect(() => service.tapMessages, throwsStateError);
      expect(() => service.initialMessage(), throwsStateError);
    });
  });

  test('default push service is FCM and fails closed until Firebase is wired', () {
    final PushService service = defaultPushService();

    expect(service, isA<FcmPushService>());
    expect(service.isReady, isFalse);
    final fcm = service as FcmPushService;
    expect(() => fcm.register(), throwsStateError);
    expect(() => fcm.tapMessages, throwsStateError);
  });

  test('default app store composes the FCM service (unwired without Firebase init)', () {
    final store = defaultAppStore();
    expect(store.pushState.phase, PushPhase.unwired);
    store.dispose();
  });

  group('MarketAlertChannel', () {
    test('fail-closed without a platform end: no post, no pending tap',
        () async {
      // No mock installed: the channel has no platform end in the test
      // environment (and none on non-Android platforms) — every call
      // degrades honestly instead of throwing or inventing a result.
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MarketAlertChannel();
      expect(
        await channel.postNotification(
            eventId: evUpEnterId, title: 't', body: 'b'),
        isFalse,
        reason: 'the caller falls back to the in-app banner',
      );
      expect(await channel.getPendingTap(), isNull,
          reason: 'a null never invents a route');
    });

    test('isMarketAlert keys on the TOP10 vocabulary and complete server text',
        () {
      PushMessage typed(String type, {String? title = 't', String? body = 'b'}) =>
          PushMessage({
            'event_id': evUpEnterId,
            'event_type': type,
          }, notificationTitle: title, notificationBody: body);

      expect(MarketAlertChannel.isMarketAlert(typed('TOP10_ENTERED')), isTrue);
      expect(MarketAlertChannel.isMarketAlert(typed('TOP10_EXITED')), isTrue);
      expect(MarketAlertChannel.isMarketAlert(typed('RANK_CHANGED')), isTrue);
      expect(MarketAlertChannel.isMarketAlert(typed('CANDIDATE_ENTERED')),
          isFalse,
          reason: 'non-market types keep the in-app banner policy');
      // Market type without the server-assembled text: not postable — the
      // app never re-assembles text the server did not send.
      expect(MarketAlertChannel.isMarketAlert(typed('RANK_CHANGED', body: null)),
          isFalse);
      // No usable event id: nothing to post or route.
      expect(
        MarketAlertChannel.isMarketAlert(PushMessage({
          'event_type': 'TOP10_ENTERED',
        }, notificationTitle: 't', notificationBody: 'b')),
        isFalse,
      );
    });
  });

  group('PushPermissionLedger', () {
    test('round-trips ask history through any KeyValueStore', () async {
      final kv = MemoryKeyValueStore();
      final ledger = PushPermissionLedger(store: kv);

      final before = await ledger.load();
      expect(before.neverAsked, isTrue);
      expect(before.askedCount, 0);

      await ledger.recordAsk(
        at: DateTime(2026, 11, 2, 9),
        response: PushPermissionDecision.denied,
      );
      await ledger.recordAsk(at: DateTime(2026, 11, 3, 9));

      final after = await ledger.load();
      expect(after.askedCount, 2);
      expect(after.lastResponse, PushPermissionDecision.denied,
          reason: 'an ask without a recorded answer keeps the previous one');
      expect(after.lastAskedAt, DateTime(2026, 11, 3, 9));
      expect(after.neverAsked, isFalse);
    });

    test('unknown response names stay null instead of crashing', () async {
      final kv = MemoryKeyValueStore();
      await kv.write('hs.push.last.response', 'maybe');
      final record = await PushPermissionLedger(store: kv).load();
      expect(record.lastResponse, isNull);
    });
  });
}
