// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_polyline_algorithm/google_polyline_algorithm.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config/app_config.dart';
import '../../core/widgets/calendar_event_detail_sheet.dart';
import '../../core/widgets/fullscreen_image_viewer.dart';
import '../../core/widgets/protected_network_image.dart';
import '../../core/utils/date_format.dart';
import '../../data/models/person_model.dart';
import '../../data/models/run_model.dart';
import '../../data/repositories/map_repository.dart';
import '../../providers.dart';
import '../persons/person_detail_page.dart';
import '../runs/run_detail_page.dart';

enum _MapStyle { light, dark, normal }

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

class _ImageClusterOverlay {
  const _ImageClusterOverlay({required this.cluster, required this.position});

  final MapImageCluster cluster;
  final LatLng position;
}

class MapPage extends ConsumerStatefulWidget {
  const MapPage({super.key});

  @override
  ConsumerState<MapPage> createState() => _MapPageState();
}

class _MapPageState extends ConsumerState<MapPage>
    with TickerProviderStateMixin {
  static const int _mapTabIndex = 3;
  static const int _mapMarkerPageSize = 300;
  static const Duration _viewportDebounce = Duration(milliseconds: 250);
  static const Duration _dayViewLoadTimeout = Duration(seconds: 24);
  static const Duration _daySwitchMapTransitionDuration = Duration(
    milliseconds: 560,
  );
  static const double _viewportPadFactor = 0.2;
  static const double _minViewportLatPad = 0.01;
  static const double _minViewportLonPad = 0.01;
  static const double _sidePanelWidth = 400;
  static const double _wideBreakpoint = 840;
  static const double _webBottomPanelMinHeight = 280;
  static const double _webBottomPanelMaxHeight = 420;
  static const int _maxDayWalkRenderPoints = 3000;
  static const int _maxDayFitPoints = 4200;
  static const int _maxDayImageMarkers = 240;
  static const _emptyTextKey = Key('map-empty-text');

  final MapController _mapController = MapController();
  final Map<String, _ImageOverlay> _imagePointCache = <String, _ImageOverlay>{};
  final Map<String, _ImageClusterOverlay> _imageClusterCache =
      <String, _ImageClusterOverlay>{};
  late final ProviderSubscription<int> _selectedTabSubscription;
  late final ProviderSubscription<DateTime> _selectedDateSubscription;
  String? _pendingDayViewDate;

  Timer? _viewportDebounceTimer;

  List<_RunOverlay> _allRuns = const [];
  List<_RunOverlay> _runs = const [];
  List<LatLng> _timelineOverviewPoints = const [];
  bool _runsLoading = true;
  bool _imagesLoading = false;
  bool _timelineOverviewLoading = false;
  bool _timelineOverviewLoadedOnce = false;
  String _error = '';
  String _timelineOverviewError = '';
  int _imageSearchGeneration = 0;
  double _currentZoom = 2.2;
  LatLngBounds? _currentBounds;
  bool _mapReady = false;
  bool _overviewFittedOnce = false;
  bool _isVisibleTab = false;
  bool _hasStartedLoad = false;
  _MapStyle _mapStyle = _MapStyle.light;
  bool _showPhotos = true;
  bool _showRuns = true;
  bool _showTimelineHistory = false;
  final bool _differentRouteColors = false;

  // Day-view state
  bool _dayViewMode = false;
  String _dayViewDate = '';
  bool _dayViewLoading = false;
  String _dayViewError = '';
  TimelineDayData? _dayViewData;
  int _dayViewRequestToken = 0;
  // All dates with run data, used to build the slider
  List<String> _dayViewDates = const [];
  int _dayViewDateIndex = 0;
  String? _selectedVisitPlaceId;
  String? _selectedRunId;
  bool? _wasWideLayout;
  final Map<String, List<LatLng>> _decodedPolylineCache =
      <String, List<LatLng>>{};
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  AnimationController? _daySwitchMapAnimation;
  final Map<String, GlobalKey> _visitTimelineKeys = <String, GlobalKey>{};
  final Map<String, GlobalKey> _runTimelineKeys = <String, GlobalKey>{};

  // Year range filter
  int _dataYearMin = DateTime.now().year;
  int _dataYearMax = DateTime.now().year;
  RangeValues? _yearRange; // null = all years (default)

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
        _scheduleViewportRefresh();
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
    _sheetController.addListener(_onSheetChanged);
    if (_isVisibleTab) {
      _load();
    } else {
      _runsLoading = false;
    }
  }

  @override
  void dispose() {
    _daySwitchMapAnimation?.dispose();
    _viewportDebounceTimer?.cancel();
    _selectedTabSubscription.close();
    _selectedDateSubscription.close();
    _sheetController.removeListener(_onSheetChanged);
    _sheetController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _hasStartedLoad = true;
    _viewportDebounceTimer?.cancel();
    _imageSearchGeneration += 1;

    setState(() {
      _runsLoading = true;
      _imagesLoading = false;
      _error = '';
      _timelineOverviewError = '';
      _timelineOverviewLoadedOnce = false;
      _imagePointCache.clear();
      _imageClusterCache.clear();
      _overviewFittedOnce = false;
    });

    await _loadRuns(ref.read(mapRepositoryProvider));
    _scheduleViewportRefresh();
  }

  List<_RunOverlay> _filterRunsByYear(List<_RunOverlay> overlays) {
    final range = _yearRange;
    if (range == null) return overlays;
    final fromY = range.start.round();
    final toY = range.end.round();
    return overlays.where((o) {
      final date = o.run.startDateLocal;
      if (date.length < 4) return true;
      final y = int.tryParse(date.substring(0, 4));
      return y == null || (y >= fromY && y <= toY);
    }).toList();
  }

  String? _yearRangeDateFrom() {
    final range = _yearRange;
    if (range == null) return null;
    return '${range.start.round()}-01-01';
  }

  String? _yearRangeDateTo() {
    final range = _yearRange;
    if (range == null) return null;
    return '${range.end.round()}-12-31';
  }

  void _onYearRangeChanged(RangeValues values) {
    setState(() {
      // If full range selected, treat as "all"
      if (values.start.round() <= _dataYearMin && values.end.round() >= _dataYearMax) {
        _yearRange = null;
      } else {
        _yearRange = values;
      }
      _runs = _filterRunsByYear(_allRuns);
      // Reset so timeline reloads with new date range
      if (_showTimelineHistory) _timelineOverviewLoadedOnce = false;
    });
    _scheduleViewportRefresh();
    if (_showTimelineHistory) {
      unawaited(_ensureTimelineOverviewLoaded(forceRefresh: true));
    }
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
              color: const Color(0xFFFF9800),
            ),
          );
        } catch (_) {
          // Skip invalid polylines without failing the entire page.
        }
      }
      // Compute year range from run dates
      int minY = DateTime.now().year;
      int maxY = minY;
      for (final o in overlays) {
        final date = o.run.startDateLocal;
        if (date.length >= 4) {
          final y = int.tryParse(date.substring(0, 4));
          if (y != null) {
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _allRuns = overlays;
        _dataYearMin = minY;
        _dataYearMax = maxY;
        _runs = _filterRunsByYear(overlays);
        _runsLoading = false;
      });
      _fitOverviewBoundsIfNeeded();
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
    if (!nextZoom.isFinite || !_isFiniteBounds(nextBounds)) {
      return;
    }
    final zoomChanged = (nextZoom - _currentZoom).abs() > 0.01;
    final boundsChanged = !_boundsCloseEnough(_currentBounds, nextBounds);
    if (!zoomChanged && !boundsChanged) return;

    if (mounted) {
      setState(() {
        _currentZoom = nextZoom;
        _currentBounds = nextBounds;
        _mapReady = true;
      });
    }
    _scheduleViewportRefresh();
    if (_showTimelineHistory &&
        !_timelineOverviewLoadedOnce &&
        !_timelineOverviewLoading) {
      unawaited(_ensureTimelineOverviewLoaded());
    }
  }

  void _onMapReady() {
    if (!mounted) return;
    final camera = _mapController.camera;
    if (!camera.zoom.isFinite || !_isFiniteBounds(camera.visibleBounds)) {
      return;
    }
    setState(() {
      _currentZoom = camera.zoom;
      _currentBounds = camera.visibleBounds;
      _mapReady = true;
    });
    _scheduleViewportRefresh();
    if (_showTimelineHistory &&
        !_timelineOverviewLoadedOnce &&
        !_timelineOverviewLoading) {
      unawaited(_ensureTimelineOverviewLoaded());
    }
  }

  void _scheduleViewportRefresh() {
    if (!_isVisibleTab || !_mapReady || _dayViewMode) return;
    _viewportDebounceTimer?.cancel();
    _viewportDebounceTimer = Timer(_viewportDebounce, () {
      if (!mounted) return;
      _imageSearchGeneration += 1;
      _refreshVisibleMapData(_imageSearchGeneration);
    });
  }

  void _stopImageSearch() {
    _imageSearchGeneration += 1;
    if (_imagesLoading && mounted) {
      setState(() => _imagesLoading = false);
    }
  }

  Future<void> _refreshVisibleMapData(int generation) async {
    if (!_isVisibleTab || _dayViewMode || !_showPhotos) {
      if (mounted && _imagesLoading) {
        setState(() => _imagesLoading = false);
      }
      return;
    }
    final bounds = _expandedBounds();
    if (bounds == null) return;

    setState(() {
      _imagesLoading = true;
      _error = '';
    });
    try {
      final result = await ref
          .read(mapRepositoryProvider)
          .loadMapMarkers(
            bounds: bounds,
            zoom: _currentZoom,
            first: _mapMarkerPageSize,
            dateFrom: _yearRangeDateFrom(),
            dateTo: _yearRangeDateTo(),
          );
      if (!mounted || generation != _imageSearchGeneration) return;

      final nextPoints = <String, _ImageOverlay>{};
      for (final point in result.points) {
        nextPoints[point.sourcePath] = _ImageOverlay(
          point: point,
          position: LatLng(point.lat, point.lon),
        );
      }
      final nextClusters = <String, _ImageClusterOverlay>{};
      for (final cluster in result.clusters) {
        final key = [
          cluster.previewPath ?? '',
          cluster.count,
          cluster.lat.toStringAsFixed(5),
          cluster.lon.toStringAsFixed(5),
        ].join('|');
        nextClusters[key] = _ImageClusterOverlay(
          cluster: cluster,
          position: LatLng(cluster.lat, cluster.lon),
        );
      }
      setState(() {
        _imagePointCache
          ..clear()
          ..addAll(nextPoints);
        _imageClusterCache
          ..clear()
          ..addAll(nextClusters);
        _imagesLoading = false;
      });
      _fitOverviewBoundsIfNeeded();
    } catch (error, stackTrace) {
      debugPrint('[MAP] overview marker load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted || generation != _imageSearchGeneration) return;
      setState(() {
        _imagesLoading = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  List<_ImageOverlay> _visibleImages() {
    final bounds = _expandedBounds();
    if (bounds == null || _imagePointCache.isEmpty) return const [];

    final candidates =
        _imagePointCache.values
            .where((image) => bounds.contains(image.position))
            .toList()
          ..sort((a, b) => b.point.date.compareTo(a.point.date));

    final cap = _maxVisibleImageMarkers();
    if (candidates.length > cap) {
      return candidates.take(cap).toList();
    }
    return candidates;
  }

  List<_ImageClusterOverlay> _visibleClusters() {
    final bounds = _expandedBounds();
    if (bounds == null || _imageClusterCache.isEmpty) return const [];
    return _imageClusterCache.values
        .where((cluster) => bounds.contains(cluster.position))
        .toList();
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
    final latPad = ((north - south).abs() * _viewportPadFactor).clamp(
      _minViewportLatPad,
      30,
    );
    final lonPad = ((east - west).abs() * _viewportPadFactor).clamp(
      _minViewportLonPad,
      40,
    );

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

  int _maxVisibleImageMarkers() {
    if (_currentZoom < 7) return 0;
    if (_currentZoom < 9) return 120;
    return 120;
  }

  double _timelineStrokeWidth() {
    if (_currentZoom < 3) return 1.0;
    if (_currentZoom < 5) return 1.5;
    if (_currentZoom < 7) return 2.1;
    return 2.5;
  }

  double _runStrokeWidth() {
    if (_currentZoom < 3) return 1.25;
    if (_currentZoom < 5) return 1.8;
    if (_currentZoom < 7) return 2.2;
    return 2.8;
  }

  void _fitOverviewBoundsIfNeeded() {
    if (!_mapReady || _dayViewMode || _overviewFittedOnce) return;
    final target = _overviewCameraTarget();
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dayViewMode) return;
      _overviewFittedOnce = true;
      _mapController.move(target.center, target.zoom);
    });
  }

  Future<void> _ensureTimelineOverviewLoaded({bool forceRefresh = false}) async {
    if (!forceRefresh && (_timelineOverviewLoadedOnce || _timelineOverviewLoading)) return;
    setState(() {
      _timelineOverviewLoading = true;
      _timelineOverviewError = '';
    });
    try {
      final points = await ref
          .read(mapRepositoryProvider)
          .loadTimelineOverview(
            forceRefresh: forceRefresh,
            dateFrom: _yearRangeDateFrom() ?? '1900-01-01',
            dateTo: _yearRangeDateTo() ?? '2100-12-31',
          );
      if (!mounted) return;
      setState(() {
        _timelineOverviewPoints = points;
        _timelineOverviewLoading = false;
        _timelineOverviewLoadedOnce = true;
      });
      _fitOverviewBoundsIfNeeded();
    } catch (error, stackTrace) {
      debugPrint('[MAP] overview timeline load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _timelineOverviewLoading = false;
        _timelineOverviewLoadedOnce = true;
        _timelineOverviewError = error.toString().replaceFirst(
          'Exception: ',
          '',
        );
      });
    }
  }

  ({LatLng center, double zoom})? _overviewCameraTarget() {
    final points = <LatLng>[
      if (_showTimelineHistory) ..._sampleLatLngs(_timelineOverviewPoints, 180),
      for (final run in _runs) ..._sampleLatLngs(run.points, 120),
      for (final image in _imagePointCache.values) image.position,
      for (final cluster in _imageClusterCache.values) cluster.position,
    ];
    if (points.isEmpty) return null;
    final cameraFit = CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(points),
      padding: const EdgeInsets.all(48),
      maxZoom: 8,
    );
    final fitted = cameraFit.fit(_mapController.camera);
    return (center: fitted.center, zoom: fitted.zoom);
  }

  @override
  Widget build(BuildContext context) {
    if (_dayViewMode) return _buildDayView(context);

    final tileConfig = AppConfig.mapTileConfig(_mapStyle.name);
    final center = _initialCenter();
    final showImages = _showPhotos;
    final showRuns = _showRuns;
    final showTimelineHistory = _showTimelineHistory;
    final visibleImages = showImages
        ? _visibleImages()
        : const <_ImageOverlay>[];
    final visibleClusters = showImages
        ? _visibleClusters()
        : const <_ImageClusterOverlay>[];
    final loading = _runsLoading || (showImages && _imagesLoading);
    final colorScheme = Theme.of(context).colorScheme;
    final routeColor = Colors.orangeAccent;
    final imageBorderColor = colorScheme.tertiary;
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
            if (showTimelineHistory && _timelineOverviewPoints.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _timelineOverviewPoints,
                    strokeWidth: _timelineStrokeWidth(),
                    color: const Color(0xFF4A90D9).withValues(alpha: 0.55),
                  ),
                ],
              ),
            if (showRuns)
              PolylineLayer(
                polylines: _runs
                    .map(
                      (run) => Polyline(
                        points: run.points,
                        strokeWidth: _runStrokeWidth(),
                        color: (_differentRouteColors ? run.color : routeColor)
                            .withValues(alpha: showImages ? 0.38 : 0.88),
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
                markers: visibleClusters
                    .map(
                      (cluster) => Marker(
                        point: cluster.position,
                        width: 34,
                        height: 34,
                        child: GestureDetector(
                          onTap: () => _zoomToCluster(cluster),
                          child: _buildClusterMarker(
                            cluster,
                            borderColor: imageBorderColor,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            if (showImages)
              MarkerLayer(
                markers: visibleImages
                    .take(120)
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

        if (!loading &&
            _error.isEmpty &&
            visibleClusters.isEmpty &&
            visibleImages.isEmpty &&
            _runs.isEmpty &&
            _timelineOverviewPoints.isEmpty)
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
        // Bottom bar: year range slider + day-view button
        if (!_runsLoading)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomBar(context),
          ),
      ],
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasRange = _dataYearMin < _dataYearMax;
    final minY = _dataYearMin.toDouble();
    final maxY = _dataYearMax.toDouble();
    final current = _yearRange ?? RangeValues(minY, maxY);
    final startLabel = current.start.round().toString();
    final endLabel = current.end.round().toString();
    final canEnterDayView = _runs.isNotEmpty;

    void enterDayView() {
      final today = DateUtils.dateOnly(DateTime.now());
      final todayStr =
          '${today.year.toString().padLeft(4, '0')}-'
          '${today.month.toString().padLeft(2, '0')}-'
          '${today.day.toString().padLeft(2, '0')}';
      _enterDayView(todayStr);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          if (hasRange) ...[
            const SizedBox(width: 4),
            Text(
              startLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
            Expanded(
              child: RangeSlider(
                values: current,
                min: minY,
                max: maxY,
                divisions: (maxY - minY).round(),
                onChanged: _onYearRangeChanged,
              ),
            ),
            Text(
              endLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ] else
            const Spacer(),
          const SizedBox(width: 8),
          VerticalDivider(width: 1, thickness: 1, indent: 8, endIndent: 8, color: colorScheme.outlineVariant),
          const SizedBox(width: 10),
          // Day-view pill button
          Tooltip(
            message: 'Day view',
            child: Material(
              color: canEnterDayView
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: canEnterDayView ? enterDayView : null,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(
                    Icons.calendar_view_day_rounded,
                    size: 20,
                    color: canEnterDayView
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  Widget _buildDayView(BuildContext context) {
    final tileConfig = AppConfig.mapTileConfig(_mapStyle.name);
    final data = _dayViewData;
    final dayColorScheme = Theme.of(context).colorScheme;
    final walkColor = const Color(0xFF4CAF50);
    final imageBorderColor = dayColorScheme.tertiary;

    // Walk points come directly as LatLng list from the repository
    final walkPoints = data != null
        ? _sampleLatLngs(
            data.walkPoints.map((p) => LatLng(p.lat, p.lon)).toList(),
            _maxDayWalkRenderPoints,
          )
        : const <LatLng>[];

    // Decode run polylines
    final runPolylines = <Polyline>[];
    final runMarkers = <Marker>[];
    if (data != null) {
      for (final run in data.runs) {
        final pts = _decodePolylinePoints(run.id, run.summaryPolyline);
        if (pts.length < 2) continue;
        final color = const Color(0xFFFF9800);
        runPolylines.add(Polyline(points: pts, strokeWidth: 3, color: color));
        runMarkers.add(
          Marker(
            point: pts.first,
            width: 28,
            height: 28,
            child: GestureDetector(
              onTap: () => _onRunMarkerTapped(run),
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
      }
    }

    // Image markers
    final imageMarkers = <Marker>[];
    if (data != null) {
      for (final img in _sampleItems(
        data.imageLocations,
        _maxDayImageMarkers,
      )) {
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
                  color: dayColorScheme.primary.withValues(alpha: 0.88),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white,
                    width: isSelected ? 2.5 : 1.0,
                  ),
                  boxShadow: [
                    if (isSelected)
                      BoxShadow(
                        blurRadius: 8,
                        spreadRadius: 1,
                        color: dayColorScheme.primary.withValues(alpha: 0.33),
                      )
                    else
                      const BoxShadow(blurRadius: 6, color: Color(0x33000000)),
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

    final sheetParams = (
      dates: _dayViewDates,
      currentIndex: _dayViewDateIndex,
      currentDate: _dayViewDate,
      onPreviousDate: _goToPreviousDay,
      onNextDate: _goToNextDay,
      data: data,
      onVisitTapped: _onBottomSheetVisitTapped,
      onSegmentTapped: _onSegmentTapped,
      onCalendarEventTapped: _onCalendarEventTapped,
      onRunTapped: _onRunTapped,
      onImageTapped: (List<TimelineImageLocation> imgs, int index) =>
          _showDayImageViewer(imgs, date: _dayViewDate, initialIndex: index),
      selectedVisitPlaceId: _selectedVisitPlaceId,
      selectedRunId: _selectedRunId,
      isLoading: _dayViewLoading,
      errorText: _dayViewError,
      authHeaders: _authHeaders(),
      authenticateUrl: _authenticatedUrl,
      visitKeyForPlaceId: _visitTimelineKey,
      runKeyForRunId: _runTimelineKey,
      runColors: {
        for (final r in data?.runs ?? <TimelineRun>[])
          r.id: const Color(0xFFFF9800),
      },
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _wideBreakpoint;

        // Refit map bounds when crossing the layout breakpoint.
        if (_wasWideLayout != null && _wasWideLayout != isWide) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_dayViewMode) return;
            final d = _dayViewData;
            if (d != null) _fitDayViewBounds(d);
          });
        }
        _wasWideLayout = isWide;

        return Stack(
          children: [
            // Map: leaves room for side panel on wide layout
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: isWide ? _sidePanelWidth : 0,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _initialCenter(),
                  initialZoom: _currentZoom,
                  onMapReady: _onMapReady,
                  onPositionChanged: (camera, _) =>
                      _handleCameraChanged(camera),
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
                  if (runPolylines.isNotEmpty)
                    PolylineLayer(polylines: runPolylines),
                  if (runMarkers.isNotEmpty) MarkerLayer(markers: runMarkers),
                  if (imageMarkers.isNotEmpty)
                    MarkerLayer(markers: imageMarkers),
                  if (visitMarkers.isNotEmpty)
                    MarkerLayer(markers: visitMarkers),
                ],
              ),
            ),
            // Top bar: back button
            Positioned(
              top: 16,
              left: 16,
              right: isWide ? _sidePanelWidth + 16 : 84,
              child: Row(
                children: [
                  Material(
                    color: const Color(0xE01C1C1E),
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: _exitDayView,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.arrow_back,
                              color: Colors.white,
                              size: 18,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Overview',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Timeline: bottom sheet on narrow, side panel on wide
            if (!isWide && _dayViewDates.isNotEmpty)
              Positioned.fill(
                child: _DayBottomSheet(
                  dates: sheetParams.dates,
                  currentIndex: sheetParams.currentIndex,
                  currentDate: sheetParams.currentDate,
                  onPreviousDate: sheetParams.onPreviousDate,
                  onNextDate: sheetParams.onNextDate,
                  data: sheetParams.data,
                  onVisitTapped: sheetParams.onVisitTapped,
                  onSegmentTapped: sheetParams.onSegmentTapped,
                  onCalendarEventTapped: sheetParams.onCalendarEventTapped,
                  onRunTapped: sheetParams.onRunTapped,
                  onImageTapped: sheetParams.onImageTapped,
                  selectedVisitPlaceId: sheetParams.selectedVisitPlaceId,
                  selectedRunId: sheetParams.selectedRunId,
                  isLoading: sheetParams.isLoading,
                  errorText: sheetParams.errorText,
                  sheetController: _sheetController,
                  authHeaders: sheetParams.authHeaders,
                  authenticateUrl: sheetParams.authenticateUrl,
                  visitKeyForPlaceId: sheetParams.visitKeyForPlaceId,
                  runKeyForRunId: sheetParams.runKeyForRunId,
                  runColors: sheetParams.runColors,
                  onAddVisit: _showAddVisitDialog,
                  onDeleteSegment: _deleteManualVisit,
                  onDateTapped: _onDateTapped,
                ),
              ),
            if (isWide && _dayViewDates.isNotEmpty)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: _sidePanelWidth,
                child: _DayBottomSheet(
                  isWideLayout: true,
                  dates: sheetParams.dates,
                  currentIndex: sheetParams.currentIndex,
                  currentDate: sheetParams.currentDate,
                  onPreviousDate: sheetParams.onPreviousDate,
                  onNextDate: sheetParams.onNextDate,
                  data: sheetParams.data,
                  onVisitTapped: sheetParams.onVisitTapped,
                  onSegmentTapped: sheetParams.onSegmentTapped,
                  onCalendarEventTapped: sheetParams.onCalendarEventTapped,
                  onRunTapped: sheetParams.onRunTapped,
                  onImageTapped: sheetParams.onImageTapped,
                  selectedVisitPlaceId: sheetParams.selectedVisitPlaceId,
                  selectedRunId: sheetParams.selectedRunId,
                  isLoading: sheetParams.isLoading,
                  errorText: sheetParams.errorText,
                  authHeaders: sheetParams.authHeaders,
                  authenticateUrl: sheetParams.authenticateUrl,
                  visitKeyForPlaceId: sheetParams.visitKeyForPlaceId,
                  runKeyForRunId: sheetParams.runKeyForRunId,
                  runColors: sheetParams.runColors,
                  onAddVisit: _showAddVisitDialog,
                  onDeleteSegment: _deleteManualVisit,
                  onDateTapped: _onDateTapped,
                ),
              ),
            // Controls FAB
            Positioned(
              right: isWide ? _sidePanelWidth + 16 : 16,
              top: 16,
              child: FloatingActionButton.small(
                heroTag: 'map_controls',
                onPressed: _showControlsSheet,
                child: const Icon(Icons.tune),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showDayImageSheet(TimelineImageLocation img, String date) {
    return _showDayImageViewer([img], date: date);
  }

  Future<void> _showDayImageViewer(
    List<TimelineImageLocation> images, {
    required String date,
    int initialIndex = 0,
  }) {
    final repo = ref.read(filesRepositoryProvider);
    final facesRepo = ref.read(facesRepositoryProvider);
    final personRepo = ref.read(personRepositoryProvider);
    final items = images
        .map(
          (img) => ImageViewerItem(
            fullUrl: _authenticatedUrl(img.path),
            thumbnailUrl: _authenticatedUrl(img.path),
            fileName: img.sourcePath.split('/').last,
            path: img.sourcePath,
            date: date,
            gps: '${img.lat}, ${img.lon}',
          ),
        )
        .toList();
    return FullscreenImageViewer.show(
      context: context,
      images: items,
      initialIndex: initialIndex.clamp(0, items.length - 1),
      httpHeaders: _authHeaders(),
      fetchImageInfo: (path) => repo.getImageInfo(path),
      fetchImageFaces: (path) => facesRepo.getImageFaces(path),
      unlabelFace: (faceId) => facesRepo.unlabelFace(faceId),
      reassignFace: (faceId, personId, {isReference = false}) =>
          facesRepo.reassignFace(
            faceId,
            personId,
            isReference: isReference,
          ),
      personRepository: personRepo,
      onOpenPerson: _openPersonFromViewer,
    );
  }

  Widget _buildClusterMarker(
    _ImageClusterOverlay overlay, {
    required Color borderColor,
  }) {
    final countLabel = overlay.cluster.count > 99
        ? '99+'
        : overlay.cluster.count.toString();
    const markerSize = 34.0;
    final badge = Align(
      alignment: Alignment.bottomRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white, width: 1.2),
        ),
        child: Text(
          countLabel,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: markerSize,
          height: markerSize,
          decoration: BoxDecoration(
            color: borderColor.withValues(alpha: 0.95),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(blurRadius: 10, color: Color(0x33000000)),
            ],
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.photo_library, color: Colors.white, size: 16),
        ),
        badge,
      ],
    );
  }

  void _zoomToCluster(_ImageClusterOverlay cluster) {
    final latMin = cluster.cluster.latMin;
    final latMax = cluster.cluster.latMax;
    final lonMin = cluster.cluster.lonMin;
    final lonMax = cluster.cluster.lonMax;
    if (latMin != null && latMax != null && lonMin != null && lonMax != null) {
      final fitted = CameraFit.bounds(
        bounds: LatLngBounds(LatLng(latMin, lonMin), LatLng(latMax, lonMax)),
        padding: const EdgeInsets.all(56),
        maxZoom: 9,
      ).fit(_mapController.camera);
      _mapController.move(fitted.center, fitted.zoom);
      return;
    }
    _mapController.move(cluster.position, math.max(_currentZoom + 1.5, 7.0));
  }

  LatLng _initialCenter() {
    if (_imagePointCache.isNotEmpty) {
      return _imagePointCache.values.first.position;
    }
    if (_imageClusterCache.isNotEmpty) {
      return _imageClusterCache.values.first.position;
    }
    if (_runs.isNotEmpty) return _runs.first.points.first;
    return const LatLng(20, 0);
  }

  double _imageMarkerSizeForZoom(double zoom) {
    if (zoom <= 3) return 22;
    if (zoom <= 4) return 24;
    if (zoom <= 5) return 26;
    if (zoom <= 6) return 28;
    if (zoom <= 7) return 30;
    return 32;
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
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _showPhotos,
                    onChanged: (value) => update(() {
                      _showPhotos = value;
                      _scheduleViewportRefresh();
                    }),
                    title: const Text('Photos'),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _showRuns,
                    onChanged: (value) => update(() {
                      _showRuns = value;
                    }),
                    title: const Text('Runs'),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _showTimelineHistory,
                    onChanged: (value) {
                      update(() {
                        _showTimelineHistory = value;
                      });
                      if (value) {
                        unawaited(_ensureTimelineOverviewLoaded());
                      }
                    },
                    title: const Text('Timeline'),
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
    final repo = ref.read(filesRepositoryProvider);
    final facesRepo = ref.read(facesRepositoryProvider);
    final personRepo = ref.read(personRepositoryProvider);
    return FullscreenImageViewer.show(
      context: context,
      images: [
        ImageViewerItem(
          fullUrl: _authenticatedUrl(image.point.path),
          thumbnailUrl: _authenticatedUrl(image.point.path),
          fileName: image.point.sourcePath.split('/').last,
          path: image.point.sourcePath,
          date: image.point.date,
          gps: '${image.point.lat}, ${image.point.lon}',
        ),
      ],
      initialIndex: 0,
      httpHeaders: _authHeaders(),
      fetchImageInfo: (path) => repo.getImageInfo(path),
      fetchImageFaces: (path) => facesRepo.getImageFaces(path),
      unlabelFace: (faceId) => facesRepo.unlabelFace(faceId),
      reassignFace: (faceId, personId, {isReference = false}) =>
          facesRepo.reassignFace(
            faceId,
            personId,
            isReference: isReference,
          ),
      personRepository: personRepo,
      onOpenPerson: _openPersonFromViewer,
    );
  }

  Future<void> _openPersonFromViewer(PersonModel person) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PersonDetailPage(person: person),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _showRunSheet(_RunOverlay runOverlay) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: BoxConstraints.tightFor(
        width: MediaQuery.of(context).size.width,
      ),
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
                    child: ProtectedNetworkImage(
                      imageUrl: _authenticatedUrl(
                        AppConfig.runImageUrl(run.id),
                      ),
                      headers: _authHeaders(),
                      height: 200,
                      fit: BoxFit.cover,
                      errorWidget: Container(
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
                          _openRunDetail(run);
                        },
                        child: const Text('Open run'),
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

  Future<void> _openRunDetail(RunModel run) async {
    final repo = ref.read(runsRepositoryProvider);
    final bundle = await repo.loadDetailBundle(run.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RunDetailPage(
          run: run,
          summary: bundle.summary,
          detail: bundle.detail,
        ),
      ),
    );
  }

  // ── Day-view ────────────────────────────────────────────────────────────────

  Future<void> _enterDayView(String date) async {
    _stopImageSearch();
    _viewportDebounceTimer?.cancel();
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
      _visitTimelineKeys.clear();
      _runTimelineKeys.clear();
    });
    await _loadDayView(date);
  }

  void _exitDayView() {
    _dayViewRequestToken += 1;
    setState(() {
      _dayViewMode = false;
      _dayViewData = null;
      _dayViewError = '';
      _dayViewLoading = false;
      _selectedVisitPlaceId = null;
      _selectedRunId = null;
    });
    _scheduleViewportRefresh();
  }

  Future<void> _loadDayView(String date) async {
    final requestToken = ++_dayViewRequestToken;
    setState(() {
      _dayViewLoading = true;
      _dayViewError = '';
      _dayViewDate = date;
      _selectedVisitPlaceId = null;
      _selectedRunId = null;
      _visitTimelineKeys.clear();
      _runTimelineKeys.clear();
    });
    try {
      final data = await ref
          .read(mapRepositoryProvider)
          .loadTimelineDay(date)
          .timeout(
            _dayViewLoadTimeout,
            onTimeout: () => throw TimeoutException(
              'Loading this day took too long. Please try again.',
            ),
          );
      if (!mounted || requestToken != _dayViewRequestToken) return;
      setState(() {
        _dayViewData = data;
        _dayViewLoading = false;
      });
      // Animate the camera when switching days so the map doesn't snap.
      _fitDayViewBounds(data, animated: true);
    } catch (error, stackTrace) {
      debugPrint('[DAY_VIEW] loadDayView failed date=$date error=$error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted || requestToken != _dayViewRequestToken) return;
      final message = error is TimeoutException
          ? (error.message ?? 'Loading this day took too long.')
          : error.toString().replaceFirst('Exception: ', '');
      setState(() {
        _dayViewLoading = false;
        _dayViewError = message;
      });
    }
  }

  void _fitDayViewBounds(TimelineDayData data, {bool animated = false}) {
    final points = <LatLng>[
      for (final img in data.imageLocations) LatLng(img.lat, img.lon),
      for (final v in data.visits)
        if (v.lat != null && v.lon != null) LatLng(v.lat!, v.lon!),
    ];
    points.addAll(data.walkPoints.map((p) => LatLng(p.lat, p.lon)));
    for (final run in data.runs) {
      points.addAll(_decodePolylinePoints(run.id, run.summaryPolyline));
    }
    final sampledPoints = _sampleLatLngs(points, _maxDayFitPoints);
    if (sampledPoints.isEmpty) return;
    final target = _dayViewCameraTarget(sampledPoints);
    if (target == null) return;
    if (animated) {
      _animateMapTo(center: target.center, zoom: target.zoom);
      return;
    }
    _stopDaySwitchMapAnimation();
    _mapController.move(target.center, target.zoom);
  }

  ({LatLng center, double zoom})? _dayViewCameraTarget(List<LatLng> points) {
    if (points.isEmpty) return null;
    final cameraFit = _cameraFitForDayViewPoints(points);
    final fittedCamera = cameraFit.fit(_mapController.camera);
    return (center: fittedCamera.center, zoom: fittedCamera.zoom);
  }

  CameraFit _cameraFitForDayViewPoints(List<LatLng> points) {
    if (points.length == 1) {
      const offset = 0.001;
      final target = points.first;
      return CameraFit.bounds(
        bounds: LatLngBounds(
          LatLng(target.latitude - offset, target.longitude - offset),
          LatLng(target.latitude + offset, target.longitude + offset),
        ),
        maxZoom: 16,
        padding: EdgeInsets.fromLTRB(
          40,
          40,
          40 + _panelRightPadding(),
          20 + _sheetBottomPadding(),
        ),
      );
    }

    final bounds = LatLngBounds.fromPoints(points);
    if (_isZeroAreaBounds(bounds)) {
      final target = points.first;
      return CameraFit.bounds(
        bounds: LatLngBounds(
          LatLng(target.latitude - 0.001, target.longitude - 0.001),
          LatLng(target.latitude + 0.001, target.longitude + 0.001),
        ),
        maxZoom: 16,
        padding: EdgeInsets.fromLTRB(
          40,
          40,
          40 + _panelRightPadding(),
          20 + _sheetBottomPadding(),
        ),
      );
    }

    return CameraFit.bounds(
      bounds: bounds,
      padding: EdgeInsets.fromLTRB(
        30,
        30,
        30 + _panelRightPadding(),
        30 + _sheetBottomPadding(),
      ),
    );
  }

  void _animateMapTo({required LatLng center, required double zoom}) {
    final startCamera = _mapController.camera;
    final startCenter = startCamera.center;
    final startZoom = startCamera.zoom;

    if ((startCenter.latitude - center.latitude).abs() < 0.000001 &&
        (startCenter.longitude - center.longitude).abs() < 0.000001 &&
        (startZoom - zoom).abs() < 0.001) {
      return;
    }

    _stopDaySwitchMapAnimation();

    final centerLatTween = Tween<double>(
      begin: startCenter.latitude,
      end: center.latitude,
    );
    final centerLonTween = Tween<double>(
      begin: startCenter.longitude,
      end: center.longitude,
    );
    final zoomTween = Tween<double>(begin: startZoom, end: zoom);

    final animation = AnimationController(
      vsync: this,
      duration: _daySwitchMapTransitionDuration,
    );
    _daySwitchMapAnimation = animation;

    void tick() {
      if (!mounted) return;
      final t = Curves.easeInOutCubic.transform(animation.value);
      _mapController.move(
        LatLng(centerLatTween.transform(t), centerLonTween.transform(t)),
        zoomTween.transform(t),
      );
    }

    animation.addListener(tick);
    animation.addStatusListener((status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      animation.removeListener(tick);
      if (identical(_daySwitchMapAnimation, animation)) {
        _daySwitchMapAnimation = null;
      }
      animation.dispose();
    });
    animation.forward();
  }

  void _stopDaySwitchMapAnimation() {
    final animation = _daySwitchMapAnimation;
    if (animation == null) return;
    _daySwitchMapAnimation = null;
    animation.stop();
    animation.dispose();
  }

  bool get _useWideLayout =>
      MediaQuery.of(context).size.width >= _wideBreakpoint;

  double _panelRightPadding() => _useWideLayout ? _sidePanelWidth : 0;

  double _sheetBottomPadding() {
    if (_useWideLayout) return 0;
    if (kIsWeb) {
      final screenHeight = MediaQuery.of(context).size.height;
      if (!screenHeight.isFinite || screenHeight <= 0) return 320;
      return (screenHeight * 0.42).clamp(
        _webBottomPanelMinHeight,
        _webBottomPanelMaxHeight,
      );
    }
    if (!_sheetController.isAttached) return 120;
    final extent = _sheetController.size;
    final screenHeight = MediaQuery.of(context).size.height;
    if (!extent.isFinite || extent <= 0) return 120;
    if (!screenHeight.isFinite || screenHeight <= 0) return 120;
    return screenHeight * extent * 0.8;
  }

  void _onSheetChanged() {
    // Intentionally empty — we don't refit bounds during drag.
    // Sheet padding is applied when the user taps a timeline item.
  }

  void _goToPreviousDay() {
    final current =
        DateTime.tryParse(_dayViewDate) ?? DateUtils.dateOnly(DateTime.now());
    final previous = DateUtils.addDaysToDate(current, -1);
    final dateStr =
        '${previous.year.toString().padLeft(4, '0')}-'
        '${previous.month.toString().padLeft(2, '0')}-'
        '${previous.day.toString().padLeft(2, '0')}';
    _enterDayView(dateStr);
  }

  void _goToNextDay() {
    final current =
        DateTime.tryParse(_dayViewDate) ?? DateUtils.dateOnly(DateTime.now());
    final today = DateUtils.dateOnly(DateTime.now());
    if (!current.isBefore(today)) return;
    final next = DateUtils.addDaysToDate(current, 1);
    final dateStr =
        '${next.year.toString().padLeft(4, '0')}-'
        '${next.month.toString().padLeft(2, '0')}-'
        '${next.day.toString().padLeft(2, '0')}';
    _enterDayView(dateStr);
  }

  List<LatLng> _decodePolylinePoints(String id, String polyline) {
    if (polyline.isEmpty) return const <LatLng>[];
    final cacheKey = '$id|$polyline';
    final cached = _decodedPolylineCache[cacheKey];
    if (cached != null) return cached;
    try {
      final decoded = decodePolyline(
        polyline,
      ).map((pair) => LatLng(pair[0].toDouble(), pair[1].toDouble())).toList();
      _decodedPolylineCache[cacheKey] = decoded;
      return decoded;
    } catch (_) {
      _decodedPolylineCache[cacheKey] = const <LatLng>[];
      return const <LatLng>[];
    }
  }

  List<LatLng> _sampleLatLngs(List<LatLng> points, int maxPoints) {
    if (points.length <= maxPoints) return points;
    final step = (points.length / maxPoints).ceil();
    final sampled = <LatLng>[];
    for (var i = 0; i < points.length; i += step) {
      sampled.add(points[i]);
    }
    if (sampled.last != points.last) {
      sampled.add(points.last);
    }
    return sampled;
  }

  List<T> _sampleItems<T>(List<T> items, int maxItems) {
    if (items.length <= maxItems) return items;
    final step = (items.length / maxItems).ceil();
    final sampled = <T>[];
    for (var i = 0; i < items.length; i += step) {
      sampled.add(items[i]);
    }
    if (sampled.last != items.last) {
      sampled.add(items.last);
    }
    return sampled;
  }

  Future<void> _onDateTapped() async {
    final current = DateTime.tryParse(_dayViewDate) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    final dateStr =
        '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    _enterDayView(dateStr);
  }

  /// Fly to a single point, keeping it visible above the sheet.
  void _flyToPoint(LatLng target) {
    final targetCamera = _dayViewCameraTarget([target]);
    if (targetCamera == null) return;
    _animateMapTo(center: targetCamera.center, zoom: targetCamera.zoom);
  }

  GlobalKey _visitTimelineKey(String placeId) {
    return _visitTimelineKeys.putIfAbsent(
      placeId,
      () => GlobalKey(debugLabel: 'visit-$placeId'),
    );
  }

  GlobalKey _runTimelineKey(String runId) {
    return _runTimelineKeys.putIfAbsent(
      runId,
      () => GlobalKey(debugLabel: 'run-$runId'),
    );
  }

  Future<void> _expandSheetForSelection() async {
    if (_useWideLayout || kIsWeb || !_sheetController.isAttached) return;
    final targetSize = math.max(_sheetController.size, 0.6);
    await _sheetController.animateTo(
      targetSize,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _scrollToTimelineKey(GlobalKey key) async {
    await _expandSheetForSelection();
    if (!mounted) return;

    BuildContext? targetContext = key.currentContext;
    if (targetContext == null) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (!mounted) return;
      targetContext = key.currentContext;
    }
    if (targetContext == null) return;
    final visibleContext = targetContext;

    await Scrollable.ensureVisible(
      visibleContext,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0.12,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
    );
  }

  Future<void> _onVisitMarkerTapped(TimelineVisit visit) async {
    final placeId = visit.placeId;
    if (placeId.isEmpty) return;
    if (_selectedVisitPlaceId == placeId) {
      _deselectAndFitOverview();
      return;
    }
    setState(() {
      _selectedVisitPlaceId = placeId;
      _selectedRunId = null;
    });
    await _scrollToTimelineKey(_visitTimelineKey(placeId));
  }

  void _deselectAndFitOverview() {
    setState(() {
      _selectedVisitPlaceId = null;
      _selectedRunId = null;
    });
    final data = _dayViewData;
    if (data != null) _fitDayViewBounds(data, animated: true);
  }

  void _onBottomSheetVisitTapped(TimelineVisit visit) {
    if (_selectedVisitPlaceId == visit.placeId) {
      _deselectAndFitOverview();
      return;
    }
    setState(() {
      _selectedVisitPlaceId = visit.placeId;
      _selectedRunId = null;
    });
    if (visit.lat != null && visit.lon != null) {
      _flyToPoint(LatLng(visit.lat!, visit.lon!));
    }
  }

  Future<void> _onRunMarkerTapped(TimelineRun run) async {
    if (_selectedRunId == run.id) {
      _deselectAndFitOverview();
      return;
    }
    setState(() {
      _selectedRunId = run.id;
      _selectedVisitPlaceId = null;
    });
    await _scrollToTimelineKey(_runTimelineKey(run.id));
  }

  void _onRunTapped(TimelineRun run) {
    if (_selectedRunId == run.id) {
      _deselectAndFitOverview();
      return;
    }
    setState(() {
      _selectedRunId = run.id;
      _selectedVisitPlaceId = null;
    });
    final pts = _decodePolylinePoints(run.id, run.summaryPolyline);
    if (pts.length < 2) return;
    try {
      final targetCamera = _dayViewCameraTarget(pts);
      if (targetCamera == null) return;
      _animateMapTo(center: targetCamera.center, zoom: targetCamera.zoom);
    } catch (_) {}
  }

  void _onSegmentTapped(TimelineSegment segment) {
    if (segment.isVisit) {
      if (_selectedVisitPlaceId == segment.placeId) {
        _deselectAndFitOverview();
        return;
      }
      setState(() {
        _selectedVisitPlaceId = segment.placeId;
        _selectedRunId = null;
      });
      if (segment.placeLat != null && segment.placeLon != null) {
        _flyToPoint(LatLng(segment.placeLat!, segment.placeLon!));
      }
    } else if (segment.isActivity) {
      if (segment.matchedRunId != null) {
        final run = _dayViewData?.runs
            .where((r) => r.id == segment.matchedRunId)
            .firstOrNull;
        if (run != null) {
          _onRunTapped(run);
          return;
        }
      }
      if (segment.startLat != null && segment.startLon != null) {
        _flyToPoint(LatLng(segment.startLat!, segment.startLon!));
      }
    }
  }

  void _onCalendarEventTapped(TimelineCalendarEvent event) {
    showCalendarEventDetailSheet(
      context,
      summary: event.summary,
      timeLabel: _formatCalendarEventTime(event),
      location: event.location ?? '',
      description: event.description ?? '',
      sourceLabel: _formatCalendarSourceLabel(event),
    );
  }

  String _formatCalendarEventTime(TimelineCalendarEvent event) {
    if (event.isAllDay) return 'All day';
    final start = event.start;
    final end = event.end;
    if (start == null) return 'Time unavailable';
    final startLabel =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
    if (end == null) return startLabel;
    final endLabel =
        '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    return '$startLabel – $endLabel';
  }

  String _formatCalendarSourceLabel(TimelineCalendarEvent event) {
    final sourceName = event.sourceName?.trim() ?? '';
    final source = event.source?.trim() ?? '';
    if (sourceName.isNotEmpty && source == 'google_calendar_manual') {
      return '$sourceName (manual import)';
    }
    if (sourceName.isNotEmpty) return sourceName;
    if (source == 'google_calendar_manual') return 'Manual calendar import';
    if (source == 'google_calendar') return 'Connected Google Calendar';
    return source;
  }

  static const _activityOptions = <(String, String, IconData)>[
    ('FLYING', 'Flight', Icons.flight_outlined),
    ('IN_VEHICLE', 'Driving', Icons.directions_car_outlined),
    ('IN_TRAIN', 'Train', Icons.train_outlined),
    ('IN_BUS', 'Bus', Icons.directions_bus_outlined),
    ('IN_FERRY', 'Ferry', Icons.directions_boat_outlined),
    ('ON_BICYCLE', 'Cycling', Icons.directions_bike_outlined),
    ('WALKING', 'Walking', Icons.directions_walk_outlined),
    ('RUNNING', 'Running', Icons.directions_run_outlined),
    ('MOTORCYCLING', 'Motorcycle', Icons.two_wheeler_outlined),
    ('IN_TRAM', 'Tram', Icons.tram_outlined),
    ('IN_SUBWAY', 'Subway', Icons.subway_outlined),
    ('HIKING', 'Hiking', Icons.hiking_outlined),
  ];

  Future<void> _showAddVisitDialog() async {
    final placeController = TextEditingController();
    final startPlaceController = TextEditingController();
    final endPlaceController = TextEditingController();
    final date = _dayViewDate;
    final baseDate =
        DateTime.tryParse(date) ?? DateUtils.dateOnly(DateTime.now());
    var startTime = TimeOfDay.now();
    var endTime = TimeOfDay(
      hour: (startTime.hour + 1) % 24,
      minute: startTime.minute,
    );
    var endDate = baseDate;
    var isTravel = false;
    var activityType = _activityOptions.first;

    DateTime combineDateTime(DateTime day, TimeOfDay time) =>
        DateTime(day.year, day.month, day.day, time.hour, time.minute);

    String formatTod(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    String formatDialogDate(DateTime value) {
      const months = <String>[
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${months[value.month - 1]} ${value.day}, ${value.year}';
    }

    String toIso(DateTime day, TimeOfDay time) {
      final dt = combineDateTime(day, time);
      final month = dt.month.toString().padLeft(2, '0');
      final dayPart = dt.day.toString().padLeft(2, '0');
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '${dt.year}-$month-$dayPart'
          'T$hour:$minute:00';
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final theme = Theme.of(context);
            final colorScheme = theme.colorScheme;
            final startDateTime = combineDateTime(baseDate, startTime);
            final endDateTime = combineDateTime(endDate, endTime);

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              title: Row(
                children: [
                  Icon(
                    isTravel ? Icons.route : Icons.add_location_alt,
                    size: 22,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(isTravel ? 'Add Travel' : 'Add Visit'),
                ],
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      date,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Visit / Travel toggle
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Visit')),
                        ButtonSegment(value: true, label: Text('Travel')),
                      ],
                      selected: {isTravel},
                      onSelectionChanged: (s) =>
                          setDialogState(() => isTravel = s.first),
                      showSelectedIcon: false,
                    ),
                    const SizedBox(height: 16),
                    if (!isTravel)
                      TextField(
                        controller: placeController,
                        decoration: const InputDecoration(
                          labelText: 'Place name',
                          hintText: 'e.g. Eiffel Tower, Paris',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.place),
                        ),
                        textCapitalization: TextCapitalization.words,
                        autofocus: true,
                      ),
                    if (isTravel) ...[
                      // Activity type picker
                      DropdownButtonFormField<(String, String, IconData)>(
                        initialValue: activityType,
                        decoration: const InputDecoration(
                          labelText: 'Travel type',
                          border: OutlineInputBorder(),
                        ),
                        items: _activityOptions
                            .map(
                              (opt) => DropdownMenuItem(
                                value: opt,
                                child: Row(
                                  children: [
                                    Icon(opt.$3, size: 20),
                                    const SizedBox(width: 10),
                                    Text(opt.$2),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setDialogState(() => activityType = v);
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: startPlaceController,
                        decoration: const InputDecoration(
                          labelText: 'From',
                          hintText: 'e.g. Berlin Airport',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.trip_origin),
                        ),
                        textCapitalization: TextCapitalization.words,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: endPlaceController,
                        decoration: const InputDecoration(
                          labelText: 'To',
                          hintText: 'e.g. Paris CDG',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.flag_outlined),
                        ),
                        textCapitalization: TextCapitalization.words,
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (!isTravel)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.schedule, size: 18),
                              label: Text(formatTod(startTime)),
                              onPressed: () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: startTime,
                                );
                                if (picked != null) {
                                  setDialogState(() => startTime = picked);
                                }
                              },
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(
                              Icons.arrow_forward,
                              size: 16,
                              color: Colors.grey,
                            ),
                          ),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.schedule, size: 18),
                              label: Text(formatTod(endTime)),
                              onPressed: () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: endTime,
                                );
                                if (picked != null) {
                                  setDialogState(() => endTime = picked);
                                }
                              },
                            ),
                          ),
                        ],
                      )
                    else ...[
                      Text(
                        'Trip window',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Start date',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.today_outlined),
                              ),
                              child: Text(formatDialogDate(baseDate)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.schedule, size: 18),
                              label: Text(formatTod(startTime)),
                              onPressed: () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: startTime,
                                );
                                if (picked != null) {
                                  setDialogState(() {
                                    startTime = picked;
                                    if (!endDateTime.isAfter(
                                      combineDateTime(baseDate, startTime),
                                    )) {
                                      endDate = baseDate.add(
                                        const Duration(days: 1),
                                      );
                                    }
                                  });
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                Icons.calendar_today_outlined,
                                size: 18,
                              ),
                              label: Text(formatDialogDate(endDate)),
                              onPressed: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: endDate,
                                  firstDate: baseDate,
                                  lastDate: baseDate.add(
                                    const Duration(days: 7),
                                  ),
                                );
                                if (picked != null) {
                                  setDialogState(() => endDate = picked);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.schedule, size: 18),
                              label: Text(formatTod(endTime)),
                              onPressed: () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: endTime,
                                );
                                if (picked != null) {
                                  setDialogState(() {
                                    endTime = picked;
                                    if (endDate == baseDate &&
                                        !combineDateTime(
                                          endDate,
                                          endTime,
                                        ).isAfter(startDateTime)) {
                                      endDate = baseDate.add(
                                        const Duration(days: 1),
                                      );
                                    }
                                  });
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${formatDialogDate(baseDate)} ${formatTod(startTime)}'
                        ' -> ${formatDialogDate(endDate)} ${formatTod(endTime)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true || !mounted) return;

    final startIso = toIso(baseDate, startTime);
    final resolvedEndDate =
        isTravel &&
            !combineDateTime(
              endDate,
              endTime,
            ).isAfter(combineDateTime(baseDate, startTime))
        ? baseDate.add(const Duration(days: 1))
        : endDate;
    final endIso = toIso(resolvedEndDate, endTime);

    try {
      if (isTravel) {
        final from = startPlaceController.text.trim();
        final to = endPlaceController.text.trim();
        if (from.isEmpty || to.isEmpty) return;
        await ref
            .read(mapRepositoryProvider)
            .addManualActivity(
              startTime: startIso,
              endTime: endIso,
              activityType: activityType.$1,
              placeNameStart: from,
              placeNameEnd: to,
            );
      } else {
        final placeName = placeController.text.trim();
        if (placeName.isEmpty) return;
        await ref
            .read(mapRepositoryProvider)
            .addManualVisit(
              date: date,
              startTime: startIso,
              endTime: endIso,
              placeName: placeName,
            );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isTravel ? 'Travel added' : 'Visit added')),
      );
      _loadDayView(date);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $error')));
    }
  }

  Future<void> _deleteManualVisit(int segmentId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete entry?'),
        content: const Text('This will remove the manually-added location.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref.read(mapRepositoryProvider).deleteManualVisit(segmentId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Entry deleted')));
      _loadDayView(_dayViewDate);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $error')));
    }
  }

  String? _authToken() {
    final tokenStore = ref.read(authTokenStoreProvider);
    return ref.read(authControllerProvider).value?.accessToken ??
        tokenStore.peekToken();
  }

  String _authenticatedUrl(String url) {
    return url;
  }

  Map<String, String> _authHeaders() {
    if (kIsWeb) {
      return const {};
    }
    final token = _authToken();
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

  bool _boundsCloseEnough(LatLngBounds? a, LatLngBounds b) {
    if (a == null) return false;
    return (a.northWest.latitude - b.northWest.latitude).abs() < 0.2 &&
        (a.northWest.longitude - b.northWest.longitude).abs() < 0.2 &&
        (a.southEast.latitude - b.southEast.latitude).abs() < 0.2 &&
        (a.southEast.longitude - b.southEast.longitude).abs() < 0.2;
  }

  bool _isFiniteBounds(LatLngBounds bounds) {
    return bounds.northWest.latitude.isFinite &&
        bounds.northWest.longitude.isFinite &&
        bounds.northEast.latitude.isFinite &&
        bounds.northEast.longitude.isFinite &&
        bounds.southWest.latitude.isFinite &&
        bounds.southWest.longitude.isFinite &&
        bounds.southEast.latitude.isFinite &&
        bounds.southEast.longitude.isFinite;
  }

  bool _isZeroAreaBounds(LatLngBounds bounds) {
    return bounds.north == bounds.south && bounds.east == bounds.west;
  }
}

class _DayBottomSheet extends StatelessWidget {
  const _DayBottomSheet({
    required this.dates,
    required this.currentIndex,
    required this.currentDate,
    required this.onPreviousDate,
    required this.onNextDate,
    required this.data,
    required this.onVisitTapped,
    required this.onSegmentTapped,
    required this.onCalendarEventTapped,
    required this.authHeaders,
    required this.authenticateUrl,
    required this.runColors,
    required this.onRunTapped,
    required this.onImageTapped,
    required this.visitKeyForPlaceId,
    required this.runKeyForRunId,
    required this.isLoading,
    required this.errorText,
    this.sheetController,
    this.selectedVisitPlaceId,
    this.selectedRunId,
    this.isWideLayout = false,
    this.onAddVisit,
    this.onDeleteSegment,
    this.onDateTapped,
  });

  final List<String> dates;
  final int currentIndex;
  final String currentDate;
  final VoidCallback onPreviousDate;
  final VoidCallback onNextDate;
  final TimelineDayData? data;
  final void Function(TimelineVisit visit) onVisitTapped;
  final void Function(TimelineSegment segment) onSegmentTapped;
  final void Function(TimelineCalendarEvent event) onCalendarEventTapped;
  final void Function(TimelineRun run) onRunTapped;
  final void Function(List<TimelineImageLocation> imgs, int index)
  onImageTapped;
  final GlobalKey Function(String placeId) visitKeyForPlaceId;
  final GlobalKey Function(String runId) runKeyForRunId;
  final String? selectedVisitPlaceId;
  final String? selectedRunId;
  final bool isLoading;
  final String errorText;
  final DraggableScrollableController? sheetController;
  final Map<String, String> authHeaders;
  final String Function(String url) authenticateUrl;
  final Map<String, Color> runColors;
  final bool isWideLayout;
  final VoidCallback? onAddVisit;
  final void Function(int segmentId)? onDeleteSegment;
  final VoidCallback? onDateTapped;

  static const double _collapsedHeight = 120;
  static const double _webPanelMinHeight = 280;
  static const double _webPanelMaxHeight = 420;

  /// Max photos to show inline per visit. Remaining are aggregated.
  static const int _maxInlinePhotos = 4;

  double _safeMinFraction(double screenHeight) {
    if (!screenHeight.isFinite || screenHeight <= 0) {
      return 0.18;
    }
    final fraction = _collapsedHeight / screenHeight;
    if (!fraction.isFinite || fraction <= 0) {
      return 0.18;
    }
    return fraction.clamp(0.08, 0.25);
  }

  @override
  Widget build(BuildContext context) {
    if (dates.isEmpty) {
      return const SizedBox.shrink();
    }
    final screenHeight = MediaQuery.of(context).size.height;
    final minFraction = _safeMinFraction(screenHeight);
    final safeIndex = currentIndex.clamp(0, dates.length - 1);
    final rawSegments = data?.segments ?? const [];
    final images = data?.imageLocations ?? const [];
    final runs = data?.runs ?? const [];
    final calendarEvents = data?.calendarEvents ?? const [];
    final keyedVisitPlaceIds = <String>{};

    // Build run lookup by ID.
    final runById = <String, TimelineRun>{};
    for (final r in runs) {
      runById[r.id] = r;
    }

    // --- Remove activity segments replaced by Strava runs, then aggregate ---
    final matchedRunIds = <String>{};
    for (final seg in rawSegments) {
      if (seg.isActivity && seg.matchedRunId != null) {
        matchedRunIds.add(seg.matchedRunId!);
      }
    }
    // Filter out matched activity segments first.
    final filtered = rawSegments
        .where(
          (seg) =>
              !(seg.isActivity &&
                  seg.matchedRunId != null &&
                  matchedRunIds.contains(seg.matchedRunId)),
        )
        .toList();

    // Aggregate consecutive same-type segments.
    final segments = <TimelineSegment>[];
    for (final seg in filtered) {
      if (segments.isNotEmpty) {
        final prev = segments.last;
        // Aggregate consecutive same-type activities.
        if (seg.isActivity &&
            prev.isActivity &&
            _activityGroupKey(prev.activityType) ==
                _activityGroupKey(seg.activityType)) {
          segments.removeLast();
          segments.add(
            TimelineSegment(
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
            ),
          );
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
          segments.add(
            TimelineSegment(
              id: prev.id,
              segmentType: prev.segmentType,
              startTime: prev.startTime,
              endTime: seg.endTime ?? prev.endTime,
              durationMinutes: prev.durationMinutes + seg.durationMinutes,
              placeId: prev.placeId,
              placeName: prev.placeName ?? seg.placeName,
              placeAddress: prev.placeAddress ?? seg.placeAddress,
              placeLat: prev.placeLat ?? seg.placeLat,
              placeLon: prev.placeLon ?? seg.placeLon,
              source: prev.source ?? seg.source,
            ),
          );
          continue;
        }
      }
      segments.add(seg);
    }

    // --- Build unified timeline: segments + runs, sorted by time ---
    final entries =
        <
          ({
            TimelineSegment? seg,
            TimelineRun? run,
            TimelineCalendarEvent? calendar,
            DateTime time,
          })
        >[];
    for (final seg in segments) {
      entries.add((seg: seg, run: null, calendar: null, time: seg.startTime));
    }
    for (final run in runs) {
      if (run.startTime != null) {
        entries.add((
          seg: null,
          run: run,
          calendar: null,
          time: run.startTime!,
        ));
      }
    }
    for (final event in calendarEvents) {
      if (event.start != null) {
        entries.add((
          seg: null,
          run: null,
          calendar: event,
          time: event.start!,
        ));
      }
    }
    entries.sort((a, b) => a.time.compareTo(b.time));

    final sortedImages = [...images]
      ..sort((a, b) {
        final aTime = a.timestamp;
        final bTime = b.timestamp;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return aTime.compareTo(bTime);
      });

    // Assign images by capture time so photo strips appear in chronological order.
    final leadingImages = <TimelineImageLocation>[];
    final imagesByEntryIndex = <int, List<TimelineImageLocation>>{};
    final unassignedImages = <TimelineImageLocation>[];
    for (final img in sortedImages) {
      final imageTime = img.timestamp;
      if (imageTime != null && entries.isNotEmpty) {
        int? insertAfter;
        for (var i = 0; i < entries.length; i++) {
          if (!entries[i].time.isAfter(imageTime)) {
            insertAfter = i;
          } else {
            break;
          }
        }
        if (insertAfter == null) {
          leadingImages.add(img);
        } else {
          (imagesByEntryIndex[insertAfter] ??= []).add(img);
        }
        continue;
      }

      int? bestIdx;
      double bestDist = 0.005; // ~500m threshold in degrees²
      for (var i = 0; i < entries.length; i++) {
        final seg = entries[i].seg;
        if (seg == null ||
            !seg.isVisit ||
            seg.placeLat == null ||
            seg.placeLon == null) {
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

    final hasTimeline =
        entries.isNotEmpty ||
        leadingImages.isNotEmpty ||
        unassignedImages.isNotEmpty;

    final timelineChildren = _buildTimelineContent(
      context,
      entries: entries,
      leadingImages: leadingImages,
      imagesByEntryIndex: imagesByEntryIndex,
      unassignedImages: unassignedImages,
      keyedVisitPlaceIds: keyedVisitPlaceIds,
      runById: runById,
      hasTimeline: hasTimeline,
      isLoading: isLoading,
      errorText: errorText,
    );

    if (isWideLayout) {
      return Container(
        color: _timelinePanelColor(context),
        child: Column(
          children: [
            const SizedBox(height: 12),
            _buildSlider(context, safeIndex),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ...timelineChildren,
                  SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (kIsWeb) {
      final panelHeight = (screenHeight * 0.42).clamp(
        _webPanelMinHeight,
        _webPanelMaxHeight,
      );
      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: panelHeight,
          decoration: BoxDecoration(
            color: _timelinePanelColor(context),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 4),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              _buildSlider(context, safeIndex),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    ...timelineChildren,
                    SizedBox(
                      height: MediaQuery.of(context).padding.bottom + 16,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return DraggableScrollableSheet(
      controller: sheetController,
      initialChildSize: minFraction,
      minChildSize: minFraction,
      maxChildSize: 0.65,
      snap: true,
      snapSizes: [minFraction, 0.65],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: _timelinePanelColor(context),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 4),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              SliverAppBar(
                pinned: true,
                automaticallyImplyLeading: false,
                toolbarHeight: 72,
                backgroundColor: _timelinePanelColor(context),
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                titleSpacing: 0,
                title: _buildSlider(context, safeIndex),
              ),
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    ...timelineChildren,
                    SizedBox(
                      height: MediaQuery.of(context).padding.bottom + 16,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildTimelineContent(
    BuildContext context, {
    required List<
      ({
        TimelineSegment? seg,
        TimelineRun? run,
        TimelineCalendarEvent? calendar,
        DateTime time,
      })
    >
    entries,
    required List<TimelineImageLocation> leadingImages,
    required Map<int, List<TimelineImageLocation>> imagesByEntryIndex,
    required List<TimelineImageLocation> unassignedImages,
    required Set<String> keyedVisitPlaceIds,
    required Map<String, TimelineRun> runById,
    required bool hasTimeline,
    required bool isLoading,
    required String errorText,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return [
      if (hasTimeline)
        Divider(
          color: colorScheme.outlineVariant.withValues(alpha: 0.45),
          height: 1,
          indent: 16,
          endIndent: 16,
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'TIMELINE',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
            ),
            if (onAddVisit != null)
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: Icon(Icons.add, color: colorScheme.onSurfaceVariant),
                  tooltip: 'Add location',
                  onPressed: onAddVisit,
                ),
              ),
          ],
        ),
      ),
      if (errorText.isNotEmpty && hasTimeline)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            errorText,
            style: const TextStyle(color: Color(0xFFFFB4AB), fontSize: 12),
          ),
        ),
      if (entries.isNotEmpty)
        Stack(
          children: [
            Positioned(
              left: 84,
              top: 8,
              bottom: 8,
              child: Container(
                width: 2,
                color: colorScheme.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            Column(
              children: [
                if (leadingImages.isNotEmpty)
                  _buildImageStrip(context, leadingImages),
                for (var i = 0; i < entries.length; i++) ...[
                  if (entries[i].seg != null)
                    _buildSegmentTile(
                      context,
                      entries[i].seg!,
                      runById,
                      keyedVisitPlaceIds,
                    )
                  else if (entries[i].calendar != null)
                    _buildCalendarEntryTile(context, entries[i].calendar!)
                  else
                    _buildRunEntryTile(context, entries[i].run!),
                  if (imagesByEntryIndex.containsKey(i))
                    _buildImageStrip(context, imagesByEntryIndex[i]!),
                ],
              ],
            ),
          ],
        ),
      if (unassignedImages.isNotEmpty) ...[
        Padding(
          padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
          child: Text(
            'PHOTOS',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
        ),
        _buildImageStrip(context, unassignedImages),
      ],
      if (isLoading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        )
      else if (errorText.isNotEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              errorText,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        )
      else if (!hasTimeline)
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text(
              'No location details for this day',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                fontSize: 13,
              ),
            ),
          ),
        ),
    ];
  }

  double _coordDist(double lat1, double lon1, double lat2, double lon2) {
    final dLat = lat1 - lat2;
    final dLon = lon1 - lon2;
    return dLat * dLat + dLon * dLon; // squared distance is fine for comparison
  }

  static const double _timelineTimeWidth = 48;
  static const double _timelineMarkerSize = 28;

  Color _timelinePanelColor(BuildContext context) {
    return Theme.of(context).colorScheme.surfaceContainerLow;
  }

  BoxDecoration _timelineTileDecoration(
    BuildContext context, {
    bool selected = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    return BoxDecoration(
      color: selected
          ? colorScheme.primaryContainer.withValues(alpha: isDark ? 0.38 : 0.9)
          : colorScheme.surfaceContainerHighest.withValues(
              alpha: isDark ? 0.3 : 0.8,
            ),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: selected
            ? colorScheme.primary.withValues(alpha: 0.45)
            : colorScheme.outlineVariant.withValues(alpha: isDark ? 0.3 : 0.55),
      ),
    );
  }

  TextStyle _timelineTimeStyle(BuildContext context, {bool selected = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    return TextStyle(
      color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  TextStyle _timelineTitleStyle(BuildContext context) => TextStyle(
    color: Theme.of(context).colorScheme.onSurface,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  TextStyle _timelineMetaStyle(BuildContext context) => TextStyle(
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    fontSize: 12,
    height: 1.3,
  );

  Color _timelineResolvedAccent(BuildContext context, Color accent) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    final luminance = accent.computeLuminance();

    if (!isDark && luminance > 0.55) {
      return Color.alphaBlend(
        colorScheme.onSurface.withValues(alpha: 0.34),
        accent,
      );
    }
    if (isDark && luminance < 0.22) {
      return Color.alphaBlend(Colors.white.withValues(alpha: 0.18), accent);
    }
    return accent;
  }

  BoxDecoration _timelineMarkerDecoration(
    BuildContext context, {
    required Color accent,
    bool selected = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    final resolvedAccent = _timelineResolvedAccent(context, accent);
    final fill = selected
        ? resolvedAccent
        : Color.alphaBlend(
            resolvedAccent.withValues(alpha: isDark ? 0.22 : 0.14),
            colorScheme.surfaceContainerHighest,
          );
    return BoxDecoration(
      color: fill,
      shape: BoxShape.circle,
      border: Border.all(
        color: selected
            ? resolvedAccent
            : resolvedAccent.withValues(alpha: isDark ? 0.72 : 0.52),
        width: 1.5,
      ),
    );
  }

  Color _timelineMarkerIconColor(
    BuildContext context, {
    required Color accent,
    bool selected = false,
  }) {
    final resolvedAccent = _timelineResolvedAccent(context, accent);
    if (!selected) return resolvedAccent;
    return ThemeData.estimateBrightnessForColor(resolvedAccent) ==
            Brightness.dark
        ? Colors.white
        : Colors.black;
  }

  Color _timelineChevronColor(
    BuildContext context, {
    bool highlighted = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return highlighted
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant.withValues(alpha: 0.72);
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

  ({
    DateTime visibleStart,
    DateTime? visibleEnd,
    int visibleDurationMinutes,
    bool startedPreviousDay,
    bool continuesNextDay,
  })
  _activitySliceForCurrentDay(TimelineSegment segment) {
    final currentDay =
        DateTime.tryParse(currentDate) ?? DateUtils.dateOnly(DateTime.now());
    final dayStart = DateTime(
      currentDay.year,
      currentDay.month,
      currentDay.day,
    );
    final dayEnd = dayStart.add(const Duration(days: 1));
    final startedPreviousDay = segment.startTime.isBefore(dayStart);
    final visibleStart = startedPreviousDay ? dayStart : segment.startTime;
    final rawEnd = segment.endTime;
    final continuesNextDay = rawEnd != null && rawEnd.isAfter(dayEnd);
    DateTime? visibleEnd;
    if (rawEnd != null) {
      visibleEnd = continuesNextDay ? dayEnd : rawEnd;
      if (visibleEnd.isBefore(visibleStart)) {
        visibleEnd = visibleStart;
      }
    }
    final visibleDurationMinutes = visibleEnd == null
        ? 0
        : visibleEnd.difference(visibleStart).inMinutes;
    return (
      visibleStart: visibleStart,
      visibleEnd: visibleEnd,
      visibleDurationMinutes: visibleDurationMinutes,
      startedPreviousDay: startedPreviousDay,
      continuesNextDay: continuesNextDay,
    );
  }

  String _timelineWeekdayLabel(DateTime date) {
    const labels = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return labels[date.weekday - 1];
  }

  String _timelineDateLabel(DateTime date) {
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  Widget _buildSlider(BuildContext context, int safeIndex) {
    final colorScheme = Theme.of(context).colorScheme;
    final today = DateUtils.dateOnly(DateTime.now());
    final current = DateTime.tryParse(currentDate) ?? today;
    final canGoForward = current.isBefore(today);
    final weekdayLabel = _timelineWeekdayLabel(current);
    final dateLabel = _timelineDateLabel(current);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: onPreviousDate,
              icon: const Icon(Icons.chevron_left, size: 22),
              color: colorScheme.onSurface,
              splashRadius: 20,
              tooltip: 'Previous day',
            ),
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onDateTapped,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          weekdayLabel,
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              dateLabel,
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.expand_more,
                              size: 18,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: canGoForward ? onNextDate : null,
              icon: const Icon(Icons.chevron_right, size: 22),
              color: colorScheme.onSurface,
              disabledColor: colorScheme.onSurface.withValues(alpha: 0.28),
              splashRadius: 20,
              tooltip: 'Next day',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentTile(
    BuildContext context,
    TimelineSegment segment,
    Map<String, TimelineRun> runById,
    Set<String> keyedVisitPlaceIds,
  ) {
    if (segment.isVisit) {
      return _buildVisitSegmentTile(context, segment, keyedVisitPlaceIds);
    } else {
      return _buildActivitySegmentTile(context, segment, runById);
    }
  }

  Widget _buildVisitSegmentTile(
    BuildContext context,
    TimelineSegment seg,
    Set<String> keyedVisitPlaceIds,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSelected = seg.placeId == selectedVisitPlaceId;
    final hasLocation = seg.placeLat != null && seg.placeLon != null;
    final displayName = seg.placeName ?? seg.placeId ?? 'Unknown';
    final timeLabel = _formatTime(seg.startTime);
    final durationLabel = _formatDuration(seg.durationMinutes);
    final markerAccent = hasLocation
        ? colorScheme.primary
        : colorScheme.outlineVariant;
    final resolvedMarkerAccent = _timelineResolvedAccent(context, markerAccent);

    final placeId = seg.placeId;
    final anchorKey = placeId != null && keyedVisitPlaceIds.add(placeId)
        ? visitKeyForPlaceId(placeId)
        : null;

    return KeyedSubtree(
      key: anchorKey,
      child: GestureDetector(
        onTap: () => onSegmentTapped(seg),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: _timelineTileDecoration(context, selected: isSelected),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _timelineTimeWidth,
                child: Text(
                  timeLabel,
                  style: _timelineTimeStyle(context, selected: isSelected),
                ),
              ),
              Container(
                width: _timelineMarkerSize,
                height: _timelineMarkerSize,
                decoration: _timelineMarkerDecoration(
                  context,
                  accent: markerAccent,
                  selected: isSelected,
                ),
                child: Icon(
                  Icons.location_on,
                  size: 15,
                  color: _timelineMarkerIconColor(
                    context,
                    accent: markerAccent,
                    selected: isSelected,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: _timelineTitleStyle(context).copyWith(
                        color: hasLocation
                            ? resolvedMarkerAccent
                            : colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (seg.placeAddress != null) ...[
                          Flexible(
                            child: Text(
                              seg.placeAddress!,
                              style: _timelineMetaStyle(context),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '  ·  ',
                            style: TextStyle(
                              color: colorScheme.outlineVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                        Text(durationLabel, style: _timelineMetaStyle(context)),
                      ],
                    ),
                  ],
                ),
              ),
              if (seg.isManual && seg.id != null && onDeleteSegment != null)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: Icon(
                      Icons.close,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                    ),
                    tooltip: 'Delete',
                    onPressed: () => onDeleteSegment!(seg.id!),
                  ),
                )
              else if (hasLocation)
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: _timelineChevronColor(
                    context,
                    highlighted: isSelected,
                  ),
                ),
            ],
          ),
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
    final colorScheme = Theme.of(context).colorScheme;
    final run = seg.matchedRunId != null ? runById[seg.matchedRunId] : null;
    final slice = _activitySliceForCurrentDay(seg);
    final timeLabel = _formatTime(slice.visibleStart);
    final hasLocation = seg.startLat != null && seg.startLon != null;
    final isRunning = seg.activityType == 'RUNNING';
    final activityColor = isRunning
        ? const Color(0xCCFF9800)
        : colorScheme.secondary;
    final resolvedActivityColor = _timelineResolvedAccent(
      context,
      activityColor,
    );
    final activityIcon = _activityTypeIcon(seg.activityType);
    // For running: prefer the Strava run name if matched.
    final typeLabel = isRunning && run != null && run.name.isNotEmpty
        ? run.name
        : _activityTypeLabel(seg.activityType);

    // Build subtitle parts
    final subtitleParts = <String>[];
    if (slice.visibleEnd != null) {
      subtitleParts.add(
        '${_formatTime(slice.visibleStart)} – ${_formatTime(slice.visibleEnd!)}',
      );
    }
    if (slice.visibleDurationMinutes > 0) {
      subtitleParts.add(_formatDuration(slice.visibleDurationMinutes));
    }
    if (seg.distanceMeters != null && seg.distanceMeters! > 0) {
      final km = seg.distanceMeters! / 1000;
      subtitleParts.add(
        km >= 1 ? '${km.toStringAsFixed(1)} km' : '${seg.distanceMeters} m',
      );
    }
    if (slice.startedPreviousDay) {
      subtitleParts.add('started previous day');
    }
    if (slice.continuesNextDay) {
      subtitleParts.add('continues next day');
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onSegmentTapped(seg),
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: _timelineTileDecoration(context),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _timelineTimeWidth,
              child: Text(timeLabel, style: _timelineTimeStyle(context)),
            ),
            Container(
              width: _timelineMarkerSize,
              height: _timelineMarkerSize,
              decoration: _timelineMarkerDecoration(
                context,
                accent: resolvedActivityColor,
              ),
              child: Icon(
                activityIcon,
                size: 15,
                color: _timelineMarkerIconColor(
                  context,
                  accent: resolvedActivityColor,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    typeLabel,
                    style: _timelineTitleStyle(
                      context,
                    ).copyWith(color: resolvedActivityColor),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitleParts.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitleParts.join('  ·  '),
                      style: _timelineMetaStyle(context),
                    ),
                  ],
                ],
              ),
            ),
            if (seg.isManual && seg.id != null && onDeleteSegment != null)
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  icon: Icon(
                    Icons.close,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                  tooltip: 'Delete',
                  onPressed: () => onDeleteSegment!(seg.id!),
                ),
              )
            else if (hasLocation)
              Icon(
                Icons.chevron_right,
                size: 16,
                color: _timelineChevronColor(context),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunEntryTile(BuildContext context, TimelineRun run) {
    const color = Color(0xCCF79C70);
    final resolvedRunColor = _timelineResolvedAccent(context, color);
    final timeLabel = run.startTime != null ? _formatTime(run.startTime!) : '';
    final isSelected = run.id == selectedRunId;

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

    return KeyedSubtree(
      key: runKeyForRunId(run.id),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onRunTapped(run),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: _timelineTileDecoration(context, selected: isSelected),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _timelineTimeWidth,
                child: Text(
                  timeLabel,
                  style: _timelineTimeStyle(context, selected: isSelected),
                ),
              ),
              Container(
                width: _timelineMarkerSize,
                height: _timelineMarkerSize,
                decoration: _timelineMarkerDecoration(
                  context,
                  accent: resolvedRunColor,
                  selected: isSelected,
                ),
                child: Icon(
                  Icons.directions_run,
                  size: 15,
                  color: _timelineMarkerIconColor(
                    context,
                    accent: resolvedRunColor,
                    selected: isSelected,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      run.name.isNotEmpty ? run.name : 'Run',
                      style: _timelineTitleStyle(
                        context,
                      ).copyWith(color: resolvedRunColor),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitleParts.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitleParts.join('  ·  '),
                        style: _timelineMetaStyle(context),
                      ),
                    ],
                  ],
                ),
              ),
              if (run.summaryPolyline.isNotEmpty)
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: isSelected
                      ? resolvedRunColor
                      : _timelineChevronColor(context),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCalendarEntryTile(
    BuildContext context,
    TimelineCalendarEvent event,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    const color = Color(0xFFA7F3D0);
    final resolvedEventColor = _timelineResolvedAccent(context, color);
    final timeLabel = event.start != null ? _formatTime(event.start!) : '';
    final subtitleParts = <String>[];
    if (event.isAllDay) {
      subtitleParts.add('All day');
    } else {
      final end = event.end;
      if (end != null && event.start != null) {
        subtitleParts.add('${_formatTime(event.start!)} – ${_formatTime(end)}');
      }
    }
    final location = event.location?.trim();
    if (location != null && location.isNotEmpty) {
      subtitleParts.add(location);
    }
    final sourceBadge = _calendarSourceBadge(event);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onCalendarEventTapped(event),
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: _timelineTileDecoration(context),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _timelineTimeWidth,
              child: Text(
                timeLabel.isNotEmpty ? timeLabel : 'All',
                style: _timelineTimeStyle(context),
              ),
            ),
            Container(
              width: _timelineMarkerSize,
              height: _timelineMarkerSize,
              decoration: _timelineMarkerDecoration(
                context,
                accent: resolvedEventColor,
              ),
              child: Icon(
                Icons.event_rounded,
                size: 15,
                color: _timelineMarkerIconColor(
                  context,
                  accent: resolvedEventColor,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          event.summary.isNotEmpty
                              ? event.summary
                              : 'Calendar event',
                          style: _timelineTitleStyle(
                            context,
                          ).copyWith(color: resolvedEventColor),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (sourceBadge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            sourceBadge,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (subtitleParts.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitleParts.join('  ·  '),
                      style: _timelineMetaStyle(context),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: _timelineChevronColor(context),
            ),
          ],
        ),
      ),
    );
  }

  String? _calendarSourceBadge(TimelineCalendarEvent event) {
    final source = event.source?.trim();
    if (source == 'google_calendar_manual') return 'Imported';
    if (source == 'google_calendar') return 'Synced';
    return null;
  }

  Widget _buildImageStrip(
    BuildContext context,
    List<TimelineImageLocation> imgs,
  ) {
    final showCount = imgs.length > _maxInlinePhotos
        ? _maxInlinePhotos
        : imgs.length;
    final remaining = imgs.length - showCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(88, 4, 16, 10),
      child: SizedBox(
        height: 68,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: showCount + (remaining > 0 ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (context, index) {
            if (index >= showCount) {
              // "+N more" badge
              return GestureDetector(
                onTap: () => onImageTapped(imgs, showCount),
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(14),
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
                ),
              );
            }
            return GestureDetector(
              onTap: () => onImageTapped(imgs, index),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ProtectedNetworkImage(
                  imageUrl: authenticateUrl(imgs[index].path),
                  headers: authHeaders,
                  fit: BoxFit.cover,
                  placeholder: Container(
                    width: 68,
                    height: 68,
                    color: const Color(0x22FFFFFF),
                  ),
                  errorWidget: Container(
                    width: 68,
                    height: 68,
                    color: const Color(0x22FFFFFF),
                    child: const Icon(
                      Icons.image_not_supported_outlined,
                      size: 16,
                      color: Colors.white30,
                    ),
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
