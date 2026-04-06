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

class _MapPageState extends ConsumerState<MapPage>
    with TickerProviderStateMixin {
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
  late final ProviderSubscription<DateTime> _selectedDateSubscription;
  String? _pendingDayViewDate;

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

  // Day-view state
  bool _dayViewMode = false;
  String _dayViewDate = '';
  bool _dayViewLoading = false;
  String _dayViewError = '';
  TimelineDayData? _dayViewData;
  // All dates with run data, used to build the slider
  List<String> _dayViewDates = const [];
  int _dayViewDateIndex = 0;
  String? _selectedVisitPlaceId;
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

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
      // If a day-view was requested and runs are already loaded, enter now.
      // If runs are still loading, _pendingDayViewDate will be consumed in _loadRuns.
      final pending = _pendingDayViewDate;
      if (pending != null && !_runsLoading) {
        _pendingDayViewDate = null;
        _enterDayView(pending);
      }
    });
    _selectedDateSubscription = ref.listenManual<DateTime>(
      selectedDateProvider,
      (previous, next) {
        // Only treat this as a map day-view request when the map tab is active.
        if (ref.read(selectedTabProvider) != _mapTabIndex) return;
        final dateStr =
            '${next.year.toString().padLeft(4, '0')}-'
            '${next.month.toString().padLeft(2, '0')}-'
            '${next.day.toString().padLeft(2, '0')}';
        if (_isVisibleTab && !_runsLoading) {
          // Tab visible and runs loaded — enter day-view immediately.
          _enterDayView(dateStr);
        } else {
          // Either tab not yet visible or runs still loading — consume later.
          _pendingDayViewDate = dateStr;
        }
      },
    );
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
    _selectedDateSubscription.close();
    _sheetController.dispose();
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
      final pending = _pendingDayViewDate;
      if (pending != null) {
        _pendingDayViewDate = null;
        _enterDayView(pending);
      }
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
    if (_dayViewMode) return _buildDayView(context);

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
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
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
          top: 16,
          child: FloatingActionButton.small(
            heroTag: 'map_controls',
            onPressed: _showControlsSheet,
            child: const Icon(Icons.tune),
          ),
        ),
        // Day-view toggle at bottom-left
        if (!_runsLoading)
          Positioned(
            left: 16,
            bottom: 16,
            child: FloatingActionButton.small(
              heroTag: 'map_day_toggle',
              tooltip: 'Day view',
              onPressed: _runs.isNotEmpty
                  ? () => _enterDayView(
                      _runs.last.run.startDateLocal.split('T').first,
                    )
                  : null,
              child: const Icon(Icons.calendar_today),
            ),
          ),
      ],
    );
  }

  Widget _buildDayView(BuildContext context) {
    final tileConfig = AppConfig.mapTileConfig(_mapStyle.name);
    final data = _dayViewData;
    final walkColor = _mapStyle == _MapStyle.dark
        ? const Color(0xFF81C784)
        : const Color(0xFF2E7D32);
    final imageBorderColor = _mapStyle == _MapStyle.dark
        ? const Color(0xFF6EB1FF)
        : const Color(0xFFD32F2F);

    // Walk points come directly as LatLng list from the repository
    final walkPoints = data != null
        ? data.walkPoints.map((p) => LatLng(p.lat, p.lon)).toList()
        : const <LatLng>[];

    // Decode run polylines
    final runPolylines = <Polyline>[];
    final runMarkers = <Marker>[];
    if (data != null) {
      for (final run in data.runs) {
        if (run.summaryPolyline.isEmpty) continue;
        try {
          final pts = decodePolyline(
            run.summaryPolyline,
          ).map((p) => LatLng(p[0].toDouble(), p[1].toDouble())).toList();
          if (pts.length < 2) continue;
          final color = _colorForSeed(run.id);
          runPolylines.add(Polyline(points: pts, strokeWidth: 3, color: color));
          // Try to find the matching full RunOverlay for the sheet.
          final matchingOverlay = _runs
              .where((r) => r.run.id == run.id)
              .firstOrNull;
          runMarkers.add(
            Marker(
              point: pts.first,
              width: 28,
              height: 28,
              child: GestureDetector(
                onTap: () {
                  if (matchingOverlay != null) {
                    _showRunSheet(matchingOverlay);
                  } else {
                    _showDayRunSheet(run);
                  }
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.88),
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
          );
        } catch (_) {}
      }
    }

    // Image markers
    final imageMarkers = <Marker>[];
    if (data != null) {
      for (final img in data.imageLocations) {
        imageMarkers.add(
          Marker(
            point: LatLng(img.lat, img.lon),
            width: 28,
            height: 28,
            child: GestureDetector(
              onTap: () => _showDayImageSheet(img, _dayViewDate),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: imageBorderColor.withValues(alpha: 0.92),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white),
                  boxShadow: const [
                    BoxShadow(blurRadius: 6, color: Color(0x33000000)),
                  ],
                ),
                child: const Icon(
                  Icons.photo_camera,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        );
      }
    }

    // Visit markers
    final visitMarkers = <Marker>[];
    if (data != null) {
      for (final visit in data.visits) {
        if (visit.lat == null || visit.lon == null) continue;
        final isSelected = visit.placeId == _selectedVisitPlaceId;
        visitMarkers.add(
          Marker(
            point: LatLng(visit.lat!, visit.lon!),
            width: isSelected ? 36 : 28,
            height: isSelected ? 36 : 28,
            child: GestureDetector(
              onTap: () => _onVisitMarkerTapped(visit),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: isSelected ? 36 : 28,
                height: isSelected ? 36 : 28,
                decoration: BoxDecoration(
                  color: const Color(0xE06EB1FF),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white,
                    width: isSelected ? 2.5 : 1.0,
                  ),
                  boxShadow: [
                    if (isSelected)
                      const BoxShadow(
                        blurRadius: 8,
                        spreadRadius: 1,
                        color: Color(0x556EB1FF),
                      )
                    else
                      const BoxShadow(
                        blurRadius: 6,
                        color: Color(0x33000000),
                      ),
                  ],
                ),
                child: Icon(
                  Icons.location_on,
                  size: isSelected ? 20 : 14,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        );
      }
      // Move selected marker to end so it renders on top.
      if (_selectedVisitPlaceId != null && visitMarkers.length > 1) {
        final geoVisits = data.visits
            .where((v) => v.lat != null && v.lon != null)
            .toList();
        final idx = geoVisits.indexWhere(
          (v) => v.placeId == _selectedVisitPlaceId,
        );
        if (idx >= 0 && idx < visitMarkers.length - 1) {
          visitMarkers.add(visitMarkers.removeAt(idx));
        }
      }
    }

    final hasSlider = _dayViewDates.length > 1;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _initialCenter(),
            initialZoom: _currentZoom,
            onMapReady: _onMapReady,
            onPositionChanged: (camera, _) => _handleCameraChanged(camera),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: tileConfig.urlTemplate,
              subdomains: tileConfig.subdomains,
              maxZoom: tileConfig.maxZoom.toDouble(),
              userAgentPackageName: 'blue_mobile',
            ),
            if (walkPoints.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: walkPoints,
                    strokeWidth: 4,
                    color: walkColor,
                  ),
                ],
              ),
            if (runPolylines.isNotEmpty) PolylineLayer(polylines: runPolylines),
            if (runMarkers.isNotEmpty) MarkerLayer(markers: runMarkers),
            if (imageMarkers.isNotEmpty) MarkerLayer(markers: imageMarkers),
            if (visitMarkers.isNotEmpty) MarkerLayer(markers: visitMarkers),
          ],
        ),
        // Top bar: back button + date label + loading/error
        Positioned(
          top: 16,
          left: 16,
          right: 84,
          child: Row(
            children: [
              Material(
                color: const Color(0xD9222222),
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _exitDayView,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.arrow_back, color: Colors.white, size: 18),
                        SizedBox(width: 6),
                        Text('Overview', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Bottom: date slider + visits sheet
        if (hasSlider)
          Positioned.fill(
            child: _DayBottomSheet(
              dates: _dayViewDates,
              currentIndex: _dayViewDateIndex,
              onDateChanged: _onDaySliderChanged,
              data: data,
              onVisitTapped: _onBottomSheetVisitTapped,
              onSegmentTapped: _onSegmentTapped,
              onRunTapped: _onRunTapped,
              selectedVisitPlaceId: _selectedVisitPlaceId,
              sheetController: _sheetController,
              authHeaders: _authHeaders(),
              runColors: {
                for (final r in data?.runs ?? <TimelineRun>[])
                  r.id: _colorForSeed(r.id),
              },
            ),
          ),
        // Controls FAB
        Positioned(
          right: 16,
          top: 16,
          child: FloatingActionButton.small(
            heroTag: 'map_controls',
            onPressed: _showControlsSheet,
            child: const Icon(Icons.tune),
          ),
        ),
      ],
    );
  }

  Future<void> _showDayRunSheet(TimelineRun run) {
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
                    run.name.isEmpty ? 'Run ${run.id}' : run.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
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
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      ref.read(selectedTabProvider.notifier).state = 2;
                    },
                    child: const Text('Open runs'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showDayImageSheet(TimelineImageLocation img, String date) {
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
                  Text(date, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: CachedNetworkImage(
                      imageUrl: img.path,
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
                      _openDay(date);
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

  IconData _mapStyleIcon(_MapStyle style) {
    switch (style) {
      case _MapStyle.light:
        return Icons.light_mode_outlined;
      case _MapStyle.dark:
        return Icons.dark_mode_outlined;
      case _MapStyle.normal:
        return Icons.map_outlined;
    }
  }

  Future<void> _showControlsSheet() {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            void update(VoidCallback action) {
              setState(action);
              setModalState(() {});
            }

            final theme = Theme.of(context);
            final colorScheme = theme.colorScheme;

            Widget buildStyleCard(_MapStyle style) {
              final selected = _mapStyle == style;
              return Expanded(
                child: GestureDetector(
                  onTap: () => update(() => _mapStyle = style),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: selected
                          ? colorScheme.primaryContainer
                          : colorScheme.surfaceContainerHighest.withValues(
                              alpha: 0.5,
                            ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: selected
                            ? colorScheme.primary
                            : colorScheme.outlineVariant.withValues(alpha: 0.4),
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          _mapStyleIcon(style),
                          size: 26,
                          color: selected
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _mapStyleLabel(style),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: selected
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              title: Row(
                children: [
                  Icon(Icons.tune, size: 22, color: colorScheme.primary),
                  const SizedBox(width: 10),
                  const Text('Map Controls'),
                ],
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'STYLE',
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.2,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    spacing: 10,
                    children: _MapStyle.values
                        .map((s) => buildStyleCard(s))
                        .toList(),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'VISIBLE LAYERS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.2,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<_DisplayType>(
                    segments: _DisplayType.values
                        .map(
                          (dt) => ButtonSegment<_DisplayType>(
                            value: dt,
                            label: Text(_displayTypeLabel(dt)),
                          ),
                        )
                        .toList(),
                    selected: {_displayType},
                    onSelectionChanged: (selection) => update(() {
                      _displayType = selection.first;
                      _ensureImagesLoadedIfNeeded();
                    }),
                    showSelectedIcon: false,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
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

  // ── Day-view ────────────────────────────────────────────────────────────────

  Future<void> _enterDayView(String date) async {
    // Build a sorted list of unique dates from loaded runs, capped at today.
    final today = DateTime.now();
    final todayStr =
        '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
    final dates =
        _runs
            .map((r) => r.run.startDateLocal.split('T').first)
            .where((d) => d.isNotEmpty && d.compareTo(todayStr) <= 0)
            .toSet()
            .toList()
          ..sort();

    // Always include today as the rightmost tick.
    if (!dates.contains(todayStr)) dates.add(todayStr);

    // If still empty, seed with the requested date.
    if (dates.isEmpty) dates.add(date);

    // Always ensure the requested date is present in the list.
    if (!dates.contains(date)) dates.add(date);
    dates.sort();

    final idx = dates.indexOf(date);
    setState(() {
      _dayViewMode = true;
      _dayViewDates = dates;
      _dayViewDateIndex = idx;
      _dayViewDate = date;
    });
    await _loadDayView(date);
  }

  void _exitDayView() {
    setState(() {
      _dayViewMode = false;
      _dayViewData = null;
      _dayViewError = '';
      _dayViewLoading = false;
      _selectedVisitPlaceId = null;
    });
  }

  Future<void> _loadDayView(String date) async {
    setState(() {
      _dayViewLoading = true;
      _dayViewError = '';
      _dayViewData = null;
      _dayViewDate = date;
      _selectedVisitPlaceId = null;
    });
    try {
      final data = await ref.read(mapRepositoryProvider).loadTimelineDay(date);
      if (!mounted) return;
      setState(() {
        _dayViewData = data;
        _dayViewLoading = false;
      });
      // Fit map to the day's content.
      _fitDayViewBounds(data);
    } catch (error, stackTrace) {
      debugPrint('[DAY_VIEW] loadDayView failed date=$date error=$error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _dayViewLoading = false;
        _dayViewError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _fitDayViewBounds(TimelineDayData data) {
    final points = <LatLng>[
      for (final img in data.imageLocations) LatLng(img.lat, img.lon),
      for (final v in data.visits)
        if (v.lat != null && v.lon != null) LatLng(v.lat!, v.lon!),
    ];
    points.addAll(data.walkPoints.map((p) => LatLng(p.lat, p.lon)));
    for (final run in data.runs) {
      if (run.summaryPolyline.isEmpty) continue;
      try {
        points.addAll(
          decodePolyline(
            run.summaryPolyline,
          ).map((p) => LatLng(p[0].toDouble(), p[1].toDouble())),
        );
      } catch (_) {}
    }
    if (points.length < 2) return;
    final bounds = LatLngBounds.fromPoints(points);
    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40)),
    );
  }

  void _onDaySliderChanged(double value) {
    final idx = value.round().clamp(0, _dayViewDates.length - 1);
    if (idx == _dayViewDateIndex) return;
    setState(() => _dayViewDateIndex = idx);
    _loadDayView(_dayViewDates[idx]);
  }

  void _animatedMove(LatLng target, double zoom) {
    final camera = _mapController.camera;
    final latTween = Tween<double>(
      begin: camera.center.latitude,
      end: target.latitude,
    );
    final lngTween = Tween<double>(
      begin: camera.center.longitude,
      end: target.longitude,
    );
    final zoomTween = Tween<double>(begin: camera.zoom, end: zoom);

    final controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOut);

    controller.addListener(() {
      _mapController.move(
        LatLng(latTween.evaluate(curved), lngTween.evaluate(curved)),
        zoomTween.evaluate(curved),
      );
    });
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        controller.dispose();
      }
    });
    controller.forward();
  }

  void _onVisitMarkerTapped(TimelineVisit visit) {
    setState(() => _selectedVisitPlaceId = visit.placeId);
    if (_sheetController.isAttached) {
      _sheetController.animateTo(
        0.6,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _onBottomSheetVisitTapped(TimelineVisit visit) {
    setState(() => _selectedVisitPlaceId = visit.placeId);
    if (visit.lat != null && visit.lon != null) {
      _animatedMove(
        LatLng(visit.lat!, visit.lon!),
        math.max(_currentZoom, 15.0),
      );
    }
  }

  void _onRunTapped(TimelineRun run) {
    if (run.summaryPolyline.isEmpty) return;
    try {
      final pts = decodePolyline(run.summaryPolyline)
          .map((p) => LatLng(p[0].toDouble(), p[1].toDouble()))
          .toList();
      if (pts.length < 2) return;
      final bounds = LatLngBounds.fromPoints(pts);
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(50)),
      );
    } catch (_) {}
  }

  void _onSegmentTapped(TimelineSegment segment) {
    if (segment.isVisit) {
      setState(() => _selectedVisitPlaceId = segment.placeId);
      if (segment.placeLat != null && segment.placeLon != null) {
        _animatedMove(
          LatLng(segment.placeLat!, segment.placeLon!),
          math.max(_currentZoom, 15.0),
        );
      }
    } else if (segment.isActivity) {
      // If matched to a run, fly to the run's polyline bounds.
      if (segment.matchedRunId != null) {
        final run = _dayViewData?.runs
            .where((r) => r.id == segment.matchedRunId)
            .firstOrNull;
        if (run != null) {
          _onRunTapped(run);
          return;
        }
      }
      // Otherwise fly to the activity start location.
      if (segment.startLat != null && segment.startLon != null) {
        _animatedMove(
          LatLng(segment.startLat!, segment.startLon!),
          math.max(_currentZoom, 13.0),
        );
      }
    }
  }

  Map<String, String> _authHeaders() {
    final tokenStore = ref.read(authTokenStoreProvider);
    final token =
        ref.read(authControllerProvider).value?.accessToken ??
        tokenStore.peekToken();
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      'X-Blue-Client': 'mobile',
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

class _DayBottomSheet extends StatelessWidget {
  const _DayBottomSheet({
    required this.dates,
    required this.currentIndex,
    required this.onDateChanged,
    required this.data,
    required this.onVisitTapped,
    required this.onSegmentTapped,
    required this.sheetController,
    required this.authHeaders,
    required this.runColors,
    required this.onRunTapped,
    this.selectedVisitPlaceId,
  });

  final List<String> dates;
  final int currentIndex;
  final ValueChanged<double> onDateChanged;
  final TimelineDayData? data;
  final void Function(TimelineVisit visit) onVisitTapped;
  final void Function(TimelineSegment segment) onSegmentTapped;
  final void Function(TimelineRun run) onRunTapped;
  final String? selectedVisitPlaceId;
  final DraggableScrollableController sheetController;
  final Map<String, String> authHeaders;
  final Map<String, Color> runColors;

  static const double _collapsedHeight = 120;
  /// Max photos to show inline per visit. Remaining are aggregated.
  static const int _maxInlinePhotos = 4;

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final minFraction = (_collapsedHeight / screenHeight).clamp(0.08, 0.25);
    final rawSegments = data?.segments ?? const [];
    final images = data?.imageLocations ?? const [];
    final runs = data?.runs ?? const [];

    // Build run lookup by ID.
    final runById = <String, TimelineRun>{};
    for (final r in runs) {
      runById[r.id] = r;
    }

    // --- Aggregate consecutive same-type segments ---
    final segments = <TimelineSegment>[];
    for (final seg in rawSegments) {
      if (segments.isNotEmpty) {
        final prev = segments.last;
        // Aggregate consecutive same-type activities.
        if (seg.isActivity &&
            prev.isActivity &&
            _activityGroupKey(prev.activityType) ==
                _activityGroupKey(seg.activityType)) {
          segments.removeLast();
          segments.add(TimelineSegment(
            segmentType: prev.segmentType,
            startTime: prev.startTime,
            endTime: seg.endTime ?? prev.endTime,
            durationMinutes: prev.durationMinutes + seg.durationMinutes,
            activityType: prev.activityType,
            distanceMeters:
                (prev.distanceMeters ?? 0) + (seg.distanceMeters ?? 0),
            startLat: prev.startLat,
            startLon: prev.startLon,
            endLat: seg.endLat ?? prev.endLat,
            endLon: seg.endLon ?? prev.endLon,
            matchedRunId: prev.matchedRunId ?? seg.matchedRunId,
          ));
          continue;
        }
        // Aggregate consecutive visits to the same place.
        if (seg.isVisit &&
            prev.isVisit &&
            seg.placeId != null &&
            (seg.placeId == prev.placeId ||
                (seg.placeName != null &&
                    seg.placeName == prev.placeName &&
                    seg.placeAddress == prev.placeAddress))) {
          segments.removeLast();
          segments.add(TimelineSegment(
            segmentType: prev.segmentType,
            startTime: prev.startTime,
            endTime: seg.endTime ?? prev.endTime,
            durationMinutes: prev.durationMinutes + seg.durationMinutes,
            placeId: prev.placeId,
            placeName: prev.placeName ?? seg.placeName,
            placeAddress: prev.placeAddress ?? seg.placeAddress,
            placeLat: prev.placeLat ?? seg.placeLat,
            placeLon: prev.placeLon ?? seg.placeLon,
          ));
          continue;
        }
      }
      segments.add(seg);
    }

    // --- Build a unified timeline: segments + standalone run entries ---
    // Collect run IDs already referenced by segments.
    final usedRunIds = <String>{};
    for (final seg in segments) {
      if (seg.matchedRunId != null) usedRunIds.add(seg.matchedRunId!);
    }

    // Timeline entries: each is either a segment or a standalone run.
    final entries = <({TimelineSegment? seg, TimelineRun? run})>[];
    // Merge segments and unmatched runs by time.
    final unmatchedRuns = runs
        .where((r) => !usedRunIds.contains(r.id) && r.startTime != null)
        .toList()
      ..sort((a, b) => a.startTime!.compareTo(b.startTime!));
    var runIdx = 0;
    for (final seg in segments) {
      // Insert any unmatched runs that come before this segment.
      while (runIdx < unmatchedRuns.length &&
          unmatchedRuns[runIdx].startTime!.isBefore(seg.startTime)) {
        entries.add((seg: null, run: unmatchedRuns[runIdx]));
        runIdx++;
      }
      entries.add((seg: seg, run: null));
    }
    // Remaining unmatched runs after all segments.
    while (runIdx < unmatchedRuns.length) {
      entries.add((seg: null, run: unmatchedRuns[runIdx]));
      runIdx++;
    }

    // Assign images to nearest visit segment by lat/lon proximity.
    final imagesByEntryIndex = <int, List<TimelineImageLocation>>{};
    final unassignedImages = <TimelineImageLocation>[];
    for (final img in images) {
      int? bestIdx;
      double bestDist = 0.005; // ~500m threshold in degrees²
      for (var i = 0; i < entries.length; i++) {
        final seg = entries[i].seg;
        if (seg == null || !seg.isVisit || seg.placeLat == null || seg.placeLon == null) {
          continue;
        }
        final d = _coordDist(img.lat, img.lon, seg.placeLat!, seg.placeLon!);
        if (d < bestDist) {
          bestDist = d;
          bestIdx = i;
        }
      }
      if (bestIdx != null) {
        (imagesByEntryIndex[bestIdx] ??= []).add(img);
      } else {
        unassignedImages.add(img);
      }
    }

    final hasTimeline = entries.isNotEmpty || unassignedImages.isNotEmpty;

    return DraggableScrollableSheet(
      controller: sheetController,
      initialChildSize: minFraction,
      minChildSize: minFraction,
      maxChildSize: 0.65,
      snap: true,
      snapSizes: [minFraction, 0.65],
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xF0222222),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.zero,
            children: [
              // Drag handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 4),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Date slider
              _buildSlider(context),
              // Timeline
              if (hasTimeline)
                const Divider(
                  color: Colors.white12,
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                ),
              if (entries.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'TIMELINE',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              for (var i = 0; i < entries.length; i++) ...[
                if (entries[i].seg != null)
                  _buildSegmentTile(context, entries[i].seg!, runById)
                else
                  _buildRunEntryTile(context, entries[i].run!),
                if (imagesByEntryIndex.containsKey(i))
                  _buildImageStrip(context, imagesByEntryIndex[i]!),
              ],
              // Unassigned photos at the end
              if (unassignedImages.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    'PHOTOS',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                _buildImageStrip(context, unassignedImages),
              ],
              if (!hasTimeline)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'No location details for this day',
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  ),
                ),
              SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
            ],
          ),
        );
      },
    );
  }

  double _coordDist(double lat1, double lon1, double lat2, double lon2) {
    final dLat = lat1 - lat2;
    final dLon = lon1 - lon2;
    return dLat * dLat + dLon * dLon; // squared distance is fine for comparison
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _formatDuration(int minutes) {
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return hours > 0 ? '${hours}h ${mins}m' : '${mins}m';
  }

  Widget _buildSlider(BuildContext context) {
    final date = dates[currentIndex];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                dates.first,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              Text(
                date,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Text(
                'Today',
                style: TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
          Slider(
            value: currentIndex.toDouble(),
            min: 0,
            max: (dates.length - 1).toDouble(),
            divisions: dates.length - 1,
            onChanged: onDateChanged,
            activeColor: Colors.white,
            inactiveColor: Colors.white30,
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentTile(
    BuildContext context,
    TimelineSegment segment,
    Map<String, TimelineRun> runById,
  ) {
    if (segment.isVisit) {
      return _buildVisitSegmentTile(context, segment);
    } else {
      return _buildActivitySegmentTile(context, segment, runById);
    }
  }

  Widget _buildVisitSegmentTile(BuildContext context, TimelineSegment seg) {
    final isSelected = seg.placeId == selectedVisitPlaceId;
    final hasLocation = seg.placeLat != null && seg.placeLon != null;
    final displayName = seg.placeName ?? seg.placeId ?? 'Unknown';
    final timeLabel = _formatTime(seg.startTime);
    final durationLabel = _formatDuration(seg.durationMinutes);

    return GestureDetector(
      onTap: () => onSegmentTapped(seg),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0x336EB1FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Time column
            SizedBox(
              width: 42,
              child: Text(
                timeLabel,
                style: TextStyle(
                  color: isSelected
                      ? const Color(0xFF6EB1FF)
                      : Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            // Timeline dot
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF6EB1FF)
                      : hasLocation
                          ? const Color(0xCC6EB1FF)
                          : const Color(0x556EB1FF),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? Colors.white : Colors.white38,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      color: hasLocation ? Colors.white : Colors.white54,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (seg.placeAddress != null) ...[
                        Flexible(
                          child: Text(
                            seg.placeAddress!,
                            style: const TextStyle(
                              color: Colors.white30,
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Text(
                          '  ·  ',
                          style: TextStyle(color: Colors.white24, fontSize: 11),
                        ),
                      ],
                      Text(
                        durationLabel,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (hasLocation)
              Icon(
                Icons.chevron_right,
                size: 16,
                color: isSelected
                    ? const Color(0xFF6EB1FF)
                    : const Color(0x44FFFFFF),
              ),
          ],
        ),
      ),
    );
  }

  /// Canonical key for aggregation — groups equivalent types together.
  static String _activityGroupKey(String? type) {
    switch (type) {
      case 'IN_PASSENGER_VEHICLE':
      case 'IN_ROAD_VEHICLE':
      case 'IN_VEHICLE':
        return 'DRIVING';
      case 'WALKING':
      case 'ON_FOOT':
      case 'HIKING':
        return type == 'HIKING' ? 'HIKING' : 'WALKING';
      case 'ON_BICYCLE':
        return 'CYCLING';
      case 'IN_RAIL_VEHICLE':
        return 'IN_TRAIN';
      default:
        return type ?? 'UNKNOWN';
    }
  }

  static String _activityTypeLabel(String? type) {
    switch (type) {
      case 'IN_PASSENGER_VEHICLE':
      case 'IN_ROAD_VEHICLE':
      case 'IN_VEHICLE':
        return 'Driving';
      case 'WALKING':
      case 'ON_FOOT':
        return 'Walking';
      case 'HIKING':
        return 'Hiking';
      case 'IN_TRAIN':
      case 'IN_RAIL_VEHICLE':
        return 'Train';
      case 'IN_TRAM':
        return 'Tram';
      case 'IN_SUBWAY':
        return 'Subway';
      case 'IN_BUS':
        return 'Bus';
      case 'IN_FERRY':
        return 'Ferry';
      case 'IN_CABLECAR':
        return 'Cable car';
      case 'IN_FUNICULAR':
        return 'Funicular';
      case 'IN_GONDOLA_LIFT':
        return 'Gondola';
      case 'CYCLING':
      case 'ON_BICYCLE':
        return 'Cycling';
      case 'RUNNING':
        return 'Running';
      case 'MOTORCYCLING':
        return 'Motorcycle';
      case 'BOATING':
        return 'Boating';
      case 'SAILING':
        return 'Sailing';
      case 'FLYING':
        return 'Flying';
      case 'SKIING':
        return 'Skiing';
      case 'HORSEBACK_RIDING':
        return 'Horseback riding';
      case 'STILL':
        return 'Stationary';
      case 'EXITING_VEHICLE':
      case 'TILTING':
        return 'Transition';
      default:
        return 'Moving';
    }
  }

  static IconData _activityTypeIcon(String? type) {
    switch (type) {
      case 'IN_PASSENGER_VEHICLE':
      case 'IN_ROAD_VEHICLE':
      case 'IN_VEHICLE':
        return Icons.directions_car_outlined;
      case 'WALKING':
      case 'ON_FOOT':
        return Icons.directions_walk_outlined;
      case 'HIKING':
        return Icons.hiking_outlined;
      case 'IN_TRAIN':
      case 'IN_RAIL_VEHICLE':
        return Icons.train_outlined;
      case 'IN_TRAM':
        return Icons.tram_outlined;
      case 'IN_SUBWAY':
        return Icons.subway_outlined;
      case 'IN_BUS':
        return Icons.directions_bus_outlined;
      case 'IN_FERRY':
      case 'BOATING':
      case 'SAILING':
        return Icons.directions_boat_outlined;
      case 'IN_CABLECAR':
      case 'IN_FUNICULAR':
      case 'IN_GONDOLA_LIFT':
        return Icons.airline_seat_legroom_extra_outlined;
      case 'CYCLING':
      case 'ON_BICYCLE':
        return Icons.directions_bike_outlined;
      case 'RUNNING':
        return Icons.directions_run_outlined;
      case 'MOTORCYCLING':
        return Icons.two_wheeler_outlined;
      case 'FLYING':
        return Icons.flight_outlined;
      case 'SKIING':
        return Icons.downhill_skiing_outlined;
      case 'HORSEBACK_RIDING':
        return Icons.pets_outlined;
      case 'STILL':
        return Icons.pause_circle_outline;
      case 'EXITING_VEHICLE':
      case 'TILTING':
        return Icons.swap_horiz;
      default:
        return Icons.moving_outlined;
    }
  }


  Widget _buildActivitySegmentTile(
    BuildContext context,
    TimelineSegment seg,
    Map<String, TimelineRun> runById,
  ) {
    final run = seg.matchedRunId != null ? runById[seg.matchedRunId] : null;
    final timeLabel = _formatTime(seg.startTime);
    final hasLocation = seg.startLat != null && seg.startLon != null;

    final isRunning = seg.activityType == 'RUNNING';
    final activityColor = isRunning
        ? const Color(0xCCF79C70)
        : const Color(0xCCBDBDBD);
    final activityIcon = _activityTypeIcon(seg.activityType);
    // For running: prefer the Strava run name if matched.
    final typeLabel = isRunning && run != null && run.name.isNotEmpty
        ? run.name
        : _activityTypeLabel(seg.activityType);

    // Build subtitle parts
    final subtitleParts = <String>[];
    if (seg.durationMinutes > 0) {
      subtitleParts.add(_formatDuration(seg.durationMinutes));
    }
    if (seg.distanceMeters != null && seg.distanceMeters! > 0) {
      final km = seg.distanceMeters! / 1000;
      subtitleParts.add(
        km >= 1 ? '${km.toStringAsFixed(1)} km' : '${seg.distanceMeters} m',
      );
    }

    return GestureDetector(
      onTap: () => onSegmentTapped(seg),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Time column
            SizedBox(
              width: 42,
              child: Text(
                timeLabel,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            // Timeline dot with activity icon
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: activityColor.withValues(alpha: 0.25),
                shape: BoxShape.circle,
                border: Border.all(color: activityColor, width: 1.5),
              ),
              child: Icon(activityIcon, size: 12, color: activityColor),
            ),
            const SizedBox(width: 8),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    typeLabel,
                    style: TextStyle(
                      color: activityColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitleParts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitleParts.join('  ·  '),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (hasLocation)
              const Icon(
                Icons.chevron_right,
                size: 16,
                color: Color(0x44FFFFFF),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunEntryTile(BuildContext context, TimelineRun run) {
    final color = runColors[run.id] ?? const Color(0xCCF79C70);
    final timeLabel = run.startTime != null ? _formatTime(run.startTime!) : '';

    final subtitleParts = <String>[];
    if (run.distanceMeters != null && run.distanceMeters! > 0) {
      final km = run.distanceMeters! / 1000;
      subtitleParts.add(
        km >= 1 ? '${km.toStringAsFixed(1)} km' : '${run.distanceMeters} m',
      );
    }
    if (run.movingTimeSeconds != null && run.movingTimeSeconds! > 0) {
      final mins = run.movingTimeSeconds! ~/ 60;
      subtitleParts.add(_formatDuration(mins));
    }

    return GestureDetector(
      onTap: () => onRunTapped(run),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Time column
            SizedBox(
              width: 42,
              child: Text(
                timeLabel,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            // Run icon circle in run color
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.25),
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1.5),
              ),
              child: Icon(Icons.directions_run, size: 12, color: color),
            ),
            const SizedBox(width: 8),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    run.name.isNotEmpty ? run.name : 'Run',
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                ),
                if (subtitleParts.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitleParts.join('  ·  '),
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (run.summaryPolyline.isNotEmpty)
            Icon(
              Icons.chevron_right,
              size: 16,
              color: color.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageStrip(
    BuildContext context,
    List<TimelineImageLocation> imgs,
  ) {
    final showCount = imgs.length > _maxInlinePhotos ? _maxInlinePhotos : imgs.length;
    final remaining = imgs.length - showCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(62, 2, 16, 6),
      child: SizedBox(
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: showCount + (remaining > 0 ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (context, index) {
            if (index >= showCount) {
              // "+N more" badge
              return Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  '+$remaining',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }
            return ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: imgs[index].path,
                httpHeaders: authHeaders,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  width: 56,
                  height: 56,
                  color: const Color(0x22FFFFFF),
                ),
                errorWidget: (_, __, ___) => Container(
                  width: 56,
                  height: 56,
                  color: const Color(0x22FFFFFF),
                  child: const Icon(
                    Icons.image_not_supported_outlined,
                    size: 16,
                    color: Colors.white30,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
