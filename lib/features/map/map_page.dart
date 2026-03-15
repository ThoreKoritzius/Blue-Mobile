import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_polyline_algorithm/google_polyline_algorithm.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/date_format.dart';
import '../../data/models/run_model.dart';
import '../../data/repositories/map_repository.dart';
import '../../providers.dart';

enum _MapStyle { light, dark, normal }

enum _DisplayType { images, runs, both }

class _RunOverlay {
  const _RunOverlay({
    required this.run,
    required this.points,
    required this.anchor,
    required this.color,
  });

  final RunModel run;
  final List<LatLng> points;
  final LatLng anchor;
  final Color color;
}

class _ImageOverlay {
  const _ImageOverlay({required this.point, required this.position});

  final MapPoint point;
  final LatLng position;
}

class MapPage extends ConsumerStatefulWidget {
  const MapPage({super.key});

  @override
  ConsumerState<MapPage> createState() => _MapPageState();
}

class _MapPageState extends ConsumerState<MapPage> {
  static const double _imageLoadZoomThreshold = 3.5;
  static const int _mapTabIndex = 4;
  static const int _imagePageSize = 60;
  static const Duration _viewportDebounce = Duration(milliseconds: 350);
  static const Duration _pageDelay = Duration(milliseconds: 650);
  static const double _viewportPadFactor = 0.2;
  static const _loadingTextKey = Key('map-loading-text');
  static const _loadedTextKey = Key('map-loaded-text');
  static const _errorTextKey = Key('map-error-text');
  static const _emptyTextKey = Key('map-empty-text');

  final MapController _mapController = MapController();
  final Map<String, _ImageOverlay> _imageCache = <String, _ImageOverlay>{};
  late final ProviderSubscription<int> _selectedTabSubscription;

  Timer? _viewportDebounceTimer;
  Timer? _nextImagePageTimer;

  List<_RunOverlay> _runs = const [];
  bool _runsLoading = true;
  bool _imagesLoading = false;
  bool _imageSearchExhausted = false;
  bool _imageRequestInFlight = false;
  String _error = '';
  int _imagesLoaded = 0;
  int _runsLoaded = 0;
  int _nextImagePage = 1;
  int _imageSearchGeneration = 0;
  double _currentZoom = 2.2;
  LatLngBounds? _currentBounds;
  bool _isVisibleTab = false;
  bool _hasStartedLoad = false;
  _MapStyle _mapStyle = _MapStyle.light;
  _DisplayType _displayType = _DisplayType.both;
  bool _differentRouteColors = false;

  @override
  void initState() {
    super.initState();
    _isVisibleTab = ref.read(selectedTabProvider) == _mapTabIndex;
    _selectedTabSubscription = ref.listenManual<int>(selectedTabProvider, (
      previous,
      next,
    ) {
      final isVisible = next == _mapTabIndex;
      if (isVisible == _isVisibleTab) return;
      _isVisibleTab = isVisible;
      if (!_isVisibleTab) {
        _stopImageSearch();
        return;
      }
      if (!_hasStartedLoad) {
        _load();
      } else {
        _ensureImagesLoadedIfNeeded();
      }
    });
    if (_isVisibleTab) {
      _load();
    } else {
      _runsLoading = false;
    }
  }

  @override
  void dispose() {
    _viewportDebounceTimer?.cancel();
    _nextImagePageTimer?.cancel();
    _selectedTabSubscription.close();
    super.dispose();
  }

  Future<void> _load() async {
    _hasStartedLoad = true;
    _viewportDebounceTimer?.cancel();
    _nextImagePageTimer?.cancel();
    _imageSearchGeneration += 1;
    _imageRequestInFlight = false;

    setState(() {
      _runsLoading = true;
      _imagesLoading = false;
      _imageSearchExhausted = false;
      _error = '';
      _imageCache.clear();
      _imagesLoaded = 0;
      _runsLoaded = 0;
      _nextImagePage = 1;
    });

    await _loadRuns(ref.read(mapRepositoryProvider));
    _ensureImagesLoadedIfNeeded();
  }

  Future<void> _loadRuns(MapRepository repo) async {
    try {
      final runs = await repo.loadRuns();
      final overlays = <_RunOverlay>[];
      for (final run in runs) {
        if (run.summaryPolyline.isEmpty) continue;
        try {
          final decoded = decodePolyline(run.summaryPolyline)
              .map((pair) => LatLng(pair[0].toDouble(), pair[1].toDouble()))
              .toList();
          if (decoded.length < 2) continue;
          overlays.add(
            _RunOverlay(
              run: run,
              points: decoded,
              anchor: decoded.first,
              color: _colorForSeed(run.id),
            ),
          );
        } catch (_) {
          // Skip invalid polylines without failing the entire page.
        }
      }
      if (!mounted) return;
      setState(() {
        _runs = overlays;
        _runsLoaded = overlays.length;
        _runsLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('[MAP] _loadRuns failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _runsLoading = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _handleCameraChanged(MapCamera camera) {
    final nextZoom = camera.zoom;
    final nextBounds = camera.visibleBounds;
    final zoomChanged = (nextZoom - _currentZoom).abs() > 0.01;
    final boundsChanged = !_boundsCloseEnough(_currentBounds, nextBounds);
    if (!zoomChanged && !boundsChanged) return;

    if (mounted) {
      setState(() {
        _currentZoom = nextZoom;
        _currentBounds = nextBounds;
      });
    }
    _scheduleViewportRefresh();
  }

  void _onMapReady() {
    if (!mounted) return;
    final camera = _mapController.camera;
    setState(() {
      _currentZoom = camera.zoom;
      _currentBounds = camera.visibleBounds;
    });
    _scheduleViewportRefresh();
  }

  void _scheduleViewportRefresh() {
    if (!_isVisibleTab) return;
    _viewportDebounceTimer?.cancel();
    _viewportDebounceTimer = Timer(_viewportDebounce, () {
      if (!mounted) return;
      _imageSearchGeneration += 1;
      _nextImagePageTimer?.cancel();
      _ensureImagesLoadedIfNeeded();
      setState(() {});
    });
  }

  void _ensureImagesLoadedIfNeeded() {
    if (!_needsImagesForViewport()) {
      _stopImageSearch();
      return;
    }

    if (_hasEnoughVisibleImages()) {
      if (_imagesLoading && mounted) {
        setState(() => _imagesLoading = false);
      }
      return;
    }

    _scheduleNextImagePage();
  }

  bool _needsImagesForViewport() {
    return _isVisibleTab &&
        _displayType != _DisplayType.runs &&
        _currentBounds != null &&
        _currentZoom >= _imageLoadZoomThreshold;
  }

  void _stopImageSearch() {
    _imageSearchGeneration += 1;
    _nextImagePageTimer?.cancel();
    if (_imagesLoading && mounted) {
      setState(() => _imagesLoading = false);
    }
  }

  void _scheduleNextImagePage() {
    if (_imageRequestInFlight ||
        _imageSearchExhausted ||
        !_needsImagesForViewport()) {
      return;
    }

    _nextImagePageTimer?.cancel();
    if (mounted) {
      setState(() {
        _imagesLoading = true;
      });
    }
    final generation = _imageSearchGeneration;
    _nextImagePageTimer = Timer(_pageDelay, () {
      _loadNextImagePage(generation);
    });
  }

  Future<void> _loadNextImagePage(int generation) async {
    if (_imageRequestInFlight ||
        generation != _imageSearchGeneration ||
        !_needsImagesForViewport() ||
        _imageSearchExhausted) {
      return;
    }

    _imageRequestInFlight = true;
    final page = _nextImagePage;

    try {
      final result = await ref
          .read(mapRepositoryProvider)
          .searchImagePage(page: page, pageSize: _imagePageSize);

      if (!mounted) return;
      if (generation != _imageSearchGeneration) {
        debugPrint('[MAP] stale image page ignored page=$page');
        return;
      }

      for (final point in result.points) {
        _imageCache[point.path] = _ImageOverlay(
          point: point,
          position: LatLng(point.lat, point.lon),
        );
      }

      setState(() {
        _imagesLoaded = _imageCache.length;
        _nextImagePage = page + 1;
        _imageSearchExhausted = !result.hasMore;
      });
    } catch (error, stackTrace) {
      debugPrint('[MAP] _loadNextImagePage failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _imagesLoading = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      _imageRequestInFlight = false;
      if (mounted) {
        if (generation != _imageSearchGeneration) {
          _ensureImagesLoadedIfNeeded();
        } else {
          final shouldContinue =
              _needsImagesForViewport() &&
              !_imageSearchExhausted &&
              !_hasEnoughVisibleImages();

          setState(() {
            _imagesLoading = shouldContinue;
          });

          if (shouldContinue) {
            _scheduleNextImagePage();
          }
        }
      }
    }
  }

  bool _hasEnoughVisibleImages() {
    return _visibleImages().length >= _targetVisibleImageCount();
  }

  List<_ImageOverlay> _visibleImages() {
    final bounds = _expandedBounds();
    if (bounds == null || _imageCache.isEmpty) return const [];

    final candidates =
        _imageCache.values
            .where((image) => bounds.contains(image.position))
            .toList()
          ..sort((a, b) => b.point.date.compareTo(a.point.date));

    final cap = _maxVisibleImageMarkers();
    if (candidates.length > cap) {
      return candidates.take(cap).toList();
    }
    return candidates;
  }

  LatLngBounds? _expandedBounds() {
    final bounds = _currentBounds;
    if (bounds == null) return null;
    final north = math.max(
      bounds.northWest.latitude,
      bounds.northEast.latitude,
    );
    final south = math.min(
      bounds.southWest.latitude,
      bounds.southEast.latitude,
    );
    final west = math.min(
      bounds.northWest.longitude,
      bounds.southWest.longitude,
    );
    final east = math.max(
      bounds.northEast.longitude,
      bounds.southEast.longitude,
    );
    final latPad = ((north - south).abs() * _viewportPadFactor).clamp(1, 30);
    final lonPad = ((east - west).abs() * _viewportPadFactor).clamp(1, 40);

    return LatLngBounds(
      LatLng(
        (south - latPad).clamp(-90, 90).toDouble(),
        (west - lonPad).clamp(-180, 180).toDouble(),
      ),
      LatLng(
        (north + latPad).clamp(-90, 90).toDouble(),
        (east + lonPad).clamp(-180, 180).toDouble(),
      ),
    );
  }

  int _targetVisibleImageCount() {
    if (_currentZoom <= 4) return 10;
    if (_currentZoom <= 5) return 16;
    if (_currentZoom <= 6) return 24;
    if (_currentZoom <= 7) return 36;
    return 48;
  }

  int _maxVisibleImageMarkers() {
    if (_currentZoom <= 4) return 18;
    if (_currentZoom <= 5) return 30;
    if (_currentZoom <= 6) return 48;
    if (_currentZoom <= 7) return 72;
    return 96;
  }

  @override
  Widget build(BuildContext context) {
    final tileConfig = AppConfig.mapTileConfig(_mapStyle.name);
    final center = _initialCenter();
    final showImages = _displayType != _DisplayType.runs;
    final showRuns = _displayType != _DisplayType.images;
    final visibleImages = showImages
        ? _visibleImages()
        : const <_ImageOverlay>[];
    final loading = _runsLoading || (showImages && _imagesLoading);
    final routeColor = _mapStyle == _MapStyle.dark
        ? const Color(0xFFF79C70)
        : const Color(0xFF2065D1);
    final imageBorderColor = _mapStyle == _MapStyle.dark
        ? const Color(0xFF6EB1FF)
        : const Color(0xFFD32F2F);
    final imageMarkerSize = _imageMarkerSizeForZoom(_currentZoom);
    final imageIconSize = imageMarkerSize * 0.5;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: _currentZoom,
            onMapReady: _onMapReady,
            onPositionChanged: (camera, _) => _handleCameraChanged(camera),
          ),
          children: [
            TileLayer(
              urlTemplate: tileConfig.urlTemplate,
              subdomains: tileConfig.subdomains,
              maxZoom: tileConfig.maxZoom.toDouble(),
              userAgentPackageName: 'blue_mobile',
            ),
            if (showRuns)
              PolylineLayer(
                polylines: _runs
                    .map(
                      (run) => Polyline(
                        points: run.points,
                        strokeWidth: 3,
                        color: _differentRouteColors ? run.color : routeColor,
                      ),
                    )
                    .toList(),
              ),
            if (showRuns)
              MarkerLayer(
                markers: _runs
                    .map(
                      (run) => Marker(
                        point: run.anchor,
                        width: 28,
                        height: 28,
                        child: GestureDetector(
                          onTap: () => _showRunSheet(run),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color:
                                  (_differentRouteColors
                                          ? run.color
                                          : routeColor)
                                      .withValues(alpha: 0.88),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white),
                            ),
                            child: const Icon(
                              Icons.directions_run,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            if (showImages)
              MarkerLayer(
                markers: visibleImages
                    .map(
                      (image) => Marker(
                        point: image.position,
                        width: imageMarkerSize,
                        height: imageMarkerSize,
                        child: GestureDetector(
                          onTap: () => _showImageSheet(image),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: imageBorderColor.withValues(alpha: 0.92),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white),
                              boxShadow: const [
                                BoxShadow(
                                  blurRadius: 6,
                                  color: Color(0x33000000),
                                ),
                              ],
                            ),
                            child: Icon(
                              Icons.photo_camera,
                              size: imageIconSize,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
        Positioned(
          top: 16,
          left: 16,
          right: 84,
          child: _StatusBanner(
            loading: loading,
            error: _error,
            imagesLoaded: _imagesLoaded,
            visibleImages: visibleImages.length,
            runsLoaded: _runsLoaded,
            hasData: visibleImages.isNotEmpty || _runs.isNotEmpty,
            waitingForImageZoom:
                showImages && _currentZoom < _imageLoadZoomThreshold,
          ),
        ),
        if (!loading &&
            _error.isEmpty &&
            visibleImages.isEmpty &&
            _runs.isEmpty &&
            !(showImages && _currentZoom < _imageLoadZoomThreshold))
          Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Text(
                  'No map data found.',
                  key: _emptyTextKey,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            heroTag: 'map_controls',
            onPressed: _showControlsSheet,
            child: const Icon(Icons.tune),
          ),
        ),
      ],
    );
  }

  LatLng _initialCenter() {
    if (_imageCache.isNotEmpty) return _imageCache.values.first.position;
    if (_runs.isNotEmpty) return _runs.first.points.first;
    return const LatLng(20, 0);
  }

  double _imageMarkerSizeForZoom(double zoom) {
    if (zoom <= 3) return 12;
    if (zoom <= 4) return 16;
    if (zoom <= 5) return 20;
    if (zoom <= 6) return 24;
    if (zoom <= 7) return 28;
    return 34;
  }

  Future<void> _showControlsSheet() {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            void update(VoidCallback action) {
              setState(action);
              setModalState(() {});
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Map Controls',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Map Style',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: _MapStyle.values
                          .map(
                            (style) => ChoiceChip(
                              label: Text(_mapStyleLabel(style)),
                              selected: _mapStyle == style,
                              onSelected: (_) => update(() {
                                _mapStyle = style;
                              }),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Visible Layers',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: _DisplayType.values
                          .map(
                            (displayType) => ChoiceChip(
                              label: Text(_displayTypeLabel(displayType)),
                              selected: _displayType == displayType,
                              onSelected: (_) => update(() {
                                _displayType = displayType;
                                _ensureImagesLoadedIfNeeded();
                              }),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Different route colors'),
                      value: _differentRouteColors,
                      onChanged: (value) => update(() {
                        _differentRouteColors = value;
                      }),
                    ),
                    if (!AppConfig.hasMapboxToken)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'MAPBOX_ACCESS_TOKEN is not set. Using fallback tiles.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showImageSheet(_ImageOverlay image) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    image.point.date,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: CachedNetworkImage(
                      imageUrl: image.point.path,
                      httpHeaders: _authHeaders(),
                      height: 220,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        height: 220,
                        color: const Color(0x11000000),
                        alignment: Alignment.center,
                        child: const Icon(Icons.image_not_supported_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _openDay(image.point.date);
                    },
                    child: const Text('Open day'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showRunSheet(_RunOverlay runOverlay) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final run = runOverlay.run;
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    run.name.isEmpty ? 'Run ${run.id}' : run.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(run.startDateLocal),
                  Text('${run.distanceKm.toStringAsFixed(2)} km'),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      AppConfig.runImageUrl(run.id),
                      headers: _authHeaders(),
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 200,
                        color: const Color(0x11000000),
                        alignment: Alignment.center,
                        child: const Icon(Icons.image_not_supported_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          ref.read(selectedTabProvider.notifier).state = 2;
                        },
                        child: const Text('Open runs'),
                      ),
                      OutlinedButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          _openDay(run.startDateLocal.split('T').first);
                        },
                        child: const Text('Open day'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openDay(String date) {
    ref.read(selectedDateProvider.notifier).state = parseYmd(date);
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

  String _mapStyleLabel(_MapStyle style) {
    switch (style) {
      case _MapStyle.light:
        return 'Light';
      case _MapStyle.dark:
        return 'Dark';
      case _MapStyle.normal:
        return 'Normal';
    }
  }

  String _displayTypeLabel(_DisplayType displayType) {
    switch (displayType) {
      case _DisplayType.images:
        return 'Images';
      case _DisplayType.runs:
        return 'Runs';
      case _DisplayType.both:
        return 'Both';
    }
  }

  bool _boundsCloseEnough(LatLngBounds? a, LatLngBounds b) {
    if (a == null) return false;
    return (a.northWest.latitude - b.northWest.latitude).abs() < 0.2 &&
        (a.northWest.longitude - b.northWest.longitude).abs() < 0.2 &&
        (a.southEast.latitude - b.southEast.latitude).abs() < 0.2 &&
        (a.southEast.longitude - b.southEast.longitude).abs() < 0.2;
  }

  Color _colorForSeed(String seed) {
    final hash = seed.hashCode;
    final hue = (hash % 360).abs().toDouble();
    final random = math.Random(hash);
    final saturation = 0.55 + (random.nextDouble() * 0.25);
    final value = 0.72 + (random.nextDouble() * 0.18);
    return HSVColor.fromAHSV(1, hue, saturation, value).toColor();
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.loading,
    required this.error,
    required this.imagesLoaded,
    required this.visibleImages,
    required this.runsLoaded,
    required this.hasData,
    required this.waitingForImageZoom,
  });

  final bool loading;
  final String error;
  final int imagesLoaded;
  final int visibleImages;
  final int runsLoaded;
  final bool hasData;
  final bool waitingForImageZoom;

  @override
  Widget build(BuildContext context) {
    if (error.isNotEmpty) {
      return Material(
        color: Colors.transparent,
        child: Card(
          color: const Color(0xFFFDEDED),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              error,
              key: _MapPageState._errorTextKey,
              style: const TextStyle(color: Color(0xFF8A1C1C)),
            ),
          ),
        ),
      );
    }

    if (loading) {
      return Material(
        color: Colors.transparent,
        child: Card(
          color: const Color(0xD9222222),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  'Loading viewport... $visibleImages shown, $imagesLoaded cached, $runsLoaded runs',
                  key: _MapPageState._loadingTextKey,
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (waitingForImageZoom) {
      return Material(
        color: Colors.transparent,
        child: Card(
          color: const Color(0xD9222222),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
              'Zoom in to load image markers. Runs are already loaded.',
              key: _MapPageState._loadedTextKey,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      );
    }

    if (!hasData) return const SizedBox.shrink();

    return Material(
      color: Colors.transparent,
      child: Card(
        color: const Color(0xD9222222),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            'Showing $visibleImages images from $imagesLoaded cached points, $runsLoaded runs',
            key: _MapPageState._loadedTextKey,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
