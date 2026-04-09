import 'dart:typed_data';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../config/app_config.dart';
import '../network/http_client/http_client_factory.dart';

class ProtectedNetworkImage extends StatelessWidget {
  const ProtectedNetworkImage({
    super.key,
    required this.imageUrl,
    this.headers = const {},
    this.fit,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
  });

  final String imageUrl;
  final Map<String, String> headers;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final Widget? errorWidget;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return CachedNetworkImage(
        imageUrl: imageUrl,
        httpHeaders: headers,
        fit: fit,
        width: width,
        height: height,
        placeholder: placeholder == null ? null : (_, __) => placeholder!,
        errorWidget: (_, __, ___) => errorWidget ?? const SizedBox.shrink(),
      );
    }

    return FutureBuilder<ImageProvider<Object>>(
      future: loadProtectedImageProvider(imageUrl, headers: headers),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return Image(
            image: snapshot.data!,
            fit: fit,
            width: width,
            height: height,
            errorBuilder: (_, __, ___) => errorWidget ?? const SizedBox.shrink(),
          );
        }
        if (snapshot.hasError) {
          return errorWidget ?? const SizedBox.shrink();
        }
        return placeholder ?? const SizedBox.shrink();
      },
    );
  }
}

final Map<String, Uint8List> _webImageBytesCache = <String, Uint8List>{};
final Map<String, _SignedMediaEntry> _signedMediaCache = <String, _SignedMediaEntry>{};

class _SignedMediaEntry {
  const _SignedMediaEntry({required this.url, required this.expiresAt});

  final String url;
  final DateTime expiresAt;
}

bool _isProtectedBackendMediaUrl(String url) {
  if (url.isEmpty) return false;
  if (!url.startsWith(AppConfig.backendUrl)) return false;
  final uri = Uri.tryParse(url);
  final path = uri?.path ?? '';
  return path.startsWith('/api/images/') ||
      path.startsWith('/api/person/') ||
      path.startsWith('/api/runs/') ||
      path.startsWith('/api/face_crops/');
}

Future<String> resolveProtectedMediaUrl(
  String imageUrl, {
  Map<String, String> headers = const {},
}) async {
  if (!kIsWeb || !_isProtectedBackendMediaUrl(imageUrl)) {
    return imageUrl;
  }

  final cached = _signedMediaCache[imageUrl];
  final now = DateTime.now().toUtc();
  if (cached != null && cached.expiresAt.isAfter(now.add(const Duration(seconds: 10)))) {
    return cached.url;
  }

  final client = createGraphqlHttpClient();
  try {
    final signUri = Uri.parse(
      '${AppConfig.backendUrl}/api/media/sign',
    ).replace(queryParameters: {'target': imageUrl});
    final response = await client.get(signUri, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Media sign HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Invalid media sign response');
    }
    final signedUrl = (decoded['signedUrl'] ?? '').toString();
    final expiresAtRaw = decoded['expiresAt'];
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      (int.tryParse('$expiresAtRaw') ?? 0) * 1000,
      isUtc: true,
    );
    if (signedUrl.isEmpty) {
      throw Exception('Missing signed media URL');
    }
    _signedMediaCache[imageUrl] = _SignedMediaEntry(
      url: signedUrl,
      expiresAt: expiresAt,
    );
    return signedUrl;
  } finally {
    client.close();
  }
}

Future<ImageProvider<Object>> loadProtectedImageProvider(
  String imageUrl, {
  Map<String, String> headers = const {},
}) async {
  final resolvedUrl = await resolveProtectedMediaUrl(
    imageUrl,
    headers: headers,
  );

  if (!kIsWeb) {
    return CachedNetworkImageProvider(resolvedUrl, headers: headers);
  }

  final cached = _webImageBytesCache[resolvedUrl];
  if (cached != null) {
    return MemoryImage(cached);
  }

  final client = createGraphqlHttpClient();
  try {
    final response = await client.get(Uri.parse(resolvedUrl), headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Image HTTP ${response.statusCode}');
    }
    _webImageBytesCache[resolvedUrl] = response.bodyBytes;
    return MemoryImage(response.bodyBytes);
  } finally {
    client.close();
  }
}
