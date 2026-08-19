import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../api/agent_api.dart';
import '../api/api_exception.dart';
import '../api/token_storage.dart';
import '../models/agent_profile.dart';
import '../services/device_identity.dart';
import '../sms/sms_bridge.dart';

enum AuthStatus { unknown, loggedOut, loggedIn }

/// App-wide session state: authentication, the agent's own profile, and
/// ownership of the SMS bridge lifecycle (start/stop tied to login state,
/// permission state, and device registration).
///
/// Kept as a single ChangeNotifier (via provider) rather than multiple
/// smaller state classes, per the product's "keep it simple" instruction —
/// this is the only cross-screen state the app needs.
class Session extends ChangeNotifier {
  Session({AgentApi? api, TokenStorage? tokenStorage})
      : _api = api ?? AgentApi(),
        _tokens = tokenStorage ?? TokenStorage.instance {
    // Share a single AgentApi/ApiClient instance between the session and
    // the SMS bridge so both benefit from the same bearer-token refresh
    // handling instead of racing two independent token refreshes.
    smsBridge = SmsBridge(api: _api);
    _api.client.onSessionExpired = _handleSessionExpired;
  }

  final AgentApi _api;
  final TokenStorage _tokens;
  late final SmsBridge smsBridge;

  AgentApi get api => _api;

  AuthStatus status = AuthStatus.unknown;
  AgentProfile? profile;
  String? deviceId;
  String? _agentName;
  String? loginError;
  bool isBusy = false;

  String get agentDisplayName => profile?.name ?? _agentName ?? 'Agent';

  /// Restores a previously persisted session on app startup.
  Future<void> bootstrap() async {
    final hasSession = await _tokens.hasSession;
    if (!hasSession) {
      status = AuthStatus.loggedOut;
      notifyListeners();
      return;
    }
    _agentName = await _tokens.agentName;
    deviceId = await DeviceIdentity.instance.getOrCreateDeviceId();
    status = AuthStatus.loggedIn;
    notifyListeners();

    // Best-effort: refresh profile and resume SMS listening in the
    // background; failures here don't invalidate the restored session
    // (a fresh access token will be pulled on the next real API call via
    // ApiClient's built-in refresh-on-401 handling).
    unawaited(_loadProfile());
    unawaited(_maybeAutoStartSmsBridge());
  }

  Future<bool> login({required String phone, required String password}) async {
    isBusy = true;
    loginError = null;
    notifyListeners();
    try {
      final result = await _api.login(phone: phone, password: password);
      await _tokens.saveTokens(accessToken: result.accessToken, refreshToken: result.refreshToken);
      await _tokens.saveAgentIdentity(id: result.userId, name: result.name);
      _agentName = result.name;

      deviceId = await DeviceIdentity.instance.getOrCreateDeviceId();
      final label = await DeviceIdentity.instance.getDeviceLabel();
      try {
        await _api.registerDevice(deviceId: deviceId!, deviceLabel: label);
      } catch (e) {
        // Device registration failure shouldn't block login entirely, but
        // SMS auto-matching must not run until it succeeds — surface this
        // clearly on the dashboard instead (see `deviceRegistered`).
        deviceRegistrationError = e is ApiException ? e.message : e.toString();
      }

      status = AuthStatus.loggedIn;
      isBusy = false;
      notifyListeners();

      unawaited(_loadProfile());
      unawaited(_maybeAutoStartSmsBridge());
      return true;
    } on ApiException catch (e) {
      loginError = e.message;
      isBusy = false;
      notifyListeners();
      return false;
    } catch (e) {
      loginError = 'Something went wrong. Please try again.';
      isBusy = false;
      notifyListeners();
      return false;
    }
  }

  String? deviceRegistrationError;

  Future<void> retryDeviceRegistration() async {
    if (deviceId == null) return;
    try {
      final label = await DeviceIdentity.instance.getDeviceLabel();
      await _api.registerDevice(deviceId: deviceId!, deviceLabel: label);
      deviceRegistrationError = null;
      notifyListeners();
      unawaited(_maybeAutoStartSmsBridge());
    } catch (e) {
      deviceRegistrationError = e is ApiException ? e.message : e.toString();
      notifyListeners();
    }
  }

  Future<void> _loadProfile() async {
    try {
      profile = await _api.getProfile();
      notifyListeners();
    } catch (_) {
      // Non-fatal — dashboard/profile screen can retry individually.
    }
  }

  /// Starts the SMS bridge automatically once: this is Android, a device
  /// id exists, device registration succeeded, and the permission has
  /// already been granted previously. If permission hasn't been granted
  /// yet, the Dashboard/SMS Transactions screen prompts for it explicitly
  /// rather than surprising the agent with a silent OS permission dialog.
  Future<void> _maybeAutoStartSmsBridge() async {
    if (!Platform.isAndroid) return;
    if (deviceId == null || deviceRegistrationError != null) return;
    final granted = await smsBridge.hasPermission();
    if (!granted) return;
    await smsBridge.start(deviceId: deviceId!);
  }

  /// Explicit opt-in path used by the UI: requests the SMS permission (if
  /// needed) and starts the bridge. Returns true if listening is active
  /// afterward.
  Future<bool> enableSmsAutoMatching() async {
    if (!Platform.isAndroid) return false;
    if (deviceId == null) return false;
    if (deviceRegistrationError != null) {
      await retryDeviceRegistration();
      if (deviceRegistrationError != null) return false;
    }
    var granted = await smsBridge.hasPermission();
    if (!granted) {
      granted = await smsBridge.requestPermission();
    }
    if (!granted) return false;
    await smsBridge.start(deviceId: deviceId!);
    notifyListeners();
    return true;
  }

  Future<void> disableSmsAutoMatching() async {
    await smsBridge.stop();
    notifyListeners();
  }

  void _handleSessionExpired() {
    status = AuthStatus.loggedOut;
    profile = null;
    unawaited(smsBridge.stop());
    notifyListeners();
  }

  Future<void> logout() async {
    await smsBridge.stop();
    await _api.logout();
    status = AuthStatus.loggedOut;
    profile = null;
    deviceRegistrationError = null;
    notifyListeners();
  }
}
