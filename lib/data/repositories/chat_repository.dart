import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/config/app_config.dart';
import '../../core/network/graphql_service.dart';
import '../../core/network/http_client/http_client_factory.dart';
import '../../features/chat/chat_parsing.dart';
import '../graphql/documents.dart';
import '../models/chat_event_model.dart';
import '../models/chat_response_model.dart';

abstract class ChatRepository {
  Stream<ChatEventModel> stream(List<Map<String, String>> messages);
  Future<ChatResponseModel> complete(List<Map<String, String>> messages);
}

class StreamingChatRepository implements ChatRepository {
  StreamingChatRepository(this._gql);

  final GraphqlService _gql;
  static const Duration _streamOpenTimeout = Duration(seconds: 90);
  static const Duration _completeTimeout = Duration(seconds: 120);

  @override
  Stream<ChatEventModel> stream(List<Map<String, String>> messages) async* {
    final client = createGraphqlHttpClient();
    try {
      final headers = await _gql.buildAuthHeaders();
      final request = http.Request(
        'POST',
        Uri.parse('${AppConfig.backendUrl}/api/chat'),
      );
      request.headers.addAll({
        'Content-Type': 'application/json',
        'Accept': 'application/x-ndjson',
        ...headers,
      });
      request.body = jsonEncode({'stream': true, 'messages': messages});

      final response = await client.send(request).timeout(_streamOpenTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Chat stream failed (${response.statusCode}).');
      }

      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final payload = jsonDecode(trimmed);
        if (payload is Map<String, dynamic>) {
          yield ChatEventModel.fromJson(payload);
        }
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<ChatResponseModel> complete(List<Map<String, String>> messages) async {
    try {
      return await _completeViaRest(messages);
    } catch (_) {
      final data = await _gql.mutate(
        GqlDocuments.chatComplete,
        variables: {'messages': messages},
      );
      final payload =
          (((data['chat'] as Map<String, dynamic>)['complete'])
              as Map<String, dynamic>?);
      final response = ChatResponseModel.fromJson(payload ?? const {});
      return response.copyWithAttachments(parseChatAttachments(response.text));
    }
  }

  Future<ChatResponseModel> _completeViaRest(
    List<Map<String, String>> messages,
  ) async {
    final client = createGraphqlHttpClient();
    try {
      final headers = await _gql.buildAuthHeaders();
      final response = await client
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/chat'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              ...headers,
            },
            body: jsonEncode({'stream': false, 'messages': messages}),
          )
          .timeout(_completeTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Chat complete failed (${response.statusCode}).');
      }

      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic>) {
        throw Exception('Unexpected chat response.');
      }

      final parsed = ChatResponseModel.fromJson(payload);
      return parsed.copyWithAttachments(parseChatAttachments(parsed.text));
    } finally {
      client.close();
    }
  }
}
