import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../providers.dart';

/// Reads the current auth token from providers.
String? chatAuthToken(WidgetRef ref) {
  final tokenStore = ref.read(authTokenStoreProvider);
  return ref.read(authControllerProvider).value?.accessToken ??
      tokenStore.peekToken();
}

String authenticatedUrl(String url, WidgetRef ref) {
  return url;
}

Map<String, String> chatAuthHeaders(WidgetRef ref) {
  if (kIsWeb) {
    return const {};
  }
  final token = chatAuthToken(ref);
  return {
    if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    'X-Blue-Client': 'mobile',
  };
}

/// Resolves a raw image path (relative or absolute) to a full URL.
String resolveChatImageUrl(String rawPath) {
  if (rawPath.startsWith('http://') || rawPath.startsWith('https://')) {
    return rawPath;
  }
  return AppConfig.imageUrlFromPath(rawPath);
}
