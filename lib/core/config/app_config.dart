class MapTileConfig {
  const MapTileConfig({
    required this.urlTemplate,
    this.subdomains = const [],
    this.maxZoom = 19,
  });

  final String urlTemplate;
  final List<String> subdomains;
  final int maxZoom;
}

class AppConfig {
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://blue.the-centaurus.com',
  );
  static const bool useOauthGateway = bool.fromEnvironment(
    'USE_OAUTH_GATEWAY',
    defaultValue: true,
  );

  static const String mapboxAccessToken = String.fromEnvironment(
    'MAPBOX_ACCESS_TOKEN',
    defaultValue: '',
  );

  static const String oauthCallbackScheme = 'bluemobileauth';
  static const String oauthCallbackHost = 'mobile-return';

  static String get graphqlHttpUrl =>
      useOauthGateway ? '$backendUrl/api/graphql' : '$backendUrl/graphql';

  static String get graphqlWsUrl {
    final base = backendUrl.startsWith('https://')
        ? backendUrl.replaceFirst('https://', 'wss://')
        : backendUrl.replaceFirst('http://', 'ws://');
    return useOauthGateway ? '$base/api/graphql' : '$base/graphql';
  }

  static String imageUrlFromPath(String path, {String? date}) {
    if (path.isEmpty) return '';
    if (!path.contains('/') && date != null && date.isNotEmpty) {
      return '$backendUrl/api/images/$date/compressed/$path';
    }
    var cleanPath = path
        .replaceFirst('./Blue/', '')
        .replaceFirst('stories_images/', '');
    cleanPath = cleanPath.replaceAll('\\\\', '/');
    return '$backendUrl/api/images/$cleanPath';
  }

  static String runImageUrl(String runId) => '$backendUrl/api/runs/$runId.png';

  static String faceCropUrlFromPath(String cropPath) {
    if (cropPath.isEmpty) return '';
    final normalized = cropPath.replaceAll('\\', '/');
    const marker = '/face_crops/';
    final markerIndex = normalized.indexOf(marker);
    final relative = markerIndex >= 0
        ? normalized.substring(markerIndex + marker.length)
        : normalized.replaceFirst(RegExp(r'^\.?/+'), '');
    return '$backendUrl/api/face_crops/$relative';
  }

  static bool get hasMapboxToken => mapboxAccessToken.trim().isNotEmpty;

  static MapTileConfig mapTileConfig(String mapType) {
    final normalized = mapType.toLowerCase();
    if (hasMapboxToken) {
      if (normalized == 'dark') {
        return MapTileConfig(
          urlTemplate:
              'https://api.mapbox.com/styles/v1/mapbox/dark-v11/tiles/{z}/{x}/{y}?access_token=$mapboxAccessToken',
          maxZoom: 22,
        );
      }
      if (normalized == 'normal') {
        return MapTileConfig(
          urlTemplate:
              'https://api.mapbox.com/styles/v1/mapbox/streets-v11/tiles/{z}/{x}/{y}?access_token=$mapboxAccessToken',
          maxZoom: 22,
        );
      }
      return MapTileConfig(
        urlTemplate:
            'https://api.mapbox.com/styles/v1/mapbox/light-v10/tiles/{z}/{x}/{y}?access_token=$mapboxAccessToken',
        maxZoom: 22,
      );
    }

    if (normalized == 'dark') {
      return const MapTileConfig(
        urlTemplate:
            'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
        subdomains: ['a', 'b', 'c', 'd'],
        maxZoom: 20,
      );
    }
    if (normalized == 'light') {
      return const MapTileConfig(
        urlTemplate:
            'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
        subdomains: ['a', 'b', 'c', 'd'],
        maxZoom: 20,
      );
    }
    return const MapTileConfig(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      maxZoom: 19,
    );
  }

  static String oauthSignInUrl({String? redirectTarget}) {
    final target = redirectTarget ?? '$backendUrl/api/auth/status';
    final encoded = Uri.encodeComponent(target);
    return '$backendUrl/oauth2/sign_in?rd=$encoded';
  }

  static String mobileOauthCallbackUrl() {
    return '$oauthCallbackScheme://$oauthCallbackHost';
  }

  static String mobileOauthBridgeUrl() {
    return '$backendUrl/api/auth/mobile/complete';
  }

  static String get authModeDescription => useOauthGateway
      ? 'Gateway auth mode via $backendUrl. Complete Google OAuth, then sign in with app username/password.'
      : 'Direct backend mode.';
}
