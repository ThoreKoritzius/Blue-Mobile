import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/date_format.dart';
import '../../core/widgets/section_card.dart';
import '../../data/models/calendar_event_model.dart';
import '../../data/models/day_media_model.dart';
import '../../data/models/day_payload_model.dart';
import '../../data/models/person_model.dart';
import '../../data/models/run_model.dart';
import '../../data/models/story_day_model.dart';
import '../../data/repositories/person_repository.dart';
import '../../providers.dart';
import '../persons/person_detail_page.dart';
import '../runs/run_detail_page.dart';

class DayPage extends ConsumerStatefulWidget {
  const DayPage({super.key});

  @override
  ConsumerState<DayPage> createState() => _DayPageState();
}

class _DayPageState extends ConsumerState<DayPage> {
  static const _defaultHeroAccent = Color(0xFF174EA6);
  static const _maxDayCacheEntries = 7;
  static const _loadDebounce = Duration(milliseconds: 90);
  static const _navigationBurstWindow = Duration(milliseconds: 260);

  late final TextEditingController _place;
  late final TextEditingController _country;
  late final TextEditingController _description;
  late final TextEditingController _tagInput;
  late final ScrollController _scrollController;
  late final ProviderSubscription<DateTime> _selectedDateSubscription;

  final Map<String, DayPayloadModel> _dayCache = <String, DayPayloadModel>{};
  final List<String> _cacheOrder = <String>[];

  Timer? _pendingLoadTimer;
  StoryDayModel? _original;
  StoryDayModel? _current;
  List<DayMediaModel> _media = const [];
  List<RunModel> _runs = const [];
  List<CalendarEventModel> _events = const [];

  bool _loading = true;
  bool _saving = false;
  bool _transitioningDay = false;
  bool _detailsLoading = false;
  bool _heroPickerEnabled = false;
  bool _syncingControllers = false;
  String _status = '';
  int _activeLoadId = 0;
  String? _activeDayKey;
  String? _pendingSyncDayKey;
  DateTime _lastNavigationAt = DateTime.fromMillisecondsSinceEpoch(0);
  Color _heroAccent = _defaultHeroAccent;
  String? _paletteSourceUrl;
  _HeroImageAsset? _heroAsset;

  @override
  void initState() {
    super.initState();
    _place = TextEditingController();
    _country = TextEditingController();
    _description = TextEditingController();
    _tagInput = TextEditingController();
    _scrollController = ScrollController();

    _place.addListener(_syncForm);
    _country.addListener(_syncForm);
    _description.addListener(_syncForm);
    _selectedDateSubscription = ref.listenManual<DateTime>(
      selectedDateProvider,
      (previous, next) {
        final nextDay = formatYmd(DateUtils.dateOnly(next));
        if (nextDay == _activeDayKey) return;
        _scheduleLoadForDate(next);
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDate(ref.read(selectedDateProvider));
    });
  }

  @override
  void dispose() {
    _place.dispose();
    _country.dispose();
    _description.dispose();
    _tagInput.dispose();
    _pendingLoadTimer?.cancel();
    _scrollController.dispose();
    _selectedDateSubscription.close();
    super.dispose();
  }

  bool get _dirty {
    final current = _current;
    final original = _original;
    if (current == null || original == null) return false;
    return current.place != original.place ||
        current.country != original.country ||
        current.names != original.names ||
        current.keywords != original.keywords ||
        current.description != original.description ||
        current.highlightImage != original.highlightImage;
  }

  void _syncForm() {
    if (_syncingControllers) return;
    final model = _current;
    if (model == null) return;
    setState(() {
      _current = model.copyWith(
        place: _place.text.trim(),
        country: _country.text.trim(),
        description: _description.text,
      );
    });
  }

  Future<void> _loadDate(DateTime date) async {
    final normalized = DateUtils.dateOnly(date);
    final day = formatYmd(normalized);
    final requestId = ++_activeLoadId;
    _activeDayKey = day;
    _lastNavigationAt = DateTime.now();

    final cached = _cacheGet(day);
    if (cached != null) {
      _applyVisiblePayload(
        cached,
        detailsLoaded: cached.detailsLoaded,
        clearStatus: true,
      );
      setState(() {
        _loading = false;
        _transitioningDay = false;
        _detailsLoading = !cached.detailsLoaded;
      });
      if (!_isRapidNavigation()) {
        _schedulePostApplyWork(
          day,
          requestId,
          cached,
          includeFullHero: false,
          prefetchAdjacent: false,
        );
        unawaited(_refreshDate(normalized, requestId));
      }
      return;
    }

    setState(() {
      _loading = _current == null;
      _transitioningDay = _current != null;
      _detailsLoading = true;
      _status = '';
    });
    await _refreshDate(normalized, requestId);
  }

  Future<void> _refreshDate(DateTime date, int requestId) async {
    final day = formatYmd(date);

    try {
      final payload = await ref
          .read(dayRepositoryProvider)
          .getDayCorePayload(day);
      _cachePut(day, payload);

      if (_isActiveRequest(requestId, day)) {
        _applyVisiblePayload(
          payload,
          detailsLoaded: payload.detailsLoaded,
          clearStatus: true,
        );
        setState(() {
          _loading = false;
          _transitioningDay = false;
          _detailsLoading = true;
        });
        _schedulePostApplyWork(
          day,
          requestId,
          payload,
          includeFullHero: true,
          prefetchAdjacent: true,
        );
      }
    } catch (error) {
      if (_isActiveRequest(requestId, day) && mounted) {
        setState(() {
          _status = error.toString().replaceFirst('Exception: ', '');
          _loading = false;
          _transitioningDay = false;
          _detailsLoading = false;
        });
      }
    }
  }

  bool _isActiveRequest(int requestId, String day) {
    return mounted && _activeLoadId == requestId && _activeDayKey == day;
  }

  bool _isRapidNavigation() {
    return DateTime.now().difference(_lastNavigationAt) <
        _navigationBurstWindow;
  }

  void _scheduleLoadForDate(DateTime date) {
    final normalized = DateUtils.dateOnly(date);
    final day = formatYmd(normalized);
    final cached = _dayCache[day];

    _pendingLoadTimer?.cancel();
    if (cached != null) {
      unawaited(_loadDate(normalized));
      return;
    }

    _pendingLoadTimer = Timer(_loadDebounce, () {
      if (!mounted) return;
      unawaited(_loadDate(normalized));
    });
  }

  Future<void> _loadCalendarEvents(String day, int requestId) async {
    try {
      final events = await ref
          .read(calendarRepositoryProvider)
          .eventsForDate(day);
      final cached = _cacheGet(day);
      if (cached != null) {
        _cachePut(day, cached.copyWith(events: events, detailsLoaded: true));
      }
      if (_isActiveRequest(requestId, day) && mounted) {
        setState(() {
          _events = events;
          _detailsLoading = false;
        });
      }
    } catch (_) {
      if (_isActiveRequest(requestId, day) && mounted) {
        setState(() {
          _detailsLoading = false;
        });
      }
    }
  }

  void _schedulePostApplyWork(
    String day,
    int requestId,
    DayPayloadModel payload, {
    required bool includeFullHero,
    required bool prefetchAdjacent,
  }) {
    unawaited(_updateHeroPalette(payload, day, requestId));
    unawaited(
      _precacheDayImages(
        payload,
        day: day,
        requestId: requestId,
        includeFullHero: includeFullHero,
      ),
    );
    unawaited(_loadCalendarEvents(day, requestId));
    if (prefetchAdjacent && !_isRapidNavigation()) {
      unawaited(_prefetchAdjacentDays(DateUtils.dateOnly(parseYmd(day))));
    }
  }

  void _applyVisiblePayload(
    DayPayloadModel payload, {
    required bool detailsLoaded,
    bool clearStatus = false,
  }) {
    _syncingControllers = true;
    _place.text = payload.story.place;
    _country.text = payload.story.country;
    _description.text = payload.story.description;
    _syncingControllers = false;

    final heroAsset = _resolveHeroAssetForModel(payload.story, payload.media);

    if (!mounted) return;
    setState(() {
      _original = payload.story;
      _current = payload.story;
      _media = payload.media;
      _runs = payload.runs;
      _events = detailsLoaded ? payload.events : const [];
      _heroAsset = heroAsset;
      if (clearStatus) {
        _status = '';
      }
    });
  }

  void _cachePut(String day, DayPayloadModel payload) {
    _dayCache[day] = payload;
    _cacheOrder.remove(day);
    _cacheOrder.add(day);
    while (_cacheOrder.length > _maxDayCacheEntries) {
      final oldest = _cacheOrder.removeAt(0);
      _dayCache.remove(oldest);
    }
  }

  DayPayloadModel? _cacheGet(String day) {
    final payload = _dayCache[day];
    if (payload == null) return null;
    _cacheOrder.remove(day);
    _cacheOrder.add(day);
    return payload;
  }

  void _cacheUpdate(
    String day,
    DayPayloadModel Function(DayPayloadModel payload) update,
  ) {
    final existing = _dayCache[day];
    if (existing == null) return;
    _cachePut(day, update(existing));
  }

  Future<void> _prefetchAdjacentDays(DateTime date) async {
    if (_isRapidNavigation()) return;
    for (final delta in const [-1, 1]) {
      unawaited(_prefetchDate(date.add(Duration(days: delta))));
    }
  }

  Future<void> _prefetchDate(DateTime date) async {
    if (!mounted) return;
    final day = formatYmd(DateUtils.dateOnly(date));
    final cached = _dayCache[day];
    if (cached != null && cached.detailsLoaded) {
      await _precacheDayImages(
        cached,
        day: day,
        requestId: _activeLoadId,
        includeFullHero: false,
      );
      return;
    }

    try {
      final payload = await ref
          .read(dayRepositoryProvider)
          .getDayCorePayload(day);
      _cachePut(day, payload);
      final events = await ref
          .read(calendarRepositoryProvider)
          .eventsForDate(day);
      _cachePut(day, payload.copyWith(events: events, detailsLoaded: true));
      await _precacheDayImages(
        payload,
        day: day,
        requestId: _activeLoadId,
        includeFullHero: false,
      );
    } catch (_) {}
  }

  Future<void> _precacheDayImages(
    DayPayloadModel payload, {
    required String day,
    required int requestId,
    required bool includeFullHero,
  }) async {
    if (!_isActiveRequest(requestId, day)) return;
    final heroAsset = _resolveHeroAssetForModel(payload.story, payload.media);
    final preview = heroAsset?.previewUrl;
    if (preview != null && preview.isNotEmpty) {
      await _safePrecache(preview);
    }
    final full = heroAsset?.fullUrl;
    if (includeFullHero &&
        full != null &&
        full.isNotEmpty &&
        full != heroAsset?.previewUrl) {
      await _safePrecache(full);
    }
  }

  Future<void> _safePrecache(String url) async {
    if (!mounted || url.isEmpty) return;
    try {
      await precacheImage(
        CachedNetworkImageProvider(url, headers: _authHeaders()),
        context,
      );
    } catch (_) {}
  }

  Future<void> _changeDate() async {
    final selected = await _showCalendarDialog(ref.read(selectedDateProvider));
    if (selected == null) return;
    await _setDate(selected);
  }

  Future<void> _setDate(DateTime date) async {
    final normalized = DateUtils.dateOnly(date);
    ref.read(selectedDateProvider.notifier).state = normalized;
  }

  Future<void> _shiftDay(int delta) async {
    final current = DateUtils.dateOnly(ref.read(selectedDateProvider));
    final target = current.add(Duration(days: delta));
    await _setDate(target);
  }

  Future<DateTime?> _showCalendarDialog(DateTime initialDate) {
    var focusedDay = DateUtils.dateOnly(initialDate);
    var selectedDay = DateUtils.dateOnly(initialDate);
    final now = DateUtils.dateOnly(DateTime.now());

    return showDialog<DateTime>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 24,
              ),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFF7FAFF), Color(0xFFEAF2FF)],
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x24000000),
                      blurRadius: 32,
                      offset: Offset(0, 18),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Choose date',
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Calendar',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TableCalendar<void>(
                      firstDay: DateTime(2005),
                      lastDay: now.add(const Duration(days: 365)),
                      focusedDay: focusedDay,
                      currentDay: now,
                      selectedDayPredicate: (day) =>
                          isSameDay(day, selectedDay),
                      headerStyle: const HeaderStyle(
                        titleCentered: true,
                        formatButtonVisible: false,
                      ),
                      calendarStyle: CalendarStyle(
                        todayDecoration: BoxDecoration(
                          color: const Color(0xFFE3EEFF),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        selectedDecoration: BoxDecoration(
                          color: const Color(0xFF174EA6),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        weekendTextStyle: const TextStyle(
                          color: Color(0xFF4D6B97),
                        ),
                        outsideTextStyle: const TextStyle(
                          color: Color(0xFF9DAAC0),
                        ),
                        defaultTextStyle: const TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      daysOfWeekStyle: const DaysOfWeekStyle(
                        weekendStyle: TextStyle(color: Color(0xFF4D6B97)),
                      ),
                      onDaySelected: (selected, focused) {
                        setDialogState(() {
                          selectedDay = DateUtils.dateOnly(selected);
                          focusedDay = DateUtils.dateOnly(focused);
                        });
                      },
                      onPageChanged: (focused) {
                        setDialogState(() {
                          focusedDay = DateUtils.dateOnly(focused);
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(selectedDay),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF174EA6),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: Text(
                          'Open ${DateFormat('d MMMM y').format(selectedDay)}',
                        ),
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

  void _removePerson(String name) {
    if (_current == null) return;
    final people = [..._current!.people]..remove(name);
    setState(() => _current = _current!.copyWith(names: people.join(';')));
  }

  bool _appendPersonName(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty || _current == null) return false;
    final people = [..._current!.people];
    if (people.any((item) => item.toLowerCase() == normalized.toLowerCase())) {
      return false;
    }
    setState(() {
      _current = _current!.copyWith(names: [...people, normalized].join(';'));
    });
    return true;
  }

  Future<void> _showAddPersonSheet() async {
    final selectedNames = _current?.people ?? const <String>[];
    final selected = await showModalBottomSheet<PersonModel>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFFF7FAFE),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => _AddPersonSheet(
        repository: ref.read(personRepositoryProvider),
        selectedNames: selectedNames,
      ),
    );
    if (!mounted || selected == null) return;
    final added = _appendPersonName(selected.displayName);
    if (added) {
      await _save();
    }
  }

  Future<void> _openPersonFromName(String name) async {
    final query = name.trim();
    if (query.isEmpty) return;

    try {
      final matches = await ref.read(personRepositoryProvider).search(query);
      if (!mounted) return;
      if (matches.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No saved person found for "$query".')),
        );
        return;
      }

      final bestMatch = _pickBestPersonMatch(query, matches);
      if (bestMatch != null) {
        _openPersonDetail(bestMatch);
        return;
      }

      if (matches.length == 1) {
        _openPersonDetail(matches.first);
        return;
      }

      final selected = await showModalBottomSheet<PersonModel>(
        context: context,
        backgroundColor: const Color(0xFFF7FAFE),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (context) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose a person',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF173B68),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Several saved people match "$query".',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF506882),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: matches.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final person = matches[index];
                        final subtitle = [
                          person.relation.trim(),
                          person.profession.trim(),
                        ].where((part) => part.isNotEmpty).join(' · ');
                        return Material(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            title: Text(
                              person.displayName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: subtitle.isEmpty ? null : Text(subtitle),
                            trailing: const Icon(
                              Icons.arrow_forward_ios_rounded,
                            ),
                            onTap: () => Navigator.of(context).pop(person),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (!mounted || selected == null) return;
      _openPersonDetail(selected);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  PersonModel? _pickBestPersonMatch(String query, List<PersonModel> matches) {
    final normalized = query.trim().toLowerCase();
    for (final person in matches) {
      if (person.displayName.trim().toLowerCase() == normalized) {
        return person;
      }
    }
    for (final person in matches) {
      if (person.firstName.trim().toLowerCase() == normalized) {
        return person;
      }
    }
    return null;
  }

  void _openPersonDetail(PersonModel person) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PersonDetailPage(person: person)),
    );
  }

  void _addTag() {
    final value = _tagInput.text.trim();
    if (value.isEmpty || _current == null) return;

    final tags = [..._current!.tags, value];
    setState(() {
      _current = _current!.copyWith(keywords: tags.join(';'));
      _tagInput.clear();
    });
  }

  void _removeTag(String tag) {
    if (_current == null) return;
    final tags = [..._current!.tags]..remove(tag);
    setState(() => _current = _current!.copyWith(keywords: tags.join(';')));
  }

  Future<void> _save() async {
    final model = _current;
    if (model == null) return;

    setState(() {
      _saving = true;
      _status = '';
    });

    try {
      await ref.read(storiesRepositoryProvider).saveDay(model);
      _cacheUpdate(model.date, (payload) => payload.copyWith(story: model));
      setState(() {
        _original = model;
        _status = 'Saved ${DateFormat('HH:mm').format(DateTime.now())}';
      });
    } catch (error) {
      setState(() {
        _status =
            'Save failed: ${error.toString().replaceFirst('Exception: ', '')}';
      });
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _uploadFiles() async {
    final date = formatYmd(ref.read(selectedDateProvider));
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;

    setState(() {
      _status = 'Uploading ${picked.files.length} files...';
    });

    try {
      final files = picked.files
          .where((item) => item.path != null)
          .map((item) => File(item.path!))
          .toList();
      await ref.read(filesRepositoryProvider).uploadFiles(date, files);
      _dayCache.remove(date);
      _cacheOrder.remove(date);
      await _loadDate(ref.read(selectedDateProvider));
      setState(() => _status = 'Upload complete');
    } catch (error) {
      setState(
        () => _status =
            'Upload failed: ${error.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  Future<void> _setHighlight(DayMediaModel media) async {
    if (_current == null) return;
    _dismissKeyboard();
    final current = _current!;
    if (_isSelectedMedia(current, media)) return;

    final previousModel = current;
    final previousHeroAsset = _heroAsset;
    final nextModel = previousModel.copyWith(highlightImage: media.path);
    final nextHeroAsset = _resolveHeroAssetForModel(nextModel, _media);

    setState(() {
      _current = nextModel;
      _heroAsset = nextHeroAsset;
      _status = 'Updating hero...';
    });
    await _updateHeroPalette(
      DayPayloadModel(
        story: nextModel,
        media: _media,
        runs: _runs,
        events: _events,
        detailsLoaded: _events.isNotEmpty,
      ),
      nextModel.date,
      _activeLoadId,
    );

    try {
      await ref.read(filesRepositoryProvider).updateHighlight(media.path);
      _cacheUpdate(
        nextModel.date,
        (payload) => payload.copyWith(story: nextModel),
      );
      setState(() {
        _original = _original?.copyWith(highlightImage: media.path);
        _status = 'Hero updated';
        _heroPickerEnabled = false;
      });
      await _scrollToTop();
    } catch (error) {
      setState(() {
        _current = previousModel;
        _heroAsset = previousHeroAsset;
        _status =
            'Failed to update highlight: ${error.toString().replaceFirst('Exception: ', '')}';
      });
      await _updateHeroPalette(
        DayPayloadModel(
          story: previousModel,
          media: _media,
          runs: _runs,
          events: _events,
          detailsLoaded: _events.isNotEmpty,
        ),
        previousModel.date,
        _activeLoadId,
      );
    }
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _showImagePreview(DayMediaModel media) async {
    _dismissKeyboard();
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(18),
          backgroundColor: Colors.transparent,
          child: CachedNetworkImage(
            imageUrl: _galleryFullUrl(media),
            fit: BoxFit.contain,
            httpHeaders: _authHeaders(),
            errorWidget: (_, __, ___) => Container(
              height: 260,
              color: Colors.white,
              child: const Center(child: Icon(Icons.broken_image_outlined)),
            ),
          ),
        );
      },
    );
    _dismissKeyboard();
  }

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients) return;
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _updateHeroPalette(
    DayPayloadModel payload,
    String day,
    int requestId,
  ) async {
    final heroAsset = _resolveHeroAssetForModel(payload.story, payload.media);
    final normalized =
        (heroAsset?.previewUrl == null || heroAsset!.previewUrl.isEmpty)
        ? null
        : heroAsset.previewUrl;
    _paletteSourceUrl = normalized == null ? null : '$day|$normalized';

    if (normalized == null) {
      if (!_isActiveRequest(requestId, day) || !mounted) return;
      setState(() {
        _heroAccent = _defaultHeroAccent;
      });
      ref.read(dayAppBarAccentProvider.notifier).state = _heroAccent;
      return;
    }

    try {
      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(normalized, headers: _authHeaders()),
        size: const Size(96, 96),
        maximumColorCount: 12,
      );
      if (!mounted || !_isActiveRequest(requestId, day)) return;
      if (_paletteSourceUrl != '$day|$normalized') return;
      final candidate =
          palette.vibrantColor?.color ??
          palette.dominantColor?.color ??
          palette.mutedColor?.color;
      if (candidate == null) return;
      final nextAccent = Color.lerp(candidate, Colors.black, 0.18) ?? candidate;
      setState(() {
        _heroAccent = nextAccent;
      });
      ref.read(dayAppBarAccentProvider.notifier).state = nextAccent;
    } catch (_) {
      if (!mounted || !_isActiveRequest(requestId, day)) return;
      if (_paletteSourceUrl != '$day|$normalized') return;
      setState(() {
        _heroAccent = _defaultHeroAccent;
      });
      ref.read(dayAppBarAccentProvider.notifier).state = _heroAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = ref.watch(selectedDateProvider);
    final model = _current;
    final selectedDayKey = formatYmd(DateUtils.dateOnly(date));

    if (selectedDayKey != _activeDayKey &&
        selectedDayKey != _pendingSyncDayKey) {
      _pendingSyncDayKey = selectedDayKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_pendingSyncDayKey != selectedDayKey) return;
        _pendingSyncDayKey = null;
        unawaited(_loadDate(date));
      });
    }

    if (_loading && model == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (model == null) {
      return Center(child: Text(_status.isEmpty ? 'No data' : _status));
    }

    final placeLine = [
      model.place.trim(),
      model.country.trim(),
    ].where((part) => part.isNotEmpty).join(', ');
    final now = DateUtils.dateOnly(DateTime.now());
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return GestureDetector(
      onTap: _dismissKeyboard,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -220) {
          _shiftDay(1);
        } else if (velocity > 220) {
          _shiftDay(-1);
        }
      },
      child: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => _loadDate(date),
            child: ListView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(16, 16, 16, 28 + bottomInset),
              children: [
                _buildHeroCard(
                  context,
                  date: date,
                  placeLine: placeLine,
                  canGoForward: !date.isAfter(
                    now.subtract(const Duration(days: 1)),
                  ),
                ),
                const SizedBox(height: 12),
                _buildOverviewCard(context),
                const SizedBox(height: 12),
                TextField(
                  controller: _description,
                  maxLines: 11,
                  onTapOutside: (_) => _dismissKeyboard(),
                  decoration: const InputDecoration(
                    alignLabelWithHint: true,
                    hintText:
                        'Write the atmosphere of the day, what surprised you, who you met, what stayed with you...',
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'People met',
                  action: IconButton.filledTonal(
                    onPressed: _showAddPersonSheet,
                    icon: const Icon(Icons.add_rounded),
                    tooltip: 'Add person',
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFFE8F0FF),
                      foregroundColor: const Color(0xFF1D4F91),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                  child: _buildPeopleEditor(context, model.people),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Tags',
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                  child: _buildChipEditor(
                    controller: _tagInput,
                    hint: 'Add a tag',
                    items: model.tags,
                    onAdd: _addTag,
                    onDelete: _removeTag,
                    chipColor: const Color(0xFFDCEBFF),
                    textColor: const Color(0xFF184A93),
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Runs & events',
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                  child: _buildRunsEventsSection(context),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Gallery',
                  action: FilledButton.tonalIcon(
                    onPressed: _uploadFiles,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('Upload'),
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                  child: _media.isEmpty
                      ? _buildEmptyState(
                          context,
                          icon: Icons.photo_library_outlined,
                          title: 'No photos',
                          subtitle: 'Upload media for this date.',
                        )
                      : _buildGallery(context, model),
                ),
              ],
            ),
          ),
          if (_transitioningDay)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: _transitioningDay ? 1 : 0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.08),
                          Colors.white.withValues(alpha: 0.32),
                        ],
                      ),
                    ),
                    child: const Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeroCard(
    BuildContext context, {
    required DateTime date,
    required String placeLine,
    required bool canGoForward,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 28,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: AspectRatio(
          aspectRatio: 1.05,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                transitionBuilder: (child, animation) {
                  return FadeTransition(opacity: animation, child: child);
                },
                child: KeyedSubtree(
                  key: ValueKey(
                    '${_heroAsset?.previewUrl ?? ''}|${_heroAsset?.fullUrl ?? ''}',
                  ),
                  child: _ProgressiveHeroImage(
                    asset: _heroAsset,
                    headers: _authHeaders(),
                  ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.08),
                      Colors.black.withValues(alpha: 0.16),
                      Colors.black.withValues(alpha: 0.62),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    _glassIconButton(
                      icon: Icons.chevron_left,
                      onPressed: () => _shiftDay(-1),
                    ),
                    const Spacer(),
                    if (_status.isNotEmpty)
                      _glassStatusPill(
                        context,
                        _status,
                        color:
                            _status.startsWith('Save failed') ||
                                _status.startsWith('Upload failed') ||
                                _status.startsWith('Failed')
                            ? const Color(0xFF832C2C)
                            : _heroAccent,
                      ),
                    if (_status.isNotEmpty) const SizedBox(width: 8),
                    _glassIconButton(
                      icon: Icons.chevron_right,
                      onPressed: canGoForward ? () => _shiftDay(1) : null,
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: _changeDate,
                      child: Text(
                        DateFormat('EEEE').format(date).toUpperCase(),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Colors.white.withValues(alpha: 0.92),
                              letterSpacing: 1.8,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: _changeDate,
                      child: Text(
                        DateFormat('d MMMM y').format(date),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              height: 0.96,
                            ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: _changeDate,
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.place_outlined,
                              color: Colors.white,
                              size: 15,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                placeLine.isEmpty ? 'Add place' : placeLine,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                          ],
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
  }

  Widget _buildOverviewCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(_heroAccent, Colors.white, 0.9) ??
                const Color(0xFFF8FBFF),
            Colors.white,
          ],
        ),
        border: Border.all(
          color:
              Color.lerp(_heroAccent, Colors.white, 0.78) ??
              const Color(0xFFD9E4F2),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _infoBadge(
              icon: Icons.photo_library_outlined,
              label: '${_media.length}',
            ),
            const SizedBox(width: 6),
            _infoBadge(
              icon: Icons.directions_run_outlined,
              label: _detailsLoading ? '...' : '${_runs.length}',
            ),
            const SizedBox(width: 6),
            FilledButton.tonalIcon(
              onPressed: () {
                _dismissKeyboard();
                setState(() {
                  _heroPickerEnabled = !_heroPickerEnabled;
                  _status = _heroPickerEnabled
                      ? 'Tap a gallery image to set the hero'
                      : '';
                });
              },
              style: FilledButton.styleFrom(
                backgroundColor: _heroPickerEnabled
                    ? _heroAccent
                    : Color.lerp(_heroAccent, Colors.white, 0.86),
                foregroundColor: _heroPickerEnabled
                    ? Colors.white
                    : _heroAccent,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: Icon(
                _heroPickerEnabled
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                size: 18,
              ),
              label: const Text('Cover'),
            ),
            const SizedBox(width: 6),
            FilledButton.tonal(
              onPressed: _uploadFiles,
              style: FilledButton.styleFrom(
                backgroundColor: Color.lerp(_heroAccent, Colors.white, 0.86),
                foregroundColor: _heroAccent,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text('Upload'),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: _dirty && !_saving ? _save : null,
              style: FilledButton.styleFrom(
                backgroundColor: _heroAccent,
                foregroundColor: Colors.white,
                minimumSize: const Size(36, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(_dirty ? Icons.save_outlined : Icons.check_rounded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunsEventsSection(BuildContext context) {
    if (_detailsLoading) {
      return Column(children: List.generate(3, (_) => _buildLoadingTile()));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_runs.isEmpty)
          _buildEmptyState(
            context,
            icon: Icons.directions_run_outlined,
            title: 'No runs',
            subtitle: 'Nothing synced for this date.',
          )
        else
          ..._runs.map((run) => _buildRunTile(context, run)),
        if (_events.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Events',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ..._events.map((event) => _buildEventTile(context, event)),
        ],
      ],
    );
  }

  Widget _buildLoadingTile() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F7FF),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            height: 42,
            width: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFDCE8FA),
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 12,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD9E6F7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: 0.52,
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE3ECF9),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChipEditor({
    required TextEditingController controller,
    required String hint,
    required List<String> items,
    required VoidCallback onAdd,
    required ValueChanged<String> onDelete,
    ValueChanged<String>? onTapItem,
    required Color chipColor,
    required Color textColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                onSubmitted: (_) => onAdd(),
                onTapOutside: (_) => _dismissKeyboard(),
                decoration: InputDecoration(labelText: hint, hintText: hint),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: onAdd,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF174EA6),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (items.isEmpty)
          const SizedBox.shrink()
        else
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: items
                .map(
                  (item) => InputChip(
                    backgroundColor: chipColor,
                    labelStyle: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w700,
                    ),
                    side: BorderSide.none,
                    label: Text(item),
                    deleteIconColor: textColor,
                    onPressed: onTapItem == null ? null : () => onTapItem(item),
                    onDeleted: () => onDelete(item),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }

  Widget _buildPeopleEditor(BuildContext context, List<String> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (items.isEmpty)
          _buildEmptyState(
            context,
            icon: Icons.people_outline_rounded,
            title: 'No people yet',
            subtitle: '',
          )
        else
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: items
                .map(
                  (item) => InputChip(
                    backgroundColor: const Color(0xFFE8F0FF),
                    labelStyle: const TextStyle(
                      color: Color(0xFF1D4F91),
                      fontWeight: FontWeight.w700,
                    ),
                    side: BorderSide.none,
                    label: Text(item),
                    onPressed: () => _openPersonFromName(item),
                    deleteIconColor: const Color(0xFF1D4F91),
                    onDeleted: () => _removePerson(item),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }

  Widget _buildRunTile(BuildContext context, RunModel run) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openRunDetail(run),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF2F7FF),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              height: 42,
              width: 42,
              decoration: BoxDecoration(
                color: const Color(0xFFDCE8FA),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.directions_run, color: Color(0xFF174EA6)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    run.name.isEmpty ? 'Run ${run.id}' : run.name,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${run.distanceKm.toStringAsFixed(1)} km',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              size: 16,
              color: Color(0xFF6B7F9E),
            ),
          ],
        ),
      ),
    );
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
          headers: _authHeaders(),
        ),
      ),
    );
  }

  Widget _buildEventTile(BuildContext context, CalendarEventModel event) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7FD),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            height: 42,
            width: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFDCE8FA),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.event_outlined, color: Color(0xFF174EA6)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.summary.isEmpty ? 'Untitled event' : event.summary,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  event.start.isEmpty ? 'All day' : event.start,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6FB),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, size: 28, color: const Color(0xFF5F7393)),
          const SizedBox(height: 10),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _infoBadge({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color:
            Color.lerp(_heroAccent, Colors.white, 0.88) ??
            const Color(0xFFEFF4FB),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: _heroAccent),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color:
                  Color.lerp(_heroAccent, Colors.black, 0.35) ??
                  const Color(0xFF173B73),
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _glassIconButton({
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: onPressed == null ? 0.14 : 0.22),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }

  Widget _glassStatusPill(
    BuildContext context,
    String text, {
    required Color color,
  }) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 210),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildGallery(BuildContext context, StoryDayModel model) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 980
            ? 4
            : width >= 700
            ? 3
            : width >= 430
            ? 2
            : 1;
        final double childAspectRatio = crossAxisCount == 1 ? 1.35 : 1.0;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _media.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: childAspectRatio,
          ),
          itemBuilder: (context, index) {
            final item = _media[index];
            final url = _galleryThumbUrl(item);
            return InkWell(
              onTap: () => _heroPickerEnabled
                  ? _setHighlight(item)
                  : _showImagePreview(item),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F6FB),
                  border: Border.all(color: const Color(0xFFDCE3EE), width: 1),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x12000000),
                      blurRadius: 12,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      httpHeaders: _authHeaders(),
                      errorWidget: (_, __, ___) => const ColoredBox(
                        color: Color(0xFFF1F5FB),
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: Color(0xFF6E83A5),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.1),
                            ],
                          ),
                        ),
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

  String _galleryThumbUrl(DayMediaModel media) {
    final date = media.date;
    final name = media.fileName;
    if (date.isNotEmpty && name.isNotEmpty) {
      return '${AppConfig.backendUrl}/api/images/$date/compressed/$name';
    }
    return AppConfig.imageUrlFromPath(media.path, date: media.date);
  }

  String _galleryFullUrl(DayMediaModel media) {
    final date = media.date;
    final name = media.fileName;
    if (date.isNotEmpty && name.isNotEmpty) {
      return '${AppConfig.backendUrl}/api/images/$date/$name';
    }
    return AppConfig.imageUrlFromPath(media.path, date: media.date);
  }

  bool _isSelectedMedia(StoryDayModel model, DayMediaModel media) {
    final highlight = model.highlightImage.trim();
    if (highlight.isEmpty) return false;
    if (media.path == highlight) return true;
    if (media.fileName == highlight) return true;
    return media.path.endsWith('/$highlight');
  }

  _HeroImageAsset? _resolveHeroAssetForModel(
    StoryDayModel model,
    List<DayMediaModel> mediaItems,
  ) {
    final highlight = model.highlightImage.trim();
    if (highlight.isEmpty) return null;

    for (final media in mediaItems) {
      if (_isSelectedMedia(model, media)) {
        return _HeroImageAsset(
          previewUrl: _galleryThumbUrl(media),
          fullUrl: _galleryFullUrl(media),
        );
      }
    }

    if (!highlight.contains('/') && model.date.isNotEmpty) {
      return _HeroImageAsset(
        previewUrl:
            '${AppConfig.backendUrl}/api/images/${model.date}/compressed/$highlight',
        fullUrl: '${AppConfig.backendUrl}/api/images/${model.date}/$highlight',
      );
    }

    final fullUrl = AppConfig.imageUrlFromPath(highlight, date: model.date);
    return _HeroImageAsset(previewUrl: fullUrl, fullUrl: fullUrl);
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

class _AddPersonSheet extends StatefulWidget {
  const _AddPersonSheet({
    required this.repository,
    required this.selectedNames,
  });

  final PersonRepository repository;
  final List<String> selectedNames;

  @override
  State<_AddPersonSheet> createState() => _AddPersonSheetState();
}

class _AddPersonSheetState extends State<_AddPersonSheet> {
  late final TextEditingController _searchController;
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _relationController;
  Timer? _debounce;
  bool _loading = false;
  bool _showCreate = false;
  bool _creating = false;
  List<PersonModel> _popular = const [];
  List<PersonModel> _results = const [];

  bool _isAlreadySelected(PersonModel person) {
    final normalized = person.displayName.trim().toLowerCase();
    return widget.selectedNames.any(
      (name) => name.trim().toLowerCase() == normalized,
    );
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _firstNameController = TextEditingController();
    _lastNameController = TextEditingController();
    _relationController = TextEditingController();
    _loadPopular();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _relationController.dispose();
    super.dispose();
  }

  Future<void> _loadPopular() async {
    setState(() => _loading = true);
    try {
      final people = await widget.repository.popular(first: 12);
      if (!mounted) return;
      setState(() {
        _popular = people;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _loading = false;
        _results = _popular;
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 220), () async {
      if (!mounted) return;
      setState(() => _loading = true);
      try {
        final results = await widget.repository.search(query);
        if (!mounted) return;
        setState(() {
          _results = results;
          _loading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _results = const [];
          _loading = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim();
    final visibleResults = query.length < 2 ? _popular : _results;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        18,
        18,
        18,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _showCreate ? 'Create new person' : 'Add person',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF173B68),
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _showCreate = !_showCreate;
                  });
                },
                child: Text(_showCreate ? 'Back' : 'New'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_showCreate)
            _buildCreateForm(context)
          else ...[
            TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                labelText: 'Search people',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : visibleResults.isEmpty
                  ? _PickerInfoCard(
                      icon: Icons.person_off_outlined,
                      title: query.length < 2
                          ? 'No popular people yet'
                          : 'No matching person found',
                      subtitle: '',
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: visibleResults.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final person = visibleResults[index];
                        final alreadySelected = _isAlreadySelected(person);
                        final subtitle = [
                          person.relation.trim(),
                          person.profession.trim(),
                        ].where((part) => part.isNotEmpty).join(' · ');
                        return Material(
                          color: alreadySelected
                              ? const Color(0xFFEAF1FB)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            title: Text(
                              person.displayName,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: alreadySelected
                                    ? const Color(0xFF6A819B)
                                    : null,
                              ),
                            ),
                            subtitle: subtitle.isEmpty ? null : Text(subtitle),
                            trailing: Icon(
                              alreadySelected
                                  ? Icons.check_circle_rounded
                                  : Icons.add_circle_outline_rounded,
                              color: alreadySelected
                                  ? const Color(0xFF1D4F91)
                                  : null,
                            ),
                            onTap: alreadySelected
                                ? null
                                : () => Navigator.of(context).pop(person),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCreateForm(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _firstNameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'First name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _lastNameController,
          decoration: const InputDecoration(labelText: 'Last name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _relationController,
          decoration: const InputDecoration(
            labelText: 'Relation',
            hintText: 'Friend, family, colleague...',
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _creating
                ? null
                : () async {
                    final navigator = Navigator.of(context);
                    final first = _firstNameController.text.trim();
                    final last = _lastNameController.text.trim();
                    if (first.isEmpty && last.isEmpty) return;
                    setState(() => _creating = true);
                    try {
                      final created = await widget.repository.create(
                        PersonModel(
                          id: 0,
                          firstName: first,
                          lastName: last,
                          birthDate: '',
                          deathDate: '',
                          relation: _relationController.text.trim(),
                          profession: '',
                          studyProgram: '',
                          languages: '',
                          email: '',
                          phone: '',
                          address: '',
                          notes: '',
                          biography: '',
                        ),
                      );
                      if (!mounted) return;
                      navigator.pop(created);
                    } catch (_) {
                      if (!mounted) return;
                      setState(() => _creating = false);
                    }
                  },
            child: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Create and add'),
          ),
        ),
      ],
    );
  }
}

class _PickerInfoCard extends StatelessWidget {
  const _PickerInfoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFF5B7290), size: 28),
          const SizedBox(height: 10),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFF173B68),
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
          if (hasSubtitle) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF5B7290)),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroImageAsset {
  const _HeroImageAsset({required this.previewUrl, required this.fullUrl});

  final String previewUrl;
  final String fullUrl;
}

class _ProgressiveHeroImage extends StatefulWidget {
  const _ProgressiveHeroImage({required this.asset, required this.headers});

  final _HeroImageAsset? asset;
  final Map<String, String> headers;

  @override
  State<_ProgressiveHeroImage> createState() => _ProgressiveHeroImageState();
}

class _ProgressiveHeroImageState extends State<_ProgressiveHeroImage> {
  bool _fullReady = false;
  String? _fullReadyUrl;

  @override
  void initState() {
    super.initState();
    _primeFullImage();
  }

  @override
  void didUpdateWidget(covariant _ProgressiveHeroImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset?.fullUrl != widget.asset?.fullUrl ||
        oldWidget.asset?.previewUrl != widget.asset?.previewUrl) {
      _primeFullImage();
    }
  }

  Future<void> _primeFullImage() async {
    final asset = widget.asset;
    if (asset == null ||
        asset.fullUrl.isEmpty ||
        asset.fullUrl == asset.previewUrl) {
      if (!mounted) return;
      setState(() {
        _fullReady = false;
        _fullReadyUrl = asset?.fullUrl;
      });
      return;
    }

    setState(() {
      _fullReady = false;
      _fullReadyUrl = asset.fullUrl;
    });

    try {
      await precacheImage(
        CachedNetworkImageProvider(asset.fullUrl, headers: widget.headers),
        context,
      );
      if (!mounted || _fullReadyUrl != asset.fullUrl) return;
      setState(() {
        _fullReady = true;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    if (asset == null || asset.previewUrl.isEmpty) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF9FBEEA), Color(0xFFDCE8FA)],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CachedNetworkImage(
          imageUrl: asset.previewUrl,
          fit: BoxFit.cover,
          httpHeaders: widget.headers,
          fadeInDuration: const Duration(milliseconds: 160),
          errorWidget: (_, __, ___) => Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF9FBEEA), Color(0xFFDCE8FA)],
              ),
            ),
            child: const Center(
              child: Icon(
                Icons.image_not_supported_outlined,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
        ),
        if (asset.fullUrl.isNotEmpty && asset.fullUrl != asset.previewUrl)
          AnimatedOpacity(
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
            opacity: _fullReady ? 1 : 0,
            child: Image(
              image: CachedNetworkImageProvider(
                asset.fullUrl,
                headers: widget.headers,
              ),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}
