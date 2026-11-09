import 'package:flutter/material.dart';

import 'screens/event_detail_screen.dart';

/// Root-navigator key for store-driven routing: notification taps arrive
/// outside the widget tree, so the store needs a handle on the navigator.
/// Long-lived by design — a key recreated per build would point at no
/// navigator (the Flutter docs' own warning about global keys), so this is
/// a single process-lifetime instance.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// The detail route currently mounted, if any. Module state, not widget
/// state: the route outlives the screen that pushed it.
Route<void>? _mountedDetailRoute;

/// Pushes the event detail route onto the root navigator. A detail route
/// already mounted is reused — the store's selection change rebuilds it in
/// place — so repeated opens (the refresh button, a notification tap while
/// a detail is showing) never stack duplicate routes. Returns false only
/// when the navigator does not exist yet (before the app's first frame):
/// the caller keeps the event id pending and flushes it after the frame.
bool showEventDetail() {
  final mounted = _mountedDetailRoute;
  if (mounted != null) {
    if (mounted.navigator != null) return true;
    // Defunct (popped, or its navigator went away — e.g. a previous test
    // app): fall through and push a fresh route.
    _mountedDetailRoute = null;
  }
  final navigator = navigatorKey.currentState;
  if (navigator == null) return false;
  final route = MaterialPageRoute<void>(
    builder: (_) => const EventDetailScreen(),
  );
  _mountedDetailRoute = route;
  navigator.push(route);
  return true;
}
