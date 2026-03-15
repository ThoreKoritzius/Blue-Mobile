import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/date_format.dart';
import '../../core/widgets/section_card.dart';
import '../../data/models/run_model.dart';
import '../../data/models/story_day_model.dart';
import '../../providers.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  List<StoryDayModel> _stories = const [];
  List<RunModel> _runs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final stories = await ref.read(storiesRepositoryProvider).listStories();
      final runs = await ref.read(runsRepositoryProvider).listRuns();
      if (mounted) {
        setState(() {
          _stories = stories;
          _runs = runs;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedDate = ref.watch(selectedDateProvider);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final selectedDay = formatYmd(selectedDate);
    final story = _stories
        .where((item) => item.date == selectedDay)
        .cast<StoryDayModel?>()
        .firstWhere((_) => true, orElse: () => null);
    final dayRuns = _runs
        .where((item) => item.startDateLocal == selectedDay)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Overview',
          child: TableCalendar(
            firstDay: DateTime(2005),
            lastDay: DateTime.now().add(const Duration(days: 500)),
            focusedDay: selectedDate,
            selectedDayPredicate: (day) => isSameDay(day, selectedDate),
            onDaySelected: (selected, _) {
              ref.read(selectedDateProvider.notifier).state = selected;
            },
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, events) {
                final key = formatYmd(day);
                final hasStory = _stories.any((entry) => entry.date == key);
                final hasRun = _runs.any(
                  (entry) => entry.startDateLocal == key,
                );
                if (!hasStory && !hasRun) return const SizedBox.shrink();

                return Align(
                  alignment: Alignment.bottomCenter,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (hasStory)
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF4F772D),
                          ),
                        ),
                      if (hasRun)
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF1D4E89),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Day preview',
          action: TextButton(
            onPressed: () => ref.read(selectedTabProvider.notifier).state = 0,
            child: const Text('Open Day tab'),
          ),
          child: story == null
              ? const Text('No diary entry for this day.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (story.highlightImage.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: AppConfig.imageUrlFromPath(
                            story.highlightImage,
                            date: story.date,
                          ),
                          httpHeaders: _authHeaders(),
                          height: 140,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                    const SizedBox(height: 10),
                    Text(story.place.isEmpty ? 'Unknown place' : story.place),
                    const SizedBox(height: 6),
                    Text(
                      story.description.isEmpty
                          ? 'No diary text yet.'
                          : story.description,
                    ),
                    const SizedBox(height: 10),
                    Text('Runs: ${dayRuns.length}'),
                  ],
                ),
        ),
      ],
    );
  }

  Map<String, String> _authHeaders() {
    final tokenStore = ref.read(authTokenStoreProvider);
    final token =
        ref.read(authControllerProvider).value?.accessToken ??
        tokenStore.peekToken();
    final gatewayToken = tokenStore.peekGatewayToken();
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (gatewayToken != null && gatewayToken.isNotEmpty)
        'X-Gateway-Session': gatewayToken,
    };
  }
}
