class DailyActivityModel {
  const DailyActivityModel({
    required this.stepCount,
    required this.distanceM,
    required this.cyclingDurationMs,
    required this.source,
    required this.sourceLabel,
  });

  final int? stepCount;
  final double? distanceM;
  final int? cyclingDurationMs;
  final String? source;
  final String? sourceLabel;

  factory DailyActivityModel.fromJson(Map<String, dynamic> json) {
    return DailyActivityModel(
      stepCount: (json['stepCount'] as num?)?.toInt(),
      distanceM: (json['distanceM'] as num?)?.toDouble(),
      cyclingDurationMs: (json['cyclingDurationMs'] as num?)?.toInt(),
      source: json['source']?.toString(),
      sourceLabel: json['sourceLabel']?.toString(),
    );
  }
}
