import 'package:flutter/material.dart';

import '../../../data/models/chat_response_model.dart';
import '../chat_models.dart';
import 'chat_typing_indicator.dart';

// ---------------------------------------------------------------------------
// Agent activity bar — unified streaming + completed view
// ---------------------------------------------------------------------------

class ChatAgentActivityBar extends StatelessWidget {
  const ChatAgentActivityBar({
    super.key,
    required this.messageId,
    required this.statuses,
    required this.toolCalls,
    required this.isStreaming,
    required this.hasText,
    required this.expandedDetailIds,
    required this.onToggleDetail,
  });

  final String messageId;
  final List<UiStatusEntry> statuses;
  final List<ChatToolCallModel> toolCalls;
  final bool isStreaming;
  final bool hasText;
  final Set<String> expandedDetailIds;
  final void Function(String id) onToggleDetail;

  String get _panelId => 'activity_panel_$messageId';

  @override
  Widget build(BuildContext context) {
    if (statuses.isEmpty && toolCalls.isEmpty) return const SizedBox.shrink();

    final showLive = isStreaming && !hasText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLive)
          _ActivityStreamingView(statuses: statuses)
        else ...[
          _ActivitySummaryBar(
            statuses: statuses,
            toolCalls: toolCalls,
            isExpanded: expandedDetailIds.contains(_panelId),
            onTap: () => onToggleDetail(_panelId),
          ),
          if (expandedDetailIds.contains(_panelId))
            _ActivityDetailPanel(
              statuses: statuses,
              toolCalls: toolCalls,
              expandedDetailIds: expandedDetailIds,
              onToggleDetail: onToggleDetail,
            ),
        ],
        const SizedBox(height: 10),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Live streaming view — shows each status as it arrives
// ---------------------------------------------------------------------------

class _ActivityStreamingView extends StatelessWidget {
  const _ActivityStreamingView({required this.statuses});

  final List<UiStatusEntry> statuses;

  static const _stageIcons = {
    'plan': Icons.psychology_outlined,
    'query': Icons.travel_explore_outlined,
    'db': Icons.check_circle_outline,
    'error': Icons.error_outline,
    'widget': Icons.dashboard_outlined,
    'compose': Icons.edit_note_outlined,
  };

  static String _labelForStatus(UiStatusEntry s) {
    if (s.stage == 'query') {
      // Show a short snippet of the actual GraphQL query from meta
      final query = s.meta['query']?.toString() ?? '';
      if (query.isNotEmpty) {
        final snippet = query
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        return snippet.length > 80
            ? 'Query: ${snippet.substring(0, 80)}...'
            : 'Query: $snippet';
      }
      return 'Running query';
    }
    if (s.stage == 'plan') return 'Thinking...';
    if (s.stage == 'compose') return 'Writing answer...';
    return s.summary;
  }

  @override
  Widget build(BuildContext context) {
    final steps = <_StreamingStep>[];
    for (final s in statuses) {
      if (s.stage == 'db') {
        if (steps.isNotEmpty && steps.last.stage == 'query') {
          steps.last.done = true;
        }
        steps.add(_StreamingStep(
          stage: s.stage,
          label: s.summary,
          done: true,
        ));
        continue;
      }
      if (s.stage == 'error') {
        if (steps.isNotEmpty && steps.last.stage == 'query') {
          steps.last.done = true;
          steps.last.hasError = true;
        }
        steps.add(_StreamingStep(
          stage: s.stage,
          label: s.summary,
          done: true,
          hasError: true,
        ));
        continue;
      }
      final label = _labelForStatus(s);
      if (steps.isNotEmpty && steps.last.stage == s.stage && !steps.last.done) {
        steps.last.label = label;
      } else {
        steps.add(_StreamingStep(
          stage: s.stage,
          label: label,
        ));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 3),
            child: _buildStepRow(
              context,
              step: steps[i],
              isLast: i == steps.length - 1,
            ),
          ),
      ],
    );
  }

  Widget _buildStepRow(
    BuildContext context, {
    required _StreamingStep step,
    required bool isLast,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isActive = isLast && !step.done;

    final Color color;
    if (step.hasError) {
      color = colorScheme.error.withValues(alpha: 0.8);
    } else if (isActive) {
      color = colorScheme.primary;
    } else {
      color = colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
    }

    final icon = _stageIcons[step.stage] ?? Icons.circle_outlined;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isActive)
          const PulsingDot()
        else
          Icon(
            step.done && !step.hasError
                ? Icons.check_circle_outline
                : step.hasError
                    ? Icons.error_outline
                    : icon,
            size: 15,
            color: color,
          ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            step.label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _StreamingStep {
  _StreamingStep({
    required this.stage,
    required this.label,
    this.done = false,
    this.hasError = false,
  });

  final String stage;
  String label;
  bool done;
  bool hasError;
}

// ---------------------------------------------------------------------------
// Collapsed summary bar (after streaming is done)
// ---------------------------------------------------------------------------

class _ActivitySummaryBar extends StatelessWidget {
  const _ActivitySummaryBar({
    required this.statuses,
    required this.toolCalls,
    required this.isExpanded,
    required this.onTap,
  });

  final List<UiStatusEntry> statuses;
  final List<ChatToolCallModel> toolCalls;
  final bool isExpanded;
  final VoidCallback onTap;

  String _summaryText() {
    final queryCount = toolCalls.isNotEmpty
        ? toolCalls.length
        : statuses.where((s) => s.stage == 'query').length;
    if (queryCount == 0) return 'Analyzed your request';
    final errorCount = toolCalls
        .where((t) => t.errors != null && t.errors!.isNotEmpty)
        .length;
    final base = queryCount == 1 ? 'Ran 1 query' : 'Ran $queryCount queries';
    if (errorCount > 0) return '$base ($errorCount failed)';
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 18,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _summaryText(),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Expanded detail panel (shows individual tool calls)
// ---------------------------------------------------------------------------

class _ActivityDetailPanel extends StatelessWidget {
  const _ActivityDetailPanel({
    required this.statuses,
    required this.toolCalls,
    required this.expandedDetailIds,
    required this.onToggleDetail,
  });

  final List<UiStatusEntry> statuses;
  final List<ChatToolCallModel> toolCalls;
  final Set<String> expandedDetailIds;
  final void Function(String id) onToggleDetail;

  static const _stageIcons = {
    'plan': Icons.psychology_outlined,
    'query': Icons.travel_explore_outlined,
    'db': Icons.storage_outlined,
    'compose': Icons.edit_note_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final stageOrder = <String>[];
    final lastByStage = <String, UiStatusEntry>{};
    for (final s in statuses) {
      if (!lastByStage.containsKey(s.stage)) stageOrder.add(s.stage);
      lastByStage[s.stage] = s;
    }

    var queryIndex = 0;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final stage in stageOrder)
            if (stage == 'query' || stage == 'db' || stage == 'error')
              if (stage == 'query')
                ...toolCalls.map((call) {
                  final idx = queryIndex++;
                  return _ActivityStepTile(
                    icon: _stageIcons['query']!,
                    label: call.displaySummary,
                    hasError:
                        call.errors != null && call.errors!.isNotEmpty,
                    toolCall: call,
                    isExpanded: expandedDetailIds.contains(
                        'tool_${call.name}_${idx}_${call.displayQuery.hashCode}'),
                    onToggle: () => onToggleDetail(
                        'tool_${call.name}_${idx}_${call.displayQuery.hashCode}'),
                  );
                })
              else
                const SizedBox.shrink()
            else
              _ActivityStepTile(
                icon: _stageIcons[stage] ?? Icons.circle_outlined,
                label: lastByStage[stage]!.summary,
              ),
        ],
      ),
    );
  }
}

class _ActivityStepTile extends StatelessWidget {
  const _ActivityStepTile({
    required this.icon,
    required this.label,
    this.hasError = false,
    this.toolCall,
    this.isExpanded = false,
    this.onToggle,
  });

  final IconData icon;
  final String label;
  final bool hasError;
  final ChatToolCallModel? toolCall;
  final bool isExpanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final color =
        hasError ? colorScheme.error : colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (toolCall != null) ...[
                  const SizedBox(width: 6),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color:
                        colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (isExpanded && toolCall != null)
          _buildToolDetail(context, toolCall!),
      ],
    );
  }

  Widget _buildToolDetail(BuildContext context, ChatToolCallModel call) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4, left: 23),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (call.displayQuery.trim().isNotEmpty)
            _detailBlock(
              context,
              call.query != null ? 'GraphQL' : 'SQL',
              call.displayQuery.trim(),
              isCode: true,
            ),
          if (call.variables.isNotEmpty)
            _detailBlock(context, 'Variables', call.variables.toString()),
          if (call.sqlParams.isNotEmpty)
            _detailBlock(context, 'Params', call.sqlParams.toString()),
          if ((call.embeddingQuery ?? '').trim().isNotEmpty)
            _detailBlock(
                context, 'Embedding Query', call.embeddingQuery!.trim()),
          if (call.errors != null && call.errors!.isNotEmpty)
            _detailBlock(context, 'Errors', call.errors!.join('\n')),
        ],
      ),
    );
  }

  static String _prettyPrintQuery(String query) {
    var indent = 0;
    final buffer = StringBuffer();
    final trimmed = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (var i = 0; i < trimmed.length; i++) {
      final ch = trimmed[i];
      if (ch == '{') {
        indent++;
        buffer.writeln(' {');
        buffer.write('  ' * indent);
      } else if (ch == '}') {
        indent--;
        buffer.writeln();
        buffer.write('  ' * indent);
        buffer.write('}');
      } else if (ch == ',' &&
          i + 1 < trimmed.length &&
          trimmed[i + 1] == ' ') {
        buffer.writeln(',');
        buffer.write('  ' * indent);
      } else {
        buffer.write(ch);
      }
    }
    return buffer.toString().trim();
  }

  Widget _detailBlock(BuildContext context, String label, String value,
      {bool isCode = false}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final displayValue = isCode ? _prettyPrintQuery(value) : value;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              displayValue,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                height: 1.5,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
