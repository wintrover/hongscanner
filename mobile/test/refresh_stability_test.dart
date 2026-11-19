import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Refresh-stability contract: a 30s poll over an already-loaded
/// projection never falls back to the initial-load skeleton, and a failed
/// refresh leaves the last successful projection in place with the
/// failure recorded beside it.
void main() {
  test('a poll over loaded data keeps the last projection (no skeleton)',
      () async {
    final transport = fixtureTransport();
    final store = makeStore(transport: transport);
    addTearDown(store.dispose);

    await store.bootstrap();
    final first = store.marketView.value;
    final requestsAfterBootstrap = transport.requests.length;
    expect(store.marketView.phase, LoadPhase.loaded);

    final refresh = store.resync();

    // The second pass has started and is suspended on the wire: the
    // visible section is still the first answer.
    expect(store.syncCount, 2);
    expect(store.isRefreshing, isTrue);
    expect(store.marketView.phase, LoadPhase.loaded);
    expect(store.marketView.value, same(first));

    await refresh;

    expect(transport.requests.length, requestsAfterBootstrap + 1);
    expect(store.isRefreshing, isFalse);
    expect(store.marketView.phase, LoadPhase.loaded);
    expect(store.refreshErrorMessage, isNull);
  });

  test('a failed poll keeps the last projection and records the failure',
      () async {
    var down = false;
    final healthy = fixtureTransport();
    final transport = FakeTransport((uri) async {
      if (down) throw Exception('connection refused');
      return healthy.get(uri);
    });
    final store = makeStore(transport: transport);
    addTearDown(store.dispose);

    await store.bootstrap();
    final last = store.marketView.value;
    expect(store.marketView.phase, LoadPhase.loaded);

    down = true;
    await store.resync();

    expect(store.marketView.phase, LoadPhase.loaded,
        reason: 'a failed refresh never erases the last successful answer');
    expect(store.marketView.value, same(last));
    expect(store.refreshErrorMessage, contains('서버에 연결할 수 없음'));
    expect(store.refreshOffline, isTrue);

    down = false;
    await store.resync();

    expect(store.marketView.phase, LoadPhase.loaded);
    expect(store.refreshErrorMessage, isNull,
        reason: 'a successful refresh clears the retained-data badge');
    expect(store.refreshOffline, isFalse);
  });

  test('the first load still reports the honest error section', () async {
    final store = makeStore(
      transport: FakeTransport((_) async => throw Exception('down')),
    );
    addTearDown(store.dispose);

    await store.bootstrap();

    expect(store.marketView.phase, LoadPhase.error);
    expect(store.marketView.offline, isTrue);
    expect(store.refreshErrorMessage, isNull,
        reason: 'no earlier projection exists to keep');
    expect(store.isRefreshing, isFalse);
  });
}