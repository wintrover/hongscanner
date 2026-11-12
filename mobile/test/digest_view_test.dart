import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/api/api_client.dart';
import 'package:hongscanner/main.dart';
import 'package:hongscanner/screens/digest_list_screen.dart';
import 'package:hongscanner/screens/event_detail_screen.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Digest list view tests (the ③ contract): a summary/digest tap gives
/// the operator every covered event — one row per recorded fact, each
/// row the fact's own name/direction/rank-change/observed-time, a row
/// tap opening the existing detail route — with honest loading and
/// error states: a fetch in flight is a skeleton, a failed fetch is a
/// visible error card with a retry, and a partial list is never
/// dressed as complete.
void main() {
  const digestCover = [evTopEnterId, evRankChangeId, evTopExitId];

  testWidgets('rows render the covered facts; a row tap opens the detail',
      (tester) async {
    final store = makeStore(transport: fixtureTransport());
    await store.bootstrap();
    await store.openEvent(evTopEnterId, eventIds: digestCover);
    await tester.pumpWidget(HongScannerApp(store: store));
    await tester.pumpAndSettle();

    expect(find.byType(DigestListScreen), findsOneWidget);
    // One row per covered event — the row count equals the cover list.
    expect(find.byType(ListTile), findsNWidgets(digestCover.length));
    expect(find.text('삼성전자 · UP · 진입'), findsOneWidget);
    expect(find.text('SK하이닉스 · DOWN · 5위 → 2위'), findsOneWidget);
    expect(find.text('삼성전자 · UP · 이탈'), findsOneWidget);
    expect(find.text('2026-11-02T09:07:41+09:00'), findsOneWidget);

    await tester.tap(find.text('SK하이닉스 · DOWN · 5위 → 2위'));
    await tester.pumpAndSettle();
    expect(store.selectedEventId, evRankChangeId);
    expect(find.byType(EventDetailScreen), findsOneWidget);
    expect(find.text('근거 (evidence_ref)'), findsOneWidget);
  });

  testWidgets('loading state while the cover fetches', (tester) async {
    final gate = Completer<TransportResponse>();
    final transport = FakeTransport((uri) async {
      if (uri.path.endsWith('/mobile/market-view')) {
        return okJson(fixtureMarketView);
      }
      return gate.future;
    });
    final store = makeStore(transport: transport);
    await store.bootstrap();
    // Unawaited: the digest fetch is gated, so openEvent suspends on it
    // — exactly the in-flight state the view must render.
    unawaited(store.openEvent(evTopEnterId, eventIds: digestCover));

    await tester.pumpWidget(HongScannerApp(store: store));
    // Zero-duration pumps only — never pumpAndSettle here: the spinner's
    // animation would keep frames scheduled, so settling would advance
    // the fake clock past the API client's 5s timeout and turn this
    // honest loading state into an error before it can be observed.
    // Two frames: the first flushes the pending route, the second builds
    // the pushed screen.
    await tester.pump();
    await tester.pump();
    expect(store.digestEvents.phase, LoadPhase.loading);
    expect(find.byType(DigestListScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('기록을 읽는 중…'), findsOneWidget);
    // No rows yet: the fetch is real, nothing is pre-rendered. Scoped to
    // the digest screen — the shell beneath is still mounted mid-route
    // transition (an opaque route drops it only once the transition
    // completes), and the shell's own rows are not this view's rows.
    expect(
      find.descendant(
        of: find.byType(DigestListScreen),
        matching: find.byType(ListTile),
      ),
      findsNothing,
    );

    // The fetch resolves → every covered event renders.
    gate.complete(okJson({'event': evTopEnter, 'delivery': <Object?>[]}));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(DigestListScreen),
        matching: find.byType(ListTile),
      ),
      findsNWidgets(digestCover.length),
    );
  });

  testWidgets(
      'a failed cover fetch renders the honest error state, never rows',
      (tester) async {
    final transport = FakeTransport((uri) async {
      if (uri.path.endsWith('/mobile/market-view')) {
        return okJson(fixtureMarketView);
      }
      throw Exception('connection refused');
    });
    final store = makeStore(transport: transport);
    await store.bootstrap();
    await store.openEvent(evTopEnterId, eventIds: digestCover);

    await tester.pumpWidget(HongScannerApp(store: store));
    await tester.pumpAndSettle();
    expect(find.byType(DigestListScreen), findsOneWidget);
    expect(find.text('오프라인'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    // Offline is an error state, not a spinner and not fake rows — and
    // never a partial list dressed as complete.
    expect(find.byType(ListTile), findsNothing);
    // Only the digest fetch failed: the projection section is untouched.
    expect(store.marketView.phase, LoadPhase.loaded);

    // The retry re-reads the full cover list (still offline → the
    // visible error stays).
    final eventsBefore =
        transport.requests.where((uri) => uri.path.contains('/events/')).length;
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(
      transport.requests.where((uri) => uri.path.contains('/events/')).length,
      eventsBefore + digestCover.length,
      reason: 'the retry refetches every covered event',
    );
    expect(find.text('오프라인'), findsOneWidget);
  });

  testWidgets('an unknown covered id fails the whole section honestly',
      (tester) async {
    // The cover list is well-formed hex but one id is not in the
    // ledger: its 404 fails the section — the server's own refusal is
    // the visible message, no rows, no invented facts.
    const unknownId =
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
    final store = makeStore(transport: fixtureTransport());
    await store.bootstrap();
    await store.openEvent(
      evTopEnterId,
      eventIds: const [evTopEnterId, unknownId],
    );

    await tester.pumpWidget(HongScannerApp(store: store));
    await tester.pumpAndSettle();
    expect(find.byType(DigestListScreen), findsOneWidget);
    expect(find.text('기록에 없음 (404 not_found)'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing,
        reason: 'a partial list is never shown as complete');
  });
}
