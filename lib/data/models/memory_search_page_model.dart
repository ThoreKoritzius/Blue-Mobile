import 'memory_search_result_model.dart';

class MemorySearchPageModel {
  const MemorySearchPageModel({
    required this.items,
    required this.totalCount,
    required this.hasNextPage,
    required this.endCursor,
    this.isOfflineFallback = false,
    this.offlineMessage,
  });

  final List<MemorySearchResultModel> items;
  final int totalCount;
  final bool hasNextPage;
  final String? endCursor;
  final bool isOfflineFallback;
  final String? offlineMessage;

  factory MemorySearchPageModel.empty() {
    return const MemorySearchPageModel(
      items: <MemorySearchResultModel>[],
      totalCount: 0,
      hasNextPage: false,
      endCursor: null,
      isOfflineFallback: false,
      offlineMessage: null,
    );
  }
}
