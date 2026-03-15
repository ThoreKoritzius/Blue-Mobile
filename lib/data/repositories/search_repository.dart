import '../../core/network/graphql_service.dart';
import '../models/memory_search_page_model.dart';
import '../models/memory_search_result_model.dart';

enum MemorySearchMode { days, images }

abstract class SearchRepository {
  Future<MemorySearchPageModel> searchMemories(
    String term, {
    required MemorySearchMode mode,
    required int page,
    required int pageSize,
  });
}

class MemorySearchRepository implements SearchRepository {
  MemorySearchRepository(this._gql);

  final GraphqlService _gql;

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
  }) async {
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
          'columns': _defaultColumns,
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
      final totalPages = total == 0 ? 1 : ((total + pageSize - 1) ~/ pageSize);
      return MemorySearchPageModel(
        items: items,
        page: page,
        pageSize: pageSize,
        total: total,
        totalPages: totalPages,
      );
    }

    return MemorySearchPageModel.empty(pageSize: pageSize);
  }
}
