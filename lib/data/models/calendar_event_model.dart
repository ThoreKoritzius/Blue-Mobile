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
    final rawStart = json['start'];
    final rawEnd = json['end'];
    final startData = rawStart is Map
        ? Map<String, dynamic>.from(rawStart)
        : null;
    final endData = rawEnd is Map ? Map<String, dynamic>.from(rawEnd) : null;
    return CalendarEventModel(
      id: (json['id'] ?? '').toString(),
      summary: (json['summary'] ?? '').toString(),
      start:
          (startData?['dateTime'] ?? startData?['date'] ?? rawStart ?? '')
              .toString(),
      end: (endData?['dateTime'] ?? endData?['date'] ?? rawEnd ?? '')
          .toString(),
      location: (json['location'] ?? '').toString(),
      allDay: json['isAllDay'] == true || startData?['date'] != null,
    );
  }
}
