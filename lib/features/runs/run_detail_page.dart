import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_polyline_algorithm/google_polyline_algorithm.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/widgets/section_card.dart';
import '../../data/models/run_detail_model.dart';
import '../../data/models/run_model.dart';

class RunDetailPage extends StatefulWidget {
  const RunDetailPage({
    super.key,
    required this.run,
    required this.summary,
    required this.detail,
  });

  final RunModel run;
  final RunDetailModel summary;
  final RunDetailModel detail;

  @override
  State<RunDetailPage> createState() => _RunDetailPageState();
}

class _RunDetailPageState extends State<RunDetailPage> {
  bool _showMap = true;
  bool _allowPop = false;
  bool _popInProgress = false;

  Future<void> _handleBack() async {
    if (_popInProgress) return;
    _popInProgress = true;

    if (_showMap && mounted) {
      setState(() => _showMap = false);
      await Future<void>.delayed(Duration.zero);
    }

    if (!mounted) return;
    _allowPop = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final routePoints = _decodePolylinePoints();
    final bounds = _computeBounds(routePoints);
    final stats = _buildStats();
    final noteLines = _buildNoteLines();
    final splits = _parseSplits();
    final bestEfforts = _parseBestEfforts();
    final sourceLabel = _runSourceLabel;
    final heroDate = _formattedHeroDate;
    final heroSubtitle = _buildHeroSubtitle();
    final stravaUri = _stravaActivityUri;

    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: colorScheme.surfaceContainerHighest,
              foregroundColor: colorScheme.onSurface,
              leading: BackButton(onPressed: _handleBack),
              title: Text(
                widget.run.name.isEmpty
                    ? 'Run ${widget.run.id}'
                    : widget.run.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            SliverToBoxAdapter(
              child: _Body(
                runTitle: widget.run.name.isEmpty
                    ? 'Run ${widget.run.id}'
                    : widget.run.name,
                routePoints: routePoints,
                bounds: bounds,
                stats: stats,
                heroDate: heroDate,
                heroSubtitle: heroSubtitle,
                noteLines: noteLines,
                splits: splits,
                bestEfforts: bestEfforts,
                sourceLabel: sourceLabel,
                showMap: _showMap,
                stravaUri: stravaUri,
                onOpenStrava: stravaUri == null
                    ? null
                    : () => _openInStrava(stravaUri),
              ),
            ),
          ],
        ),
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
    final elapsedTime = _numberFromPayload('elapsed_time')?.round();

    final stats = <(String, String)>[
      ('Distance', '${widget.run.distanceKm.toStringAsFixed(2)} km'),
      ('Date', widget.run.startDateLocal),
    ];

    if (_formattedDuration != null) {
      stats.add(('Moving time', _formattedDuration!));
    }
    if (elapsedTime != null && elapsedTime > 0) {
      final h = elapsedTime ~/ 3600;
      final m = (elapsedTime % 3600) ~/ 60;
      stats.add(('Elapsed time', h > 0 ? '${h}h ${m}m' : '${m}m'));
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
    final summaryPayload = widget.summary.payload;
    final detailPayload = widget.detail.payload;

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

  String? get _runSource {
    final summarySource = widget.summary.payload['source']?.toString().trim();
    if (summarySource != null && summarySource.isNotEmpty) return summarySource;
    final detailSource = widget.detail.payload['source']?.toString().trim();
    if (detailSource != null && detailSource.isNotEmpty) return detailSource;
    final modelSource = widget.run.source.trim();
    if (modelSource.isNotEmpty) return modelSource;
    return null;
  }

  String? get _runSourceLabel {
    final summaryLabel = widget.summary.payload['source_label']
        ?.toString()
        .trim();
    if (summaryLabel != null && summaryLabel.isNotEmpty) return summaryLabel;
    final detailLabel = widget.detail.payload['source_label']
        ?.toString()
        .trim();
    if (detailLabel != null && detailLabel.isNotEmpty) return detailLabel;
    final modelLabel = widget.run.sourceLabel.trim();
    if (modelLabel.isNotEmpty) return modelLabel;
    final source = _runSource;
    if (source == 'strava') return 'Strava';
    if (source == null || source.isEmpty) return null;
    return source.replaceAll('_', ' ');
  }

  /// Parse per-km splits from Strava detail JSON.
  /// The data can be either a list or wrapped in {"0": [...]}.
  List<_Split> _parseSplits() {
    final raw =
        widget.detail.payload['splits_metric'] ??
        widget.summary.payload['splits_metric'];
    if (raw == null) return const [];

    List<dynamic> items;
    if (raw is List) {
      items = raw;
    } else if (raw is Map) {
      // Strava export wraps in {"0": [...]}
      final inner = raw['0'] ?? raw.values.first;
      if (inner is List) {
        items = inner;
      } else {
        return const [];
      }
    } else {
      return const [];
    }

    return items.whereType<Map>().map((s) {
      final distance = (s['distance'] as num?)?.toDouble() ?? 0;
      final movingTime = (s['moving_time'] as num?)?.toInt() ?? 0;
      final elevDiff = (s['elevation_difference'] as num?)?.toDouble() ?? 0;
      final split = (s['split'] as num?)?.toInt() ?? 0;
      final avgSpeed = (s['average_speed'] as num?)?.toDouble() ?? 0;
      return _Split(
        km: split,
        distance: distance,
        movingTimeSeconds: movingTime,
        elevationDiff: elevDiff,
        avgSpeedMs: avgSpeed,
      );
    }).toList();
  }

  /// Parse best efforts from Strava detail JSON.
  List<_BestEffort> _parseBestEfforts() {
    final raw =
        widget.detail.payload['best_efforts'] ??
        widget.summary.payload['best_efforts'];
    if (raw == null) return const [];

    List<dynamic> items;
    if (raw is List) {
      items = raw;
    } else if (raw is Map) {
      final inner = raw['0'] ?? raw.values.first;
      if (inner is List) {
        items = inner;
      } else {
        return const [];
      }
    } else {
      return const [];
    }

    return items.whereType<Map>().map((e) {
      final name = (e['name'] ?? '').toString();
      final elapsedTime = (e['elapsed_time'] as num?)?.toInt() ?? 0;
      final distance = (e['distance'] as num?)?.toDouble() ?? 0;
      return _BestEffort(
        name: name,
        elapsedTimeSeconds: elapsedTime,
        distance: distance,
      );
    }).toList();
  }

  List<LatLng> _decodePolylinePoints() {
    final polyline =
        _stringFromPayload('summary_polyline') ?? widget.run.summaryPolyline;
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
    final summaryValue = widget.summary.payload[key];
    if (summaryValue != null && summaryValue.toString().trim().isNotEmpty) {
      return summaryValue.toString();
    }
    final detailValue = widget.detail.payload[key];
    if (detailValue != null && detailValue.toString().trim().isNotEmpty) {
      return detailValue.toString();
    }
    return null;
  }

  double? _numberFromPayload(String key) {
    final value = widget.summary.payload[key] ?? widget.detail.payload[key];
    if (value is num) return value.toDouble();
    if (value is Map) {
      // Strava export: {"0": 1234}
      final inner = value['0'] ?? value.values.first;
      if (inner is num) return inner.toDouble();
      return double.tryParse(inner?.toString() ?? '');
    }
    return double.tryParse(value?.toString() ?? '');
  }

  String _formatPace(double speedKmH) {
    if (speedKmH <= 0) return '--';
    final totalSeconds = (3600 / speedKmH).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')} /km';
  }

  String? get _formattedHeroDate {
    final raw = widget.run.startDateLocal.trim();
    if (raw.isEmpty) return null;
    final parsed = _parseRunDisplayDateTime(
      rawDate: raw,
      rawTime: widget.run.startTime.trim(),
    );
    if (parsed != null) {
      return DateFormat('EEE, d MMM · HH:mm').format(parsed);
    }

    final parsedDateOnly = DateTime.tryParse(raw.split('T').first);
    if (parsedDateOnly != null) {
      return DateFormat('EEE, d MMM').format(parsedDateOnly);
    }
    return raw;
  }

  DateTime? _parseRunDisplayDateTime({
    required String rawDate,
    required String rawTime,
  }) {
    final dateValue = rawDate.trim();
    if (dateValue.isEmpty) return null;

    // Strava's `start_date_local` is sometimes stored with a trailing `Z`
    // even though the clock time is already local. Treat it as wall-clock local
    // time to avoid shifting it twice in the UI.
    if (dateValue.contains('T')) {
      final normalized = dateValue.endsWith('Z')
          ? dateValue.substring(0, dateValue.length - 1)
          : dateValue;
      final parsed = DateTime.tryParse(normalized);
      if (parsed != null && (parsed.hour != 0 || parsed.minute != 0)) {
        return parsed;
      }
    }

    final baseDate = DateTime.tryParse(dateValue.split('T').first);
    if (baseDate == null) return null;

    final parsedTime = _parseTimeOfDay(rawTime);
    if (parsedTime == null) return baseDate;

    return DateTime(
      baseDate.year,
      baseDate.month,
      baseDate.day,
      parsedTime.hour,
      parsedTime.minute,
      parsedTime.second,
    );
  }

  _ParsedTime? _parseTimeOfDay(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    final hhmmss = RegExp(
      r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$',
    ).firstMatch(value);
    if (hhmmss != null) {
      return _ParsedTime(
        hour: int.parse(hhmmss.group(1)!),
        minute: int.parse(hhmmss.group(2)!),
        second: int.parse(hhmmss.group(3) ?? '0'),
      );
    }

    final isoTime = RegExp(r'T(\d{2}):(\d{2})(?::(\d{2}))?').firstMatch(value);
    if (isoTime != null) {
      return _ParsedTime(
        hour: int.parse(isoTime.group(1)!),
        minute: int.parse(isoTime.group(2)!),
        second: int.parse(isoTime.group(3) ?? '0'),
      );
    }

    return null;
  }

  String? _buildHeroSubtitle() {
    final pieces = <String>[];
    final place = _stringFromPayload('place')?.trim();
    final sourceLabel = _runSourceLabel?.trim();
    if (place != null && place.isNotEmpty) {
      pieces.add(place);
    }
    if (sourceLabel != null && sourceLabel.isNotEmpty) {
      pieces.add(sourceLabel);
    }
    if (pieces.isEmpty) return null;
    return pieces.join('  •  ');
  }

  Uri? get _stravaActivityUri {
    if (_runSource != 'strava') return null;
    final activityId = _activityIdFromPayload();
    if (activityId == null || activityId.isEmpty) return null;
    return Uri.parse('https://www.strava.com/activities/$activityId');
  }

  String? _activityIdFromPayload() {
    final raw =
        widget.detail.payload['id'] ??
        widget.summary.payload['id'] ??
        widget.detail.payload['activity_id'] ??
        widget.summary.payload['activity_id'];
    if (raw is Map) {
      final inner = raw['0'] ?? (raw.isNotEmpty ? raw.values.first : null);
      final id = inner?.toString().trim() ?? '';
      return id.isEmpty ? null : id;
    }
    final id = raw?.toString().trim() ?? '';
    return id.isEmpty ? null : id;
  }

  Future<void> _openInStrava(Uri webUri) async {
    if (kIsWeb) {
      final openedWeb = await launchUrl(
        webUri,
        mode: LaunchMode.platformDefault,
      );
      if (openedWeb || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open Strava for this activity.'),
        ),
      );
      return;
    }

    final activityId = webUri.pathSegments.isNotEmpty
        ? webUri.pathSegments.last
        : '';
    final appUri = activityId.isEmpty
        ? null
        : Uri.parse('strava://activities/$activityId');

    final openedApp =
        appUri != null &&
        await launchUrl(appUri, mode: LaunchMode.externalApplication);
    if (openedApp || !mounted) return;

    final openedWeb = await launchUrl(
      webUri,
      mode: LaunchMode.externalApplication,
    );
    if (openedWeb || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open Strava for this activity.')),
    );
  }
}

// ── Data models ──────────────────────────────────────────────────────────────

class _Split {
  const _Split({
    required this.km,
    required this.distance,
    required this.movingTimeSeconds,
    required this.elevationDiff,
    required this.avgSpeedMs,
  });

  final int km;
  final double distance;
  final int movingTimeSeconds;
  final double elevationDiff;
  final double avgSpeedMs;

  /// Pace as min:ss /km. Speed is in m/s.
  String get pace {
    if (avgSpeedMs <= 0) return '--';
    final secsPerKm = (1000 / avgSpeedMs).round();
    final m = secsPerKm ~/ 60;
    final s = secsPerKm % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _BestEffort {
  const _BestEffort({
    required this.name,
    required this.elapsedTimeSeconds,
    required this.distance,
  });

  final String name;
  final int elapsedTimeSeconds;
  final double distance;

  String get formattedTime {
    final h = elapsedTimeSeconds ~/ 3600;
    final m = (elapsedTimeSeconds % 3600) ~/ 60;
    final s = elapsedTimeSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _ParsedTime {
  const _ParsedTime({
    required this.hour,
    required this.minute,
    required this.second,
  });

  final int hour;
  final int minute;
  final int second;
}

// ── Body ─────────────────────────────────────────────────────────────────────

class _Body extends StatelessWidget {
  const _Body({
    required this.runTitle,
    required this.routePoints,
    required this.bounds,
    required this.stats,
    required this.heroDate,
    required this.heroSubtitle,
    required this.noteLines,
    required this.splits,
    required this.bestEfforts,
    required this.sourceLabel,
    required this.showMap,
    required this.stravaUri,
    required this.onOpenStrava,
  });

  final String runTitle;
  final List<LatLng> routePoints;
  final LatLngBounds? bounds;
  final List<(String, String)> stats;
  final String? heroDate;
  final String? heroSubtitle;
  final List<String> noteLines;
  final List<_Split> splits;
  final List<_BestEffort> bestEfforts;
  final String? sourceLabel;
  final bool showMap;
  final Uri? stravaUri;
  final VoidCallback? onOpenStrava;

  @override
  Widget build(BuildContext context) {
    final hasMap = showMap && routePoints.length >= 2;
    const maxContentWidth = 960.0;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxContentWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          child: Column(
            children: [
              _RunOverviewSection(
                title: runTitle,
                subtitle: heroSubtitle,
                dateLabel: heroDate,
                stravaUri: stravaUri,
                onOpenStrava: onOpenStrava,
              ),
              if (hasMap) const SizedBox(height: 16),
              if (hasMap)
                _RunMapSection(
                  points: routePoints,
                  bounds: bounds,
                  stravaUri: stravaUri,
                  onOpenStrava: onOpenStrava,
                ),
              if (hasMap) const SizedBox(height: 16),
              _StatsSection(stats: stats),
              if (splits.isNotEmpty) const SizedBox(height: 12),
              if (splits.isNotEmpty) _SplitsSection(splits: splits),
              if (bestEfforts.isNotEmpty) const SizedBox(height: 12),
              if (bestEfforts.isNotEmpty)
                _BestEffortsSection(efforts: bestEfforts),
              if (noteLines.isNotEmpty) const SizedBox(height: 12),
              if (noteLines.isNotEmpty) _DetailsSection(noteLines: noteLines),
              if (sourceLabel != null && sourceLabel!.isNotEmpty)
                const SizedBox(height: 14),
              if (sourceLabel != null && sourceLabel!.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: _SourceFooter(label: sourceLabel!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunOverviewSection extends StatelessWidget {
  const _RunOverviewSection({
    required this.title,
    required this.subtitle,
    required this.dateLabel,
    required this.stravaUri,
    required this.onOpenStrava,
  });

  final String title;
  final String? subtitle;
  final String? dateLabel;
  final Uri? stravaUri;
  final VoidCallback? onOpenStrava;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (dateLabel != null && dateLabel!.isNotEmpty)
                      Text(
                        dateLabel!,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    if (dateLabel != null && dateLabel!.isNotEmpty)
                      const SizedBox(height: 8),
                    Text(
                      title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      const SizedBox(height: 8),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ),
              if (stravaUri != null && onOpenStrava != null)
                const SizedBox(width: 16),
              if (stravaUri != null && onOpenStrava != null)
                FilledButton.tonalIcon(
                  onPressed: onOpenStrava,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF56B1F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Strava'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RunMapSection extends StatelessWidget {
  const _RunMapSection({
    required this.points,
    required this.bounds,
    required this.stravaUri,
    required this.onOpenStrava,
  });

  final List<LatLng> points;
  final LatLngBounds? bounds;
  final Uri? stravaUri;
  final VoidCallback? onOpenStrava;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Route',
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: _RouteMapCard(points: points, bounds: bounds, height: 320),
    );
  }
}

class _SourceFooter extends StatelessWidget {
  const _SourceFooter({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          'Origin',
          style: theme.textTheme.labelMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Sections ─────────────────────────────────────────────────────────────────

class _StatsSection extends StatelessWidget {
  const _StatsSection({required this.stats});

  final List<(String, String)> stats;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Run stats',
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: stats
            .map((stat) => _StatCard(label: stat.$1, value: stat.$2))
            .toList(),
      ),
    );
  }
}

class _SplitsSection extends StatelessWidget {
  const _SplitsSection({required this.splits});

  final List<_Split> splits;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Find fastest/slowest pace for the bar chart scale
    final paces = splits
        .where((s) => s.avgSpeedMs > 0)
        .map((s) => 1000 / s.avgSpeedMs) // seconds per km
        .toList();
    if (paces.isEmpty) return const SizedBox.shrink();
    final fastestPace = paces.reduce(math.min);
    final slowestPace = paces.reduce(math.max);
    final paceRange = slowestPace - fastestPace;

    return SectionCard(
      title: 'Splits',
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      child: Column(
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  child: Text(
                    'km',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    'Pace',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    'Elev',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ...splits.map((split) {
            final secsPerKm = split.avgSpeedMs > 0
                ? 1000 / split.avgSpeedMs
                : 0.0;
            // Bar fill: 1.0 = fastest, smaller = slower
            final barFraction = paceRange > 0
                ? 1.0 - ((secsPerKm - fastestPace) / paceRange) * 0.6
                : 1.0;
            final isFastest = secsPerKm == fastestPace && splits.length > 1;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: Text(
                      '${split.km}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LayoutBuilder(
                          builder: (context, constraints) {
                            return Stack(
                              children: [
                                Container(
                                  height: 22,
                                  width:
                                      constraints.maxWidth *
                                      barFraction.clamp(0.1, 1.0),
                                  decoration: BoxDecoration(
                                    color: isFastest
                                        ? colorScheme.primary.withValues(
                                            alpha: 0.25,
                                          )
                                        : colorScheme.primaryContainer
                                              .withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                Positioned.fill(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: Text(
                                        '${split.pace} /km',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontWeight: isFastest
                                                  ? FontWeight.w800
                                                  : FontWeight.w600,
                                              color: isFastest
                                                  ? colorScheme.primary
                                                  : colorScheme.onSurface,
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      '${split.elevationDiff >= 0 ? '+' : ''}${split.elevationDiff.toStringAsFixed(0)}m',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: split.elevationDiff >= 0
                            ? colorScheme.error
                            : colorScheme.tertiary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _BestEffortsSection extends StatelessWidget {
  const _BestEffortsSection({required this.efforts});

  final List<_BestEffort> efforts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SectionCard(
      title: 'Best efforts',
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: efforts.map((e) {
          return Container(
            width: 132,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.formattedTime,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _DetailsSection extends StatelessWidget {
  const _DetailsSection({required this.noteLines});

  final List<String> noteLines;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SectionCard(
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
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

// ── Reusable widgets ─────────────────────────────────────────────────────────

class _RouteMapCard extends StatelessWidget {
  const _RouteMapCard({
    required this.points,
    required this.bounds,
    this.height = 280,
  });

  final List<LatLng> points;
  final LatLngBounds? bounds;
  final double height;

  @override
  Widget build(BuildContext context) {
    final tileConfig = AppConfig.mapTileConfig('light');
    final cameraFit = _cameraFitForPoints();
    return SizedBox(
      height: height,
      child: FlutterMap(
        options: MapOptions(
          initialCameraFit: cameraFit,
          initialCenter: cameraFit == null ? points.first : const LatLng(0, 0),
          initialZoom: cameraFit == null ? 13 : 2,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom,
          ),
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
                strokeWidth: 7,
                color: const Color(0xFFF56B1F),
                borderStrokeWidth: 2,
                borderColor: Colors.white.withValues(alpha: 0.92),
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
                    color: const Color(0xFFF56B1F),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                ),
              ),
              Marker(
                point: points.last,
                width: 20,
                height: 20,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF111827),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  CameraFit? _cameraFitForPoints() {
    if (points.isEmpty) return null;
    if (points.length == 1) {
      return CameraFit.coordinates(
        coordinates: [points.first],
        maxZoom: 15,
        padding: const EdgeInsets.all(28),
      );
    }

    final safeBounds = bounds ?? LatLngBounds.fromPoints(points);
    if (safeBounds.north == safeBounds.south &&
        safeBounds.east == safeBounds.west) {
      return CameraFit.coordinates(
        coordinates: [points.first],
        maxZoom: 15,
        padding: const EdgeInsets.all(28),
      );
    }

    return CameraFit.bounds(
      bounds: safeBounds,
      padding: const EdgeInsets.all(28),
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
              : [colorScheme.surface, colorScheme.surfaceContainerLow],
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
