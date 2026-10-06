import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Remembers who is signed in on this device (shown before the profile
/// loads). The session itself -- access and refresh tokens -- is kept by
/// Supabase Auth in the platform keystore (see SecureSessionStorage).
class TokenStorage {
  TokenStorage._();
  static final TokenStorage instance = TokenStorage._();

  static const _agentNameKey = 'badal_agent_name';
  static const _agentIdKey = 'badal_agent_id';
  // Written by app versions that talked to the old REST backend.
  static const _legacyKeys = ['badal_agent_access_token', 'badal_agent_refresh_token'];

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> saveAgentIdentity({required String id, required String name}) async {
    await _storage.write(key: _agentIdKey, value: id);
    await _storage.write(key: _agentNameKey, value: name);
  }

  Future<String?> get agentName => _storage.read(key: _agentNameKey);
  Future<String?> get agentId => _storage.read(key: _agentIdKey);

  Future<void> clear() async {
    await _storage.delete(key: _agentNameKey);
    await _storage.delete(key: _agentIdKey);
    for (final key in _legacyKeys) {
      await _storage.delete(key: key);
    }
  }
}
