// System Health: the one-line status on the Dashboard and the list of what the monitor found.
import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/models/management.dart';
import 'package:badal_agent_app/screens/admin/system_health_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _json({List<Map<String, dynamic>> open = const [], List<Map<String, dynamic>> resolved = const [], bool linked = true, DateTime? at}) => {
      'lastScan': {'at': (at ?? DateTime.now()).toUtc().toIso8601String(), 'checks': 13, 'errors': 0},
      'ownerChatLinked': linked,
      'open': open,
      'resolved': resolved,
    };

Map<String, dynamic> _incident(String key, String severity, {String? repair, bool financial = false, bool developer = false}) => {
      'key': key, 'severity': severity, 'title': 'Title of $key', 'cause': 'because', 'firstSeen': '2026-11-05T08:00:00Z',
      'occurrences': 3, 'repair': repair, 'repairResult': repair == null ? null : 'waiting', 'financial': financial, 'customers': true, 'developer': developer,
    };

class _Api extends AgentApi {
  _Api(this.data);
  Map<String, dynamic> data;
  @override
  Future<SystemHealth> getSystemHealth() async => SystemHealth.fromJson(data);
}

Future<void> _show(WidgetTester t, Map<String, dynamic> data) async {
  t.view.physicalSize = const Size(900, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final session = Session(api: _Api(data));
  await t.pumpWidget(ChangeNotifierProvider<Session>.value(
    value: session,
    child: const MaterialApp(home: SystemHealthScreen(poll: Duration(hours: 1))),
  ));
  await t.pump();
  await t.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.current.value = AppLanguage.english;
  });

  test('the model: problems and critical ignore info items; a scan that is 5 minutes old is stale', () {
    final h = SystemHealth.fromJson(_json(open: [_incident('a', 'critical'), _incident('b', 'warning'), _incident('c', 'info')]));
    expect(h.problems, 2);
    expect(h.critical, 1);
    expect(h.stale, isFalse);
    expect(SystemHealth.fromJson(_json(at: DateTime.now().subtract(const Duration(minutes: 9)))).stale, isTrue);
    expect(SystemHealth.fromJson({'open': [], 'resolved': []}).stale, isTrue, reason: 'no scan at all');
  });

  testWidgets('healthy: one green line and nothing open', (t) async {
    await _show(t, _json());
    expect(find.text('Everything is healthy'), findsOneWidget);
    expect(find.byKey(const Key('health-none')), findsOneWidget);
  });

  testWidgets('a critical money problem is shown with its cause, repair and the warning not to touch balances', (t) async {
    await _show(t, _json(open: [_incident('ledger_wallet_mismatch', 'critical', financial: true, developer: true)]));
    expect(find.text('1 critical problem(s)'), findsOneWidget);
    expect(find.byKey(const Key('health-ledger_wallet_mismatch')), findsOneWidget);
    expect(find.text('Title of ledger_wallet_mismatch'), findsOneWidget);
    expect(find.textContaining('do not change balances by hand'), findsOneWidget);
    expect(find.text('A developer is needed'), findsOneWidget);
  });

  testWidgets('a repair the platform made is listed; solved problems have their own list', (t) async {
    await _show(t, _json(open: [_incident('broadcast_stuck', 'warning', repair: 'back in the queue')], resolved: [
      {'key': 'sahal_feed', 'severity': 'critical', 'title': 'Sahal feed', 'resolvedAt': '2026-11-05T07:00:00Z', 'repair': 'worker woken', 'repairResult': 'worked'},
    ]));
    expect(find.text('1 problem(s) to watch'), findsOneWidget);
    expect(find.textContaining('back in the queue'), findsOneWidget);
    expect(find.text('SOLVED IN THE LAST 2 DAYS'), findsOneWidget);
    expect(find.byKey(const Key('health-sahal_feed')), findsOneWidget);
  });

  testWidgets('a monitor that stopped scanning is a problem of its own; an unlinked owner chat is said', (t) async {
    await _show(t, _json(at: DateTime.now().subtract(const Duration(minutes: 20)), linked: false));
    expect(find.text('The monitor has not scanned for 5 minutes'), findsOneWidget);
    expect(find.byKey(const Key('health-owner-chat')), findsOneWidget);
  });
}
