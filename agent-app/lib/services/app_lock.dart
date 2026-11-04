import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// The phone's own biometric check (fingerprint). The fingerprint itself is
/// handled by Android inside the phone: the app only learns "yes" or "no",
/// never the fingerprint, and nothing about it is stored or sent anywhere.
abstract class DeviceBiometrics {
  /// A fingerprint (or other biometric) is set up on this phone.
  Future<bool> isAvailable();

  /// Shows the system fingerprint prompt; true only when it matched.
  Future<bool> authenticate(String reason);
}

class LocalAuthBiometrics implements DeviceBiometrics {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Fingerprint only: the PIN and the password are this app's own fallbacks.
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
    } catch (_) {
      return false;
    }
  }
}

/// Fingerprint unlock for the agent app: when it is switched on (Account), the
/// app asks for the fingerprint when it opens and when it comes back after a
/// minute in the background. The account password is always the other way in
/// (the unlock screen has "Use password instead"), so an agent whose
/// fingerprint does not work is never locked out.
///
/// The choice is kept on this phone only (secure storage). The fingerprint
/// itself stays inside Android: the app learns only "matched" or "not".
class AppLock extends ChangeNotifier {
  AppLock({FlutterSecureStorage? storage, DeviceBiometrics? biometrics, DateTime Function()? now})
      : _storage = storage ?? const FlutterSecureStorage(),
        biometrics = biometrics ?? LocalAuthBiometrics(),
        _now = now ?? DateTime.now;

  /// The one the app uses (tests make their own).
  static AppLock instance = AppLock();

  /// How long the app can be in the background before it asks again.
  static const Duration lockAfter = Duration(seconds: 60);

  static const _kEnabled = 'agent_applock_fingerprint';

  final FlutterSecureStorage _storage;
  final DeviceBiometrics biometrics;
  final DateTime Function() _now;

  bool _enabled = false;
  bool _locked = false;
  DateTime? _backgroundAt;
  bool _authenticating = false;

  bool get enabled => _enabled;
  bool get locked => _enabled && _locked;

  /// Reads the saved choice; the app starts locked when it is on.
  Future<void> load() async {
    try {
      _enabled = (await _storage.read(key: _kEnabled)) == '1';
    } catch (_) {
      _enabled = false;
    }
    _locked = _enabled;
    notifyListeners();
  }

  Future<bool> biometricAvailable() => biometrics.isAvailable();

  /// Switches the fingerprint unlock on (the app is not locked right now).
  Future<void> enable() async {
    try {
      await _storage.write(key: _kEnabled, value: '1');
    } catch (_) {}
    _enabled = true;
    _locked = false;
    notifyListeners();
  }

  /// Switches it off and forgets the choice (also when the agent logs out).
  Future<void> disable() async {
    try {
      await _storage.delete(key: _kEnabled);
    } catch (_) {}
    _enabled = false;
    _locked = false;
    notifyListeners();
  }

  /// Shows the fingerprint prompt. The result is only yes or no.
  Future<bool> authenticate(String reason) async {
    _authenticating = true;
    try {
      return await biometrics.authenticate(reason);
    } finally {
      _authenticating = false;
      _backgroundAt = null;
    }
  }

  void unlock() {
    if (!_locked) return;
    _locked = false;
    notifyListeners();
  }

  void lock() {
    if (!_enabled || _locked) return;
    _locked = true;
    notifyListeners();
  }

  /// The app went to the background (not for the system fingerprint prompt).
  void appPaused() {
    if (_authenticating) return;
    _backgroundAt ??= _now();
  }

  /// The app came back: locked again when it was away for a minute or more.
  void appResumed() {
    final at = _backgroundAt;
    _backgroundAt = null;
    if (at != null && _enabled && _now().difference(at) >= lockAfter) lock();
  }
}
