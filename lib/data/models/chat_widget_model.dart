import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Map spec
// ---------------------------------------------------------------------------

class ChatMapSpec {
  const ChatMapSpec({
    required this.title,
    this.style = 'dark',
    this.fitBounds = true,
    this.polylines = const [],
    this.markers = const [],
    this.bounds,
  });

  final String title;
  final String style;
  final bool fitBounds;
  final List<ChatMapPolyline> polylines;
  final List<ChatMapMarker> markers;
  final ChatMapBounds? bounds;

  factory ChatMapSpec.fromJson(Map<String, dynamic> json) {
    final polylines = (json['polylines'] as List?)
            ?.map((e) =>
                ChatMapPolyline.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    final markers = (json['markers'] as List?)
            ?.map(
                (e) => ChatMapMarker.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    final boundsJson = json['bounds'];
    return ChatMapSpec(
      title: (json['title'] ?? 'Map').toString(),
      style: (json['style'] ?? 'dark').toString(),
      fitBounds: json['fit_bounds'] != false,
      polylines: polylines,
      markers: markers,
      bounds: boundsJson is Map<String, dynamic>
          ? ChatMapBounds.fromJson(boundsJson)
          : null,
    );
  }
}

class ChatMapPolyline {
  const ChatMapPolyline({
    this.encodedPoints,
    this.rawCoords,
    this.color,
    this.width = 3.0,
    this.label,
    this.meta,
  });

  /// Google-encoded polyline string (preferred).
  final String? encodedPoints;

  /// Raw [[lat, lng], ...] fallback when encoded is unavailable.
  final List<List<double>>? rawCoords;

  final Color? color;
  final double width;
  final String? label;
  final Map<String, dynamic>? meta;

  factory ChatMapPolyline.fromJson(Map<String, dynamic> json) {
    List<List<double>>? rawCoords;
    final rawList = json['raw_coords'];
    if (rawList is List) {
      rawCoords = rawList
          .whereType<List>()
          .map((pair) => [
                (pair[0] as num).toDouble(),
                (pair[1] as num).toDouble(),
              ])
          .toList();
    }
    return ChatMapPolyline(
      encodedPoints: json['points']?.toString(),
      rawCoords: rawCoords,
      color: _parseColor(json['color']),
      width: (json['width'] as num?)?.toDouble() ?? 3.0,
      label: json['label']?.toString(),
      meta: json['meta'] is Map<String, dynamic> ? json['meta'] : null,
    );
  }
}

class ChatMapMarker {
  const ChatMapMarker({
    required this.lat,
    required this.lng,
    this.label,
    this.icon,
  });

  final double lat;
  final double lng;
  final String? label;
  final String? icon;

  factory ChatMapMarker.fromJson(Map<String, dynamic> json) {
    return ChatMapMarker(
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      label: json['label']?.toString(),
      icon: json['icon']?.toString(),
    );
  }
}

class ChatMapBounds {
  const ChatMapBounds({required this.swLat, required this.swLng, required this.neLat, required this.neLng});

  final double swLat;
  final double swLng;
  final double neLat;
  final double neLng;

  factory ChatMapBounds.fromJson(Map<String, dynamic> json) {
    final sw = json['sw'] as List;
    final ne = json['ne'] as List;
    return ChatMapBounds(
      swLat: (sw[0] as num).toDouble(),
      swLng: (sw[1] as num).toDouble(),
      neLat: (ne[0] as num).toDouble(),
      neLng: (ne[1] as num).toDouble(),
    );
  }
}

// ---------------------------------------------------------------------------
// Chart spec
// ---------------------------------------------------------------------------

class ChatChartSpec {
  const ChatChartSpec({
    required this.type,
    required this.title,
    this.xLabel,
    this.yLabel,
    this.series = const [],
  });

  final String type; // bar, line, area, pie
  final String title;
  final String? xLabel;
  final String? yLabel;
  final List<ChatChartSeries> series;

  factory ChatChartSpec.fromJson(Map<String, dynamic> json) {
    final series = (json['series'] as List?)
            ?.map((e) =>
                ChatChartSeries.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    return ChatChartSpec(
      type: (json['type'] ?? 'bar').toString(),
      title: (json['title'] ?? 'Chart').toString(),
      xLabel: json['x_label']?.toString(),
      yLabel: json['y_label']?.toString(),
      series: series,
    );
  }
}

class ChatChartSeries {
  const ChatChartSeries({
    required this.name,
    this.color,
    this.data = const [],
  });

  final String name;
  final Color? color;
  final List<ChatChartPoint> data;

  factory ChatChartSeries.fromJson(Map<String, dynamic> json) {
    final data = (json['data'] as List?)
            ?.map(
                (e) => ChatChartPoint.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    return ChatChartSeries(
      name: (json['name'] ?? '').toString(),
      color: _parseColor(json['color']),
      data: data,
    );
  }
}

class ChatChartPoint {
  const ChatChartPoint({required this.x, required this.y});

  final dynamic x; // String label or num
  final double y;

  factory ChatChartPoint.fromJson(Map<String, dynamic> json) {
    return ChatChartPoint(
      x: json['x'],
      y: (json['y'] as num).toDouble(),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Color? _parseColor(dynamic value) {
  if (value == null) return null;
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  final hex = s.replaceFirst('#', '');
  if (hex.length == 6) {
    return Color(int.parse('FF$hex', radix: 16));
  }
  if (hex.length == 8) {
    return Color(int.parse(hex, radix: 16));
  }
  return null;
}
