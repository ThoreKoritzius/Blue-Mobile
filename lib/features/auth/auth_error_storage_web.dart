// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;

String? readAuthError(String key) {
  return html.window.sessionStorage[key];
}

void writeAuthError(String key, String? value) {
  if (value == null || value.trim().isEmpty) {
    html.window.sessionStorage.remove(key);
    return;
  }
  html.window.sessionStorage[key] = value;
}
