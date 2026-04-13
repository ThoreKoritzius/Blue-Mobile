import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'auth_token_store.dart';
import 'http_client/http_client_factory.dart';

class GraphqlService {
  GraphqlService(this._tokenStore, {this.onSessionExpired});

  final AuthTokenStore _tokenStore;
  final Future<void> Function()? onSessionExpired;

  static const Duration requestTimeout = Duration(seconds: 20);
  late final http.Client _httpClient = createGraphqlHttpClient();
  // Separate client for mutations so saves never queue behind heavy read requests
  late final http.Client _mutationHttpClient = createGraphqlHttpClient();
  bool _refreshing = false;
  Completer<bool>? _refreshCompleter;
  String? _csrfToken;
  static const Duration _refreshLeadTime = Duration(minutes: 3);

  void _log(String message) {
    debugPrint('[AUTH] $message');
  }

  Map<String, String> buildAuthHeaders() {
    if (kIsWeb) {
      return const {};
    }
    final token = _tokenStore.peekToken();
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      'X-Blue-Client': 'mobile',
    };
  }

  Future<Map<String, String>> buildRequestHeaders({
    bool includeCsrf = false,
    Map<String, String> extra = const {},
    bool forceRefreshCsrf = false,
  }) async {
    String? csrfToken;
    if (includeCsrf) {
      if (forceRefreshCsrf) {
        _csrfToken = null;
      }
      csrfToken = await _getCsrfToken(forceRefresh: forceRefreshCsrf);
    }
    return {
      if (csrfToken != null && csrfToken.isNotEmpty) 'X-CSRF-Token': csrfToken,
      ...buildAuthHeaders(),
      ...extra,
    };
  }

  Future<void> _hydrateAuthCache() async {
    if (kIsWeb) return;
    if (_tokenStore.peekToken() == null) {
      await _tokenStore.readToken();
    }
    if (_tokenStore.peekRefreshToken() == null) {
      await _tokenStore.readRefreshToken();
    }
    if (_tokenStore.peekDeviceId() == null) {
      await _tokenStore.readOrCreateDeviceId();
    }
    if (_tokenStore.peekTokenExpiry() == null) {
      await _tokenStore.readTokenExpiry();
    }
    if (_tokenStore.peekRefreshTokenExpiry() == null) {
      await _tokenStore.readRefreshTokenExpiry();
    }
  }

  Future<bool> ensureFreshSession() async {
    if (kIsWeb) return true;
    await _hydrateAuthCache();
    final refreshToken = _tokenStore.peekRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      return false;
    }
    final refreshExpiry = _tokenStore.peekRefreshTokenExpiry();
    final now = DateTime.now().toUtc();
    if (refreshExpiry != null && !refreshExpiry.isAfter(now)) {
      _log('refresh token expired — forcing logout');
      await _tokenStore.clear();
      await onSessionExpired?.call();
      return false;
    }
    final accessToken = _tokenStore.peekToken();
    final accessExpiry = _tokenStore.peekTokenExpiry();
    final needsRefresh =
        accessToken == null ||
        accessToken.isEmpty ||
        accessExpiry == null ||
        !accessExpiry.isAfter(now.add(_refreshLeadTime));
    if (!needsRefresh) {
      return true;
    }
    return _tryRefresh();
  }

  Future<String?> _getCsrfToken({bool forceRefresh = false}) async {
    if (!kIsWeb) return null;
    if (!forceRefresh && _csrfToken != null && _csrfToken!.isNotEmpty) {
      return _csrfToken;
    }
    final response = await _httpClient
        .get(
          Uri.parse('${AppConfig.backendUrl}/api/auth/csrf'),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final token = (decoded['csrfToken'] ?? '').toString();
    _csrfToken = token.isEmpty ? null : token;
    return _csrfToken;
  }

  /// Attempts to refresh the access token using the stored refresh token.
  /// Returns true if refresh succeeded (new tokens stored), false otherwise.
  /// Concurrent callers wait for the in-flight refresh via a Completer.
  Future<bool> _tryRefresh() async {
    if (_refreshing) return _refreshCompleter!.future;
    _refreshing = true;
    _refreshCompleter = Completer<bool>();

    try {
      await _hydrateAuthCache();
      final refreshToken = _tokenStore.peekRefreshToken();
      if (refreshToken == null || refreshToken.isEmpty) {
        _log('no refresh token — forcing logout');
        await _tokenStore.clear();
        await onSessionExpired?.call();
        _refreshCompleter!.complete(false);
        return false;
      }

      final deviceId = _tokenStore.peekDeviceId() ?? '';
      final client = createGraphqlHttpClient();
      try {
        final response = await client
            .post(
              Uri.parse('${AppConfig.backendUrl}/api/auth/refresh'),
              headers: const {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
                'X-Blue-Client': 'mobile',
              },
              body: jsonEncode({
                'refresh_token': refreshToken,
                'device_id': deviceId,
              }),
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode == 200) {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          await _tokenStore.writeToken((body['accessToken'] ?? '').toString());
          await _tokenStore.writeRefreshToken(
            (body['refreshToken'] ?? '').toString(),
          );
          final now = DateTime.now().toUtc();
          final accessExpiresIn =
              int.tryParse((body['expiresIn'] ?? '').toString()) ?? 0;
          final refreshExpiresIn =
              int.tryParse((body['refreshExpiresIn'] ?? '').toString()) ?? 0;
          if (accessExpiresIn > 0) {
            await _tokenStore.writeTokenExpiry(
              now.add(Duration(seconds: accessExpiresIn)),
            );
          }
          if (refreshExpiresIn > 0) {
            await _tokenStore.writeRefreshTokenExpiry(
              now.add(Duration(seconds: refreshExpiresIn)),
            );
          }
          _log('token refresh succeeded');
          _refreshCompleter!.complete(true);
          return true;
        }

        if (response.statusCode == 400 ||
            response.statusCode == 401 ||
            response.statusCode == 403) {
          _log(
            'token refresh rejected (${response.statusCode}) — forcing logout',
          );
          await _tokenStore.clear();
          await onSessionExpired?.call();
          _refreshCompleter!.complete(false);
          return false;
        }
      } finally {
        client.close();
      }

      _log('token refresh unavailable — preserving cached session');
      _refreshCompleter!.complete(false);
      return false;
    } catch (e) {
      _log('token refresh error: $e — preserving cached session');
      _refreshCompleter?.complete(false);
      return false;
    } finally {
      _refreshing = false;
    }
  }

  Future<Map<String, dynamic>> query(
    String document, {
    Map<String, dynamic> variables = const {},
  }) async {
    try {
      await ensureFreshSession();
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
      await ensureFreshSession();
      _log('graphql mutate ${AppConfig.graphqlHttpUrl}');
      return await _postJsonGraphql(
        document,
        variables: variables,
        client: _mutationHttpClient,
      );
    } on TimeoutException {
      throw Exception('Request timeout after ${requestTimeout.inSeconds}s.');
    } catch (error) {
      throw Exception(_humanizeError(error.toString()));
    }
  }

  Future<Map<String, dynamic>> mutateMultipartWithProgress(
    String document, {
    Map<String, dynamic> variables = const {},
    required List<MultipartUploadFile> files,
    required void Function(int sentBytes, int totalBytes) onProgress,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? requestTimeout;
    try {
      await ensureFreshSession();
      return await _doMultipartWithProgress(
        document,
        variables: variables,
        files: files,
        onProgress: onProgress,
        timeout: effectiveTimeout,
      );
    } on TimeoutException {
      throw Exception(_formatTimeoutMessage(effectiveTimeout));
    } catch (error) {
      throw Exception(_humanizeError(error.toString()));
    }
  }

  Future<Map<String, dynamic>> _doMultipartWithProgress(
    String document, {
    Map<String, dynamic> variables = const {},
    required List<MultipartUploadFile> files,
    required void Function(int sentBytes, int totalBytes) onProgress,
    Duration? timeout,
    bool isRetry = false,
  }) async {
    final csrfToken = await _getCsrfToken();
    final request = _ProgressMultipartRequest(
      'POST',
      Uri.parse(AppConfig.graphqlHttpUrl),
      onProgress: onProgress,
    );
    request.headers.addAll(buildAuthHeaders());
    if (csrfToken != null && csrfToken.isNotEmpty) {
      request.headers['X-CSRF-Token'] = csrfToken;
    }

    final operationsVariables = <String, dynamic>{
      ...variables,
      'files': List<dynamic>.filled(files.length, null),
    };
    request.fields['operations'] = jsonEncode({
      'query': document,
      'variables': operationsVariables,
    });
    request.fields['map'] = jsonEncode({
      for (var i = 0; i < files.length; i++) '$i': ['variables.files.$i'],
    });

    for (var i = 0; i < files.length; i++) {
      request.files.add(
        http.MultipartFile.fromBytes(
          '$i',
          files[i].bytes,
          filename: files[i].filename,
        ),
      );
    }

    final streamed = await _mutationHttpClient
        .send(request)
        .timeout(timeout ?? requestTimeout);
    final response = await http.Response.fromStream(streamed);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Invalid GraphQL response.');
    }

    if (response.statusCode == 401 && !isRetry) {
      final refreshed = await _tryRefresh();
      if (refreshed) {
        return _doMultipartWithProgress(
          document,
          variables: variables,
          files: files,
          onProgress: onProgress,
          timeout: timeout,
          isRetry: true,
        );
      }
      throw Exception('Session expired. Please sign in again.');
    }

    if (response.statusCode == 403 && kIsWeb && !isRetry) {
      _csrfToken = null;
      await _getCsrfToken(forceRefresh: true);
      return _doMultipartWithProgress(
        document,
        variables: variables,
        files: files,
        onProgress: onProgress,
        timeout: timeout,
        isRetry: true,
      );
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

  Future<Map<String, dynamic>> _postJsonGraphql(
    String document, {
    Map<String, dynamic> variables = const {},
    http.Client? client,
    bool isRetry = false,
  }) async {
    final csrfToken = await _getCsrfToken();
    final response = await (client ?? _httpClient)
        .post(
          Uri.parse(AppConfig.graphqlHttpUrl),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            if (csrfToken != null && csrfToken.isNotEmpty)
              'X-CSRF-Token': csrfToken,
            ...buildAuthHeaders(),
          },
          body: jsonEncode({'query': document, 'variables': variables}),
        )
        .timeout(requestTimeout);

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Invalid GraphQL response.');
    }

    if (response.statusCode == 401 && !isRetry) {
      final refreshed = await _tryRefresh();
      if (refreshed) {
        return _postJsonGraphql(
          document,
          variables: variables,
          client: client,
          isRetry: true,
        );
      }
      throw Exception('Session expired. Please sign in again.');
    }

    if (response.statusCode == 403 && kIsWeb && !isRetry) {
      _csrfToken = null;
      await _getCsrfToken(forceRefresh: true);
      return _postJsonGraphql(
        document,
        variables: variables,
        client: client,
        isRetry: true,
      );
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

  String _graphqlErrorsToMessage(List<dynamic> errors) {
    return errors
        .whereType<Map>()
        .map((error) => (error['message'] ?? '').toString().trim())
        .where((message) => message.isNotEmpty)
        .join('\n');
  }

  String _formatTimeoutMessage(Duration timeout) {
    if (timeout.inMinutes >= 1) {
      return 'Request timeout after ${timeout.inMinutes}m.';
    }
    return 'Request timeout after ${timeout.inSeconds}s.';
  }

  Stream<Map<String, dynamic>> subscribe(
    String document, {
    Map<String, dynamic> variables = const {},
  }) async* {
    Link link = HttpLink(
      AppConfig.graphqlHttpUrl,
      httpClient: createGraphqlHttpClient(),
    );
    final wsLink = WebSocketLink(
      AppConfig.graphqlWsUrl,
      config: SocketClientConfig(
        autoReconnect: true,
        inactivityTimeout: const Duration(seconds: 30),
        // Use a live closure so reconnects pick up refreshed tokens
        initialPayload: () => buildAuthHeaders(),
      ),
    );
    link = Link.split((request) => request.isSubscription, wsLink, link);

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
        context: Context.fromList([
          HttpLinkHeaders(headers: buildAuthHeaders()),
        ]),
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
      return 'Gateway returned a non-JSON response. Check /api/graphql routing at ${AppConfig.backendUrl}.';
    }
    if (text.contains('timeout')) {
      return 'Network timeout while contacting ${AppConfig.backendUrl}.';
    }
    if (text.contains('not authenticated') ||
        text.contains('session expired')) {
      return 'Not authenticated. Sign in again.';
    }
    return cleaned;
  }
}

class MultipartUploadFile {
  const MultipartUploadFile({required this.filename, required this.bytes});

  final String filename;
  final Uint8List bytes;
}

class _ProgressMultipartRequest extends http.MultipartRequest {
  _ProgressMultipartRequest(
    super.method,
    super.url, {
    required this.onProgress,
  });

  final void Function(int sentBytes, int totalBytes) onProgress;

  @override
  http.ByteStream finalize() {
    final stream = super.finalize();
    final total = contentLength;
    var sent = 0;
    return http.ByteStream(
      stream.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            sent += chunk.length;
            onProgress(sent, total);
            sink.add(chunk);
          },
        ),
      ),
    );
  }
}
