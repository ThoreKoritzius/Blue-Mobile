import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/calendar_event_model.dart';

abstract class CalendarRepository {
  Future<List<CalendarEventModel>> eventsForDate(String date);
}

class GraphqlCalendarRepository implements CalendarRepository {
  GraphqlCalendarRepository(this._gql);

  final GraphqlService _gql;
  final Map<String, Future<List<CalendarEventModel>>> _inFlight =
      <String, Future<List<CalendarEventModel>>>{};

  @override
  Future<List<CalendarEventModel>> eventsForDate(String date) async {
    final existing = _inFlight[date];
    if (existing != null) {
      return existing;
    }

    final future = _loadEventsForDate(date);
    _inFlight[date] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(date);
    }
  }

  Future<List<CalendarEventModel>> _loadEventsForDate(String date) async {
    final response = await _gql.query(
      GqlDocuments.calendarEvents,
      variables: {'date': date},
    );

    final calendarRoot = response['calendar'];
    final calendarMap = calendarRoot is Map
        ? Map<String, dynamic>.from(calendarRoot)
        : const <String, dynamic>{};
    final payload = calendarMap['events'];
    final payloadMap = payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    final items = payloadMap['items'] as List<dynamic>? ?? const <dynamic>[];

    return items
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .map(CalendarEventModel.fromJson)
        .toList();
  }
}
