import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hongscanner/main.dart';
import 'package:hongscanner/screens/event_detail_screen.dart';
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
    '후보 tab renders both top-10 cards; 히스토리 the change history',
    (WidgetTester tester) async {
      final store = makeStore(transport: fixtureTransport());
      await store.bootstrap();
      await pumpTallApp(tester, store);

      // 후보 is the initial tab: the two top-10 cards from the single
      // /mobile/market-view projection — server-ranked rows, ascending
      // rank, the recorded stock name as the title (rank in the existing
      // '(rank N)' style).
      expect(find.text('삼성전자 (rank 1)'), findsOneWidget);
      expect(find.text('삼성전자 (rank 2)'), findsOneWidget);
      expect(find.text('SK하이닉스 (rank 1)'), findsOneWidget);
      // Normal-quality rows (the OK/COMPLETE/OBSERVING set) show no
      // quality suffix…
      expect(find.textContaining('· OBSERVING'), findsNothing);
      // …and the run/as_of meta card and the push/token UI are gone
      // (abnormal quality still shows per item, asserted below).
      expect(find.text('세션 · 시점'), findsNothing);
      expect(find.text('2026-11-02'), findsNothing);
      expect(find.text('INCOMPLETE×1, OBSERVING×3'), findsNothing);
      expect(find.textContaining('푸시'), findsNothing);
      // Core mode carries no MA20 semantics: no mode headers, no tag
      // badges — the pre-mode display unchanged.
      expect(find.textContaining('(MA20'), findsNothing);
      expect(find.byType(Badge), findsNothing);

      // 히스토리 tab: the retained TOP10 state-change records in server
      // order (oldest→newest), prev rank→new rank.
      await tester.tap(find.text('히스토리'));
      await tester.pumpAndSettle();
      expect(
          find.text('TOP10_ENTERED · 삼성전자 · UP #11→7'), findsOneWidget);
      expect(find.text('RANK_CHANGED · SK하이닉스 · DOWN #5→2'),
          findsOneWidget);
      expect(
          find.text('TOP10_EXITED · 삼성전자 · UP #8→11'), findsOneWidget);
      // The EXITED row has no name record: symbol fallback. rank is null
      // on CANDIDATE_EXITED — honest absence, never a fake 0.
      expect(find.text('CANDIDATE_EXITED · 000660 · DOWN'), findsOneWidget);
      expect(find.textContaining('#0'), findsNothing);
      expect(find.textContaining('(rank 0'), findsNothing);
      // Conditional quality: INCOMPLETE stays explicit per item, never
      // flattened to normal.
      expect(find.text('2026-11-02T09:03:30+09:00 · INCOMPLETE'),
          findsOneWidget);

      // Tab switches read the single store — no refetch.
      await tester.tap(find.text('후보'));
      await tester.pumpAndSettle();
      expect(find.text('삼성전자 (rank 1)'), findsOneWidget);
      expect(store.syncCount, 1);
    },
  );

  testWidgets('history tap pushes the event detail route; back pops it',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport());
    await store.bootstrap();
    await pumpTallApp(tester, store);

    await tester.tap(find.text('히스토리'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RANK_CHANGED · SK하이닉스 · DOWN #5→2'));
    await tester.pumpAndSettle();

    expect(store.selectedEventId, evDownEnterId);
    // The detail is a pushed route on the root navigator, not a tab
    // switch: the tab index is untouched.
    expect(store.tabIndex, 1);
    expect(find.byType(EventDetailScreen), findsOneWidget);
    // The route shows the recorded fact, verbatim fields and delivery
    // section.
    expect(find.text('근거 (evidence_ref)'), findsOneWidget);
    // 근거 card + recorded fact table both show the evidence reference.
    expect(find.text('ka10027:stex_tp=1:sort_tp=1'), findsNWidgets(2));
    expect(find.text('전달 기록 없음'), findsOneWidget);
    expect(find.text('event_id'), findsOneWidget);
    expect(find.text('direction'), findsOneWidget);
    expect(find.text('DOWN'), findsOneWidget);

    // Back is natural: popping the route returns to the two-tab shell.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailScreen), findsNothing);
    expect(find.text('히스토리'), findsOneWidget);
  });

  testWidgets('quality suffix policy: normal hidden, abnormal explicit',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport(extra: {
      '/mobile/market-view': okJson({
        'as_of': '2026-11-02T15:30:58+09:00',
        'falling_top10': <Object?>[],
        'history': <Object?>[],
        'latest': null,
        'mode': 'core',
        'rising_top10': [
          fixtureMarketItem(evUpEnterId,
              eventType: 'CANDIDATE_ENTERED',
              observedAt: '2026-11-02T09:00:05+09:00',
              direction: 'UP',
              rank: 1,
              symbol: '005930',
              dataQuality: 'COMPLETE',
              name: '삼성전자'),
          fixtureMarketItem(evUpUpdateId,
              eventType: 'CANDIDATE_UPDATED',
              observedAt: '2026-11-02T09:02:41+09:00',
              direction: 'UP',
              rank: 2,
              symbol: '000660',
              dataQuality: 'UNKNOWN',
              name: null),
        ],
        'run': null,
        'runs_present': false,
        'status': null,
      }),
    }));
    await store.bootstrap();
    await pumpTallApp(tester, store);

    // COMPLETE is on the normal whitelist: time only, no suffix.
    expect(find.text('2026-11-02T09:00:05+09:00'), findsOneWidget);
    expect(find.textContaining('· COMPLETE'), findsNothing);
    // UNKNOWN is abnormal: the explicit quality suffix stays, and a
    // missing name record falls back to the symbol.
    expect(find.text('2026-11-02T09:02:41+09:00 · UNKNOWN'), findsOneWidget);
    expect(find.text('000660 (rank 2)'), findsOneWidget);
  });

  testWidgets(
    'opening_ma20 mode labels both lists with the MA20 basis and tags rows',
    (WidgetTester tester) async {
      final store = makeStore(transport: fixtureTransport(extra: {
        '/mobile/market-view': okJson(fixtureMarketViewOpeningMa20),
      }));
      await store.bootstrap();
      await pumpTallApp(tester, store);

      // In opening_ma20 mode the two lists rank the price against the
      // 20-day MA over the opening 30 minutes — not the day's change
      // rate — and the headers say so. Row order and row titles are the
      // server's, unchanged by the mode.
      expect(find.text('상승 TOP 10 (MA20 위)'), findsOneWidget);
      expect(find.text('하락 TOP 10 (MA20 아래)'), findsOneWidget);
      expect(find.text('삼성전자 (rank 1)'), findsOneWidget);
      expect(find.text('삼성전자 (rank 2)'), findsOneWidget);
      expect(find.text('SK하이닉스 (rank 1)'), findsOneWidget);

      // The projection's tag rides as a badge: ABOVE → 'MA20 위',
      // BELOW → 'MA20 아래' — verbatim, never derived in the app.
      expect(find.text('MA20 위'), findsOneWidget);
      expect(find.text('MA20 아래'), findsOneWidget);
      expect(find.byType(Badge), findsNWidgets(2));

      // A null ma20_tag (an out-of-window row) renders no badge: the
      // rank-2 row's trailing is the bare chevron, not a badge row.
      final rank2Tile = tester.widget<ListTile>(
          find.widgetWithText(ListTile, '삼성전자 (rank 2)'));
      expect(rank2Tile.trailing, isA<Icon>());

      // The mode reaches only the top-10 lists: the history tab shows
      // the same rows as in core mode, with no MA20 strings.
      await tester.tap(find.text('히스토리'));
      await tester.pumpAndSettle();
      expect(find.text('TOP10_ENTERED · 삼성전자 · UP #11→7'), findsOneWidget);
      expect(find.textContaining('(MA20'), findsNothing);
      expect(find.byType(Badge), findsNothing);
    },
  );

  testWidgets('no eligible run renders honest absence, not fake content',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport(extra: {
      '/mobile/market-view': okJson({
        'as_of': null,
        'falling_top10': <Object?>[],
        'history': <Object?>[],
        'latest': null,
        'mode': 'core',
        'rising_top10': <Object?>[],
        'run': null,
        'runs_present': false,
        'status': null,
      }),
    }));
    await store.bootstrap();
    await pumpTallApp(tester, store);

    // runs_present:false / run:null — no eligible run recorded renders as
    // per-section "기록 없음", never as zero-filled rows.
    expect(find.text('상승 TOP 10 기록 없음'), findsOneWidget);
    expect(find.text('하락 TOP 10 기록 없음'), findsOneWidget);
    await tester.tap(find.text('히스토리'));
    await tester.pumpAndSettle();
    expect(find.text('변화 기록 없음'), findsOneWidget);
    // Nothing recorded, so no ranked rows anywhere.
    expect(find.text('삼성전자 (rank 1)'), findsNothing);
    expect(find.text('TOP10_ENTERED · 삼성전자 · UP #11→7'), findsNothing);
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
