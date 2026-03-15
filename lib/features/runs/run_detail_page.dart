import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_polyline_algorithm/google_polyline_algorithm.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config/app_config.dart';
import '../../core/widgets/section_card.dart';
import '../../data/models/run_detail_model.dart';
import '../../data/models/run_model.dart';

class RunDetailPage extends StatelessWidget {
  const RunDetailPage({
    super.key,
    required this.run,
    required this.summary,
    required this.detail,
    required this.headers,
  });

  final RunModel run;
  final RunDetailModel summary;
  final RunDetailModel detail;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final routePoints = _decodePolylinePoints();
    final bounds = _computeBounds(routePoints);
    final stats = _buildStats();
    final noteLines = _buildNoteLines();

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 320,
            backgroundColor: isDark
                ? colorScheme.surfaceContainerHighest
                : const Color(0xFF133864),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              title: Text(
                run.name.isEmpty ? 'Run ${run.id}' : run.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: AppConfig.runImageUrl(run.id),
                    httpHeaders: headers,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      color: isDark
                          ? colorScheme.surfaceContainerHighest
                          : const Color(0xFF163B68),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x22000000),
                          Color(0x33000000),
                          isDark
                              ? const Color(0xE608111D)
                              : const Color(0xCC0A1A30),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 72,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _HeroBadge(label: run.startDateLocal),
                        _HeroBadge(
                          label: '${run.distanceKm.toStringAsFixed(1)} km',
                        ),
                        if (_formattedDuration != null)
                          _HeroBadge(label: _formattedDuration!),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              child: Column(
                children: [
                  if (routePoints.length >= 2)
                    _RouteMapCard(points: routePoints, bounds: bounds),
                  if (routePoints.length >= 2) const SizedBox(height: 12),
                  SectionCard(
                    title: 'Run stats',
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: stats
                          .map(
                            (stat) => _StatCard(label: stat.$1, value: stat.$2),
                          )
                          .toList(),
                    ),
                  ),
                  if (noteLines.isNotEmpty) const SizedBox(height: 12),
                  if (noteLines.isNotEmpty)
                    SectionCard(
                      title: 'Details',
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: noteLines
                            .map(
                              (line) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(
                                  line,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        color: colorScheme.onSurface,
                                        height: 1.4,
                                      ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? get _formattedDuration {
    final seconds =
        _numberFromPayload('moving_time')?.round() ??
        _numberFromPayload('elapsed_time')?.round();
    if (seconds == null || seconds <= 0) return null;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  List<(String, String)> _buildStats() {
    final averageSpeed = _numberFromPayload('average_speed');
    final maxSpeed = _numberFromPayload('max_speed');
    final elevation = _numberFromPayload('total_elevation_gain');
    final calories = _numberFromPayload('calories');

    final stats = <(String, String)>[
      ('Distance', '${run.distanceKm.toStringAsFixed(2)} km'),
      ('Date', run.startDateLocal),
    ];

    if (_formattedDuration != null) {
      stats.add(('Moving time', _formattedDuration!));
    }
    if (averageSpeed != null && averageSpeed > 0) {
      stats.add(('Avg speed', '${averageSpeed.toStringAsFixed(1)} km/h'));
      stats.add(('Pace', _formatPace(averageSpeed)));
    }
    if (maxSpeed != null && maxSpeed > 0) {
      stats.add(('Max speed', '${maxSpeed.toStringAsFixed(1)} km/h'));
    }
    if (elevation != null && elevation > 0) {
      stats.add(('Elevation', '${elevation.toStringAsFixed(0)} m'));
    }
    if (calories != null && calories > 0) {
      stats.add(('Calories', calories.toStringAsFixed(0)));
    }

    return stats;
  }

  List<String> _buildNoteLines() {
    final lines = <String>[];
    final summaryPayload = summary.payload;
    final detailPayload = detail.payload;

    final place = _stringFromPayload('place');
    if (place != null && place.isNotEmpty) {
      lines.add('Location: $place');
    }

    final description = (summaryPayload['description'] ?? '').toString().trim();
    if (description.isNotEmpty) {
      lines.add(description);
    }

    final achievement = (detailPayload['achievement_count'] ?? '')
        .toString()
        .trim();
    if (achievement.isNotEmpty && achievement != '0') {
      lines.add('Achievements: $achievement');
    }

    final kudos = (detailPayload['kudos_count'] ?? '').toString().trim();
    if (kudos.isNotEmpty && kudos != '0') {
      lines.add('Kudos: $kudos');
    }

    return lines;
  }

  List<LatLng> _decodePolylinePoints() {
    final polyline =
        _stringFromPayload('summary_polyline') ?? run.summaryPolyline;
    if (polyline.isEmpty) return const [];
    try {
      return decodePolyline(
        polyline,
      ).map((pair) => LatLng(pair[0].toDouble(), pair[1].toDouble())).toList();
    } catch (_) {
      return const [];
    }
  }

  LatLngBounds? _computeBounds(List<LatLng> points) {
    if (points.length < 2) return null;
    final latitudes = points.map((point) => point.latitude);
    final longitudes = points.map((point) => point.longitude);
    return LatLngBounds(
      LatLng(
        latitudes.reduce((a, b) => a < b ? a : b),
        longitudes.reduce((a, b) => a < b ? a : b),
      ),
      LatLng(
        latitudes.reduce((a, b) => a > b ? a : b),
        longitudes.reduce((a, b) => a > b ? a : b),
      ),
    );
  }

  String? _stringFromPayload(String key) {
    final summaryValue = summary.payload[key];
    if (summaryValue != null && summaryValue.toString().trim().isNotEmpty) {
      return summaryValue.toString();
    }
    final detailValue = detail.payload[key];
    if (detailValue != null && detailValue.toString().trim().isNotEmpty) {
      return detailValue.toString();
    }
    return null;
  }

  double? _numberFromPayload(String key) {
    final value = summary.payload[key] ?? detail.payload[key];
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  String _formatPace(double speedKmH) {
    if (speedKmH <= 0) return '--';
    final totalSeconds = (3600 / speedKmH).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')} /km';
  }
}

class _RouteMapCard extends StatelessWidget {
  const _RouteMapCard({required this.points, required this.bounds});

  final List<LatLng> points;
  final LatLngBounds? bounds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tileConfig = AppConfig.mapTileConfig('light');
    return Container(
      height: 280,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0x28000000) : const Color(0x18000000),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: FlutterMap(
        options: MapOptions(
          initialCenter: points.first,
          initialZoom: 12,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom,
          ),
          onMapReady: () {},
          cameraConstraint: bounds != null
              ? CameraConstraint.contain(bounds: bounds!)
              : const CameraConstraint.unconstrained(),
        ),
        children: [
          TileLayer(
            urlTemplate: tileConfig.urlTemplate,
            subdomains: tileConfig.subdomains,
            maxZoom: tileConfig.maxZoom.toDouble(),
            userAgentPackageName: 'blue_mobile',
          ),
          PolylineLayer(
            polylines: [
              Polyline(
                points: points,
                strokeWidth: 5,
                color: const Color(0xFF1D63D3),
              ),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: points.first,
                width: 20,
                height: 20,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1D63D3),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
              Marker(
                point: points.last,
                width: 20,
                height: 20,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF06D4F),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: 132,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  colorScheme.surfaceContainerHighest,
                  colorScheme.surfaceContainer,
                ]
              : [const Color(0xFFF9FBFF), const Color(0xFFEFF5FF)],
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroBadge extends StatelessWidget {
  const _HeroBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
