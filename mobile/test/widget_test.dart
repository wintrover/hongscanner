import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hongscanner/main.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Pump with a tall test viewport: ListViews build children lazily, so a
/// default 800x600 surface never builds the below-the-fold cards these
/// assertions target. A 1200x4000 surface builds the whole list.
Future<void> pumpTallApp(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HongScannerApp(store: store));
}

void main() {
  testWidgets(
    'market view renders the three elements from the projection fixture',
    (WidgetTester tester) async {
      final store = makeStore(transport: fixtureTransport());
      await store.bootstrap();
      await pumpTallApp(tester, store);

      // Market View is the initial tab: exactly three market elements,
      // all from the single /mobile/market-view projection.
      expect(find.text('상승 TOP 10'), findsOneWidget);
      expect(find.text('하락 TOP 10'), findsOneWidget);
      expect(find.text('최근 후보 이벤트'), findsOneWidget);
      // Server-ranked rows, ascending rank — including a rank-1 item.
      expect(find.text('005930 (rank 1)'), findsOneWidget);
      expect(find.text('005930 (rank 2)'), findsOneWidget);
      expect(find.text('000660 (rank 1)'), findsOneWidget);
      // Retained history in server order (oldest→newest), CANDIDATE_* only.
      expect(find.text('CANDIDATE_ENTERED · 005930 · UP #1'), findsOneWidget);
      expect(find.text('CANDIDATE_ENTERED · 000660 · DOWN #1'), findsOneWidget);
      expect(find.text('CANDIDATE_UPDATED · 005930 · UP #2'), findsOneWidget);
      // rank is null on the CANDIDATE_EXITED row: honest absence — the
      // row renders without a rank, never with a fake 0.
      expect(find.text('CANDIDATE_EXITED · 000660 · DOWN'), findsOneWidget);
      expect(find.textContaining('#0'), findsNothing);
      expect(find.textContaining('(rank 0'), findsNothing);
      // Run header facts and the verbatim data-quality status.
      expect(find.text('2026-11-02'), findsOneWidget);
      expect(find.text('2026-11-02T15:30:58+09:00'), findsOneWidget);
      expect(find.text('INCOMPLETE×1, OBSERVING×3'), findsOneWidget);
      // INCOMPLETE stays visible per item, never flattened to normal.
      expect(find.text('2026-11-02T09:03:30+09:00 · INCOMPLETE'),
          findsOneWidget);
      // Push unwired state is honest about Firebase being absent.
      expect(find.textContaining('푸시 미연결 — Firebase 미설정'), findsOneWidget);

      // Event Detail tab (no selection yet).
      await tester.tap(find.text('Event Detail'));
      await tester.pumpAndSettle();
      expect(find.text('이벤트 미선택'), findsOneWidget);

      // Back to Market View: IndexedStack keeps state across tab switches.
      await tester.tap(find.text('Market View'));
      await tester.pumpAndSettle();
      expect(find.text('상승 TOP 10'), findsOneWidget);
    },
  );

  testWidgets('history tap routes into the event detail tab',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport());
    await store.bootstrap();
    await pumpTallApp(tester, store);

    await tester.tap(find.text('CANDIDATE_ENTERED · 000660 · DOWN #1'));
    await tester.pumpAndSettle();

    expect(store.tabIndex, AppStore.detailTabIndex);
    expect(store.selectedEventId, evDownEnterId);
    // The detail tab now shows the recorded fact, verbatim fields and
    // delivery section.
    expect(find.text('근거 (evidence_ref)'), findsOneWidget);
    // 근거 card + recorded fact table both show the evidence reference.
    expect(find.text('ka10027:stex_tp=1:sort_tp=1'), findsNWidgets(2));
    expect(find.text('전달 기록 없음'), findsOneWidget);
    expect(find.text('event_id'), findsOneWidget);
    expect(find.text('direction'), findsOneWidget);
    expect(find.text('DOWN'), findsOneWidget);
  });

  testWidgets('no eligible run renders honest absence, not fake content',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport(extra: {
      '/mobile/market-view': okJson({
        'as_of': null,
        'falling_top10': <Object?>[],
        'history': <Object?>[],
        'latest': null,
        'rising_top10': <Object?>[],
        'run': null,
        'runs_present': false,
        'status': null,
      }),
    }));
    await store.bootstrap();
    await pumpTallApp(tester, store);

    // runs_present:false / run:null — "no eligible run recorded" renders
    // as 기록 없음 (session_date, as_of, 데이터 품질 rows), never as
    // zero-filled rows.
    expect(find.text('기록 없음'), findsNWidgets(3));
    expect(find.text('상승 TOP 10 기록 없음'), findsOneWidget);
    expect(find.text('하락 TOP 10 기록 없음'), findsOneWidget);
    expect(find.text('후보 이벤트 기록 없음'), findsOneWidget);
    // Nothing recorded, so no ranked rows anywhere.
    expect(find.text('005930 (rank 1)'), findsNothing);
    expect(find.text('CANDIDATE_ENTERED · 000660 · DOWN #1'), findsNothing);
    expect(find.textContaining('#0'), findsNothing);
  });

  testWidgets('offline server surfaces an honest offline state with retry',
      (WidgetTester tester) async {
    final store = makeStore(
      transport: FakeTransport(
          (_) async => throw Exception('connection refused')),
      backoffs: [],
    );
    await store.bootstrap();
    await pumpTallApp(tester, store);

    expect(find.text('오프라인'), findsWidgets);
    expect(find.text('다시 시도'), findsWidgets);
    expect(find.textContaining('기록을 읽는 중'), findsNothing,
        reason: 'offline is an error state, not an eternal spinner');
  });
}
