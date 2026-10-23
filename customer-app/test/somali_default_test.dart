import 'package:badal_exchange_customer/l10n/server_text.dart';
import 'package:badal_exchange_customer/l10n/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => AppLanguage.current.value = AppLanguage.somali);

  test('Somali is the default; English only when the customer chose it', () async {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.current.value = AppLanguage.english;
    await AppLanguage.load();
    expect(AppLanguage.current.value, AppLanguage.somali);
    expect(AppStrings.login, 'Gal');

    SharedPreferences.setMockInitialValues({'app_language': 'en'});
    await AppLanguage.load();
    expect(AppLanguage.current.value, AppLanguage.english);
    expect(AppStrings.login, 'Log In');
  });

  test('server messages a customer sees are shown in Somali', () {
    AppLanguage.current.value = AppLanguage.somali;
    expect(serverText('Insufficient wallet balance', code: 'INSUFFICIENT_BALANCE'), 'Haraaga boorsadaadu kuma filna.');
    expect(serverText('Minimum withdrawal is 2', code: 'BELOW_MIN_WITHDRAWAL'), 'Lacag-bixinta ugu yar waa \$2.');
    expect(serverText('Maximum withdrawal is 500.00', code: 'ABOVE_MAX_WITHDRAWAL'), 'Lacag-bixinta ugu badan waa \$500.00.');
    expect(serverText('WinWin account 555555 was not found'), 'Akoonka 555555 lama helin.');
    expect(serverText('Not paid within 30 minutes'), 'Lacag lama bixin 30 daqiiqo gudahood.');
    expect(serverText('Transaction failed. Your balance was not charged.'), 'Dalabku wuu fashilmay. Lacag lagaama jarin.');
    // A note an agent typed stays as written.
    expect(serverText('Lacagta waa lagu celiyay'), 'Lacagta waa lagu celiyay');
  });

  test('in English the server text is unchanged', () {
    AppLanguage.current.value = AppLanguage.english;
    expect(serverText('Minimum withdrawal is 2', code: 'BELOW_MIN_WITHDRAWAL'), 'Minimum withdrawal is 2');
  });
}
