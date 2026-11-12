import 'package:firebase_messaging/firebase_messaging.dart';
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

  group('PushMessage digest parsing', () {
    test('messageFromRemote parses kind, event_ids and count', () {
      // The summary/digest wire shape: everything string-valued,
      // event_ids one comma-joined 64-hex list.
      final message = FcmPushService.messageFromRemote(RemoteMessage(
        data: {
          'kind': 'digest',
          'event_ids': '$evTopEnterId,$evRankChangeId,$evTopExitId',
          'count': '3',
        },
        notification: RemoteNotification(
          title: '홍스캐너 TOP10 순위 요약',
          body: '관측 그룹 요약',
        ),
      ));
      expect(message.kind, 'digest');
      expect(message.eventIds, [evTopEnterId, evRankChangeId, evTopExitId]);
      expect(message.count, 3);
      // A digest carries no single event_id: the cover list is the
      // routing, its first id the representative.
      expect(message.eventId, isNull);
      expect(message.representativeEventId, evTopEnterId);
      expect(message.notificationTitle, '홍스캐너 TOP10 순위 요약');
    });

    test('non-string or unparsable values degrade to null, never throw',
        () {
      final message = FcmPushService.messageFromRemote(RemoteMessage(data: {
        'kind': 7,
        'event_ids': '',
        'count': 'many',
      }));
      expect(message.kind, isNull);
      expect(message.eventIds, isNull);
      expect(message.count, isNull);
      expect(message.representativeEventId, isNull);
      expect(message.dedupKey, isNull);
    });

    test('single messages keep the pre-digest shape and dedup unit', () {
      // kind="single" is the labeled form of the per-event message: no
      // cover list, the event id remains the routing and the unit key.
      final message = FcmPushService.messageFromRemote(RemoteMessage(data: {
        'event_id': evTopEnterId,
        'event_type': 'TOP10_ENTERED',
        'kind': 'single',
      }));
      expect(message.kind, 'single');
      expect(message.eventIds, isNull);
      expect(message.representativeEventId, evTopEnterId);
      expect(message.dedupKey, evTopEnterId);
    });

    test('summary, digest and the covered single are distinct units', () {
      PushMessage covered(String kind) => PushMessage({
            'kind': kind,
            'event_ids': evTopEnterId,
            'count': '1',
          });
      expect(covered('summary').dedupKey, 'summary:$evTopEnterId');
      expect(covered('digest').dedupKey, 'digest:$evTopEnterId');
      expect(
        PushMessage.fromData({'event_id': evTopEnterId}).dedupKey,
        evTopEnterId,
        reason: 'a single event and a digest covering it are different '
            'units — both must surface',
      );
      // A cover list without a summary/digest kind is malformed: no
      // unit key, nothing dedups against it.
      expect(PushMessage({'event_ids': evTopEnterId}).dedupKey, isNull);
    });
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

    test('isMarketAlert also admits summary and digest cover messages',
        () {
      PushMessage covered(String kind) => PushMessage({
            'kind': kind,
            'event_ids': '$evTopEnterId,$evRankChangeId',
            'count': '2',
          }, notificationTitle: '홍스캐너 TOP10 변화', notificationBody: '요약');

      expect(MarketAlertChannel.isMarketAlert(covered('summary')), isTrue);
      expect(MarketAlertChannel.isMarketAlert(covered('digest')), isTrue);
      // No cover list: the tap contract (the list view of every covered
      // event) cannot be met — not postable, never degraded to a
      // single-event tap.
      expect(
        MarketAlertChannel.isMarketAlert(PushMessage({
          'kind': 'digest',
          'count': '2',
        }, notificationTitle: 't', notificationBody: 'b')),
        isFalse,
      );
      // No server-assembled text: never re-assembled by the app.
      expect(
        MarketAlertChannel.isMarketAlert(PushMessage({
          'kind': 'summary',
          'event_ids': evTopEnterId,
        }, notificationTitle: 't')),
        isFalse,
      );
      // kind="single" keeps the TOP10-vocabulary judgment, and an
      // unknown kind without an event_type does not become postable.
      expect(
        MarketAlertChannel.isMarketAlert(PushMessage({
          'event_id': evTopEnterId,
          'event_type': 'TOP10_ENTERED',
          'kind': 'single',
        }, notificationTitle: 't', notificationBody: 'b')),
        isTrue,
      );
      expect(
        MarketAlertChannel.isMarketAlert(PushMessage({
          'kind': 'single',
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
