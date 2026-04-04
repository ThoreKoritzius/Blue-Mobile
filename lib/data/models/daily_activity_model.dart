class DailyActivityModel {
  const DailyActivityModel({
    required this.stepCount,
    required this.distanceM,
    required this.cyclingDurationMs,
  });

  final int? stepCount;
  final double? distanceM;
  final int? cyclingDurationMs;

  factory DailyActivityModel.fromJson(Map<String, dynamic> json) {
    return DailyActivityModel(
      stepCount: (json['stepCount'] as num?)?.toInt(),
      distanceM: (json['distanceM'] as num?)?.toDouble(),
      cyclingDurationMs: (json['cyclingDurationMs'] as num?)?.toInt(),
    );
  }
}
