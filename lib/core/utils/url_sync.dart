import 'url_sync_stub.dart'
    if (dart.library.html) 'url_sync_web.dart';

/// Reads the initial date/tab from the browser URL and pushes URL updates.
/// No-op on native platforms.
class UrlSync {
  UrlSync._();

  /// Read date from browser URL path like `/day/2026-04-06`.
  /// Returns null on native or if URL doesn't match.
  static String? readInitialDate() => readInitialDateImpl();

  /// Read tab index from browser URL path.
  /// `/day/...` → 0, `/calendar` → 1, `/chat` → 2, `/map` → 3.
  static int readInitialTab() => readInitialTabImpl();

  /// Update the browser URL without triggering navigation.
  static void updateUrl(int tab, [String? dateStr]) =>
      updateUrlImpl(tab, dateStr);
}
