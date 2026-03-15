import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/date_format.dart';
import '../../data/models/story_day_model.dart';
import '../../providers.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  static const int _pageSize = 120;
  static const int _initialMonthTarget = 60;
  static const double _monthCardHeight = 552;
  static const double _monthItemExtent = 570;

  final ScrollController _scrollController = ScrollController();
  final Map<String, StoryDayModel> _storiesByDate = <String, StoryDayModel>{};
  final ValueNotifier<int> _activeMonthIndexNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool> _showScrubberHintNotifier = ValueNotifier<bool>(
    false,
  );

  Timer? _scrubberHintTimer;
  bool _loadingInitial = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _nextCursor;
  String? _error;
  List<DateTime> _lastBuiltMonths = const [];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _primeInitialRange();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _scrubberHintTimer?.cancel();
    _activeMonthIndexNotifier.dispose();
    _showScrubberHintNotifier.dispose();
    super.dispose();
  }

  int _loadedMonthCountFor(Map<String, StoryDayModel> stories) {
    if (stories.isEmpty) return 1;
    final now = DateUtils.dateOnly(DateTime.now());
    final currentMonth = DateTime(now.year, now.month);
    final oldestDate = stories.keys
        .map(parseYmd)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    return (currentMonth.year - oldestDate.year) * 12 +
        (currentMonth.month - oldestDate.month) +
        1;
  }

  void _applyPageItems(Iterable<StoryDayModel> items) {
    for (final story in items) {
      if (story.date.isNotEmpty) {
        _storiesByDate[story.date] = story;
      }
    }
  }

  Future<void> _primeInitialRange() async {
    if (_loadingMore) return;

    setState(() {
      _loadingInitial = true;
      _error = null;
    });

    try {
      String? cursor;
      var hasMore = true;
      final stagedStories = <String, StoryDayModel>{..._storiesByDate};

      while (hasMore &&
          _loadedMonthCountFor(stagedStories) < _initialMonthTarget) {
        final page = await ref
            .read(storiesRepositoryProvider)
            .listStoriesPage(first: _pageSize, after: cursor);
        _applyPageItems(page.items);
        for (final story in page.items) {
          if (story.date.isNotEmpty) {
            stagedStories[story.date] = story;
          }
        }
        cursor = page.endCursor;
        hasMore = page.hasNextPage;
        if (page.items.isEmpty) break;
      }

      if (!mounted) return;
      setState(() {
        _nextCursor = cursor;
        _hasMore = hasMore;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingInitial = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _loadNextPage({bool initial = false}) async {
    if (_loadingMore || (!_hasMore && !initial)) return;

    setState(() {
      if (initial) {
        _loadingInitial = true;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });

    try {
      final page = await ref
          .read(storiesRepositoryProvider)
          .listStoriesPage(
            first: _pageSize,
            after: initial ? null : _nextCursor,
          );
      if (!mounted) return;
      setState(() {
        _applyPageItems(page.items);
        _nextCursor = page.endCursor;
        _hasMore = page.hasNextPage;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingInitial = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadingInitial || _loadingMore) {
      return;
    }
    final position = _scrollController.position;
    _syncActiveMonthFromScroll();
    if (position.extentAfter < 900) {
      _loadNextPage();
    }
  }

  void _syncActiveMonthFromScroll() {
    if (!_scrollController.hasClients || _lastBuiltMonths.isEmpty) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) {
      if (_activeMonthIndexNotifier.value != 0) {
        _activeMonthIndexNotifier.value = 0;
      }
      return;
    }
    final fraction = (_scrollController.offset / maxScroll).clamp(0.0, 1.0);
    final index = ((fraction * (_lastBuiltMonths.length - 1)).round()).clamp(
      0,
      _lastBuiltMonths.length - 1,
    );
    if (index != _activeMonthIndexNotifier.value) {
      _activeMonthIndexNotifier.value = index;
    }
  }

  void _showMonthHint() {
    _scrubberHintTimer?.cancel();
    if (!_showScrubberHintNotifier.value) {
      _showScrubberHintNotifier.value = true;
    }
    _scrubberHintTimer = Timer(const Duration(milliseconds: 900), () {
      _showScrubberHintNotifier.value = false;
    });
  }

  void _handleScrub(double localDy, double height) {
    if (!_scrollController.hasClients ||
        _lastBuiltMonths.isEmpty ||
        height <= 0) {
      return;
    }
    final fraction = (localDy / height).clamp(0.0, 1.0);
    final maxScroll = _scrollController.position.maxScrollExtent;
    final targetOffset = maxScroll * fraction;
    final index = ((fraction * (_lastBuiltMonths.length - 1)).round()).clamp(
      0,
      _lastBuiltMonths.length - 1,
    );
    _scrollController.jumpTo(targetOffset.clamp(0.0, maxScroll));
    _activeMonthIndexNotifier.value = index;
    _showMonthHint();
    if (_hasMore && fraction > 0.82) {
      _loadNextPage();
    }
  }

  List<DateTime> _visibleMonths() {
    final now = DateUtils.dateOnly(DateTime.now());
    final currentMonth = DateTime(now.year, now.month);

    if (_storiesByDate.isEmpty) {
      return [currentMonth];
    }

    final oldestDate = _storiesByDate.keys
        .map(parseYmd)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final oldestMonth = DateTime(oldestDate.year, oldestDate.month);
    final months = <DateTime>[];
    var cursor = currentMonth;
    while (!cursor.isBefore(oldestMonth)) {
      months.add(cursor);
      cursor = DateTime(cursor.year, cursor.month - 1);
    }
    return months;
  }

  void _openDay(DateTime date) {
    ref.read(selectedDateProvider.notifier).state = DateUtils.dateOnly(date);
    ref.read(selectedTabProvider.notifier).state = 0;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final months = _visibleMonths();
    _lastBuiltMonths = months;
    final loadedStories = _storiesByDate.length;

    if (_loadingInitial && _storiesByDate.isEmpty) {
      return _CalendarSkeleton(colorScheme: colorScheme);
    }

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            _storiesByDate.clear();
            _nextCursor = null;
            _hasMore = true;
            await _primeInitialRange();
          },
          child: CustomScrollView(
            controller: _scrollController,
            cacheExtent: _monthItemExtent * 2,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 24, 12),
                  child: _CalendarHero(
                    loadedStories: loadedStories,
                    loadedMonths: months.length,
                    loadingMore: _loadingMore,
                  ),
                ),
              ),
              if (_error != null && _storiesByDate.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _CalendarErrorState(
                    message: _error!,
                    onRetry: () => _loadNextPage(initial: true),
                  ),
                )
              else if (_storiesByDate.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _CalendarEmptyState(
                    title: 'No story days yet',
                    subtitle:
                        'Once days have photos or notes, they will appear here as a scrollable calendar archive.',
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 24, 24),
                  sliver: SliverFixedExtentList(
                    itemExtent: _monthItemExtent,
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final month = months[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: RepaintBoundary(
                          child: _MonthCard(
                            month: month,
                            storiesByDate: _storiesByDate,
                            headers: _authHeaders(),
                            onDayTap: _openDay,
                          ),
                        ),
                      );
                    }, childCount: months.length),
                  ),
                ),
              if (_error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 24, 24),
                    child: _CalendarInlineError(
                      message: _error!,
                      onRetry: _loadNextPage,
                    ),
                  ),
                )
              else if (_loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else if (_hasMore)
                const SliverToBoxAdapter(child: SizedBox(height: 24))
              else
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 12),
                    child: Center(
                      child: Text(
                        'End of loaded history',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (months.isNotEmpty && _storiesByDate.isNotEmpty)
          Positioned(
            top: 138,
            right: 4,
            bottom: 26,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight;
                return ValueListenableBuilder<int>(
                  valueListenable: _activeMonthIndexNotifier,
                  builder: (context, activeMonthIndex, _) {
                    final fraction = months.length <= 1
                        ? 0.0
                        : (activeMonthIndex / (months.length - 1)).clamp(
                            0.0,
                            1.0,
                          );
                    final bubbleMonth =
                        months[activeMonthIndex.clamp(0, months.length - 1)];
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: _showScrubberHintNotifier,
                          builder: (context, showHint, _) {
                            return AnimatedOpacity(
                              duration: const Duration(milliseconds: 160),
                              opacity: showHint ? 1 : 0,
                              child: IgnorePointer(
                                child: Container(
                                  margin: const EdgeInsets.only(right: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.inverseSurface,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(
                                    DateFormat('MMMM y').format(bubbleMonth),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          color: colorScheme.onInverseSurface,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onVerticalDragStart: (_) => _showMonthHint(),
                          onVerticalDragUpdate: (details) =>
                              _handleScrub(details.localPosition.dy, height),
                          onTapDown: (details) =>
                              _handleScrub(details.localPosition.dy, height),
                          child: SizedBox(
                            width: 28,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 4,
                                    decoration: BoxDecoration(
                                      color: colorScheme.outlineVariant
                                          .withValues(alpha: 0.45),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: (height - 44) * fraction,
                                  child: Container(
                                    width: 18,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: colorScheme.primary,
                                      borderRadius: BorderRadius.circular(999),
                                      boxShadow: [
                                        BoxShadow(
                                          color: colorScheme.primary.withValues(
                                            alpha: 0.34,
                                          ),
                                          blurRadius: 14,
                                          offset: const Offset(0, 6),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
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

class _CalendarHero extends StatelessWidget {
  const _CalendarHero({
    required this.loadedStories,
    required this.loadedMonths,
    required this.loadingMore,
  });

  final int loadedStories;
  final int loadedMonths;
  final bool loadingMore;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.surfaceContainerHighest,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Memory Calendar',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'A monthly archive with one hero image per day. Scroll down to move backward through time.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeroStatPill(
                icon: Icons.photo_library_outlined,
                label: '$loadedStories loaded days',
              ),
              _HeroStatPill(
                icon: Icons.calendar_month_outlined,
                label: '$loadedMonths months visible',
              ),
              _HeroStatPill(
                icon: loadingMore
                    ? Icons.sync_rounded
                    : Icons.history_toggle_off_rounded,
                label: loadingMore ? 'Loading older months' : 'Pull to refresh',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroStatPill extends StatelessWidget {
  const _HeroStatPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colorScheme.onSurface),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthCard extends StatelessWidget {
  const _MonthCard({
    required this.month,
    required this.storiesByDate,
    required this.headers,
    required this.onDayTap,
  });

  final DateTime month;
  final Map<String, StoryDayModel> storiesByDate;
  final Map<String, String> headers;
  final ValueChanged<DateTime> onDayTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final monthLabel = DateFormat('MMMM y').format(month);
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);
    final firstWeekday = DateTime(month.year, month.month, 1).weekday;
    final leadingEmpty = firstWeekday - 1;
    final totalCells = leadingEmpty + daysInMonth;
    final trailingEmpty = (7 - (totalCells % 7)) % 7;
    final cellCount = totalCells + trailingEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.28),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      monthLabel,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  DateFormat('yyyy').format(month),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _WeekdayHeader(),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: cellCount,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 0,
              crossAxisSpacing: 0,
              childAspectRatio: 0.66,
            ),
            itemBuilder: (context, index) {
              if (index < leadingEmpty || index >= leadingEmpty + daysInMonth) {
                return const SizedBox.shrink();
              }
              final dayNumber = index - leadingEmpty + 1;
              final date = DateTime(month.year, month.month, dayNumber);
              final story = storiesByDate[formatYmd(date)];
              return _DayCell(
                date: date,
                story: story,
                headers: headers,
                onTap: () => onDayTap(date),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  static const List<String> _labels = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: _labels
          .map(
            (label) => Expanded(
              child: Center(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.story,
    required this.headers,
    required this.onTap,
  });

  final DateTime date;
  final StoryDayModel? story;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasImage = story != null && story!.highlightImage.trim().isNotEmpty;
    final imageUrl = hasImage
        ? AppConfig.imageUrlFromPath(story!.highlightImage, date: story!.date)
        : '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: hasImage
                ? colorScheme.surfaceContainerHighest
                : colorScheme.surfaceContainer,
            border: Border.all(
              color: story != null
                  ? colorScheme.primary.withValues(alpha: 0.22)
                  : colorScheme.outlineVariant.withValues(alpha: 0.24),
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasImage)
                Image.network(
                  imageUrl,
                  headers: headers,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (_, __, ___) =>
                      _DayFallback(date: date, story: story),
                )
              else
                _DayFallback(date: date, story: story),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: hasImage ? 0.04 : 0.0),
                      Colors.black.withValues(alpha: hasImage ? 0.14 : 0.02),
                      Colors.black.withValues(alpha: hasImage ? 0.48 : 0.08),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 5,
                top: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(
                      alpha: hasImage ? 0.34 : 0.1,
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${date.day}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: hasImage ? Colors.white : colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayFallback extends StatelessWidget {
  const _DayFallback({required this.date, required this.story});

  final DateTime date;
  final StoryDayModel? story;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isStoryDay = story != null;
    final weekday = DateFormat('E').format(date).toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isStoryDay
              ? [
                  colorScheme.surfaceContainerHigh,
                  colorScheme.surfaceContainerHighest,
                ]
              : [colorScheme.surfaceContainerLow, colorScheme.surfaceContainer],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              isStoryDay ? Icons.article_outlined : Icons.remove_rounded,
              color: isStoryDay
                  ? colorScheme.onSurface
                  : colorScheme.onSurfaceVariant,
              size: 16,
            ),
            const SizedBox(height: 4),
            Text(
              weekday,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: isStoryDay
                    ? colorScheme.onSurface
                    : colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarSkeleton extends StatelessWidget {
  const _CalendarSkeleton({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          height: 150,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(28),
          ),
        ),
        const SizedBox(height: 16),
        ...List.generate(
          2,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Container(
              height: _CalendarPageState._monthCardHeight,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(28),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CalendarEmptyState extends StatelessWidget {
  const _CalendarEmptyState({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.calendar_month_outlined,
                size: 34,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CalendarErrorState extends StatelessWidget {
  const _CalendarErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 34,
                color: colorScheme.onErrorContainer,
              ),
              const SizedBox(height: 14),
              Text(
                'Calendar load failed',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: colorScheme.onErrorContainer,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onErrorContainer.withValues(alpha: 0.88),
                  height: 1.35,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.onErrorContainer,
                  foregroundColor: colorScheme.errorContainer,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CalendarInlineError extends StatelessWidget {
  const _CalendarInlineError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: onRetry,
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.onErrorContainer,
              foregroundColor: colorScheme.errorContainer,
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
