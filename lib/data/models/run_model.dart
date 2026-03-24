class RunModel {
  const RunModel({
    required this.id,
    required this.name,
    required this.startDateLocal,
    required this.distance,
    required this.summaryPolyline,
    required this.movingTime,
    required this.averageSpeed,
    required this.startTime,
  });

  final String id;
  final String name;
  final String startDateLocal;
  final double distance;
  final String summaryPolyline;
  final int movingTime;
  final double averageSpeed;
  final String startTime;

  double get distanceKm => distance / 1000;
  int get movingMinutes => movingTime ~/ 60;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'start_date_local': startDateLocal,
      'distance': distance,
      'summary_polyline': summaryPolyline,
      'moving_time': movingTime,
      'average_speed': averageSpeed,
      'start_time': startTime,
    };
  }

  factory RunModel.fromJson(Map<String, dynamic> json) {
    return RunModel(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      startDateLocal: (json['start_date_local'] ?? '').toString(),
      distance: (json['distance'] as num?)?.toDouble() ?? 0,
      summaryPolyline: (json['summary_polyline'] ?? '').toString(),
      movingTime: (json['moving_time'] as num?)?.toInt() ?? 0,
      averageSpeed: (json['average_speed'] as num?)?.toDouble() ?? 0,
      startTime: (json['start_time'] ?? '').toString(),
    );
  }
}
