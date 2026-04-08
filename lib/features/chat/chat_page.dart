import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/date_format.dart';
import '../../data/models/chat_event_model.dart';
import '../../data/models/chat_response_model.dart';
import '../../data/models/story_day_model.dart';
import '../../providers.dart';
import 'chat_models.dart';
import 'chat_parsing.dart';
import 'widgets/chat_message_tile.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <UiMessage>[];
  StreamSubscription<ChatEventModel>? _streamSub;
  bool _sending = false;
  bool _autoScroll = true;
  final Set<String> _expandedDetailIds = <String>{};
  final Map<String, StoryDayModel?> _dayPreviewCache =
      <String, StoryDayModel?>{};
  final Map<String, Future<StoryDayModel?>> _dayPreviewFutures =
      <String, Future<StoryDayModel?>>{};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _input.dispose();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Scroll
  // ---------------------------------------------------------------------------

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final distance = position.maxScrollExtent - position.pixels;
    _autoScroll = distance < 120;
  }

  void _scrollToBottom({bool animated = true}) {
    if (!_scrollController.hasClients || !_autoScroll) return;
    final target = _scrollController.position.maxScrollExtent + 80;
    if (animated) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  // ---------------------------------------------------------------------------
  // Send / Stream
  // ---------------------------------------------------------------------------

  Future<void> _send([String? overridePrompt]) async {
    final prompt = overridePrompt ?? _input.text.trim();
    if (prompt.isEmpty || _sending) return;

    final chatRepo = ref.read(chatRepositoryProvider);
    final history = [
      ..._messages.map((m) => {'role': m.role, 'content': m.rawText}),
      {'role': 'user', 'content': prompt},
    ];

    final assistantId = DateTime.now().microsecondsSinceEpoch.toString();

    setState(() {
      _messages.add(UiMessage(
        id: 'u_$assistantId',
        role: 'user',
        rawText: prompt,
        text: prompt,
      ));
      _messages.add(UiMessage(
        id: assistantId,
        role: 'assistant',
        rawText: '',
        text: '',
        state: UiMessageState.streaming,
      ));
      _sending = true;
      _input.clear();
      _autoScroll = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    var buffer = '';
    var streamedAnyDelta = false;

    _streamSub?.cancel();
    _streamSub = chatRepo.stream(history).listen(
      (event) {
        if (!mounted) return;
        switch (event.type) {
          case 'status':
            final nextStatus = UiStatusEntry(
              id: '${assistantId}_${event.stage ?? 'status'}_${DateTime.now().microsecondsSinceEpoch}',
              stage: event.stage ?? 'status',
              summary: event.summary ?? '',
              meta: event.meta ?? const {},
            );
            _updateAssistant(
              assistantId,
              (m) => m.copyWith(
                statuses: [
                  ...m.statuses,
                  if (nextStatus.summary.trim().isNotEmpty) nextStatus,
                ],
              ),
            );
            break;
          case 'delta':
            final delta = event.delta ?? '';
            if (delta.isEmpty) break;
            streamedAnyDelta = true;
            buffer += delta;
            final attachments = parseChatAttachments(buffer);
            _updateAssistant(
              assistantId,
              (m) => m.copyWith(
                rawText: buffer,
                text: attachments.text,
                dates: attachments.dates,
                images: attachments.images,
                state: UiMessageState.streaming,
              ),
            );
            break;
          case 'final':
            final response = event.response;
            if (response != null) {
              final parsed = response.copyWithAttachments(
                parseChatAttachments(response.text),
              );
              _applyFinalResponse(assistantId, parsed);
            }
            break;
          case 'done':
            _updateAssistant(
              assistantId,
              (m) => m.copyWith(state: UiMessageState.done),
            );
            setState(() => _sending = false);
            break;
          case 'error':
            _updateAssistant(
              assistantId,
              (m) => m.copyWith(
                state: UiMessageState.error,
                errorText: event.message ?? 'Stream failed.',
              ),
            );
            setState(() => _sending = false);
            break;
        }
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _scrollToBottom());
      },
      onError: (_) async {
        if (!mounted) return;
        if (streamedAnyDelta) {
          _updateAssistant(
            assistantId,
            (m) => m.copyWith(
              state: UiMessageState.error,
              errorText: 'Streaming stopped. You can retry.',
            ),
          );
          setState(() => _sending = false);
          return;
        }
        try {
          final fallback = await chatRepo.complete(history);
          if (!mounted) return;
          _applyFinalResponse(assistantId, fallback);
        } catch (error) {
          if (!mounted) return;
          _updateAssistant(
            assistantId,
            (m) => m.copyWith(
              state: UiMessageState.error,
              errorText: error.toString().replaceFirst('Exception: ', ''),
            ),
          );
        } finally {
          if (mounted) setState(() => _sending = false);
        }
      },
      onDone: () {
        if (mounted) setState(() => _sending = false);
      },
    );
  }

  void _stopStream() {
    _streamSub?.cancel();
    _streamSub = null;
    final lastAssistant = _messages.lastWhere(
      (m) => m.role == 'assistant',
      orElse: () => const UiMessage(id: '', role: '', rawText: '', text: ''),
    );
    if (lastAssistant.id.isNotEmpty &&
        lastAssistant.state == UiMessageState.streaming) {
      _updateAssistant(
        lastAssistant.id,
        (m) => m.copyWith(state: UiMessageState.done),
      );
    }
    setState(() => _sending = false);
  }

  void _applyFinalResponse(String id, ChatResponseModel response) {
    _updateAssistant(
      id,
      (m) => m.copyWith(
        rawText: response.text,
        text: response.text,
        dates: response.dates,
        images: response.images,
        toolCalls: response.toolCalls,
        maps: response.maps,
        charts: response.charts,
        state: UiMessageState.done,
        clearError: true,
      ),
    );
    setState(() => _sending = false);
  }

  void _updateAssistant(String id, UiMessage Function(UiMessage) update) {
    setState(() {
      final index = _messages.indexWhere((m) => m.id == id);
      if (index == -1) return;
      _messages[index] = update(_messages[index]);
    });
  }

  void _retryLastPrompt() {
    final lastUser = _messages.lastWhere(
      (m) => m.role == 'user',
      orElse: () =>
          const UiMessage(id: '', role: 'user', rawText: '', text: ''),
    );
    if (lastUser.rawText.isEmpty) return;
    _send(lastUser.rawText);
  }

  Future<StoryDayModel?> _loadDayPreview(String date) {
    final cached = _dayPreviewCache[date];
    if (cached != null) return Future.value(cached);
    final existing = _dayPreviewFutures[date];
    if (existing != null) return existing;

    final future = () async {
      try {
        final story = await ref.read(storiesRepositoryProvider).getDay(date);
        _dayPreviewCache[date] = story;
        return story;
      } catch (_) {
        _dayPreviewCache[date] = null;
        return null;
      } finally {
        _dayPreviewFutures.remove(date);
      }
    }();

    _dayPreviewFutures[date] = future;
    return future;
  }

  void _openDayFromChat(String date) {
    ref.read(selectedDateProvider.notifier).state = parseYmd(date);
    ref.read(selectedTabProvider.notifier).state = 0;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  /// Constrains a child to the centered content column.
  Widget _constrained(Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 768),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: _messages.isEmpty
              ? _buildEmptyState(theme)
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
                  itemCount: _messages.length + 1,
                  itemBuilder: (context, index) {
                    if (index < _messages.length) {
                      return _constrained(
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 16),
                          child: ChatMessageTile(
                            message: _messages[index],
                            expandedDetailIds: _expandedDetailIds,
                            onToggleDetail: (id) {
                              setState(() {
                                if (_expandedDetailIds.contains(id)) {
                                  _expandedDetailIds.remove(id);
                                } else {
                                  _expandedDetailIds.add(id);
                                }
                              });
                            },
                            onOpenDay: _openDayFromChat,
                            onRetry: _retryLastPrompt,
                            loadDayPreview: _loadDayPreview,
                          ),
                        ),
                      );
                    }
                    if (_sending) return const SizedBox.shrink();
                    return _constrained(
                      Padding(
                        padding:
                            const EdgeInsets.only(top: 16, bottom: 8),
                        child: Center(
                          child: TextButton.icon(
                            onPressed: () =>
                                setState(() => _messages.clear()),
                            icon: Icon(Icons.delete_outline,
                                size: 16,
                                color:
                                    theme.colorScheme.onSurfaceVariant),
                            label: Text(
                              'Clear chat',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme
                                      .colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        _buildInputBar(theme),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Empty state with suggestion chips
  // ---------------------------------------------------------------------------

  Widget _buildEmptyState(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    const suggestions = [
      'What did I do last weekend?',
      'Show my running stats',
      'Best photos from March',
      'Where have I traveled?',
      'Summarize this month',
    ];

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        controller: _scrollController,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.auto_awesome,
                        color: colorScheme.onPrimaryContainer,
                        size: 26,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Ask about your days',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Memories, runs, places, photos — all searchable.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: suggestions
                          .map((s) => ActionChip(
                                label: Text(s),
                                onPressed: () => _send(s),
                                backgroundColor:
                                    colorScheme.surfaceContainerLow,
                                side: BorderSide(
                                  color: colorScheme.outlineVariant
                                      .withValues(alpha: 0.5),
                                ),
                                labelStyle:
                                    theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurface,
                                ),
                              ))
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Input bar — pinned at bottom, never overlapping
  // ---------------------------------------------------------------------------

  Widget _buildInputBar(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: _constrained(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Container(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed) {
                        if (!_sending) _send();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      style: theme.textTheme.bodyLarge,
                      decoration: InputDecoration(
                        hintText: 'Message Blue...',
                        hintStyle: theme.textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.5),
                        ),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.fromLTRB(20, 14, 8, 14),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 6),
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: _sending
                        ? IconButton(
                            onPressed: _stopStream,
                            padding: EdgeInsets.zero,
                            icon: Icon(Icons.stop_rounded,
                                size: 20,
                                color: colorScheme.onSurfaceVariant),
                            tooltip: 'Stop generating',
                            style: IconButton.styleFrom(
                              backgroundColor:
                                  colorScheme.surfaceContainerHigh,
                              shape: const CircleBorder(),
                            ),
                          )
                        : IconButton(
                            onPressed: _send,
                            padding: EdgeInsets.zero,
                            icon: Icon(Icons.arrow_upward_rounded,
                                size: 20,
                                color: colorScheme.onPrimary),
                            tooltip: 'Send',
                            style: IconButton.styleFrom(
                              backgroundColor: colorScheme.primary,
                              shape: const CircleBorder(),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
