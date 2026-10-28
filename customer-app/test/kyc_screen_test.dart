import 'dart:typed_data';

import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/models/kyc.dart';
import 'package:badal_exchange_customer/screens/profile/kyc_screen.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeApi extends CustomerApi {
  _FakeApi(this.status) : super(ApiClient());

  KycStatus status;
  Map<String, Object?>? submitted;
  ApiException? fail;

  @override
  Future<KycStatus> getKycStatus() async => status;

  @override
  Future<KycStatus> submitKyc({
    required String documentType,
    required String fullName,
    required String documentNumber,
    required String country,
    required String dateOfBirth,
    required String expiryDate,
    required List<int> front,
    List<int>? back,
    required List<int> selfie,
  }) async {
    if (fail != null) throw fail!;
    submitted = {
      'type': documentType, 'name': fullName, 'number': documentNumber, 'country': country,
      'dob': dateOfBirth, 'expiry': expiryDate, 'front': front.length, 'back': back?.length, 'selfie': selfie.length,
    };
    return status = KycStatus.fromJson({'status': 'pending_review', 'canSubmit': false, 'submittedAt': '2026-10-28T14:20:00Z',
      'autoCheckedAt': '2026-10-28T14:20:01Z'});
  }
}

Future<Uint8List?> _fakePhoto(BuildContext context, {required bool selfie}) async => Uint8List.fromList(List.filled(selfie ? 7 : 9, 1));

Future<_FakeApi> _pump(WidgetTester tester, KycStatus status) async {
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final api = _FakeApi(status);
  await tester.pumpWidget(Provider<CustomerApi>.value(
      value: api, child: MaterialApp(theme: AppTheme.current, home: KycScreen(key: UniqueKey(), pickPhoto: _fakePhoto))));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppLanguage.current.value = AppLanguage.english);

  testWidgets('not submitted: document, details, photos, selfie, review, submit -> Pending Admin Review', (tester) async {
    final api = await _pump(tester, KycStatus.fromJson({'status': 'not_submitted', 'canSubmit': true}));
    expect(find.text('Start Verification'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('kyc-start')));
    await _tap(tester, find.byKey(const Key('kyc-type-national_id')));
    await _tap(tester, find.byKey(const Key('kyc-type-continue')));

    final next = find.byKey(const Key('kyc-details-continue'));
    await tester.enterText(find.byKey(const Key('kyc-name')), 'Yasin Mohamed Adan');
    await tester.enterText(find.byKey(const Key('kyc-number')), 'nid789456');
    await _tap(tester, find.byKey(const Key('kyc-dob')));
    await _tap(tester, find.text('OK'));
    await _tap(tester, find.byKey(const Key('kyc-expiry')));
    await _tap(tester, find.text('OK'));
    await _tap(tester, find.byKey(const Key('kyc-photo-front')));
    expect(tester.widget<ElevatedButton>(find.descendant(of: next, matching: find.byType(ElevatedButton))).onPressed, isNull,
        reason: 'a national ID needs its back too');
    await _tap(tester, find.byKey(const Key('kyc-photo-back')));
    await _tap(tester, next);

    expect(tester.widget<ElevatedButton>(
        find.descendant(of: find.byKey(const Key('kyc-selfie-continue')), matching: find.byType(ElevatedButton))).onPressed, isNull);
    await _tap(tester, find.byKey(const Key('kyc-photo-selfie')));
    await _tap(tester, find.byKey(const Key('kyc-selfie-continue')));

    expect(find.text('Review & Submit'), findsOneWidget);
    expect(find.text('NID789456'), findsOneWidget);
    expect(find.text('Somalia'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('kyc-submit')));
    expect(api.submitted!['type'], 'national_id');
    expect(api.submitted!['name'], 'Yasin Mohamed Adan');
    expect(api.submitted!['country'], 'SO');
    expect([api.submitted!['front'], api.submitted!['back'], api.submitted!['selfie']], [9, 9, 7]);
    expect(api.submitted!['dob'], matches(RegExp(r'^\d{4}-\d\d-\d\d$')));
    expect(find.byKey(const Key('kyc-status-pending_review')), findsOneWidget);
    expect(find.text('Pending Admin Review'), findsOneWidget);
  });

  testWidgets('approved, rejected with the reason (submit again), resubmission', (tester) async {
    await _pump(tester, KycStatus.fromJson({'status': 'approved', 'canSubmit': false, 'decidedAt': '2026-10-28T14:25:00Z'}));
    expect(find.text('KYC Approved'), findsOneWidget);
    expect(find.byKey(const Key('kyc-resubmit')), findsNothing);

    await _pump(tester, KycStatus.fromJson({'status': 'rejected', 'canSubmit': true, 'reason': 'Document does not match the person'}));
    expect(find.text('KYC Rejected'), findsOneWidget);
    expect(find.text('Document does not match the person'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('kyc-resubmit')));
    expect(find.text('Select Document Type'), findsOneWidget);

    await _pump(tester, KycStatus.fromJson({'status': 'resubmission_required', 'canSubmit': true, 'reason': 'Photo is blurred'}));
    expect(find.text('Resubmission Required'), findsOneWidget);
    expect(find.text('Photo is blurred'), findsOneWidget);
  });
}
