class CalendarEventModel {
  const CalendarEventModel({
    required this.id,
    required this.summary,
    required this.start,
    required this.end,
    required this.location,
    required this.allDay,
    this.description = '',
    this.status = '',
    this.htmlLink = '',
    this.source = '',
    this.sourceName = '',
    this.sourceId = '',
  });

  final String id;
  final String summary;
  final String start;
  final String end;
  final String location;
  final bool allDay;
  final String description;
  final String status;
  final String htmlLink;
  final String source;
  final String sourceName;
  final String sourceId;

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
      description: (json['description'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      htmlLink: (json['htmlLink'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      sourceName: (json['sourceName'] ?? '').toString(),
      sourceId: (json['sourceId'] ?? '').toString(),
      location: (json['location'] ?? '').toString(),
      allDay: json['isAllDay'] == true || startData?['date'] != null,
    );
  }
}

DateTime? parseCalendarEventDateTime(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final normalized = trimmed.replaceFirst(
    RegExp(r'(Z|[+-]\d{2}:\d{2})$'),
    '',
  );
  final parsed = DateTime.tryParse(normalized);
  if (parsed == null) return null;
  return parsed;
}
