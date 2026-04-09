import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/network/graphql_service.dart';
import '../../core/utils/breakpoints.dart';
import '../../data/graphql/documents.dart';
import '../../data/models/data_source_status_model.dart';
import '../../providers.dart';

class DataSourcesPage extends ConsumerStatefulWidget {
  const DataSourcesPage({super.key});

  @override
  ConsumerState<DataSourcesPage> createState() => _DataSourcesPageState();
}

class _DataSourcesPageState extends ConsumerState<DataSourcesPage> {
  late Future<List<DataSourceStatusModel>> _sourcesFuture;
  bool _timelineImporting = false;
  bool _takeoutImporting = false;
  bool _calendarLoading = false;
  bool _calendarImporting = false;
  String? _timelineImportResult;
  String? _takeoutImportResult;
  String? _calendarResult;
  String? _calendarImportResult;

  @override
  void initState() {
    super.initState();
    _sourcesFuture = _loadSources();
  }

  Future<List<DataSourceStatusModel>> _loadSources() {
    return ref.read(systemRepositoryProvider).dataSources();
  }

  Future<void> _refreshSources() async {
    final future = _loadSources();
    setState(() {
      _sourcesFuture = future;
    });
    await future;
  }

  Future<void> _importTimeline() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final bytes = picked.files.first.bytes;
    if (bytes == null) return;

    setState(() {
      _timelineImporting = true;
      _timelineImportResult = null;
    });
    try {
      final graphql = ref.read(graphqlServiceProvider);
      final data = await graphql.mutateMultipartWithProgress(
        r'''
          mutation ImportTakeout($files: [Upload!]!) {
            timeline { importTakeout(files: $files) { message } }
          }
        ''',
        files: [
          MultipartUploadFile(
            filename: picked.files.first.name.isNotEmpty
                ? picked.files.first.name
                : 'Zeitachse.json',
            bytes: bytes,
          ),
        ],
        onProgress: (_, __) {},
        timeout: const Duration(minutes: 5),
      );
      final message =
          (data['timeline'] as Map?)?['importTakeout']?['message'] as String?;
      final resultMessage = message ?? 'Import complete';
      setState(() {
        _timelineImportResult = resultMessage;
      });
      await _refreshSources();
      if (!mounted) return;
      await _showImportDialog(
        title: 'Google Timeline Imported',
        intro: 'Your Google Timeline export was processed.',
        message: resultMessage,
        isError: false,
      );
    } catch (e) {
      final errorMessage = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _timelineImportResult = 'Error: $errorMessage';
      });
      if (!mounted) return;
      await _showImportDialog(
        title: 'Timeline Import Failed',
        intro: 'The Google Timeline JSON could not be processed.',
        message: errorMessage,
        isError: true,
      );
    } finally {
      setState(() {
        _timelineImporting = false;
      });
    }
  }

  Future<void> _importTakeout() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final bytes = picked.files.first.bytes;
    if (bytes == null) return;

    setState(() {
      _takeoutImporting = true;
      _takeoutImportResult = null;
    });
    try {
      final graphql = ref.read(graphqlServiceProvider);
      final data = await graphql.mutateMultipartWithProgress(
        r'''
          mutation ImportTakeout($files: [Upload!]!) {
            health { importTakeout(files: $files) { message } }
          }
        ''',
        files: [
          MultipartUploadFile(
            filename: picked.files.first.name.isNotEmpty
                ? picked.files.first.name
                : 'takeout.zip',
            bytes: bytes,
          ),
        ],
        onProgress: (_, __) {},
        timeout: const Duration(minutes: 5),
      );
      final message =
          (data['health'] as Map?)?['importTakeout']?['message'] as String?;
      final resultMessage = message ?? 'Import complete';
      setState(() {
        _takeoutImportResult = resultMessage;
      });
      await _refreshSources();
      if (!mounted) return;
      await _showImportDialog(
        title: 'Google Takeout Imported',
        intro:
            'The Google Fit summary from your Takeout archive was processed.',
        message: resultMessage,
        isError: false,
      );
    } catch (e) {
      final errorMessage = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _takeoutImportResult = 'Error: $errorMessage';
      });
      if (!mounted) return;
      await _showImportDialog(
        title: 'Import Failed',
        intro: 'The Takeout ZIP could not be processed.',
        message: errorMessage,
        isError: true,
      );
    } finally {
      setState(() {
        _takeoutImporting = false;
      });
    }
  }

  Future<void> _calendarConnect() async {
    await _runCalendarMutation(
      document: GqlDocuments.calendarConnect,
      title: 'Google Calendar Connected',
      intro: 'The current Google Calendar connection was stored and synced.',
      errorTitle: 'Calendar Connection Failed',
      errorIntro:
          'Google Calendar could not be connected. Make sure a Google access token is available from the proxy.',
      responseKey: 'connect',
    );
  }

  Future<void> _calendarSyncNow() async {
    await _runCalendarMutation(
      document: GqlDocuments.calendarSyncNow,
      title: 'Google Calendar Synced',
      intro: 'Your primary Google Calendar was synced into local storage.',
      errorTitle: 'Calendar Sync Failed',
      errorIntro: 'Google Calendar could not be synced.',
      responseKey: 'syncNow',
    );
  }

  Future<void> _importCalendarTakeout() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip', 'ics'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;

    setState(() {
      _calendarImporting = true;
      _calendarImportResult = null;
    });
    try {
      final data = await ref.read(graphqlServiceProvider).mutateMultipartWithProgress(
        GqlDocuments.calendarImportTakeout,
        files: [
          MultipartUploadFile(
            filename: file.name.isNotEmpty ? file.name : 'google-calendar.ics',
            bytes: bytes,
          ),
        ],
        onProgress: (_, __) {},
        timeout: const Duration(minutes: 5),
      );
      final payload =
          (data['calendar'] as Map?)?['importTakeout'] as Map<String, dynamic>?;
      final resultMessage = (payload?['message'] as String?) ?? 'Import complete';
      setState(() {
        _calendarImportResult = resultMessage;
      });
      await _refreshSources();
      if (!mounted) return;
      await _showImportDialog(
        title: 'Google Calendar Imported',
        intro: 'The Google Calendar file was indexed into local storage.',
        message: resultMessage,
        details: _calendarImportLines(payload),
        isError: false,
      );
    } catch (e) {
      final errorMessage = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _calendarImportResult = 'Error: $errorMessage';
      });
      if (!mounted) return;
      await _showImportDialog(
        title: 'Calendar Import Failed',
        intro: 'The Google Calendar ZIP or ICS file could not be processed.',
        message: errorMessage,
        details: _errorLines(errorMessage),
        isError: true,
      );
    } finally {
      setState(() {
        _calendarImporting = false;
      });
    }
  }

  Future<void> _runCalendarMutation({
    required String document,
    required String title,
    required String intro,
    required String errorTitle,
    required String errorIntro,
    required String responseKey,
  }) async {
    setState(() {
      _calendarLoading = true;
      _calendarResult = null;
    });
    try {
      final data = await ref.read(graphqlServiceProvider).mutate(document);
      final message =
          (data['calendar'] as Map?)?[responseKey]?['message'] as String?;
      final resultMessage = message ?? 'Sync complete';
      setState(() {
        _calendarResult = resultMessage;
      });
      await _refreshSources();
      if (!mounted) return;
      await _showImportDialog(
        title: title,
        intro: intro,
        message: resultMessage,
        isError: false,
      );
    } catch (e) {
      final errorMessage = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _calendarResult = 'Error: $errorMessage';
      });
      if (!mounted) return;
      await _showImportDialog(
        title: errorTitle,
        intro: errorIntro,
        message: errorMessage,
        isError: true,
      );
    } finally {
      setState(() {
        _calendarLoading = false;
      });
    }
  }

  Future<void> _showImportDialog({
    required String title,
    required String intro,
    required String message,
    required bool isError,
    List<String>? details,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final lines =
        details ??
        message
            .split(',')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList();

    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          icon: Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_outline,
            color: isError ? colorScheme.error : colorScheme.primary,
          ),
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(intro, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 12),
              ...lines.map(
                (line) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isError ? '• ' : '• ',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Expanded(
                        child: Text(
                          _prettifyImportLine(line),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  String _prettifyImportLine(String line) {
    return line.replaceFirstMapped(
      RegExp(r'^(\d+) (\w+)'),
      (match) => '${match.group(1)} ${_capitalize(match.group(2) ?? '')}',
    );
  }

  String _capitalize(String value) {
    if (value.isEmpty) return value;
    return '${value[0].toUpperCase()}${value.substring(1)}';
  }

  String _formatTimestamp(DateTime? value) {
    if (value == null) return 'Not available yet';
    return DateFormat('MMM d, y · HH:mm').format(value.toLocal());
  }

  List<String> _calendarImportLines(Map<String, dynamic>? payload) {
    if (payload == null) {
      return const ['Import complete'];
    }
    final calendars =
        (payload['calendars'] as List<dynamic>? ?? const [])
            .map((value) => value.toString())
            .where((value) => value.trim().isNotEmpty)
            .toList();
    final errors =
        (payload['errors'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(
              (error) =>
                  '${error['fileName'] ?? 'File'}: ${error['message'] ?? 'Import failed'}',
            )
            .toList();
    return [
      if ((payload['zipFilename'] ?? '').toString().isNotEmpty)
        'File: ${payload['zipFilename']}',
      '${payload['calendarCount'] ?? 0} calendars indexed from ${payload['fileCount'] ?? 0} ICS files',
      '${payload['inserted'] ?? 0} inserted',
      '${payload['updated'] ?? 0} updated',
      '${payload['skipped'] ?? 0} unchanged',
      if (calendars.isNotEmpty) 'Calendars: ${calendars.join(', ')}',
      ...errors,
    ];
  }

  List<String> _errorLines(String message) {
    final normalized = message.replaceAll(';', ',');
    final lines = normalized
        .split(',')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.isEmpty ? <String>[message] : lines;
  }

  String _sectionTitle(List<DataSourceStatusModel> sources) {
    final hasAutomated = sources.any((source) => source.automated);
    final hasLiveData = sources.any((source) => source.lastSyncAt != null);
    final hasManualUpload = sources.any(
      (source) =>
          source.key == 'google_timeline' ||
          source.key == 'google_takeout' ||
          source.key == 'google_calendar_import',
    );
    if (hasAutomated) return 'Automated';
    if (hasManualUpload) return 'Manual';
    if (hasLiveData) return 'Manual';
    return 'Planned';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;

    return Scaffold(
      appBar: AppBar(title: const Text('Data Sources')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Breakpoints.compact),
          child: FutureBuilder<List<DataSourceStatusModel>>(
            future: _sourcesFuture,
            builder: (context, snapshot) {
              final sources = snapshot.data ?? const <DataSourceStatusModel>[];
              final connected = sources
                  .where((source) => source.lastSyncAt != null)
                  .length;
              final groups = <List<DataSourceStatusModel>>[
                sources.where((source) => source.automated).toList(),
                sources
                    .where(
                      (source) =>
                          !source.automated &&
                          (source.lastSyncAt != null ||
                              source.key == 'google_timeline' ||
                              source.key == 'google_takeout' ||
                              source.key == 'google_calendar_import'),
                    )
                    .toList(),
                sources
                    .where(
                      (source) =>
                          !source.automated &&
                          source.lastSyncAt == null &&
                          source.key != 'google_timeline' &&
                          source.key != 'google_calendar_import',
                    )
                    .toList(),
              ].where((group) => group.isNotEmpty).toList();

              return RefreshIndicator(
                onRefresh: _refreshSources,
                child: ListView(
                  padding: EdgeInsets.symmetric(
                    horizontal: screenWidth > Breakpoints.compact ? 32 : 20,
                    vertical: 20,
                  ),
                  children: [
                    _DataSourcesHeader(
                      totalSources: sources.length,
                      connectedSources: connected,
                    ),
                    const SizedBox(height: 24),
                    if (snapshot.hasError)
                      Card(
                        child: ListTile(
                          leading: Icon(
                            Icons.error_outline_rounded,
                            color: colorScheme.error,
                          ),
                          title: const Text('Could not load source status'),
                          subtitle: Text(
                            snapshot.error.toString().replaceFirst(
                              'Exception: ',
                              '',
                            ),
                          ),
                          trailing: TextButton(
                            onPressed: _refreshSources,
                            child: const Text('Retry'),
                          ),
                        ),
                      )
                    else if (!snapshot.hasData)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      ...groups.map(
                        (group) => Padding(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: _SourceSection(
                            title: _sectionTitle(group),
                            children: group
                                .map(
                                  (source) => Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: _DataSourceCard(
                                      source: source,
                                      importResult: switch (source.key) {
                                        'google_timeline' =>
                                          _timelineImportResult,
                                        'google_takeout' =>
                                          _takeoutImportResult,
                                        'google_calendar' => _calendarResult,
                                        'google_calendar_import' =>
                                          _calendarImportResult,
                                        _ => null,
                                      },
                                      importing: switch (source.key) {
                                        'google_timeline' => _timelineImporting,
                                        'google_takeout' => _takeoutImporting,
                                        'google_calendar' => _calendarLoading,
                                        'google_calendar_import' =>
                                          _calendarImporting,
                                        _ => false,
                                      },
                                      onImport: switch (source.key) {
                                        'google_timeline' => _importTimeline,
                                        'google_takeout' => _importTakeout,
                                        'google_calendar' =>
                                          source.status.toLowerCase().contains(
                                                'needs connection',
                                              )
                                              ? _calendarConnect
                                              : _calendarSyncNow,
                                        'google_calendar_import' =>
                                          _importCalendarTakeout,
                                        _ => null,
                                      },
                                      formatTimestamp: _formatTimestamp,
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DataSourcesHeader extends StatelessWidget {
  const _DataSourcesHeader({
    required this.totalSources,
    required this.connectedSources,
  });

  final int totalSources;
  final int connectedSources;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'Data integrations',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Manage imports and monitor sync state in one place.',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$connectedSources of $totalSources sources have synced data available.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceSection extends StatelessWidget {
  const _SourceSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    );
  }
}

class _DataSourceCard extends StatelessWidget {
  const _DataSourceCard({
    required this.source,
    required this.formatTimestamp,
    this.importResult,
    this.importing = false,
    this.onImport,
  });

  final DataSourceStatusModel source;
  final String Function(DateTime? value) formatTimestamp;
  final String? importResult;
  final bool importing;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accentColor = _accentColor(colorScheme);
    final statusTone = _statusTone(colorScheme);
    final note = importResult ?? source.detail ?? source.description;

    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_icon(), color: accentColor),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              source.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          _StatusPill(
                            label: source.status,
                            background: statusTone.$1,
                            foreground: statusTone.$2,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        source.automated ? 'Automated source' : 'Manual source',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: accentColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        note,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      if (source.key == 'google_takeout') ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerLowest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Included product',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Google Fit',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Indexed data: daily activity totals including move minutes, calories, distance, heart points, heart minutes and steps.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Last sync',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          formatTimestamp(source.lastSyncAt),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (onImport != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: importing
                    ? OutlinedButton.icon(
                        onPressed: null,
                        icon: const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        label: Text(_uploadingLabel()),
                      )
                    : FilledButton.icon(
                        onPressed: onImport,
                        icon: Icon(_buttonIcon()),
                        label: Text(_buttonLabel()),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _icon() {
    switch (source.key) {
      case 'google_timeline':
        return Icons.route_rounded;
      case 'strava':
        return Icons.directions_run_rounded;
      case 'google_fit':
      case 'google_takeout':
        return Icons.folder_zip_rounded;
      case 'google_calendar':
      case 'google_calendar_import':
        return Icons.calendar_month_rounded;
      default:
        return Icons.storage_rounded;
    }
  }

  Color _accentColor(ColorScheme colorScheme) {
    if (source.automated) return colorScheme.primary;
    if (source.lastSyncAt != null) return colorScheme.secondary;
    return colorScheme.tertiary;
  }

  (Color, Color) _statusTone(ColorScheme colorScheme) {
    final lower = source.status.toLowerCase();
    if (lower.contains('planned')) {
      return (colorScheme.surfaceContainerHigh, colorScheme.onSurfaceVariant);
    }
    if (lower.contains('waiting') || lower.contains('ready')) {
      return (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer);
    }
    return (colorScheme.primaryContainer, colorScheme.onPrimaryContainer);
  }

  String _buttonLabel() {
    switch (source.key) {
      case 'google_timeline':
        return 'Upload Timeline JSON';
      case 'google_takeout':
        return 'Upload Takeout ZIP';
      case 'google_calendar':
        return source.status.toLowerCase().contains('needs connection')
            ? 'Connect Google Calendar'
            : 'Sync Google Calendar';
      case 'google_calendar_import':
        return 'Upload Calendar ZIP or ICS';
      default:
        return 'Upload';
    }
  }

  IconData _buttonIcon() {
    switch (source.key) {
      case 'google_timeline':
      case 'google_takeout':
        return Icons.upload_file_rounded;
      case 'google_calendar':
        return source.status.toLowerCase().contains('needs connection')
            ? Icons.link_rounded
            : Icons.sync_rounded;
      case 'google_calendar_import':
        return Icons.upload_file_rounded;
      default:
        return Icons.play_arrow_rounded;
    }
  }

  String _uploadingLabel() {
    switch (source.key) {
      case 'google_timeline':
        return 'Uploading Timeline JSON';
      case 'google_takeout':
        return 'Uploading Takeout ZIP';
      case 'google_calendar':
        return source.status.toLowerCase().contains('needs connection')
            ? 'Connecting Google Calendar'
            : 'Syncing Google Calendar';
      case 'google_calendar_import':
        return 'Uploading Calendar File';
      default:
        return 'Uploading';
    }
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
