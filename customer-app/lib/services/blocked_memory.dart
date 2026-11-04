import 'package:shared_preferences/shared_preferences.dart';

/// Remembers, on this phone, that its account was blocked (the phone was signed out, or a login was refused
/// because of it). The next login that the server accepts is then the server's own confirmation that the
/// account was unblocked: the app shows the Account Unblocked screen once. Nothing about the account is stored
/// except this yes / no, and it is never asked of the server for a phone number that is not logged in.
class BlockedMemory {
  const BlockedMemory._();

  static const _key = 'account_was_blocked';

  static Future<void> mark() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, true);
    } catch (_) {}
  }

  static Future<bool> wasBlocked() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clear() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }
}
