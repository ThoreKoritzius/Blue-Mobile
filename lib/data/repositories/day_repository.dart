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

  @override
  Future<DayPayloadModel?> getCachedDayCorePayload(String day) async {
    final story = await _storiesRepository.getCachedDay(day);
    List<RunModel> runs = const [];
    if (!_isFutureDay(day)) {
      final cachedRuns = await _runsRepository.getCachedRuns();
      runs = cachedRuns
          .where((run) => run.startDateLocal.split('T').first == day)
          .toList();
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
      final storyJson = storyPayload is Map<String, dynamic>
          ? (storyPayload['story'] is Map<String, dynamic>
                ? storyPayload['story'] as Map<String, dynamic>
                : storyPayload)
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

      final story = StoryDayModel.fromJson(day, storyJson);
      await _storiesRepository.cacheDay(story);
      final dayRuns = runEdges
          .map((item) => (item as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
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
        final node = (activityEdges.first as Map<String, dynamic>)['node'];
        if (node is Map<String, dynamic>) {
          activity = DailyActivityModel.fromJson(node);
        }
      }
      final weatherEdges =
          (((response['health'] as Map<String, dynamic>?)?['dailyWeather']
                      as Map<String, dynamic>?)?['edges']
                  as List<dynamic>?) ??
              const [];
      DailyWeatherModel? weather;
      if (weatherEdges.isNotEmpty) {
        final node = (weatherEdges.first as Map<String, dynamic>)['node'];
        if (node is Map<String, dynamic>) {
          weather = DailyWeatherModel.fromJson(node);
        }
      }

      return DayPayloadModel(
        story: story,
        media: fileEdges
            .map((item) => (item as Map<String, dynamic>)['node'])
            .whereType<Map<String, dynamic>>()
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
