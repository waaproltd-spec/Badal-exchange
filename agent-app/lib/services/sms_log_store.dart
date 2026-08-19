import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/sms_transaction_log.dart';

/// Simple local persistence for the "SMS Transactions" screen.
///
/// The backend has no dedicated "list my sms transactions" GET endpoint, so
/// this device keeps its own log of what it has submitted (extracted fields
/// + the backend's matched/unmatched/duplicate response) — never the raw
/// SMS text. Capped to the most recent [_maxEntries] so it can't grow
/// unbounded on a long-lived install.
class SmsLogStore {
  SmsLogStore._();
  static final SmsLogStore instance = SmsLogStore._();

  static const _prefsKey = 'badal_agent_sms_log_v1';
  static const _maxEntries = 200;

  Future<List<SmsTransactionLog>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => SmsTransactionLog.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.submittedAt.compareTo(a.submittedAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> add(SmsTransactionLog entry) async {
    final all = await loadAll();
    all.insert(0, entry);
    final trimmed = all.length > _maxEntries ? all.sublist(0, _maxEntries) : all;
    await _saveAll(trimmed);
  }

  Future<void> _saveAll(List<SmsTransactionLog> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, encoded);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
