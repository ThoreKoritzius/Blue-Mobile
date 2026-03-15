import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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
}

class GraphqlAuthRepository implements AuthRepository {
  GraphqlAuthRepository(this._gql, this._tokenStore);

  final GraphqlService _gql;
  final AuthTokenStore _tokenStore;

  void _log(String message) {
    debugPrint('[AUTH] $message');
  }

  @override
  Future<AuthSession> login(String username, String password) async {
    _log('repository login mutation start user="$username"');
    late final Map<String, dynamic> response;
    try {
      response = await _gql.mutate(
        GqlDocuments.login,
        variables: {'username': username, 'password': password},
      );
    } catch (error) {
      final raw = error.toString().toLowerCase();
      _log('repository login mutation error=$error');
      if (raw.contains('unknown error occurred') ||
          raw.contains('invalid credentials') ||
          raw.contains('unauthorized') ||
          raw.contains('not authenticated')) {
        throw Exception('Invalid username or password.');
      }
      if (raw.contains('stage-1 oauth proof missing') ||
          raw.contains('oauth proof missing')) {
        throw Exception(
          'Google OAuth proof missing or expired. Complete step 1 again.',
        );
      }
      rethrow;
    }

    final auth = response['auth'];
    if (auth is! Map<String, dynamic>) {
      throw Exception('Unexpected auth response from gateway/backend.');
    }
    final payload = auth['login'];
    if (payload is! Map<String, dynamic>) {
      _log('repository login payload missing response=$response');
      throw Exception(
        'Login response missing. Check OAuth stage and credentials.',
      );
    }

    final token = (payload['accessToken'] ?? '').toString();
    final userData = payload['user'];
    final user = userData is Map<String, dynamic>
        ? (userData['username'] ?? '').toString()
        : '';

    if (token.isEmpty) {
      _log('repository login missing access token payload=$payload');
      throw Exception('Authentication did not return an access token.');
    }

    await _tokenStore.writeToken(token);
    if (user.isNotEmpty) {
      await _tokenStore.writeUsername(user);
    }
    _log('repository login success user="$user"');
    return AuthSession(username: user, accessToken: token);
  }

  @override
  Future<String> exchangeMobileCode(String code) async {
    final client = createGraphqlHttpClient();
    try {
      _log(
        'mobile exchange POST ${AppConfig.backendUrl}/api/auth/mobile/exchange',
      );
      final response = await client
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/auth/mobile/exchange'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'code': code}),
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        throw Exception(
          'Mobile OAuth exchange failed (${response.statusCode}).',
        );
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        throw Exception('Invalid mobile OAuth exchange response.');
      }
      final gatewayToken = (body['gatewayToken'] ?? '').toString();
      if (gatewayToken.isEmpty) {
        throw Exception(
          'Mobile OAuth exchange did not return a gateway token.',
        );
      }
      await _tokenStore.writeGatewayToken(gatewayToken);
      _log('mobile exchange success user="${body['user']}"');
      return gatewayToken;
    } on TimeoutException {
      throw Exception('Mobile OAuth exchange timed out.');
    } finally {
      client.close();
    }
  }

  @override
  Future<AuthSession?> checkSession() async {
    final token = await _tokenStore.readToken();
    final gatewayToken = await _tokenStore.readGatewayToken();
    final cachedUsername = await _tokenStore.readUsername();
    if (token == null ||
        token.isEmpty ||
        gatewayToken == null ||
        gatewayToken.isEmpty) {
      return null;
    }

    try {
      final response = await _gql.query(GqlDocuments.me);
      final username =
          ((response['auth'] as Map<String, dynamic>)['me']
                  as Map<String, dynamic>)['username']
              .toString();
      if (username.isNotEmpty) {
        await _tokenStore.writeUsername(username);
      }
      return AuthSession(username: username, accessToken: token);
    } catch (error) {
      final raw = error.toString().toLowerCase();
      final isAuthFailure =
          raw.contains('not authenticated') ||
          raw.contains('unauthorized') ||
          raw.contains('invalid token') ||
          raw.contains('oauth proof missing') ||
          raw.contains('oauth session missing');
      if (isAuthFailure) {
        await _tokenStore.clear();
        return null;
      }
      if (cachedUsername != null && cachedUsername.isNotEmpty) {
        _log('checkSession network/transient failure, using cached session');
        return AuthSession(username: cachedUsername, accessToken: token);
      }
      await _tokenStore.clear();
      return null;
    }
  }

  @override
  Future<bool> hasStoredGatewayProof() async {
    final token = await _tokenStore.readGatewayToken();
    return token != null && token.isNotEmpty;
  }

  @override
  Future<bool> checkGatewaySession() async {
    final client = createGraphqlHttpClient();
    try {
      _log('checkGatewaySession GET ${AppConfig.backendUrl}/api/auth/status');
      final response = await client
          .get(
            Uri.parse('${AppConfig.backendUrl}/api/auth/status'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 8));
      _log(
        'checkGatewaySession status=${response.statusCode} body=${response.body}',
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        return body['oauthReady'] == true;
      }
      if (response.statusCode == 401) {
        return false;
      }

      throw Exception('OAuth status check failed (${response.statusCode}).');
    } on TimeoutException {
      throw Exception('OAuth status check timed out.');
    } finally {
      client.close();
    }
  }

  @override
  Future<void> logout() async {
    await _tokenStore.clear();
  }
}
