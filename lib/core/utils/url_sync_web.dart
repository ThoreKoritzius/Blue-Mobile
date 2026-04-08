// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

String? readInitialDateImpl() {
  final path = html.window.location.pathname ?? '';
  // Match /day/YYYY-MM-DD
  final match = RegExp(r'^/day/(\d{4}-\d{2}-\d{2})').firstMatch(path);
  return match?.group(1);
}

int readInitialTabImpl() {
  final path = html.window.location.pathname ?? '';
  if (path.startsWith('/day')) return 0;
  if (path.startsWith('/calendar')) return 1;
  if (path.startsWith('/chat')) return 2;
  if (path.startsWith('/map')) return 3;
  return 0;
}

void updateUrlImpl(int tab, [String? dateStr]) {
  final String path;
  switch (tab) {
    case 1:
      path = '/calendar';
    case 2:
      path = '/chat';
    case 3:
      path = '/map';
    default:
      path = '/day/${dateStr ?? ''}';
  }
  final current = html.window.location.pathname ?? '';
  if (current != path) {
    html.window.history.replaceState(null, '', path);
  }
}
