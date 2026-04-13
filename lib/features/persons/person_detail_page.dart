import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/breakpoints.dart';
import '../../core/widgets/fullscreen_image_viewer.dart';
import '../../core/widgets/protected_network_image.dart';
import '../../core/widgets/section_card.dart';
import '../../data/models/day_media_model.dart';
import '../../data/models/person_detail_payload_model.dart';
import '../../data/models/person_model.dart';
import '../../data/models/person_recognition_status_model.dart';
import '../../data/repositories/person_repository.dart';
import '../../providers.dart';

class PersonDetailPage extends ConsumerStatefulWidget {
  const PersonDetailPage({super.key, required this.person});

  final PersonModel person;

  @override
  ConsumerState<PersonDetailPage> createState() => _PersonDetailPageState();
}

class _PersonDetailPageState extends ConsumerState<PersonDetailPage> {
  static const _galleryPageSize = 24;

  PersonDetailPayloadModel? _payload;
  List<DayMediaModel> _galleryImages = const [];
  PersonRecognitionStatusModel? _recognition;
  bool _loading = true;
  bool _saving = false;
  bool _loadingMoreImages = false;
  bool _loadingRecognition = false;
  String? _error;
  String? _imagesError;
  String? _recognitionError;
  int _photoCacheBust = 0;
  int _imagePage = 1;
  int _imageTotalCount = 0;
  bool _imageHasNextPage = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading || _payload == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() => _error = null);
    }
    try {
      final payload = await ref
          .read(personRepositoryProvider)
          .loadDetail(_payload?.person ?? widget.person);
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _galleryImages = payload.images;
        _recognition = payload.recognition;
        _imagePage = 1;
        _imageTotalCount = payload.imageTotalCount;
        _imageHasNextPage = payload.imageHasNextPage;
        _imagesError = null;
        _recognitionError = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
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

  Future<void> _loadMoreImages() async {
    final payload = _payload;
    if (payload == null || _loadingMoreImages || !_imageHasNextPage) return;

    setState(() => _loadingMoreImages = true);
    try {
      final page = await ref
          .read(personRepositoryProvider)
          .loadPersonImagesPage(
            payload.person.id,
            page: _imagePage + 1,
            pageSize: _galleryPageSize,
          );
      if (!mounted) return;
      setState(() {
        _galleryImages = _mergeImages(_galleryImages, page.items);
        _imagePage = page.page;
        _imageTotalCount = page.totalCount;
        _imageHasNextPage = page.hasNextPage;
        _imagesError = null;
        _loadingMoreImages = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _imagesError = error.toString().replaceFirst('Exception: ', '');
        _loadingMoreImages = false;
      });
    }
  }

  Future<void> _refreshRecognition() async {
    final payload = _payload;
    if (payload == null || _loadingRecognition) return;

    setState(() {
      _loadingRecognition = true;
      _recognitionError = null;
    });
    try {
      final recognition = await ref
          .read(personRepositoryProvider)
          .loadRecognitionStatus(payload.person.id);
      if (!mounted) return;
      setState(() {
        _recognition = recognition;
        _recognitionError = null;
        _loadingRecognition = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _recognitionError = error.toString().replaceFirst('Exception: ', '');
        _loadingRecognition = false;
      });
    }
  }

  List<DayMediaModel> _mergeImages(
    List<DayMediaModel> current,
    List<DayMediaModel> incoming,
  ) {
    final seen = current.map((item) => item.path).toSet();
    final merged = List<DayMediaModel>.of(current);
    for (final image in incoming) {
      if (seen.add(image.path)) {
        merged.add(image);
      }
    }
    return merged;
  }

  Future<void> _editPerson() async {
    final person = _payload?.person;
    if (person == null) return;

    final updated = await showModalBottomSheet<PersonModel>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => _PersonEditorSheet(person: person),
    );

    if (!mounted || updated == null) return;

    setState(() => _saving = true);
    try {
      final saved = await ref.read(personRepositoryProvider).update(updated);
      if (!mounted) return;
      setState(() {
        _payload =
            (_payload ??
                    PersonDetailPayloadModel(
                      person: saved,
                      faces: const [],
                      images: const [],
                      recognition: PersonRecognitionStatusModel.empty(
                        personId: saved.id,
                      ),
                      imageTotalCount: 0,
                      imageHasNextPage: false,
                    ))
                .copyWith(person: saved);
        _saving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Person updated.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompactMobile = screenWidth < Breakpoints.compact;
    if (_loading && _payload == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null && _payload == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final payload = _payload!;
    final person = payload.person;
    final heroUrl = _heroUrl(payload);
    final stats = _stats(person);
    final contact = _contact(person);
    final authHeaders = _authHeaders();
    final notes = person.notes.trim();
    final recognition =
        _recognition ?? PersonRecognitionStatusModel.empty(personId: person.id);
    final heroHeader = _HeroHeader(
      person: person,
      imageUrl: heroUrl,
      headers: authHeaders,
      fallbackInitials: _initials(person),
      onPhotoTap: _pickAndUploadPhoto,
    );
    final tabsBar = _PersonTabBar(
      colorScheme: colorScheme,
      horizontalPadding: isCompactMobile ? 12 : 16,
      bottomPadding: isCompactMobile ? 8 : 10,
    );

    return DefaultTabController(
      length: 2,
      initialIndex: 1,
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) {
            if (isCompactMobile) {
              return [
                SliverAppBar(
                  pinned: true,
                  backgroundColor: colorScheme.surface,
                  foregroundColor: colorScheme.onSurface,
                  actions: [
                    IconButton(
                      onPressed: _saving ? null : _editPerson,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.edit_outlined),
                    ),
                  ],
                ),
                SliverToBoxAdapter(
                  child: _HeroSurface(
                    isDark: isDark,
                    colorScheme: colorScheme,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: heroHeader,
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _PinnedHeaderDelegate(child: tabsBar),
                ),
              ];
            }

            return [
              SliverAppBar(
                pinned: true,
                expandedHeight: _heroExpandedHeight(context, person),
                backgroundColor: colorScheme.surface,
                foregroundColor: colorScheme.onSurface,
                actions: [
                  IconButton(
                    onPressed: _saving ? null : _editPerson,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.edit_outlined),
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: _HeroSurface(
                    isDark: isDark,
                    colorScheme: colorScheme,
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 88),
                    child: heroHeader,
                  ),
                ),
                bottom: tabsBar,
              ),
            ];
          },
          body: TabBarView(
            children: [
              _OverviewTab(
                stats: stats,
                contact: contact,
                biography: person.biography.trim(),
                notes: notes,
                recognition: recognition,
                recognitionLoading: _loadingRecognition,
                recognitionError: _recognitionError,
                onRefreshRecognition: _refreshRecognition,
              ),
              _PhotosTab(
                images: _galleryImages,
                hasNextPage: _imageHasNextPage,
                isLoadingMore: _loadingMoreImages,
                loadError: _imagesError,
                totalCount: _imageTotalCount,
                onLoadMore: _loadMoreImages,
                headers: authHeaders,
                fetchImageInfo: ref.read(filesRepositoryProvider).getImageInfo,
                fetchImageFaces: ref.read(facesRepositoryProvider).getImageFaces,
                unlabelFace: ref.read(facesRepositoryProvider).unlabelFace,
                reassignFace: ref.read(facesRepositoryProvider).reassignFace,
                personRepository: ref.read(personRepositoryProvider),
                onOpenPerson: _openPersonFromViewer,
                onDelete: (path) =>
                    ref.read(filesRepositoryProvider).deleteFile(path),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _initials(PersonModel person) {
    String firstLetter(String value) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? '' : trimmed.substring(0, 1).toUpperCase();
    }

    final initials =
        '${firstLetter(person.firstName)}${firstLetter(person.lastName)}';
    return initials.isEmpty ? '?' : initials;
  }

  String? _heroUrl(PersonDetailPayloadModel payload) {
    final photo = payload.person.photoPath.trim();
    if (photo.isNotEmpty) {
      return '${AppConfig.backendUrl}/api/person/$photo?v=$_photoCacheBust';
    }
    for (final face in payload.faces) {
      if (face.isReference && face.cropPath.trim().isNotEmpty) {
        return AppConfig.faceCropUrlFromPath(face.cropPath.trim());
      }
    }
    for (final face in payload.faces) {
      if (face.cropPath.trim().isNotEmpty) {
        return AppConfig.faceCropUrlFromPath(face.cropPath.trim());
      }
    }
    for (final image in payload.images) {
      if (image.path.trim().isNotEmpty) {
        return AppConfig.imageUrlFromPath(image.path, date: image.date);
      }
    }
    return null;
  }

  Future<void> _pickAndUploadPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    final imageBytes = await picked.readAsBytes();
    if (!mounted) return;
    final navigator = Navigator.of(context);

    final croppedBytes = await navigator.push<Uint8List>(
      MaterialPageRoute<Uint8List>(
        fullscreenDialog: true,
        builder: (_) => _CropPage(imageBytes: imageBytes),
      ),
    );
    if (croppedBytes == null || !mounted) return;

    final personId = _payload?.person.id;
    if (personId == null) return;

    setState(() => _saving = true);
    try {
      final uploadResult = await ref
          .read(personRepositoryProvider)
          .uploadPhoto(personId, 'photo.jpg', croppedBytes);
      if (!mounted) return;
      setState(() {
        _payload = _payload?.copyWith(
          person: _payload!.person.copyWith(photoPath: uploadResult.photoPath),
        );
        _photoCacheBust++;
        _saving = false;
        imageCache.clear();
      });
      await _load(showLoading: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            uploadResult.message.isEmpty
                ? 'Photo updated.'
                : uploadResult.message,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  List<(String, String)> _stats(PersonModel person) {
    return [
      ('Relation', person.relation.trim()),
      ('Profession', person.profession.trim()),
      ('Studies', person.studyProgram.trim()),
      ('Languages', person.languages.trim()),
      ('Born', person.birthDate.trim()),
      ('Died', person.deathDate.trim()),
    ].where((entry) => entry.$2.isNotEmpty).toList();
  }

  List<(String, String)> _contact(PersonModel person) {
    return [
      ('Email', person.email.trim()),
      ('Phone', person.phone.trim()),
      ('Address', person.address.trim()),
    ].where((entry) => entry.$2.isNotEmpty).toList();
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

  double _heroExpandedHeight(BuildContext context, PersonModel person) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= Breakpoints.expanded) return 292;
    if (width >= Breakpoints.medium) return 272;
    final chipsPerRow = width >= Breakpoints.compact
        ? 3
        : width >= 360
        ? 2
        : 1;
    final chipRows = person.chips.isEmpty
        ? 0
        : (person.chips.length / chipsPerRow).ceil();
    final relationExtra = person.relation.trim().isEmpty ? 0 : 28;
    final nameExtra = person.displayName.trim().length > 22 ? 18 : 0;
    if (width >= Breakpoints.compact) {
      return 288 + relationExtra + (chipRows.clamp(0, 3) * 20);
    }
    return 228.0 +
        relationExtra.toDouble() +
        (chipRows.clamp(0, 2) * 16).toDouble() +
        (nameExtra / 2);
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.person,
    required this.imageUrl,
    required this.headers,
    required this.fallbackInitials,
    required this.onPhotoTap,
  });

  final PersonModel person;
  final String? imageUrl;
  final Map<String, String> headers;
  final String fallbackInitials;
  final VoidCallback onPhotoTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= Breakpoints.medium;
        final isCompactMobile = constraints.maxWidth < Breakpoints.compact;
        final avatar = GestureDetector(
          onTap: onPhotoTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _ProfileAvatar(
                imageUrl: imageUrl,
                headers: headers,
                fallback: fallbackInitials,
                size: isWide
                    ? 132
                    : isCompactMobile
                    ? 76
                    : 112,
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: colorScheme.surface, width: 2),
                  ),
                  child: const Icon(
                    Icons.camera_alt_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        );
        final content = _HeroDetails(
          person: person,
          centered: !isWide && !isCompactMobile,
          compact: isCompactMobile,
        );

        if (isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              avatar,
              const SizedBox(width: 22),
              Expanded(child: content),
            ],
          );
        }

        if (isCompactMobile) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              avatar,
              const SizedBox(width: 14),
              Expanded(child: content),
            ],
          );
        }

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            SizedBox(height: isCompactMobile ? 12 : 18),
            content,
          ],
        );
      },
    );
  }
}

class _HeroSurface extends StatelessWidget {
  const _HeroSurface({
    required this.isDark,
    required this.colorScheme,
    required this.padding,
    required this.child,
  });

  final bool isDark;
  final ColorScheme colorScheme;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  colorScheme.surfaceContainerHighest,
                  colorScheme.surfaceContainer,
                ]
              : [colorScheme.surface, colorScheme.primaryContainer],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

class _PersonTabBar extends StatelessWidget implements PreferredSizeWidget {
  const _PersonTabBar({
    required this.colorScheme,
    required this.horizontalPadding,
    required this.bottomPadding,
  });

  final ColorScheme colorScheme;
  final double horizontalPadding;
  final double bottomPadding;

  @override
  Size get preferredSize => Size.fromHeight(54 + bottomPadding);

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: colorScheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1232),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              0,
              horizontalPadding,
              bottomPadding,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: TabBar(
                dividerColor: Colors.transparent,
                labelColor: colorScheme.onSurface,
                unselectedLabelColor: colorScheme.onSurfaceVariant,
                indicatorColor: colorScheme.primary,
                indicatorWeight: 3,
                tabs: const [
                  Tab(text: 'Overview'),
                  Tab(text: 'Gallery'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedHeaderDelegate({required this.child});

  final PreferredSizeWidget child;

  @override
  double get minExtent => child.preferredSize.height;

  @override
  double get maxExtent => child.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _PinnedHeaderDelegate oldDelegate) {
    return oldDelegate.child != child;
  }
}

class _HeroDetails extends StatelessWidget {
  const _HeroDetails({
    required this.person,
    required this.centered,
    this.compact = false,
  });

  final PersonModel person;
  final bool centered;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          person.displayName,
          maxLines: compact ? 2 : (centered ? 2 : 1),
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style:
              (compact
                      ? theme.textTheme.titleLarge
                      : theme.textTheme.headlineSmall)
                  ?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w900,
                  ),
        ),
        if (person.relation.trim().isNotEmpty) ...[
          SizedBox(height: compact ? 4 : 6),
          Text(
            person.relation.trim(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: centered ? TextAlign.center : TextAlign.start,
            style:
                (compact
                        ? theme.textTheme.titleSmall
                        : theme.textTheme.titleMedium)
                    ?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
          ),
        ],
        if (person.chips.isNotEmpty) ...[
          SizedBox(height: compact ? 10 : 12),
          Align(
            alignment: centered ? Alignment.center : Alignment.centerLeft,
            child: Wrap(
              alignment: centered ? WrapAlignment.center : WrapAlignment.start,
              spacing: compact ? 6 : 8,
              runSpacing: compact ? 6 : 8,
              children: person.chips
                  .map(
                    (chip) => _HeroBadge(
                      label: chip,
                      centered: centered,
                      compact: compact,
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.stats,
    required this.contact,
    required this.biography,
    required this.notes,
    required this.recognition,
    required this.recognitionLoading,
    required this.recognitionError,
    required this.onRefreshRecognition,
  });

  final List<(String, String)> stats;
  final List<(String, String)> contact;
  final String biography;
  final String notes;
  final PersonRecognitionStatusModel recognition;
  final bool recognitionLoading;
  final String? recognitionError;
  final Future<void> Function() onRefreshRecognition;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isTwoColumn = constraints.maxWidth >= Breakpoints.expanded;
        final primary = <Widget>[
          _RecognitionCard(
            recognition: recognition,
            loading: recognitionLoading,
            error: recognitionError,
            onRefresh: onRefreshRecognition,
          ),
          if (stats.isNotEmpty)
            SectionCard(
              title: 'About',
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              child: _StatsGrid(stats: stats),
            ),
          if (biography.isNotEmpty)
            SectionCard(
              title: 'Story',
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              child: Text(
                biography,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurface,
                  height: 1.5,
                ),
              ),
            ),
          if (notes.isNotEmpty)
            SectionCard(
              title: 'Notes',
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              child: Text(
                notes,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                  height: 1.5,
                ),
              ),
            ),
        ];
        final secondary = <Widget>[
          if (contact.isNotEmpty)
            SectionCard(
              title: 'Contact',
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              child: Column(
                children: contact.map((row) {
                  final type = row.$1;
                  final value = row.$2;
                  if (type == 'Phone') {
                    return _ContactTile(
                      icon: Icons.phone_rounded,
                      label: type,
                      value: value,
                      onTap: () => launchUrl(Uri(scheme: 'tel', path: value)),
                    );
                  }
                  if (type == 'Email') {
                    return _ContactTile(
                      icon: Icons.email_rounded,
                      label: type,
                      value: value,
                      onTap: () =>
                          launchUrl(Uri(scheme: 'mailto', path: value)),
                    );
                  }
                  return _ContactTile(
                    icon: Icons.place_rounded,
                    label: type,
                    value: value,
                    onTap: () => launchUrl(
                      Uri.parse('geo:0,0?q=${Uri.encodeComponent(value)}'),
                    ),
                  );
                }).toList(),
              ),
            ),
        ];

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              children: [
                if (isTwoColumn)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _OverviewColumn(children: primary)),
                      const SizedBox(width: 16),
                      Expanded(child: _OverviewColumn(children: secondary)),
                    ],
                  )
                else
                  _OverviewColumn(children: [...primary, ...secondary]),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OverviewColumn extends StatelessWidget {
  const _OverviewColumn({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      children:
          children
              .expand((child) => [child, const SizedBox(height: 12)])
              .toList()
            ..removeLast(),
    );
  }
}

class _RecognitionCard extends StatelessWidget {
  const _RecognitionCard({
    required this.recognition,
    required this.loading,
    required this.error,
    required this.onRefresh,
  });

  final PersonRecognitionStatusModel recognition;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SectionCard(
      title: 'Recognition',
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _RecognitionPill(
                label: 'Reference Faces',
                value: '${recognition.referenceFaceCount}',
              ),
              _RecognitionPill(
                label: 'Linked Images',
                value: '${recognition.linkedImageCount}',
              ),
              _RecognitionPill(
                label: 'Candidate Images',
                value: '${recognition.candidateImageCount}',
              ),
              _RecognitionPill(
                label: 'Embedding',
                value: recognition.hasEmbedding ? 'Ready' : 'Missing',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Profile photo',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  recognition.profilePhotoMessage,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                if (recognition.profilePhotoError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Status: ${recognition.profilePhotoStatus}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: loading ? null : () => onRefresh(),
              icon: loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: const Text('Refresh recognition'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecognitionPill extends StatelessWidget {
  const _RecognitionPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});

  final List<(String, String)> stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= Breakpoints.medium
            ? 3
            : width >= Breakpoints.compact
            ? 2
            : 1;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: stats.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: 108,
          ),
          itemBuilder: (context, index) {
            final stat = stats[index];
            return _StatCard(label: stat.$1, value: stat.$2);
          },
        );
      },
    );
  }
}

class _PhotosFooter extends StatelessWidget {
  const _PhotosFooter({
    required this.totalCount,
    required this.loadedCount,
    required this.hasNextPage,
    required this.isLoadingMore,
    required this.loadError,
    required this.onRetry,
  });

  final int totalCount;
  final int loadedCount;
  final bool hasNextPage;
  final bool isLoadingMore;
  final String? loadError;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (isLoadingMore) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (loadError != null) {
      return SectionCard(
        title: 'Gallery loading',
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loadError!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.error,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => onRetry(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (hasNextPage) {
      return Center(
        child: Text(
          'Loaded $loadedCount${totalCount > 0 ? ' of $totalCount' : ''}. Scroll for more.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Center(
      child: Text(
        totalCount > 0
            ? 'Showing all $totalCount photos.'
            : 'No more photos to load.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _PhotosTab extends StatelessWidget {
  const _PhotosTab({
    required this.images,
    required this.hasNextPage,
    required this.isLoadingMore,
    required this.loadError,
    required this.totalCount,
    required this.onLoadMore,
    required this.headers,
    required this.fetchImageInfo,
    required this.fetchImageFaces,
    required this.unlabelFace,
    required this.reassignFace,
    required this.personRepository,
    required this.onOpenPerson,
    this.onDelete,
  });

  final List<DayMediaModel> images;
  final bool hasNextPage;
  final bool isLoadingMore;
  final String? loadError;
  final int totalCount;
  final Future<void> Function() onLoadMore;
  final Map<String, String> headers;
  final ImageInfoFetcher fetchImageInfo;
  final ImageFacesFetcher fetchImageFaces;
  final FaceUnlabeler unlabelFace;
  final FaceReassigner reassignFace;
  final PersonRepository personRepository;
  final OpenPerson onOpenPerson;
  final ImageDeleter? onDelete;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            children: const [
              SectionCard(
                title: 'Photos',
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('No photos linked to this person yet.'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width >= Breakpoints.expanded
                ? 4
                : width >= Breakpoints.medium
                ? 3
                : width >= Breakpoints.compact
                ? 2
                : 1;
            final aspectRatio = width >= Breakpoints.expanded
                ? 1.02
                : width >= Breakpoints.medium
                ? 0.96
                : width >= Breakpoints.compact
                ? 0.92
                : 1.18;

            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (loadError == null &&
                    hasNextPage &&
                    notification.metrics.pixels >=
                        notification.metrics.maxScrollExtent - 320) {
                  onLoadMore();
                }
                return false;
              },
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: aspectRatio,
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final image = images[index];
                        final imageUrl = AppConfig.imageUrlFromPath(
                          image.path,
                          date: image.date,
                        );
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: () {
                              final items = images
                                  .map(
                                    (m) => ImageViewerItem(
                                      fullUrl: AppConfig.imageUrlFromPath(
                                        m.path,
                                        date: m.date,
                                      ),
                                      thumbnailUrl: AppConfig.imageUrlFromPath(
                                        m.path,
                                        date: m.date,
                                      ),
                                      fileName: m.fileName,
                                      path: m.path,
                                      date: m.date,
                                      gps: m.gps,
                                      favorite: m.favorite,
                                    ),
                                  )
                                  .toList();
                              FullscreenImageViewer.show(
                                context: context,
                                images: items,
                                initialIndex: index,
                                httpHeaders: headers,
                                fetchImageInfo: fetchImageInfo,
                                fetchImageFaces: fetchImageFaces,
                                unlabelFace: unlabelFace,
                                reassignFace: reassignFace,
                                personRepository: personRepository,
                                onOpenPerson: onOpenPerson,
                                onDelete: onDelete,
                              );
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  _AuthenticatedImage(
                                    imageUrl: imageUrl,
                                    headers: headers,
                                    fit: BoxFit.cover,
                                    errorWidget: Container(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                      alignment: Alignment.center,
                                      child: Icon(
                                        Icons.image_not_supported_outlined,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.black.withValues(alpha: 0.02),
                                          Colors.black.withValues(alpha: 0.08),
                                          Colors.black.withValues(alpha: 0.44),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 12,
                                    right: 12,
                                    bottom: 12,
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            image.fileName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(
                                              alpha: 0.18,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            image.date,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }, childCount: images.length),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                      child: _PhotosFooter(
                        totalCount: totalCount,
                        loadedCount: images.length,
                        hasNextPage: hasNextPage,
                        isLoadingMore: isLoadingMore,
                        loadError: loadError,
                        onRetry: onLoadMore,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PersonEditorSheet extends StatefulWidget {
  const _PersonEditorSheet({required this.person});

  final PersonModel person;

  @override
  State<_PersonEditorSheet> createState() => _PersonEditorSheetState();
}

class _PersonEditorSheetState extends State<_PersonEditorSheet> {
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _relation;
  late final TextEditingController _profession;
  late final TextEditingController _birthDate;
  late final TextEditingController _deathDate;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _languages;
  late final TextEditingController _studyProgram;
  late final TextEditingController _biography;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    final person = widget.person;
    _firstName = TextEditingController(text: person.firstName);
    _lastName = TextEditingController(text: person.lastName);
    _relation = TextEditingController(text: person.relation);
    _profession = TextEditingController(text: person.profession);
    _birthDate = TextEditingController(text: person.birthDate);
    _deathDate = TextEditingController(text: person.deathDate);
    _email = TextEditingController(text: person.email);
    _phone = TextEditingController(text: person.phone);
    _address = TextEditingController(text: person.address);
    _languages = TextEditingController(text: person.languages);
    _studyProgram = TextEditingController(text: person.studyProgram);
    _biography = TextEditingController(text: person.biography);
    _notes = TextEditingController(text: person.notes);
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _relation.dispose();
    _profession.dispose();
    _birthDate.dispose();
    _deathDate.dispose();
    _email.dispose();
    _phone.dispose();
    _address.dispose();
    _languages.dispose();
    _studyProgram.dispose();
    _biography.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 18, 18, 24 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit person',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 18),
            _FormRow(
              children: [
                _EditorField(controller: _firstName, label: 'First name'),
                _EditorField(controller: _lastName, label: 'Last name'),
              ],
            ),
            _FormRow(
              children: [
                _EditorField(controller: _relation, label: 'Relation'),
                _EditorField(controller: _profession, label: 'Occupation'),
              ],
            ),
            _FormRow(
              children: [
                _EditorField(controller: _birthDate, label: 'Birth date'),
                _EditorField(controller: _deathDate, label: 'Death date'),
              ],
            ),
            _FormRow(
              children: [
                _EditorField(controller: _email, label: 'Email'),
                _EditorField(controller: _phone, label: 'Phone'),
              ],
            ),
            _EditorField(controller: _address, label: 'Address'),
            const SizedBox(height: 12),
            _FormRow(
              children: [
                _EditorField(controller: _languages, label: 'Languages'),
                _EditorField(controller: _studyProgram, label: 'Studies'),
              ],
            ),
            _EditorField(
              controller: _biography,
              label: 'Biography',
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            _EditorField(
              controller: _notes,
              label: 'Important notes',
              maxLines: 3,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        widget.person.copyWith(
                          firstName: _firstName.text.trim(),
                          lastName: _lastName.text.trim(),
                          relation: _relation.text.trim(),
                          profession: _profession.text.trim(),
                          birthDate: _birthDate.text.trim(),
                          deathDate: _deathDate.text.trim(),
                          email: _email.text.trim(),
                          phone: _phone.text.trim(),
                          address: _address.text.trim(),
                          languages: _languages.text.trim(),
                          studyProgram: _studyProgram.text.trim(),
                          biography: _biography.text.trim(),
                          notes: _notes.text.trim(),
                        ),
                      );
                    },
                    child: const Text('Save changes'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FormRow extends StatelessWidget {
  const _FormRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.sizeOf(context).width < Breakpoints.compact;
    if (isNarrow) {
      return Column(
        children:
            children
                .expand((child) => [child, const SizedBox(height: 12)])
                .toList()
              ..removeLast(),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(child: children.first),
          const SizedBox(width: 12),
          Expanded(child: children.last),
        ],
      ),
    );
  }
}

class _EditorField extends StatelessWidget {
  const _EditorField({
    required this.controller,
    required this.label,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      decoration: InputDecoration(labelText: label),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.imageUrl,
    required this.headers,
    required this.fallback,
    this.size = 116,
  });

  final String? imageUrl;
  final Map<String, String> headers;
  final String fallback;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.surfaceContainerHighest,
        border: Border.all(color: colorScheme.surface, width: 4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl == null || imageUrl!.isEmpty
          ? _AvatarFallback(text: fallback)
          : _AuthenticatedImage(
              imageUrl: imageUrl!,
              headers: headers,
              fit: BoxFit.cover,
              errorWidget: _AvatarFallback(text: fallback),
            ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colorScheme.primaryContainer,
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: colorScheme.onPrimaryContainer,
            fontSize: 36,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _HeroBadge extends StatelessWidget {
  const _HeroBadge({
    required this.label,
    this.centered = false,
    this.compact = false,
  });

  final String label;
  final bool centered;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final maxWidth =
        MediaQuery.sizeOf(context).width *
        (compact ? (centered ? 0.82 : 0.54) : (centered ? 0.72 : 0.46));
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth.clamp(120.0, 220.0)),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 12,
          vertical: compact ? 6 : 8,
        ),
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style:
              (compact
                      ? Theme.of(context).textTheme.labelMedium
                      : Theme.of(context).textTheme.labelLarge)
                  ?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthenticatedImage extends StatelessWidget {
  const _AuthenticatedImage({
    required this.imageUrl,
    required this.headers,
    required this.fit,
    required this.errorWidget,
  });

  final String imageUrl;
  final Map<String, String> headers;
  final BoxFit fit;
  final Widget errorWidget;

  @override
  Widget build(BuildContext context) {
    return ProtectedNetworkImage(
      imageUrl: imageUrl,
      headers: headers,
      fit: fit,
      errorWidget: errorWidget,
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tappable = onTap != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: tappable
                        ? colorScheme.primary.withValues(alpha: 0.12)
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: tappable
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: tappable
                              ? colorScheme.primary
                              : colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (tappable)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CropPage extends StatefulWidget {
  const _CropPage({required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<_CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<_CropPage> {
  final _controller = CropController();
  bool _cropping = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Crop photo'),
        actions: [
          _cropping
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.check_rounded),
                  onPressed: () {
                    setState(() => _cropping = true);
                    _controller.crop();
                  },
                ),
        ],
      ),
      body: Crop(
        image: widget.imageBytes,
        controller: _controller,
        aspectRatio: 1,
        withCircleUi: true,
        interactive: true,
        fixCropRect: true,
        baseColor: Colors.black,
        maskColor: Colors.black.withValues(alpha: 0.7),
        cornerDotBuilder: (_, __) => const SizedBox.shrink(),
        onCropped: (croppedBytes) {
          Navigator.of(context).pop(croppedBytes);
        },
      ),
    );
  }
}
