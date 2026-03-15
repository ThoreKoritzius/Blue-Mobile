import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/story_day_model.dart';
import '../models/story_day_page_model.dart';

abstract class StoriesRepository {
  Future<StoryDayModel> getDay(String day);
  Future<StoryDayPageModel> listStoriesPage({int first = 120, String? after});
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
  Future<StoryDayPageModel> listStoriesPage({
    int first = 120,
    String? after,
  }) async {
    final response = await _gql.query(
      GqlDocuments.storiesList,
      variables: {'first': first, 'after': after},
    );
    final connection =
        ((response['stories'] as Map<String, dynamic>)['list']
            as Map<String, dynamic>?);
    final edges = (connection?['edges'] as List<dynamic>? ?? const []);
    final items = edges
        .map((item) => (item as Map<String, dynamic>)['node'])
        .whereType<Map<String, dynamic>>()
        .map((json) {
          final day = (json['date'] ?? '').toString();
          return StoryDayModel.fromJson(day, json);
        })
        .toList();
    final pageInfo = connection?['pageInfo'] as Map<String, dynamic>?;
    return StoryDayPageModel(
      items: items,
      totalCount:
          int.tryParse((connection?['totalCount'] ?? '').toString()) ??
          items.length,
      hasNextPage: pageInfo?['hasNextPage'] == true,
      endCursor: pageInfo?['endCursor']?.toString(),
    );
  }

  @override
  Future<List<StoryDayModel>> listStories({int first = 500}) async {
    final items = <StoryDayModel>[];
    String? cursor;
    var hasNextPage = true;

    while (hasNextPage && items.length < first) {
      final page = await listStoriesPage(
        first: (first - items.length).clamp(1, 200),
        after: cursor,
      );
      items.addAll(page.items);
      cursor = page.endCursor;
      hasNextPage = page.hasNextPage;
      if (page.items.isEmpty) break;
    }

    return items;
  }

  @override
  Future<void> saveDay(StoryDayModel model) async {
    await _gql.mutate(
      GqlDocuments.saveDay,
      variables: {'day': model.date, 'input': model.toSaveInput()},
    );
  }
}
