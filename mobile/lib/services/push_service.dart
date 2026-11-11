/// Abstraction over push notification wiring.
///
/// Implementations must fail closed: a service that is not wired reports
/// [isReady] == false and must not pretend that registration succeeded —
/// [requestPermission] answers null ("nothing was asked") instead of a
/// decision that was never made.
library;

/// The decision the platform reported for a notification permission ask.
///
/// Android 13+ makes `denied` ambiguous (user denied vs asked-before),
/// which is why the ask history is persisted separately (see
/// services/push_permission.dart): whether *we* asked is a fact we record,
/// not something the platform can answer.
enum PushPermissionDecision { granted, denied, provisional }

/// One received push message: the data fields the app routes on plus
/// the notification payload's title/body.
///
/// The dispatcher sends notification+data messages; the data payload is
/// the routing contract (`{event_id, event_type, severity}` — docs plan
/// PR-6 dispatcher). Tap routing keys on `event_id`. The notification
/// title/body are the dispatcher's own assembled strings — the app
/// treats them as opaque display text (passed verbatim to the OS
/// market-alert post) and never re-derives or overrides them.
class PushMessage {
  const PushMessage(
    this.data, {
    this.notificationTitle,
    this.notificationBody,
  });

  factory PushMessage.fromData(Map<String, dynamic> data) =>
      PushMessage(Map<String, dynamic>.from(data));

  final Map<String, dynamic> data;

  /// The notification payload's title, as the dispatcher assembled it.
  /// Null on data-only messages.
  final String? notificationTitle;

  /// The notification payload's body, as the dispatcher assembled it.
  /// Null on data-only messages.
  final String? notificationBody;

  String? get eventId {
    final value = data['event_id'];
    return value is String ? value : null;
  }

  String? get eventType {
    final value = data['event_type'];
    return value is String ? value : null;
  }

  String? get severity {
    final value = data['severity'];
    return value is String ? value : null;
  }
}

/// Message-stream capability for a wired push service.
///
/// Kept separate from [PushService] so the no-wired default never has to
/// fake empty streams: the app only touches these when the installed
/// service both is ready and implements this interface.
///
/// Note: firebase_messaging 17.x no longer exposes `onDeletedMessages`
/// (the FCM deleted-messages Dart callback was removed upstream in the
/// 15.x major). Queue-discard recovery is therefore guaranteed by the
/// startup and foreground-resume resync paths instead of a callback —
/// documented in mobile/README.md.
/// Token-registration capability for a wired push service.
///
/// firebase_messaging 17.x replaced `getToken()`/`onTokenRefresh` with the
/// FID registration APIs (`register()`/`onRegistered`): registration is
/// initiated, then the Firebase Installation ID (FID) arrives
/// asynchronously on the stream — there is no direct "fetch current token"
/// call anymore. Kept separate from [PushService] for the same reason as
/// [PushMessageSource]: the no-wired default never fakes a registration
/// stream.
///
/// The scaffold contract is unchanged: the app only *displays* the
/// identifier; registering it with the server is the operator's
/// `tools/notify/register` CLI step (mobile/README.md).
abstract interface class PushTokenSource {
  /// Initiates FCM registration for this app instance. Completes once
  /// registration has been initiated; the FID itself is delivered via
  /// [onRegistered].
  Future<void> register();

  /// FIDs delivered when registration completes (and whenever the
  /// installation id changes). The value is what the Overview push card
  /// shows the operator — the app has no write path to the server.
  Stream<String> get onRegistered;
}

abstract interface class PushMessageSource {
  /// Messages received while the app is in the foreground. With
  /// notification+data messages the OS does not display the notification
  /// in the foreground (official firebase_messaging behavior); the app
  /// re-posts the server's own title/body to the OS market-alert channel
  /// or falls back to the in-app banner (documented in mobile/README.md
  /// — the app never re-assembles the text itself).
  Stream<PushMessage> get foregroundMessages;

  /// Messages whose notification the user tapped while the app was in the
  /// background (not terminated).
  Stream<PushMessage> get tapMessages;

  /// The message that launched the app from the terminated state (cold
  /// start via notification tap), or null when there was none. Terminated
  /// display itself is the OS notification — the official path; no local
  /// notification re-synthesis happens here.
  Future<PushMessage?> initialMessage();
}

abstract class PushService {
  const PushService();

  /// Whether the underlying push infrastructure is wired and usable.
  bool get isReady;

  /// Requests permission to show notifications.
  ///
  /// Returns the platform's decision, or null when nothing was asked
  /// (service not wired) — never a fabricated decision.
  Future<PushPermissionDecision?> requestPermission();
}
