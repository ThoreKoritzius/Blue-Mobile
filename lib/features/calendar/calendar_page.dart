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

enum _MonthLoadState { unloaded, loading, loaded, error }

class _CalendarPageState extends ConsumerState<CalendarPage> {
  static const int _pageSize = 120;
  static const int _initialVirtualMonthCount = 120;
  static const int _visibleMonthPrefetch = 0;
  static const double _monthItemExtent = 552;
  static const double _heroExtentEstimate = 190;

  final ScrollController _scrollController = ScrollController();
  final Map<String, StoryDayModel> _storiesByDate = <String, StoryDayModel>{};
  final Map<String, _MonthLoadState> _monthStates = <String, _MonthLoadState>{};
  final ValueNotifier<int> _activeMonthIndexNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool> _showScrubberHintNotifier = ValueNotifier<bool>(
    false,
  );

  Timer? _scrubberHintTimer;
  Timer? _scrollIdleTimer;
  bool _initializing = true;
  bool _fetchingPages = false;
  bool _hasMore = true;
  bool _isScrollingFast = false;
  String? _nextCursor;
  String? _globalError;
  int _visibleStartIndex = 0;
  int _visibleEndIndex = 0;
  List<DateTime> _months = const [];
  DateTime? _oldestFetchedMonth;

  @override
  void initState() {
    super.initState();
    _months = _buildVirtualMonths();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _syncVisibleWindow(force: true);
      await _ensureVisibleWindowLoaded();
      if (mounted) {
        setState(() => _initializing = false);
      }
    });
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _scrubberHintTimer?.cancel();
    _scrollIdleTimer?.cancel();
    _activeMonthIndexNotifier.dispose();
    _showScrubberHintNotifier.dispose();
    super.dispose();
  }

  List<DateTime> _buildVirtualMonths() {
    final now = DateUtils.dateOnly(DateTime.now());
    final currentMonth = DateTime(now.year, now.month);
    final oldestGuaranteed = DateTime(
      currentMonth.year,
      currentMonth.month - (_initialVirtualMonthCount - 1),
    );
    final oldestVisible =
        _oldestFetchedMonth != null &&
            _oldestFetchedMonth!.isBefore(oldestGuaranteed)
        ? _oldestFetchedMonth!
        : oldestGuaranteed;

    final months = <DateTime>[];
    var cursor = currentMonth;
    while (!cursor.isBefore(oldestVisible)) {
      months.add(cursor);
      cursor = DateTime(cursor.year, cursor.month - 1);
    }
    return months;
  }

  String _monthKey(DateTime month) =>
      '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}';

  void _ingestPage(Iterable<StoryDayModel> items) {
    for (final story in items) {
      if (story.date.isEmpty) continue;
      _storiesByDate[story.date] = story;
    }

    if (_storiesByDate.isNotEmpty) {
      final oldestDate = _storiesByDate.keys
          .map(parseYmd)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      _oldestFetchedMonth = DateTime(oldestDate.year, oldestDate.month);
    }
  }

  bool _monthIsCovered(DateTime month) {
    if (_oldestFetchedMonth == null) return false;
    return !month.isBefore(_oldestFetchedMonth!);
  }

  void _markMonthRange(int start, int end, _MonthLoadState state) {
    for (var index = start; index <= end; index++) {
      final key = _monthKey(_months[index]);
      _monthStates[key] = state;
    }
  }

  void _reconcileMonthStates(int start, int end) {
    for (var index = start; index <= end; index++) {
      final month = _months[index];
      final key = _monthKey(month);
      final current = _monthStates[key];
      if (current == _MonthLoadState.error) continue;
      _monthStates[key] = _monthIsCovered(month)
          ? _MonthLoadState.loaded
          : _MonthLoadState.unloaded;
    }
  }

  Future<void> _ensureVisibleWindowLoaded() async {
    if (_months.isEmpty) return;

    final targetEnd = (_visibleEndIndex + _visibleMonthPrefetch).clamp(
      0,
      _months.length - 1,
    );
    final targetMonth = _months[targetEnd];

    if (_monthIsCovered(targetMonth)) {
      if (mounted) {
        setState(() {
          _reconcileMonthStates(_visibleStartIndex, targetEnd);
        });
      }
      return;
    }

    if (_fetchingPages || !_hasMore) {
      if (mounted) {
        setState(() {
          if (!_hasMore) {
            _reconcileMonthStates(_visibleStartIndex, targetEnd);
          } else {
            _markMonthRange(
              _visibleStartIndex,
              targetEnd,
              _MonthLoadState.loading,
            );
          }
        });
      }
      return;
    }

    setState(() {
      _globalError = null;
      _markMonthRange(_visibleStartIndex, targetEnd, _MonthLoadState.loading);
      _fetchingPages = true;
    });

    try {
      while (_hasMore && !_monthIsCovered(targetMonth)) {
        final page = await ref
            .read(storiesRepositoryProvider)
            .listStoriesPage(first: _pageSize, after: _nextCursor);
        _ingestPage(page.items);
        _nextCursor = page.endCursor;
        _hasMore = page.hasNextPage;
        if (page.items.isEmpty) break;
      }

      final nextMonths = _buildVirtualMonths();
      if (!mounted) return;
      setState(() {
        _months = nextMonths;
        _reconcileMonthStates(
          _visibleStartIndex,
          targetEnd.clamp(0, _months.length - 1),
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _globalError = error.toString().replaceFirst('Exception: ', '');
        _markMonthRange(_visibleStartIndex, targetEnd, _MonthLoadState.error);
      });
    } finally {
      if (mounted) {
        setState(() => _fetchingPages = false);
      }
    }
  }

  void _syncVisibleWindow({bool force = false}) {
    if (!_scrollController.hasClients || _months.isEmpty) return;

    final pixels = _scrollController.offset;
    final adjusted = (pixels - _heroExtentEstimate).clamp(0.0, double.infinity);
    final start = (adjusted / _monthItemExtent).floor().clamp(
      0,
      _months.length - 1,
    );
    final end = ((adjusted + (_monthItemExtent * 1.8)) / _monthItemExtent)
        .ceil()
        .clamp(0, _months.length - 1);

    final changed =
        force || start != _visibleStartIndex || end != _visibleEndIndex;
    if (!changed) return;

    _visibleStartIndex = start;
    _visibleEndIndex = end;
    _activeMonthIndexNotifier.value = start;
    unawaited(_ensureVisibleWindowLoaded());
  }

  void _onScroll() {
    if (!_isScrollingFast && mounted) {
      setState(() => _isScrollingFast = true);
    }
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(const Duration(milliseconds: 140), () {
      if (mounted && _isScrollingFast) {
        setState(() => _isScrollingFast = false);
      }
    });
    _syncVisibleWindow();
  }

  void _showMonthHint() {
    _scrubberHintTimer?.cancel();
    _showScrubberHintNotifier.value = true;
    _scrubberHintTimer = Timer(const Duration(milliseconds: 900), () {
      _showScrubberHintNotifier.value = false;
    });
  }

  void _jumpToMonthIndex(int index) {
    final safeIndex = index.clamp(0, _months.length - 1);
    final targetOffset = (_heroExtentEstimate + (safeIndex * _monthItemExtent))
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.jumpTo(targetOffset);
    _activeMonthIndexNotifier.value = safeIndex;
    _syncVisibleWindow(force: true);
  }

  void _handleScrub(double localDy, double height) {
    if (!_scrollController.hasClients || _months.isEmpty || height <= 0) return;
    final fraction = (localDy / height).clamp(0.0, 1.0);
    final index = ((fraction * (_months.length - 1)).round()).clamp(
      0,
      _months.length - 1,
    );
    _jumpToMonthIndex(index);
    _showMonthHint();
  }

  void _openDay(DateTime date) {
    ref.read(selectedDateProvider.notifier).state = DateUtils.dateOnly(date);
    ref.read(selectedTabProvider.notifier).state = 0;
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_initializing && _storiesByDate.isEmpty) {
      return _CalendarSkeleton(colorScheme: colorScheme);
    }

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            _storiesByDate.clear();
            _monthStates.clear();
            _nextCursor = null;
            _hasMore = true;
            _globalError = null;
            _oldestFetchedMonth = null;
            _months = _buildVirtualMonths();
            setState(() => _initializing = true);
            await _ensureVisibleWindowLoaded();
            if (mounted) {
              setState(() => _initializing = false);
            }
          },
          child: CustomScrollView(
            controller: _scrollController,
            cacheExtent: _monthItemExtent,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 24, 12),
                  child: _CalendarHero(
                    loadedStories: _storiesByDate.length,
                    loadedMonths: _months.length,
                    loadingMore: _fetchingPages,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 24, 24),
                sliver: SliverFixedExtentList(
                  itemExtent: _monthItemExtent,
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final month = _months[index];
                      final key = _monthKey(month);
                      final state =
                          _monthStates[key] ?? _MonthLoadState.unloaded;
                      final isActiveMonth = index == _visibleStartIndex;
                      final shouldRenderImages =
                          !_isScrollingFast &&
                          index >= _visibleStartIndex &&
                          index <= _visibleEndIndex;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: RepaintBoundary(
                          child: _MonthCard(
                            month: month,
                            storiesByDate: _storiesByDate,
                            headers: _authHeaders(),
                            onDayTap: _openDay,
                            mode: shouldRenderImages
                                ? (state == _MonthLoadState.loading
                                      ? _MonthRenderMode.loading
                                      : state == _MonthLoadState.error
                                      ? _MonthRenderMode.error
                                      : _MonthRenderMode.full)
                                : (isActiveMonth &&
                                          state == _MonthLoadState.loading
                                      ? _MonthRenderMode.loading
                                      : _MonthRenderMode.placeholder),
                          ),
                        ),
                      );
                    },
                    childCount: _months.length,
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: false,
                  ),
                ),
              ),
              if (_globalError != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 24, 20),
                    child: _CalendarInlineError(
                      message: _globalError!,
                      onRetry: _ensureVisibleWindowLoaded,
                    ),
                  ),
                )
              else if (_fetchingPages)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        ),
        if (_months.isNotEmpty)
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
                    final fraction = _months.length <= 1
                        ? 0.0
                        : (activeMonthIndex / (_months.length - 1)).clamp(
                            0.0,
                            1.0,
                          );
                    final bubbleMonth =
                        _months[activeMonthIndex.clamp(0, _months.length - 1)];
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: _showScrubberHintNotifier,
                          builder: (context, showHint, _) {
                            return AnimatedOpacity(
                              duration: const Duration(milliseconds: 140),
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
                            width: 26,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Positioned.fill(
                                  child: Align(
                                    alignment: Alignment.center,
                                    child: Container(
                                      width: 4,
                                      decoration: BoxDecoration(
                                        color: colorScheme.outlineVariant
                                            .withValues(alpha: 0.42),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: (height - 42) * fraction,
                                  child: Container(
                                    width: 16,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: colorScheme.primary,
                                      borderRadius: BorderRadius.circular(999),
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
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(
            'Scroll or drag the right scrubber to move through time. Nearby months load their real content on demand.',
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
                icon: Icons.calendar_month_outlined,
                label: '$loadedMonths months in range',
              ),
              _HeroStatPill(
                icon: Icons.photo_library_outlined,
                label: '$loadedStories loaded story days',
              ),
              _HeroStatPill(
                icon: loadingMore ? Icons.sync_rounded : Icons.bolt_outlined,
                label: loadingMore ? 'Loading month window' : 'Viewport-first',
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colorScheme.onSurface),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

enum _MonthRenderMode { placeholder, loading, full, error }

class _MonthCard extends StatelessWidget {
  const _MonthCard({
    required this.month,
    required this.storiesByDate,
    required this.headers,
    required this.onDayTap,
    required this.mode,
  });

  final DateTime month;
  final Map<String, StoryDayModel> storiesByDate;
  final Map<String, String> headers;
  final ValueChanged<DateTime> onDayTap;
  final _MonthRenderMode mode;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final monthLabel = DateFormat('MMMM y').format(month);
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
            children: [
              Expanded(
                child: Text(
                  monthLabel,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
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
          Expanded(
            child: switch (mode) {
              _MonthRenderMode.placeholder => _MonthPlaceholderGrid(
                month: month,
              ),
              _MonthRenderMode.loading => const _MonthLoadingGrid(),
              _MonthRenderMode.error => const _MonthErrorGrid(),
              _MonthRenderMode.full => _MonthDayGrid(
                month: month,
                storiesByDate: storiesByDate,
                headers: headers,
                onDayTap: onDayTap,
              ),
            },
          ),
        ],
      ),
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  static const _labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

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

class _MonthDayGrid extends StatelessWidget {
  const _MonthDayGrid({
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
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);
    final firstWeekday = DateTime(month.year, month.month, 1).weekday;
    final leadingEmpty = firstWeekday - 1;
    final totalCells = leadingEmpty + daysInMonth;
    final trailingEmpty = (7 - (totalCells % 7)) % 7;
    final cellCount = totalCells + trailingEmpty;

    return GridView.builder(
      itemCount: cellCount,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 0,
        crossAxisSpacing: 0,
        childAspectRatio: 0.72,
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
          showImage: true,
        );
      },
    );
  }
}

class _MonthPlaceholderGrid extends StatelessWidget {
  const _MonthPlaceholderGrid({required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final formatter = DateFormat('MMM');
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.surfaceContainerLowest,
            colorScheme.surfaceContainerLow,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatter.format(month).toUpperCase(),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Scroll here to load this month',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthLoadingGrid extends StatelessWidget {
  const _MonthLoadingGrid();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GridView.builder(
      itemCount: 42,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 0,
        crossAxisSpacing: 0,
        childAspectRatio: 0.72,
      ),
      itemBuilder: (context, index) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: index.isEven
                ? colorScheme.surfaceContainer
                : colorScheme.surfaceContainerHigh,
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.12),
            ),
          ),
        );
      },
    );
  }
}

class _MonthErrorGrid extends StatelessWidget {
  const _MonthErrorGrid();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      color: colorScheme.errorContainer.withValues(alpha: 0.3),
      alignment: Alignment.center,
      child: Text(
        'Month failed to load',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: colorScheme.onErrorContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.story,
    required this.headers,
    required this.onTap,
    required this.showImage,
  });

  final DateTime date;
  final StoryDayModel? story;
  final Map<String, String> headers;
  final VoidCallback onTap;
  final bool showImage;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasImage =
        showImage && story != null && story!.highlightImage.trim().isNotEmpty;
    final imageUrl = hasImage
        ? AppConfig.imageUrlFromPath(story!.highlightImage, date: story!.date)
        : '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            border: Border.all(
              color: story != null
                  ? colorScheme.primary.withValues(alpha: 0.16)
                  : colorScheme.outlineVariant.withValues(alpha: 0.2),
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
                      Colors.black.withValues(alpha: hasImage ? 0.44 : 0.08),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 4,
                top: 4,
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
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: hasImage ? Colors.white : colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
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
    final weekday = DateFormat('E').format(date).toUpperCase();
    final isStoryDay = story != null;
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
      child: Center(
        child: Text(
          weekday,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
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
              height: _CalendarPageState._monthItemExtent - 18,
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
