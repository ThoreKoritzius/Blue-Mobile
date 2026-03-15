import 'chat_response_model.dart';

class ChatEventModel {
  const ChatEventModel({
    required this.type,
    this.delta,
    this.message,
    this.stage,
    this.summary,
    this.meta,
    this.response,
  });

  final String type;
  final String? delta;
  final String? message;
  final String? stage;
  final String? summary;
  final Map<String, dynamic>? meta;
  final ChatResponseModel? response;

  factory ChatEventModel.fromJson(Map<String, dynamic> json) {
    final type = (json['type'] ?? json['eventType'] ?? '').toString();
    return ChatEventModel(
      type: type,
      delta: json['delta']?.toString(),
      message: (json['message'] ?? json['error'])?.toString(),
      stage: json['stage']?.toString(),
      summary: json['summary']?.toString(),
      meta: json['meta'] is Map<String, dynamic>
          ? json['meta'] as Map<String, dynamic>
          : null,
      response: type == 'final' ? ChatResponseModel.fromJson(json) : null,
    );
  }
}
