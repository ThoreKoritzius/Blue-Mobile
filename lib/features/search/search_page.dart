import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/date_format.dart';
import '../../core/widgets/protected_network_image.dart';
import '../../data/models/memory_search_result_model.dart';
import '../../providers.dart';
import '../persons/person_detail_page.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchState {
  const _SearchState({
    required this.items,
    required this.totalCount,
    required this.hasNextPage,
    required this.endCursor,
    required this.loading,
    required this.loadingMore,
    required this.error,
    required this.hasRequested,
    required this.isOfflineFallback,
    required this.offlineMessage,
  });

  final List<MemorySearchResultModel> items;
  final int totalCount;
  final bool hasNextPage;
  final String? endCursor;
  final bool loading;
  final bool loadingMore;
  final String error;
  final bool hasRequested;
  final bool isOfflineFallback;
  final String? offlineMessage;

  factory _SearchState.empty() {
    return const _SearchState(
      items: <MemorySearchResultModel>[],
      totalCount: 0,
      hasNextPage: false,
      endCursor: null,
      loading: false,
      loadingMore: false,
      error: '',
      hasRequested: false,
      isOfflineFallback: false,
      offlineMessage: null,
    );
  }

  _SearchState copyWith({
    List<MemorySearchResultModel>? items,
    int? totalCount,
    bool? hasNextPage,
    String? endCursor,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool? hasRequested,
    bool? isOfflineFallback,
    String? offlineMessage,
  }) {
    return _SearchState(
      items: items ?? this.items,
      totalCount: totalCount ?? this.totalCount,
      hasNextPage: hasNextPage ?? this.hasNextPage,
      endCursor: endCursor ?? this.endCursor,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: error ?? this.error,
      hasRequested: hasRequested ?? this.hasRequested,
      isOfflineFallback: isOfflineFallback ?? this.isOfflineFallback,
      offlineMessage: offlineMessage ?? this.offlineMessage,
    );
  }
}

enum _SearchFilterPreset {
  all,
  places,
  days,
  images,
  runs,
  people,
  timeline,
  calendar,
}

class _SearchPageState extends ConsumerState<SearchPage> {
  static const int _pageSize = 16;

  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  Timer? _debounce;
  int _queryGeneration = 0;
  String _activeQuery = '';
  _SearchFilterPreset _activePreset = _SearchFilterPreset.all;
  _SearchState _state = _SearchState.empty();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Set<MemorySearchResultType> get _selectedTypes => switch (_activePreset) {
    _SearchFilterPreset.all => const <MemorySearchResultType>{
      MemorySearchResultType.story,
      MemorySearchResultType.run,
      MemorySearchResultType.timeline,
      MemorySearchResultType.calendar,
      MemorySearchResultType.weather,
      MemorySearchResultType.activity,
      MemorySearchResultType.person,
    },
    _SearchFilterPreset.places => const <MemorySearchResultType>{
      MemorySearchResultType.story,
      MemorySearchResultType.timeline,
      MemorySearchResultType.calendar,
      MemorySearchResultType.weather,
    },
    _SearchFilterPreset.days => const <MemorySearchResultType>{
      MemorySearchResultType.story,
      MemorySearchResultType.activity,
      MemorySearchResultType.weather,
    },
    _SearchFilterPreset.images => const <MemorySearchResultType>{
      MemorySearchResultType.file,
    },
    _SearchFilterPreset.runs => const <MemorySearchResultType>{
      MemorySearchResultType.run,
    },
    _SearchFilterPreset.people => const <MemorySearchResultType>{
      MemorySearchResultType.person,
      MemorySearchResultType.file,
    },
    _SearchFilterPreset.timeline => const <MemorySearchResultType>{
      MemorySearchResultType.timeline,
    },
    _SearchFilterPreset.calendar => const <MemorySearchResultType>{
      MemorySearchResultType.calendar,
    },
  };

  bool get _includeContext =>
      _activePreset == _SearchFilterPreset.days ||
      _activePreset == _SearchFilterPreset.places;

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _runNewQuery(value.trim());
    });
    setState(() {});
  }

  void _setPreset(_SearchFilterPreset preset) {
    if (_activePreset == preset) return;
    setState(() {
      _activePreset = preset;
      _state = _SearchState.empty();
    });
    if (_activeQuery.isNotEmpty) {
      _queryGeneration += 1;
      _runSearch(_activeQuery, reset: true, generation: _queryGeneration);
    }
  }

  void _runNewQuery(String query) {
    _queryGeneration += 1;
    if (query.isEmpty) {
      setState(() {
        _activeQuery = '';
        _state = _SearchState.empty();
      });
      return;
    }
    setState(() {
      _activeQuery = query;
      _state = _SearchState.empty();
    });
    _runSearch(query, reset: true, generation: _queryGeneration);
  }

  Future<void> _runSearch(
    String query, {
    required bool reset,
    int? generation,
  }) async {
    if (query.isEmpty) return;
    if (_state.loading || _state.loadingMore) return;

    final requestGeneration = generation ?? _queryGeneration;
    setState(() {
      _state = _state.copyWith(
        loading: reset,
        loadingMore: !reset,
        error: '',
        hasRequested: true,
        isOfflineFallback: false,
        offlineMessage: null,
      );
    });

    try {
      final page = await ref
          .read(searchRepositoryProvider)
          .searchMemories(
            query,
            types: _selectedTypes,
            after: reset ? null : _state.endCursor,
            first: _pageSize,
            includeContext: _includeContext,
          );
      if (!mounted ||
          requestGeneration != _queryGeneration ||
          query != _activeQuery) {
        return;
      }
      setState(() {
        _state = _state.copyWith(
          items: reset ? page.items : [..._state.items, ...page.items],
          totalCount: page.totalCount,
          hasNextPage: page.hasNextPage,
          endCursor: page.endCursor,
          loading: false,
          loadingMore: false,
          error: '',
          hasRequested: true,
          isOfflineFallback: page.isOfflineFallback,
          offlineMessage: page.offlineMessage,
        );
      });
    } catch (error) {
      if (!mounted ||
          requestGeneration != _queryGeneration ||
          query != _activeQuery) {
        return;
      }
      setState(() {
        _state = _state.copyWith(
          loading: false,
          loadingMore: false,
          error: error.toString().replaceFirst('Exception: ', ''),
          hasRequested: true,
        );
      });
    }
  }

  void _handleScroll() {
    if (_activeQuery.isEmpty ||
        _state.loading ||
        _state.loadingMore ||
        !_state.hasNextPage) {
      return;
    }
    if (!_scrollController.hasClients) return;
    final remaining = _scrollController.position.extentAfter;
    final threshold = _scrollController.position.viewportDimension * 1.25;
    if (remaining < threshold) {
      _runSearch(_activeQuery, reset: false);
    }
  }

  void _openResult(MemorySearchResultModel item) {
    if (item.type == MemorySearchResultType.person &&
        item.personRecord != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PersonDetailPage(person: item.personRecord!),
        ),
      );
      return;
    }
    final date = item.effectiveDate;
    if (date.isEmpty) return;
    ref.read(selectedDateProvider.notifier).state = parseYmd(date);
    ref.read(selectedTabProvider.notifier).state = 0;
    Navigator.of(context).pop();
  }

  void _openResultOnMap(MemorySearchResultModel item) {
    final date = item.effectiveDate;
    if (date.isEmpty) return;
    ref.read(selectedDateProvider.notifier).state = parseYmd(date);
    ref.read(selectedTabProvider.notifier).state = 4;
    Navigator.of(context).pop();
  }

  String _resultSummary() {
    if (_state.loading && _state.items.isEmpty) {
      return 'Searching...';
    }
    if (_state.items.isEmpty) {
      return 'No results';
    }
    if (_state.hasNextPage) {
      return 'Showing ${_state.items.length} top results';
    }
    return '${_state.items.length} result${_state.items.length == 1 ? '' : 's'}';
  }

  Map<String, String> _authHeaders() {
    if (kIsWeb) {
      return const {};
    }
    final tokenStore = ref.read(authTokenStoreProvider);
    final token =
        ref.read(authControllerProvider).value?.accessToken ??
        tokenStore.peekToken();
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      'X-Blue-Client': 'mobile',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authHeaders = _authHeaders();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        toolbarHeight: 88,
        title: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: TextField(
            controller: _controller,
            autofocus: true,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: (value) => _runNewQuery(value.trim()),
            decoration: InputDecoration(
              hintText: 'Search everything',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _controller.clear();
                        _runNewQuery('');
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          _SearchFilterBar(activePreset: _activePreset, onSelected: _setPreset),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _activeQuery.isEmpty
                        ? 'Search stories, runs, images, people, timeline, calendar, weather, and activities.'
                        : _resultSummary(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (_state.loading)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ),
          if (_state.isOfflineFallback &&
              (_state.offlineMessage?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.offline_bolt_rounded,
                        size: 16,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _state.offlineMessage!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(child: _buildBody(authHeaders)),
        ],
      ),
    );
  }

  Widget _buildBody(Map<String, String> authHeaders) {
    if (_activeQuery.isEmpty) {
      return const _SearchBlankState();
    }
    if (_state.error.isNotEmpty) {
      return _SearchErrorState(
        message: _state.error,
        onRetry: () => _runSearch(_activeQuery, reset: true),
      );
    }
    if (_state.loading && _state.items.isEmpty) {
      return const _SearchSkeletonList();
    }
    if (_state.hasRequested && _state.items.isEmpty) {
      return _SearchEmptyState(query: _activeQuery);
    }
    if (_activePreset == _SearchFilterPreset.images) {
      return _SearchImageGrid(
        items: _state.items,
        authHeaders: authHeaders,
        loadingMore: _state.loadingMore,
        scrollController: _scrollController,
        onTap: _openResult,
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _state.items.length + (_state.loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _state.items.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final item = _state.items[index];
        return _SearchResultCard(
          item: item,
          authHeaders: authHeaders,
          onTap: () => _openResult(item),
          onMapTap: item.place.isNotEmpty && item.effectiveDate.isNotEmpty
              ? () => _openResultOnMap(item)
              : null,
        );
      },
    );
  }
}

class _SearchImageGrid extends StatelessWidget {
  const _SearchImageGrid({
    required this.items,
    required this.authHeaders,
    required this.loadingMore,
    required this.scrollController,
    required this.onTap,
  });

  final List<MemorySearchResultModel> items;
  final Map<String, String> authHeaders;
  final bool loadingMore;
  final ScrollController scrollController;
  final ValueChanged<MemorySearchResultModel> onTap;

  @override
  Widget build(BuildContext context) {
    final gridItems = items
        .where((item) => item.type == MemorySearchResultType.file)
        .toList();
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 0.84,
      ),
      itemCount: gridItems.length + (loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= gridItems.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final item = gridItems[index];
        return _SearchImageTile(
          item: item,
          authHeaders: authHeaders,
          onTap: () => onTap(item),
        );
      },
    );
  }
}

class _SearchFilterBar extends StatelessWidget {
  const _SearchFilterBar({
    required this.activePreset,
    required this.onSelected,
  });

  final _SearchFilterPreset activePreset;
  final ValueChanged<_SearchFilterPreset> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: SizedBox(
        height: 38,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final preset in _SearchFilterPreset.values) ...[
              _FilterChipButton(
                label: switch (preset) {
                  _SearchFilterPreset.all => 'All',
                  _SearchFilterPreset.places => 'Places',
                  _SearchFilterPreset.days => 'Days',
                  _SearchFilterPreset.images => 'Images',
                  _SearchFilterPreset.runs => 'Runs',
                  _SearchFilterPreset.people => 'People',
                  _SearchFilterPreset.timeline => 'Timeline',
                  _SearchFilterPreset.calendar => 'Calendar',
                },
                selected: activePreset == preset,
                onTap: () => onSelected(preset),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
      selectedColor: theme.colorScheme.secondaryContainer,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      labelStyle: TextStyle(
        color: selected
            ? theme.colorScheme.onSecondaryContainer
            : theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
    );
  }
}

class _SearchBlankState extends StatelessWidget {
  const _SearchBlankState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.surfaceContainerHighest,
                    theme.colorScheme.surfaceContainer,
                  ],
                ),
              ),
              child: Icon(
                Icons.travel_explore_rounded,
                size: 42,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Unified search',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Search days, images, runs, people, places, calendar events, weather, and activities in one place.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              child: Icon(
                Icons.search_off_rounded,
                size: 42,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'No matching results',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Nothing matched "$query". Try a broader place, person, event, or date.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchErrorState extends StatelessWidget {
  const _SearchErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _SearchSkeletonList extends StatelessWidget {
  const _SearchSkeletonList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: 6,
      itemBuilder: (_, __) => const _SearchSkeletonCard(),
    );
  }
}

class _SearchSkeletonCard extends StatelessWidget {
  const _SearchSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: const [
            _SkeletonBox(
              width: 76,
              height: 76,
              radius: BorderRadius.all(Radius.circular(10)),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonBox(width: 70, height: 12),
                  SizedBox(height: 8),
                  _SkeletonBox(width: 180, height: 18),
                  SizedBox(height: 8),
                  _SkeletonBox(width: double.infinity, height: 12),
                  SizedBox(height: 6),
                  _SkeletonBox(width: 160, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonBox extends StatefulWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    this.radius = const BorderRadius.all(Radius.circular(8)),
  });

  final double width;
  final double height;
  final BorderRadius radius;

  @override
  State<_SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<_SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final baseColor = colorScheme.surfaceContainerHighest;
    final highlightColor = colorScheme.surfaceContainerHigh;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.radius,
            color: Color.lerp(baseColor, highlightColor, _controller.value),
          ),
          child: SizedBox(width: widget.width, height: widget.height),
        );
      },
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({
    required this.item,
    required this.authHeaders,
    required this.onTap,
    this.onMapTap,
  });

  final MemorySearchResultModel item;
  final Map<String, String> authHeaders;
  final VoidCallback onTap;
  final VoidCallback? onMapTap;

  IconData _iconForType() {
    return switch (item.type) {
      MemorySearchResultType.story => Icons.auto_stories_rounded,
      MemorySearchResultType.run => Icons.directions_run_rounded,
      MemorySearchResultType.file => Icons.photo_library_rounded,
      MemorySearchResultType.timeline => Icons.timeline_rounded,
      MemorySearchResultType.calendar => Icons.event_note_rounded,
      MemorySearchResultType.weather => Icons.wb_cloudy_rounded,
      MemorySearchResultType.activity => Icons.monitor_heart_rounded,
      MemorySearchResultType.person => Icons.person_rounded,
    };
  }

  String? _imageUrl() {
    if (item.type == MemorySearchResultType.person &&
        item.personRecord != null &&
        item.personRecord!.photoPath.trim().isNotEmpty) {
      return '${AppConfig.backendUrl}/api/person/${item.personRecord!.photoPath.trim()}';
    }
    final previewPath = item.previewImagePath;
    final previewDate = item.effectiveDate;
    if (previewPath.isEmpty) return null;
    return AppConfig.imageUrlFromPath(previewPath, date: previewDate);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final imageUrl = _imageUrl();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SearchPreview(
                imageUrl: imageUrl,
                icon: _iconForType(),
                authHeaders: authHeaders,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _TypeBadge(label: item.type.label),
                        const SizedBox(width: 8),
                        if (item.effectiveDate.isNotEmpty)
                          Expanded(
                            child: Text(
                              item.effectiveDate,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.displayTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.displaySubtitle.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.displaySubtitle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                    if (item.place.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            Icons.place_outlined,
                            size: 15,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              item.place,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (item.metaChips.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: item.metaChips
                            .map(
                              (entry) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  entry,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              if (onMapTap != null)
                IconButton(
                  tooltip: 'Open on map',
                  onPressed: onMapTap,
                  icon: const Icon(Icons.map_outlined),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchImageTile extends StatelessWidget {
  const _SearchImageTile({
    required this.item,
    required this.authHeaders,
    required this.onTap,
  });

  final MemorySearchResultModel item;
  final Map<String, String> authHeaders;
  final VoidCallback onTap;

  String? _imageUrl() {
    final previewPath = item.previewImagePath;
    final previewDate = item.effectiveDate;
    if (previewPath.isEmpty) return null;
    return AppConfig.imageUrlFromPath(previewPath, date: previewDate);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUrl = _imageUrl();
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageUrl != null && imageUrl.isNotEmpty)
              ProtectedNetworkImage(
                imageUrl: imageUrl,
                headers: authHeaders,
                fit: BoxFit.cover,
                errorWidget: Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Container(
                color: theme.colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: Icon(
                  Icons.photo_library_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xB3000000)],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.effectiveDate,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (item.place.isNotEmpty)
                        Text(
                          item.place,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchPreview extends StatelessWidget {
  const _SearchPreview({
    required this.imageUrl,
    required this.icon,
    required this.authHeaders,
  });

  final String? imageUrl;
  final IconData icon;
  final Map<String, String> authHeaders;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 76,
          height: 76,
          child: ProtectedNetworkImage(
            imageUrl: imageUrl!,
            headers: authHeaders,
            fit: BoxFit.cover,
            errorWidget: Container(
              color: colorScheme.surfaceContainerHighest,
              child: Icon(icon, color: colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: colorScheme.onSurfaceVariant),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
