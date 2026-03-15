class DayMediaModel {
  const DayMediaModel({
    required this.path,
    required this.date,
    required this.type,
    required this.gps,
    required this.favorite,
  });

  final String path;
  final String date;
  final String type;
  final String gps;
  final bool favorite;

  String get fileName => path.split('/').last;

  factory DayMediaModel.fromJson(Map<String, dynamic> json) {
    return DayMediaModel(
      path: (json['path'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      gps: (json['gps'] ?? '').toString(),
      favorite: json['favorite'] == true,
    );
  }
}
