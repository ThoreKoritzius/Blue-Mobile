// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;

Future<bool> launchOauth(String url) async {
  html.window.open(url, '_blank');
  return true;
}

Future<bool> launchOauthWithAppCallback(
  String url,
  String callbackScheme,
) async {
  html.window.open(url, '_blank');
  return true;
}
