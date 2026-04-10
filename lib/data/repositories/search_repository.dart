import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/memory_search_page_model.dart';
import '../models/memory_search_result_model.dart';
import 'stories_repository.dart';

abstract class SearchRepository {
  Future<MemorySearchPageModel> searchMemories(
    String term, {
    Set<MemorySearchResultType> types = const <MemorySearchResultType>{},
    String? after,
    int first = 16,
    bool includeContext = false,
  });
}

class MemorySearchRepository implements SearchRepository {
  MemorySearchRepository(this._gql, this._storiesRepository);

  final GraphqlService _gql;
  final StoriesRepository _storiesRepository;

  @override
  Future<MemorySearchPageModel> searchMemories(
    String term, {
    Set<MemorySearchResultType> types = const <MemorySearchResultType>{},
    String? after,
    int first = 16,
    bool includeContext = false,
  }) async {
    try {
      final payload = await _gql.query(
        GqlDocuments.searchUnified,
        variables: {
          'input': {
            'query': term,
            'types': types.map((item) => item.graphqlName).toList(),
            'limit': first,
            'includeContext': includeContext,
          },
          'first': first,
          'after': after,
        },
      );

      final connection = payload['search'] is Map<String, dynamic>
          ? (payload['search'] as Map<String, dynamic>)['unified']
          : null;

      if (connection is Map<String, dynamic>) {
        final rawEdges = connection['edges'] as List<dynamic>? ?? const [];
        final items = rawEdges
            .whereType<Map<String, dynamic>>()
            .map((edge) => edge['node'])
            .whereType<Map<String, dynamic>>()
            .map(MemorySearchResultModel.fromJson)
            .toList();
        final pageInfo =
            connection['pageInfo'] as Map<String, dynamic>? ?? const {};
        return MemorySearchPageModel(
          items: items,
          totalCount:
              int.tryParse((connection['totalCount'] ?? '').toString()) ??
              items.length,
          hasNextPage: pageInfo['hasNextPage'] == true,
          endCursor: (pageInfo['endCursor'] ?? '').toString().isEmpty
              ? null
              : (pageInfo['endCursor'] ?? '').toString(),
        );
      }
    } catch (error) {
      return _searchOffline(term, after: after, first: first, types: types);
    }

    return MemorySearchPageModel.empty();
  }

  Future<MemorySearchPageModel> _searchOffline(
    String term, {
    required String? after,
    required int first,
    required Set<MemorySearchResultType> types,
  }) async {
    final allowsStories =
        types.isEmpty || types.contains(MemorySearchResultType.story);
    if (!allowsStories) {
      return const MemorySearchPageModel(
        items: <MemorySearchResultModel>[],
        totalCount: 0,
        hasNextPage: false,
        endCursor: null,
        isOfflineFallback: true,
        offlineMessage:
            'Offline search only includes cached story days right now.',
      );
    }

    final allStories = await _storiesRepository.getCachedRecentDays(
      limit: 9999,
    );
    final query = term.trim().toLowerCase();
    final filtered =
        allStories
            .where((story) {
              final haystack = <String>[
                story.date,
                story.place,
                story.country,
                story.names,
                story.keywords,
                story.description,
                story.highlightImage,
              ].join('\n').toLowerCase();
              return query.isEmpty || haystack.contains(query);
            })
            .map(MemorySearchResultModel.storyOffline)
            .toList()
          ..sort((a, b) => b.effectiveDate.compareTo(a.effectiveDate));

    final start = int.tryParse(after ?? '') ?? 0;
    final end = (start + first).clamp(0, filtered.length);
    final items = start >= filtered.length
        ? const <MemorySearchResultModel>[]
        : filtered.sublist(start, end);
    return MemorySearchPageModel(
      items: items,
      totalCount: filtered.length,
      hasNextPage: end < filtered.length,
      endCursor: end < filtered.length ? '$end' : null,
      isOfflineFallback: true,
      offlineMessage:
          'Offline search only includes cached story days right now.',
    );
  }
}
