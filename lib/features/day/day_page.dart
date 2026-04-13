import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:palette_generator/palette_generator.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:google_polyline_algorithm/google_polyline_algorithm.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/breakpoints.dart';
import '../../core/utils/date_format.dart';
import '../../core/widgets/person_picker_sheet.dart';
import '../../data/graphql/documents.dart';
import '../../core/widgets/fullscreen_image_viewer.dart';
import '../../core/widgets/protected_network_image.dart';
import '../../core/widgets/calendar_event_detail_sheet.dart';
import '../../core/widgets/section_card.dart';
import '../../data/models/calendar_event_model.dart';
import '../../data/repositories/map_repository.dart';
import '../../data/models/daily_activity_model.dart';
import '../../data/models/daily_weather_model.dart';
import '../../data/models/day_media_model.dart';
import '../../data/models/day_payload_model.dart';
import '../../data/models/person_model.dart';
import '../../data/models/run_model.dart';
import '../../data/models/story_day_model.dart';
import '../../data/models/upload_batch_state_model.dart';
import '../../providers.dart';
import 'day_draft_controller.dart';
import 'widgets/day_weather_section.dart';
import '../persons/person_detail_page.dart';
import '../runs/run_detail_page.dart';

class DayPage extends ConsumerStatefulWidget {
  const DayPage({super.key});

  @override
  ConsumerState<DayPage> createState() => _DayPageState();
}

class _DayPageState extends ConsumerState<DayPage> with WidgetsBindingObserver {
  static const _defaultHeroAccent = Color(0xFF174EA6);
  static const _maxDayCacheEntries = 7;
  static const _navigationBurstWindow = Duration(milliseconds: 260);

  late final TextEditingController _place;
  late final TextEditingController _country;
  late final TextEditingController _description;
  late final ScrollController _scrollController;
  late final ProviderSubscription<DateTime> _selectedDateSubscription;

  final Map<String, DayPayloadModel> _dayCache = <String, DayPayloadModel>{};
  final List<String> _cacheOrder = <String>[];

  Timer? _pendingLoadTimer;
  Timer? _debounceTimer;
  Timer? _autosaveTimer;
  StoryDayModel? _original;
  StoryDayModel? _current;
  List<DayMediaModel> _media = const [];
  List<RunModel> _runs = const [];
  List<CalendarEventModel> _calendarEvents = const [];
  Future<List<CalendarEventModel>>? _calendarEventsFuture;
  DailyActivityModel? _dailyActivity;
  DailyWeatherModel? _dailyWeather;
  TimelineDayData? _timelineDay;
  List<UploadItemStateModel> _uploadQueue = const [];
  double _uploadProgress = 0.0;
  Map<String, PersonModel> _personLookup = const {};

  bool _loading = true;
  bool _saving = false;
  bool _transitioningDay = false;
  bool _heroPickerEnabled = false;
  bool _galleryExpanded = false;
  bool _syncingControllers = false;
  String _status = '';
  int _activeLoadId = 0;
  String? _activeDayKey;
  String? _pendingSyncDayKey;
  DateTime? _queuedDateAfterSave;
  bool _suppressDateSync = false;
  DateTime _lastNavigationAt = DateTime.fromMillisecondsSinceEpoch(0);
  Color _heroAccent = _defaultHeroAccent;
  String? _paletteSourceUrl;
  _HeroImageAsset? _heroAsset;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _dirty && !_saving) {
      _debounceTimer?.cancel();
      _autosaveTimer?.cancel();
      _saveNow();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _place = TextEditingController();
    _country = TextEditingController();
    _description = TextEditingController();
    _scrollController = ScrollController();

    _place.addListener(_syncForm);
    _country.addListener(_syncForm);
    _description.addListener(_syncForm);
    _selectedDateSubscription = ref.listenManual<DateTime>(
      selectedDateProvider,
      (previous, next) {
        if (_suppressDateSync) return;
        final nextDay = formatYmd(DateUtils.dateOnly(next));
        if (nextDay == _activeDayKey) return;
        unawaited(_handleRequestedDateChange(next));
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDate(ref.read(selectedDateProvider));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _autosaveTimer?.cancel();
    _place.dispose();
    _country.dispose();
    _description.dispose();
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
    final place = _place.text.trim();
    final country = _country.text.trim();
    final description = _description.text;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final model = _current;
      if (model == null) return;
      setState(() {
        _current = model.copyWith(
          place: place,
          country: country,
          description: description,
        );
      });
      _markDirtyAndScheduleAutosave();
    });
  }

  void _syncDraftStatus([String? text]) {
    final notifier = ref.read(dayDraftControllerProvider.notifier);
    notifier.setCurrentDay(_activeDayKey ?? '');
    if (_saving) {
      notifier.markSaving(text: text ?? 'Saving');
      return;
    }
    if (_uploadQueue.any((item) => item.status != UploadItemStatus.done)) {
      notifier.setUploading(true, text: text ?? 'Uploading');
      return;
    }
    notifier.setUploading(false);
    if (_dirty) {
      notifier.markDirty(text: text ?? 'Unsaved changes');
      return;
    }
    notifier.markClean(text: text ?? _status);
  }

  static const _autosaveDelayTyping = Duration(seconds: 3);
  static const _autosaveDelayDiscrete = Duration(seconds: 1);

  void _markDirtyAndScheduleAutosave({Duration delay = _autosaveDelayTyping}) {
    if (!_dirty) {
      _autosaveTimer?.cancel();
      _syncDraftStatus();
      return;
    }
    _syncDraftStatus('Unsaved changes');
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(delay, () {
      if (!mounted || !_dirty || _saving) return;
      _saveNow();
    });
  }

  Future<void> _loadDate(DateTime date) async {
    final normalized = DateUtils.dateOnly(date);
    final day = formatYmd(normalized);
    final isFutureDay = _isFutureDate(normalized);
    final requestId = ++_activeLoadId;
    _activeDayKey = day;
    _lastNavigationAt = DateTime.now();
    _timelineDay = null;
    _calendarEventsFuture = ref
        .read(calendarRepositoryProvider)
        .eventsForDate(day);
    ref.read(dayDraftControllerProvider.notifier).setCurrentDay(day);
    unawaited(_loadTimeline(day));
    unawaited(_loadCalendarEvents(day));

    final cached = _cacheGet(day);
    if (cached != null) {
      _applyVisiblePayload(
        cached,
        detailsLoaded: cached.detailsLoaded,
        clearStatus: true,
        finishTransition: true,
      );
      if (cached.activity == null && !isFutureDay) {
        unawaited(_loadDailyActivity(day));
      }
      _schedulePostApplyWork(
        day,
        requestId,
        cached,
        includeFullHero: false,
        prefetchAdjacent: !_isRapidNavigation(),
      );
      unawaited(_refreshDate(normalized, requestId));
      return;
    }

    final persisted = await ref
        .read(dayRepositoryProvider)
        .getCachedDayCorePayload(day);
    if (persisted != null) {
      _cachePut(day, persisted);
      if (_isActiveRequest(requestId, day)) {
        _applyVisiblePayload(
          persisted,
          detailsLoaded: persisted.detailsLoaded,
          clearStatus: true,
          finishTransition: true,
        );
      }
      unawaited(_refreshDate(normalized, requestId));
      return;
    }

    setState(() {
      _loading = _current == null;
      _transitioningDay = _current != null;
      _galleryExpanded = false;
      _status = '';
    });
    await _refreshDate(normalized, requestId);
  }

  Future<void> _refreshDate(DateTime date, int requestId) async {
    final day = formatYmd(date);
    final isFutureDay = _isFutureDate(date);

    try {
      final cachedEvents =
          _dayCache[day]?.events ?? const <CalendarEventModel>[];
      final basePayload = await ref
          .read(dayRepositoryProvider)
          .getDayCorePayload(day);
      final normalizedPayload = isFutureDay
          ? basePayload.copyWith(runs: const <RunModel>[], detailsLoaded: true)
          : basePayload;
      final payload = normalizedPayload.copyWith(
        events: normalizedPayload.events.isNotEmpty
            ? normalizedPayload.events
            : cachedEvents,
      );
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

  bool _isFutureDate(DateTime date) {
    return DateUtils.dateOnly(date).isAfter(DateUtils.dateOnly(DateTime.now()));
  }

  bool get _isFutureDayActive {
    final day = _activeDayKey;
    if (day == null || day.isEmpty) return false;
    return _isFutureDate(parseYmd(day));
  }

  void _scheduleLoadForDate(DateTime date) {
    _pendingLoadTimer?.cancel();
    unawaited(_loadDate(DateUtils.dateOnly(date)));
  }

  Future<void> _loadTimeline(String day) async {
    try {
      final data = await ref.read(mapRepositoryProvider).loadTimelineDay(day);
      if (!mounted || _activeDayKey != day) return;
      setState(() => _timelineDay = data);
    } catch (_) {}
  }

  Future<void> _loadDailyActivity(String day) async {
    try {
      final gql = ref.read(graphqlServiceProvider);
      final response = await gql.query(
        GqlDocuments.dailyActivity,
        variables: {'date': day},
      );
      if (!mounted) return;
      final edges =
          (((response['health'] as Map<String, dynamic>?)?['dailyActivity']
                  as Map<String, dynamic>?)?['edges']
              as List<dynamic>?) ??
          [];
      if (edges.isNotEmpty) {
        final node = (edges.first as Map<String, dynamic>)['node'];
        if (node is Map<String, dynamic>) {
          final result = DailyActivityModel.fromJson(node);
          _cacheUpdate(day, (p) => p.copyWith(activity: result));
          if (_activeDayKey == day && mounted) {
            setState(() => _dailyActivity = result);
          }
        }
      }
    } catch (_) {
      // non-critical, ignore silently
    }
  }

  Future<void> _loadCalendarEvents(String day) async {
    try {
      final events = await ref
          .read(calendarRepositoryProvider)
          .eventsForDate(day);
      _cacheUpdate(day, (p) => p.copyWith(events: events));
      if (_activeDayKey == day && mounted) {
        setState(() => _calendarEvents = events);
      }
    } catch (_) {
      // non-critical, ignore silently
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
    final isFutureDay = _isFutureDate(parseYmd(day));
    if (!isFutureDay && payload.activity == null) {
      unawaited(_loadDailyActivity(day));
    }
    if (payload.events.isEmpty) {
      unawaited(_loadCalendarEvents(day));
    }
    if (prefetchAdjacent && !_isRapidNavigation() && !isFutureDay) {
      unawaited(_prefetchAdjacentDays(DateUtils.dateOnly(parseYmd(day))));
    }
  }

  void _applyVisiblePayload(
    DayPayloadModel payload, {
    required bool detailsLoaded,
    bool clearStatus = false,
    bool finishTransition = false,
  }) {
    final heroAsset = _resolveHeroAssetForModel(payload.story, payload.media);

    if (!mounted) return;

    if (!_dirty) {
      // Safe to overwrite text and story — user hasn't edited anything
      _syncingControllers = true;
      _place.text = payload.story.place;
      _country.text = payload.story.country;
      _description.text = payload.story.description;
      _syncingControllers = false;
      setState(() {
        _original = payload.story;
        _current = payload.story;
        _media = payload.media;
        _runs = payload.runs;
        _calendarEvents = payload.events.isNotEmpty
            ? payload.events
            : _calendarEvents;
        _dailyActivity = payload.activity;
        _dailyWeather = payload.weather;
        _heroAsset = heroAsset;
        if (clearStatus) _status = '';
        if (finishTransition) {
          _loading = false;
          _transitioningDay = false;
        }
      });
      unawaited(_refreshPersonLookup(payload.story.people));
    } else {
      // User is editing — never touch text or story model
      setState(() {
        _media = payload.media;
        _runs = payload.runs;
        if (payload.events.isNotEmpty) {
          _calendarEvents = payload.events;
        }
        if (payload.activity != null) _dailyActivity = payload.activity;
        _dailyWeather = payload.weather;
        _heroAsset = heroAsset;
        if (finishTransition) {
          _loading = false;
          _transitioningDay = false;
        }
      });
    }
    _syncDraftStatus();
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
    for (final delta in const [-2, -1, 1, 2]) {
      unawaited(_prefetchDate(date.add(Duration(days: delta))));
    }
  }

  Future<void> _prefetchDate(DateTime date) async {
    if (!mounted) return;
    final day = formatYmd(DateUtils.dateOnly(date));
    final isFuture = _isFutureDate(date);
    final cached = _dayCache[day];
    if (cached != null && cached.detailsLoaded) {
      if (cached.activity == null && !isFuture) {
        unawaited(_loadDailyActivity(day));
      }
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
      _cachePut(day, payload.copyWith(events: const [], detailsLoaded: true));
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
      final provider = await loadProtectedImageProvider(
        url,
        headers: _authHeaders(),
      );
      await precacheImage(provider, context);
    } catch (_) {}
  }

  Future<void> _handleRequestedDateChange(DateTime next) async {
    final normalized = DateUtils.dateOnly(next);
    if (await _prepareForDayNavigation(normalized)) {
      _scheduleLoadForDate(normalized);
    }
  }

  Future<bool> _prepareForDayNavigation(DateTime next) async {
    final nextDay = formatYmd(next);
    if (nextDay == _activeDayKey) return true;
    if (_saving) {
      _queueNavigation(next, 'Finishing save');
      return false;
    }
    _debounceTimer?.cancel();
    _autosaveTimer?.cancel();
    if (_dirty) {
      await _saveNow();
    }
    return true;
  }

  void _queueNavigation(DateTime next, String text) {
    _queuedDateAfterSave = DateUtils.dateOnly(next);
    _status = text;
    _syncDraftStatus(text);
    if (_activeDayKey != null) {
      _suppressDateSync = true;
      ref.read(selectedDateProvider.notifier).state = parseYmd(_activeDayKey!);
      _suppressDateSync = false;
    }
  }

  Future<void> _runQueuedNavigationIfNeeded() async {
    final queued = _queuedDateAfterSave;
    if (queued == null || _dirty || _saving) return;
    _queuedDateAfterSave = null;
    _suppressDateSync = true;
    ref.read(selectedDateProvider.notifier).state = queued;
    _suppressDateSync = false;
    await _loadDate(queued);
  }

  Future<void> _changeDate() async {
    final selected = await _showCalendarDialog(ref.read(selectedDateProvider));
    if (selected == null) return;
    await _requestDateChange(selected);
  }

  Future<void> _requestDateChange(DateTime date) async {
    final normalized = DateUtils.dateOnly(date);
    if (!await _prepareForDayNavigation(normalized)) return;
    _suppressDateSync = true;
    ref.read(selectedDateProvider.notifier).state = normalized;
    _suppressDateSync = false;
    await _loadDate(normalized);
  }

  Future<void> _shiftDay(int delta) async {
    final current = DateUtils.dateOnly(ref.read(selectedDateProvider));
    final target = current.add(Duration(days: delta));
    await _requestDateChange(target);
  }

  Future<DateTime?> _showCalendarDialog(DateTime initialDate) {
    return showDatePicker(
      context: context,
      locale: const Locale('en', 'GB'),
      initialDate: DateUtils.dateOnly(initialDate),
      firstDate: DateTime(2005),
      lastDate: DateTime.now(),
    );
  }

  Future<void> _refreshPersonLookup(List<String> names) async {
    if (names.isEmpty) {
      if (_personLookup.isNotEmpty) setState(() => _personLookup = const {});
      return;
    }
    final cache = ref.read(personCacheStoreProvider);
    final lookup = <String, PersonModel>{};
    final allCached = await cache.readAllPersons();
    for (final name in names) {
      final needle = name.trim().toLowerCase();
      if (needle.isEmpty) continue;
      for (final person in allCached) {
        final display = person.displayName.toLowerCase();
        final first = person.firstName.trim().toLowerCase();
        if (display == needle || first == needle) {
          lookup[name] = person;
          break;
        }
      }
    }
    if (!mounted) return;
    setState(() => _personLookup = lookup);
  }

  void _removePerson(String name) {
    if (_current == null) return;
    final current = _current!;
    final people = [...current.people]..remove(name);
    final matchedId = _personLookup[name]?.id;
    final nextPersonIds = [
      for (final personId in current.personIds)
        if (matchedId == null || personId != matchedId) personId,
    ];
    setState(() {
      _current = current.copyWith(
        names: people.join(';'),
        personIds: nextPersonIds,
      );
    });
    _markDirtyAndScheduleAutosave(delay: _autosaveDelayDiscrete);
  }

  bool _appendPerson(PersonModel person) {
    final normalized = person.displayName.trim();
    if (normalized.isEmpty || _current == null) return false;
    final current = _current!;
    final people = [...current.people];
    if (people.any((item) => item.toLowerCase() == normalized.toLowerCase())) {
      return false;
    }
    setState(() {
      _personLookup = {..._personLookup, normalized: person};
      _current = current.copyWith(
        names: [...people, normalized].join(';'),
        personIds: [...current.personIds, person.id],
      );
    });
    _markDirtyAndScheduleAutosave(delay: _autosaveDelayDiscrete);
    return true;
  }

  Future<void> _showAddPersonSheet() async {
    final selectedNames = _current?.people ?? const <String>[];
    final selected = await PersonPickerSheet.show(
      context,
      repository: ref.read(personRepositoryProvider),
      selectedNames: selectedNames,
      allowCreate: true,
      title: 'Add person',
    );
    if (!mounted || selected == null) return;
    _appendPerson(selected);
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
        backgroundColor: Colors.transparent,
        builder: (context) {
          final theme = Theme.of(context);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.38,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 32,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose a person',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Several saved people match "$query".',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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
                            color: theme.colorScheme.surfaceContainer,
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
                              subtitle: subtitle.isEmpty
                                  ? null
                                  : Text(subtitle),
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

  void _removeTag(String tag) {
    if (_current == null) return;
    final tags = [..._current!.tags]..remove(tag);
    setState(() => _current = _current!.copyWith(keywords: tags.join(';')));
    _markDirtyAndScheduleAutosave(delay: _autosaveDelayDiscrete);
  }

  Future<void> _showAddTagDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add tag'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Tag name'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    final value = result?.trim() ?? '';
    if (value.isEmpty || _current == null) return;
    final tags = [..._current!.tags, value];
    setState(() {
      _current = _current!.copyWith(keywords: tags.join(';'));
    });
    _markDirtyAndScheduleAutosave(delay: _autosaveDelayDiscrete);
  }

  Widget _buildTagsContent(List<String> tags) {
    if (tags.isEmpty) {
      return Text(
        'No tags yet',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: tags.map((tag) {
        final colorScheme = Theme.of(context).colorScheme;
        return InputChip(
          backgroundColor: colorScheme.secondaryContainer,
          labelStyle: TextStyle(
            color: colorScheme.onSecondaryContainer,
            fontWeight: FontWeight.w500,
          ),
          side: BorderSide.none,
          label: Text(tag),
          deleteIconColor: colorScheme.onSecondaryContainer,
          onDeleted: () => _removeTag(tag),
        );
      }).toList(),
    );
  }

  Future<bool> _saveNow() async {
    // Flush any pending debounced text changes before saving
    if (_debounceTimer?.isActive ?? false) {
      _debounceTimer!.cancel();
      final model = _current;
      if (model != null) {
        _current = model.copyWith(
          place: _place.text.trim(),
          country: _country.text.trim(),
          description: _description.text,
        );
      }
    }
    _autosaveTimer?.cancel();

    final model = _current;
    if (model == null) return true;
    if (!_dirty) {
      _syncDraftStatus();
      await _runQueuedNavigationIfNeeded();
      return true;
    }
    if (_saving) return false;

    final savedDay = model.date; // capture — _activeDayKey may change mid-save

    setState(() {
      _saving = true;
      _status = '';
    });
    ref.read(dayDraftControllerProvider.notifier).markSaving();

    try {
      await ref.read(storiesRepositoryProvider).saveDay(model);
      _cacheUpdate(savedDay, (payload) => payload.copyWith(story: model));
      final savedAt = DateTime.now();
      // Only update _original if we're still on the day we saved
      if (_activeDayKey == savedDay && mounted) {
        setState(() {
          _original = model;
          _status = 'Saved ${DateFormat('HH:mm').format(savedAt)}';
        });
        ref
            .read(dayDraftControllerProvider.notifier)
            .markClean(savedAt: savedAt, text: _status);
      }
      await _runQueuedNavigationIfNeeded();
      return true;
    } catch (error) {
      final message = error.toString().replaceFirst('Exception: ', '');
      if (_activeDayKey == savedDay && mounted) {
        setState(() => _status = 'Retry needed');
        ref.read(dayDraftControllerProvider.notifier).markError(message);
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _uploadFiles() async {
    if (_saving) return;
    final date = formatYmd(ref.read(selectedDateProvider));
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;

    final files = picked.files
        .where((item) => item.path != null)
        .map((item) => File(item.path!))
        .toList();
    if (files.isEmpty) return;

    ref
        .read(dayDraftControllerProvider.notifier)
        .setUploading(true, text: 'Uploading ${files.length}');
    await for (final batch
        in ref
            .read(filesRepositoryProvider)
            .uploadFilesWithProgress(date, files)) {
      if (!mounted) return;
      setState(() {
        _uploadQueue = batch.items;
      });
      if (batch.uploading) {
        _uploadProgress = batch.overallProgress;
        _status = 'Uploading ${(batch.overallProgress * 100).round()}%';
        ref
            .read(dayDraftControllerProvider.notifier)
            .setUploading(true, text: _status);
        continue;
      }
      if (batch.errorMessage != null && batch.errorMessage!.isNotEmpty) {
        _status = 'Upload failed';
        ref
            .read(dayDraftControllerProvider.notifier)
            .markError(batch.errorMessage!, text: 'Upload failed');
        continue;
      }
      final result = batch.result;
      if (result == null) continue;
      final media = [...result.media, ..._media];
      // Evict any cached image errors for newly uploaded files
      for (final item in result.media) {
        CachedNetworkImage.evictFromCache(_galleryThumbUrl(item));
      }
      final nextStory = result.highlightImage.isNotEmpty && _current != null
          ? _current!.copyWith(highlightImage: result.highlightImage)
          : _current;
      if (nextStory != null) {
        _cacheUpdate(
          nextStory.date,
          (payload) => payload.copyWith(story: nextStory, media: media),
        );
      }
      setState(() {
        _uploadQueue = const [];
        _uploadProgress = 0.0;
        _media = media;
        _current = nextStory;
        _original = nextStory ?? _original;
        _heroAsset = nextStory == null
            ? _heroAsset
            : _resolveHeroAssetForModel(nextStory, media);
        _status = result.autoAssignedHighlight
            ? 'Cover updated'
            : 'Upload complete';
      });
      if (nextStory != null) {
        await _updateHeroPalette(
          DayPayloadModel(
            story: nextStory,
            media: media,
            runs: _runs,
            events: const [],
            detailsLoaded: true,
            weather: _dailyWeather,
          ),
          nextStory.date,
          _activeLoadId,
        );
      }
      ref.read(dayDraftControllerProvider.notifier).setUploading(false);
      ref
          .read(dayDraftControllerProvider.notifier)
          .markClean(text: _status, savedAt: DateTime.now());
      unawaited(_refreshDate(ref.read(selectedDateProvider), _activeLoadId));
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
      _status = 'Updating cover';
    });
    ref
        .read(dayDraftControllerProvider.notifier)
        .markSaving(text: 'Updating cover');
    await _updateHeroPalette(
      DayPayloadModel(
        story: nextModel,
        media: _media,
        runs: _runs,
        events: const [],
        detailsLoaded: true,
        weather: _dailyWeather,
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
        _status = 'Cover updated';
        _heroPickerEnabled = false;
      });
      ref
          .read(dayDraftControllerProvider.notifier)
          .markClean(savedAt: DateTime.now(), text: _status);
      await _scrollToTop();
    } catch (error) {
      final message = error.toString().replaceFirst('Exception: ', '');
      setState(() {
        _current = previousModel;
        _heroAsset = previousHeroAsset;
        _status = 'Retry needed';
      });
      ref.read(dayDraftControllerProvider.notifier).markError(message);
      await _updateHeroPalette(
        DayPayloadModel(
          story: previousModel,
          media: _media,
          runs: _runs,
          events: const [],
          detailsLoaded: true,
          weather: _dailyWeather,
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
    final items = _media
        .map(
          (m) => ImageViewerItem(
            fullUrl: _galleryFullUrl(m),
            thumbnailUrl: _galleryThumbUrl(m),
            fileName: m.fileName,
            path: m.path,
            date: m.date,
            gps: m.gps,
            favorite: m.favorite,
          ),
        )
        .toList();
    final index = _media.indexOf(media);
    final repo = ref.read(filesRepositoryProvider);
    final facesRepo = ref.read(facesRepositoryProvider);
    final personRepo = ref.read(personRepositoryProvider);
    final deleted = await FullscreenImageViewer.show(
      context: context,
      images: items,
      initialIndex: index >= 0 ? index : 0,
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
      onOpenPerson: _openPersonDetailFromViewer,
      onDelete: (path) => repo.deleteFile(path),
      onSetCover: (path) async {
        final media = _media.firstWhere((m) => m.path == path);
        await _setHighlight(media);
      },
    );
    if (deleted.isNotEmpty && mounted) {
      setState(() {
        _media.removeWhere((m) => deleted.contains(m.path));
      });
    }
    _dismissKeyboard();
  }

  Future<void> _openPersonDetailFromViewer(PersonModel person) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PersonDetailPage(person: person),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients) return;
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _showPlaceEditorSheet() async {
    final draft = ref.read(dayDraftControllerProvider);
    final result = await showModalBottomSheet<({String place, String country})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _PlaceEditorSheet(
        initialPlace: _place.text,
        initialCountry: _country.text,
        placeSuggestions: _placeSuggestions(),
        countrySuggestions: _countrySuggestions(),
        statusText: draft.statusText,
        errorText: draft.errorMessage,
      ),
    );
    if (!mounted || result == null) return;
    if (_place.text.trim() == result.place.trim() &&
        _country.text.trim() == result.country.trim()) {
      return;
    }
    _syncingControllers = true;
    _place.text = result.place.trim();
    _country.text = result.country.trim();
    _syncingControllers = false;
    final model = _current;
    if (model != null) {
      setState(() {
        _current = model.copyWith(
          place: result.place.trim(),
          country: result.country.trim(),
        );
      });
    }
    _markDirtyAndScheduleAutosave(delay: _autosaveDelayDiscrete);
  }

  List<String> _placeSuggestions() {
    final values = <String>{};
    for (final payload in _dayCache.values) {
      final place = payload.story.place.trim();
      if (place.isNotEmpty && place != _place.text.trim()) {
        values.add(place);
      }
    }
    return values.take(6).toList();
  }

  List<String> _countrySuggestions() {
    final values = <String>{};
    for (final payload in _dayCache.values) {
      final country = payload.story.country.trim();
      if (country.isNotEmpty && country != _country.text.trim()) {
        values.add(country);
      }
    }
    return values.take(4).toList();
  }

  Future<void> _updateHeroPalette(
    DayPayloadModel payload,
    String day,
    int requestId,
  ) async {
    // Skip palette generation on web — it's CPU-heavy and blocks the main thread.
    if (kIsWeb) {
      if (!_isActiveRequest(requestId, day) || !mounted) return;
      setState(() => _heroAccent = _defaultHeroAccent);
      return;
    }

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
      return;
    }

    try {
      final provider = await loadProtectedImageProvider(
        normalized,
        headers: _authHeaders(),
      );
      final palette = await PaletteGenerator.fromImageProvider(
        provider,
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
    } catch (_) {
      if (!mounted || !_isActiveRequest(requestId, day)) return;
      if (_paletteSourceUrl != '$day|$normalized') return;
      setState(() {
        _heroAccent = _defaultHeroAccent;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = ref.watch(selectedDateProvider);
    final draft = ref.watch(dayDraftControllerProvider);
    final model = _current;
    final selectedDayKey = formatYmd(DateUtils.dateOnly(date));

    if (selectedDayKey != _activeDayKey &&
        selectedDayKey != _pendingSyncDayKey) {
      _pendingSyncDayKey = selectedDayKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_pendingSyncDayKey != selectedDayKey) return;
        _pendingSyncDayKey = null;
        unawaited(_handleRequestedDateChange(date));
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = screenWidth >= Breakpoints.medium;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final primary = FocusManager.instance.primaryFocus;
        if (primary != null && primary != node) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _shiftDay(-1);
          return KeyEventResult.handled;
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _shiftDay(1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: _dismissKeyboard,
        onHorizontalDragEnd: (details) {
          if (_dirty) return; // don't swipe away while editing
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
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: isWide
                    ? const EdgeInsets.fromLTRB(20, 24, 20, 40)
                    : const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Column(
                        children: [
                          if (isWide) ...[
                            // ── Top row: Hero + Diary side by side ──
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: IntrinsicHeight(
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      flex: 2,
                                      child: _buildHeroCard(
                                        context,
                                        date: date,
                                        placeLine: placeLine,
                                        draft: draft,
                                        canGoForward: !date.isAfter(
                                          now.subtract(const Duration(days: 1)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      flex: 3,
                                      child: TextField(
                                        controller: _description,
                                        maxLines: null,
                                        expands: true,
                                        textAlignVertical:
                                            TextAlignVertical.top,
                                        onTapOutside: (_) => _dismissKeyboard(),
                                        decoration: const InputDecoration(
                                          alignLabelWithHint: true,
                                          hintText: 'Diary text...',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // ── Middle row: Map+Activity left, People+Tags right ──
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        if (_timelineDay != null &&
                                            _timelineDay!.hasData) ...[
                                          _buildTimelineMapCard(context),
                                          const SizedBox(height: 12),
                                        ],
                                        if (_dailyActivity != null ||
                                            _runs.isNotEmpty)
                                          SectionCard(
                                            title: 'Activity',
                                            padding: const EdgeInsets.fromLTRB(
                                              18,
                                              14,
                                              18,
                                              16,
                                            ),
                                            child: _buildActivityBar(context),
                                          ),
                                        if (_dailyWeather != null) ...[
                                          const SizedBox(height: 12),
                                          SectionCard(
                                            title: 'Weather',
                                            padding: const EdgeInsets.fromLTRB(
                                              18,
                                              16,
                                              18,
                                              18,
                                            ),
                                            child: DayWeatherSection(
                                              weather: _dailyWeather!,
                                              onTap: _showWeatherDetailDialog,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    flex: 2,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        SectionCard(
                                          title: 'People',
                                          action: IconButton.filledTonal(
                                            onPressed: _showAddPersonSheet,
                                            icon: const Icon(Icons.add_rounded),
                                            tooltip: 'Add person',
                                            style: IconButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFFE8F0FF,
                                              ),
                                              foregroundColor: const Color(
                                                0xFF1D4F91,
                                              ),
                                            ),
                                          ),
                                          padding: const EdgeInsets.fromLTRB(
                                            18,
                                            18,
                                            18,
                                            20,
                                          ),
                                          child: _buildPeopleEditor(
                                            context,
                                            model.people,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        SectionCard(
                                          title: 'Calendar',
                                          padding: const EdgeInsets.fromLTRB(
                                            18,
                                            18,
                                            18,
                                            20,
                                          ),
                                          child: _buildCalendarSection(context),
                                        ),
                                        const SizedBox(height: 12),
                                        SectionCard(
                                          title: 'Tags',
                                          action: IconButton.filledTonal(
                                            onPressed: _showAddTagDialog,
                                            icon: const Icon(Icons.add_rounded),
                                            tooltip: 'Add tag',
                                            style: IconButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFFDCEBFF,
                                              ),
                                              foregroundColor: const Color(
                                                0xFF184A93,
                                              ),
                                            ),
                                          ),
                                          padding: const EdgeInsets.fromLTRB(
                                            18,
                                            18,
                                            18,
                                            20,
                                          ),
                                          child: _buildTagsContent(model.tags),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else ...[
                            _buildHeroCard(
                              context,
                              date: date,
                              placeLine: placeLine,
                              draft: draft,
                              canGoForward: !date.isAfter(
                                now.subtract(const Duration(days: 1)),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _description,
                              maxLines: 11,
                              onTapOutside: (_) => _dismissKeyboard(),
                              decoration: const InputDecoration(
                                alignLabelWithHint: true,
                                hintText: 'Diary text...',
                              ),
                            ),
                            if (_timelineDay != null &&
                                _timelineDay!.hasData) ...[
                              const SizedBox(height: 12),
                              _buildTimelineMapCard(context),
                            ],
                            if (_dailyActivity != null || _runs.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              SectionCard(
                                title: 'Activity',
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  14,
                                  18,
                                  16,
                                ),
                                child: _buildActivityBar(context),
                              ),
                            ],
                            if (_dailyWeather != null) ...[
                              const SizedBox(height: 12),
                              SectionCard(
                                title: 'Weather',
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  16,
                                  18,
                                  18,
                                ),
                                child: DayWeatherSection(
                                  weather: _dailyWeather!,
                                  onTap: _showWeatherDetailDialog,
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            SectionCard(
                              title: 'People',
                              action: IconButton.filledTonal(
                                onPressed: _showAddPersonSheet,
                                icon: const Icon(Icons.add_rounded),
                                tooltip: 'Add person',
                              ),
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                18,
                                18,
                                20,
                              ),
                              child: _buildPeopleEditor(context, model.people),
                            ),
                            const SizedBox(height: 12),
                            SectionCard(
                              title: 'Calendar',
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                18,
                                18,
                                20,
                              ),
                              child: _buildCalendarSection(context),
                            ),
                            const SizedBox(height: 12),
                            SectionCard(
                              title: 'Tags',
                              action: IconButton.filledTonal(
                                onPressed: _showAddTagDialog,
                                icon: const Icon(Icons.add_rounded),
                                tooltip: 'Add tag',
                              ),
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                18,
                                18,
                                20,
                              ),
                              child: _buildTagsContent(model.tags),
                            ),
                          ],
                          const SizedBox(height: 12),
                          SectionCard(
                            title: 'Gallery',
                            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_heroPickerEnabled) ...[
                                  Text(
                                    'Tap a photo to set it as cover.',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                                if (_uploadQueue.isNotEmpty) ...[
                                  _buildUploadQueue(context),
                                  const SizedBox(height: 12),
                                ],
                                if (_media.isEmpty)
                                  _buildEmptyState(
                                    context,
                                    icon: Icons.photo_library_outlined,
                                    title: draft.uploading
                                        ? 'Uploading photos'
                                        : 'No photos',
                                    subtitle: draft.uploading
                                        ? 'Your uploads will appear here.'
                                        : 'Upload media for this date.',
                                  )
                                else
                                  _buildGallery(context, model),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 18,
              bottom: 18 + bottomInset,
              child: FloatingActionButton(
                heroTag: 'upload_fab',
                onPressed: draft.uploading ? null : _uploadFiles,
                elevation: 4,
                child: draft.uploading
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          value: _uploadProgress >= 1.0
                              ? null
                              : _uploadProgress,
                          strokeWidth: 3,
                        ),
                      )
                    : const Icon(Icons.add_photo_alternate_rounded),
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
      ),
    );
  }

  Widget _buildHeroCard(
    BuildContext context, {
    required DateTime date,
    required String placeLine,
    required DayDraftState draft,
    required bool canGoForward,
  }) {
    return Container(
      decoration: BoxDecoration(boxShadow: const [BoxShadow()]),
      child: ClipRRect(
        child: AspectRatio(
          aspectRatio: 1.1,
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
                    if (draft.statusText.isNotEmpty)
                      GestureDetector(
                        onTap: (_dirty && !_saving)
                            ? () => _saveNow()
                            : draft.hasError
                            ? () => _saveNow()
                            : null,
                        child: _glassStatusPill(
                          context,
                          _saving ? 'Saving…' : draft.statusText,
                          color: draft.hasError
                              ? Theme.of(context).colorScheme.error
                              : _heroAccent,
                        ),
                      ),
                    if (draft.statusText.isNotEmpty) const SizedBox(width: 8),
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
                      onTap: _showPlaceEditorSheet,
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
                              Icons.edit_location_alt_outlined,
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

  Widget _buildOverviewCard(BuildContext context, DayDraftState draft) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.surfaceContainerLow,
            colorScheme.surfaceContainerHighest,
          ],
        ),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(
            alpha: isDark ? 0.55 : 1.0,
          ),
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
              label: '${_runs.length}',
            ),
            const SizedBox(width: 6),
            FilledButton.tonalIcon(
              onPressed: draft.uploading
                  ? null
                  : () {
                      _dismissKeyboard();
                      setState(() {
                        _heroPickerEnabled = !_heroPickerEnabled;
                      });
                    },
              style: FilledButton.styleFrom(
                backgroundColor: _heroPickerEnabled
                    ? colorScheme.primary
                    : colorScheme.secondaryContainer,
                foregroundColor: _heroPickerEnabled
                    ? colorScheme.onPrimary
                    : colorScheme.onSecondaryContainer,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
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
              onPressed: draft.uploading ? null : _uploadFiles,
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.secondaryContainer,
                foregroundColor: colorScheme.onSecondaryContainer,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text('Upload'),
            ),
            const SizedBox(width: 6),
            if (draft.hasError)
              FilledButton.tonalIcon(
                onPressed: _saving ? null : () => unawaited(_saveNow()),
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.errorContainer,
                  foregroundColor: colorScheme.onErrorContainer,
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineMapCard(BuildContext context) {
    final data = _timelineDay!;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tileConfig = AppConfig.mapTileConfig(isDark ? 'dark' : 'light');
    final mapBackground = isDark
        ? const Color(0xFF111315)
        : colorScheme.surfaceContainerHighest;

    final walkLatLngs = data.walkPoints
        .map((p) => LatLng(p.lat, p.lon))
        .toList();

    final runPolylines = data.runs
        .where((r) => r.summaryPolyline.isNotEmpty)
        .map((r) {
          final decoded = decodePolyline(r.summaryPolyline);
          return decoded
              .map((p) => LatLng(p[0].toDouble(), p[1].toDouble()))
              .toList();
        })
        .where((pts) => pts.isNotEmpty)
        .toList();

    final allPoints = [
      ...walkLatLngs,
      ...runPolylines.expand((pts) => pts),
      ...data.imageLocations.map((i) => LatLng(i.lat, i.lon)),
      ...data.visits
          .where((v) => v.lat != null && v.lon != null)
          .map((v) => LatLng(v.lat!, v.lon!)),
    ];
    if (allPoints.isEmpty) return const SizedBox.shrink();

    final mapViewKey = ValueKey<String>(
      [
        _activeDayKey ?? '',
        '${allPoints.length}',
        for (final point in allPoints)
          '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}',
      ].join('|'),
    );

    final CameraFit cameraFit;
    if (allPoints.length == 1) {
      cameraFit = CameraFit.coordinates(
        coordinates: allPoints,
        maxZoom: 15,
        padding: const EdgeInsets.all(28),
      );
    } else {
      final bounds = LatLngBounds.fromPoints(allPoints);
      // Guard against zero-area bounds (all points identical).
      if (bounds.north == bounds.south && bounds.east == bounds.west) {
        cameraFit = CameraFit.coordinates(
          coordinates: [allPoints.first],
          maxZoom: 15,
          padding: const EdgeInsets.all(28),
        );
      } else {
        cameraFit = CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(28),
        );
      }
    }

    void openMapPage() {
      // Switch to map tab first so the map's date listener sees the tab as active
      ref.read(selectedTabProvider.notifier).state = 3;
      if (_activeDayKey != null) {
        ref.read(selectedDateProvider.notifier).state = parseYmd(
          _activeDayKey!,
        );
      }
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row — same style as SectionCard
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Movement',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: openMapPage,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('Open map'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Non-interactive map — wrapped in GestureDetector to intercept taps
          GestureDetector(
            onTap: openMapPage,
            child: SizedBox(
              height: 220,
              child: AbsorbPointer(
                child: FlutterMap(
                  key: mapViewKey,
                  options: MapOptions(
                    initialCameraFit: cameraFit,
                    backgroundColor: mapBackground,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.none,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: tileConfig.urlTemplate,
                      subdomains: tileConfig.subdomains,
                      maxZoom: tileConfig.maxZoom.toDouble(),
                      userAgentPackageName: 'com.blue.app',
                      tileDisplay: isDark
                          ? const TileDisplay.instantaneous()
                          : const TileDisplay.fadeIn(),
                    ),
                    if (walkLatLngs.length > 1)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: walkLatLngs,
                            color: colorScheme.primary.withValues(alpha: 0.85),
                            strokeWidth: 3,
                          ),
                        ],
                      ),
                    if (runPolylines.isNotEmpty)
                      PolylineLayer(
                        polylines: runPolylines
                            .map(
                              (pts) => Polyline(
                                points: pts,
                                color: Colors.orange.withValues(alpha: 0.9),
                                strokeWidth: 4,
                              ),
                            )
                            .toList(),
                      ),
                    if (data.imageLocations.isNotEmpty)
                      MarkerLayer(
                        markers: data.imageLocations
                            .take(50)
                            .map(
                              (img) => Marker(
                                point: LatLng(img.lat, img.lon),
                                width: 10,
                                height: 10,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: colorScheme.primary,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    if (data.visits.isNotEmpty)
                      MarkerLayer(
                        markers: data.visits
                            .where((img) => img.lat != null && img.lon != null)
                            .map(
                              (img) => Marker(
                                point: LatLng(img.lat!, img.lon!),
                                width: 10,
                                height: 10,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.greenAccent,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: colorScheme.primary,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Stats row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                if (data.visits.isNotEmpty)
                  _mapStat(
                    context,
                    icon: Icons.route_outlined,
                    label: '${data.visits.length} Places',
                  ),
                if (runPolylines.isNotEmpty)
                  _mapStat(
                    context,
                    icon: Icons.directions_run_outlined,
                    label:
                        '${runPolylines.length} run${runPolylines.length > 1 ? 's' : ''}',
                    color: Colors.orange,
                  ),
                if (data.imageLocations.isNotEmpty)
                  _mapStat(
                    context,
                    icon: Icons.photo_outlined,
                    label:
                        '${data.imageLocations.length} photo${data.imageLocations.length > 1 ? 's' : ''} with GPS',
                  ),
              ],
            ),
          ),
          // Key places list
          if (data.visits.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1, indent: 16, endIndent: 16),
            const SizedBox(height: 4),
            ...data.visits.map((v) {
              final hours = v.durationMinutes ~/ 60;
              final mins = v.durationMinutes % 60;
              final durationLabel = hours > 0
                  ? '${hours}h ${mins}m'
                  : '${mins}m';
              final displayName = v.placeName ?? v.placeId;
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 5,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.location_on_outlined,
                        size: 15,
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            style: Theme.of(context).textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (v.placeAddress != null)
                            Text(
                              v.placeAddress!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.45),
                                    fontSize: 11,
                                  ),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      durationLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
          ] else
            const SizedBox(height: 14),
        ],
      ),
    );
  }

  Widget _mapStat(
    BuildContext context, {
    required IconData icon,
    required String label,
    Color? color,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final c = color ?? colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: c.withValues(alpha: 0.8)),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c),
        ),
      ],
    );
  }

  Widget _buildPeopleEditor(BuildContext context, List<String> items) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (items.isEmpty) {
      return Text(
        'No people yet',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: items.map((name) {
        final person = _personLookup[name];
        final firstName = name.trim().split(' ').first;
        final initial = firstName.isEmpty ? '?' : firstName[0].toUpperCase();
        final photoUrl = _personPhotoUrl(person);

        return InputChip(
          avatar: CircleAvatar(
            radius: 14,
            backgroundColor: colorScheme.primary.withValues(alpha: 0.15),
            child: photoUrl == null
                ? Text(
                    initial,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: colorScheme.primary,
                    ),
                  )
                : ClipOval(
                    child: ProtectedNetworkImage(
                      imageUrl: photoUrl,
                      headers: _authHeaders(),
                      width: 28,
                      height: 28,
                      fit: BoxFit.cover,
                      errorWidget: Text(
                        initial,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
          ),
          backgroundColor: colorScheme.surfaceContainer,
          labelStyle: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
          side: BorderSide.none,
          label: Text(firstName),
          onPressed: () => _openPersonFromName(name),
          deleteIconColor: colorScheme.onSurfaceVariant,
          onDeleted: () => _removePerson(name),
        );
      }).toList(),
    );
  }

  Widget _buildCalendarSection(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final future = _calendarEventsFuture;
    if (future == null) {
      return _CalendarEmptyState(
        icon: Icons.event_busy_rounded,
        title: 'No calendar events',
        subtitle: 'Nothing is scheduled for this day.',
      );
    }
    return FutureBuilder<List<CalendarEventModel>>(
      future: future,
      initialData: _calendarEvents,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !(snapshot.hasData && snapshot.data!.isNotEmpty)) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Loading calendar events…',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }

        if (snapshot.hasError) {
          return _CalendarEmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Calendar unavailable',
            subtitle: snapshot.error.toString().replaceFirst('Exception: ', ''),
            isError: true,
          );
        }

        final events = snapshot.data ?? const <CalendarEventModel>[];
        if (events.isEmpty) {
          return _CalendarEmptyState(
            icon: Icons.event_available_rounded,
            title: 'No calendar events',
            subtitle: 'Nothing is scheduled for this day.',
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${events.length} ${events.length == 1 ? 'entry' : 'entries'}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: colorScheme.outline,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Agenda',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (var index = 0; index < events.length; index++) ...[
              _CalendarEventTile(
                event: events[index],
                onTap: _showCalendarEventDetail,
                showConnector: index != events.length - 1,
              ),
            ],
          ],
        );
      },
    );
  }

  void _showCalendarEventDetail(CalendarEventModel event) {
    showCalendarEventDetailSheet(
      context,
      summary: event.summary,
      timeLabel: _calendarDetailTimeLabel(event),
      location: event.location,
      description: event.description,
      sourceLabel: _calendarSourceLabel(event),
    );
  }

  String _calendarSourceLabel(CalendarEventModel event) {
    final sourceName = event.sourceName.trim();
    final source = event.source.trim();
    if (sourceName.isNotEmpty && source == 'google_calendar_manual') {
      return '$sourceName (manual import)';
    }
    if (sourceName.isNotEmpty) return sourceName;
    if (source == 'google_calendar_manual') return 'Manual calendar import';
    if (source == 'google_calendar') return 'Connected Google Calendar';
    return source;
  }

  String? _personPhotoUrl(PersonModel? person) {
    if (person == null) return null;
    final photo = person.photoPath.trim();
    if (photo.isNotEmpty) {
      return '${AppConfig.backendUrl}/api/person/$photo';
    }
    return null;
  }

  Widget _buildActivityBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final act = _dailyActivity;
    final activitySource = act != null ? _activitySourceDescription(act) : null;

    final steps = act?.stepCount;
    final distKm = act?.distanceM != null ? act!.distanceM! / 1000.0 : null;
    final cyclingMin = act?.cyclingDurationMs != null
        ? (act!.cyclingDurationMs! / 60000).round()
        : null;
    final hasMetricCards =
        steps != null ||
        distKm != null ||
        (cyclingMin != null && cyclingMin > 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasMetricCards)
          Row(
            children: [
              if (steps != null)
                Expanded(
                  child: _activityChip(
                    context,
                    icon: Icons.directions_walk_rounded,
                    value: _formatSteps(steps),
                    label: 'steps',
                    color: colorScheme.primary,
                    onTap: () => _showActivityDetailDialog(
                      _ActivityMetricDetail(
                        title: 'Steps',
                        icon: Icons.directions_walk_rounded,
                        accentColor: colorScheme.primary,
                        value: '${_formatCount(steps)} steps',
                        explanation:
                            'Estimated number of walking and running steps recorded for this day.',
                        source: activitySource!,
                      ),
                    ),
                  ),
                ),
              if (steps != null && distKm != null) const SizedBox(width: 10),
              if (distKm != null)
                Expanded(
                  child: _activityChip(
                    context,
                    icon: Icons.straighten_rounded,
                    value: '${distKm.toStringAsFixed(1)} km',
                    label: 'distance',
                    color: const Color(0xFF2E7D32),
                    onTap: () => _showActivityDetailDialog(
                      _ActivityMetricDetail(
                        title: 'Distance',
                        icon: Icons.straighten_rounded,
                        accentColor: const Color(0xFF2E7D32),
                        value: '${distKm.toStringAsFixed(1)} km',
                        explanation:
                            'Total distance moved across the day, aggregated from the connected health source.',
                        source: activitySource!,
                      ),
                    ),
                  ),
                ),
              if (cyclingMin != null && cyclingMin > 0) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _activityChip(
                    context,
                    icon: Icons.directions_bike_rounded,
                    value: '$cyclingMin min',
                    label: 'cycling',
                    color: const Color(0xFF7C4DDB),
                    onTap: () => _showActivityDetailDialog(
                      _ActivityMetricDetail(
                        title: 'Cycling',
                        icon: Icons.directions_bike_rounded,
                        accentColor: const Color(0xFF7C4DDB),
                        value: '$cyclingMin min',
                        explanation:
                            'Minutes of cycling activity detected and summed for this day.',
                        source: activitySource!,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        if (_runs.isNotEmpty) ...[
          if (hasMetricCards) const SizedBox(height: 12),
          for (var i = 0; i < _runs.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _buildRunRow(context, _runs[i]),
          ],
        ],
      ],
    );
  }

  Widget _buildRunRow(BuildContext context, RunModel run) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final pace = run.averageSpeed > 0 ? _formatRunPace(run.averageSpeed) : null;
    final runColor = const Color(0xFFE8733A);

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openRunDetail(run),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: runColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: runColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.directions_run_rounded,
                size: 18,
                color: runColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    run.name.isEmpty ? 'Run' : run.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      '${run.distanceKm.toStringAsFixed(1)} km',
                      if (run.movingMinutes > 0) '${run.movingMinutes} min',
                      if (pace != null) pace,
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (run.startTime.isNotEmpty)
              Text(
                run.startTime,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _activityChip(
    BuildContext context, {
    required IconData icon,
    required String value,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showActivityDetailDialog(_ActivityMetricDetail detail) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final colorScheme = theme.colorScheme;
        final accent = detail.accentColor;
        return Dialog(
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 440),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.16),
                  blurRadius: 36,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(detail.icon, color: accent, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Daily activity',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              detail.title,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          accent.withValues(alpha: 0.16),
                          accent.withValues(alpha: 0.06),
                        ],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Recorded value',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          detail.value,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: accent,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    detail.explanation,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurface,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.65,
                        ),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.source_rounded,
                            size: 18,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Source',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                detail.source,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  height: 1.4,
                                ),
                              ),
                            ],
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
      },
    );
  }

  Future<void> _showWeatherDetailDialog() {
    final weather = _dailyWeather;
    if (weather == null) {
      return Future.value();
    }

    final details = <_WeatherDetailRow>[
      _WeatherDetailRow(
        label: 'Condition',
        value: _weatherConditionDetail(weather),
      ),
      _WeatherDetailRow(
        label: 'Temperature',
        value: _weatherTemperatureDetail(weather),
      ),
      if (weather.apparentTemperatureMaxC != null ||
          weather.apparentTemperatureMinC != null)
        _WeatherDetailRow(
          label: 'Feels like',
          value: _weatherFeelsLikeDetail(weather),
        ),
      if (weather.precipitationSumMm != null)
        _WeatherDetailRow(
          label: 'Precipitation',
          value:
              '${weather.precipitationSumMm!.toStringAsFixed(weather.precipitationSumMm! >= 10 ? 0 : 1)} mm',
        ),
      if (weather.precipitationHours != null)
        _WeatherDetailRow(
          label: 'Rain hours',
          value: '${weather.precipitationHours!.toStringAsFixed(1)} h',
        ),
      if (weather.windSpeedMaxKmh != null)
        _WeatherDetailRow(
          label: 'Max wind',
          value: '${weather.windSpeedMaxKmh!.toStringAsFixed(0)} km/h',
        ),
      if (weather.sunriseAt != null)
        _WeatherDetailRow(
          label: 'Sunrise',
          value: _weatherClockLabel(weather.sunriseAt!, weather.timezoneName),
        ),
      if (weather.sunsetAt != null)
        _WeatherDetailRow(
          label: 'Sunset',
          value: _weatherClockLabel(weather.sunsetAt!, weather.timezoneName),
        ),
      if (weather.locationLabel?.trim().isNotEmpty == true)
        _WeatherDetailRow(
          label: 'Location',
          value: weather.locationLabel!.trim(),
        ),
      _WeatherDetailRow(
        label: 'Source',
        value: weather.sourceLabel?.trim().isNotEmpty == true
            ? weather.sourceLabel!.trim()
            : (weather.source?.trim().isNotEmpty == true
                  ? weather.source!.trim()
                  : 'Historical weather archive'),
      ),
    ];

    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final colorScheme = theme.colorScheme;
        final accent = colorScheme.primary;
        final presentation = resolveDayWeatherPresentation(
          dialogContext,
          weather.weatherCode,
        );
        return Dialog(
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 460),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.16),
                  blurRadius: 36,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          presentation.icon,
                          color: presentation.iconColor,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Daily weather',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              presentation.label,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          accent.withValues(alpha: 0.16),
                          accent.withValues(alpha: 0.06),
                        ],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Summary',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _weatherTemperatureDetail(weather),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: accent,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.65,
                        ),
                      ),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < details.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 20,
                              color: colorScheme.outlineVariant.withValues(
                                alpha: 0.55,
                              ),
                            ),
                          _WeatherDetailItem(row: details[i]),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _activitySourceDescription(DailyActivityModel activity) {
    final label = activity.sourceLabel?.trim();
    final source = activity.source?.trim();
    if (label != null && label.isNotEmpty) {
      return '$label daily activity export imported into Blue.';
    }
    if (source == 'google_takeout_google_fit') {
      return 'Google Takeout / Google Fit daily activity export imported into Blue.';
    }
    return 'Imported daily activity data.';
  }

  String _weatherConditionDetail(DailyWeatherModel weather) {
    switch (weather.weatherCode) {
      case 0:
        return 'Sunny';
      case 1:
        return 'Sunny';
      case 2:
        return 'Partly cloudy';
      case 3:
        return 'Overcast';
      case 45:
        return 'Fog';
      case 48:
        return 'Freezing fog';
      case 51:
        return 'Light drizzle';
      case 53:
        return 'Drizzle';
      case 55:
        return 'Heavy drizzle';
      case 56:
        return 'Light freezing drizzle';
      case 57:
        return 'Freezing drizzle';
      case 61:
        return 'Light rain';
      case 63:
        return 'Rain';
      case 65:
        return 'Heavy rain';
      case 66:
        return 'Light freezing rain';
      case 67:
        return 'Freezing rain';
      case 71:
        return 'Light snow';
      case 73:
        return 'Snow';
      case 75:
        return 'Heavy snow';
      case 77:
        return 'Snow grains';
      case 80:
        return 'Light showers';
      case 81:
        return 'Rain showers';
      case 82:
        return 'Heavy showers';
      case 85:
        return 'Light snow showers';
      case 86:
        return 'Snow showers';
      case 95:
        return 'Thunderstorm';
      case 96:
        return 'Thunderstorm with hail';
      case 99:
        return 'Severe storm with hail';
      default:
        return 'Weather summary';
    }
  }

  String _weatherTemperatureDetail(DailyWeatherModel weather) {
    final max = weather.temperatureMaxC;
    final min = weather.temperatureMinC;
    if (max == null && min == null) return 'No temperature range available';
    if (max != null && min != null) {
      return '${max.toStringAsFixed(0)}° high • ${min.toStringAsFixed(0)}° low';
    }
    if (max != null) return '${max.toStringAsFixed(0)}° high';
    return '${min!.toStringAsFixed(0)}° low';
  }

  String _weatherFeelsLikeDetail(DailyWeatherModel weather) {
    final max = weather.apparentTemperatureMaxC;
    final min = weather.apparentTemperatureMinC;
    if (max != null && min != null) {
      return '${max.toStringAsFixed(0)}° high • ${min.toStringAsFixed(0)}° low';
    }
    if (max != null) return '${max.toStringAsFixed(0)}° high';
    if (min != null) return '${min.toStringAsFixed(0)}° low';
    return 'Unavailable';
  }

  String _weatherClockLabel(DateTime value, String? timezoneName) {
    final tz = (timezoneName ?? '').trim();
    if (tz.isNotEmpty) {
      return DateFormat('HH:mm').format(value);
    }
    return DateFormat('HH:mm').format(value.toLocal());
  }

  String _formatSteps(int steps) {
    if (steps >= 1000) {
      return '${(steps / 1000.0).toStringAsFixed(1)}k';
    }
    return '$steps';
  }

  String _formatCount(int value) {
    return NumberFormat.decimalPattern().format(value);
  }

  Widget _buildRunTile(BuildContext context, RunModel run) {
    final colorScheme = Theme.of(context).colorScheme;
    final pace = run.averageSpeed > 0 ? _formatRunPace(run.averageSpeed) : null;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openRunDetail(run),
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 40,
                  width: 40,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.directions_run, color: colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    run.name.isEmpty ? 'Run ${run.id}' : run.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              '${run.distanceKm.toStringAsFixed(1)} km',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (run.startTime.isNotEmpty) run.startTime,
                if (run.movingMinutes > 0) '${run.movingMinutes} min',
                if (pace != null) pace,
              ].join(' · '),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
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
        ),
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, size: 28, color: colorScheme.onSurfaceVariant),
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
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildUploadQueue(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: _uploadQueue.map((item) {
        final isDone = item.status == UploadItemStatus.done;
        final hasError = item.status == UploadItemStatus.failed;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: hasError
                  ? colorScheme.error.withValues(alpha: 0.35)
                  : colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: Image.file(
                    File(item.localPath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => ColoredBox(
                      color: colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.photo_outlined,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: hasError ? null : item.progress.clamp(0, 1),
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      hasError
                          ? (item.errorMessage ?? 'Upload failed')
                          : isDone
                          ? 'Uploaded'
                          : item.status == UploadItemStatus.processing
                          ? 'Processing'
                          : '${(item.progress * 100).round()}%',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: hasError
                            ? colorScheme.error
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _infoBadge({required IconData icon, required String label}) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: isDark
            ? colorScheme.surfaceContainerHighest
            : colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isDark
                ? colorScheme.primary
                : colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: isDark
                  ? colorScheme.onSurface
                  : colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }

  String? _formatRunPace(double averageSpeedMetersPerSecond) {
    if (averageSpeedMetersPerSecond <= 0) return null;
    final secondsPerKm = 1000 / averageSpeedMetersPerSecond;
    final minutes = secondsPerKm ~/ 60;
    final seconds = (secondsPerKm.round() % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds /km';
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
    final colorScheme = Theme.of(context).colorScheme;
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

        const maxCollapsed = 24;
        final showAll = _galleryExpanded || _media.length <= maxCollapsed;
        final visibleCount = showAll ? _media.length : maxCollapsed;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: visibleCount,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: childAspectRatio,
              ),
              itemBuilder: (context, index) {
                final item = _media[index];
                final url = _galleryThumbUrl(item);
                final isCover = _isSelectedMedia(model, item);
                return InkWell(
                  onLongPress: _heroPickerEnabled || _uploadQueue.isNotEmpty
                      ? null
                      : () => _setHighlight(item),
                  onTap: () => _heroPickerEnabled
                      ? _setHighlight(item)
                      : _showImagePreview(item),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainer,
                      border: Border.all(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.6,
                        ),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 12,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ProtectedNetworkImage(
                          imageUrl: url,
                          headers: _authHeaders(),
                          fit: BoxFit.cover,
                          placeholder: ColoredBox(
                            color: colorScheme.surfaceContainerHighest,
                            child: const Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ),
                          errorWidget: GestureDetector(
                            onTap: () {
                              setState(() {});
                            },
                            child: ColoredBox(
                              color: colorScheme.surfaceContainerHighest,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.broken_image_outlined,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Tap to retry',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
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
                        if (isCover)
                          Positioned(
                            top: 10,
                            right: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.56),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                'Cover',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (!showAll)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TextButton(
                  onPressed: () => setState(() => _galleryExpanded = true),
                  child: Text('Show all ${_media.length} photos'),
                ),
              ),
          ],
        );
      },
    );
  }

  static const _videoExtensions = {'.mp4', '.mov', '.avi', '.wmv'};
  static const _rawExtensions = {
    '.dng',
    '.cr2',
    '.cr3',
    '.nef',
    '.arw',
    '.orf',
    '.rw2',
    '.raf',
    '.srw',
  };

  static bool _isVideoFile(String name) {
    final lower = name.toLowerCase();
    return _videoExtensions.any((ext) => lower.endsWith(ext));
  }

  static bool _isRawFile(String name) {
    final lower = name.toLowerCase();
    return _rawExtensions.any((ext) => lower.endsWith(ext));
  }

  /// For videos and raw files, the compressed version is a .jpg with the same stem.
  static String _compressedJpgName(String name) {
    final stem = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    return '$stem.jpg';
  }

  String _galleryThumbUrl(DayMediaModel media) {
    final date = media.date;
    final name = media.fileName;
    if (date.isNotEmpty && name.isNotEmpty) {
      final compressedName = (_isVideoFile(name) || _isRawFile(name))
          ? _compressedJpgName(name)
          : name;
      return _authenticatedUrl(
        '${AppConfig.backendUrl}/api/images/$date/compressed/$compressedName',
      );
    }
    return _authenticatedUrl(
      AppConfig.imageUrlFromPath(media.path, date: media.date),
    );
  }

  String _galleryFullUrl(DayMediaModel media) {
    final date = media.date;
    final name = media.fileName;
    if (date.isNotEmpty && name.isNotEmpty) {
      // Raw files can't be displayed — use the compressed JPEG instead.
      if (_isRawFile(name)) {
        return _authenticatedUrl(
          '${AppConfig.backendUrl}/api/images/$date/compressed/${_compressedJpgName(name)}',
        );
      }
      return _authenticatedUrl(
        '${AppConfig.backendUrl}/api/images/$date/$name',
      );
    }
    return _authenticatedUrl(
      AppConfig.imageUrlFromPath(media.path, date: media.date),
    );
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
      final previewName = _isVideoFile(highlight)
          ? '${highlight.substring(0, highlight.lastIndexOf('.'))}.jpg'
          : highlight;
      return _HeroImageAsset(
        previewUrl: _authenticatedUrl(
          '${AppConfig.backendUrl}/api/images/${model.date}/compressed/$previewName',
        ),
        fullUrl: _authenticatedUrl(
          '${AppConfig.backendUrl}/api/images/${model.date}/$highlight',
        ),
      );
    }

    final fullUrl = _authenticatedUrl(
      AppConfig.imageUrlFromPath(highlight, date: model.date),
    );
    return _HeroImageAsset(previewUrl: fullUrl, fullUrl: fullUrl);
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
}

class _CalendarEventTile extends StatelessWidget {
  const _CalendarEventTile({
    required this.event,
    required this.onTap,
    required this.showConnector,
  });

  final CalendarEventModel event;
  final ValueChanged<CalendarEventModel> onTap;
  final bool showConnector;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final timeLabel = _timePresentation(event);

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => onTap(event),
      child: Container(
        width: double.infinity,
        margin: EdgeInsets.only(bottom: showConnector ? 12 : 0),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 86,
                child: Column(
                  children: [
                    Container(
                      width: 72,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        timeLabel,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                          height: 1.0,
                        ),
                      ),
                    ),
                    if (showConnector)
                      Expanded(
                        child: Container(
                          width: 2,
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            color: colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.7),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              event.summary.isEmpty
                                  ? 'Untitled event'
                                  : event.summary,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              event.allDay ? 'All day' : 'Scheduled',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _CalendarMetaPill(
                            icon: Icons.schedule_rounded,
                            label: _calendarDetailTimeLabel(event),
                          ),
                          if (event.location.isNotEmpty)
                            _CalendarMetaPill(
                              icon: Icons.place_rounded,
                              label: event.location,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _timePresentation(CalendarEventModel event) {
    if (event.allDay) return 'All day';
    final start = parseCalendarEventDateTime(event.start);
    if (start == null) return 'Time';
    return DateFormat('HH:mm').format(start);
  }
}

String _calendarDetailTimeLabel(CalendarEventModel event) {
  if (event.allDay) return 'All day';
  final start = parseCalendarEventDateTime(event.start);
  final end = parseCalendarEventDateTime(event.end);
  if (start == null) return 'Time unavailable';
  final startLabel = DateFormat('HH:mm').format(start);
  if (end == null) return startLabel;
  final endLabel = DateFormat('HH:mm').format(end);
  return '$startLabel – $endLabel';
}

class _CalendarMetaPill extends StatelessWidget {
  const _CalendarMetaPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CalendarEmptyState extends StatelessWidget {
  const _CalendarEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.isError = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accent = isError ? colorScheme.error : colorScheme.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: isError ? colorScheme.error : colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isError
                        ? colorScheme.error.withValues(alpha: 0.9)
                        : colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityMetricDetail {
  const _ActivityMetricDetail({
    required this.title,
    required this.icon,
    required this.accentColor,
    required this.value,
    required this.explanation,
    required this.source,
  });

  final String title;
  final IconData icon;
  final Color accentColor;
  final String value;
  final String explanation;
  final String source;
}

class _WeatherDetailRow {
  const _WeatherDetailRow({required this.label, required this.value});

  final String label;
  final String value;
}

class _WeatherDetailItem extends StatelessWidget {
  const _WeatherDetailItem({required this.row});

  final _WeatherDetailRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(
            row.label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            row.value,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaceEditorSheet extends StatefulWidget {
  const _PlaceEditorSheet({
    required this.initialPlace,
    required this.initialCountry,
    required this.placeSuggestions,
    required this.countrySuggestions,
    required this.statusText,
    required this.errorText,
  });

  final String initialPlace;
  final String initialCountry;
  final List<String> placeSuggestions;
  final List<String> countrySuggestions;
  final String statusText;
  final String? errorText;

  @override
  State<_PlaceEditorSheet> createState() => _PlaceEditorSheetState();
}

class _PlaceEditorSheetState extends State<_PlaceEditorSheet> {
  late final TextEditingController _placeController;
  late final TextEditingController _countryController;

  @override
  void initState() {
    super.initState();
    _placeController = TextEditingController(text: widget.initialPlace);
    _countryController = TextEditingController(text: widget.initialCountry);
  }

  @override
  void dispose() {
    _placeController.dispose();
    _countryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        12 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 28,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Where were you?',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _placeController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Place',
                    hintText: 'City, neighborhood, spot',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _countryController,
                  decoration: const InputDecoration(
                    labelText: 'Country',
                    hintText: 'Country',
                  ),
                ),
                if (widget.placeSuggestions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.placeSuggestions
                        .map(
                          (item) => ActionChip(
                            label: Text(item),
                            onPressed: () => _placeController.text = item,
                          ),
                        )
                        .toList(),
                  ),
                ],
                if (widget.countrySuggestions.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.countrySuggestions
                        .map(
                          (item) => ActionChip(
                            label: Text(item),
                            onPressed: () => _countryController.text = item,
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.errorText ?? widget.statusText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: widget.errorText != null
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop((
                          place: _placeController.text.trim(),
                          country: _countryController.text.trim(),
                        ));
                      },
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
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
      final provider = await loadProtectedImageProvider(
        asset.fullUrl,
        headers: widget.headers,
      );
      await precacheImage(provider, context);
      if (!mounted || _fullReadyUrl != asset.fullUrl) return;
      setState(() {
        _fullReady = true;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (asset == null || asset.previewUrl.isEmpty) {
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
                : [colorScheme.primaryContainer, colorScheme.surface],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ProtectedNetworkImage(
          imageUrl: asset.previewUrl,
          headers: widget.headers,
          fit: BoxFit.cover,
          placeholder: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        colorScheme.surfaceContainerHighest,
                        colorScheme.surfaceContainer,
                      ]
                    : [colorScheme.primaryContainer, colorScheme.surface],
              ),
            ),
            child: const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ),
          errorWidget: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        colorScheme.surfaceContainerHighest,
                        colorScheme.surfaceContainer,
                      ]
                    : [colorScheme.primaryContainer, colorScheme.surface],
              ),
            ),
            child: Center(
              child: Icon(
                Icons.image_not_supported_outlined,
                color: colorScheme.onSurfaceVariant,
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
            child: FutureBuilder<ImageProvider<Object>>(
              future: loadProtectedImageProvider(
                asset.fullUrl,
                headers: widget.headers,
              ),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const SizedBox.shrink();
                }
                return Image(
                  image: snapshot.data!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                );
              },
            ),
          ),
      ],
    );
  }
}
