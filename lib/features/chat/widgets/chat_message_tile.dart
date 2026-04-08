import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/story_day_model.dart';
import '../chat_models.dart';
import 'chat_message_content.dart';

/// A single message row in the ChatGPT-style layout.
///
/// - **User messages**: right-aligned subtle pill.
/// - **Assistant messages**: full-width with small avatar on the left.
class ChatMessageTile extends ConsumerStatefulWidget {
  const ChatMessageTile({
    super.key,
    required this.message,
    required this.expandedDetailIds,
    required this.onToggleDetail,
    required this.onOpenDay,
    required this.onRetry,
    required this.loadDayPreview,
  });

  final UiMessage message;
  final Set<String> expandedDetailIds;
  final void Function(String id) onToggleDetail;
  final void Function(String date) onOpenDay;
  final VoidCallback onRetry;
  final Future<StoryDayModel?> Function(String date) loadDayPreview;

  @override
  ConsumerState<ChatMessageTile> createState() => _ChatMessageTileState();
}

class _ChatMessageTileState extends ConsumerState<ChatMessageTile> {
  bool _hovered = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.role == 'user';
    return isUser ? _buildUserMessage(context) : _buildAssistantMessage(context);
  }

  Widget _buildUserMessage(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxWidth = screenWidth > 768 ? 600.0 : screenWidth * 0.82;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: SelectableText(
            widget.message.text,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface,
              height: 1.45,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAssistantMessage(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDone = widget.message.state == UiMessageState.done;
    final hasContent = widget.message.text.trim().isNotEmpty ||
        widget.message.dates.isNotEmpty ||
        widget.message.images.isNotEmpty ||
        widget.message.maps.isNotEmpty ||
        widget.message.charts.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar
                Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.auto_awesome,
                    size: 15,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                // Content
                Expanded(
                  child: ChatMessageContent(
                    message: widget.message,
                    expandedDetailIds: widget.expandedDetailIds,
                    onToggleDetail: widget.onToggleDetail,
                    onOpenDay: widget.onOpenDay,
                    loadDayPreview: widget.loadDayPreview,
                  ),
                ),
              ],
            ),
            // Action buttons row (copy, retry)
            if (isDone && hasContent)
              IgnorePointer(
                ignoring: !_hovered,
                child: AnimatedOpacity(
                  opacity: _hovered ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 40, top: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ActionButton(
                          icon: _copied
                              ? Icons.check_rounded
                              : Icons.content_copy_rounded,
                          tooltip: _copied ? 'Copied' : 'Copy',
                          onTap: () => _copyMessage(),
                        ),
                        const SizedBox(width: 4),
                        _ActionButton(
                          icon: Icons.refresh_rounded,
                          tooltip: 'Retry',
                          onTap: widget.onRetry,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _copyMessage() {
    Clipboard.setData(ClipboardData(text: widget.message.rawText));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 16,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}
