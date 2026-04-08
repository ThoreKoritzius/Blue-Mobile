import 'chat_attachment_model.dart';
import 'chat_widget_model.dart';

class ChatToolCallModel {
  const ChatToolCallModel({
    required this.name,
    this.query,
    this.variables = const {},
    this.errors,
    this.sql,
    this.sqlParams = const {},
    this.embeddingQuery,
    this.rowCount,
    this.searchedCount,
    this.truncated,
  });

  final String name;
  // GraphQL fields
  final String? query;
  final Map<String, dynamic> variables;
  final List<String>? errors;
  // Legacy SQL fields (backwards compatible)
  final String? sql;
  final Map<String, dynamic> sqlParams;
  final String? embeddingQuery;
  final int? rowCount;
  final int? searchedCount;
  final bool? truncated;

  String get displayQuery => query ?? sql ?? '';

  String get displaySummary {
    if (errors != null && errors!.isNotEmpty) {
      return 'Error: ${errors!.first}';
    }
    if (query != null) {
      return name == 'graphql_query' ? 'GraphQL query' : name;
    }
    return 'Searched\u2248${searchedCount ?? '?'} returned=${rowCount ?? '?'}';
  }

  factory ChatToolCallModel.fromJson(Map<String, dynamic> json) {
    final params = json['sql_params'];
    final vars = json['variables'];
    final errs = json['errors'];
    return ChatToolCallModel(
      name: (json['name'] ?? '').toString(),
      query: json['query']?.toString(),
      variables: vars is Map<String, dynamic> ? vars : const {},
      errors: errs is List ? errs.map((e) => e.toString()).toList() : null,
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
    this.maps = const [],
    this.charts = const [],
  });

  final String text;
  final List<String> dates;
  final List<ChatAttachmentImage> images;
  final List<ChatToolCallModel> toolCalls;
  final List<ChatMapSpec> maps;
  final List<ChatChartSpec> charts;

  factory ChatResponseModel.fromJson(Map<String, dynamic> json) {
    final toolCalls = json['tool_calls'];
    final maps = json['maps'];
    final charts = json['charts'];
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
      maps: maps is List
          ? maps
                .whereType<Map<String, dynamic>>()
                .map(ChatMapSpec.fromJson)
                .toList()
          : const [],
      charts: charts is List
          ? charts
                .whereType<Map<String, dynamic>>()
                .map(ChatChartSpec.fromJson)
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
      maps: maps,
      charts: charts,
    );
  }
}
