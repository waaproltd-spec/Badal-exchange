import 'package:badal_exchange_customer/api/api_client.dart';
import 'package:badal_exchange_customer/api/api_exception.dart';
import 'package:badal_exchange_customer/api/customer_api.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:badal_exchange_customer/screens/profile/profile_screen.dart';
import 'package:badal_exchange_customer/state/auth_provider.dart';
import 'package:badal_exchange_customer/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends CustomerApi {
  _FakeApi() : super(ApiClient());

  String password = 'old-pass-123';
  final changes = <(String, String)>[];

  @override
  Future<void> changePassword({required String currentPassword, required String newPassword}) async {
    changes.add((currentPassword, newPassword));
    if (currentPassword != password) {
      throw const ApiException(status: 400, code: 'INVALID_PASSWORD', message: 'Current password is incorrect');
    }
    password = newPassword;
  }
}

late _FakeApi _api;

Widget _app() {
  _api = _FakeApi();
  final auth = AuthProvider(apiClient: ApiClient(), customerApi: _api);
  return MultiProvider(
    providers: [
      Provider<CustomerApi>.value(value: _api),
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
    ],
    child: MaterialApp(theme: AppTheme.current, home: const ProfileScreen()),
  );
}

Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(_app());
  await tester.scrollUntilVisible(find.byKey(const Key('change-password')), 200);
  await tester.tap(find.byKey(const Key('change-password')));
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester, String current, String next, String confirm) async {
  await tester.enterText(find.descendant(of: find.byKey(const Key('current-password')), matching: find.byType(TextField)), current);
  await tester.enterText(find.descendant(of: find.byKey(const Key('new-password')), matching: find.byType(TextField)), next);
  await tester.enterText(find.descendant(of: find.byKey(const Key('confirm-password')), matching: find.byType(TextField)), confirm);
  await tester.tap(find.byKey(const Key('save-password')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Profile opens Change Password; the form checks before sending', (tester) async {
    await _open(tester);
    expect(find.byKey(const Key('current-password')), findsOneWidget);

    await _fill(tester, 'old-pass-123', 'short', 'short');
    expect(find.text(AppStrings.passwordTooShort), findsOneWidget);
    await _fill(tester, 'old-pass-123', 'new-pass-456', 'new-pass-789');
    expect(find.text(AppStrings.passwordsDontMatch), findsOneWidget);
    await _fill(tester, 'old-pass-123', 'old-pass-123', 'old-pass-123');
    expect(find.text(AppStrings.newPasswordSame), findsOneWidget);
    expect(_api.changes, isEmpty, reason: 'nothing sent until the form is right');
  });

  testWidgets('a wrong current password is shown; the right one changes it and goes back', (tester) async {
    await _open(tester);
    await _fill(tester, 'not-my-pass', 'new-pass-456', 'new-pass-456');
    expect(find.byKey(const Key('change-password-error')), findsOneWidget);
    expect(find.text(AppStrings.wrongCurrentPassword), findsOneWidget);
    expect(_api.password, 'old-pass-123');

    await _fill(tester, 'old-pass-123', 'new-pass-456', 'new-pass-456');
    expect(_api.password, 'new-pass-456');
    expect(find.text(AppStrings.passwordChanged), findsOneWidget);
    expect(find.byKey(const Key('change-password')), findsOneWidget, reason: 'back on Profile');
  });
}
