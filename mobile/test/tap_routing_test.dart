import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:hongscanner/main.dart';
import 'package:hongscanner/screens/digest_list_screen.dart';
import 'package:hongscanner/screens/event_detail_screen.dart';
import 'package:hongscanner/services/fcm_push_service.dart';
import 'package:hongscanner/services/market_alert_channel.dart';
import 'package:hongscanner/services/push_permission.dart';
import 'package:hongscanner/services/push_service.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Tap-routing tests driven by stub messages. The data payload contract
/// has three shapes: a single event (`event_id`, …), an immediate
/// summary and a silent digest (`kind`, `event_ids`, `count` — the
/// routing keys on the payload shape: an `event_id` routes to the event
/// detail, a cover list to the digest list view). The screen
/// transition is a pushed route on the root navigator, not a tab
/// switch — in store-only tests no navigator exists, so a routed id is
/// observable as store.pendingEventId / store.pendingEventIds until
/// the shell's first-frame flush. The market-alert group drives the
/// real shell so the OS-notification posting (MethodChannel
/// "hongscanner/market_alert", mocked via
/// TestDefaultBinaryMessengerBinding) and its fallbacks are observable
/// end-to-end.
void main() {
  /// The cover list every digest test below uses, and the rows it must
  /// render: one per covered event, each row the fact's own
  /// name/direction/rank-change/observed-time.
  const digestCover = [evTopEnterId, evRankChangeId, evTopExitId];
  const digestCoverJoined = '$evTopEnterId,$evRankChangeId,$evTopExitId';

  PushMessage digestMessage() => PushMessage.fromData({
        'kind': 'digest',
        'event_ids': digestCoverJoined,
        'count': '3',
      });

  void expectDigestRows() {
    expect(find.byType(DigestListScreen), findsOneWidget);
    // Every covered event is a row — the count equals the cover list.
    expect(find.byType(ListTile), findsNWidgets(digestCover.length));
    expect(find.text('삼성전자 · UP · 진입'), findsOneWidget);
    expect(find.text('SK하이닉스 · DOWN · 5위 → 2위'), findsOneWidget);
    expect(find.text('삼성전자 · UP · 이탈'), findsOneWidget);
    expect(find.text('2026-11-02T09:05:11+09:00'), findsOneWidget);
  }

  test('FcmPushService maps a stub RemoteMessage to a PushMessage', () {
    final message = FcmPushService.messageFromRemote(RemoteMessage(data: {
      'event_id': evUpEnterId,
      'event_type': 'CANDIDATE_ENTERED',
      'severity': 'HIGH',
    }));
    expect(message.eventId, evUpEnterId);
    expect(message.eventType, 'CANDIDATE_ENTERED');
    expect(message.severity, 'HIGH');
  });

  test('notification payload title/body pass through verbatim', () {
    // The dispatcher (tools/notify) assembles the notification text; the
    // app carries it as opaque display text and never re-assembles it.
    final message = FcmPushService.messageFromRemote(RemoteMessage(
      data: {
        'event_id': evUpEnterId,
        'event_type': 'TOP10_ENTERED',
        'severity': 'HIGH',
      },
      notification: RemoteNotification(
        title: 'TOP10 진입: 삼성전자',
        body: '순위 11 → 7',
      ),
    ));
    expect(message.notificationTitle, 'TOP10 진입: 삼성전자');
    expect(message.notificationBody, '순위 11 → 7');
    // Data parsing is untouched: the routing fields still come from data.
    expect(message.eventId, evUpEnterId);
    expect(message.eventType, 'TOP10_ENTERED');
  });

  test('non-string payload fields degrade to null, never throw', () {
    final message = FcmPushService.messageFromRemote(
        RemoteMessage(data: {'event_id': 12345}));
    expect(message.eventId, isNull);
    expect(message.eventType, isNull);
  });

  test('cold start with initial message routes to the event detail',
      () async {
    final push = FakeMessagePushService(
        initial: PushMessage.fromData({
      'event_id': evUpUpdateId,
      'event_type': 'CANDIDATE_UPDATED',
      'severity': 'HIGH',
    }));
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();
    // Cold-start routing fetches the detail asynchronously; drain the
    // queue so the assertion observes the completed fetch (the fetch is
    // real — no fake loaded state).
    await pumpEventQueue();

    // No navigator exists in this store-only test, so the route cannot be
    // pushed yet: the id is pending for the shell's first-frame flush.
    // The selection and the fetch still ran.
    expect(store.pendingEventId, evUpUpdateId);
    expect(store.selectedEventId, evUpUpdateId);
    expect(store.eventDetail.phase, LoadPhase.loaded);
    expect(store.eventDetail.value?.event.eventType, 'CANDIDATE_UPDATED');
  });

  test('background tap message routes; foreground delivery is never routed',
      () async {
    final push = FakeMessagePushService();
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    final banners = <PushMessage>[];
    await store.bootstrap(onForegroundMessage: banners.add);

    // Background notification tap: routed (pending — no navigator in a
    // store-only test) + fetched.
    push.tapController.add(PushMessage.fromData({
      'event_id': evDownEnterId,
      'event_type': 'CANDIDATE_ENTERED',
    }));
    await pumpEventQueue();
    expect(store.pendingEventId, evDownEnterId);
    expect(store.selectedEventId, evDownEnterId);

    // Foreground delivery: forwarded to the shell's display callback
    // (which posts market alerts to the OS channel or shows the banner
    // fallback — driven by the shell-level tests below) — never routed:
    // no selection change, no fetch, no pending route.
    push.foregroundController.add(PushMessage.fromData({
      'event_id': evUpEnterId,
      'event_type': 'CANDIDATE_ENTERED',
    }));
    await pumpEventQueue();
    expect(banners, hasLength(1));
    expect(banners.single.eventId, evUpEnterId);
    expect(store.selectedEventId, evDownEnterId,
        reason: 'foreground banner must not hijack the current selection');
    expect(store.pendingEventId, evDownEnterId);
  });

  test('background digest tap routes the cover list; foreground stays display-only',
      () async {
    final push = FakeMessagePushService();
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    final banners = <PushMessage>[];
    await store.bootstrap(onForegroundMessage: banners.add);

    // Background notification tap on a digest: the cover list routes
    // (pending — no navigator in a store-only test) and every covered
    // event is fetched.
    push.tapController.add(digestMessage());
    await pumpEventQueue();
    expect(store.pendingEventIds, digestCover);
    expect(store.selectedEventIds, digestCover);
    expect(store.digestEvents.phase, LoadPhase.loaded);
    expect(
      store.digestEvents.value?.map((d) => d.event.eventId).toList(),
      digestCover,
      reason: 'one fetched fact per covered event, in cover order',
    );
    // The digest never disturbs the single-event selection/detail.
    expect(store.selectedEventId, isNull);
    expect(store.pendingEventId, isNull);

    // Foreground digest delivery: display only (banner callback), never
    // routed — no selection change, no fetch, no pending route.
    push.foregroundController.add(digestMessage());
    await pumpEventQueue();
    expect(banners, hasLength(1));
    expect(banners.single.kind, 'digest');
    expect(store.pendingEventIds, digestCover,
        reason: 'unchanged by the foreground delivery');
  });

  test('payload without a usable event_id is not routed (no invention)',
      () async {
    final push = FakeMessagePushService();
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();

    expect(store.selectedEventId, isNull,
        reason: 'no initial message — nothing selected');
    expect(store.pendingEventId, isNull);
    push.tapController
        .add(PushMessage.fromData({'event_type': 'SESSION_ENDED'}));
    await pumpEventQueue();
    expect(store.selectedEventId, isNull);
    expect(store.pendingEventId, isNull);

    push.tapController.add(PushMessage.fromData({'event_id': 4}));
    await pumpEventQueue();
    expect(store.selectedEventId, isNull);
  });

  testWidgets(
      'notification tap from cold start drives the real shell to detail',
      (WidgetTester tester) async {
    final push = FakeMessagePushService(
        initial: PushMessage.fromData({
      'event_id': evUpEnterId,
      'event_type': 'CANDIDATE_ENTERED',
      'severity': 'INFO',
    }));
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();
    // The tap routed before any navigator existed: the id is pending.
    expect(store.pendingEventId, evUpEnterId);

    await tester.pumpWidget(HongScannerApp(store: store));
    await tester.pumpAndSettle();
    // The shell's post-frame flush turned the pending id into the detail
    // route on the root navigator; the detail screen renders the recorded
    // fact.
    expect(store.pendingEventId, isNull);
    expect(find.byType(EventDetailScreen), findsOneWidget);
    expect(find.text('근거 (evidence_ref)'), findsOneWidget);
    // The evidence_ref value renders twice on the detail screen by design:
    // once highlighted in the 근거 card and once verbatim in the recorded
    // fact table (evidence_ref row).
    expect(find.text('ka10027:stex_tp=1:sort_tp=1'), findsNWidgets(2));
    expect(find.text('dev-1 — ACCEPTED'), findsOneWidget);
    // Back is natural: popping returns to the two-tab shell.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailScreen), findsNothing);
    expect(find.text('후보'), findsOneWidget);
  });

  testWidgets(
      'digest tap from FCM cold start routes to the cover-list view',
      (WidgetTester tester) async {
    final push = FakeMessagePushService(initial: digestMessage());
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();
    // Routed before any navigator existed: the cover list is pending.
    // (No pumpEventQueue here: its event-loop hops are timer-based and
    // never fire in the fake-async zone of a widget test — the fetches
    // drain during the pumps below instead.)
    expect(store.pendingEventIds, digestCover);

    await tester.pumpWidget(HongScannerApp(store: store));
    await tester.pumpAndSettle();
    expect(store.pendingEventIds, isNull);
    expectDigestRows();

    // A row tap routes to the existing event detail — the ③ contract
    // gives every covered event the same detail access a single tap has.
    await tester.tap(find.text('SK하이닉스 · DOWN · 5위 → 2위'));
    await tester.pumpAndSettle();
    expect(store.selectedEventId, evRankChangeId);
    expect(find.byType(EventDetailScreen), findsOneWidget);
    expect(find.text('근거 (evidence_ref)'), findsOneWidget);
    // Back is natural: popping the detail returns to the digest list,
    // not out of the app.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailScreen), findsNothing);
    expect(find.byType(DigestListScreen), findsOneWidget);
  });

  testWidgets(
      'background digest tap while the shell runs routes to the cover-list view',
      (WidgetTester tester) async {
    final push = FakeMessagePushService();
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await tester.pumpWidget(HongScannerApp(store: store));
    await tester.pumpAndSettle();
    expect(find.byType(DigestListScreen), findsNothing);

    // onMessageOpenedApp with a digest payload: cover list routed.
    push.tapController.add(digestMessage());
    await tester.pumpAndSettle();
    expect(store.pendingEventIds, isNull);
    expectDigestRows();
    // A repeated digest tap reuses the mounted list route (selection
    // update in place) — no stacked routes.
    push.tapController.add(digestMessage());
    await tester.pumpAndSettle();
    expect(find.byType(DigestListScreen), findsOneWidget);
  });

  group('market-alert channel', () {
    PushMessage marketMessage(String eventId, String eventType,
            {String? title, String? body}) =>
        PushMessage({
          'event_id': eventId,
          'event_type': eventType,
        }, notificationTitle: title, notificationBody: body);

    testWidgets(
      'foreground TOP10 alerts post to the OS channel verbatim; no banner, no routing hijack',
      (tester) async {
        final mock = mockMarketAlert();
        final push = FakeMessagePushService();
        final store = makeStore(
            transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
        await tester.pumpWidget(HongScannerApp(store: store));
        await tester.pumpAndSettle();

        // A TOP10 state change with the dispatcher's own text: re-posted
        // to the OS channel with the server-assembled strings, verbatim.
        push.foregroundController.add(marketMessage(evUpEnterId,
            'TOP10_ENTERED',
            title: 'TOP10 진입: 삼성전자', body: '순위 11 → 7'));
        await tester.pumpAndSettle();
        expect(mock.posts, hasLength(1));
        expect(mock.posts.single['eventId'], evUpEnterId);
        expect(mock.posts.single['title'], 'TOP10 진입: 삼성전자');
        expect(mock.posts.single['body'], '순위 11 → 7');
        // The OS notification owns the display: no in-app banner on top.
        expect(find.byType(SnackBar), findsNothing);
        // Foreground policy unchanged: no route, no selection hijack,
        // no detail fetch.
        expect(store.selectedEventId, isNull);
        expect(store.pendingEventId, isNull);
        expect(store.eventDetail.phase, LoadPhase.idle);

        // A re-delivery of the same event dedups (bounded history): no
        // second post, no banner.
        push.foregroundController.add(marketMessage(evUpEnterId,
            'TOP10_ENTERED',
            title: 'TOP10 진입: 삼성전자', body: '순위 11 → 7'));
        await tester.pumpAndSettle();
        expect(mock.posts, hasLength(1));

        // A different market event posts again.
        push.foregroundController.add(marketMessage(evUpUpdateId,
            'RANK_CHANGED',
            title: '순위 변화: 삼성전자', body: '순위 7 → 2'));
        await tester.pumpAndSettle();
        expect(mock.posts, hasLength(2));

        // A market type WITHOUT the server text is not postable — the
        // app never re-assembles text the server did not send. The
        // banner is the fallback.
        push.foregroundController
            .add(marketMessage(evDownEnterId, 'TOP10_EXITED'));
        await tester.pumpAndSettle();
        expect(mock.posts, hasLength(2));
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text('포그라운드 알림 수신: TOP10_EXITED'), findsOneWidget);
        // Still no routing through any of the foreground deliveries.
        expect(store.selectedEventId, isNull);

        // Let the fallback banner expire before the next delivery.
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();

        // Non-market types: banner only, no OS post.
        push.foregroundController.add(PushMessage.fromData({
          'event_id': evDownExitId,
          'event_type': 'CANDIDATE_EXITED',
        }));
        await tester.pumpAndSettle();
        expect(mock.posts, hasLength(2));
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text('포그라운드 알림 수신: CANDIDATE_EXITED'), findsOneWidget);
      },
    );

    testWidgets('a refused OS post falls back to the in-app banner',
        (tester) async {
      // postResult false = the platform refused (notification permission
      // off / disabled): nothing is displayed by the OS, so the banner
      // takes over instead of the alert being lost.
      final mock = mockMarketAlert(postResult: false);
      final push = FakeMessagePushService();
      final store = makeStore(
          transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
      await tester.pumpWidget(HongScannerApp(store: store));
      await tester.pumpAndSettle();

      push.foregroundController.add(marketMessage(evUpEnterId,
          'TOP10_ENTERED',
          title: 'TOP10 진입: 삼성전자', body: '순위 11 → 7'));
      await tester.pumpAndSettle();
      expect(mock.posts, hasLength(1));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('포그라운드 알림 수신: TOP10_ENTERED'), findsOneWidget);
      expect(store.selectedEventId, isNull);
    });

    testWidgets(
      'cold-start pending local-notification tap is consumed once and routes to detail',
      (tester) async {
        // pendingTap: the id the platform side kept from the launch intent
        // (MainActivity.configureFlutterEngine → pendingTapEventId).
        mockMarketAlert(pendingTap: evUpEnterId);
        final push = FakeMessagePushService();
        final store = makeStore(
            transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
        await tester.pumpWidget(HongScannerApp(store: store));
        await tester.pumpAndSettle();

        // The pending tap the platform side kept from the launch routed
        // through the store's openEvent: the detail route shows the
        // recorded fact, same as an FCM cold-start tap.
        expect(store.selectedEventId, evUpEnterId);
        expect(store.pendingEventId, isNull);
        expect(find.byType(EventDetailScreen), findsOneWidget);
        expect(find.text('근거 (evidence_ref)'), findsOneWidget);
        // One-shot: the consume cleared the platform-side copy.
        expect(await const MarketAlertChannel().getPendingTap(), isNull);
      },
    );

    testWidgets('a warm local-notification tap routes via the channel handler',
        (tester) async {
      // The mock keeps getPendingTap deterministic (null — warm taps never
      // park the id); the tap itself arrives as a platform→Dart message.
      mockMarketAlert();
      final push = FakeMessagePushService();
      final store = makeStore(
          transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
      await tester.pumpWidget(HongScannerApp(store: store));
      await tester.pumpAndSettle();
      expect(store.selectedEventId, isNull);

      // MainActivity.onNewIntent → invokeMethod("onNotificationTap"): the
      // platform→Dart call reaches the handler the shell registered
      // (getPendingTap stays null — the warm path never parks the id).
      await deliverMarketAlertTap(evDownEnterId);
      await tester.pumpAndSettle();
      expect(store.selectedEventId, evDownEnterId);
      expect(store.pendingEventId, isNull);
      expect(find.byType(EventDetailScreen), findsOneWidget);
    });

    testWidgets('a warm local digest tap routes to the cover-list view',
        (tester) async {
      // The digest notification's tap intent carries event_ids alongside
      // the representative event_id — the platform→Dart call keeps both,
      // exactly as MainActivity builds them.
      mockMarketAlert();
      final push = FakeMessagePushService();
      final store = makeStore(
          transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
      await tester.pumpWidget(HongScannerApp(store: store));
      await tester.pumpAndSettle();

      await deliverMarketAlertTap(evTopEnterId, eventIds: digestCoverJoined);
      await tester.pumpAndSettle();
      expect(store.pendingEventIds, isNull);
      expectDigestRows();
      // The pending copy was acknowledged: nothing stays parked.
      expect(await const MarketAlertChannel().getPendingTap(), isNull);
    });

    testWidgets(
      'cold-start pending local digest tap is consumed once and routes to the list view',
      (tester) async {
        // pendingTap/pendingTapEventIds: the payload the platform side
        // kept from the launch intent of a digest notification tap
        // (MainActivity.configureFlutterEngine).
        mockMarketAlert(pendingTap: evTopEnterId, pendingTapEventIds: digestCoverJoined);
        final push = FakeMessagePushService();
        final store = makeStore(
            transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
        await tester.pumpWidget(HongScannerApp(store: store));
        await tester.pumpAndSettle();

        expect(store.pendingEventIds, isNull);
        expectDigestRows();
        // One-shot: the consume cleared the platform-side copy.
        expect(await const MarketAlertChannel().getPendingTap(), isNull);
      },
    );

    testWidgets(
      'foreground digest posts to the silent digest channel with its cover list',
      (tester) async {
        final mock = mockMarketAlert();
        final push = FakeMessagePushService();
        final store = makeStore(
            transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
        await tester.pumpWidget(HongScannerApp(store: store));
        await tester.pumpAndSettle();

        push.foregroundController.add(PushMessage({
          'kind': 'digest',
          'event_ids': digestCoverJoined,
          'count': '3',
        }, notificationTitle: '홍스캐너 TOP10 순위 요약', notificationBody: '관측 그룹 요약'));
        await tester.pumpAndSettle();
        expect(mock.posts, hasLength(1));
        // The post carries the server's text verbatim plus the message
        // unit: the representative (first covered) id, the kind, the
        // comma-joined cover list, and the silent channel.
        expect(mock.posts.single['eventId'], evTopEnterId);
        expect(mock.posts.single['title'], '홍스캐너 TOP10 순위 요약');
        expect(mock.posts.single['body'], '관측 그룹 요약');
        expect(mock.posts.single['kind'], 'digest');
        expect(mock.posts.single['eventIds'], digestCoverJoined);
        expect(mock.posts.single['channelId'], 'market_rank_digest');
        // The OS notification owns the display: no in-app banner on top.
        expect(find.byType(SnackBar), findsNothing);
        // Foreground policy unchanged: no route, no selection hijack.
        expect(store.selectedEventId, isNull);
        expect(store.pendingEventIds, isNull);
        expect(store.digestEvents.phase, LoadPhase.idle);

        // A re-delivery of the same digest is one unit: no second post.
        push.foregroundController.add(PushMessage({
          'kind': 'digest',
          'event_ids': digestCoverJoined,
          'count': '3',
        }, notificationTitle: '홍스캐너 TOP10 순위 요약', notificationBody: '관측 그룹 요약'));
        await tester.pumpAndSettle();
        expect(mock.posts, hasLength(1));

        // The single event covered by the digest is a different unit:
        // it still surfaces — on the sound channel (no channelId arg).
        push.foregroundController.add(marketMessage(evTopEnterId,
            'TOP10_ENTERED',
            title: 'TOP10 진입: 삼성전자', body: '순위 11 → 7'));
        await tester.pumpAndSettle();
        expect(mock.posts, hasLength(2));
        expect(mock.posts.last['channelId'], isNull,
            reason: 'the default sound channel — the pre-digest contract');
      },
    );

    testWidgets('foreground summary posts on the sound channel', (tester) async {
      final mock = mockMarketAlert();
      final push = FakeMessagePushService();
      final store = makeStore(
          transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
      await tester.pumpWidget(HongScannerApp(store: store));
      await tester.pumpAndSettle();

      // An immediate ≥2-event summary: sound channel, kind and cover
      // list carried like the digest's.
      push.foregroundController.add(PushMessage({
        'kind': 'summary',
        'event_ids': digestCoverJoined,
        'count': '3',
      }, notificationTitle: '홍스캐너 TOP10 변화', notificationBody: '순위 변화 요약'));
      await tester.pumpAndSettle();
      expect(mock.posts, hasLength(1));
      expect(mock.posts.single['eventId'], evTopEnterId);
      expect(mock.posts.single['kind'], 'summary');
      expect(mock.posts.single['eventIds'], digestCoverJoined);
      expect(mock.posts.single['channelId'], isNull,
          reason: 'a summary is a sound notification — the default channel');
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
