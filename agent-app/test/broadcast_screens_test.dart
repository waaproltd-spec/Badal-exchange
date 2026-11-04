// Scheduled mass messages in the Agent App: the stats, the schedules (daily, weekly, monthly), the
// create / edit form with its summary, preview and test message, pause, resume and delete, and the
// sending progress. The backend (tests/scheduled_messages.test.mjs) sends them; only managers may manage.
import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/models/broadcast.dart';
import 'package:badal_agent_app/screens/admin/broadcast_screens.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:badal_agent_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _schedule(String id, String kind, String time, {String status = 'active', int? weekday, int? monthDay, String message = 'Macaamiisha sharafta leh, mahadsanid.', Map<String, dynamic>? lastRun, List<String> channels = const ['telegram'], String? title}) => {
      'id': id, 'title': title, 'channels': channels, 'message': message, 'kind': kind, 'time': time, 'weekday': weekday, 'monthDay': monthDay, 'status': status,
      'nextRunAt': '2026-11-05T05:00:00Z', 'lastRunAt': null, 'lastRun': lastRun,
    };

class _Api extends AgentApi {
  _Api() : super();

  final calls = <String>[];
  Map<String, Object?>? saved;
  bool teamChatLinked = true;
  Map<String, dynamic> runSending = const {};
  List<Map<String, dynamic>> schedules = [
    _schedule('s1', 'daily', '08:00', channels: ['push'], title: 'Maalinle', lastRun: {'status': 'done', 'total': 100, 'sent': 97, 'failed': 3}),
    _schedule('s2', 'weekly', '10:00', weekday: 7, channels: ['push', 'telegram']),
    _schedule('s3', 'monthly', '09:00', monthDay: 1, status: 'paused'),
  ];

  @override
  Future<BroadcastData> getBroadcasts() async {
    calls.add('list');
    return BroadcastData.fromJson({
      'stats': {'registeredCustomers': 160, 'activeCustomers': 150, 'pushReachable': 130, 'eligibleCustomers': 120, 'sent': 1920, 'failed': 28, 'pushSent': 1500, 'pushFailed': 20, 'pushNoDevice': 40, 'telegramSent': 420, 'telegramFailed': 8, 'activeSchedules': 2, 'teamChatLinked': teamChatLinked},
      'schedules': schedules,
      'runs': [if (runSending.isNotEmpty) runSending],
    });
  }

  @override
  Future<BroadcastSchedule> saveBroadcast({String? id, required String message, required String kind, required String time, int? weekday, int? monthDay, bool active = true, String? title, List<String> channels = const ['push']}) async {
    calls.add('save');
    saved = {'id': id, 'message': message, 'kind': kind, 'time': time, 'weekday': weekday, 'monthDay': monthDay, 'active': active, 'title': title, 'channels': channels};
    return BroadcastSchedule.fromJson(_schedule(id ?? 'new', kind, time, weekday: weekday, monthDay: monthDay));
  }

  @override
  Future<void> setBroadcastActive(String id, bool active) async {
    calls.add('active $id $active');
    final i = schedules.indexWhere((s) => s['id'] == id);
    schedules[i] = {...schedules[i], 'status': active ? 'active' : 'paused'};
  }

  @override
  Future<void> deleteBroadcast(String id) async {
    calls.add('delete $id');
    schedules.removeWhere((s) => s['id'] == id);
  }

  bool deviceRegistered = true;

  @override
  Future<bool> testPush({String? title, required String message, required String phone}) async {
    calls.add('push $title|$message|$phone');
    if (phone == '252699999999') throw const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'No Customer App customer has this phone number');
    return deviceRegistered;
  }

  @override
  Future<void> testBroadcast(String message) async {
    calls.add('test $message');
    if (!teamChatLinked) throw const ApiException(statusCode: 409, code: 'TEAM_CHAT_NOT_LINKED', message: 'The Telegram team chat is not linked yet');
  }
}

Future<_Api> _pump(WidgetTester tester, Widget home, {Size size = const Size(393, 1800), _Api? api, ThemeData? theme}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final a = api ?? _Api();
  await tester.pumpWidget(ChangeNotifierProvider(create: (_) => Session(api: a), child: MaterialApp(theme: theme, home: home)));
  await tester.pumpAndSettle();
  return a;
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  test('Mogadishu time and the schedule words', () {
    expect(mogadishu(DateTime.utc(2026, 11, 4, 19, 5)), '2026-11-04 22:05', reason: 'GMT+3, whatever the phone\'s time zone');
    expect(mogadishu(DateTime.utc(2026, 11, 4, 21, 30)), '2026-11-05 00:30');
    expect(timeLabel('08:00'), '08:00 AM');
    expect(timeLabel('00:15'), '12:15 AM');
    expect(timeLabel('12:00'), '12:00 PM');
    expect(timeLabel('17:45'), '05:45 PM');
    expect(scheduleSummary('daily', '08:00'), 'Every day at 08:00 AM (Mogadishu time)');
    expect(scheduleSummary('weekly', '10:00', weekday: 7), 'Every Sunday at 10:00 AM (Mogadishu time)');
    expect(scheduleSummary('monthly', '09:00', monthDay: 1), 'On day 1 of every month at 09:00 AM (Mogadishu time)');
  });

  test('the model: progress is what was handled of the total', () {
    final run = BroadcastRun.fromJson({'id': 'r', 'status': 'sending', 'total': 200, 'sent': 150, 'failed': 24, 'skipped': 6});
    expect(run.percent, 90);
    expect(run.sending, isTrue);
    expect(BroadcastRun.fromJson({'id': 'r', 'status': 'done', 'total': 0}).percent, 100);
  });

  testWidgets('the stats and each schedule: kind, time, state, next moment (Mogadishu) and the last run', (tester) async {
    await _pump(tester, const BroadcastScreen());
    expect(find.descendant(of: find.byKey(const Key('broadcast-stat-customers')), matching: find.text('150')), findsOneWidget, reason: 'every active customer');
    expect(find.text('130 with notifications • 120 on Telegram'), findsOneWidget);
    expect(find.text('Notifications sent'), findsOneWidget);
    expect(find.text('Push 1500 • Telegram 420'), findsOneWidget);
    expect(find.text('Push 20 • Telegram 8'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('broadcast-stat-sent')), matching: find.text('1920')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('broadcast-stat-failed')), matching: find.text('28')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('broadcast-stat-active')), matching: find.text('2')), findsOneWidget);
    expect(find.text('Daily • 08:00 AM'), findsOneWidget);
    expect(find.text('Weekly • 10:00 AM'), findsOneWidget);
    expect(find.text('Every Sunday at 10:00 AM (Mogadishu time)'), findsOneWidget);
    expect(find.text('Monthly • 09:00 AM'), findsOneWidget);
    expect(find.text('Next: 2026-11-05 08:00'), findsNWidgets(2), reason: 'only the active ones');
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-last-s1'))).data, 'Last run: 97 sent, 3 failed');
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-status-s3'))).data, 'Paused');
    expect(find.byKey(const Key('broadcast-progress')), findsNothing);
    expect(find.byKey(const Key('broadcast-channel-s1-push')), findsOneWidget);
    expect(find.byKey(const Key('broadcast-channel-s1-telegram')), findsNothing);
    expect(find.byKey(const Key('broadcast-channel-s2-push')), findsOneWidget);
    expect(find.byKey(const Key('broadcast-channel-s2-telegram')), findsOneWidget);
    expect(find.text('Maalinle'), findsOneWidget, reason: 'the title');
  });

  testWidgets('a run being sent shows its progress; the list asks again by itself', (tester) async {
    final api = _Api()..runSending = {'id': 'r1', 'status': 'sending', 'channel': 'push', 'total': 200, 'sent': 150, 'failed': 24, 'skipped': 6, 'isTest': false};
    await _pump(tester, const BroadcastScreen(), api: api);
    expect(find.byKey(const Key('broadcast-progress')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-percent'))).data, '90%', reason: '(150 + 24 + 6) of 200');
    expect(find.text('Sending progress • Push notification'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-skipped'))).data, '6 customers have no device (notifications off or signed out).');
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-counts'))).data, 'Sent 150 • Failed 24 • Total 200');
    final before = api.calls.where((c) => c == 'list').length;
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c == 'list').length, greaterThan(before), reason: 'the progress follows by itself');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pause and resume are one switch; delete asks first', (tester) async {
    final api = await _pump(tester, const BroadcastScreen());
    await tester.tap(find.byKey(const Key('broadcast-active-s1')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('active s1 false'));
    expect(tester.widget<Switch>(find.byKey(const Key('broadcast-active-s1'))).value, isFalse);
    await tester.tap(find.byKey(const Key('broadcast-active-s3')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('active s3 true'));

    await tester.tap(find.byKey(const Key('broadcast-menu-s2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('delete')), isEmpty);
    expect(find.text('Delete this schedule?'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('delete s2'));
    expect(find.text('Weekly • 10:00 AM'), findsNothing);
  });

  testWidgets('create a weekly schedule: the summary follows, it is sent to the server as chosen', (tester) async {
    final api = await _pump(tester, const BroadcastFormScreen());
    expect(find.text('Every day at 08:00 AM (Mogadishu time)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('broadcast-message')), 'Toddobaad wanaagsan!');
    await tester.tap(find.byKey(const Key('broadcast-kind-weekly')));
    await tester.pumpAndSettle();
    expect(find.text('Every Sunday at 08:00 AM (Mogadishu time)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('broadcast-weekday-3')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-summary-text'))).data, 'Every Wednesday at 08:00 AM (Mogadishu time)');
    await tester.ensureVisible(find.byKey(const Key('broadcast-save')));
    await tester.tap(find.byKey(const Key('broadcast-save')));
    await tester.pumpAndSettle();
    expect(api.saved, {'id': null, 'message': 'Toddobaad wanaagsan!', 'kind': 'weekly', 'time': '08:00', 'weekday': 3, 'monthDay': 1, 'active': true, 'title': null, 'channels': ['push']});
  });

  testWidgets('a monthly schedule picks the day of the month; an empty message is not saved', (tester) async {
    final api = await _pump(tester, const BroadcastFormScreen());
    await tester.tap(find.byKey(const Key('broadcast-kind-monthly')));
    await tester.pumpAndSettle();
    expect(find.text('A shorter month sends on its last day.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('broadcast-save')));
    await tester.tap(find.byKey(const Key('broadcast-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('broadcast-error')), findsOneWidget);
    expect(api.calls, isNot(contains('save')));

    await tester.enterText(find.byKey(const Key('broadcast-message')), 'Bisha cusub!');
    await tester.tap(find.byKey(const Key('broadcast-monthday')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15').last);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-summary-text'))).data, 'On day 15 of every month at 08:00 AM (Mogadishu time)');
    await tester.ensureVisible(find.byKey(const Key('broadcast-activate')));
    await tester.tap(find.byKey(const Key('broadcast-activate')));
    await tester.ensureVisible(find.byKey(const Key('broadcast-save')));
    await tester.tap(find.byKey(const Key('broadcast-save')));
    await tester.pumpAndSettle();
    expect(api.saved?['monthDay'], 15);
    expect(api.saved?['active'], false, reason: 'saved paused when "Start sending" is off');
  });

  testWidgets('editing starts from the saved values', (tester) async {
    final api = _Api();
    await _pump(tester, BroadcastFormScreen(schedule: BroadcastSchedule.fromJson(_schedule('s2', 'weekly', '10:30', weekday: 5, message: 'Jimce wanaagsan'))), api: api);
    expect(tester.widget<TextField>(find.byKey(const Key('broadcast-message'))).controller!.text, 'Jimce wanaagsan');
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-summary-text'))).data, 'Every Friday at 10:30 AM (Mogadishu time)');
    await tester.ensureVisible(find.byKey(const Key('broadcast-save')));
    await tester.tap(find.byKey(const Key('broadcast-save')));
    await tester.pumpAndSettle();
    expect(api.saved?['id'], 's2');
    expect(api.saved?['time'], '10:30');
  });

  testWidgets('Preview shows the message; Test message goes to the team chat and says so; a missing team chat is explained', (tester) async {
    final api = await _pump(tester, const BroadcastFormScreen());
    await tester.enterText(find.byKey(const Key('broadcast-message')), 'Salaan\nMahadsanid 💙');
    await tester.tap(find.byKey(const Key('broadcast-channel-telegram')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('broadcast-preview-button')));
    await tester.tap(find.byKey(const Key('broadcast-preview-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('broadcast-preview')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-preview-text'))).data, 'Salaan\nMahadsanid 💙');
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('broadcast-test-button')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('test Salaan\nMahadsanid 💙'));
    expect(find.text('Test message sent to the team chat.'), findsOneWidget);
    expect(api.calls, isNot(contains('save')), reason: 'a test is not a schedule');

    api.teamChatLinked = false;
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.byKey(const Key('broadcast-test-button')));
    await tester.pumpAndSettle();
    expect(find.text('The Telegram team chat is not linked yet'), findsOneWidget);
  });

  testWidgets('Somali: the day names and the summary; a 320 px phone with the app theme fits', (tester) async {
    AppLanguage.current.value = AppLanguage.somali;
    await _pump(tester, const BroadcastFormScreen(), size: const Size(320, 2000), theme: AppTheme.current);
    await tester.tap(find.byKey(const Key('broadcast-kind-weekly')));
    await tester.pumpAndSettle();
    expect(find.text('Axad'), findsOneWidget);
    expect(find.text('Isniin'), findsOneWidget);
    expect(find.text('Maalin kasta oo Axad ah, saacadda 08:00 AM (waqtiga Muqdisho)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('broadcast-channel-telegram')));
    await tester.pumpAndSettle();
    expect(find.text('Fariinta tijaabada'), findsOneWidget);
    // The two buttons sit side by side, not one under the other.
    final a = tester.getRect(find.byKey(const Key('broadcast-preview-button')));
    final b = tester.getRect(find.byKey(const Key('broadcast-test-button')));
    expect(a.right, lessThanOrEqualTo(b.left), reason: 'side by side');
    expect((a.center.dy - b.center.dy).abs(), lessThan(30), reason: 'on one row');
    expect(b.right, lessThanOrEqualTo(320));
  });

  testWidgets('channels: push by default, Telegram optional, at least one; the title and the channels are saved', (tester) async {
    final api = await _pump(tester, const BroadcastFormScreen());
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('broadcast-channel-push'))).value, isTrue);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('broadcast-channel-telegram'))).value, isFalse);
    // Turning the only channel off turns the other one on.
    await tester.tap(find.byKey(const Key('broadcast-channel-push')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('broadcast-channel-telegram'))).value, isTrue);
    expect(find.byKey(const Key('broadcast-title')), findsNothing, reason: 'no title for Telegram only');
    await tester.tap(find.byKey(const Key('broadcast-channel-push')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('broadcast-title')), 'Ogeysiis muhiim ah');
    await tester.enterText(find.byKey(const Key('broadcast-message')), 'Salaan');
    await tester.ensureVisible(find.byKey(const Key('broadcast-save')));
    await tester.tap(find.byKey(const Key('broadcast-save')));
    await tester.pumpAndSettle();
    expect(api.saved?['title'], 'Ogeysiis muhiim ah');
    expect(api.saved?['channels'], ['push', 'telegram']);
  });

  testWidgets('Test push: one customer by phone; says if the customer has no device; an unknown number is explained; the preview shows the title', (tester) async {
    final api = await _pump(tester, const BroadcastFormScreen());
    await tester.enterText(find.byKey(const Key('broadcast-title')), 'Salaan');
    await tester.enterText(find.byKey(const Key('broadcast-message')), 'Mahadsanid');
    await tester.ensureVisible(find.byKey(const Key('broadcast-test-push-button')));
    await tester.tap(find.byKey(const Key('broadcast-test-push-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('broadcast-error')), findsOneWidget, reason: 'a phone number is needed');
    expect(api.calls.where((c) => c.startsWith('push')), isEmpty);

    await tester.enterText(find.byKey(const Key('broadcast-test-phone')), '252610000003');
    await tester.tap(find.byKey(const Key('broadcast-test-push-button')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('push Salaan|Mahadsanid|252610000003'));
    expect(find.text('Test notification queued: it arrives within a minute.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));

    api.deviceRegistered = false;
    await tester.tap(find.byKey(const Key('broadcast-test-push-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('has no device registered'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));

    await tester.enterText(find.byKey(const Key('broadcast-test-phone')), '252699999999');
    await tester.tap(find.byKey(const Key('broadcast-test-push-button')));
    await tester.pumpAndSettle();
    expect(find.text('No Customer App customer has this phone number'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('broadcast-preview-button')));
    await tester.tap(find.byKey(const Key('broadcast-preview-button')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('broadcast-preview-title'))).data, 'Salaan');
    expect(find.byKey(const Key('broadcast-test-button')), findsNothing, reason: 'the Telegram test is only for Telegram');
  });
}
