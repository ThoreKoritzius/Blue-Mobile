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

    final payload = ((response['calendar'] as Map<String, dynamic>)['events']);
    final items = payload is Map<String, dynamic>
        ? (payload['items'] as List<dynamic>? ?? const [])
        : const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(CalendarEventModel.fromJson)
        .toList();
  }
}
