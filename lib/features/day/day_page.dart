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
import '../../data/graphql/documents.dart';
import '../../core/widgets/section_card.dart';
import '../../data/models/daily_activity_model.dart';
import '../../data/models/day_media_model.dart';
import '../../data/models/day_payload_model.dart';
import '../../data/models/person_model.dart';
import '../../data/models/run_model.dart';
import '../../data/models/story_day_model.dart';
import '../../data/models/upload_batch_state_model.dart';
import '../../data/repositories/person_repository.dart';
import '../../providers.dart';
import 'day_draft_controller.dart';
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
  DailyActivityModel? _dailyActivity;
  List<UploadItemStateModel> _uploadQueue = const [];

  bool _loading = true;
  bool _saving = false;
  bool _transitioningDay = false;
  bool _heroPickerEnabled = false;
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
    _markDirtyAndScheduleAutosave();
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

  void _markDirtyAndScheduleAutosave() {
    if (!_dirty) {
      _syncDraftStatus();
      return;
    }
    _syncDraftStatus('Unsaved changes');
  }

  Future<void> _loadDate(DateTime date) async {
    final normalized = DateUtils.dateOnly(date);
    final day = formatYmd(normalized);
    final isFutureDay = _isFutureDate(normalized);
    final requestId = ++_activeLoadId;
    _activeDayKey = day;
    _lastNavigationAt = DateTime.now();
    ref.read(dayDraftControllerProvider.notifier).setCurrentDay(day);

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
      });
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
        );
        setState(() {
          _loading = false;
          _transitioningDay = false;
        });
      }
      unawaited(_refreshDate(normalized, requestId));
      return;
    }

    setState(() {
      _loading = _current == null;
      _transitioningDay = _current != null;
      _status = '';
    });
    await _refreshDate(normalized, requestId);
  }

  Future<void> _refreshDate(DateTime date, int requestId) async {
    final day = formatYmd(date);
    final isFutureDay = _isFutureDate(date);

    try {
      final basePayload = await ref
          .read(dayRepositoryProvider)
          .getDayCorePayload(day);
      final payload = isFutureDay
          ? basePayload.copyWith(
              runs: const <RunModel>[],
              detailsLoaded: true,
            )
          : basePayload;
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

  Future<void> _loadDailyActivity(String day) async {
    try {
      final gql = ref.read(graphqlServiceProvider);
      final response = await gql.query(
        GqlDocuments.dailyActivity,
        variables: {'date': day},
      );
      if (!mounted) return;
      final edges = (((response['health'] as Map<String, dynamic>?)?['dailyActivity']
              as Map<String, dynamic>?)?['edges'] as List<dynamic>?) ??
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
    if (prefetchAdjacent && !_isRapidNavigation() && !isFutureDay) {
      unawaited(_prefetchAdjacentDays(DateUtils.dateOnly(parseYmd(day))));
    }
  }

  void _applyVisiblePayload(
    DayPayloadModel payload, {
    required bool detailsLoaded,
    bool clearStatus = false,
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
        _dailyActivity = payload.activity;
        _heroAsset = heroAsset;
        if (clearStatus) _status = '';
      });
    } else {
      // User is editing — never touch text or story model
      setState(() {
        _media = payload.media;
        _runs = payload.runs;
        if (payload.activity != null) _dailyActivity = payload.activity;
        _heroAsset = heroAsset;
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
      final payload = await ref.read(dayRepositoryProvider).getDayCorePayload(day);
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
      await precacheImage(
        CachedNetworkImageProvider(url, headers: _authHeaders()),
        context,
      );
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
    if (_dirty) {
      unawaited(_saveNow());
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
    var focusedDay = DateUtils.dateOnly(initialDate);
    var selectedDay = DateUtils.dateOnly(initialDate);
    final now = DateUtils.dateOnly(DateTime.now());
    final years = List<int>.generate(
      now.year - 2005 + 2,
      (index) => 2005 + index,
    );
    const monthNames = <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        colorScheme.surfaceContainerHighest,
                        colorScheme.surfaceContainer,
                      ],
                    ),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.38),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.22),
                        blurRadius: 36,
                        offset: const Offset(0, 18),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
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
                                  'Jump to date',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  DateFormat(
                                    'EEEE, d MMMM y',
                                  ).format(selectedDay),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () {
                                setDialogState(() {
                                  selectedDay = now;
                                  focusedDay = now;
                                });
                              },
                              icon: const Icon(Icons.today_rounded),
                              label: const Text('Today'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () {
                                final target = DateUtils.dateOnly(
                                  selectedDay.subtract(const Duration(days: 1)),
                                );
                                setDialogState(() {
                                  selectedDay = target;
                                  focusedDay = target;
                                });
                              },
                              icon: const Icon(Icons.chevron_left_rounded),
                              label: const Text('Prev'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: selectedDay.isBefore(now)
                                  ? () {
                                      final target = DateUtils.dateOnly(
                                        selectedDay.add(
                                          const Duration(days: 1),
                                        ),
                                      );
                                      setDialogState(() {
                                        final clamped = target.isAfter(now)
                                            ? now
                                            : target;
                                        selectedDay = clamped;
                                        focusedDay = clamped;
                                      });
                                    }
                                  : null,
                              icon: const Icon(Icons.chevron_right_rounded),
                              label: const Text('Next'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: focusedDay.month,
                              decoration: const InputDecoration(
                                labelText: 'Month',
                              ),
                              items: List.generate(
                                12,
                                (index) => DropdownMenuItem<int>(
                                  value: index + 1,
                                  child: Text(monthNames[index]),
                                ),
                              ),
                              onChanged: (value) {
                                if (value == null) return;
                                final daysInMonth = DateUtils.getDaysInMonth(
                                  focusedDay.year,
                                  value,
                                );
                                final adjusted = DateTime(
                                  focusedDay.year,
                                  value,
                                  selectedDay.day.clamp(1, daysInMonth),
                                );
                                setDialogState(() {
                                  final normalized = DateUtils.dateOnly(
                                    adjusted,
                                  );
                                  final clamped = normalized.isAfter(now)
                                      ? now
                                      : normalized;
                                  focusedDay = clamped;
                                  selectedDay = clamped;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: focusedDay.year,
                              decoration: const InputDecoration(
                                labelText: 'Year',
                              ),
                              items: years
                                  .map(
                                    (year) => DropdownMenuItem<int>(
                                      value: year,
                                      child: Text('$year'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) {
                                if (value == null) return;
                                final daysInMonth = DateUtils.getDaysInMonth(
                                  value,
                                  focusedDay.month,
                                );
                                final adjusted = DateTime(
                                  value,
                                  focusedDay.month,
                                  selectedDay.day.clamp(1, daysInMonth),
                                );
                                setDialogState(() {
                                  final normalized = DateUtils.dateOnly(
                                    adjusted,
                                  );
                                  final clamped = normalized.isAfter(now)
                                      ? now
                                      : normalized;
                                  focusedDay = clamped;
                                  selectedDay = clamped;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Container(
                        decoration: BoxDecoration(
                          color: colorScheme.surface,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
                        child: TableCalendar<void>(
                          firstDay: DateTime(2005),
                          lastDay: now,
                          focusedDay: focusedDay,
                          currentDay: now,
                          selectedDayPredicate: (day) =>
                              isSameDay(day, selectedDay),
                          availableCalendarFormats: const {
                            CalendarFormat.month: 'Month',
                          },
                          calendarFormat: CalendarFormat.month,
                          headerVisible: false,
                          daysOfWeekHeight: 28,
                          rowHeight: 44,
                          calendarStyle: CalendarStyle(
                            todayDecoration: BoxDecoration(
                              color: colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            todayTextStyle: TextStyle(
                              color: colorScheme.onSecondaryContainer,
                              fontWeight: FontWeight.w800,
                            ),
                            selectedDecoration: BoxDecoration(
                              color: colorScheme.primary,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            selectedTextStyle: TextStyle(
                              color: colorScheme.onPrimary,
                              fontWeight: FontWeight.w900,
                            ),
                            weekendTextStyle: TextStyle(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                            outsideTextStyle: TextStyle(
                              color: colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.52,
                              ),
                            ),
                            defaultTextStyle: TextStyle(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                            cellMargin: const EdgeInsets.all(3),
                          ),
                          daysOfWeekStyle: DaysOfWeekStyle(
                            weekdayStyle: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                            weekendStyle: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
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
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () =>
                              Navigator.of(context).pop(selectedDay),
                          style: FilledButton.styleFrom(
                            backgroundColor: colorScheme.primary,
                            foregroundColor: colorScheme.onPrimary,
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
    _markDirtyAndScheduleAutosave();
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
    _markDirtyAndScheduleAutosave();
    return true;
  }

  Future<void> _showAddPersonSheet() async {
    final selectedNames = _current?.people ?? const <String>[];
    final selected = await showModalBottomSheet<PersonModel>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _AddPersonSheet(
        repository: ref.read(personRepositoryProvider),
        selectedNames: selectedNames,
      ),
    );
    if (!mounted || selected == null) return;
    _appendPersonName(selected.displayName);
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

  void _addTag() {
    final value = _tagInput.text.trim();
    if (value.isEmpty || _current == null) return;

    final tags = [..._current!.tags, value];
    setState(() {
      _current = _current!.copyWith(keywords: tags.join(';'));
      _tagInput.clear();
    });
    _markDirtyAndScheduleAutosave();
  }

  void _removeTag(String tag) {
    if (_current == null) return;
    final tags = [..._current!.tags]..remove(tag);
    setState(() => _current = _current!.copyWith(keywords: tags.join(';')));
    _markDirtyAndScheduleAutosave();
  }

  Future<bool> _saveNow() async {
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
        final colorScheme = Theme.of(context).colorScheme;
        return Dialog(
          insetPadding: const EdgeInsets.all(18),
          backgroundColor: Colors.transparent,
          child: CachedNetworkImage(
            imageUrl: _galleryFullUrl(media),
            fit: BoxFit.contain,
            httpHeaders: _authHeaders(),
            errorWidget: (_, __, ___) => Container(
              height: 260,
              color: colorScheme.surfaceContainerHighest,
              child: Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
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
    _place.text = result.place.trim();
    _country.text = result.country.trim();
    _markDirtyAndScheduleAutosave();
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

    return GestureDetector(
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
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(16, 16, 16, 28 + bottomInset),
              children: [
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
                _buildOverviewCard(context, draft),
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
                if (_dailyActivity != null) ...[
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'Activity',
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                    child: _buildActivityBar(context),
                  ),
                ],
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
                    onPressed: draft.uploading ? null : _uploadFiles,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('Upload'),
                  ),
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
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            right: 18,
            bottom: _dirty ? (18 + bottomInset) : -(72 + bottomInset),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: _dirty ? 1.0 : 0.0,
              child: FloatingActionButton.extended(
                onPressed: _saving ? null : () => unawaited(_saveNow()),
                backgroundColor: _heroAccent,
                foregroundColor: Colors.white,
                elevation: 6,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_saving ? 'Saving…' : 'Save'),
              ),
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
    required DayDraftState draft,
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
                    if (draft.statusText.isNotEmpty)
                      _glassStatusPill(
                        context,
                        draft.statusText,
                        color: draft.hasError
                            ? const Color(0xFF832C2C)
                            : _heroAccent,
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
          colors: isDark
              ? [
                  Color.lerp(_heroAccent, colorScheme.surface, 0.86) ??
                      colorScheme.surfaceContainer,
                  colorScheme.surfaceContainerHighest,
                ]
              : [
                  Color.lerp(_heroAccent, Colors.white, 0.9) ??
                      const Color(0xFFF8FBFF),
                  Colors.white,
                ],
        ),
        border: Border.all(
          color: isDark
              ? colorScheme.outlineVariant.withValues(alpha: 0.55)
              : (Color.lerp(_heroAccent, Colors.white, 0.78) ??
                    const Color(0xFFD9E4F2)),
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
              onPressed: draft.uploading ? null : _uploadFiles,
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

  Widget _buildRunsEventsSection(BuildContext context) {
    if (_isFutureDayActive) {
      return _buildEmptyState(
        context,
        icon: Icons.edit_calendar_outlined,
        title: 'Future day',
        subtitle:
            'No runs or events yet. Use it for planning, notes, and media.',
      );
    }

    if (_runs.isEmpty) {
      return _buildEmptyState(
        context,
        icon: Icons.directions_run_outlined,
        title: 'No runs',
        subtitle: 'Nothing synced for this date.',
      );
    }

    return SizedBox(
      height: 118,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _runs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) => _buildRunTile(context, _runs[index]),
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
    final colorScheme = Theme.of(context).colorScheme;
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
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
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
    final colorScheme = Theme.of(context).colorScheme;
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
                    backgroundColor: colorScheme.secondaryContainer,
                    labelStyle: TextStyle(
                      color: colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                    side: BorderSide.none,
                    label: Text(item),
                    onPressed: () => _openPersonFromName(item),
                    deleteIconColor: colorScheme.onSecondaryContainer,
                    onDeleted: () => _removePerson(item),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }

  Widget _buildActivityBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final act = _dailyActivity!;

    final steps = act.stepCount;
    final distKm = act.distanceM != null ? act.distanceM! / 1000.0 : null;
    final cyclingMin = act.cyclingDurationMs != null
        ? (act.cyclingDurationMs! / 60000).round()
        : null;

    return Row(
      children: [
        if (steps != null)
          Expanded(
            child: _activityChip(
              context,
              icon: Icons.directions_walk_rounded,
              value: _formatSteps(steps),
              label: 'steps',
              color: colorScheme.primary,
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
              color: const Color(0xFF1A7A4A),
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
            ),
          ),
        ],
      ],
    );
  }

  Widget _activityChip(
    BuildContext context, {
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
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
    );
  }

  String _formatSteps(int steps) {
    if (steps >= 1000) {
      return '${(steps / 1000.0).toStringAsFixed(1)}k';
    }
    return '$steps';
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
          headers: _authHeaders(),
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
            ? Color.lerp(_heroAccent, colorScheme.surface, 0.82) ??
                  colorScheme.surfaceContainerHighest
            : (Color.lerp(_heroAccent, Colors.white, 0.88) ??
                  const Color(0xFFEFF4FB)),
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
              color: isDark
                  ? colorScheme.onSurface
                  : (Color.lerp(_heroAccent, Colors.black, 0.35) ??
                        const Color(0xFF173B73)),
              fontWeight: FontWeight.w700,
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
                    color: colorScheme.outlineVariant.withValues(alpha: 0.6),
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
                    CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      httpHeaders: _authHeaders(),
                      errorWidget: (_, __, ___) => ColoredBox(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: colorScheme.onSurfaceVariant,
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
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      'X-Blue-Client': 'mobile',
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
    final colorScheme = Theme.of(context).colorScheme;
    final query = _searchController.text.trim();
    final visibleResults = query.length < 2 ? _popular : _results;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        12 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.38),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 32,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
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
                          color: colorScheme.onSurface,
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
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final person = visibleResults[index];
                              final alreadySelected = _isAlreadySelected(
                                person,
                              );
                              final subtitle = [
                                person.relation.trim(),
                                person.profession.trim(),
                              ].where((part) => part.isNotEmpty).join(' · ');
                              return Material(
                                color: alreadySelected
                                    ? colorScheme.secondaryContainer
                                    : colorScheme.surfaceContainer,
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
                                          ? colorScheme.onSecondaryContainer
                                          : null,
                                    ),
                                  ),
                                  subtitle: subtitle.isEmpty
                                      ? null
                                      : Text(subtitle),
                                  trailing: Icon(
                                    alreadySelected
                                        ? Icons.check_circle_rounded
                                        : Icons.add_circle_outline_rounded,
                                    color: alreadySelected
                                        ? colorScheme.primary
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
          ),
        ),
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
    final colorScheme = Theme.of(context).colorScheme;
    final hasSubtitle = subtitle.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: colorScheme.onSurfaceVariant, size: 28),
          const SizedBox(height: 10),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
          if (hasSubtitle) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
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
                : const [Color(0xFF9FBEEA), Color(0xFFDCE8FA)],
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
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        colorScheme.surfaceContainerHighest,
                        colorScheme.surfaceContainer,
                      ]
                    : const [Color(0xFF9FBEEA), Color(0xFFDCE8FA)],
              ),
            ),
            child: Center(
              child: Icon(
                Icons.image_not_supported_outlined,
                color: isDark ? colorScheme.onSurfaceVariant : Colors.white,
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
