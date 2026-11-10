import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/api/api_client.dart';
import 'package:hongscanner/api/api_models.dart';

import 'test_kit.dart';

void main() {
  group('ApiClient request building', () {
    test('default base URL targets the emulator host loopback alias', () {
      // Documented default: the API binds 127.0.0.1 only; the emulator
      // reaches the host loopback via 10.0.2.2.
      expect(ApiClient.defaultBaseUrl, 'http://10.0.2.2:8080');
    });

    test('rejects non-origin base URLs', () {
      expect(() => ApiClient(baseUrl: 'not a url'), throwsArgumentError);
      expect(
        () => ApiClient(baseUrl: 'http://10.0.2.2:8080?x=1'),
        throwsArgumentError,
      );
    });

    test('builds the market-view GET path under the base origin', () async {
      final transport = FakeTransport(
          (_) async => okJson(fixtureMarketView));
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080', transport: transport);
      await client.fetchMarketView();
      expect(transport.requests.single.toString(),
          'http://127.0.0.1:8080/mobile/market-view');
      client.close();
      expect(transport.closed, isFalse,
          reason: 'an injected transport is owned by the caller; close() '
              'only closes transports the client created itself');
    });

    test('builds the single-event GET path under the base origin', () async {
      Uri? captured;
      final transport = FakeTransport((uri) async {
        captured = uri;
        return okJson({'delivery': <Object?>[], 'event': evUpEnter});
      });
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080', transport: transport);
      await client.fetchEvent(evUpEnterId);
      expect(captured!.toString(), 'http://127.0.0.1:8080/events/$evUpEnterId');
    });
  });

  group('ApiClient identifier validation (server rules, client-side)', () {
    test('non-hex event id is refused before any request', () async {
      final transport = FakeTransport((_) async => okJson(fixtureMarketView));
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080', transport: transport);
      await expectLater(
        client.fetchEvent('../../etc/passwd'),
        throwsA(isA<ApiClientException>()
            .having((e) => e.code, 'code', ApiErrorCode.invalidIdentifier)),
      );
      expect(transport.requests, isEmpty,
          reason: 'invalid identifiers must not reach the wire');
    });

    test('uppercase or short event id is refused', () async {
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:8080',
        transport: FakeTransport((_) async => okJson(fixtureMarketView)),
      );
      for (final bad in ['ABC', 'a' * 63, 'A' * 64]) {
        await expectLater(
          client.fetchEvent(bad),
          throwsA(isA<ApiClientException>()),
          reason: bad,
        );
      }
    });
  });

  group('ApiClient response parsing (contract shapes)', () {
    Future<MarketViewResponse> fetchFixture() async => ApiClient(
        baseUrl: 'http://127.0.0.1:8080',
        transport: fixtureTransport()).fetchMarketView();

    test('fetchMarketView parses the projection blocks', () async {
      final marketView = await fetchFixture();
      expect(marketView.asOf, '2026-11-02T15:30:58+09:00');
      expect(marketView.runsPresent, isTrue);
      expect(marketView.run?.session, fixtureSession);
      expect(marketView.run?.sessionDate, '2026-11-02');
      expect(marketView.run?.runId, 'run-2026-11-02-1');
      expect(marketView.run?.startedAt, '2026-11-02T09:00:00+09:00');
      expect(marketView.risingTop10, hasLength(2));
      expect(marketView.fallingTop10.single.symbol, '000660');
      expect(marketView.fallingTop10.single.direction, 'DOWN');
      expect(marketView.fallingTop10.single.rank, 1);
      expect(marketView.history, hasLength(4));
      expect(marketView.latest?.eventId, evDownExitId);
      expect(marketView.latest?.eventType, 'CANDIDATE_EXITED');
      expect(marketView.status?.byDataQuality,
          {'INCOMPLETE': 1, 'OBSERVING': 3});
    });

    test('mode and ma20_tag parse as the projection recorded them',
        () async {
      final marketView = await fetchFixture();
      expect(marketView.mode, 'core',
          reason: 'the recorded mode parses verbatim');
      expect(marketView.risingTop10.first.ma20Tag, isNull,
          reason: 'core-mode rows carry no tag — honest absence');

      final opening = await ApiClient(
        baseUrl: 'http://127.0.0.1:8080',
        transport: FakeTransport(
            (_) async => okJson(fixtureMarketViewOpeningMa20)),
      ).fetchMarketView();
      expect(opening.mode, 'opening_ma20');
      expect(opening.risingTop10.first.ma20Tag, 'ABOVE');
      expect(opening.fallingTop10.single.ma20Tag, 'BELOW');
      expect(opening.risingTop10.last.ma20Tag, isNull,
          reason: 'an out-of-window row carries ma20_tag:null');

      expect(MarketViewResponse.fromMap(const {}).mode, 'core',
          reason: 'a missing mode key keeps the core display — never a '
              'fabricated opening_ma20 reading');
    });

    test('history keeps the server order (oldest→newest), change kinds',
        () async {
      final marketView = await fetchFixture();
      expect(marketView.history.map((i) => i.eventId).toList(),
          [evUpEnterId, evDownEnterId, evUpUpdateId, evDownExitId]);
      expect(
        marketView.history.map((i) => i.changeType ?? '').toList(),
        everyElement(isIn(const [
          'TOP10_ENTERED',
          'TOP10_EXITED',
          'CANDIDATE_EXITED',
          'RANK_CHANGED',
        ])),
        reason: 'the server sends change records only — the client must '
            'not need to filter',
      );
    });

    test('rank null on CANDIDATE_EXITED history items — absence kept',
        () async {
      final marketView = await fetchFixture();
      final exited = marketView.history.last;
      expect(exited.changeType, 'CANDIDATE_EXITED');
      expect(exited.rank, isNull,
          reason: 'honest absence, never coerced to 0');
      expect(exited.dataQuality, 'INCOMPLETE');
      expect(marketView.history.first.rank, 7,
          reason: 'ranked change records keep the new rank');
      expect(marketView.history.first.prevRank, 11,
          reason: 'prev_rank parses as the previous recorded rank');
      expect(exited.prevRank, 3,
          reason: 'the EXITED row keeps its previous-group rank');
    });

    test('name parses as recorded: value, JSON null, and key absence',
        () async {
      final marketView = await fetchFixture();
      expect(marketView.risingTop10.first.name, '삼성전자',
          reason: 'a recorded name parses as-is');
      expect(marketView.fallingTop10.single.name, 'SK하이닉스');
      expect(marketView.history.last.name, isNull,
          reason: 'name:null on the EXITED row — honest absence; the UI '
              'falls back to the symbol, never a blank title');
      expect(MarketViewItem.fromMap(const {'event_id': 'x'}).name, isNull,
          reason: 'an item without the name key reads as absence too');
      expect(MarketViewItem.fromMap(const {'event_id': 'x'}).prevRank,
          isNull,
          reason: 'an item without the prev_rank key reads as absence '
              'too — no prior state');
    });

    test('null absence semantics: no run, no status, no as_of', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport((_) async => okJson({
                'as_of': null,
                'falling_top10': <Object?>[],
                'history': <Object?>[],
                'latest': null,
                'rising_top10': <Object?>[],
                'run': null,
                'runs_present': false,
                'status': null,
              })));
      final marketView = await client.fetchMarketView();
      expect(marketView.runsPresent, isFalse);
      expect(marketView.run, isNull,
          reason: 'run:null = no eligible run recorded, '
              'not a zero-filled run');
      expect(marketView.asOf, isNull);
      expect(marketView.status, isNull);
      expect(marketView.latest, isNull);
      expect(marketView.history, isEmpty);
      expect(marketView.risingTop10, isEmpty);
      expect(marketView.fallingTop10, isEmpty);
    });

    test('fetchEvent returns fact plus its delivery records', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: fixtureTransport());
      final detail = await client.fetchEvent(evUpEnterId);
      expect(detail.event.eventType, 'CANDIDATE_ENTERED');
      expect(detail.event.direction, 'UP');
      expect(detail.event.evidenceRef, 'ka10027:stex_tp=1:sort_tp=1');
      expect(detail.event.rank, 1);
      expect(detail.delivery.single.deviceId, 'dev-1');
    });
  });

  group('ApiClient fail-closed errors', () {
    test('404 not_found carries status and server code', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: fixtureTransport());
      try {
        await client.fetchEvent('0' * 64);
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.statusCode, 404);
        expect(e.serverCode, 'not_found');
        expect(e.isConnectivityProblem, isFalse);
      }
    });

    test('500 data_fault is a server fault, not offline', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport(
              (_) async => errorJson(500, 'data_fault', 'ledger line 3 is bad JSON')));
      try {
        await client.fetchMarketView();
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.statusCode, 500);
        expect(e.serverCode, 'data_fault');
        expect(e.isConnectivityProblem, isFalse);
      }
    });

    test('socket failure classifies as network (offline)', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport(
              (_) async => throw const SocketFailure()));
      try {
        await client.fetchMarketView();
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.code, ApiErrorCode.network);
        expect(e.isConnectivityProblem, isTrue);
      }
    });

    test('non-JSON body classifies as format error', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport((_) async => TransportResponse(
              statusCode: 200, body: utf8.encode('<html>502</html>'))));
      try {
        await client.fetchMarketView();
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.code, ApiErrorCode.format);
      }
    });

    test('error body without error object still yields http code', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport((_) async =>
              TransportResponse(statusCode: 503, body: utf8.encode('{"x":1}\n'))));
      try {
        await client.fetchMarketView();
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.code, ApiErrorCode.http);
        expect(e.statusCode, 503);
        expect(e.serverCode, isNull);
      }
    });
  });
}

class SocketFailure implements Exception {
  const SocketFailure();
}
