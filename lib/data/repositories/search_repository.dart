import '../../core/network/graphql_service.dart';
import '../models/memory_search_page_model.dart';
import '../models/memory_search_result_model.dart';
import 'stories_repository.dart';

enum MemorySearchMode { days, images }

abstract class SearchRepository {
  Future<MemorySearchPageModel> searchMemories(
    String term, {
    required MemorySearchMode mode,
    required int page,
    required int pageSize,
    List<String> columns = const [],
  });
}

class MemorySearchRepository implements SearchRepository {
  MemorySearchRepository(this._gql, this._storiesRepository);

  final GraphqlService _gql;
  final StoriesRepository _storiesRepository;

  static const List<String> _defaultColumns = [
    'date',
    'place',
    'keywords',
    'names',
    'description',
  ];

  @override
  Future<MemorySearchPageModel> searchMemories(
    String term, {
    required MemorySearchMode mode,
    required int page,
    required int pageSize,
    List<String> columns = const [],
  }) async {
    final selectedColumns = columns.isEmpty ? _defaultColumns : columns;
    try {
      final payload = await _gql.query(
        r'''
        query SearchMemories($input: SearchInput!, $first: Int!) {
          search {
            query(input: $input, first: $first) {
              totalCount
              edges {
                node
              }
            }
          }
        }
        ''',
        variables: {
          'input': {
            'input': term,
            'imageDays': mode == MemorySearchMode.days ? 'dates' : 'images',
            'columns': selectedColumns,
            'limit': pageSize,
            'page': page,
            'pageSize': pageSize,
          },
          'first': pageSize,
        },
      );

      final connection = payload['search'] is Map<String, dynamic>
          ? (payload['search'] as Map<String, dynamic>)['query']
          : null;

      if (connection is Map<String, dynamic>) {
        final rawEdges = connection['edges'];
        final items = rawEdges is List
            ? rawEdges
                  .whereType<Map<String, dynamic>>()
                  .map((edge) => edge['node'])
                  .whereType<Map<String, dynamic>>()
                  .map(MemorySearchResultModel.fromJson)
                  .toList()
            : const <MemorySearchResultModel>[];
        final total =
            int.tryParse((connection['totalCount'] ?? '').toString()) ??
            items.length;
        final totalPages = total == 0
            ? 1
            : ((total + pageSize - 1) ~/ pageSize);
        return MemorySearchPageModel(
          items: items,
          page: page,
          pageSize: pageSize,
          total: total,
          totalPages: totalPages,
        );
      }
    } catch (error) {
      if (mode == MemorySearchMode.images) {
        throw Exception(
          'Image search is unavailable offline because image metadata is not cached.',
        );
      }
      return _searchOffline(
        term,
        page: page,
        pageSize: pageSize,
        columns: selectedColumns,
      );
    }

    return MemorySearchPageModel.empty(pageSize: pageSize);
  }

  Future<MemorySearchPageModel> _searchOffline(
    String term, {
    required int page,
    required int pageSize,
    required List<String> columns,
  }) async {
    final allStories = await _storiesRepository.getCachedRecentDays();
    final query = term.trim().toLowerCase();
    final filtered =
        allStories
            .where((story) {
              final haystacks =
                  <String>[
                        if (columns.contains('date')) story.date,
                        if (columns.contains('place')) story.place,
                        if (columns.contains('country')) story.country,
                        if (columns.contains('names')) story.names,
                        if (columns.contains('keywords')) story.keywords,
                        if (columns.contains('description')) story.description,
                        if (columns.contains('food')) story.food,
                        if (columns.contains('sport')) story.sport,
                        if (columns.contains('path')) story.highlightImage,
                      ]
                      .where((value) => value.trim().isNotEmpty)
                      .join('\n')
                      .toLowerCase();
              return haystacks.contains(query);
            })
            .map((story) => MemorySearchResultModel.fromJson(story.toJson()))
            .toList()
          ..sort((a, b) => b.date.compareTo(a.date));

    final total = filtered.length;
    final start = (page - 1) * pageSize;
    final end = (start + pageSize).clamp(0, total);
    final items = start >= total
        ? const <MemorySearchResultModel>[]
        : filtered.sublist(start, end);
    final totalPages = total == 0 ? 1 : ((total + pageSize - 1) ~/ pageSize);
    return MemorySearchPageModel(
      items: items,
      page: page,
      pageSize: pageSize,
      total: total,
      totalPages: totalPages,
      isOfflineFallback: true,
      offlineMessage: 'Offline results from the last 10 years of cached days.',
    );
  }
}
