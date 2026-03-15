import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthTokenStore {
  AuthTokenStore() : _storage = const FlutterSecureStorage();

  static const _tokenKey = 'blue_mobile_access_token';
  static const _gatewayTokenKey = 'blue_mobile_gateway_token';
  static const _usernameKey = 'blue_mobile_username';
  final FlutterSecureStorage _storage;
  String? _cachedToken;
  String? _cachedGatewayToken;
  String? _cachedUsername;

  String? peekToken() => _cachedToken;

  String? peekGatewayToken() => _cachedGatewayToken;

  String? peekUsername() => _cachedUsername;

  Future<String?> readToken() async {
    _cachedToken = await _storage.read(key: _tokenKey);
    return _cachedToken;
  }

  Future<String?> readGatewayToken() async {
    _cachedGatewayToken = await _storage.read(key: _gatewayTokenKey);
    return _cachedGatewayToken;
  }

  Future<String?> readUsername() async {
    _cachedUsername = await _storage.read(key: _usernameKey);
    return _cachedUsername;
  }

  Future<void> writeToken(String token) async {
    _cachedToken = token;
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<void> writeGatewayToken(String token) async {
    _cachedGatewayToken = token;
    await _storage.write(key: _gatewayTokenKey, value: token);
  }

  Future<void> writeUsername(String username) async {
    _cachedUsername = username;
    await _storage.write(key: _usernameKey, value: username);
  }

  Future<void> clearToken() async {
    _cachedToken = null;
    await _storage.delete(key: _tokenKey);
  }

  Future<void> clearGatewayToken() async {
    _cachedGatewayToken = null;
    await _storage.delete(key: _gatewayTokenKey);
  }

  Future<void> clearUsername() async {
    _cachedUsername = null;
    await _storage.delete(key: _usernameKey);
  }

  Future<void> clear() async {
    await clearToken();
    await clearGatewayToken();
    await clearUsername();
  }
}
