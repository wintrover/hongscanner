package com.hongscanner.hongscanner

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Hosts the platform end of the `hongscanner/market_alert` method
/// channel (the Dart end: lib/services/market_alert_channel.dart).
///
/// Channel handshake — a delivered tap is never lost and never
/// acknowledged twice:
/// * A notification tap that launches the app (cold start) is read from
///   the launch intent here and kept in [pendingTapEventId] (plus
///   [pendingTapEventIds], the cover list of a summary/digest
///   notification); the Dart side consumes it once with
///   `getPendingTap`.
/// * A tap while the app runs arrives via [onNewIntent]: the ids are
///   kept pending and `onNotificationTap` is invoked on the channel.
///   The Dart handler replies `true` when it routed the tap — that
///   acknowledgement clears the pending copy. No handler (Dart side not
///   wired yet, or the message dropped) keeps the ids pending for the
///   next `getPendingTap`. (An Activity recreation may re-deliver the
///   launch intent — plain Android task semantics; the Dart side's
///   openEvent is idempotent: same selection, reused route.)
///
/// A tap intent carries `event_id` (the representative — the single
/// event's own id, or the first covered id of a summary/digest) and,
/// on a summary/digest post, `event_ids` (the comma-joined cover list):
/// the Dart side routes a cover list to the digest list view, a bare
/// event id to the event detail.
///
/// Foreground FCM notification messages are delivered to Dart only (the
/// OS does not display them — official firebase_messaging behavior), so
/// `postNotification` re-posts the dispatcher's own title/body to the
/// OS: the sound `market_rank_changes` channel for per-event and
/// summary posts, the silent `market_rank_digest` channel for digest
/// roll-ups — display delivery only, no text is assembled or altered on
/// this side either.
class MainActivity : FlutterActivity() {

    private var marketAlertChannel: MethodChannel? = null

    /// One-shot: the representative event id of a local-notification
    /// tap the Dart side has not acknowledged yet. Consumed by
    /// `getPendingTap`.
    private var pendingTapEventId: String? = null

    /// One-shot with the same lifetime: the comma-joined cover list of
    /// a summary/digest tap, or null on a single-event tap.
    private var pendingTapEventIds: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createMarketAlertChannel()
        marketAlertChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "postNotification" -> handlePostNotification(call, result)
                    "getPendingTap" -> {
                        // One-shot: answered once, then consumed.
                        val eventId = pendingTapEventId
                        val eventIds = pendingTapEventIds
                        result.success(
                            if (eventId == null) null
                            else tapArguments(eventId, eventIds)
                        )
                        pendingTapEventId = null
                        pendingTapEventIds = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // Cold start via a local notification tap: the launch intent
        // carries the ids. The Dart handler does not exist yet (the
        // engine is still starting) — keep them pending; the Dart side
        // consumes them with getPendingTap after wiring the channel.
        val launchEventId = extractTapEventId(intent)
        if (launchEventId != null) {
            pendingTapEventId = launchEventId
            pendingTapEventIds = extractTapEventIds(intent)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        marketAlertChannel?.setMethodCallHandler(null)
        marketAlertChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Warm tap: the Dart side is running. Keep the ids pending until
        // the handler acknowledges the delivery (replies true) — that is
        // the handshake above.
        val eventId = extractTapEventId(intent) ?: return
        val eventIds = extractTapEventIds(intent)
        pendingTapEventId = eventId
        pendingTapEventIds = eventIds
        marketAlertChannel?.invokeMethod(
            "onNotificationTap",
            tapArguments(eventId, eventIds),
            object : MethodChannel.Result {
                override fun success(reply: Any?) {
                    if (reply == true && pendingTapEventId == eventId) {
                        pendingTapEventId = null
                        pendingTapEventIds = null
                    }
                }

                // The Dart side dropped the call (no handler): the ids
                // stay pending for the next getPendingTap.
                override fun error(code: String, message: String?, details: Any?) {}

                override fun notImplemented() {}
            },
        )
    }

    /// Creates the OS notification channels at startup — before any FCM
    /// message can display against them. `market_rank_changes`:
    /// IMPORTANCE HIGH = sound, vibration and heads-up (the user can
    /// change all of it in the system notification settings; channel
    /// policy, not app policy). `market_rank_digest`: IMPORTANCE LOW
    /// with sound and vibration explicitly off — the silent roll-up
    /// channel (no heads-up; the summary lands in the shade only).
    /// Channel importance cannot be changed after creation — the first
    /// setting is final unless the channel id changes.
    private fun createMarketAlertChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = NotificationManagerCompat.from(this)
        val changes = NotificationChannelCompat.Builder(
            MARKET_ALERT_CHANNEL_ID,
            NotificationManagerCompat.IMPORTANCE_HIGH,
        )
            .setName(MARKET_ALERT_CHANNEL_NAME)
            .setDescription(MARKET_ALERT_CHANNEL_DESCRIPTION)
            .build()
        manager.createNotificationChannel(changes)
        val digest = NotificationChannelCompat.Builder(
            MARKET_DIGEST_CHANNEL_ID,
            NotificationManagerCompat.IMPORTANCE_LOW,
        )
            .setName(MARKET_DIGEST_CHANNEL_NAME)
            .setDescription(MARKET_DIGEST_CHANNEL_DESCRIPTION)
            .setSound(null, null)
            .setVibrationEnabled(false)
            .build()
        manager.createNotificationChannel(digest)
    }

    private fun handlePostNotification(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val eventId = call.argument<String>("eventId")
        val title = call.argument<String>("title")
        val body = call.argument<String>("body")
        val channelId = call.argument<String>("channelId")
        val kind = call.argument<String>("kind")
        val eventIds = call.argument<String>("eventIds")
        if (eventId.isNullOrEmpty() || title == null || body == null) {
            // Fail-closed: nothing is posted, the Dart side falls back
            // to its in-app banner instead of crashing the message path.
            result.success(false)
            return
        }
        // Channel selection: a missing channelId means the sound
        // market-alert channel (the pre-digest contract, kept for
        // compatibility); the digest channel is explicit. Any other id
        // names a channel this side never created — Android would drop
        // the post silently, so it is refused instead (fail-closed: the
        // Dart side falls back to the banner, the alert is not lost).
        val channel = when (channelId) {
            null, "" -> MARKET_ALERT_CHANNEL_ID
            MARKET_ALERT_CHANNEL_ID, MARKET_DIGEST_CHANNEL_ID -> channelId
            else -> {
                result.success(false)
                return
            }
        }
        val batch = kind == "summary" || kind == "digest"
        if (batch && eventIds.isNullOrEmpty()) {
            // A summary/digest post without its cover list cannot
            // fulfill the tap contract (the list view of every covered
            // event): refused, never degraded to a single-event tap
            // that would hide events.
            result.success(false)
            return
        }
        val manager = NotificationManagerCompat.from(this)
        if (!manager.areNotificationsEnabled()) {
            // POST_NOTIFICATIONS off or notifications disabled: refuse
            // (false), the Dart side falls back to the banner.
            result.success(false)
            return
        }
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(TAP_EVENT_ID_KEY, eventId)
            if (!eventIds.isNullOrEmpty()) {
                putExtra(TAP_EVENT_IDS_KEY, eventIds)
            }
        }
        // Stable slot per message unit. Audible units (single, summary)
        // keep distinct unit ids under tag = null: a single event keys
        // on its own id (a re-delivery updates the post in place instead
        // of stacking a second notification) and a summary keys on kind
        // + the representative id, so a roll-up never overwrites the
        // single alert of an event it covers. Silent digest units share
        // one replaceable slot with background FCM posts: Firebase
        // Messaging's DisplayNotification posts
        // notify("market_rank_digest", 0, ...) for a message carrying
        // android.notification.tag = "market_rank_digest", so the
        // foreground post uses the same (tag, id) and the shade holds
        // at most one silent summary card, updated in place. The
        // PendingIntent request code follows the slot, and each digest
        // update replaces the tap intent's event_id/event_ids via
        // FLAG_UPDATE_CURRENT.
        val isDigest = kind == "digest"
        val notificationTag = if (isDigest) MARKET_DIGEST_CHANNEL_ID else null
        val notificationId =
            if (isDigest) 0
            else if (batch) "$kind:$eventId".hashCode()
            else eventId.hashCode()
        val requestCode =
            if (isDigest) MARKET_DIGEST_CHANNEL_ID.hashCode() else notificationId
        val contentIntent = PendingIntent.getActivity(
            this,
            requestCode,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, channel)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(contentIntent)
            // Pre-O devices have no channel importance: HIGH priority is
            // what carries the heads-up there; the silent digest channel
            // maps to DEFAULT so it stays quiet pre-O too.
            .setPriority(
                if (channel == MARKET_DIGEST_CHANNEL_ID) {
                    NotificationCompat.PRIORITY_DEFAULT
                } else {
                    NotificationCompat.PRIORITY_HIGH
                }
            )
            .setAutoCancel(true)
            // One silent summary card, updated in place: a replaced
            // digest does not re-alert (sound is channel-owned anyway,
            // but heads-up/vibration behavior stays stable pre-O).
            .setOnlyAlertOnce(isDigest)
            .build()
        try {
            manager.notify(notificationTag, notificationId, notification)
            result.success(true)
        } catch (e: SecurityException) {
            // Permission revoked between the check and the post: refuse,
            // never crash the foreground message path.
            result.success(false)
        }
    }

    private fun extractTapEventId(intent: Intent?): String? =
        intent?.getStringExtra(TAP_EVENT_ID_KEY)?.takeIf { it.isNotEmpty() }

    private fun extractTapEventIds(intent: Intent?): String? =
        intent?.getStringExtra(TAP_EVENT_IDS_KEY)?.takeIf { it.isNotEmpty() }

    /// The tap payload the Dart side parses (MarketAlertTap):
    /// `event_id` plus, on a summary/digest tap, `event_ids`.
    private fun tapArguments(eventId: String, eventIds: String?): Map<String, String?> =
        if (eventIds == null) {
            mapOf(TAP_EVENT_ID_KEY to eventId)
        } else {
            mapOf(TAP_EVENT_ID_KEY to eventId, TAP_EVENT_IDS_KEY to eventIds)
        }

    companion object {
        private const val MARKET_ALERT_CHANNEL_ID = "market_rank_changes"
        private const val MARKET_ALERT_CHANNEL_NAME = "시장 순위 변화"
        private const val MARKET_ALERT_CHANNEL_DESCRIPTION =
            "TOP10 진입·이탈과 순위 변화 알림"
        private const val MARKET_DIGEST_CHANNEL_ID = "market_rank_digest"
        private const val MARKET_DIGEST_CHANNEL_NAME = "시장 순위 요약"
        private const val MARKET_DIGEST_CHANNEL_DESCRIPTION =
            "같은 관측 시점의 TOP10 순위 변경을 묶은 무음 요약"
        private const val METHOD_CHANNEL = "hongscanner/market_alert"
        private const val TAP_EVENT_ID_KEY = "event_id"
        private const val TAP_EVENT_IDS_KEY = "event_ids"
    }
}
