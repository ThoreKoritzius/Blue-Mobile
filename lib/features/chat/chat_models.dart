import '../../data/models/chat_attachment_model.dart';
import '../../data/models/chat_response_model.dart';
import '../../data/models/chat_widget_model.dart';

enum UiMessageState { streaming, done, error }

class UiStatusEntry {
  const UiStatusEntry({
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

class UiMessage {
  const UiMessage({
    required this.id,
    required this.role,
    required this.rawText,
    required this.text,
    this.state = UiMessageState.done,
    this.dates = const [],
    this.images = const [],
    this.statuses = const [],
    this.toolCalls = const [],
    this.maps = const [],
    this.charts = const [],
    this.errorText,
  });

  final String id;
  final String role;
  final String rawText;
  final String text;
  final UiMessageState state;
  final List<String> dates;
  final List<ChatAttachmentImage> images;
  final List<UiStatusEntry> statuses;
  final List<ChatToolCallModel> toolCalls;
  final List<ChatMapSpec> maps;
  final List<ChatChartSpec> charts;
  final String? errorText;

  UiMessage copyWith({
    String? rawText,
    String? text,
    UiMessageState? state,
    List<String>? dates,
    List<ChatAttachmentImage>? images,
    List<UiStatusEntry>? statuses,
    List<ChatToolCallModel>? toolCalls,
    List<ChatMapSpec>? maps,
    List<ChatChartSpec>? charts,
    String? errorText,
    bool clearError = false,
  }) {
    return UiMessage(
      id: id,
      role: role,
      rawText: rawText ?? this.rawText,
      text: text ?? this.text,
      state: state ?? this.state,
      dates: dates ?? this.dates,
      images: images ?? this.images,
      statuses: statuses ?? this.statuses,
      toolCalls: toolCalls ?? this.toolCalls,
      maps: maps ?? this.maps,
      charts: charts ?? this.charts,
      errorText: clearError ? null : (errorText ?? this.errorText),
    );
  }
}
