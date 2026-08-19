import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists auth tokens using the platform keystore/keychain
/// (flutter_secure_storage), never plain SharedPreferences — these are
/// bearer credentials for a money-moving agent account.
class TokenStorage {
  TokenStorage._();
  static final TokenStorage instance = TokenStorage._();

  static const _accessTokenKey = 'badal_agent_access_token';
  static const _refreshTokenKey = 'badal_agent_refresh_token';
  static const _agentNameKey = 'badal_agent_name';
  static const _agentIdKey = 'badal_agent_id';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  Future<void> saveAgentIdentity({required String id, required String name}) async {
    await _storage.write(key: _agentIdKey, value: id);
    await _storage.write(key: _agentNameKey, value: name);
  }

  Future<String?> get accessToken => _storage.read(key: _accessTokenKey);
  Future<String?> get refreshToken => _storage.read(key: _refreshTokenKey);
  Future<String?> get agentName => _storage.read(key: _agentNameKey);
  Future<String?> get agentId => _storage.read(key: _agentIdKey);

  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _agentNameKey);
    await _storage.delete(key: _agentIdKey);
  }

  Future<bool> get hasSession async => (await accessToken) != null;
}
