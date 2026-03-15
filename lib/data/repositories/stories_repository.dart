import '../../core/network/graphql_service.dart';
import '../cache/story_cache_store.dart';
import '../graphql/documents.dart';
import '../models/story_day_model.dart';
import '../models/story_day_page_model.dart';

abstract class StoriesRepository {
  Future<StoryDayModel?> getCachedDay(String day);
  Future<List<StoryDayModel>> getCachedRecentDays({
    int limit = StoryCacheStore.maxCachedDays,
  });
  Future<void> cacheDay(StoryDayModel model);
  Future<StoryDayModel> getDay(String day);
  Future<StoryDayPageModel> listStoriesPage({int first = 120, String? after});
  Future<List<StoryDayModel>> listStories({int first = 500});
  Future<void> warmRecentCache({int limit = StoryCacheStore.maxCachedDays});
  Future<void> saveDay(StoryDayModel model);
}

class GraphqlStoriesRepository implements StoriesRepository {
  GraphqlStoriesRepository(this._gql, this._cacheStore);

  final GraphqlService _gql;
  final StoryCacheStore _cacheStore;

  @override
  Future<StoryDayModel?> getCachedDay(String day) {
    return _cacheStore.readDay(day);
  }

  @override
  Future<List<StoryDayModel>> getCachedRecentDays({
    int limit = StoryCacheStore.maxCachedDays,
  }) {
    return _cacheStore.readRecentDays(limit: limit);
  }

  @override
  Future<void> cacheDay(StoryDayModel model) {
    return _cacheStore.upsertStory(model);
  }

  @override
  Future<StoryDayModel> getDay(String day) async {
    try {
      final response = await _gql.query(
        GqlDocuments.storiesDay,
        variables: {'day': day},
      );
      final payload = ((response['stories'] as Map<String, dynamic>)['day']);

      late final StoryDayModel story;
      if (payload is Map<String, dynamic> &&
          payload['story'] is Map<String, dynamic>) {
        story = StoryDayModel.fromJson(
          day,
          payload['story'] as Map<String, dynamic>,
        );
      } else if (payload is Map<String, dynamic>) {
        story = StoryDayModel.fromJson(day, payload);
      } else {
        story = StoryDayModel.empty(day);
      }
      await _cacheStore.upsertStory(story);
      return story;
    } catch (_) {
      final cached = await _cacheStore.readDay(day);
      if (cached != null) return cached;
      rethrow;
    }
  }

  @override
  Future<StoryDayPageModel> listStoriesPage({
    int first = 120,
    String? after,
  }) async {
    try {
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
      await _cacheStore.upsertStories(items);
      final pageInfo = connection?['pageInfo'] as Map<String, dynamic>?;
      return StoryDayPageModel(
        items: items,
        totalCount:
            int.tryParse((connection?['totalCount'] ?? '').toString()) ??
            items.length,
        hasNextPage: pageInfo?['hasNextPage'] == true,
        endCursor: pageInfo?['endCursor']?.toString(),
      );
    } catch (_) {
      if (after != null && after.isNotEmpty) rethrow;
      final cached = await _cacheStore.readRecentDays(limit: first);
      return StoryDayPageModel(
        items: cached,
        totalCount: cached.length,
        hasNextPage: false,
        endCursor: null,
      );
    }
  }

  @override
  Future<List<StoryDayModel>> listStories({int first = 500}) async {
    try {
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

      await _cacheStore.upsertStories(items);
      return items;
    } catch (_) {
      final cached = await _cacheStore.readRecentDays(limit: first);
      if (cached.isNotEmpty) return cached;
      rethrow;
    }
  }

  @override
  Future<void> warmRecentCache({
    int limit = StoryCacheStore.maxCachedDays,
  }) async {
    final lastWarmAt = await _cacheStore.readLastWarmAt();
    if (lastWarmAt != null &&
        DateTime.now().toUtc().difference(lastWarmAt) <
            const Duration(minutes: 20)) {
      return;
    }
    final items = await listStories(first: limit);
    await _cacheStore.upsertStories(items.take(limit).toList());
    await _cacheStore.writeLastWarmAt(DateTime.now().toUtc());
  }

  @override
  Future<void> saveDay(StoryDayModel model) async {
    await _gql.mutate(
      GqlDocuments.saveDay,
      variables: {'day': model.date, 'input': model.toSaveInput()},
    );
    await _cacheStore.upsertStory(model);
  }
}
