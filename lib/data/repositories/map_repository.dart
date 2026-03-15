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
