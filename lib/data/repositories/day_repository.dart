import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/daily_activity_model.dart';
import '../models/daily_weather_model.dart';
import '../models/day_media_model.dart';
import '../models/day_payload_model.dart';
import '../models/run_model.dart';
import '../models/story_day_model.dart';
import 'runs_repository.dart';
import 'stories_repository.dart';

abstract class DayRepository {
  Future<DayPayloadModel?> getCachedDayCorePayload(String day);
  Future<DayPayloadModel> getDayCorePayload(
    String day, {
    int filesFirst = 300,
    int runsFirst = 50,
  });
}

class GraphqlDayRepository implements DayRepository {
  GraphqlDayRepository(
    this._gql,
    this._storiesRepository,
    this._runsRepository,
  );

  final GraphqlService _gql;
  final StoriesRepository _storiesRepository;
  final RunsRepository _runsRepository;
  final Map<String, Future<DayPayloadModel>> _inFlight =
      <String, Future<DayPayloadModel>>{};

  Future<StoryDayModel> _preservePeopleIfFreshPayloadIsEmpty(
    String day,
    StoryDayModel incoming,
  ) async {
    if (incoming.people.isNotEmpty) return incoming;
    final cached = await _storiesRepository.getCachedDay(day);
    if (cached == null || cached.people.isEmpty) return incoming;
    return incoming.copyWith(names: cached.names, personIds: cached.personIds);
  }

  @override
  Future<DayPayloadModel?> getCachedDayCorePayload(String day) async {
    final story = await _storiesRepository.getCachedDay(day);
    List<RunModel> runs = const [];
    if (!_isFutureDay(day)) {
      runs = await _runsRepository.getCachedRunsForDate(day);
    }
    if (story == null && runs.isEmpty) return null;
    return DayPayloadModel(
      story: story ?? StoryDayModel.empty(day),
      media: const <DayMediaModel>[],
      runs: runs,
      events: const [],
      detailsLoaded: false,
      weather: null,
    );
  }

  @override
  Future<DayPayloadModel> getDayCorePayload(
    String day, {
    int filesFirst = 300,
    int runsFirst = 50,
  }) async {
    final key = '$day|$filesFirst|$runsFirst';
    final existing = _inFlight[key];
    if (existing != null) {
      return existing;
    }

    final future = _loadDayCorePayload(
      day,
      filesFirst: filesFirst,
      runsFirst: runsFirst,
    );
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<DayPayloadModel> _loadDayCorePayload(
    String day, {
    required int filesFirst,
    required int runsFirst,
  }) async {
    try {
      final response = await _gql.query(
        GqlDocuments.dayBundle,
        variables: {
          'day': day,
          'filesFirst': filesFirst,
          'runsFirst': runsFirst,
        },
      );

      final stories = response['stories'] as Map<String, dynamic>? ?? const {};
      final storyPayload = stories['day'];
      final storyJson = storyPayload is Map
          ? (storyPayload['story'] is Map
                ? Map<String, dynamic>.from(storyPayload['story'] as Map)
                : Map<String, dynamic>.from(storyPayload))
          : const <String, dynamic>{};

      final files = response['files'] as Map<String, dynamic>? ?? const {};
      final fileEdges =
          ((files['day'] as Map<String, dynamic>?)?['edges']
              as List<dynamic>? ??
          const []);

      final runEdges = _isFutureDay(day)
          ? const <dynamic>[]
          : (((response['runs'] as Map<String, dynamic>?)?['byDate']
                        as Map<String, dynamic>?)?['edges']
                    as List<dynamic>? ??
                const []);

      final story = await _preservePeopleIfFreshPayloadIsEmpty(
        day,
        StoryDayModel.fromJson(day, storyJson),
      );
      await _storiesRepository.cacheDay(story);
      final dayRuns = runEdges
          .whereType<Map>()
          .map((item) => item['node'])
          .whereType<Map>()
          .map((json) => Map<String, dynamic>.from(json))
          .map(RunModel.fromJson)
          .toList();
      await _runsRepository.cacheRuns(dayRuns);
      final activityEdges =
          (((response['health'] as Map<String, dynamic>?)?['dailyActivity']
                  as Map<String, dynamic>?)?['edges']
              as List<dynamic>?) ??
          const [];
      DailyActivityModel? activity;
      if (activityEdges.isNotEmpty) {
        final node = (activityEdges.first as Map)['node'];
        if (node is Map) {
          activity = DailyActivityModel.fromJson(
            Map<String, dynamic>.from(node),
          );
        }
      }
      final weatherEdges =
          (((response['health'] as Map<String, dynamic>?)?['dailyWeather']
                  as Map<String, dynamic>?)?['edges']
              as List<dynamic>?) ??
          const [];
      DailyWeatherModel? weather;
      if (weatherEdges.isNotEmpty) {
        final node = (weatherEdges.first as Map)['node'];
        if (node is Map) {
          weather = DailyWeatherModel.fromJson(Map<String, dynamic>.from(node));
        }
      }

      return DayPayloadModel(
        story: story,
        media: fileEdges
            .whereType<Map>()
            .map((item) => item['node'])
            .whereType<Map>()
            .map((json) => Map<String, dynamic>.from(json))
            .map(DayMediaModel.fromJson)
            .toList(),
        runs: dayRuns,
        events: const [],
        detailsLoaded: false,
        activity: activity,
        weather: weather,
      );
    } catch (_) {
      final cached = await getCachedDayCorePayload(day);
      if (cached != null) return cached;
      rethrow;
    }
  }

  bool _isFutureDay(String day) {
    final parsed = DateTime.tryParse(day);
    if (parsed == null) return false;
    return DateTime(
      parsed.year,
      parsed.month,
      parsed.day,
    ).isAfter(DateTime.now());
  }
}
