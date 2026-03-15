import 'chat_attachment_model.dart';

class ChatToolCallModel {
  const ChatToolCallModel({
    required this.name,
    this.sql,
    this.sqlParams = const {},
    this.embeddingQuery,
    this.rowCount,
    this.searchedCount,
    this.truncated,
  });

  final String name;
  final String? sql;
  final Map<String, dynamic> sqlParams;
  final String? embeddingQuery;
  final int? rowCount;
  final int? searchedCount;
  final bool? truncated;

  factory ChatToolCallModel.fromJson(Map<String, dynamic> json) {
    final params = json['sql_params'];
    return ChatToolCallModel(
      name: (json['name'] ?? '').toString(),
      sql: json['sql']?.toString(),
      sqlParams: params is Map<String, dynamic> ? params : const {},
      embeddingQuery: json['embedding_query']?.toString(),
      rowCount: int.tryParse((json['row_count'] ?? '').toString()),
      searchedCount: int.tryParse((json['searched_count'] ?? '').toString()),
      truncated: json['truncated'] is bool ? json['truncated'] as bool : null,
    );
  }
}

class ChatResponseModel {
  const ChatResponseModel({
    required this.text,
    required this.dates,
    required this.images,
    this.toolCalls = const [],
  });

  final String text;
  final List<String> dates;
  final List<ChatAttachmentImage> images;
  final List<ChatToolCallModel> toolCalls;

  factory ChatResponseModel.fromJson(Map<String, dynamic> json) {
    final toolCalls = json['tool_calls'];
    return ChatResponseModel(
      text: (json['text'] ?? '').toString(),
      dates: const [],
      images: const [],
      toolCalls: toolCalls is List
          ? toolCalls
                .whereType<Map<String, dynamic>>()
                .map(ChatToolCallModel.fromJson)
                .toList()
          : const [],
    );
  }

  ChatResponseModel copyWithAttachments(ChatAttachmentSet attachments) {
    return ChatResponseModel(
      text: attachments.text,
      dates: attachments.dates,
      images: attachments.images,
      toolCalls: toolCalls,
    );
  }
}
