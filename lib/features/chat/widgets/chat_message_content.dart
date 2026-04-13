import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/widgets/fullscreen_image_viewer.dart';
import '../../../data/models/chat_attachment_model.dart';
import '../../../data/models/person_model.dart';
import '../../../data/models/story_day_model.dart';
import '../../../providers.dart';
import '../chat_image_utils.dart';
import '../chat_models.dart';
import '../../persons/person_detail_page.dart';
import 'chat_agent_activity.dart';
import 'chat_day_memory_card.dart';
import 'chat_inline_chart.dart';
import 'chat_inline_image.dart';
import 'chat_inline_map.dart';
import 'chat_typing_indicator.dart';

Future<void> _openPersonDetailPage(
  BuildContext context,
  PersonModel person,
) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PersonDetailPage(person: person),
      fullscreenDialog: true,
    ),
  );
}

/// Renders the full content of a single assistant message:
/// activity bar, markdown text, date cards, images, maps, charts, errors.
class ChatMessageContent extends ConsumerWidget {
  const ChatMessageContent({
    super.key,
    required this.message,
    required this.expandedDetailIds,
    required this.onToggleDetail,
    required this.onOpenDay,
    required this.loadDayPreview,
  });

  final UiMessage message;
  final Set<String> expandedDetailIds;
  final void Function(String id) onToggleDetail;
  final void Function(String date) onOpenDay;
  final Future<StoryDayModel?> Function(String date) loadDayPreview;

  static final RegExp _htmlTagPattern = RegExp(
    r'<\s*/?\s*(script|style|iframe|object|embed|link|meta|img|svg|math|video|audio|source)[^>]*>',
    caseSensitive: false,
  );
  static final RegExp _dangerousHrefPattern = RegExp(
    r'\]\((?:\s*)(javascript:|data:)',
    caseSensitive: false,
  );

  String _sanitizeMarkdown(String value) {
    final withoutHtml = value.replaceAll(_htmlTagPattern, '');
    return withoutHtml.replaceAllMapped(_dangerousHrefPattern, (match) => '](#blocked:');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isStreaming = message.state == UiMessageState.streaming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Activity bar
        if (message.statuses.isNotEmpty || message.toolCalls.isNotEmpty)
          ChatAgentActivityBar(
            messageId: message.id,
            statuses: message.statuses,
            toolCalls: message.toolCalls,
            isStreaming: isStreaming,
            hasText: message.text.trim().isNotEmpty,
            expandedDetailIds: expandedDetailIds,
            onToggleDetail: onToggleDetail,
          ),

        // Markdown text — SelectionArea wraps for cross-paragraph selection
        if (message.text.isNotEmpty || isStreaming)
          Builder(
            builder: (context) {
              final safeMarkdown = _sanitizeMarkdown(
                message.text.isEmpty && isStreaming ? ' ' : message.text,
              );
              return MarkdownBody(
                data: safeMarkdown,
                selectable: message.state == UiMessageState.done,
                sizedImageBuilder: (config) => Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: SizedBox(
                    width: config.width,
                    height: config.height,
                    child: ChatInlineImage(
                      imageUrl: authenticatedUrl(
                        resolveChatImageUrl(config.uri.toString()),
                        ref,
                      ),
                      headers: chatAuthHeaders(ref),
                      onTap: () => _openImageViewer(
                        context,
                        ref,
                        [ChatAttachmentImage(path: config.uri.toString())],
                        0,
                      ),
                    ),
                  ),
                ),
                styleSheet: MarkdownStyleSheet(
                  p: theme.textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                    height: 1.55,
                  ),
                  code: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.primary,
                    backgroundColor:
                        colorScheme.primary.withValues(alpha: 0.10),
                  ),
                  blockquote: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  listBullet: theme.textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                  a: TextStyle(color: colorScheme.primary),
                ),
                onTapLink: (text, href, title) {},
              );
            },
          ),

        // Typing dots (streaming, no text yet, no statuses)
        if (isStreaming &&
            message.text.isEmpty &&
            message.statuses.isEmpty) ...[
          const SizedBox(height: 8),
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TypingDot(delay: 0),
              SizedBox(width: 4),
              TypingDot(delay: 120),
              SizedBox(width: 4),
              TypingDot(delay: 240),
            ],
          ),
        ],

        // Date cards — responsive grid
        if (message.dates.isNotEmpty) ...[
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final count = message.dates.length;
              final maxWidth = constraints.maxWidth;
              const gap = 10.0;
              // Pick columns based on available width and card count
              int cols;
              if (count == 1) {
                cols = 1;
              } else if (maxWidth < 400 || count == 2) {
                cols = 2;
              } else {
                cols = 3;
              }
              // Don't use more columns than cards
              if (cols > count) cols = count;
              final cardWidth =
                  (maxWidth - gap * (cols - 1)) / cols;
              final cardHeight = (cardWidth * 0.62).clamp(100.0, 160.0);

              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: message.dates.map((date) {
                  return FutureBuilder<StoryDayModel?>(
                    future: loadDayPreview(date),
                    builder: (context, snapshot) {
                      final story = snapshot.data;
                      return ChatDayMemoryCard(
                        date: date,
                        story: story,
                        loading: snapshot.connectionState ==
                            ConnectionState.waiting,
                        headers: chatAuthHeaders(ref),
                        previewUrl: _dayCardPreviewUrl(story, ref),
                        width: cardWidth,
                        height: cardHeight,
                        onTap: () => onOpenDay(date),
                      );
                    },
                  );
                }).toList(),
              );
            },
          ),
        ],

        // Image gallery
        if (message.images.isNotEmpty) ...[
          const SizedBox(height: 14),
          _ImageGallery(
            images: message.images,
            ref: ref,
          ),
        ],

        // Maps
        if (message.maps.isNotEmpty) ...[
          const SizedBox(height: 14),
          for (final mapSpec in message.maps)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ChatInlineMap(spec: mapSpec),
            ),
        ],

        // Charts
        if (message.charts.isNotEmpty) ...[
          const SizedBox(height: 14),
          for (final chartSpec in message.charts)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ChatInlineChart(spec: chartSpec),
            ),
        ],

        // Error
        if (message.state == UiMessageState.error &&
            message.errorText != null &&
            message.errorText!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline,
                    size: 18, color: colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message.errorText!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Builds an authenticated preview URL for a day card's hero image.
  String? _dayCardPreviewUrl(StoryDayModel? story, WidgetRef ref) {
    if (story == null) return null;
    final highlight = story.highlightImage.trim();
    if (highlight.isEmpty) return null;
    String rawUrl;
    if (!highlight.contains('/') && story.date.isNotEmpty) {
      rawUrl =
          '${AppConfig.backendUrl}/api/images/${story.date}/compressed/$highlight';
    } else {
      rawUrl = AppConfig.imageUrlFromPath(highlight, date: story.date);
    }
    return authenticatedUrl(rawUrl, ref);
  }

  /// Opens the fullscreen image viewer (same one used in day_page).
  void _openImageViewer(
    BuildContext context,
    WidgetRef ref,
    List<ChatAttachmentImage> images,
    int initialIndex,
  ) {
    final headers = chatAuthHeaders(ref);
    final filesRepo = ref.read(filesRepositoryProvider);
    final facesRepo = ref.read(facesRepositoryProvider);
    final personRepo = ref.read(personRepositoryProvider);

    final viewerItems = images.map((img) {
      final fullUrl = authenticatedUrl(resolveChatImageUrl(img.path), ref);
      final thumbUrl = authenticatedUrl(
        resolveChatImageUrl(img.previewPath ?? img.path),
        ref,
      );
      // Extract filename and date from path
      final parts = img.path.replaceAll('\\', '/').split('/');
      final fileName = parts.isNotEmpty ? parts.last : 'image';
      // Try to extract date from path like /stories_images/2024-01-15/photo.jpg
      var date = '';
      final dateMatch = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(img.path);
      if (dateMatch != null) date = dateMatch.group(1)!;

      return ImageViewerItem(
        fullUrl: fullUrl,
        thumbnailUrl: thumbUrl,
        fileName: fileName,
        path: img.path,
        date: date,
      );
    }).toList();

    FullscreenImageViewer.show(
      context: context,
      images: viewerItems,
      initialIndex: initialIndex,
      httpHeaders: headers,
      fetchImageInfo: (path) => filesRepo.getImageInfo(path),
      fetchImageFaces: (path) => facesRepo.getImageFaces(path),
      unlabelFace: (faceId) => facesRepo.unlabelFace(faceId),
      reassignFace: (faceId, personId, {isReference = false}) =>
          facesRepo.reassignFace(
            faceId,
            personId,
            isReference: isReference,
          ),
      personRepository: personRepo,
      onOpenPerson: (person) => _openPersonDetailPage(context, person),
    );
  }
}

class _ImageGallery extends StatelessWidget {
  const _ImageGallery({required this.images, required this.ref});

  final List<ChatAttachmentImage> images;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
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
          children: List.generate(images.length, (index) {
            final image = images[index];
            return SizedBox(
              width: tileWidth,
              height: tileHeight,
              child: ChatInlineImage(
                imageUrl: authenticatedUrl(
                  resolveChatImageUrl(image.previewPath ?? image.path),
                  ref,
                ),
                headers: chatAuthHeaders(ref),
                onTap: () => _openViewer(context, index),
              ),
            );
          }),
        );
      },
    );
  }

  void _openViewer(BuildContext context, int index) {
    final headers = chatAuthHeaders(ref);
    final filesRepo = ref.read(filesRepositoryProvider);
    final facesRepo = ref.read(facesRepositoryProvider);
    final personRepo = ref.read(personRepositoryProvider);

    final viewerItems = images.map((img) {
      final fullUrl = authenticatedUrl(resolveChatImageUrl(img.path), ref);
      final thumbUrl = authenticatedUrl(
        resolveChatImageUrl(img.previewPath ?? img.path),
        ref,
      );
      final parts = img.path.replaceAll('\\', '/').split('/');
      final fileName = parts.isNotEmpty ? parts.last : 'image';
      var date = '';
      final dateMatch = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(img.path);
      if (dateMatch != null) date = dateMatch.group(1)!;

      return ImageViewerItem(
        fullUrl: fullUrl,
        thumbnailUrl: thumbUrl,
        fileName: fileName,
        path: img.path,
        date: date,
      );
    }).toList();

    FullscreenImageViewer.show(
      context: context,
      images: viewerItems,
      initialIndex: index,
      httpHeaders: headers,
      fetchImageInfo: (path) => filesRepo.getImageInfo(path),
      fetchImageFaces: (path) => facesRepo.getImageFaces(path),
      unlabelFace: (faceId) => facesRepo.unlabelFace(faceId),
      reassignFace: (faceId, personId, {isReference = false}) =>
          facesRepo.reassignFace(
            faceId,
            personId,
            isReference: isReference,
          ),
      personRepository: personRepo,
      onOpenPerson: (person) => _openPersonDetailPage(context, person),
    );
  }
}
