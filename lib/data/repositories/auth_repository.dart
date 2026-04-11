import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/config/app_config.dart';
import '../../core/network/auth_token_store.dart';
import '../../core/network/graphql_service.dart';
import '../../core/network/http_client/http_client_factory.dart';
import '../graphql/documents.dart';
import '../models/auth_session.dart';

abstract class AuthRepository {
  Future<AuthSession> login(String username, String password);
  Future<AuthSession?> checkSession();
  Future<bool> checkGatewaySession();
  Future<bool> hasStoredGatewayProof();
  Future<String> exchangeMobileCode(String code);
  Future<void> logout();
  Future<void> changePassword(String currentPassword, String newPassword);
}

class GatewaySessionStatus {
  const GatewaySessionStatus({
    required this.oauthReady,
    required this.appReady,
    required this.reason,
    required this.oauthIdentity,
    required this.username,
  });

  final bool oauthReady;
  final bool appReady;
  final String? reason;
  final String? oauthIdentity;
  final String? username;
}

class GraphqlAuthRepository implements AuthRepository {
  GraphqlAuthRepository(this._gql, this._tokenStore);

  final GraphqlService _gql;
  final AuthTokenStore _tokenStore;
  String? _csrfToken;

  Future<void> _storeMobileTokenMetadata(Map<String, dynamic> payload) async {
    final now = DateTime.now().toUtc();
    final accessExpiresIn = _readDurationSeconds(payload['expiresIn']);
    final refreshExpiresIn = _readDurationSeconds(payload['refreshExpiresIn']);
    if (accessExpiresIn != null && accessExpiresIn > 0) {
      await _tokenStore.writeTokenExpiry(
        now.add(Duration(seconds: accessExpiresIn)),
      );
    }
    if (refreshExpiresIn != null && refreshExpiresIn > 0) {
      await _tokenStore.writeRefreshTokenExpiry(
        now.add(Duration(seconds: refreshExpiresIn)),
      );
    }
  }

  int? _readDurationSeconds(Object? rawValue) {
    if (rawValue == null) return null;
    if (rawValue is int) return rawValue;
    return int.tryParse(rawValue.toString());
  }

  @override
  Future<AuthSession> login(String username, String password) async {
    if (kIsWeb) {
      return _loginBrowser(username, password);
    }
    return _loginMobile(username, password);
  }

  Future<AuthSession> _loginBrowser(String username, String password) async {
    final client = createGraphqlHttpClient();
    try {
      final basic = base64Encode(utf8.encode('$username:$password'));
      final response = await client
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/auth/login'),
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Basic $basic',
            },
          )
          .timeout(const Duration(seconds: 12));
      final body = jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw Exception(_extractError(body));
      }
      final payload = body as Map<String, dynamic>;
      final user =
          ((payload['user'] ?? const {}) as Map<String, dynamic>)['username']
              .toString();
      await _tokenStore.clear();
      if (user.isNotEmpty) {
        await _tokenStore.writeUsername(user);
      }
      await _fetchCsrfToken(client, forceRefresh: true);
      return AuthSession(username: user, accessToken: '');
    } finally {
      client.close();
    }
  }

  Future<String?> _fetchCsrfToken(
    http.Client client, {
    bool forceRefresh = false,
  }) async {
    if (!kIsWeb) return null;
    if (!forceRefresh && _csrfToken != null && _csrfToken!.isNotEmpty) {
      return _csrfToken;
    }
    final response = await client
        .get(
          Uri.parse('${AppConfig.backendUrl}/api/auth/csrf'),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      return null;
    }
    final token = (body['csrfToken'] ?? '').toString();
    _csrfToken = token.isEmpty ? null : token;
    return _csrfToken;
  }

  Future<AuthSession> _loginMobile(String username, String password) async {
    final deviceId = await _tokenStore.readOrCreateDeviceId();
    final client = createGraphqlHttpClient();
    try {
      final response = await client
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/auth/login'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'X-Blue-Client': 'mobile',
            },
            body: jsonEncode({
              'username': username,
              'password': password,
              'device_id': deviceId,
            }),
          )
          .timeout(const Duration(seconds: 12));
      final body = jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw Exception(_extractError(body));
      }
      final payload = body as Map<String, dynamic>;
      final token = (payload['accessToken'] ?? '').toString();
      final refreshToken = (payload['refreshToken'] ?? '').toString();
      final user =
          ((payload['user'] ?? const {}) as Map<String, dynamic>)['username']
              .toString();
      if (token.isEmpty || refreshToken.isEmpty) {
        throw Exception('Authentication did not return mobile session tokens.');
      }
      await _tokenStore.writeToken(token);
      await _tokenStore.writeRefreshToken(refreshToken);
      await _storeMobileTokenMetadata(payload);
      if (user.isNotEmpty) {
        await _tokenStore.writeUsername(user);
      }
      return AuthSession(username: user, accessToken: token);
    } finally {
      client.close();
    }
  }

  @override
  Future<String> exchangeMobileCode(String code) async {
    throw Exception('Google OAuth flow has been removed.');
  }

  Future<GatewaySessionStatus> fetchSessionStatus() async {
    final client = createGraphqlHttpClient();
    try {
      final headers = <String, String>{'Accept': 'application/json'};
      if (!kIsWeb) {
        final token = await _tokenStore.readToken();
        headers['X-Blue-Client'] = 'mobile';
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Bearer $token';
        }
      }
      final response = await client
          .get(
            Uri.parse('${AppConfig.backendUrl}/api/auth/status'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 8));
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return GatewaySessionStatus(
        oauthReady: true,
        appReady: body['appReady'] == true,
        reason: body['reason']?.toString(),
        oauthIdentity: body['oauthIdentity']?.toString(),
        username: body['username']?.toString(),
      );
    } on TimeoutException {
      throw Exception('OAuth status check timed out.');
    } finally {
      client.close();
    }
  }

  Future<void> _refreshMobileSession() async {
    final refreshToken = await _tokenStore.readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw Exception('Refresh token missing.');
    }
    final deviceId = await _tokenStore.readOrCreateDeviceId();
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
      final body = jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw Exception(_extractError(body));
      }
      await _tokenStore.writeToken((body['accessToken'] ?? '').toString());
      await _tokenStore.writeRefreshToken(
        (body['refreshToken'] ?? '').toString(),
      );
      await _storeMobileTokenMetadata((body as Map<String, dynamic>));
      final username =
          ((body['user'] ?? const {}) as Map<String, dynamic>)['username']
              ?.toString();
      if (username != null && username.isNotEmpty) {
        await _tokenStore.writeUsername(username);
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<AuthSession?> checkSession() async {
    final status = await fetchSessionStatus();
    if (!status.appReady) {
      if (!kIsWeb) {
        final refresh = await _tokenStore.readRefreshToken();
        if (refresh != null && refresh.isNotEmpty) {
          try {
            await _refreshMobileSession();
            final refreshed = await fetchSessionStatus();
            if (refreshed.appReady) {
              return _querySessionUser();
            }
          } catch (_) {}
        }
      }
      return null;
    }
    return _querySessionUser();
  }

  Future<AuthSession?> _querySessionUser() async {
    try {
      final response = await _gql.query(GqlDocuments.me);
      final username =
          ((response['auth'] as Map<String, dynamic>)['me']
                  as Map<String, dynamic>)['username']
              .toString();
      final token = await _tokenStore.readToken() ?? '';
      if (username.isNotEmpty) {
        await _tokenStore.writeUsername(username);
      }
      return AuthSession(username: username, accessToken: token);
    } catch (_) {
      await _tokenStore.clear();
      return null;
    }
  }

  @override
  Future<bool> hasStoredGatewayProof() async {
    return true;
  }

  @override
  Future<bool> checkGatewaySession() async {
    return true;
  }

  @override
  Future<void> logout() async {
    final client = createGraphqlHttpClient();
    try {
      final headers = <String, String>{'Accept': 'application/json'};
      if (!kIsWeb) {
        final token = await _tokenStore.readToken();
        headers['X-Blue-Client'] = 'mobile';
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Bearer $token';
        }
      }
      await client.post(
        Uri.parse('${AppConfig.backendUrl}/api/auth/logout'),
        headers: {
          ...headers,
          if (kIsWeb) 'X-CSRF-Token': (await _fetchCsrfToken(client)) ?? '',
        },
      );
    } catch (_) {
      // Best effort.
    } finally {
      client.close();
      await _tokenStore.clear();
    }
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    final client = createGraphqlHttpClient();
    try {
      final token = await _tokenStore.readToken();
      final csrfToken = await _fetchCsrfToken(client);
      final response = await client
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/auth/change-password'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (kIsWeb && csrfToken != null && csrfToken.isNotEmpty)
                'X-CSRF-Token': csrfToken,
              if (!kIsWeb) 'X-Blue-Client': 'mobile',
              if (!kIsWeb && token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'current_password': currentPassword,
              'new_password': newPassword,
            }),
          )
          .timeout(const Duration(seconds: 12));
      final body = jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw Exception(_extractError(body));
      }
    } finally {
      client.close();
    }
  }

  String _extractError(Object? body) {
    if (body is Map<String, dynamic>) {
      final detail = body['detail']?.toString();
      if (detail != null && detail.isNotEmpty) return detail;
      final reason = body['reason']?.toString();
      if (reason != null && reason.isNotEmpty) return reason;
      if (body['errors'] is List && (body['errors'] as List).isNotEmpty) {
        final first = (body['errors'] as List).first;
        if (first is Map<String, dynamic>) {
          final message = first['message']?.toString();
          if (message != null && message.isNotEmpty) return message;
        }
      }
    }
    return 'Request failed.';
  }
}
