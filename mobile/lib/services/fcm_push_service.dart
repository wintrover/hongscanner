import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'push_service.dart';

/// FCM-backed [PushService].
///
/// Fail-closed by construction: with no Firebase project there is no
/// google-services.json and no Firebase.initializeApp, so [isReady] is
/// false and every call throws [StateError] instead of reporting success.
/// The app ships with [NoopPushService] until the Firebase handoff
/// (mobile/README.md) swaps the composition point.
///
/// Token acquisition uses the firebase_messaging 17.x FID registration
/// APIs: [register] initiates registration and the Firebase Installation
/// ID arrives on [onRegistered] ([PushTokenSource]) — the deprecated
/// `getToken()`/`onTokenRefresh` surface is not used.
class FcmPushService implements PushService, PushMessageSource, PushTokenSource {
  const FcmPushService();

  bool get _wired => Firebase.apps.isNotEmpty;

  Never _throwUnwired() => throw StateError(
    'FcmPushService is not wired: Firebase.initializeApp / google-services '
    'setup has not been done yet. See mobile/README.md.',
  );

  @override
  bool get isReady => _wired;

  @override
  Future<void> register() {
    if (!_wired) _throwUnwired();
    return _messaging.register();
  }

  @override
  Stream<String> get onRegistered {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.instance.onRegistered;
  }

  @override
  Future<PushPermissionDecision?> requestPermission() {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.instance.requestPermission().then(
      (settings) => switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized => PushPermissionDecision.granted,
        AuthorizationStatus.denied => PushPermissionDecision.denied,
        // Permanent denial is still a denial — recorded as such; the
        // Overview card stays honest and the OS will not re-prompt.
        AuthorizationStatus.deniedPermanently => PushPermissionDecision.denied,
        // No recorded decision: the store keeps the ask history but the
        // phase stays "unknown" instead of inventing an answer.
        AuthorizationStatus.notDetermined => null,
        AuthorizationStatus.provisional => PushPermissionDecision.provisional,
      },
    );
  }

  /// Pure mapping from the plugin type to our [PushMessage]. Static and
  /// dependency-free so tests can exercise it with constructed
  /// [RemoteMessage] stubs — no Firebase init needed. The notification
  /// title/body pass through verbatim (the dispatcher's assembled text —
  /// the app never re-assembles it).
  static PushMessage messageFromRemote(RemoteMessage message) => PushMessage(
        Map<String, dynamic>.from(message.data),
        notificationTitle: message.notification?.title,
        notificationBody: message.notification?.body,
      );

  FirebaseMessaging get _messaging {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.instance;
  }

  @override
  Stream<PushMessage> get foregroundMessages {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.onMessage.map(messageFromRemote);
  }

  @override
  Stream<PushMessage> get tapMessages {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.onMessageOpenedApp.map(messageFromRemote);
  }

  @override
  Future<PushMessage?> initialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : messageFromRemote(message);
  }
}
