import 'package:flutter/foundation.dart';

import '../../core/config/app_config.dart';
import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/run_model.dart';
import 'files_repository.dart';
import 'runs_repository.dart';

class MapPoint {
  const MapPoint({
    required this.date,
    required this.lat,
    required this.lon,
    required this.path,
  });

  final String date;
  final double lat;
  final double lon;
  final String path;
}

class MapImagePage {
  const MapImagePage({required this.points, required this.hasMore});

  final List<MapPoint> points;
  final bool hasMore;
}

class TimelineImageLocation {
  const TimelineImageLocation({
    required this.path,
    required this.lat,
    required this.lon,
  });

  final String path;
  final double lat;
  final double lon;
}

class TimelineRun {
  const TimelineRun({
    required this.id,
    required this.name,
    required this.summaryPolyline,
    this.startTime,
    this.distanceMeters,
    this.movingTimeSeconds,
  });

  final String id;
  final String name;
  final String summaryPolyline;
  final DateTime? startTime;
  final int? distanceMeters;
  final int? movingTimeSeconds;
}

class TimelineCalendarEvent {
  const TimelineCalendarEvent({
    required this.id,
    required this.summary,
    this.description,
    this.location,
    this.status,
    this.start,
    this.end,
    this.isAllDay = false,
    this.htmlLink,
    this.source,
    this.sourceName,
    this.sourceId,
  });

  final String id;
  final String summary;
  final String? description;
  final String? location;
  final String? status;
  final DateTime? start;
  final DateTime? end;
  final bool isAllDay;
  final String? htmlLink;
  final String? source;
  final String? sourceName;
  final String? sourceId;
}

class TimelineWalkPoint {
  const TimelineWalkPoint({required this.lat, required this.lon});

  final double lat;
  final double lon;
}

class TimelineVisit {
  const TimelineVisit({
    required this.placeId,
    required this.durationMinutes,
    this.placeName,
    this.placeAddress,
    this.lat,
    this.lon,
    this.startTime,
    this.endTime,
  });

  final String placeId;
  final int durationMinutes;
  final String? placeName;
  final String? placeAddress;
  final double? lat;
  final double? lon;
  final DateTime? startTime;
  final DateTime? endTime;
}

/// A unified segment from the timeline (VISIT or ACTIVITY), ordered by startTime.
class TimelineSegment {
  const TimelineSegment({
    this.id,
    required this.segmentType,
    required this.startTime,
    this.endTime,
    this.durationMinutes = 0,
    this.placeId,
    this.placeName,
    this.placeAddress,
    this.placeLat,
    this.placeLon,
    this.activityType,
    this.distanceMeters,
    this.startLat,
    this.startLon,
    this.endLat,
    this.endLon,
    this.matchedRunId,
    this.source,
  });

  final int? id;
  final String segmentType; // 'VISIT' or 'ACTIVITY'
  final DateTime startTime;
  final DateTime? endTime;
  final int durationMinutes;
  // Visit fields
  final String? placeId;
  final String? placeName;
  final String? placeAddress;
  final double? placeLat;
  final double? placeLon;
  // Activity fields
  final String? activityType;
  final int? distanceMeters;
  final double? startLat;
  final double? startLon;
  final double? endLat;
  final double? endLon;

  /// Run ID matched from the runs list (by start time proximity).
  final String? matchedRunId;
  final String? source;

  bool get isVisit => segmentType == 'VISIT';
  bool get isActivity => segmentType == 'ACTIVITY';
  bool get isManual => source == 'manual' || source == 'story_backfill';
}

class TimelineDayData {
  const TimelineDayData({
    required this.date,
    required this.walkPoints,
    required this.runs,
    required this.imageLocations,
    this.calendarEvents = const [],
    this.visits = const [],
    this.segments = const [],
  });

  final String date;
  final List<TimelineWalkPoint> walkPoints;
  final List<TimelineRun> runs;
  final List<TimelineImageLocation> imageLocations;
  final List<TimelineCalendarEvent> calendarEvents;
  final List<TimelineVisit> visits;
  final List<TimelineSegment> segments;

  bool get hasData =>
      visits.isNotEmpty ||
      runs.isNotEmpty ||
      imageLocations.isNotEmpty ||
      calendarEvents.isNotEmpty;
}

class WhenWasINearResult {
  const WhenWasINearResult({
    required this.location,
    required this.dates,
    this.latMin,
    this.latMax,
    this.lonMin,
    this.lonMax,
  });

  factory WhenWasINearResult.empty(String location) =>
      WhenWasINearResult(location: location, dates: const []);

  final String location;
  final List<String> dates;
  final double? latMin;
  final double? latMax;
  final double? lonMin;
  final double? lonMax;
}

class MapRepository {
  static final RegExp _gpsPattern = RegExp(r'-?\d+(?:\.\d+)?');
  static const Duration timelineDayCacheTtl = Duration(minutes: 5);

  MapRepository(FilesRepository _, this._runsRepository, this._gql);

  final RunsRepository _runsRepository;
  final GraphqlService _gql;
  final Map<String, ({DateTime cachedAt, TimelineDayData data})>
  _timelineDayCache = <String, ({DateTime cachedAt, TimelineDayData data})>{};
  final Map<String, Future<TimelineDayData>> _timelineDayInFlight =
      <String, Future<TimelineDayData>>{};

  Future<MapImagePage> searchImagePage({
    required int page,
    required int pageSize,
  }) async {
    final points = <MapPoint>[];
    try {
      final response = await _gql.query(
        GqlDocuments.searchImages,
        variables: {
          'input': {
            'input': '',
            'imageDays': 'images',
            'columns': <String>[],
            'limit': pageSize,
            'page': page,
            'pageSize': pageSize,
          },
          'first': pageSize,
        },
      );
      final connection =
          ((response['search'] as Map<String, dynamic>)['query']
              as Map<String, dynamic>? ??
          const {});
      final items = (connection['edges'] as List<dynamic>? ?? const [])
          .map((item) => (item as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .toList();

      for (final item in items) {
        final gps = _parseGps((item['gps'] ?? '').toString());
        final date = (item['date'] ?? '').toString();
        final rawPath = (item['path'] ?? '').toString();
        final fileName = rawPath.split('/').last;
        if (gps == null || date.isEmpty || fileName.isEmpty) continue;
        points.add(
          MapPoint(
            date: date,
            lat: gps.$1,
            lon: gps.$2,
            path: AppConfig.imageUrlFromPath(fileName, date: date),
          ),
        );
      }
      debugPrint(
        '[MAP] image page=$page raw=${items.length} usable=${points.length}',
      );
      return MapImagePage(points: points, hasMore: items.length >= pageSize);
    } catch (error, stackTrace) {
      debugPrint(
        '[MAP] searchImagePage error page=$page size=$pageSize: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<List<RunModel>> loadRuns() => _runsRepository.listRuns();

  Future<WhenWasINearResult> whenWasINear(String location) async {
    debugPrint('[TIMELINE] whenWasINear location=$location');
    final response = await _gql.query(
      GqlDocuments.timelineWhenWasINear,
      variables: {'location': location},
    );
    final raw =
        (response['timeline'] as Map<String, dynamic>?)?['whenWasINear']
            as Map<String, dynamic>?;
    if (raw == null) return WhenWasINearResult.empty(location);

    final resolvedLocation = (raw['location'] ?? location).toString();
    final dates = (raw['dates'] as List<dynamic>? ?? [])
        .map((d) => d.toString())
        .where((d) => d.isNotEmpty)
        .toList();
    final bb = raw['boundingBox'] as Map<String, dynamic>?;
    return WhenWasINearResult(
      location: resolvedLocation,
      dates: dates,
      latMin: (bb?['latMin'] as num?)?.toDouble(),
      latMax: (bb?['latMax'] as num?)?.toDouble(),
      lonMin: (bb?['lonMin'] as num?)?.toDouble(),
      lonMax: (bb?['lonMax'] as num?)?.toDouble(),
    );
  }

  Future<TimelineDayData> loadTimelineDay(
    String date, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = _timelineDayCache[date];
      if (cached != null &&
          DateTime.now().difference(cached.cachedAt) <= timelineDayCacheTtl) {
        debugPrint('[TIMELINE] cache hit date=$date');
        return cached.data;
      }
      final inFlight = _timelineDayInFlight[date];
      if (inFlight != null) {
        debugPrint('[TIMELINE] join in-flight date=$date');
        return inFlight;
      }
    } else {
      _timelineDayCache.remove(date);
    }
    final future = _loadTimelineDayUncached(date);
    _timelineDayInFlight[date] = future;
    try {
      final data = await future;
      _timelineDayCache[date] = (cachedAt: DateTime.now(), data: data);
      return data;
    } finally {
      _timelineDayInFlight.remove(date);
    }
  }

  Future<TimelineDayData> _loadTimelineDayUncached(String date) async {
    debugPrint('[TIMELINE] loadTimelineDay date=$date');
    late final Map<String, dynamic> response;
    try {
      response = await _gql.query(
        GqlDocuments.timelineDay,
        variables: {'date': date},
      );
    } catch (error, stackTrace) {
      debugPrint('[TIMELINE] query failed date=$date error=$error');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
    debugPrint('[TIMELINE] raw response keys=${response.keys.toList()}');

    try {
      final timeline =
          _asMap(response['timeline']) ?? const <String, dynamic>{};
      debugPrint('[TIMELINE] timeline keys=${timeline.keys.toList()}');

      // polyline returns [{lat, lon, timestamp}] JSON array
      final rawPolyline = timeline['polyline'];
      debugPrint('[TIMELINE] polyline raw type=${rawPolyline.runtimeType}');
      final walkPoints = <TimelineWalkPoint>[];
      var walkPointErrors = 0;
      for (final raw in _asList(rawPolyline)) {
        final p = _asMap(raw);
        if (p == null) {
          walkPointErrors += 1;
          continue;
        }
        try {
          final lat = (p['lat'] as num?)?.toDouble();
          final lon = (p['lon'] as num?)?.toDouble();
          if (lat == null || lon == null) continue;
          if (lat.abs() > 90 || lon.abs() > 180) continue;
          walkPoints.add(TimelineWalkPoint(lat: lat, lon: lon));
        } catch (error, stackTrace) {
          walkPointErrors += 1;
          _logTimelineItemError(
            date: date,
            section: 'polyline',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      debugPrint('[TIMELINE] walkPoints count=${walkPoints.length}');
      if (walkPointErrors > 0) {
        debugPrint('[TIMELINE] skipped $walkPointErrors invalid walk points');
      }

      final runs = <TimelineRun>[];
      final rawRuns = timeline['runs'];
      debugPrint('[TIMELINE] runs raw type=${rawRuns.runtimeType}');
      var runErrors = 0;
      for (final raw in _asList(rawRuns)) {
        final r = _asMap(raw);
        if (r == null) {
          runErrors += 1;
          continue;
        }
        try {
          DateTime? startTime;
          final rawStart = r['startTime'];
          if (rawStart is String && rawStart.isNotEmpty) {
            // startTime may be time-of-day ("06:30:00") or ISO datetime
            startTime =
                DateTime.tryParse(rawStart) ??
                DateTime.tryParse('${date}T$rawStart');
          }
          runs.add(
            TimelineRun(
              id: (r['id'] ?? '').toString(),
              name: (r['name'] ?? '').toString(),
              summaryPolyline: (r['summaryPolyline'] ?? '').toString(),
              startTime: startTime,
              distanceMeters: (r['distanceMeters'] as num?)?.toInt(),
              movingTimeSeconds: (r['movingTimeSeconds'] as num?)?.toInt(),
            ),
          );
        } catch (error, stackTrace) {
          runErrors += 1;
          _logTimelineItemError(
            date: date,
            section: 'runs',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      debugPrint('[TIMELINE] parsed ${runs.length} runs');
      if (runErrors > 0) {
        debugPrint('[TIMELINE] skipped $runErrors invalid runs');
      }

      final imageLocations = <TimelineImageLocation>[];
      final rawImgs = timeline['imageLocations'];
      debugPrint('[TIMELINE] image_locations raw type=${rawImgs.runtimeType}');
      var imageErrors = 0;
      for (final raw in _asList(rawImgs)) {
        final r = _asMap(raw);
        if (r == null) {
          imageErrors += 1;
          continue;
        }
        try {
          final lat = (r['lat'] as num?)?.toDouble();
          final lon = (r['lon'] as num?)?.toDouble();
          final path = (r['path'] ?? '').toString();
          if (lat == null || lon == null || path.isEmpty) continue;
          if (lat.abs() > 90 || lon.abs() > 180) continue;
          imageLocations.add(
            TimelineImageLocation(
              path: AppConfig.imageUrlFromPath(
                path.split('/').last,
                date: date,
              ),
              lat: lat,
              lon: lon,
            ),
          );
        } catch (error, stackTrace) {
          imageErrors += 1;
          _logTimelineItemError(
            date: date,
            section: 'imageLocations',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      debugPrint('[TIMELINE] parsed ${imageLocations.length} imageLocations');
      if (imageErrors > 0) {
        debugPrint('[TIMELINE] skipped $imageErrors invalid image locations');
      }

      final visits = <TimelineVisit>[];
      final segments = <TimelineSegment>[];
      final calendarEvents = <TimelineCalendarEvent>[];
      final rawSegs = timeline['segments'];
      var segmentErrors = 0;
      for (final raw in _asList(rawSegs)) {
        final s = _asMap(raw);
        if (s == null) {
          segmentErrors += 1;
          continue;
        }
        try {
          final segType = (s['segmentType'] as String?) ?? '';
          final segId = (s['id'] as num?)?.toInt();
          final segSource = s['source'] as String?;
          final rawStart = s['startTime'] as String?;
          final rawEnd = s['endTime'] as String?;
          final startTime = rawStart != null
              ? DateTime.tryParse(rawStart)
              : null;
          final endTime = rawEnd != null ? DateTime.tryParse(rawEnd) : null;
          final duration = (s['durationMinutes'] as num?)?.toInt() ?? 0;

          if (segType == 'VISIT') {
            final placeId = (s['placeId'] ?? '').toString();
            if (placeId.isEmpty) continue;
            if (duration < 5) continue;
            final placeName = (s['placeName'] as String?)?.isNotEmpty == true
                ? s['placeName'] as String
                : null;
            final placeAddress =
                (s['placeAddress'] as String?)?.isNotEmpty == true
                ? s['placeAddress'] as String
                : null;
            final lat = (s['placeLat'] as num?)?.toDouble();
            final lon = (s['placeLon'] as num?)?.toDouble();
            visits.add(
              TimelineVisit(
                placeId: placeId,
                durationMinutes: duration,
                placeName: placeName,
                placeAddress: placeAddress,
                lat: lat,
                lon: lon,
                startTime: startTime,
                endTime: endTime,
              ),
            );
            if (startTime != null) {
              segments.add(
                TimelineSegment(
                  id: segId,
                  segmentType: segType,
                  startTime: startTime,
                  endTime: endTime,
                  durationMinutes: duration,
                  placeId: placeId,
                  placeName: placeName,
                  placeAddress: placeAddress,
                  placeLat: lat,
                  placeLon: lon,
                  source: segSource,
                ),
              );
            }
          } else if (segType == 'ACTIVITY' && startTime != null) {
            // Try to match to a run by closest start time
            String? matchedRunId;
            if (runs.isNotEmpty) {
              TimelineRun? best;
              Duration bestDiff = const Duration(hours: 2);
              for (final run in runs) {
                if (run.startTime == null) continue;
                final diff = run.startTime!.difference(startTime).abs();
                if (diff < bestDiff) {
                  bestDiff = diff;
                  best = run;
                }
              }
              matchedRunId = best?.id;
            }
            segments.add(
              TimelineSegment(
                id: segId,
                segmentType: segType,
                startTime: startTime,
                endTime: endTime,
                durationMinutes: duration,
                activityType: (s['activityType'] as String?),
                distanceMeters: (s['distanceMeters'] as num?)?.toInt(),
                startLat: (s['startLat'] as num?)?.toDouble(),
                startLon: (s['startLon'] as num?)?.toDouble(),
                endLat: (s['endLat'] as num?)?.toDouble(),
                endLon: (s['endLon'] as num?)?.toDouble(),
                matchedRunId: matchedRunId,
                source: segSource,
              ),
            );
          }
        } catch (error, stackTrace) {
          segmentErrors += 1;
          _logTimelineItemError(
            date: date,
            section: 'segments',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      segments.sort((a, b) => a.startTime.compareTo(b.startTime));
      if (segmentErrors > 0) {
        debugPrint('[TIMELINE] skipped $segmentErrors invalid segments');
      }
      final rawCalendar = timeline['calendar'];
      var calendarErrors = 0;
      for (final raw in _asList(rawCalendar)) {
        final item = _asMap(raw);
        if (item == null) {
          calendarErrors += 1;
          continue;
        }
        try {
          final id = (item['id'] ?? '').toString();
          if (id.isEmpty) continue;
          final start = DateTime.tryParse((item['start'] ?? '').toString());
          final end = DateTime.tryParse((item['end'] ?? '').toString());
          calendarEvents.add(
            TimelineCalendarEvent(
              id: id,
              summary: (item['summary'] ?? '').toString(),
              description: (item['description'] as String?)?.trim(),
              location: (item['location'] as String?)?.trim(),
              status: (item['status'] as String?)?.trim(),
              start: start,
              end: end,
              isAllDay: item['isAllDay'] == true,
              htmlLink: (item['htmlLink'] as String?)?.trim(),
              source: (item['source'] as String?)?.trim(),
              sourceName: (item['sourceName'] as String?)?.trim(),
              sourceId: (item['sourceId'] as String?)?.trim(),
            ),
          );
        } catch (error, stackTrace) {
          calendarErrors += 1;
          _logTimelineItemError(
            date: date,
            section: 'calendar',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      calendarEvents.sort((a, b) {
        final aTime = a.start ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.start ?? DateTime.fromMillisecondsSinceEpoch(0);
        return aTime.compareTo(bTime);
      });
      if (calendarErrors > 0) {
        debugPrint(
          '[TIMELINE] skipped $calendarErrors invalid calendar events',
        );
      }
      debugPrint(
        '[TIMELINE] parsed ${visits.length} visits, ${segments.length} segments, ${calendarEvents.length} calendar events',
      );

      return TimelineDayData(
        date: date,
        walkPoints: walkPoints,
        runs: runs,
        imageLocations: imageLocations,
        calendarEvents: calendarEvents,
        visits: visits,
        segments: segments,
      );
    } catch (error, stackTrace) {
      debugPrint('[TIMELINE] parse failed date=$date error=$error');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> addManualVisit({
    required String date,
    required String startTime,
    required String endTime,
    required String placeName,
  }) async {
    await _gql.query(
      GqlDocuments.addManualVisit,
      variables: {
        'date': date,
        'startTime': startTime,
        'endTime': endTime,
        'placeName': placeName,
      },
    );
    _invalidateTimelineDay(date);
  }

  Future<void> addManualActivity({
    required String date,
    required String startTime,
    required String endTime,
    required String activityType,
    required String placeNameStart,
    required String placeNameEnd,
  }) async {
    await _gql.query(
      GqlDocuments.addManualActivity,
      variables: {
        'date': date,
        'startTime': startTime,
        'endTime': endTime,
        'activityType': activityType,
        'placeNameStart': placeNameStart,
        'placeNameEnd': placeNameEnd,
      },
    );
    _invalidateTimelineDay(date);
  }

  Future<void> deleteManualVisit(int segmentId) async {
    await _gql.query(
      GqlDocuments.deleteManualVisit,
      variables: {'segmentId': segmentId},
    );
    _timelineDayCache.clear();
  }

  (double, double)? _parseGps(String input) {
    final matches = _gpsPattern
        .allMatches(input)
        .map((match) => match.group(0))
        .whereType<String>()
        .toList();
    if (matches.length < 2) return null;
    var lat = double.tryParse(matches[0]);
    var lon = double.tryParse(matches[1]);
    if (lat == null || lon == null) return null;
    if (lat.abs() > 90 && lon.abs() <= 90) {
      final swappedLat = lon;
      lon = lat;
      lat = swappedLat;
    }
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return (lat, lon);
  }

  void _invalidateTimelineDay(String date) {
    _timelineDayCache.remove(date);
    _timelineDayInFlight.remove(date);
  }

  List<dynamic> _asList(Object? value) {
    if (value is List) return value;
    return const <dynamic>[];
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return null;
  }

  void _logTimelineItemError({
    required String date,
    required String section,
    required Object error,
    StackTrace? stackTrace,
  }) {
    debugPrint(
      '[TIMELINE] skipped invalid $section item date=$date error=$error',
    );
    if (stackTrace != null) {
      debugPrintStack(stackTrace: stackTrace, maxFrames: 4);
    }
  }
}
