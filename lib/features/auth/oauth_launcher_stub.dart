import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';

Future<bool> launchOauth(String url) {
  return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

Future<String> launchOauthWithAppCallback(
  String url,
  String callbackScheme,
) async {
  debugPrint('[AUTH] oauth launch url=$url callbackScheme=$callbackScheme');
  try {
    final callbackUrl = await FlutterWebAuth2.authenticate(
      url: url,
      callbackUrlScheme: callbackScheme,
    ).timeout(const Duration(seconds: 90));
    debugPrint('[AUTH] oauth callback url=$callbackUrl');
    final uri = Uri.tryParse(callbackUrl);
    if (uri == null) {
      throw Exception('oauth_callback_invalid: malformed callback URL');
    }
    final code = uri.queryParameters['code']?.trim() ?? '';
    if (code.isEmpty) {
      throw Exception(
        'oauth_callback_invalid: expected exchange code in callback',
      );
    }
    return code;
  } on TimeoutException {
    throw Exception('oauth_callback_timeout: no callback received within 90s');
  } on PlatformException catch (error) {
    debugPrint(
      '[AUTH] oauth platform exception code=${error.code} message=${error.message}',
    );
    if (error.code.toLowerCase() == 'canceled') {
      throw Exception(
        'oauth_callback_canceled: app did not receive valid callback. '
        'Check Android deep link and gateway redirect.',
      );
    }
    throw Exception('oauth_platform_error: ${error.message ?? error.code}');
  }
}
