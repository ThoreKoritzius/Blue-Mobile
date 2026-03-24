import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthTokenStore {
  AuthTokenStore() : _storage = const FlutterSecureStorage();

  static const _tokenKey = 'blue_mobile_access_token';
  static const _refreshTokenKey = 'blue_mobile_refresh_token';
  static const _loginTicketKey = 'blue_mobile_login_ticket';
  static const _deviceIdKey = 'blue_mobile_device_id';
  static const _usernameKey = 'blue_mobile_username';
  static const _themeModeKey = 'blue_mobile_theme_mode';
  final FlutterSecureStorage _storage;
  String? _cachedToken;
  String? _cachedRefreshToken;
  String? _cachedLoginTicket;
  String? _cachedDeviceId;
  String? _cachedUsername;
  String? _cachedThemeMode;

  String? peekToken() => _cachedToken;

  String? peekRefreshToken() => _cachedRefreshToken;

  String? peekLoginTicket() => _cachedLoginTicket;

  String? peekDeviceId() => _cachedDeviceId;

  String? peekUsername() => _cachedUsername;

  String? peekThemeMode() => _cachedThemeMode;

  Future<String?> readToken() async {
    _cachedToken = await _storage.read(key: _tokenKey);
    return _cachedToken;
  }

  Future<String?> readRefreshToken() async {
    _cachedRefreshToken = await _storage.read(key: _refreshTokenKey);
    return _cachedRefreshToken;
  }

  Future<String?> readLoginTicket() async {
    _cachedLoginTicket = await _storage.read(key: _loginTicketKey);
    return _cachedLoginTicket;
  }

  Future<String> readOrCreateDeviceId() async {
    _cachedDeviceId = await _storage.read(key: _deviceIdKey);
    if (_cachedDeviceId != null && _cachedDeviceId!.isNotEmpty) {
      return _cachedDeviceId!;
    }
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final deviceId = base64UrlEncode(bytes).replaceAll('=', '');
    _cachedDeviceId = deviceId;
    await _storage.write(key: _deviceIdKey, value: deviceId);
    return deviceId;
  }

  Future<String?> readUsername() async {
    _cachedUsername = await _storage.read(key: _usernameKey);
    return _cachedUsername;
  }

  Future<String?> readThemeMode() async {
    _cachedThemeMode = await _storage.read(key: _themeModeKey);
    return _cachedThemeMode;
  }

  Future<void> writeToken(String token) async {
    _cachedToken = token;
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<void> writeRefreshToken(String token) async {
    _cachedRefreshToken = token;
    await _storage.write(key: _refreshTokenKey, value: token);
  }

  Future<void> writeLoginTicket(String token) async {
    _cachedLoginTicket = token;
    await _storage.write(key: _loginTicketKey, value: token);
  }

  Future<void> writeUsername(String username) async {
    _cachedUsername = username;
    await _storage.write(key: _usernameKey, value: username);
  }

  Future<void> writeThemeMode(String themeMode) async {
    _cachedThemeMode = themeMode;
    await _storage.write(key: _themeModeKey, value: themeMode);
  }

  Future<void> clearToken() async {
    _cachedToken = null;
    await _storage.delete(key: _tokenKey);
  }

  Future<void> clearRefreshToken() async {
    _cachedRefreshToken = null;
    await _storage.delete(key: _refreshTokenKey);
  }

  Future<void> clearLoginTicket() async {
    _cachedLoginTicket = null;
    await _storage.delete(key: _loginTicketKey);
  }

  Future<void> clearUsername() async {
    _cachedUsername = null;
    await _storage.delete(key: _usernameKey);
  }

  Future<void> clear() async {
    await clearToken();
    await clearRefreshToken();
    await clearLoginTicket();
    await clearUsername();
  }
}
