class RunModel {
  const RunModel({
    required this.id,
    required this.name,
    required this.type,
    required this.startDateLocal,
    required this.distance,
    required this.summaryPolyline,
    required this.movingTime,
    required this.averageSpeed,
    required this.startTime,
    required this.source,
    required this.sourceLabel,
  });

  final String id;
  final String name;
  final String type;
  final String startDateLocal;
  final double distance;
  final String summaryPolyline;
  final int movingTime;
  final double averageSpeed;
  final String startTime;
  final String source;
  final String sourceLabel;

  double get distanceKm => distance / 1000;
  int get movingMinutes => movingTime ~/ 60;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'startDateLocal': startDateLocal,
      'distance': distance,
      'summaryPolyline': summaryPolyline,
      'movingTime': movingTime,
      'averageSpeed': averageSpeed,
      'startTime': startTime,
      'source': source,
      'sourceLabel': sourceLabel,
    };
  }

  factory RunModel.fromJson(Map<String, dynamic> json) {
    final rawName = (json['name'] ?? '').toString();
    final rawId = (json['id'] ?? '').toString();
    final source = (json['source'] ?? '').toString();
    final rawType = (json['type'] ?? '').toString();
    return RunModel(
      id: rawId,
      name: rawName,
      type: rawType,
      startDateLocal: (json['startDateLocal'] ?? json['start_date_local'] ?? '')
          .toString(),
      distance: (json['distance'] as num?)?.toDouble() ?? 0,
      summaryPolyline:
          (json['summaryPolyline'] ?? json['summary_polyline'] ?? '')
              .toString(),
      movingTime:
          (json['movingTime'] ?? json['moving_time'] as num?)?.toInt() ?? 0,
      averageSpeed:
          (json['averageSpeed'] ?? json['average_speed'] as num?)?.toDouble() ??
          0,
      startTime: (json['startTime'] ?? json['start_time'] ?? '').toString(),
      source: source,
      sourceLabel:
          (json['sourceLabel'] ??
                  json['source_label'] ??
                  _sourceLabelFor(source))
              .toString(),
    );
  }

  static String _sourceLabelFor(String source) {
    if (source == 'strava') return 'Strava';
    if (source == 'runtastic') return 'Runtastic';
    if (source == 'samsung_health') return 'Samsung Health';
    if (source.isEmpty) return '';
    return source.replaceAll('_', ' ');
  }
}
