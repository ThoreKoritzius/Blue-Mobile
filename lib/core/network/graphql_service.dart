import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'auth_token_store.dart';
import 'http_client/http_client_factory.dart';

class GraphqlService {
  GraphqlService(this._tokenStore);

  final AuthTokenStore _tokenStore;
  static const Duration requestTimeout = Duration(seconds: 20);
  late final http.Client _httpClient = createGraphqlHttpClient();
  late final GraphQLClient _multipartGraphqlClient = _buildMultipartClient();

  void _log(String message) {
    debugPrint('[AUTH] $message');
  }

  Future<Map<String, String>> buildAuthHeaders() async {
    final token = await _tokenStore.readToken();
    final gatewayToken = await _tokenStore.readGatewayToken();
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (gatewayToken != null && gatewayToken.isNotEmpty)
        'X-Gateway-Session': gatewayToken,
    };
  }

  GraphQLClient _buildMultipartClient() {
    final httpLink = HttpLink(
      AppConfig.graphqlHttpUrl,
      httpClient: _httpClient,
    );

    return GraphQLClient(
      cache: GraphQLCache(store: InMemoryStore()),
      link: httpLink,
      defaultPolicies: DefaultPolicies(
        query: Policies(fetch: FetchPolicy.networkOnly),
        mutate: Policies(fetch: FetchPolicy.networkOnly),
        subscribe: Policies(fetch: FetchPolicy.networkOnly),
      ),
    );
  }

  Future<Map<String, dynamic>> query(
    String document, {
    Map<String, dynamic> variables = const {},
  }) async {
    try {
      _log('graphql query ${AppConfig.graphqlHttpUrl}');
      return await _postJsonGraphql(document, variables: variables);
    } on TimeoutException {
      throw Exception('Request timeout after ${requestTimeout.inSeconds}s.');
    } catch (error) {
      throw Exception(_humanizeError(error.toString()));
    }
  }

  Future<Map<String, dynamic>> mutate(
    String document, {
    Map<String, dynamic> variables = const {},
  }) async {
    try {
      _log('graphql mutate ${AppConfig.graphqlHttpUrl}');
      if (_containsMultipart(variables)) {
        final result = await _multipartGraphqlClient
            .mutate(
              MutationOptions(
                document: gql(document),
                variables: variables,
                context: Context.fromList([
                  HttpLinkHeaders(headers: await buildAuthHeaders()),
                ]),
              ),
            )
            .timeout(requestTimeout);
        _throwIfError(result);
        return result.data ?? <String, dynamic>{};
      }
      return await _postJsonGraphql(document, variables: variables);
    } on TimeoutException {
      throw Exception('Request timeout after ${requestTimeout.inSeconds}s.');
    } catch (error) {
      throw Exception(_humanizeError(error.toString()));
    }
  }

  Future<Map<String, dynamic>> _postJsonGraphql(
    String document, {
    Map<String, dynamic> variables = const {},
  }) async {
    final response = await _httpClient
        .post(
          Uri.parse(AppConfig.graphqlHttpUrl),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            ...await buildAuthHeaders(),
          },
          body: jsonEncode({'query': document, 'variables': variables}),
        )
        .timeout(requestTimeout);

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Invalid GraphQL response.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errors = decoded['errors'];
      if (errors is List && errors.isNotEmpty) {
        throw Exception(_graphqlErrorsToMessage(errors));
      }
      throw Exception('GraphQL HTTP ${response.statusCode}.');
    }

    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      throw Exception(_graphqlErrorsToMessage(errors));
    }
    final data = decoded['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  bool _containsMultipart(Object? value) {
    if (value is http.MultipartFile) return true;
    if (value is Iterable) {
      for (final item in value) {
        if (_containsMultipart(item)) return true;
      }
      return false;
    }
    if (value is Map) {
      for (final item in value.values) {
        if (_containsMultipart(item)) return true;
      }
      return false;
    }
    return false;
  }

  String _graphqlErrorsToMessage(List<dynamic> errors) {
    return errors
        .whereType<Map>()
        .map((error) => (error['message'] ?? '').toString().trim())
        .where((message) => message.isNotEmpty)
        .join('\n');
  }

  Stream<Map<String, dynamic>> subscribe(
    String document, {
    Map<String, dynamic> variables = const {},
  }) async* {
    final headers = await buildAuthHeaders();
    Link link = HttpLink(
      AppConfig.graphqlHttpUrl,
      httpClient: createGraphqlHttpClient(),
    );
    if (headers.isNotEmpty) {
      final wsLink = WebSocketLink(
        AppConfig.graphqlWsUrl,
        config: SocketClientConfig(
          autoReconnect: true,
          inactivityTimeout: const Duration(seconds: 30),
          initialPayload: () => headers,
        ),
      );
      link = Link.split((request) => request.isSubscription, wsLink, link);
    }
    final client = GraphQLClient(
      cache: GraphQLCache(store: InMemoryStore()),
      link: link,
      defaultPolicies: DefaultPolicies(
        query: Policies(fetch: FetchPolicy.networkOnly),
        mutate: Policies(fetch: FetchPolicy.networkOnly),
        subscribe: Policies(fetch: FetchPolicy.networkOnly),
      ),
    );
    final stream = client.subscribe(
      SubscriptionOptions(
        document: gql(document),
        variables: variables,
        context: Context.fromList([HttpLinkHeaders(headers: headers)]),
      ),
    );
    await for (final result in stream) {
      _throwIfError(result);
      yield result.data ?? <String, dynamic>{};
    }
  }

  void _throwIfError(QueryResult<Object?> result) {
    if (!result.hasException) return;
    final exception = result.exception;
    final graphqlMessages =
        exception?.graphqlErrors
            .map((e) => e.message.trim())
            .where((e) => e.isNotEmpty)
            .join('\n') ??
        '';
    final linkMessage = exception?.linkException?.toString() ?? '';
    final message = graphqlMessages.isNotEmpty
        ? graphqlMessages
        : (linkMessage.isNotEmpty ? linkMessage : exception.toString());
    _log('graphql error: $message');
    throw Exception(message);
  }

  String _humanizeError(String raw) {
    final cleaned = raw.replaceFirst('Exception: ', '').trim();
    if (cleaned.isEmpty) {
      return 'Request failed with an empty error response.';
    }
    final text = cleaned.toLowerCase();
    if (text.contains('cors') || text.contains('xmlhttprequest error')) {
      return 'CORS/network blocked by gateway at ${AppConfig.backendUrl}.';
    }
    if (text.contains('oauth2') ||
        text.contains('sign_in') ||
        text.contains('<!doctype html') ||
        text.contains('responseformatexception') ||
        text.contains('unexpected end of input') ||
        text.contains('unexpected character')) {
      return 'Gateway returned non-JSON auth/proxy response. '
          'This usually means oauth2-proxy redirected or blocked /api/graphql. '
          'Check gateway routing for /api/graphql at ${AppConfig.backendUrl}.';
    }
    if (text.contains('timeout')) {
      return 'Network timeout while contacting ${AppConfig.backendUrl}.';
    }
    if (text.contains('not authenticated')) {
      return 'Not authenticated. Complete Google OAuth and app sign-in again.';
    }
    if (text.contains('stage-1 oauth proof missing') ||
        text.contains('oauth proof missing')) {
      return 'Google OAuth proof missing or expired. Complete step 1 again.';
    }
    return cleaned;
  }
}
