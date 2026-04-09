import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config/app_config.dart';
import '../../data/repositories/files_repository.dart';
import 'protected_network_image.dart';

class ImageViewerItem {
  const ImageViewerItem({
    required this.fullUrl,
    required this.thumbnailUrl,
    required this.fileName,
    required this.path,
    required this.date,
    this.gps,
    this.favorite = false,
  });

  final String fullUrl;
  final String thumbnailUrl;
  final String fileName;
  final String path;
  final String date;
  final String? gps;
  final bool favorite;
}

typedef ImageInfoFetcher = Future<ImageInfoResult> Function(String path);
typedef ImageDeleter = Future<void> Function(String path);
typedef ImageCoverSetter = Future<void> Function(String path);

class FullscreenImageViewer extends StatefulWidget {
  const FullscreenImageViewer({
    super.key,
    required this.images,
    required this.initialIndex,
    required this.httpHeaders,
    required this.fetchImageInfo,
    this.onDelete,
    this.onSetCover,
  });

  final List<ImageViewerItem> images;
  final int initialIndex;
  final Map<String, String> httpHeaders;
  final ImageInfoFetcher fetchImageInfo;
  final ImageDeleter? onDelete;
  final ImageCoverSetter? onSetCover;

  /// Returns the set of deleted image paths (empty if none deleted).
  static Future<Set<String>> show({
    required BuildContext context,
    required List<ImageViewerItem> images,
    required int initialIndex,
    required Map<String, String> httpHeaders,
    required ImageInfoFetcher fetchImageInfo,
    ImageDeleter? onDelete,
    ImageCoverSetter? onSetCover,
  }) {
    return Navigator.of(context).push<Set<String>>(
      PageRouteBuilder<Set<String>>(
        opaque: true,
        pageBuilder: (_, __, ___) => FullscreenImageViewer(
          images: images,
          initialIndex: initialIndex,
          httpHeaders: httpHeaders,
          fetchImageInfo: fetchImageInfo,
          onDelete: onDelete,
          onSetCover: onSetCover,
        ),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 200),
      ),
    ).then((v) => v ?? const {});
  }

  @override
  State<FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<FullscreenImageViewer> {
  late PageController _pageController;
  late int _currentIndex;
  late List<ImageViewerItem> _images;
  final Set<String> _deletedPaths = {};
  bool _overlayVisible = true;
  bool _isZoomed = false;
  bool _downloading = false;
  bool _sharing = false;
  bool _deleting = false;
  final TransformationController _transformController =
      TransformationController();

  @override
  void initState() {
    super.initState();
    _images = List.of(widget.images);
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _transformController.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transformController.removeListener(_onTransformChanged);
    _transformController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final scale = _transformController.value.getMaxScaleOnAxis();
    final zoomed = scale > 1.05;
    if (zoomed != _isZoomed) {
      setState(() => _isZoomed = zoomed);
    }
  }

  void _toggleOverlay() {
    setState(() => _overlayVisible = !_overlayVisible);
  }

  void _onPageChanged(int index) {
    _transformController.value = Matrix4.identity();
    setState(() => _currentIndex = index);
  }

  ImageViewerItem get _current => _images[_currentIndex];

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final resolvedUrl = await resolveProtectedMediaUrl(
        _current.fullUrl,
        headers: widget.httpHeaders,
      );
      final response = await http.get(
        Uri.parse(resolvedUrl),
        headers: widget.httpHeaders,
      );
      if (response.statusCode != 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to load image')),
          );
        }
        return;
      }
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/${_current.fileName}');
      await file.writeAsBytes(response.bodyBytes);
      await Share.shareXFiles([XFile(file.path)]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final resolvedUrl = await resolveProtectedMediaUrl(
        _current.fullUrl,
        headers: widget.httpHeaders,
      );
      final response = await http.get(
        Uri.parse(resolvedUrl),
        headers: widget.httpHeaders,
      );
      if (response.statusCode != 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to load image')),
          );
        }
        return;
      }
      await Gal.putImageBytes(response.bodyBytes, name: _current.fileName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to gallery')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _setCover() async {
    if (widget.onSetCover == null) return;
    try {
      await widget.onSetCover!(_current.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cover updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to set cover: $e')),
        );
      }
    }
  }

  Future<void> _delete() async {
    if (_deleting || widget.onDelete == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete image?'),
        content: const Text('This will permanently delete the image.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      await widget.onDelete!(_current.path);
      if (!mounted) return;
      _deletedPaths.add(_current.path);
      _images.removeAt(_currentIndex);
      if (_images.isEmpty) {
        Navigator.of(context).pop(_deletedPaths);
        return;
      }
      final newIndex = _currentIndex.clamp(0, _images.length - 1);
      setState(() {
        _currentIndex = newIndex;
        _pageController.jumpToPage(newIndex);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image deleted')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  void _showMetadataPanel() {
    final item = _current;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _ImageMetadataSheet(
        item: item,
        fetchImageInfo: widget.fetchImageInfo,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Image pager
          PageView.builder(
            controller: _pageController,
            itemCount: _images.length,
            onPageChanged: _onPageChanged,
            physics: _isZoomed
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemBuilder: (_, index) {
              final image = _images[index];
              return GestureDetector(
                onTap: _toggleOverlay,
                child: InteractiveViewer(
                  transformationController:
                      index == _currentIndex ? _transformController : null,
                  minScale: 1.0,
                  maxScale: 5.0,
                  child: Center(
                    child: ProtectedNetworkImage(
                      imageUrl: image.fullUrl,
                      headers: widget.httpHeaders,
                      fit: BoxFit.contain,
                      placeholder: ProtectedNetworkImage(
                        imageUrl: image.thumbnailUrl,
                        headers: widget.httpHeaders,
                        fit: BoxFit.contain,
                        placeholder: const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                        errorWidget: const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                      errorWidget: const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),

          // Top bar
          AnimatedOpacity(
            opacity: _overlayVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !_overlayVisible,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
                padding: EdgeInsets.only(top: mediaQuery.padding.top),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () =>
                          Navigator.of(context).pop(_deletedPaths),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _current.date,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _current.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        '${_currentIndex + 1} / ${_images.length}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              opacity: _overlayVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_overlayVisible,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  padding: EdgeInsets.only(bottom: mediaQuery.padding.bottom),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        onPressed: _sharing ? null : _share,
                        tooltip: 'Share',
                        icon: _sharing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.share_outlined,
                                color: Colors.white,
                              ),
                      ),
                      if (!kIsWeb)
                        IconButton(
                          onPressed: _downloading ? null : _download,
                          tooltip: 'Download',
                          icon: _downloading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.download_outlined,
                                  color: Colors.white,
                                ),
                        ),
                      IconButton(
                        onPressed: _showMetadataPanel,
                        tooltip: 'Details',
                        icon: const Icon(
                          Icons.info_outline,
                          color: Colors.white,
                        ),
                      ),
                      if (widget.onSetCover != null)
                        IconButton(
                          onPressed: _setCover,
                          tooltip: 'Set as cover',
                          icon: const Icon(
                            Icons.star_outline_rounded,
                            color: Colors.white,
                          ),
                        ),
                      if (widget.onDelete != null)
                        IconButton(
                          onPressed: _deleting ? null : _delete,
                          tooltip: 'Delete',
                          icon: _deleting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.delete_outline,
                                  color: Colors.white,
                                ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Metadata bottom sheet — fetches real EXIF data from the backend
// ---------------------------------------------------------------------------

class _ImageMetadataSheet extends StatefulWidget {
  const _ImageMetadataSheet({
    required this.item,
    required this.fetchImageInfo,
  });

  final ImageViewerItem item;
  final ImageInfoFetcher fetchImageInfo;

  @override
  State<_ImageMetadataSheet> createState() => _ImageMetadataSheetState();
}

class _ImageMetadataSheetState extends State<_ImageMetadataSheet> {
  ImageInfoResult? _info;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchInfo();
  }

  Future<void> _fetchInfo() async {
    try {
      final info = await widget.fetchImageInfo(widget.item.path);
      if (mounted) setState(() { _info = info; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  /// Parse EXIF datetime "YYYY:MM:DD HH:MM:SS" into a readable string.
  static String _formatExifDateTime(String raw) {
    // EXIF format: "2024:03:15 14:30:22"
    final parts = raw.split(' ');
    if (parts.length >= 2) {
      final date = parts[0].replaceAll(':', '-'); // "2024-03-15"
      final time = parts[1]; // "14:30:22"
      return '$date  $time';
    }
    return raw;
  }

  /// Try to parse a GPS coordinate string like "52.5200000, 13.4050000" into LatLng.
  static LatLng? _parseGps(String gps) {
    final parts = gps.split(',');
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0].trim());
    final lon = double.tryParse(parts[1].trim());
    if (lat == null || lon == null) return null;
    return LatLng(lat, lon);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;

    if (_loading) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(48),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (_error != null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Failed to load details: $_error'),
        ),
      );
    }

    final exif = _info?.exif ?? const {};
    final file = _info?.file ?? const {};

    // Date & time from EXIF
    final rawDateTime = exif['DateTimeOriginal']?.toString() ??
        exif['DateTime']?.toString();
    final dateDisplay = rawDateTime != null
        ? _formatExifDateTime(rawDateTime)
        : item.date;

    // Location
    final gpsStr = (file['gps'] ?? item.gps ?? '').toString();
    final gpsLatLng = gpsStr.isNotEmpty ? _parseGps(gpsStr) : null;

    // Image resolution
    final imgWidth = exif['ExifImageWidth'] ?? exif['ImageWidth'];
    final imgHeight = exif['ExifImageHeight'] ?? exif['ImageLength'];
    final resolution = (imgWidth is num && imgHeight is num)
        ? '${imgWidth.toInt()} × ${imgHeight.toInt()}'
        : '';

    // Camera info
    final make = (exif['Make']?.toString() ?? '').trim();
    final model = (exif['Model']?.toString() ?? '').trim();
    final camera = [make, model].where((s) => s.isNotEmpty).join(' ');
    final lens = (exif['LensModel']?.toString() ?? '').trim();

    // Shooting parameters
    final focalLength = exif['FocalLength']?.toString() ?? '';
    final fNumber = exif['FNumber']?.toString() ?? '';
    final exposure = exif['ExposureTime']?.toString() ?? '';
    final iso = exif['ISOSpeedRatings']?.toString() ?? '';
    final params = <String>[
      if (focalLength.isNotEmpty) '${focalLength}mm',
      if (fNumber.isNotEmpty) 'f/$fNumber',
      if (exposure.isNotEmpty) '${exposure}s',
      if (iso.isNotEmpty) 'ISO $iso',
    ];

    // File size
    final sizeBytes = file['size'];
    final sizeDisplay = sizeBytes is num ? _formatFileSize(sizeBytes) : '';

    // File info line
    final fileParts = <String>[item.fileName];
    if (resolution.isNotEmpty) fileParts.add(resolution);
    if (sizeDisplay.isNotEmpty) fileParts.add(sizeDisplay);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Details', style: theme.textTheme.titleLarge),
            const SizedBox(height: 20),
            _MetadataRow(
              icon: Icons.calendar_today_outlined,
              label: 'Date & Time',
              value: dateDisplay,
            ),
            if (gpsLatLng != null) ...[
              _MetadataRow(
                icon: Icons.location_on_outlined,
                label: 'Location',
                value: gpsStr,
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: IgnorePointer(
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: gpsLatLng,
                        initialZoom: 13,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.none,
                        ),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: AppConfig.mapTileConfig('light')
                              .urlTemplate,
                          maxZoom: 18,
                          userAgentPackageName: 'blue_mobile',
                        ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: gpsLatLng,
                              width: 36,
                              height: 36,
                              child: Icon(
                                Icons.location_on,
                                color: theme.colorScheme.primary,
                                size: 36,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ] else if (gpsStr.isNotEmpty)
              _MetadataRow(
                icon: Icons.location_on_outlined,
                label: 'Location',
                value: gpsStr,
              ),
            if (camera.isNotEmpty)
              _MetadataRow(
                icon: Icons.camera_alt_outlined,
                label: 'Camera',
                value: camera,
              ),
            if (lens.isNotEmpty)
              _MetadataRow(
                icon: Icons.camera_outlined,
                label: 'Lens',
                value: lens,
              ),
            if (params.isNotEmpty)
              _MetadataRow(
                icon: Icons.tune_outlined,
                label: 'Settings',
                value: params.join('  '),
              ),
            _MetadataRow(
              icon: Icons.insert_drive_file_outlined,
              label: 'File',
              value: fileParts.join('  ·  '),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatFileSize(num bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 2),
                Text(value, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
