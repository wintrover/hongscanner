import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'api/api_client.dart';
import 'app_routes.dart';
import 'firebase_options.dart';
import 'screens/app_scope.dart';
import 'screens/auth_dialog.dart';
import 'screens/market_view_screen.dart';
import 'services/fcm_push_service.dart';
import 'services/market_alert_channel.dart';
import 'services/push_service.dart';
import 'state/app_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const HongScannerApp());
}

/// Composition point for push wiring — Firebase handoff step 4 (see
/// README.md in this directory). Fails closed by design: without
/// google-services.json / initializeApp, FcmPushService throws StateError
/// instead of reporting success. The API base URL is configurable with
/// `--dart-define=HS_API_BASE=…` (default: the Android emulator's host
/// loopback alias).
PushService defaultPushService() => const FcmPushService();

AppStore defaultAppStore() => AppStore(
      apiClient: ApiClient.fromEnvironment(),
      pushService: defaultPushService(),
    );

class HongScannerApp extends StatefulWidget {
  const HongScannerApp({super.key, this.store});

  /// Injectable so tests can drive the app with fakes and fixtures; the
  /// default composition builds the production store once per app run.
  final AppStore? store;

  @override
  State<HongScannerApp> createState() => _HongScannerAppState();
}

class _HongScannerAppState extends State<HongScannerApp> {
  late final AppStore _store;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? defaultAppStore();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      store: _store,
      child: MaterialApp(
        title: 'Hong Scanner',
        navigatorKey: navigatorKey,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        home: const RootShell(),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  AppStore? _store;

  /// The OS market-alert path (MainActivity.kt owns the platform end):
  /// foreground posting, local-notification taps, the pending cold-start
  /// tap. One instance per shell; see [MarketAlertChannel].
  final MarketAlertChannel _marketAlert = const MarketAlertChannel();

  /// Foreground alert units already surfaced (an OS notification or the
  /// in-app banner), so a burst of repeated deliveries shows one alert,
  /// not a stack. A unit is one event (its event id) or one summary/
  /// digest notification (kind + first covered id) — a single event and
  /// a digest covering it are different units, and both surface. The
  /// keys come from [PushMessage.dedupKey]. Bounded: the oldest key
  /// drops out once the history is full.
  final Set<String> _surfacedUnits = <String>{};

  static const int _maxSurfacedHistory = 64;

  static const _screens = <Widget>[
    MarketViewScreen(),
    HistoryScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = _store;
      if (store == null) return;
      store.bootstrap(
        onForegroundMessage: _handleForegroundAlert,
        onUnauthorized: () => _reenterCredentials(store),
      );
      // Local-notification taps bypass FCM's tap APIs: a tap while the
      // app runs arrives as "onNotificationTap" on the market-alert
      // channel, a cold-start tap is consumed once via getPendingTap.
      // The handler is registered before the pending query so a tap
      // landing between the two is delivered live, not parked — see the
      // handshake notes in MarketAlertChannel and MainActivity.kt. A
      // summary/digest tap carries its cover list and routes to the
      // list view; a single-event tap routes to the detail.
      _marketAlert.setTapHandler(
        (tap) => store.openEvent(tap.eventId, eventIds: tap.eventIds),
      );
      _marketAlert.getPendingTap().then((tap) {
        if (tap != null) {
          store.openEvent(tap.eventId, eventIds: tap.eventIds);
        }
      });
      // A cold-start tap can route before the navigator exists (the store
      // may be bootstrapped ahead of the first frame); the deferred route
      // flushes here, once the navigator is guaranteed to be mounted.
      store.flushPendingEvent();
    });
  }

  @override
  void dispose() {
    _marketAlert.clearTapHandler();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store ??= AppScope.of(context);
  }

  /// Foreground resume resync: the offline / force-killed / dropped-queue
  /// recovery path. Notification taps route through the store's push
  /// wiring (bootstrap), not the lifecycle observer.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _store?.resync();
    }
  }

  /// Foreground delivery policy: with notification+data messages the OS
  /// does not display the notification while the app is foregrounded
  /// (official firebase_messaging behavior), so the app surfaces the
  /// alert itself. TOP10 state changes (TOP10_ENTERED / TOP10_EXITED /
  /// RANK_CHANGED) and immediate summaries are re-posted to the OS
  /// `market_rank_changes` channel, silent digest roll-ups to
  /// `market_rank_digest` (IMPORTANCE_LOW — the post lands in the shade
  /// with no heads-up: the quiet display a digest is) — with the
  /// dispatcher's own title/body, display delivery only; the app never
  /// re-assembles or re-computes the text. A refused post (notification
  /// permission off, no platform end) falls back to the in-app banner.
  /// Alerts dedup by message unit with a bounded history (an event id
  /// for singles, a kind+first-id key for summary/digest — a single
  /// event and a digest covering it are different units and both
  /// surface), and a new banner replaces the current one instead of
  /// queueing behind it. Data-only payloads plus local notification
  /// re-synthesis of text the server did not send stay forbidden —
  /// terminated-state display remains the OS notification (the
  /// official path).
  Future<void> _handleForegroundAlert(PushMessage message) async {
    if (!mounted) return;
    final eventId = message.representativeEventId;
    final dedupKey = message.dedupKey;
    if (dedupKey != null) {
      if (_surfacedUnits.contains(dedupKey)) return;
      if (_surfacedUnits.length >= _maxSurfacedHistory) {
        // LinkedHashSet keeps insertion order: drop the oldest surfaced unit.
        _surfacedUnits.remove(_surfacedUnits.first);
      }
      _surfacedUnits.add(dedupKey);
    }
    final title = message.notificationTitle;
    final body = message.notificationBody;
    if (eventId != null && title != null && body != null &&
        MarketAlertChannel.isMarketAlert(message)) {
      final posted = await _marketAlert.postNotification(
        eventId: eventId,
        title: title,
        body: body,
        kind: message.kind,
        eventIds: message.eventIds?.join(','),
        channelId: message.kind == 'digest'
            ? MarketAlertChannel.digestChannelId
            : null,
      );
      if (posted) return; // the OS notification owns the display
    }
    if (!mounted) return; // the post awaited: the shell may be gone
    final label = message.eventType ??
        message.kind ??
        message.representativeEventId ??
        '페이로드 없음';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('포그라운드 알림 수신: $label'),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// The 401 re-entry path the store calls: one credential dialog, and —
  /// only when the operator submits a pair — persist it to the secure
  /// store via [AppStore.saveCredentials] and allow the single retry.
  Future<bool> _reenterCredentials(AppStore store) async {
    if (!mounted) return false;
    final credentials = await showCredentialPrompt(context);
    if (credentials == null) return false;
    await store.saveCredentials(credentials);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    return Scaffold(
      body: IndexedStack(index: store.tabIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: store.tabIndex,
        onDestinationSelected: store.selectTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.leaderboard_outlined),
            selectedIcon: Icon(Icons.leaderboard),
            label: '후보',
          ),
          NavigationDestination(
            icon: Icon(Icons.history),
            selectedIcon: Icon(Icons.history),
            label: '히스토리',
          ),
        ],
      ),
    );
  }
}
