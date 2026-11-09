import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'api/api_client.dart';
import 'app_routes.dart';
import 'firebase_options.dart';
import 'screens/app_scope.dart';
import 'screens/auth_dialog.dart';
import 'screens/market_view_screen.dart';
import 'services/fcm_push_service.dart';
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

  /// Event ids already shown as a foreground banner, so a burst of
  /// repeated deliveries for one event shows one banner, not a stack.
  /// Bounded: the oldest id drops out once the history is full.
  final Set<String> _bannerShownEventIds = <String>{};

  static const int _maxBannerHistory = 64;

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
        onForegroundMessage: _showForegroundBanner,
        onUnauthorized: () => _reenterCredentials(store),
      );
      // A cold-start tap can route before the navigator exists (the store
      // may be bootstrapped ahead of the first frame); the deferred route
      // flushes here, once the navigator is guaranteed to be mounted.
      store.flushPendingEvent();
    });
  }

  @override
  void dispose() {
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
  /// does not display the notification while the app is in the foreground,
  /// so the app shows an in-app banner. Banners dedup by event_id with a
  /// bounded history, and a new banner replaces the current one instead
  /// of queueing behind it. Data-only payloads plus local notification
  /// re-synthesis are forbidden by design — terminated-state display
  /// stays with the OS notification (the official path).
  void _showForegroundBanner(PushMessage message) {
    if (!mounted) return;
    final eventId = message.eventId;
    if (eventId != null) {
      if (_bannerShownEventIds.contains(eventId)) return;
      if (_bannerShownEventIds.length >= _maxBannerHistory) {
        // LinkedHashSet keeps insertion order: drop the oldest shown id.
        _bannerShownEventIds.remove(_bannerShownEventIds.first);
      }
      _bannerShownEventIds.add(eventId);
    }
    final label = message.eventType ?? message.eventId ?? '페이로드 없음';
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
