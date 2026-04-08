import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_polyline_algorithm/google_polyline_algorithm.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/config/app_config.dart';
import '../../../data/models/chat_widget_model.dart';

/// Default palette for polylines when no color is specified.
const _defaultPolylineColors = [
  Color(0xFFFF9800), // orange
  Color(0xFF4CAF50), // green
  Color(0xFF2196F3), // blue
  Color(0xFFE91E63), // pink
  Color(0xFF9C27B0), // purple
  Color(0xFF00BCD4), // cyan
  Color(0xFFFF5722), // deep orange
  Color(0xFF8BC34A), // light green
];

class ChatInlineMap extends StatefulWidget {
  const ChatInlineMap({super.key, required this.spec});

  final ChatMapSpec spec;

  @override
  State<ChatInlineMap> createState() => _ChatInlineMapState();
}

class _ChatInlineMapState extends State<ChatInlineMap> {
  final _mapController = MapController();
  late final List<_DecodedPolyline> _decodedPolylines;
  late final List<LatLng> _allPoints;
  late final LatLngBounds? _bounds;

  @override
  void initState() {
    super.initState();
    _decodedPolylines = _decodePolylines(widget.spec.polylines);
    _allPoints = [
      for (final dp in _decodedPolylines) ...dp.points,
      for (final m in widget.spec.markers) LatLng(m.lat, m.lng),
    ];
    _bounds = _computeBounds(_allPoints);
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tileStyle = widget.spec.style == 'light' ? 'light' : 'dark';
    final tileConfig = AppConfig.mapTileConfig(tileStyle);

    if (_allPoints.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            widget.spec.title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Container(
          height: 300,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: isDark ? const Color(0x28000000) : const Color(0x18000000),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCameraFit: _bounds != null
                      ? CameraFit.bounds(
                          bounds: _bounds,
                          padding: const EdgeInsets.all(32),
                        )
                      : null,
                  initialCenter: _bounds == null ? _allPoints.first : const LatLng(0, 0),
                  initialZoom: _bounds == null ? 13 : 2,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate: tileConfig.urlTemplate,
                    subdomains: tileConfig.subdomains,
                    maxZoom: tileConfig.maxZoom.toDouble(),
                    userAgentPackageName: 'blue_mobile',
                  ),
                  if (_decodedPolylines.isNotEmpty)
                    PolylineLayer(
                      polylines: [
                        for (final dp in _decodedPolylines)
                          Polyline(
                            points: dp.points,
                            strokeWidth: dp.width,
                            color: dp.color,
                          ),
                      ],
                    ),
                  if (widget.spec.markers.isNotEmpty)
                    MarkerLayer(
                      markers: [
                        for (final m in widget.spec.markers)
                          Marker(
                            point: LatLng(m.lat, m.lng),
                            width: 28,
                            height: 28,
                            child: Tooltip(
                              message: m.label ?? '',
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withValues(alpha: 0.88),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 1.5),
                                  boxShadow: const [
                                    BoxShadow(blurRadius: 6, color: Color(0x33000000)),
                                  ],
                                ),
                                child: const Icon(Icons.place, size: 16, color: Colors.white),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
              // Zoom controls
              Positioned(
                right: 10,
                bottom: 10,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ZoomButton(
                      icon: Icons.add,
                      onTap: () => _mapController.move(
                        _mapController.camera.center,
                        _mapController.camera.zoom + 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _ZoomButton(
                      icon: Icons.remove,
                      onTap: () => _mapController.move(
                        _mapController.camera.center,
                        _mapController.camera.zoom - 1,
                      ),
                    ),
                    if (_bounds != null) ...[
                      const SizedBox(height: 4),
                      _ZoomButton(
                        icon: Icons.fit_screen_outlined,
                        onTap: () => _mapController.fitCamera(
                          CameraFit.bounds(
                            bounds: _bounds,
                            padding: const EdgeInsets.all(32),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_decodedPolylines.isNotEmpty || widget.spec.markers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              [
                if (_decodedPolylines.isNotEmpty) '${_decodedPolylines.length} route(s)',
                if (widget.spec.markers.isNotEmpty) '${widget.spec.markers.length} point(s)',
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  static List<_DecodedPolyline> _decodePolylines(List<ChatMapPolyline> polylines) {
    final result = <_DecodedPolyline>[];
    for (var i = 0; i < polylines.length; i++) {
      final p = polylines[i];
      List<LatLng>? points;

      // Try encoded polyline first
      if (p.encodedPoints != null && p.encodedPoints!.isNotEmpty) {
        try {
          points = decodePolyline(p.encodedPoints!)
              .map((pair) => LatLng(pair[0].toDouble(), pair[1].toDouble()))
              .toList();
        } catch (_) {
          // fall through to rawCoords
        }
      }

      // Fallback: raw coordinate pairs
      if ((points == null || points.length < 2) && p.rawCoords != null && p.rawCoords!.isNotEmpty) {
        points = p.rawCoords!
            .map((pair) => LatLng(pair[0], pair[1]))
            .toList();
      }

      if (points == null || points.length < 2) continue;
      result.add(_DecodedPolyline(
        points: points,
        color: p.color ?? _defaultPolylineColors[i % _defaultPolylineColors.length],
        width: p.width,
        label: p.label,
      ));
    }
    return result;
  }

  static LatLngBounds? _computeBounds(List<LatLng> points) {
    if (points.length < 2) return null;
    final lats = points.map((p) => p.latitude);
    final lngs = points.map((p) => p.longitude);
    return LatLngBounds(
      LatLng(lats.reduce((a, b) => a < b ? a : b), lngs.reduce((a, b) => a < b ? a : b)),
      LatLng(lats.reduce((a, b) => a > b ? a : b), lngs.reduce((a, b) => a > b ? a : b)),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(8),
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 20, color: Colors.black87),
        ),
      ),
    );
  }
}

class _DecodedPolyline {
  const _DecodedPolyline({
    required this.points,
    required this.color,
    required this.width,
    this.label,
  });

  final List<LatLng> points;
  final Color color;
  final double width;
  final String? label;
}
