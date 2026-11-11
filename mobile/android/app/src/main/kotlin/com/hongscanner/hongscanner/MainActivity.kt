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
///   the launch intent here and kept in [pendingTapEventId]; the Dart
///   side consumes it once with `getPendingTap`.
/// * A tap while the app runs arrives via [onNewIntent]: the id is kept
///   pending and `onNotificationTap` is invoked on the channel. The Dart
///   handler replies `true` when it routed the tap — that acknowledgement
///   clears the pending copy. No handler (Dart side not wired yet, or the
///   message dropped) keeps the id pending for the next `getPendingTap`.
///   (An Activity recreation may re-deliver the launch intent — plain
///   Android task semantics; the Dart side's openEvent is idempotent:
///   same selection, reused detail route.)
///
/// Foreground FCM notification messages are delivered to Dart only (the
/// OS does not display them — official firebase_messaging behavior), so
/// `postNotification` re-posts the dispatcher's own title/body to the OS
/// `market_rank_changes` channel: display delivery only, no text is
/// assembled or altered on this side either.
class MainActivity : FlutterActivity() {

    private var marketAlertChannel: MethodChannel? = null

    /// One-shot: the event id of a local-notification tap the Dart side
    /// has not acknowledged yet. Consumed by `getPendingTap`.
    private var pendingTapEventId: String? = null

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
                        result.success(pendingTapEventId)
                        pendingTapEventId = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // Cold start via a local notification tap: the launch intent
        // carries the id. The Dart handler does not exist yet (the
        // engine is still starting) — keep it pending; the Dart side
        // consumes it with getPendingTap after wiring the channel.
        pendingTapEventId = extractTapEventId(intent) ?: pendingTapEventId
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        marketAlertChannel?.setMethodCallHandler(null)
        marketAlertChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Warm tap: the Dart side is running. Keep the id pending until
        // the handler acknowledges the delivery (replies true) — that is
        // the handshake above.
        val eventId = extractTapEventId(intent) ?: return
        pendingTapEventId = eventId
        marketAlertChannel?.invokeMethod(
            "onNotificationTap",
            mapOf(TAP_EVENT_ID_KEY to eventId),
            object : MethodChannel.Result {
                override fun success(reply: Any?) {
                    if (reply == true && pendingTapEventId == eventId) {
                        pendingTapEventId = null
                    }
                }

                // The Dart side dropped the call (no handler): the id
                // stays pending for the next getPendingTap.
                override fun error(code: String, message: String?, details: Any?) {}

                override fun notImplemented() {}
            },
        )
    }

    /// Creates the OS notification channel at startup — before any FCM
    /// message can display against it. Importance HIGH = sound, vibration
    /// and heads-up (the user can change all of it in the system
    /// notification settings; channel policy, not app policy).
    private fun createMarketAlertChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannelCompat.Builder(
            MARKET_ALERT_CHANNEL_ID,
            NotificationManagerCompat.IMPORTANCE_HIGH,
        )
            .setName(MARKET_ALERT_CHANNEL_NAME)
            .setDescription(MARKET_ALERT_CHANNEL_DESCRIPTION)
            .build()
        NotificationManagerCompat.from(this).createNotificationChannel(channel)
    }

    private fun handlePostNotification(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val eventId = call.argument<String>("eventId")
        val title = call.argument<String>("title")
        val body = call.argument<String>("body")
        if (eventId.isNullOrEmpty() || title == null || body == null) {
            // Fail-closed: nothing is posted, the Dart side falls back
            // to its in-app banner instead of crashing the message path.
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
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            eventId.hashCode(),
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, MARKET_ALERT_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(contentIntent)
            // Pre-O devices have no channel importance: HIGH priority is
            // what carries the heads-up there.
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        try {
            // Same id per event id: a re-delivery updates the post in
            // place instead of stacking a second notification.
            manager.notify(eventId.hashCode(), notification)
            result.success(true)
        } catch (e: SecurityException) {
            // Permission revoked between the check and the post: refuse,
            // never crash the foreground message path.
            result.success(false)
        }
    }

    private fun extractTapEventId(intent: Intent?): String? =
        intent?.getStringExtra(TAP_EVENT_ID_KEY)?.takeIf { it.isNotEmpty() }

    companion object {
        private const val MARKET_ALERT_CHANNEL_ID = "market_rank_changes"
        private const val MARKET_ALERT_CHANNEL_NAME = "시장 순위 변화"
        private const val MARKET_ALERT_CHANNEL_DESCRIPTION =
            "TOP10 진입·이탈과 순위 변화 알림"
        private const val METHOD_CHANNEL = "hongscanner/market_alert"
        private const val TAP_EVENT_ID_KEY = "event_id"
    }
}
