import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/api/api_client.dart';
import 'package:hongscanner/api/credentials.dart';
import 'package:hongscanner/screens/auth_dialog.dart';
import 'package:hongscanner/services/credential_store.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Basic-auth suite: header generation, header attachment on the wire,
/// the secure credential store, the store's 401 re-entry flow (one prompt,
/// one retry), and the credential dialog itself.
///
/// Contract anchors: credentials live only in the platform's secure store
/// (AGENTS.md §0.3 — never shared_preferences, never logs); a 401 must
/// surface as an honest error unless the operator submits a fresh pair,
/// which triggers exactly one retry. All pairs here are clearly-marked
/// example fixtures — no real credential ever enters the repository.
void main() {
  // The fixture pair used across the suite; the header value is derived,
  // never spelled out as a base64 literal. Values are referenced through
  // these constants everywhere so no password-shaped string literal
  // exists in this file (secret scanners see identifiers, not values).
  const fixtureUser1 = 'example-user';
  const fixtureValue1 = 'example-value-1';
  const fixtureUser2 = 'example-user-2';
  const fixtureValue2 = 'example-value-2';
  const fixtureUserKo = '예시-사용자';
  const fixtureValueKo = '예시-값';
  final fixtureHeader =
      'Basic ${base64Encode(utf8.encode('$fixtureUser1:$fixtureValue1'))}';

  group('Credentials header generation', () {
    test('encodes the pair exactly as RFC 7617 Basic', () {
      const credentials =
          Credentials(username: fixtureUser1, password: fixtureValue1);
      final expected =
          'Basic ${base64Encode(utf8.encode('$fixtureUser1:$fixtureValue1'))}';
      expect(credentials.authorizationHeader, expected);
      expect(credentials.authorizationHeader.startsWith('Basic '), isTrue);
    });

    test('encodes non-ASCII credentials as UTF-8', () {
      const credentials =
          Credentials(username: fixtureUserKo, password: fixtureValueKo);
      expect(
        credentials.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('$fixtureUserKo:$fixtureValueKo'))}',
      );
    });

    test('toString carries neither half of the credential', () {
      const credentials =
          Credentials(username: fixtureUser1, password: fixtureValue1);
      final printed = credentials.toString();
      expect(printed, isNot(contains(fixtureUser1)));
      expect(printed, isNot(contains(fixtureValue1)));
    });

    test('equality keys on both fields', () {
      expect(
        const Credentials(username: fixtureUser1, password: fixtureValue1),
        const Credentials(username: fixtureUser1, password: fixtureValue1),
      );
      expect(
        const Credentials(username: fixtureUser1, password: fixtureValue1),
        isNot(const Credentials(username: fixtureUser1, password: fixtureValue2)),
      );
      expect(
        const Credentials(username: fixtureUser1, password: fixtureValue1),
        isNot(const Credentials(username: fixtureUser2, password: fixtureValue1)),
      );
    });
  });

  group('ApiClient Authorization header', () {
    test('every request carries the Basic header when armed', () async {
      final transport = fixtureTransport();
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:8080',
        transport: transport,
        authCredentials:
            const Credentials(username: fixtureUser1, password: fixtureValue1),
      );
      await client.fetchMarketView();
      await client.fetchEvent(evUpEnterId);
      expect(transport.headersSeen, hasLength(2));
      for (final headers in transport.headersSeen) {
        expect(headers?['authorization'], fixtureHeader);
      }
    });

    test('no header when unarmed (local unexposed API)', () async {
      final transport = fixtureTransport();
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080', transport: transport);
      await client.fetchMarketView();
      expect(transport.headersSeen.single, isNull);
    });

    test('re-arming swaps the header on the next request', () async {
      final transport = fixtureTransport();
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:8080',
        transport: transport,
        authCredentials:
            const Credentials(username: fixtureUser1, password: fixtureValue1),
      );
      await client.fetchMarketView();
      client.authCredentials =
          const Credentials(username: fixtureUser2, password: fixtureValue2);
      await client.fetchEvent(evUpEnterId);
      expect(
        transport.headersSeen.first?['authorization'],
        'Basic ${base64Encode(utf8.encode('$fixtureUser1:$fixtureValue1'))}',
      );
      expect(
        transport.headersSeen.last?['authorization'],
        'Basic ${base64Encode(utf8.encode('$fixtureUser2:$fixtureValue2'))}',
      );
    });

    test('a 401 with a non-JSON body is an auth refusal, not a format error',
        () async {
      // The authenticating front (Northflank ingress) answers 401 with a
      // plain/HTML body that has nothing to do with the API's JSON error
      // shape — classification must happen before any JSON decode.
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:8080',
        transport: FakeTransport((uri) async => TransportResponse(
              statusCode: 401,
              body: utf8.encode('<html>401 Unauthorized</html>'),
            )),
      );
      try {
        await client.fetchMarketView();
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.statusCode, 401);
        expect(e.code, ApiErrorCode.http);
        expect(e.isConnectivityProblem, isFalse);
      }
    });
  });

  group('CredentialStore', () {
    test('memory store round-trips and reads empty as null', () async {
      final store = MemoryCredentialStore();
      expect(await store.load(), isNull);
      const credentials =
          Credentials(username: fixtureUser1, password: fixtureValue1);
      await store.save(credentials);
      expect(await store.load(), credentials);
    });

    test('secure store round-trips through both keys', () async {
      // Mutable: the mock platform writes into this very map.
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final store = SecureCredentialStore();
      expect(await store.load(), isNull);
      const credentials =
          Credentials(username: fixtureUser1, password: fixtureValue1);
      await store.save(credentials);
      expect(await store.load(), credentials);
      final stored = await const FlutterSecureStorage().readAll();
      expect(stored.keys, hasLength(2),
          reason: 'username and password both live in the secure store, '
              'never in shared_preferences');
    });

    test('half a stored pair reads back as null (fail-closed)', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'hs.api.username': fixtureUser1,
      });
      final store = SecureCredentialStore();
      expect(await store.load(), isNull);
    });
  });

  group('AppStore 401 re-entry flow', () {
    /// A server that refuses everything until the exact expected Basic
    /// header arrives, then serves the fixture API.
    FakeTransport authGate({required String expectedHeader}) {
      final inner = fixtureTransport();
      return FakeTransport.withHeaders((uri, [headers]) async {
        if (headers?['authorization'] != expectedHeader) {
          return errorJson(401, 'unauthorized', 'bad or missing credentials');
        }
        return inner.get(uri, headers: headers);
      });
    }

    test('401 prompts once, saves, and the retry loads the projection',
        () async {
      final credentialsStore = MemoryCredentialStore();
      final store = makeStore(
        transport: authGate(expectedHeader: fixtureHeader),
        credentialStore: credentialsStore,
      );
      var prompts = 0;
      await store.bootstrap(onUnauthorized: () async {
        prompts += 1;
        await store.saveCredentials(
            const Credentials(username: fixtureUser1, password: fixtureValue1));
        return true;
      });

      expect(prompts, 1,
          reason: 'one prompt per resync even though the single fetch 401s');
      expect(await credentialsStore.load(),
          const Credentials(username: fixtureUser1, password: fixtureValue1));
      expect(store.marketView.phase, LoadPhase.loaded);
    });

    test('cancel keeps the visible 401 states and never retries', () async {
      final store = makeStore(
          transport: authGate(expectedHeader: fixtureHeader));
      var prompts = 0;
      await store.bootstrap(onUnauthorized: () async {
        prompts += 1;
        return false;
      });

      expect(prompts, 1);
      expect(store.marketView.phase, LoadPhase.error);
      expect(store.marketView.errorMessage, contains('인증 필요 (401)'));
    });

    test('stored credentials cover the next start without any prompt',
        () async {
      final credentialsStore = MemoryCredentialStore();
      await credentialsStore
          .save(const Credentials(username: fixtureUser1, password: fixtureValue1));
      final store = makeStore(
        transport: authGate(expectedHeader: fixtureHeader),
        credentialStore: credentialsStore,
      );
      var prompts = 0;
      await store.bootstrap(onUnauthorized: () async {
        prompts += 1;
        return true;
      });

      expect(prompts, 0,
          reason: '자격증명은 최초 1회 입력 — 저장된 페어가 이후 세션을 커버한다');
      expect(store.marketView.phase, LoadPhase.loaded);
    });

    test('no re-entry callback wired: 401 stays a visible error', () async {
      final store = makeStore(
          transport: authGate(expectedHeader: fixtureHeader));
      await store.bootstrap();

      expect(store.marketView.phase, LoadPhase.error);
      expect(store.marketView.errorMessage, contains('인증 필요 (401)'));
    });

    test('a failing prompt is not a retry trigger (fail-closed)', () async {
      final store = makeStore(
          transport: authGate(expectedHeader: fixtureHeader));
      var prompts = 0;
      await store.bootstrap(onUnauthorized: () async {
        prompts += 1;
        throw StateError('dialog path failed');
      });

      expect(prompts, 1);
      expect(store.marketView.phase, LoadPhase.error);
      expect(store.marketView.errorMessage, contains('인증 필요 (401)'));
    });
  });

  group('Credential dialog', () {
    Future<void> openDialog(WidgetTester tester,
        void Function(Credentials? credentials) onResult) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  onResult(await showCredentialPrompt(context));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('fields gate the save button; submit returns the pair',
        (tester) async {
      Credentials? result;
      await openDialog(tester, (credentials) => result = credentials);

      final saveButton = find.widgetWithText(TextButton, '저장하고 재시도');
      // Disabled while either field is empty.
      expect(tester.widget<TextButton>(saveButton).onPressed, isNull);

      await tester.enterText(find.byType(TextField).at(0), fixtureUser1);
      await tester.enterText(find.byType(TextField).at(1), fixtureValue1);
      await tester.pump();

      // The password field obscures its text.
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).obscureText,
        isTrue,
      );
      expect(tester.widget<TextButton>(saveButton).onPressed, isNotNull);

      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(result,
          const Credentials(username: fixtureUser1, password: fixtureValue1));
    });

    testWidgets('cancel returns null (no invented credentials)',
        (tester) async {
      Credentials? result;
      await openDialog(tester, (credentials) => result = credentials);

      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });
}
