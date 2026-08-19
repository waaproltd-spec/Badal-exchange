import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Resolves a stable identifier for this physical device, used when calling
/// POST /agent/devices/register.
///
/// SMS reading in this app must only ever run on a device that has been
/// registered this way — see lib/sms/sms_bridge.dart, which refuses to
/// start listening until a device id has been registered with the backend
/// for the currently logged-in agent.
///
/// A locally-generated, persisted UUID is used as the primary identifier
/// (simple, stable across app restarts, no extra native code required).
/// device_info_plus is used only to produce a human-readable label the
/// backend stores for the admin dashboard's benefit (e.g. "Pixel 7 -
/// agent-device"), never as the identifier itself.
class DeviceIdentity {
  DeviceIdentity._();
  static final DeviceIdentity instance = DeviceIdentity._();

  static const _deviceIdPrefsKey = 'badal_agent_device_id';
  static const _uuid = Uuid();

  Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdPrefsKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final generated = _uuid.v4();
    await prefs.setString(_deviceIdPrefsKey, generated);
    return generated;
  }

  Future<String> getDeviceLabel() async {
    try {
      final plugin = DeviceInfoPlugin();
      final info = await plugin.androidInfo;
      final manufacturer = info.manufacturer.trim();
      final model = info.model.trim();
      final label = [manufacturer, model].where((s) => s.isNotEmpty).join(' ');
      return label.isNotEmpty ? label : 'Agent device';
    } catch (_) {
      // device_info_plus can throw on unsupported platforms (e.g. during
      // development on desktop) — fall back to a generic label rather than
      // failing device registration over it.
      return 'Agent device';
    }
  }
}
