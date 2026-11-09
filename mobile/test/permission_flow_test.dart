import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/main.dart';
import 'package:hongscanner/services/push_permission.dart';
import 'package:hongscanner/services/push_service.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Permission-flow tests. The plugin boundary is faked at the two levels
/// the flow actually uses: the PushService fake scripts the platform's
/// permission decision, and persistence goes through the in-memory
/// KeyValueStore (the same interface the SharedPreferences impl serves on
/// device). This is where the Android 13+ "denied is ambiguous" problem
/// lives: the app's own ask history is the only recorded fact.
void main() {
  test('first run with granted decision: asked once, recorded, phase granted',
      () async {
    final kv = MemoryKeyValueStore();
    final push = FakeTokenPushService(
        ready: true,
        decision: PushPermissionDecision.granted,
        fid: 'fcm-fid-abc');
    final store = makeStore(
        transport: fixtureTransport(), push: push, kv: kv);
    await store.bootstrap();

    expect(push.askCount, 1, reason: 'first run auto-asks exactly once');
    expect(push.registerCount, 1,
        reason: 'a ready token source registers exactly once per bootstrap');
    expect(store.pushState.phase, PushPhase.granted);
    expect(store.pushState.askedCount, 1);
    expect(store.pushState.lastResponse, PushPermissionDecision.granted);
    expect(store.pushState.token, 'fcm-fid-abc',
        reason: 'the FID delivered via onRegistered is display-only');

    final record = await PushPermissionLedger(store: kv).load();
    expect(record.askedCount, 1);
    expect(record.lastResponse, PushPermissionDecision.granted);
    expect(record.lastAskedAt, DateTime(2026, 11, 2, 9));
  });

  test('register() failure surfaces an honest error, not a fake token',
      () async {
    final push = FakeTokenPushService(
        ready: true,
        registerError: StateError('registration failed at the plugin'));
    final store = makeStore(
        transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();

    expect(push.registerCount, 1);
    expect(store.pushState.token, isNull);
    expect(store.pushState.tokenError, contains('토큰 획득 실패'));
    expect(store.pushState.tokenError, contains('registration failed'));
  });

  test('ready service without a token source shows no token and no error',
      () async {
    final push = FakePushService(
        ready: true, decision: PushPermissionDecision.granted);
    final store = makeStore(
        transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();

    expect(store.pushState.token, isNull);
    expect(store.pushState.tokenError, isNull,
        reason: 'nothing was delivered and nothing failed — no invented state');
  });

  test('denied decision: app keeps working, push shown disabled', () async {
    final push = FakePushService(
        ready: true, decision: PushPermissionDecision.denied);
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();

    expect(store.pushState.phase, PushPhase.denied);
    // The app still synced the projection — denial only kills push.
    expect(store.marketView.phase, LoadPhase.loaded);
    expect(store.pushState.askedCount, 1);
  });

  test('restart after denial does NOT auto-ask again (ask history wins)',
      () async {
    final kv = MemoryKeyValueStore();
    final first = FakePushService(
        ready: true, decision: PushPermissionDecision.denied);
    final firstStore =
        makeStore(transport: fixtureTransport(), push: first, kv: kv);
    await firstStore.bootstrap();
    expect(first.askCount, 1);

    // New "process": new store + fresh fake, same persisted history.
    final second = FakePushService(
        ready: true, decision: PushPermissionDecision.denied);
    final secondStore =
        makeStore(transport: fixtureTransport(), push: second, kv: kv);
    await secondStore.bootstrap();

    expect(second.askCount, 0,
        reason: 'Android 13+ ambiguity: auto-ask only when never asked');
    expect(secondStore.pushState.phase, PushPhase.denied);
    expect(secondStore.pushState.askedCount, 1);

    // The operator can still re-ask explicitly from the Overview card.
    await secondStore.requestPushPermission();
    expect(second.askCount, 1);
    expect(secondStore.pushState.askedCount, 2);
    final record = await PushPermissionLedger(store: kv).load();
    expect(record.askedCount, 2);
    expect(record.lastResponse, PushPermissionDecision.denied);
  });

  test('failed ask records an ask with no decision (unknown, honest)',
      () async {
    final kv = MemoryKeyValueStore();
    final push = FakePushService(ready: true, throwOnAsk: true);
    final store = makeStore(transport: fixtureTransport(), push: push, kv: kv);
    await store.bootstrap();

    expect(store.pushState.phase, PushPhase.unknown);
    expect(store.pushState.lastResponse, isNull);
    expect(store.pushState.askedCount, 1);
    expect(store.pushState.notice, contains('권한 요청 실패'));

    final record = await PushPermissionLedger(store: kv).load();
    expect(record.askedCount, 1);
    expect(record.lastResponse, isNull);
    // An unknown outcome is not "never asked": no auto-ask loop on restart.
    final again = FakePushService(
        ready: true, decision: PushPermissionDecision.granted);
    final store2 = makeStore(transport: fixtureTransport(), push: again, kv: kv);
    await store2.bootstrap();
    expect(again.askCount, 0);
  });

  test('provisional decision is tracked as its own state', () async {
    final push = FakePushService(
        ready: true, decision: PushPermissionDecision.provisional);
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();
    expect(store.pushState.phase, PushPhase.provisional);
  });

  test('unwired service (no Firebase): no ask, app functional, phase unwired',
      () async {
    final push = FakePushService(ready: false);
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();

    expect(push.askCount, 0);
    expect(store.pushState.phase, PushPhase.unwired);
    expect(store.pushState.token, isNull);
    // Everything else still loads.
    expect(store.marketView.phase, LoadPhase.loaded);
    expect(store.syncCount, 1);
  });

  testWidgets('denied push renders the disabled state with a re-ask button',
      (WidgetTester tester) async {
    final push = FakePushService(
        ready: true, decision: PushPermissionDecision.denied);
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();
    await tester.pumpWidget(HongScannerApp(store: store));

    expect(find.text('푸시 비활성 — 권한 거부됨'), findsOneWidget);
    expect(find.text('다시 요청'), findsOneWidget);
    expect(find.textContaining('요청 이력: 1회'), findsOneWidget);
  });

  testWidgets('the delivered FID renders in full — copyable, not truncated',
      (WidgetTester tester) async {
    // FID-scale length (~150 chars): a 60-char prefix would visibly cut it.
    final fid = 'fcm-${'a1B2c3D4' * 18}x';
    final push = FakeTokenPushService(
        ready: true, decision: PushPermissionDecision.granted, fid: fid);
    final store =
        makeStore(transport: fixtureTransport(), push: push, kv: MemoryKeyValueStore());
    await store.bootstrap();
    await tester.pumpWidget(HongScannerApp(store: store));

    expect(find.textContaining(fid), findsOneWidget,
        reason: 'the operator registers exactly the displayed identifier — '
            'a truncated prefix would be a broken registration');
  });
}
