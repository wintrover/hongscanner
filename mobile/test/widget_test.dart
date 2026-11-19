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
      // rank, the recorded stock name as the title. The label names the
      // rank's source (the vendor's full-market rank), never this
      // projection's list position.
      expect(find.text('삼성전자 (전체 1위)'), findsOneWidget);
      expect(find.text('삼성전자 (전체 2위)'), findsOneWidget);
      expect(find.text('SK하이닉스 (전체 1위)'), findsOneWidget);
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
      expect(find.textContaining('(전체 0위'), findsNothing);
      // Conditional quality: INCOMPLETE stays explicit per item, never
      // flattened to normal.
      expect(find.text('2026-11-02T09:03:30+09:00 · INCOMPLETE'),
          findsOneWidget);

      // Tab switches read the single store — no refetch.
      await tester.tap(find.text('후보'));
      await tester.pumpAndSettle();
      expect(find.text('삼성전자 (전체 1위)'), findsOneWidget);
      expect(store.syncCount, 1);
    },
  );

  testWidgets('core mode shows the general TOP10 banner, not the opening label',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport());
    await store.bootstrap();
    await pumpTallApp(tester, store);

    // The server decides the mode; the banner names its projection and
    // separates the decision clock (mode_as_of) from the recorded data
    // clock (data_as_of). Core mode is never labeled as the opening MA20
    // ranking.
    expect(find.text('일반 TOP10'), findsOneWidget);
    expect(find.text('판정 15:30:58 · 데이터 15:30:58'), findsOneWidget);
    expect(find.text('개장 MA20 순위'), findsNothing);
    expect(find.textContaining('(MA20'), findsNothing);
  });

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
    expect(find.text('000660 (전체 2위)'), findsOneWidget);
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
      expect(find.text('삼성전자 (전체 1위)'), findsOneWidget);
      expect(find.text('삼성전자 (전체 2위)'), findsOneWidget);
      expect(find.text('SK하이닉스 (전체 1위)'), findsOneWidget);

      // The projection's tag rides as a badge: ABOVE → 'MA20 위',
      // BELOW → 'MA20 아래' — verbatim, never derived in the app.
      expect(find.text('MA20 위'), findsOneWidget);
      expect(find.text('MA20 아래'), findsOneWidget);
      expect(find.byType(Badge), findsNWidgets(2));

      // A null ma20_tag (an out-of-window row) renders no badge: the
      // rank-2 row's trailing is the bare chevron, not a badge row.
      final rank2Tile = tester.widget<ListTile>(
          find.widgetWithText(ListTile, '삼성전자 (전체 2위)'));
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
    expect(find.text('삼성전자 (전체 1위)'), findsNothing);
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

  testWidgets('banner derives staleness and the data date from the payload',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport(extra: {
      '/mobile/market-view': okJson({
        ...fixtureMarketView,
        'mode_as_of': '2026-11-19T09:05:00+09:00',
        'data_as_of': '2026-11-18T15:30:00+09:00',
      }),
    }));
    await store.bootstrap();
    await pumpTallApp(tester, store);

    // 17h35m behind the decision clock, and the recorded data is from the
    // previous calendar day: the banner must say both, from the payload's
    // two timestamps only.
    expect(
        find.text('판정 09:05:00 · 데이터 11-18 15:30:00 · 1055분 지연'),
        findsOneWidget);
  });

  testWidgets('a failed poll keeps the rows and shows the retained-data badge',
      (WidgetTester tester) async {
    var down = false;
    final healthy = fixtureTransport();
    final store = makeStore(transport: FakeTransport((uri) async {
      if (down) throw Exception('connection refused');
      return healthy.get(uri);
    }));
    await store.bootstrap();
    await pumpTallApp(tester, store);
    expect(find.text('삼성전자 (전체 1위)'), findsOneWidget);

    down = true;
    await store.resync();
    await tester.pump();

    // The last successful projection stays on screen; the failure rides
    // beside it as the existing offline card, not as a blank list.
    expect(find.text('삼성전자 (전체 1위)'), findsOneWidget);
    expect(find.text('오프라인'), findsWidgets);
    expect(find.textContaining('마지막 데이터를 표시 중'), findsWidgets);
    expect(find.textContaining('기록을 읽는 중'), findsNothing);
  });
}
