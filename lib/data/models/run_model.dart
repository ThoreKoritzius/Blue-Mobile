class RunModel {
  const RunModel({
    required this.id,
    required this.name,
    required this.startDateLocal,
    required this.distance,
    required this.summaryPolyline,
  });

  final String id;
  final String name;
  final String startDateLocal;
  final double distance;
  final String summaryPolyline;

  double get distanceKm => distance / 1000;

  factory RunModel.fromJson(Map<String, dynamic> json) {
    return RunModel(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      startDateLocal: (json['start_date_local'] ?? '').toString(),
      distance: (json['distance'] as num?)?.toDouble() ?? 0,
      summaryPolyline: (json['summary_polyline'] ?? '').toString(),
    );
  }
}
