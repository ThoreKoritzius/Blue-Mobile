import 'memory_search_result_model.dart';

class MemorySearchPageModel {
  const MemorySearchPageModel({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.totalPages,
  });

  final List<MemorySearchResultModel> items;
  final int page;
  final int pageSize;
  final int total;
  final int totalPages;

  factory MemorySearchPageModel.empty({int pageSize = 20}) {
    return MemorySearchPageModel(
      items: const [],
      page: 1,
      pageSize: pageSize,
      total: 0,
      totalPages: 1,
    );
  }
}
