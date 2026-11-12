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
/// the routing contract. Three shapes: a single event
/// (`{event_id, event_type, severity, …}` — docs plan PR-6 dispatcher),
/// an immediate ≥2-event summary (`kind="summary"`, `event_ids`,
/// `count`) and a silent digest roll-up (`kind="digest"`, `event_ids`,
/// `count`) — all values strings on the wire, `event_ids` a
/// comma-joined 64-hex list. Tap routing keys on the payload shape: an
/// `event_id` routes to the event detail, a cover list routes to the
/// digest list view. The notification title/body are the dispatcher's
/// own assembled strings — the app treats them as opaque display text
/// (passed verbatim to the OS market-alert post) and never re-derives
/// or overrides them.
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

  /// The dispatcher's message kind: "summary" (immediate, ≥2 events,
  /// sound), "digest" (silent roll-up) — absent or "single" on the
  /// per-event message. Routing keys on the payload shape (event_id vs
  /// event_ids), not on this label; it picks the OS channel and the
  /// dedup unit.
  String? get kind {
    final value = data['kind'];
    return value is String ? value : null;
  }

  /// The covered event ids of a summary/digest message: the dispatcher
  /// sends them as one comma-joined 64-hex string. Null on single
  /// messages; a non-string or empty value degrades to null — never
  /// throws, never invents ids.
  List<String>? get eventIds {
    final value = data['event_ids'];
    if (value is! String || value.isEmpty) return null;
    return value.split(',');
  }

  /// The cover-list size the dispatcher recorded, when it sent one.
  /// Data values are strings on the wire ("N"); an unparsable value
  /// stays null — never a guessed count.
  int? get count {
    final value = data['count'];
    return value is String ? int.tryParse(value) : null;
  }

  /// The event id this message is addressed by: the single event's own
  /// `event_id`, or the first covered id of a summary/digest message
  /// (the representative — the same id the notification's tap carries
  /// as `event_id`).
  String? get representativeEventId {
    final ids = eventIds;
    if (ids != null && ids.isNotEmpty) return ids.first;
    return eventId;
  }

  /// The foreground-alert dedup key: which notification unit this
  /// delivery belongs to. A single event is one unit keyed by its
  /// `event_id`; a summary or digest is one unit per kind + first
  /// covered id, so a re-delivered digest is suppressed while a single
  /// event covered by that digest still surfaces (a different unit).
  /// A cover list without a summary/digest kind is malformed — no unit
  /// key, so nothing dedups against it.
  String? get dedupKey {
    final ids = eventIds;
    if (ids != null && ids.isNotEmpty) {
      final value = kind;
      return (value == 'summary' || value == 'digest')
          ? '$value:${ids.first}'
          : null;
    }
    return eventId;
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
