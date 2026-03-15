class CalendarEventModel {
  const CalendarEventModel({
    required this.id,
    required this.summary,
    required this.start,
    required this.end,
    required this.location,
    required this.allDay,
  });

  final String id;
  final String summary;
  final String start;
  final String end;
  final String location;
  final bool allDay;

  factory CalendarEventModel.fromJson(Map<String, dynamic> json) {
    final startData = json['start'] as Map<String, dynamic>?;
    final endData = json['end'] as Map<String, dynamic>?;
    return CalendarEventModel(
      id: (json['id'] ?? '').toString(),
      summary: (json['summary'] ?? '').toString(),
      start: (startData?['dateTime'] ?? startData?['date'] ?? '').toString(),
      end: (endData?['dateTime'] ?? endData?['date'] ?? '').toString(),
      location: (json['location'] ?? '').toString(),
      allDay: startData?['date'] != null,
    );
  }
}
