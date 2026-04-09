class DailyWeatherModel {
  const DailyWeatherModel({
    required this.date,
    this.timezoneName,
    this.weatherCode,
    this.temperatureMaxC,
    this.temperatureMinC,
    this.apparentTemperatureMaxC,
    this.apparentTemperatureMinC,
    this.precipitationSumMm,
    this.precipitationHours,
    this.windSpeedMaxKmh,
    this.daylightDurationSeconds,
    this.sunshineDurationSeconds,
    this.sunriseAt,
    this.sunsetAt,
    this.locationLabel,
    this.source,
    this.sourceLabel,
  });

  final String date;
  final String? timezoneName;
  final int? weatherCode;
  final double? temperatureMaxC;
  final double? temperatureMinC;
  final double? apparentTemperatureMaxC;
  final double? apparentTemperatureMinC;
  final double? precipitationSumMm;
  final double? precipitationHours;
  final double? windSpeedMaxKmh;
  final double? daylightDurationSeconds;
  final double? sunshineDurationSeconds;
  final DateTime? sunriseAt;
  final DateTime? sunsetAt;
  final String? locationLabel;
  final String? source;
  final String? sourceLabel;

  factory DailyWeatherModel.fromJson(Map<String, dynamic> json) {
    return DailyWeatherModel(
      date: (json['date'] ?? '').toString(),
      timezoneName: json['timezoneName']?.toString(),
      weatherCode: (json['weatherCode'] as num?)?.toInt(),
      temperatureMaxC: (json['temperatureMaxC'] as num?)?.toDouble(),
      temperatureMinC: (json['temperatureMinC'] as num?)?.toDouble(),
      apparentTemperatureMaxC:
          (json['apparentTemperatureMaxC'] as num?)?.toDouble(),
      apparentTemperatureMinC:
          (json['apparentTemperatureMinC'] as num?)?.toDouble(),
      precipitationSumMm: (json['precipitationSumMm'] as num?)?.toDouble(),
      precipitationHours: (json['precipitationHours'] as num?)?.toDouble(),
      windSpeedMaxKmh: (json['windSpeedMaxKmh'] as num?)?.toDouble(),
      daylightDurationSeconds:
          (json['daylightDurationSeconds'] as num?)?.toDouble(),
      sunshineDurationSeconds:
          (json['sunshineDurationSeconds'] as num?)?.toDouble(),
      sunriseAt: DateTime.tryParse((json['sunriseAt'] ?? '').toString()),
      sunsetAt: DateTime.tryParse((json['sunsetAt'] ?? '').toString()),
      locationLabel: json['locationLabel']?.toString(),
      source: json['source']?.toString(),
      sourceLabel: json['sourceLabel']?.toString(),
    );
  }
}
