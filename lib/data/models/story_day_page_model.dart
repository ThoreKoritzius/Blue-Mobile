import 'story_day_model.dart';

class StoryDayPageModel {
  const StoryDayPageModel({
    required this.items,
    required this.totalCount,
    required this.hasNextPage,
    required this.endCursor,
  });

  final List<StoryDayModel> items;
  final int totalCount;
  final bool hasNextPage;
  final String? endCursor;
}
