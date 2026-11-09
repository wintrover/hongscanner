import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_models.dart';
import 'credentials.dart';

/// Transport abstraction so tests can fake the wire without sockets.
abstract class HttpTransport {
  Future<TransportResponse> get(Uri uri, {Map<String, String>? headers});

  void close();
}

class TransportResponse {
  const TransportResponse({required this.statusCode, required this.body});

  final int statusCode;
  final List<int> body;
}

/// Production transport over dart:io HttpClient. The API server closes the
/// connection after each response (contract §2); HttpClient handles that
/// per request.
class IoHttpTransport implements HttpTransport {
  IoHttpTransport() : _client = HttpClient();

  final HttpClient _client;
  bool _closed = false;

  @override
  Future<TransportResponse> get(Uri uri,
      {Map<String, String>? headers}) async {
    if (_closed) throw StateError('transport closed');
    final request = await _client.getUrl(uri);
    headers?.forEach(request.headers.set);
    final response = await request.close();
    final body = <int>[];
    await for (final chunk in response) {
      body.addAll(chunk);
    }
    return TransportResponse(statusCode: response.statusCode, body: body);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

/// Why a fetch failed. The UI must be able to tell "the server answered
/// and refused" (http/data faults) from "no connection" (timeout/network) —
/// conflating them would hide offline state behind a fake empty record.
enum ApiErrorCode {
  invalidIdentifier,
  timeout,
  network,
  http,
  format,
}

class ApiClientException implements Exception {
  ApiClientException(this.code, this.message, {this.statusCode, this.serverCode});

  final ApiErrorCode code;
  final String message;
  final int? statusCode;

  /// `error.code` from the API's JSON error body (e.g. not_found,
  /// data_fault), when the server answered with its documented shape.
  final String? serverCode;

  bool get isConnectivityProblem =>
      code == ApiErrorCode.timeout || code == ApiErrorCode.network;

  @override
  String toString() =>
      'ApiClientException(${code.name}${statusCode == null ? '' : ' $statusCode'}): $message';
}

/// Typed client for the VS-3 read-only API (tools/api/README.md).
///
/// GET-only, like the server. The client validates identifiers with the
/// same rules the server applies (§5.3) before building any path — a bad
/// id fails here first, never as a surprising 404 for a different reason.
/// Read-only by construction: there is no method on this class that sends
/// anything but GET.
class ApiClient {
  ApiClient({
    required String baseUrl,
    HttpTransport? transport,
    this.timeout = const Duration(seconds: 5),
    this.authCredentials,
  })  : _transport = transport ?? IoHttpTransport(),
        _ownsTransport = transport == null {
    final base = Uri.tryParse(baseUrl);
    if (base == null ||
        !base.hasScheme ||
        base.userInfo.isNotEmpty ||
        base.queryParameters.isNotEmpty ||
        (base.path.isNotEmpty && base.path != '/')) {
      throw ArgumentError.value(
          baseUrl, 'baseUrl', 'must be a plain http(s) origin');
    }
    _base = base.replace(path: base.path.endsWith('/') && base.path != '/'
        ? base.path
        : '${base.path}/');
  }

  /// Base URL for the API. The server binds 127.0.0.1 only (contract §5 —
  /// there is no remote exposure), so the default targets the Android
  /// emulator loopback alias `10.0.2.2`, where `adb reverse` is not
  /// needed. Physical devices use `adb reverse tcp:<port> tcp:<port>`
  /// and `--dart-define=HS_API_BASE=http://127.0.0.1:<port>`. Remote
  /// exposure of the API is explicitly out of scope (contract §7).
  factory ApiClient.fromEnvironment() =>
      ApiClient(baseUrl: defaultBaseUrl);

  static const String defaultBaseUrl = String.fromEnvironment(
    'HS_API_BASE',
    defaultValue: 'http://10.0.2.2:8080',
  );

  static final RegExp eventIdPattern = RegExp(r'^[0-9a-f]{64}$');

  late final Uri _base;
  final HttpTransport _transport;
  final bool _ownsTransport;
  final Duration timeout;

  /// Current Basic-auth credential pair, or null when the client is used
  /// without authentication (the local, unexposed API). Sent as
  /// `Authorization: Basic …` on every request; replaced when the
  /// operator re-enters credentials after a 401.
  Credentials? authCredentials;

  void close() {
    if (_ownsTransport) _transport.close();
  }

  Future<Map<String, Object?>> _getJson(
    String path,
    Map<String, String> query,
  ) async {
    final uri = _base.replace(
      path: '${_base.path}$path',
      queryParameters: query.isEmpty ? null : query,
    );
    final credentials = authCredentials;
    TransportResponse response;
    try {
      response = await _transport
          .get(
            uri,
            headers: credentials == null
                ? null
                : {
                    HttpHeaders.authorizationHeader:
                        credentials.authorizationHeader,
                  },
          )
          .timeout(timeout);
    } on TimeoutException {
      throw ApiClientException(ApiErrorCode.timeout,
          'timed out after ${timeout.inSeconds}s: ${uri.path}');
    } on SocketException catch (e) {
      throw ApiClientException(
          ApiErrorCode.network, 'network error: ${e.osError?.errorCode ?? e.message}');
    } on HttpException catch (e) {
      throw ApiClientException(ApiErrorCode.network, 'http error: ${e.message}');
    } on Exception catch (e) {
      // Unwrapping the transport layers would misclassify honest failures.
      throw ApiClientException(ApiErrorCode.network, 'connection failed: $e');
    }
    if (response.statusCode == 401) {
      // Basic-auth refusal. The 401 body from an authenticating front
      // (e.g. the Northflank ingress) is not the API's JSON error shape,
      // so it is classified here, before any JSON decode, and never
      // masquerades as a format error.
      throw ApiClientException(
        ApiErrorCode.http,
        'HTTP 401: authentication required',
        statusCode: 401,
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.body, allowMalformed: false));
    } on FormatException {
      throw ApiClientException(ApiErrorCode.format,
          'response body is not JSON (status ${response.statusCode})');
    }
    if (decoded is! Map<String, Object?>) {
      throw ApiClientException(ApiErrorCode.format,
          'response body is not a JSON object (status ${response.statusCode})');
    }
    if (response.statusCode != 200) {
      final error = decoded['error'];
      final errorMap = error is Map<String, Object?> ? error : const {};
      final serverCode =
          errorMap['code'] is String ? errorMap['code'] as String : null;
      throw ApiClientException(
        ApiErrorCode.http,
        serverCode == null
            ? 'unexpected HTTP ${response.statusCode}'
            : 'HTTP ${response.statusCode}: $serverCode',
        statusCode: response.statusCode,
        serverCode: serverCode,
      );
    }
    return decoded;
  }

  /// `GET /mobile/market-view` — the single bounded projection for the
  /// phone: rising/falling top 10, the retained candidate-event history
  /// (≤100, oldest→newest), and the run/as_of context. The server
  /// projection is authoritative; this client never recomputes ranks or
  /// refilters events into candidates.
  Future<MarketViewResponse> fetchMarketView() async =>
      MarketViewResponse.fromMap(
          await _getJson('mobile/market-view', const {}));

  /// `GET /events/{event_id}` — one fact plus its delivery records.
  /// Throws [ApiClientException] with `statusCode == 404` when the id is
  /// not in the ledger; the UI must show that honestly, not as empty.
  Future<EventDetailResponse> fetchEvent(String eventId) async {
    if (!eventIdPattern.hasMatch(eventId)) {
      throw ApiClientException(ApiErrorCode.invalidIdentifier,
          'event_id must be 64 lowercase hex digits');
    }
    return EventDetailResponse.fromMap(
        await _getJson('events/$eventId', const {}));
  }
}
