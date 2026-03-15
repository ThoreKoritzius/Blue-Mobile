import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/day_media_model.dart';
import '../models/day_payload_model.dart';
import '../models/run_model.dart';
import '../models/story_day_model.dart';

abstract class DayRepository {
  Future<DayPayloadModel> getDayCorePayload(
    String day, {
    int filesFirst = 300,
    int runsFirst = 50,
  });
}

class GraphqlDayRepository implements DayRepository {
  GraphqlDayRepository(this._gql);

  final GraphqlService _gql;
  final Map<String, Future<DayPayloadModel>> _inFlight =
      <String, Future<DayPayloadModel>>{};

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
    final response = await _gql.query(
      GqlDocuments.dayBundle,
      variables: {'day': day, 'filesFirst': filesFirst, 'runsFirst': runsFirst},
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
        ((files['day'] as Map<String, dynamic>?)?['edges'] as List<dynamic>? ??
        const []);

    final runs = response['runs'] as Map<String, dynamic>? ?? const {};
    final runEdges =
        ((runs['byDate'] as Map<String, dynamic>?)?['edges']
            as List<dynamic>? ??
        const []);

    return DayPayloadModel(
      story: StoryDayModel.fromJson(day, storyJson),
      media: fileEdges
          .map((item) => (item as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .map(DayMediaModel.fromJson)
          .toList(),
      runs: runEdges
          .map((item) => (item as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .map(RunModel.fromJson)
          .toList(),
      events: const [],
      detailsLoaded: false,
    );
  }
}
