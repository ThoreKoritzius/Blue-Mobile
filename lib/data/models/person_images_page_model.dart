import 'day_media_model.dart';

class PersonImagesPageModel {
  const PersonImagesPageModel({
    required this.items,
    required this.totalCount,
    required this.hasNextPage,
    required this.endCursor,
    required this.page,
  });

  final List<DayMediaModel> items;
  final int totalCount;
  final bool hasNextPage;
  final String? endCursor;
  final int page;
}
