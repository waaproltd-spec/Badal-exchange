import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/kyc.dart';
import 'package:badal_agent_app/screens/admin/kyc_screens.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

class _FakeApi extends AgentApi {
  String status = 'pending_review';
  final calls = <String>[];

  Map<String, dynamic> get _row => {
        'id': 'k1', 'customerId': 'c1', 'customerName': 'Ahmed Ali', 'phone': '252611234567', 'documentType': 'passport',
        'documentNumber': 'P1234567', 'fullName': 'Ahmed Ali', 'country': 'SO', 'status': status,
        'submittedAt': '2026-10-28T14:20:00Z', 'failedChecks': 1,
      };

  @override
  Future<({List<KycListItem> items, Map<String, int> counts, String provider})> getKycApplications(
      {String status = 'pending_review', String? query}) async {
    calls.add('list $status ${query ?? ''}');
    return (items: [KycListItem.fromJson(_row)], counts: {'pending_review': 8, 'approved': 1245}, provider: 'none');
  }

  @override
  Future<KycApplication> getKycApplication(String id) async => KycApplication.fromJson({
        ..._row,
        'dateOfBirth': '1995-03-01', 'expiryDate': '2030-01-01',
        'checks': [
          {'key': 'document_number', 'ok': true, 'detail': '6 to 9 letters or digits'},
          {'key': 'image_selfie', 'ok': false, 'detail': 'png 300x300, 15 KB (at least 400x400 and 20 KB to be readable)'},
        ],
        'provider': 'none', 'reviewReason': 'Some checks did not pass',
        'decidedAt': status == 'pending_review' ? null : '2026-10-28T14:30:00Z',
        'decidedBy': status == 'pending_review' ? null : 'Demo Agent',
        'decisionReason': status == 'pending_review' ? null : 'Selfie unclear',
        'documents': {'front': {'mime': 'image/png', 'data': _png}, 'selfie': {'mime': 'image/png', 'data': _png}},
        'history': [],
      });

  @override
  Future<void> decideKyc(String id, String decision, String reason) async {
    calls.add('$decision $id $reason');
    status = {'approve': 'approved', 'reject': 'rejected', 'resubmit': 'resubmission_required'}[decision]!;
  }
}

Future<_FakeApi> _pump(WidgetTester tester, Widget home) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 5000);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final api = _FakeApi();
  await tester.pumpWidget(ChangeNotifierProvider(create: (_) => Session(api: api), child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('the list: counts per status, the row, the search', (tester) async {
    final api = await _pump(tester, const KycManagementScreen());
    expect(find.text('Pending Admin Review (8)'), findsOneWidget);
    expect(find.text('Approved (1245)'), findsOneWidget);
    expect(find.text('Ahmed Ali'), findsOneWidget);
    expect(find.textContaining('P1234567'), findsOneWidget);
    expect(find.text('1 check(s) failed'), findsOneWidget);
    expect(find.textContaining('No identity-verification service'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'P123');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(api.calls.last, 'list pending_review P123');
  });

  testWidgets('review: documents, information, checks; request resubmission with a reason', (tester) async {
    final api = await _pump(tester, const KycReviewScreen(id: 'k1'));
    expect(find.byKey(const Key('kyc-doc-front')), findsOneWidget);
    expect(find.byKey(const Key('kyc-doc-selfie')), findsOneWidget);
    expect(find.text('P1234567'), findsOneWidget);
    expect(find.text('Some checks did not pass'), findsOneWidget);
    expect(find.textContaining('at least 400x400'), findsOneWidget);
    await tester.tap(find.byKey(const Key('kyc-resubmit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('kyc-reason')), 'Selfie unclear');
    await tester.tap(find.byKey(const Key('kyc-confirm')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('resubmit k1 Selfie unclear'));
    expect(find.text('Resubmission Required'), findsOneWidget);
    expect(find.text('Demo Agent'), findsOneWidget);
    expect(find.byKey(const Key('kyc-approve')), findsNothing, reason: 'decided: no more buttons');
  });
}
