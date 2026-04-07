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
    this.visits = const [],
    this.segments = const [],
  });

  final String date;
  final List<TimelineWalkPoint> walkPoints;
  final List<TimelineRun> runs;
  final List<TimelineImageLocation> imageLocations;
  final List<TimelineVisit> visits;
  final List<TimelineSegment> segments;

  bool get hasData =>
      visits.isNotEmpty || runs.isNotEmpty || imageLocations.isNotEmpty;
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

  MapRepository(FilesRepository _, this._runsRepository, this._gql);

  final RunsRepository _runsRepository;
  final GraphqlService _gql;

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

  Future<TimelineDayData> loadTimelineDay(String date) async {
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
          (response['timeline'] as Map<String, dynamic>?) ?? const {};
      debugPrint('[TIMELINE] timeline keys=${timeline.keys.toList()}');

      // polyline returns [{lat, lon, timestamp}] JSON array
      final rawPolyline = timeline['polyline'];
      debugPrint('[TIMELINE] polyline raw type=${rawPolyline.runtimeType}');
      final walkPoints = <TimelineWalkPoint>[];
      final polyList = rawPolyline is List
          ? rawPolyline
          : (rawPolyline as List<dynamic>? ?? []);
      for (final raw in polyList) {
        final p = raw as Map<String, dynamic>;
        final lat = (p['lat'] as num?)?.toDouble();
        final lon = (p['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        walkPoints.add(TimelineWalkPoint(lat: lat, lon: lon));
      }
      debugPrint('[TIMELINE] walkPoints count=${walkPoints.length}');

      final runs = <TimelineRun>[];
      final rawRuns = timeline['runs'];
      debugPrint('[TIMELINE] runs raw type=${rawRuns.runtimeType}');
      final runsList = rawRuns is List
          ? rawRuns
          : (rawRuns is String ? [] : (rawRuns as List<dynamic>? ?? []));
      for (final raw in runsList) {
        final r = raw as Map<String, dynamic>;
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
      }
      debugPrint('[TIMELINE] parsed ${runs.length} runs');

      final imageLocations = <TimelineImageLocation>[];
      final rawImgs = timeline['imageLocations'];
      debugPrint('[TIMELINE] image_locations raw type=${rawImgs.runtimeType}');
      final imgList = rawImgs is List
          ? rawImgs
          : (rawImgs is String ? [] : (rawImgs as List<dynamic>? ?? []));
      for (final raw in imgList) {
        final r = raw as Map<String, dynamic>;
        final lat = (r['lat'] as num?)?.toDouble();
        final lon = (r['lon'] as num?)?.toDouble();
        final path = (r['path'] ?? '').toString();
        if (lat == null || lon == null || path.isEmpty) continue;
        if (lat.abs() > 90 || lon.abs() > 180) continue;
        imageLocations.add(
          TimelineImageLocation(
            path: AppConfig.imageUrlFromPath(path.split('/').last, date: date),
            lat: lat,
            lon: lon,
          ),
        );
      }
      debugPrint('[TIMELINE] parsed ${imageLocations.length} imageLocations');

      final visits = <TimelineVisit>[];
      final segments = <TimelineSegment>[];
      final rawSegs = timeline['segments'];
      final segList = rawSegs is List
          ? rawSegs
          : (rawSegs is String ? [] : (rawSegs as List<dynamic>? ?? []));
      for (final raw in segList) {
        final s = raw as Map<String, dynamic>;
        final segType = (s['segmentType'] as String?) ?? '';
        final segId = (s['id'] as num?)?.toInt();
        final segSource = s['source'] as String?;
        final rawStart = s['startTime'] as String?;
        final rawEnd = s['endTime'] as String?;
        final startTime = rawStart != null ? DateTime.tryParse(rawStart) : null;
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
      }
      segments.sort((a, b) => a.startTime.compareTo(b.startTime));
      debugPrint(
        '[TIMELINE] parsed ${visits.length} visits, ${segments.length} segments',
      );

      return TimelineDayData(
        date: date,
        walkPoints: walkPoints,
        runs: runs,
        imageLocations: imageLocations,
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
  }

  Future<void> deleteManualVisit(int segmentId) async {
    await _gql.query(
      GqlDocuments.deleteManualVisit,
      variables: {'segmentId': segmentId},
    );
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
}
