import 'package:flutter/services.dart';

import 'push_service.dart';

/// The Android market-alert path: the `hongscanner/market_alert` method
/// channel, whose platform end is MainActivity.kt.
///
/// Why it exists: firebase_messaging delivers foreground notification
/// messages to Dart only — the OS does not display them — and taps on
/// locally posted notifications never arrive through FCM's
/// `getInitialMessage`/`onMessageOpenedApp`. The channel carries:
///
/// * `postNotification` (Dart → platform) — re-posts a foreground
///   message's **server-assembled** notification title/body (dispatcher:
///   tools/notify) to an OS channel: `market_rank_changes` (sound) for
///   per-event and summary posts, `market_rank_digest` (silent) for
///   digest roll-ups. The app is a display courier: it never
///   re-assembles, re-computes or re-judges the text (M15 — the app
///   projects; the server decides).
/// * `getPendingTap` (Dart → platform) — the one-shot tap payload of a
///   local-notification that launched the app, consumed once at startup.
/// * `onNotificationTap` (platform → Dart) — a tap on a locally posted
///   notification while the app is running.
///
/// Fail-closed contract: no method throws. A refused or failed post
/// answers false (the caller falls back to the in-app banner), a
/// missing platform end (tests, non-Android platforms) answers
/// false/null — no notification, no invented route. Taps the Dart side
/// cannot acknowledge stay pending on the platform side and are
/// consumed by the next `getPendingTap` (the handshake documented in
/// MainActivity.kt).
class MarketAlertChannel {
  const MarketAlertChannel();

  /// The channel MainActivity.kt binds its platform handler to. Tests
  /// intercept outgoing calls on this name via
  /// TestDefaultBinaryMessengerBinding.
  static const MethodChannel channel =
      MethodChannel('hongscanner/market_alert');

  /// The silent OS channel for digest roll-ups (created by
  /// MainActivity.kt alongside the sound `market_rank_changes` channel).
  /// Null/absent channelId on a post means the sound channel — the
  /// pre-digest default, kept for compatibility.
  static const String digestChannelId = 'market_rank_digest';

  /// The event_type vocabulary routed to the OS market-alert channel:
  /// the TOP10 state-change notifications, dispatched with a
  /// server-assembled title/body. Anything else keeps the in-app banner
  /// policy.
  static const Set<String> marketEventTypes = {
    'TOP10_ENTERED',
    'TOP10_EXITED',
    'RANK_CHANGED',
  };

  /// The dispatcher message kinds routed to the OS market-alert
  /// channels: `summary` (immediate ≥2 events, sound channel) and
  /// `digest` (silent roll-up, digest channel). A single-event message
  /// (kind absent or "single") is judged by [marketEventTypes] as
  /// before.
  static const Set<String> marketKinds = {'summary', 'digest'};

  /// Whether [message] is a market alert the OS channel should display:
  /// a TOP10 state-change event — or a summary/digest cover list —
  /// whose server-assembled title and body both arrived. A market
  /// message with missing text is **not** postable — the caller falls
  /// back to the banner instead of re-assembling the text (the app
  /// never computes what the server should have said). A summary or
  /// digest without its cover list is not postable either: the tap
  /// contract (the list view of every covered event) cannot be
  /// fulfilled, and degrading it to a single-event tap would hide
  /// events.
  static bool isMarketAlert(PushMessage message) {
    if (marketKinds.contains(message.kind)) {
      return (message.eventIds?.isNotEmpty ?? false) &&
          message.notificationTitle != null &&
          message.notificationBody != null;
    }
    return message.eventId != null &&
        marketEventTypes.contains(message.eventType) &&
        message.notificationTitle != null &&
        message.notificationBody != null;
  }

  /// Posts the dispatcher's own title/body as an OS notification.
  /// [eventId] is the message's routing id (the event's own id, or the
  /// first covered id of a summary/digest — the representative). A null
  /// [channelId] means the sound `market_rank_changes` channel;
  /// [MarketAlertChannel.digestChannelId] routes the post to the silent
  /// digest channel. [kind] and [eventIds] (comma-joined cover list)
  /// carry the message unit: a summary/digest post gets a stable
  /// per-kind notification id (never colliding with a single event's)
  /// and keeps the cover list in the notification's tap intent, so the
  /// tap routes to the list view. Answers false when the platform
  /// refuses or cannot post (POST_NOTIFICATIONS off, notifications
  /// disabled, missing arguments, a channel this app never created, no
  /// platform end) — never throws, so the foreground message path
  /// always has its banner fallback.
  Future<bool> postNotification({
    required String eventId,
    required String title,
    required String body,
    String? channelId,
    String? kind,
    String? eventIds,
  }) async {
    try {
      final posted = await channel.invokeMethod<bool>('postNotification', {
        'eventId': eventId,
        'title': title,
        'body': body,
        'channelId': ?channelId,
        'kind': ?kind,
        'eventIds': ?eventIds,
      });
      return posted ?? false;
    } on Object {
      return false;
    }
  }

  /// The one-shot local-notification tap that launched the app, or null
  /// when there was none. The answer clears the platform-side copy; a
  /// null never invents a route.
  Future<MarketAlertTap?> getPendingTap() async {
    try {
      return MarketAlertTap.fromArguments(
        await channel.invokeMethod<dynamic>('getPendingTap'),
      );
    } on Object {
      return null;
    }
  }

  /// Registers the live tap path for notifications tapped while the app
  /// is running. The handler replies `true` — the acknowledgement
  /// MainActivity.kt uses to clear its pending copy (one tap routes
  /// exactly once).
  void setTapHandler(void Function(MarketAlertTap tap) onTap) {
    channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onNotificationTap') {
        final tap = MarketAlertTap.fromArguments(call.arguments);
        if (tap != null) {
          onTap(tap);
          return true;
        }
      }
      return null;
    });
  }

  /// Removes the tap handler (the shell's dispose path). Taps arriving
  /// afterwards stay pending on the platform side and are routed by the
  /// next [getPendingTap].
  void clearTapHandler() {
    channel.setMethodCallHandler(null);
  }
}

/// One local-notification tap: the representative event id plus, on a
/// summary/digest notification, the full cover list the platform side
/// kept in the tap intent.
class MarketAlertTap {
  const MarketAlertTap({required this.eventId, this.eventIds});

  /// Parses the platform's tap arguments (`event_id`, optional
  /// comma-joined `event_ids`). Answers null when the arguments carry
  /// no usable id — never an invented route.
  static MarketAlertTap? fromArguments(Object? arguments) {
    if (arguments is! Map) return null;
    final eventId = arguments['event_id'];
    if (eventId is! String || eventId.isEmpty) return null;
    final eventIds = arguments['event_ids'];
    return MarketAlertTap(
      eventId: eventId,
      eventIds: eventIds is String && eventIds.isNotEmpty
          ? eventIds.split(',')
          : null,
    );
  }

  /// The representative event id: the single event's own id, or the
  /// first covered id of a summary/digest notification.
  final String eventId;

  /// The covered event ids of a summary/digest tap; null on a
  /// single-event tap.
  final List<String>? eventIds;
}
