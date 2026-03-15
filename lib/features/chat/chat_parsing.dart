import '../../data/models/chat_attachment_model.dart';

final _dateRegex = RegExp(r'\b(\d{4}-\d{2}-\d{2})\b');

ChatAttachmentSet parseChatAttachments(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  final kept = <String>[];
  final dates = <String>[];
  final images = <ChatAttachmentImage>[];
  final seenDates = <String>{};
  final seenImages = <String>{};

  for (final line in lines) {
    final trimmed = line.trim();
    if (_isMetadataLine(trimmed, 'dates')) {
      for (final match in _dateRegex.allMatches(trimmed)) {
        final value = match.group(1)!;
        if (seenDates.add(value)) {
          dates.add(value);
        }
      }
      continue;
    }
    if (_isMetadataLine(trimmed, 'images')) {
      final payload = trimmed.contains(':')
          ? trimmed.split(':').skip(1).join(':')
          : '';
      for (final part in payload.split(RegExp(r'[;,]'))) {
        final value = part.trim();
        if (value.isEmpty || !seenImages.add(value)) {
          continue;
        }
        images.add(
          ChatAttachmentImage(
            path: value,
            previewPath: coercePreviewPath(value),
          ),
        );
      }
      continue;
    }
    kept.add(line);
  }

  return ChatAttachmentSet(
    text: kept.join('\n').trimRight(),
    dates: dates,
    images: images,
  );
}

bool _isMetadataLine(String value, String key) {
  final lower = value.toLowerCase();
  return lower.startsWith('$key:') || lower == key;
}

String? coercePreviewPath(String path) {
  if (path.isEmpty) return null;
  final normalized = path.replaceAll('\\', '/');
  final match = RegExp(
    r'/stories_images/([^/]+)/([^/]+)$',
  ).firstMatch(normalized);
  if (match == null) return null;
  final date = match.group(1)!;
  final fileName = match.group(2)!;
  return './Blue/stories_images/$date/compressed/$fileName';
}
