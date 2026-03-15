import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/story_day_model.dart';

abstract class StoriesRepository {
  Future<StoryDayModel> getDay(String day);
  Future<List<StoryDayModel>> listStories({int first = 500});
  Future<void> saveDay(StoryDayModel model);
}

class GraphqlStoriesRepository implements StoriesRepository {
  GraphqlStoriesRepository(this._gql);

  final GraphqlService _gql;

  @override
  Future<StoryDayModel> getDay(String day) async {
    final response = await _gql.query(
      GqlDocuments.storiesDay,
      variables: {'day': day},
    );
    final payload = ((response['stories'] as Map<String, dynamic>)['day']);

    if (payload is Map<String, dynamic> &&
        payload['story'] is Map<String, dynamic>) {
      return StoryDayModel.fromJson(
        day,
        payload['story'] as Map<String, dynamic>,
      );
    }
    if (payload is Map<String, dynamic>) {
      return StoryDayModel.fromJson(day, payload);
    }

    return StoryDayModel.empty(day);
  }

  @override
  Future<List<StoryDayModel>> listStories({int first = 500}) async {
    final response = await _gql.query(
      GqlDocuments.storiesList,
      variables: {'first': first},
    );
    final edges =
        (((response['stories'] as Map<String, dynamic>)['list']
                as Map<String, dynamic>)['edges']
            as List<dynamic>? ??
        const []);

    return edges
        .map((item) => (item as Map<String, dynamic>)['node'])
        .whereType<Map<String, dynamic>>()
        .map((json) {
          final day = (json['date'] ?? '').toString();
          return StoryDayModel.fromJson(day, json);
        })
        .toList();
  }

  @override
  Future<void> saveDay(StoryDayModel model) async {
    await _gql.mutate(
      GqlDocuments.saveDay,
      variables: {'day': model.date, 'input': model.toSaveInput()},
    );
  }
}
