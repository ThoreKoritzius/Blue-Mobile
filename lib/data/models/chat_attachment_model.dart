class ChatAttachmentImage {
  const ChatAttachmentImage({required this.path, this.previewPath});

  final String path;
  final String? previewPath;
}

class ChatAttachmentSet {
  const ChatAttachmentSet({
    required this.text,
    required this.dates,
    required this.images,
  });

  final String text;
  final List<String> dates;
  final List<ChatAttachmentImage> images;
}
