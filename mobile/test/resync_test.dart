import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/main.dart';
import 'package:hongscanner/services/push_permission.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Phone-like viewport for gesture tests.
///
/// RefreshIndicator arms at a drag of (viewport × 0.25) ÷ 1.5, so the
/// arming threshold scales with viewport height: a tall 1200×4000 surface
/// needs a ~650 px pull before the indicator fires, and a human-scale
/// 300 px drag is silently cancelled. 800×1000 keeps the Market View
/// content visible and pull-to-refresh reachable (verified: the same
/// 300 px drag does not resync at 4000 px but does at 1000 px).
Future<void> pumpApp(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HongScannerApp(store: store));
}

/// Resync tests: startup, foreground resume, message-discard recovery,
/// and the bounded backoff on failures — all on the single
/// `/mobile/market-view` projection fetch.
void main() {
  test('startup performs exactly one sync pass of the single projection',
      () async {
    final transport = fixtureTransport();
    final store = makeStore(transport: transport);
    await store.bootstrap();
    expect(store.syncCount, 1);
    expect(transport.requests.map((uri) => uri.path).toList(),
        ['/mobile/market-view'],
        reason: 'one bounded fetch per pass — no list endpoints, '
            'no client-side re-derivation');
    expect(store.marketView.phase, LoadPhase.loaded);
  });

  test('market-view failure retries with restrained backoff, stays honest',
      () async {
    final backoffs = <Duration>[];
    final store = makeStore(
      transport: FakeTransport((_) async => throw Exception('down')),
      backoffs: backoffs,
    );
    await store.bootstrap();

    expect(store.syncCount, 1);
    expect(backoffs, [const Duration(seconds: 1), const Duration(seconds: 2)],
        reason: 'restrained exponential backoff, capped by max attempts');
    expect(store.marketView.phase, LoadPhase.error);
    expect(store.marketView.offline, isTrue);
    expect(store.pushState.phase, PushPhase.unwired);
  });

  test('a second sync pass after recovery reloads the projection',
      () async {
    var down = true;
    final healthy = fixtureTransport();
    final transport = FakeTransport((uri) async {
      if (down) throw Exception('down');
      return healthy.get(uri);
    });
    final store = makeStore(transport: transport);
    await store.bootstrap();
    expect(store.marketView.phase, LoadPhase.error);

    down = false;
    await store.resync();

    expect(store.syncCount, 2);
    expect(store.marketView.phase, LoadPhase.loaded);
    expect(store.marketView.value?.run?.sessionDate, '2026-11-02');
    expect(store.marketView.value?.risingTop10, hasLength(2));
    expect(store.marketView.value?.fallingTop10, hasLength(1));
    expect(store.marketView.value?.history, hasLength(4));
  });

  testWidgets('foreground resume (lifecycle) triggers a resync',
      (WidgetTester tester) async {
    final transport = fixtureTransport();
    final store = makeStore(transport: transport);
    await store.bootstrap();
    await tester.pumpWidget(HongScannerApp(store: store));
    final requestsAfterBootstrap = transport.requests.length;

    // Simulate the app going to background and coming back.
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(store.syncCount, 2);
    expect(transport.requests.length, greaterThan(requestsAfterBootstrap));
  });

  testWidgets('pull-to-refresh on the market view resyncs',
      (WidgetTester tester) async {
    final transport = fixtureTransport();
    final store = makeStore(transport: transport);
    await store.bootstrap();
    await pumpApp(tester, store);

    // The Market View list is the initial tab; a slow drag past the
    // refresh threshold triggers the indicator (a fling is too fast and
    // cancels it).
    await tester.drag(find.byType(RefreshIndicator), const Offset(0, 300));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(store.syncCount, greaterThanOrEqualTo(2),
        reason: 'RefreshIndicator.onRefresh is store.resync');
  });
}
