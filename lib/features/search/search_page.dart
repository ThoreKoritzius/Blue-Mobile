import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/date_format.dart';
import '../../data/models/memory_search_result_model.dart';
import '../../data/repositories/search_repository.dart';
import '../../providers.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _TabSearchState {
  const _TabSearchState({
    required this.page,
    required this.pageSize,
    required this.total,
    required this.totalPages,
    required this.items,
    required this.loading,
    required this.loadingMore,
    required this.error,
    required this.hasRequested,
  });

  final int page;
  final int pageSize;
  final int total;
  final int totalPages;
  final List<MemorySearchResultModel> items;
  final bool loading;
  final bool loadingMore;
  final String error;
  final bool hasRequested;

  factory _TabSearchState.empty({required int pageSize}) {
    return _TabSearchState(
      page: 1,
      pageSize: pageSize,
      total: 0,
      totalPages: 1,
      items: const [],
      loading: false,
      loadingMore: false,
      error: '',
      hasRequested: false,
    );
  }

  _TabSearchState copyWith({
    int? page,
    int? pageSize,
    int? total,
    int? totalPages,
    List<MemorySearchResultModel>? items,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool? hasRequested,
  }) {
    return _TabSearchState(
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      total: total ?? this.total,
      totalPages: totalPages ?? this.totalPages,
      items: items ?? this.items,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: error ?? this.error,
      hasRequested: hasRequested ?? this.hasRequested,
    );
  }
}

class _SearchPageState extends ConsumerState<SearchPage>
    with SingleTickerProviderStateMixin {
  static const _daysPageSize = 24;
  static const _imagesPageSize = 36;

  final _controller = TextEditingController();
  final _daysScrollController = ScrollController();
  final _imagesScrollController = ScrollController();

  late final TabController _tabController;

  Timer? _debounce;
  int _queryGeneration = 0;
  String _activeQuery = '';
  late Map<MemorySearchMode, _TabSearchState> _tabStates;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabStates = {
      MemorySearchMode.days: _TabSearchState.empty(pageSize: _daysPageSize),
      MemorySearchMode.images: _TabSearchState.empty(pageSize: _imagesPageSize),
    };
    _daysScrollController.addListener(
      () => _handleScroll(MemorySearchMode.days),
    );
    _imagesScrollController.addListener(
      () => _handleScroll(MemorySearchMode.images),
    );
    _tabController.addListener(_handleTabChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    _controller.dispose();
    _daysScrollController.dispose();
    _imagesScrollController.dispose();
    super.dispose();
  }

  MemorySearchMode get _activeMode => _tabController.index == 0
      ? MemorySearchMode.days
      : MemorySearchMode.images;

  void _handleTabChanged() {
    if (_tabController.indexIsChanging || !mounted) return;
    final state = _tabStates[_activeMode]!;
    if (_activeQuery.isEmpty || state.hasRequested) {
      setState(() {});
      return;
    }
    _runSearch(_activeQuery, mode: _activeMode, reset: true);
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      _runNewQuery(value.trim());
    });
    setState(() {});
  }

  void _runNewQuery(String query) {
    _queryGeneration += 1;

    if (query.isEmpty) {
      setState(() {
        _activeQuery = '';
        _tabStates = {
          MemorySearchMode.days: _TabSearchState.empty(pageSize: _daysPageSize),
          MemorySearchMode.images: _TabSearchState.empty(
            pageSize: _imagesPageSize,
          ),
        };
      });
      return;
    }

    setState(() {
      _activeQuery = query;
      _tabStates = {
        MemorySearchMode.days: _TabSearchState.empty(pageSize: _daysPageSize),
        MemorySearchMode.images: _TabSearchState.empty(
          pageSize: _imagesPageSize,
        ),
      };
    });

    _runSearch(
      query,
      mode: _activeMode,
      reset: true,
      generation: _queryGeneration,
    );
  }

  Future<void> _runSearch(
    String query, {
    required MemorySearchMode mode,
    required bool reset,
    int? generation,
  }) async {
    if (query.isEmpty) return;
    final currentState = _tabStates[mode]!;
    if (currentState.loading || currentState.loadingMore) return;

    final requestGeneration = generation ?? _queryGeneration;
    final nextPage = reset ? 1 : (currentState.page + 1);

    setState(() {
      _tabStates = {
        ..._tabStates,
        mode: currentState.copyWith(
          loading: reset,
          loadingMore: !reset,
          error: '',
          hasRequested: true,
        ),
      };
    });

    try {
      final page = await ref
          .read(searchRepositoryProvider)
          .searchMemories(
            query,
            mode: mode,
            page: nextPage,
            pageSize: currentState.pageSize,
          );
      if (!mounted ||
          requestGeneration != _queryGeneration ||
          query != _activeQuery) {
        return;
      }

      final existing = _tabStates[mode]!;
      setState(() {
        _tabStates = {
          ..._tabStates,
          mode: existing.copyWith(
            page: page.page,
            pageSize: page.pageSize,
            total: page.total,
            totalPages: page.totalPages,
            items: reset ? page.items : [...existing.items, ...page.items],
            loading: false,
            loadingMore: false,
            error: '',
            hasRequested: true,
          ),
        };
      });
    } catch (error) {
      if (!mounted ||
          requestGeneration != _queryGeneration ||
          query != _activeQuery) {
        return;
      }
      final existing = _tabStates[mode]!;
      setState(() {
        _tabStates = {
          ..._tabStates,
          mode: existing.copyWith(
            loading: false,
            loadingMore: false,
            error: error.toString().replaceFirst('Exception: ', ''),
            hasRequested: true,
          ),
        };
      });
    }
  }

  void _handleScroll(MemorySearchMode mode) {
    if (_activeMode != mode || _activeQuery.isEmpty) return;
    final controller = _scrollControllerForMode(mode);
    final state = _tabStates[mode]!;
    if (state.loading || state.loadingMore || state.page >= state.totalPages) {
      return;
    }
    if (!controller.hasClients) return;
    final remaining =
        controller.position.maxScrollExtent - controller.position.pixels;
    if (remaining < 280) {
      _runSearch(_activeQuery, mode: mode, reset: false);
    }
  }

  ScrollController _scrollControllerForMode(MemorySearchMode mode) {
    return mode == MemorySearchMode.days
        ? _daysScrollController
        : _imagesScrollController;
  }

  void _openResult(MemorySearchResultModel item) {
    if (item.date.isNotEmpty) {
      ref.read(selectedDateProvider.notifier).state = parseYmd(item.date);
    }
    ref.read(selectedTabProvider.notifier).state = 0;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authHeaders = _authHeaders();
    final activeState = _tabStates[_activeMode]!;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 88,
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12, top: 8, bottom: 8),
          child: TextField(
            controller: _controller,
            autofocus: true,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: (value) => _runNewQuery(value.trim()),
            decoration: InputDecoration(
              hintText: 'Search memories',
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFEAF1FB),
                borderRadius: BorderRadius.circular(18),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                labelColor: const Color(0xFF163E73),
                unselectedLabelColor: const Color(0xFF6982A1),
                dividerColor: Colors.transparent,
                tabs: [
                  Tab(
                    text: 'Days (${_tabStates[MemorySearchMode.days]!.total})',
                  ),
                  Tab(
                    text:
                        'Images (${_tabStates[MemorySearchMode.images]!.total})',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _activeQuery.isEmpty
                        ? 'Search by date, place, people, tags, or diary text.'
                        : '${activeState.total} matches in ${_activeMode == MemorySearchMode.days ? 'days' : 'images'}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF526A88),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (activeState.loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildTabBody(
                  mode: MemorySearchMode.days,
                  state: _tabStates[MemorySearchMode.days]!,
                  authHeaders: authHeaders,
                ),
                _buildTabBody(
                  mode: MemorySearchMode.images,
                  state: _tabStates[MemorySearchMode.images]!,
                  authHeaders: authHeaders,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBody({
    required MemorySearchMode mode,
    required _TabSearchState state,
    required Map<String, String> authHeaders,
  }) {
    if (_activeQuery.isEmpty) {
      return _SearchBlankState(mode: mode);
    }

    if (state.error.isNotEmpty) {
      return _SearchErrorState(
        message: state.error,
        onRetry: () => _runSearch(_activeQuery, mode: mode, reset: true),
      );
    }

    if (state.loading && state.items.isEmpty) {
      return mode == MemorySearchMode.days
          ? const _DaysSkeletonList()
          : const _ImagesSkeletonGrid();
    }

    if (state.hasRequested && state.items.isEmpty) {
      return _SearchEmptyState(query: _activeQuery, mode: mode);
    }

    if (mode == MemorySearchMode.days) {
      return ListView.builder(
        controller: _scrollControllerForMode(mode),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        itemCount: state.items.length + (state.loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= state.items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _SearchResultCard(
            item: state.items[index],
            authHeaders: authHeaders,
            onTap: () => _openResult(state.items[index]),
          );
        },
      );
    }

    return GridView.builder(
      controller: _scrollControllerForMode(mode),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: state.items.length + (state.loadingMore ? 2 : 0),
      itemBuilder: (context, index) {
        if (index >= state.items.length) {
          return const _ImageTileSkeleton();
        }
        return _ImageSearchTile(
          item: state.items[index],
          authHeaders: authHeaders,
          onTap: () => _openResult(state.items[index]),
        );
      },
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

class _SearchBlankState extends StatelessWidget {
  const _SearchBlankState({required this.mode});

  final MemorySearchMode mode;

  @override
  Widget build(BuildContext context) {
    final isDays = mode == MemorySearchMode.days;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFFE7F0FF), Color(0xFFDCE8FF)],
                ),
              ),
              child: Icon(
                isDays
                    ? Icons.auto_stories_rounded
                    : Icons.photo_library_rounded,
                size: 42,
                color: const Color(0xFF2156A3),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              isDays ? 'Search days' : 'Search images',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              isDays
                  ? 'Find diary entries by date, place, people, tags, or text.'
                  : 'Find matching images and jump straight to the related day.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: const Color(0xFF60738F)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({required this.query, required this.mode});

  final String query;
  final MemorySearchMode mode;

  @override
  Widget build(BuildContext context) {
    final isDays = mode == MemorySearchMode.days;
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
                color: const Color(0xFFF1F5FA),
              ),
              child: Icon(
                isDays
                    ? Icons.event_busy_outlined
                    : Icons.image_search_outlined,
                size: 42,
                color: const Color(0xFF6F85A2),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              isDays ? 'No matching days' : 'No matching images',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Nothing matched "$query". Try a broader place, person, or tag.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: const Color(0xFF60738F)),
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
                color: const Color(0xFF932F2F),
                fontWeight: FontWeight.w600,
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

class _DaysSkeletonList extends StatelessWidget {
  const _DaysSkeletonList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      itemCount: 5,
      itemBuilder: (context, index) => const _DayCardSkeleton(),
    );
  }
}

class _DayCardSkeleton extends StatelessWidget {
  const _DayCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _SkeletonBox(
              width: 72,
              height: 72,
              radius: BorderRadius.circular(14),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonBox(width: 90, height: 14),
                  SizedBox(height: 8),
                  _SkeletonBox(width: 130, height: 18),
                  SizedBox(height: 10),
                  _SkeletonBox(width: double.infinity, height: 12),
                  SizedBox(height: 6),
                  _SkeletonBox(width: 180, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImagesSkeletonGrid extends StatelessWidget {
  const _ImagesSkeletonGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: 6,
      itemBuilder: (_, __) => const _ImageTileSkeleton(),
    );
  }
}

class _ImageTileSkeleton extends StatelessWidget {
  const _ImageTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          const Expanded(
            child: _SkeletonBox(
              width: double.infinity,
              height: double.infinity,
              radius: BorderRadius.zero,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _SkeletonBox(width: 84, height: 12),
                SizedBox(height: 8),
                _SkeletonBox(width: double.infinity, height: 14),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatefulWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    this.radius = const BorderRadius.all(Radius.circular(12)),
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
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.radius,
            color: Color.lerp(
              const Color(0xFFE9EFF7),
              const Color(0xFFDCE6F4),
              _controller.value,
            ),
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
  });

  final MemorySearchResultModel item;
  final Map<String, String> authHeaders;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = item.previewImagePath.trim();
    final meta = [...item.people.take(3), ...item.tags.take(3)];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (preview.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: CachedNetworkImage(
                    imageUrl: AppConfig.imageUrlFromPath(
                      preview,
                      date: item.date,
                    ),
                    httpHeaders: authHeaders,
                    width: 78,
                    height: 78,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      width: 78,
                      height: 78,
                      color: const Color(0xFFEAF0F8),
                      child: const Icon(Icons.image_not_supported_outlined),
                    ),
                  ),
                ),
              if (preview.isNotEmpty) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.date.isEmpty ? 'Unknown date' : item.date,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: const Color(0xFF19447B),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (item.place.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.place,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                    if (item.description.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: meta
                            .map(
                              (entry) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEAF1FB),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  entry,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImageSearchTile extends StatelessWidget {
  const _ImageSearchTile({
    required this.item,
    required this.authHeaders,
    required this.onTap,
  });

  final MemorySearchResultModel item;
  final Map<String, String> authHeaders;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = item.previewImagePath.trim();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: AppConfig.imageUrlFromPath(
                      preview,
                      date: item.date,
                    ),
                    httpHeaders: authHeaders,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      color: const Color(0xFFEAF0F8),
                      child: const Icon(Icons.image_not_supported_outlined),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xAA0B1422),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.date.isEmpty ? 'Unknown date' : item.date,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            if (item.place.isNotEmpty)
                              Text(
                                item.place,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: const Color(0xFFD9E4F5)),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
