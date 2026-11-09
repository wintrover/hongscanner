import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:hongscanner/main.dart';
import 'package:hongscanner/screens/event_detail_screen.dart';
import 'package:hongscanner/services/fcm_push_service.dart';
import 'package:hongscanner/services/push_permission.dart';
import 'package:hongscanner/services/push_service.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Tap-routing tests driven by stub messages. The data payload contract is
/// {event_id, event_type, severity}; routing keys on event_id only. The
/// screen transition is a pushed detail route (root navigator), not a tab
/// switch — in store-only tests no navigator exists, so a routed id is
/// observable as store.pendingEventId until the shell's first-frame flush.
void main() {
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

  test('background tap message routes; foreground shows banner only',
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

    // Foreground delivery: in-app banner policy — no route, no fetch.
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
}
