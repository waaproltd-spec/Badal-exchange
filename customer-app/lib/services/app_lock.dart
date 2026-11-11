import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
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
      // canCheckBiometrics is true only when the phone has the sensor and a
      // fingerprint is enrolled. (The list of biometric types is not used: some
      // phones report it empty although the fingerprint works.)
      if (!await _auth.isDeviceSupported()) return false;
      return await _auth.canCheckBiometrics;
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

enum PinCheck { ok, wrong, waiting, tooMany }

class PinAttempt {
  const PinAttempt(this.result, {this.wait = Duration.zero});
  final PinCheck result;

  /// For [PinCheck.waiting] and the wrong try that started a wait.
  final Duration wait;
}

/// Customer verification: a PIN kept only on this phone (salted and hashed,
/// in the platform's secure storage) and, if the customer chooses, the phone's
/// fingerprint. It locks the app when it is opened and after it was away for a
/// minute, and the customer can always verify with the account password
/// instead. Wrong PINs are counted on the phone: a wait that grows after five,
/// and a forced sign-in with the password after ten.
///
/// Nothing here is sent to the server, and no fingerprint data is ever read.
class AppLock extends ChangeNotifier {
  AppLock({FlutterSecureStorage? storage, DeviceBiometrics? biometrics, DateTime Function()? now})
      : _storage = storage ?? const FlutterSecureStorage(),
        biometrics = biometrics ?? LocalAuthBiometrics(),
        _now = now ?? DateTime.now;

  /// The one the app uses (tests make their own).
  static AppLock instance = AppLock();

  static const int pinLength = 6;

  /// How long the app can be in the background before it asks again.
  static const Duration lockAfter = Duration(seconds: 60);
  static const int freeTries = 5;
  static const int maxTries = 10;

  static const _kPin = 'applock_pin';
  static const _kBio = 'applock_bio';
  static const _kFails = 'applock_fails';
  static const _kUntil = 'applock_until';
  static const int _rounds = 20000;

  final FlutterSecureStorage _storage;
  final DeviceBiometrics biometrics;
  final DateTime Function() _now;

  String? _pinRecord;
  bool _biometric = false;
  bool _locked = false;
  int _fails = 0;
  DateTime? _until;
  DateTime? _backgroundAt;
  bool _authenticating = false;

  /// A PIN is set: the app asks for verification.
  bool get enabled => _pinRecord != null;
  bool get biometricEnabled => enabled && _biometric;
  bool get locked => enabled && _locked;

  /// Reads what is saved; the app starts locked when verification is on.
  Future<void> load() async {
    try {
      _pinRecord = await _storage.read(key: _kPin);
      _biometric = (await _storage.read(key: _kBio)) == '1';
      _fails = int.tryParse(await _storage.read(key: _kFails) ?? '') ?? 0;
      final until = int.tryParse(await _storage.read(key: _kUntil) ?? '');
      _until = until == null ? null : DateTime.fromMillisecondsSinceEpoch(until);
    } catch (_) {
      _pinRecord = null;
    }
    _locked = enabled;
    notifyListeners();
  }

  Future<bool> biometricAvailable() => biometrics.isAvailable();

  // ---------------------------------------------------------------- the PIN

  /// 6 digits that are not all the same and not a run (123456, 654321).
  static bool isStrongPin(String pin) {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) return false;
    final d = pin.codeUnits;
    if (d.every((c) => c == d.first)) return false;
    var up = true, down = true;
    for (var i = 1; i < d.length; i++) {
      if (d[i] != d[i - 1] + 1) up = false;
      if (d[i] != d[i - 1] - 1) down = false;
    }
    return !up && !down;
  }

  static List<int> _derive(String pin, List<int> salt) {
    var digest = sha256.convert([...utf8.encode(pin), ...salt]).bytes;
    for (var i = 0; i < _rounds; i++) {
      digest = sha256.convert([...digest, ...salt]).bytes;
    }
    return digest;
  }

  static String _record(String pin) {
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    return '${base64.encode(salt)}:${base64.encode(_derive(pin, salt))}';
  }

  static bool _matches(String record, String pin) {
    final parts = record.split(':');
    if (parts.length != 2) return false;
    try {
      final expected = base64.decode(parts[1]);
      final actual = _derive(pin, base64.decode(parts[0]));
      if (expected.length != actual.length) return false;
      var diff = 0;
      for (var i = 0; i < expected.length; i++) {
        diff |= expected[i] ^ actual[i];
      }
      return diff == 0;
    } catch (_) {
      return false;
    }
  }

  /// Turns verification on (or changes the PIN). The app is not locked right now.
  Future<void> setPin(String pin, {bool? biometric}) async {
    assert(isStrongPin(pin));
    final record = _record(pin);
    await _write(_kPin, record);
    if (biometric != null) await _write(_kBio, biometric ? '1' : '0');
    _pinRecord = record;
    if (biometric != null) _biometric = biometric;
    await _clearFailures();
    _locked = false;
    notifyListeners();
  }

  Future<void> setBiometric(bool on) async {
    if (!enabled) return;
    await _write(_kBio, on ? '1' : '0');
    _biometric = on;
    notifyListeners();
  }

  /// Turns verification off and forgets everything (also when the customer logs out).
  Future<void> disable() async {
    for (final key in [_kPin, _kBio, _kFails, _kUntil]) {
      try {
        await _storage.delete(key: key);
      } catch (_) {}
    }
    _pinRecord = null;
    _biometric = false;
    _fails = 0;
    _until = null;
    _locked = false;
    notifyListeners();
  }

  /// Checks a typed PIN. Wrong tries are counted on this phone.
  Future<PinAttempt> checkPin(String pin) async {
    final record = _pinRecord;
    if (record == null) return const PinAttempt(PinCheck.ok);
    final until = _until;
    if (until != null && _now().isBefore(until)) return PinAttempt(PinCheck.waiting, wait: until.difference(_now()));
    if (_matches(record, pin)) {
      await _clearFailures();
      return const PinAttempt(PinCheck.ok);
    }
    _fails++;
    await _write(_kFails, '$_fails');
    if (_fails >= maxTries) return const PinAttempt(PinCheck.tooMany);
    if (_fails >= freeTries) {
      final wait = Duration(seconds: min(900, 30 * (1 << (_fails - freeTries))));
      _until = _now().add(wait);
      await _write(_kUntil, '${_until!.millisecondsSinceEpoch}');
      return PinAttempt(PinCheck.wrong, wait: wait);
    }
    return const PinAttempt(PinCheck.wrong);
  }

  /// After the account password was verified instead of the PIN.
  Future<void> passwordVerified() => _clearFailures();

  Future<void> _clearFailures() async {
    _fails = 0;
    _until = null;
    await _write(_kFails, '0');
    try {
      await _storage.delete(key: _kUntil);
    } catch (_) {}
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {}
  }

  // ------------------------------------------------------------ fingerprint

  /// Shows the fingerprint prompt. The result is only yes or no.
  Future<bool> authenticateBiometric(String reason) async {
    _authenticating = true;
    try {
      return await biometrics.authenticate(reason);
    } finally {
      _authenticating = false;
      _backgroundAt = null;
    }
  }

  // ------------------------------------------------------------ app locking

  void unlock() {
    if (!_locked) return;
    _locked = false;
    notifyListeners();
  }

  void lock() {
    if (!enabled || _locked) return;
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
    if (at != null && enabled && _now().difference(at) >= lockAfter) lock();
  }
}
