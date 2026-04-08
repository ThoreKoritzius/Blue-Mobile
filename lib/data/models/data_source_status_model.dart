class DataSourceStatusModel {
  const DataSourceStatusModel({
    required this.key,
    required this.name,
    required this.description,
    required this.status,
    required this.automated,
    this.lastSyncAt,
  });

  final String key;
  final String name;
  final String description;
  final String status;
  final bool automated;
  final DateTime? lastSyncAt;

  factory DataSourceStatusModel.fromJson(Map<String, dynamic> json) {
    return DataSourceStatusModel(
      key: (json['key'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      automated: json['automated'] == true,
      lastSyncAt: DateTime.tryParse((json['lastSyncAt'] ?? '').toString()),
    );
  }
}
