import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/date_format.dart';
import '../../data/models/chat_attachment_model.dart';
import '../../data/models/chat_event_model.dart';
import '../../data/models/chat_response_model.dart';
import '../../data/models/story_day_model.dart';
import '../../providers.dart';
import 'chat_parsing.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <_UiMessage>[];
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

  Future<void> _send() async {
    final prompt = _input.text.trim();
    if (prompt.isEmpty || _sending) return;

    final chatRepo = ref.read(chatRepositoryProvider);
    final history = [
      ..._messages.map((item) => {'role': item.role, 'content': item.rawText}),
      {'role': 'user', 'content': prompt},
    ];

    final assistantId = DateTime.now().microsecondsSinceEpoch.toString();

    setState(() {
      _messages.add(
        _UiMessage(
          id: 'u_$assistantId',
          role: 'user',
          rawText: prompt,
          text: prompt,
        ),
      );
      _messages.add(
        _UiMessage(
          id: assistantId,
          role: 'assistant',
          rawText: '',
          text: '',
          state: _UiMessageState.streaming,
        ),
      );
      _sending = true;
      _input.clear();
      _autoScroll = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    var buffer = '';
    var streamedAnyDelta = false;

    _streamSub?.cancel();
    _streamSub = chatRepo
        .stream(history)
        .listen(
          (event) {
            if (!mounted) return;
            switch (event.type) {
              case 'status':
                final nextStatus = _UiStatusEntry(
                  id: '${assistantId}_${event.stage ?? 'status'}_${DateTime.now().microsecondsSinceEpoch}',
                  stage: event.stage ?? 'status',
                  summary: event.summary ?? '',
                  meta: event.meta ?? const {},
                );
                _updateAssistant(
                  assistantId,
                  (message) => message.copyWith(
                    statuses: [
                      ...message.statuses,
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
                  (message) => message.copyWith(
                    rawText: buffer,
                    text: attachments.text,
                    dates: attachments.dates,
                    images: attachments.images,
                    state: _UiMessageState.streaming,
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
                  (message) => message.copyWith(state: _UiMessageState.done),
                );
                setState(() => _sending = false);
                break;
              case 'error':
                _updateAssistant(
                  assistantId,
                  (message) => message.copyWith(
                    state: _UiMessageState.error,
                    errorText: event.message ?? 'Stream failed.',
                  ),
                );
                setState(() => _sending = false);
                break;
            }
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _scrollToBottom(),
            );
          },
          onError: (_) async {
            if (!mounted) return;
            if (streamedAnyDelta) {
              _updateAssistant(
                assistantId,
                (message) => message.copyWith(
                  state: _UiMessageState.error,
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
                (message) => message.copyWith(
                  state: _UiMessageState.error,
                  errorText: error.toString().replaceFirst('Exception: ', ''),
                ),
              );
            } finally {
              if (mounted) {
                setState(() => _sending = false);
              }
            }
          },
          onDone: () {
            if (mounted) {
              setState(() => _sending = false);
            }
          },
        );
  }

  void _applyFinalResponse(String id, ChatResponseModel response) {
    _updateAssistant(
      id,
      (message) => message.copyWith(
        rawText: response.text,
        text: response.text,
        dates: response.dates,
        images: response.images,
        toolCalls: response.toolCalls,
        state: _UiMessageState.done,
        clearError: true,
      ),
    );
    setState(() => _sending = false);
  }

  void _updateAssistant(String id, _UiMessage Function(_UiMessage) update) {
    setState(() {
      final index = _messages.indexWhere((item) => item.id == id);
      if (index == -1) return;
      _messages[index] = update(_messages[index]);
    });
  }

  void _retryLastPrompt() {
    final lastUser = _messages.lastWhere(
      (item) => item.role == 'user',
      orElse: () =>
          const _UiMessage(id: '', role: 'user', rawText: '', text: ''),
    );
    if (lastUser.rawText.isEmpty) return;
    _input.text = lastUser.rawText;
    _send();
  }

  Future<StoryDayModel?> _loadDayPreview(String date) {
    final cached = _dayPreviewCache[date];
    if (cached != null) {
      return Future.value(cached);
    }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [const Color(0xFF08111D), const Color(0xFF0F1B2C)]
              : [const Color(0xFFF7FAFF), const Color(0xFFEDF4FD)],
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(theme)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final item = _messages[index];
                      return _buildMessageBubble(context, theme, item);
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(
                  alpha: isDark ? 0.96 : 0.92,
                ),
                border: Border(
                  top: BorderSide(color: colorScheme.outlineVariant),
                ),
                boxShadow: [
                  BoxShadow(
                    color: isDark
                        ? const Color(0x28000000)
                        : const Color(0x12000000),
                    blurRadius: 18,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Message Blue...',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _sending ? null : _send,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(50, 50),
                      padding: EdgeInsets.zero,
                    ),
                    child: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: isDark
                    ? colorScheme.primary.withValues(alpha: 0.18)
                    : const Color(0xFFDCEBFF),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                Icons.auto_awesome_outlined,
                color: colorScheme.primary,
                size: 36,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Ask about your days',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Memories, runs, places, photos.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(
    BuildContext context,
    ThemeData theme,
    _UiMessage item,
  ) {
    final isUser = item.role == 'user';
    final colorScheme = theme.colorScheme;
    final bubbleColor = isUser
        ? colorScheme.primary
        : colorScheme.surfaceContainer;
    final textColor = isUser ? colorScheme.onPrimary : colorScheme.onSurface;
    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(24),
      topRight: const Radius.circular(24),
      bottomLeft: Radius.circular(isUser ? 24 : 8),
      bottomRight: Radius.circular(isUser ? 8 : 24),
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: borderRadius,
          border: isUser ? null : Border.all(color: colorScheme.outlineVariant),
          boxShadow: isUser
              ? const []
              : [
                  BoxShadow(
                    color: theme.brightness == Brightness.dark
                        ? const Color(0x22000000)
                        : const Color(0x12000000),
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isUser)
              Text(
                item.text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: textColor,
                  height: 1.45,
                ),
              )
            else
              MarkdownBody(
                data:
                    item.text.isEmpty && item.state == _UiMessageState.streaming
                    ? ' '
                    : item.text,
                selectable: false,
                sizedImageBuilder: (config) => Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: SizedBox(
                    width: config.width,
                    height: config.height,
                    child: _InlineChatImage(
                      imageUrl: _resolveChatImageUrl(config.uri.toString()),
                      headers: _authHeaders(),
                      onTap: () => _showImagePreview(
                        context,
                        ChatAttachmentImage(path: config.uri.toString()),
                      ),
                    ),
                  ),
                ),
                styleSheet: MarkdownStyleSheet(
                  p: theme.textTheme.bodyLarge?.copyWith(
                    color: textColor,
                    height: 1.5,
                  ),
                  code: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.primary,
                    backgroundColor: colorScheme.primary.withValues(
                      alpha: 0.14,
                    ),
                  ),
                  blockquote: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  listBullet: theme.textTheme.bodyLarge?.copyWith(
                    color: textColor,
                  ),
                  a: TextStyle(color: colorScheme.primary),
                ),
                onTapLink: (text, href, title) {},
              ),
            if (!isUser &&
                item.state == _UiMessageState.streaming &&
                item.statuses.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                item.statuses.last.summary,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            if (item.state == _UiMessageState.streaming) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  _TypingDot(delay: 0),
                  SizedBox(width: 4),
                  _TypingDot(delay: 120),
                  SizedBox(width: 4),
                  _TypingDot(delay: 240),
                ],
              ),
            ],
            if (item.dates.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 124,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: item.dates.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final date = item.dates[index];
                    return FutureBuilder<StoryDayModel?>(
                      future: _loadDayPreview(date),
                      builder: (context, snapshot) {
                        return _DayMemoryCard(
                          date: date,
                          story: snapshot.data,
                          loading:
                              snapshot.connectionState ==
                              ConnectionState.waiting,
                          headers: _authHeaders(),
                          onTap: () => _openDayFromChat(date),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
            if (item.images.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildInlineImageGallery(context, theme, item.images),
            ],
            if (item.toolCalls.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...item.toolCalls.map(
                (call) => _buildToolCallInline(theme, call),
              ),
            ],
            if (item.state == _UiMessageState.error &&
                item.errorText != null &&
                item.errorText!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark
                      ? const Color(0xFF3A1619)
                      : const Color(0xFFFFECEC),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.errorText!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFFFFCDD2)
                            : const Color(0xFF912F2F),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _retryLastPrompt,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToolCallInline(ThemeData theme, ChatToolCallModel call) {
    final id = 'tool_${call.name}_${call.sql.hashCode}';
    final expanded = _expandedDetailIds.contains(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            setState(() {
              if (expanded) {
                _expandedDetailIds.remove(id);
              } else {
                _expandedDetailIds.add(id);
              }
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Searched≈${call.searchedCount ?? '?'} returned=${call.rowCount ?? '?'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Container(
            margin: const EdgeInsets.only(top: 4, bottom: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((call.sql ?? '').trim().isNotEmpty)
                  _buildDetailBlock('SQL', call.sql!.trim()),
                if (call.sqlParams.isNotEmpty)
                  _buildDetailBlock('Params', call.sqlParams.toString()),
                if ((call.embeddingQuery ?? '').trim().isNotEmpty)
                  _buildDetailBlock(
                    'Embedding Query',
                    call.embeddingQuery!.trim(),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDetailBlock(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showImagePreview(
    BuildContext context,
    ChatAttachmentImage image,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(18),
          backgroundColor: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: CachedNetworkImage(
              imageUrl: _resolveChatImageUrl(image.path),
              fit: BoxFit.contain,
              httpHeaders: _authHeaders(),
              errorWidget: (_, __, ___) => Container(
                height: 260,
                color: Theme.of(context).colorScheme.surface,
                child: const Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
        );
      },
    );
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

  String _resolveChatImageUrl(String rawPath) {
    if (rawPath.startsWith('http://') || rawPath.startsWith('https://')) {
      return rawPath;
    }
    return AppConfig.imageUrlFromPath(rawPath);
  }

  Widget _buildInlineImageGallery(
    BuildContext context,
    ThemeData theme,
    List<ChatAttachmentImage> images,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final single = images.length == 1;
        final tileWidth = single
            ? constraints.maxWidth
            : (constraints.maxWidth - 10) / 2;
        final tileHeight = single ? 190.0 : tileWidth;

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: images
              .map(
                (image) => SizedBox(
                  width: tileWidth,
                  height: tileHeight,
                  child: _InlineChatImage(
                    imageUrl: _resolveChatImageUrl(
                      image.previewPath ?? image.path,
                    ),
                    headers: _authHeaders(),
                    onTap: () => _showImagePreview(context, image),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

enum _UiMessageState { streaming, done, error }

class _UiStatusEntry {
  const _UiStatusEntry({
    required this.id,
    required this.stage,
    required this.summary,
    required this.meta,
  });

  final String id;
  final String stage;
  final String summary;
  final Map<String, dynamic> meta;
}

class _UiMessage {
  const _UiMessage({
    required this.id,
    required this.role,
    required this.rawText,
    required this.text,
    this.state = _UiMessageState.done,
    this.dates = const [],
    this.images = const [],
    this.statuses = const [],
    this.toolCalls = const [],
    this.errorText,
  });

  final String id;
  final String role;
  final String rawText;
  final String text;
  final _UiMessageState state;
  final List<String> dates;
  final List<ChatAttachmentImage> images;
  final List<_UiStatusEntry> statuses;
  final List<ChatToolCallModel> toolCalls;
  final String? errorText;

  _UiMessage copyWith({
    String? rawText,
    String? text,
    _UiMessageState? state,
    List<String>? dates,
    List<ChatAttachmentImage>? images,
    List<_UiStatusEntry>? statuses,
    List<ChatToolCallModel>? toolCalls,
    String? errorText,
    bool clearError = false,
  }) {
    return _UiMessage(
      id: id,
      role: role,
      rawText: rawText ?? this.rawText,
      text: text ?? this.text,
      state: state ?? this.state,
      dates: dates ?? this.dates,
      images: images ?? this.images,
      statuses: statuses ?? this.statuses,
      toolCalls: toolCalls ?? this.toolCalls,
      errorText: clearError ? null : (errorText ?? this.errorText),
    );
  }
}

class _TypingDot extends StatefulWidget {
  const _TypingDot({required this.delay});

  final int delay;

  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final value = ((_controller.value + (widget.delay / 900)) % 1.0);
        final opacity = 0.35 + (value * 0.65);
        return Opacity(
          opacity: opacity,
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.78),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

class _DayMemoryCard extends StatelessWidget {
  const _DayMemoryCard({
    required this.date,
    required this.story,
    required this.loading,
    required this.headers,
    required this.onTap,
  });

  final String date;
  final StoryDayModel? story;
  final bool loading;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final previewUrl = _heroPreviewUrl();
    final place = [
      story?.place.trim() ?? '',
      story?.country.trim() ?? '',
    ].where((part) => part.isNotEmpty).join(', ');

    return SizedBox(
      width: 168,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x16000000),
                  blurRadius: 18,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (previewUrl != null)
                    CachedNetworkImage(
                      imageUrl: previewUrl,
                      fit: BoxFit.cover,
                      httpHeaders: headers,
                      errorWidget: (_, __, ___) => _fallback(),
                    )
                  else
                    _fallback(),
                  if (loading)
                    Container(color: Colors.white.withValues(alpha: 0.28)),
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x14000000),
                          Color(0x22000000),
                          Color(0xC40C1728),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 14,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          date,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        if (place.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            place,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.88),
                                  height: 1.3,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF9CB7D8), Color(0xFFD8E6F6)],
        ),
      ),
    );
  }

  String? _heroPreviewUrl() {
    final highlight = story?.highlightImage.trim() ?? '';
    if (highlight.isEmpty || story == null) return null;
    if (!highlight.contains('/') && story!.date.isNotEmpty) {
      return '${AppConfig.backendUrl}/api/images/${story!.date}/compressed/$highlight';
    }
    return AppConfig.imageUrlFromPath(highlight, date: story!.date);
  }
}

class _InlineChatImage extends StatelessWidget {
  const _InlineChatImage({
    required this.imageUrl,
    required this.headers,
    required this.onTap,
  });

  final String imageUrl;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            boxShadow: const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 14,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: CachedNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.cover,
              httpHeaders: headers,
              errorWidget: (_, __, ___) => Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
