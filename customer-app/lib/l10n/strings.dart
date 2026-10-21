import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's language: English or Somali. Chosen in Profile and remembered
/// on the device; until then it follows the phone's language.
class AppLanguage {
  AppLanguage._();

  static const String english = 'en';
  static const String somali = 'so';
  static const String _prefsKey = 'app_language';

  /// The whole app rebuilds when this changes (see main.dart).
  static final ValueNotifier<String> current = ValueNotifier(english);

  static bool get isSomali => current.value == somali;

  static Future<void> load() async {
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_prefsKey);
    } catch (_) {}
    current.value = saved ?? (PlatformDispatcher.instance.locale.languageCode == somali ? somali : english);
  }

  static Future<void> set(String code) async {
    current.value = code == somali ? somali : english;
    try {
      await (await SharedPreferences.getInstance()).setString(_prefsKey, current.value);
    } catch (_) {}
  }
}

String _t(String en, String so) => AppLanguage.isSomali ? so : en;

/// Flat customer-facing string table, in English and Somali.
///
/// Every screen reads through `AppStrings.*`, so switching
/// [AppLanguage.current] changes the whole app.
class AppStrings {
  AppStrings._();

  static const String appName = 'BAARI';

  // Language
  static String get language => _t('Language', 'Luqadda');
  static const String englishName = 'English';
  static const String somaliName = 'Soomaali';

  // Auth
  static String get login => _t('Log In', 'Gal');
  static String get register => _t('Create Account', 'Samee Akoon');
  static String get phoneNumber => _t('Phone Number', 'Lambarka Taleefanka');
  static String get password => _t('Password', 'Erayga Sirta');
  static String get fullName => _t('Full Name', 'Magaca oo Dhammaystiran');
  static String get confirmPassword => _t('Confirm Password', 'Xaqiiji Erayga Sirta');
  static String get noAccount => _t("Don't have an account?", 'Akoon ma lihid?');
  static String get haveAccount => _t('Already have an account?', 'Horay akoon ma u lahayd?');
  static String get logout => _t('Log Out', 'Ka Bax');
  static String get logoutConfirm => _t('Are you sure you want to log out?', 'Ma hubtaa inaad ka baxayso?');
  static String get cancel => _t('Cancel', 'Jooji');

  // Home
  static String get home => _t('Home', 'Hoyga');
  static String get availableBalance => _t('Available Balance', 'Haraaga la Isticmaali Karo');
  static String get deposit => _t('Deposit', 'Dhigasho');
  static String get withdraw => _t('Withdraw', 'Bixin');
  static const String xiran = 'Xiran';
  static String get bonus => _t('Bonus', 'Gunno');
  static String get recentOrders => _t('Recent Orders', 'Dalabyadii u Dambeeyay');
  static String get viewAll => _t('View all', 'Dhammaan');

  // Method picker
  static String get chooseMethod => _t('Choose a method', 'Dooro hab');
  static String get chooseDepositMethod => _t('Choose a deposit method', 'Dooro habka dhigashada');
  static String get chooseWithdrawMethod => _t('Choose a withdrawal method', 'Dooro habka bixinta');
  static String get noMethods =>
      _t('No payment methods are available right now.', 'Hadda ma jiraan habab lacag-bixin oo diyaar ah.');
  static String get methodsLoadFailed =>
      _t('Could not load payment methods.', 'Hababka lacag-bixinta lama soo rari karin.');
  static String get close => _t('Close', 'Xir');
  static String get mobileMoney => _t('Mobile money', 'Lacagta moobilka');
  static String get bettingPlatforms => _t('Betting platforms', 'Goobaha sharadka');
  static String get sendPaymentTo => _t('Send your payment to', 'Lacagta u dir');
  static String get notifications => _t('Notifications', 'Ogeysiisyo');
  static String get noNotifications => _t('No notifications yet', 'Weli ogeysiis ma jiro');
  static const String evcPlus = 'EVC Plus';
  static const String winwin = 'WinWin';

  // Deposit / withdraw shared
  static String get amount => _t('Amount (USD)', 'Lacagta (USD)');
  static String get continueLabel => _t('Continue', 'Sii wad');
  static String get confirm => _t('Confirm', 'Xaqiiji');
  static String get rate => _t('Rate', 'Sarifka');
  static String get fee => _t('Fee', 'Khidmadda');
  static String get netAmount => _t('You will receive', 'Waxaad helaysaa');
  static String get youReceive => _t('You receive', 'Waxaad helaysaa');
  static String get totalDeducted => _t('Total Deducted', 'Wadarta laga jarayo');
  static String get processing => _t('Processing...', 'Waa la shaqeynayaa...');
  static String get pleaseWait =>
      _t('Please wait while we submit your request.', 'Fadlan sug inta codsigaaga la gudbinayo.');
  static String get depositCodeLabel => _t('Deposit Code', 'Koodhka Dhigashada');
  static String get depositCodeHelp =>
      _t('Use this code as the payment reference.', 'Koodhkan u isticmaal tixraaca lacag-bixinta.');
  static String get done => _t('Done', 'Dhammee');
  static String get tryAgain => _t('Try Again', 'Isku day mar kale');
  static String get back => _t('Back', 'Dib u noqo');
  static String get somethingWentWrong =>
      _t('Something went wrong. Please try again.', 'Wax baa khaldamay. Fadlan isku day mar kale.');
  static String get couldNotComplete => _t('We could not complete this', 'Tan lama dhammaystiri karin');
  static String get accountId => _t('Account ID', 'Aqoonsiga Akoonka');
  static String get enterAccountId => _t('Enter your account ID', 'Geli aqoonsiga akoonkaaga');
  static String get enterPhone => _t('Enter a phone number', 'Geli lambar taleefan');
  static String get enterValidAmount => _t('Enter a valid amount', 'Geli lacag sax ah');
  static String identifierLabel(String method, bool isPlatform) => isPlatform
      ? _t('$method Account ID', 'Aqoonsiga Akoonka $method')
      : _t('$method Phone Number', 'Lambarka Taleefanka $method');
  static String identifierHint(bool isPlatform) =>
      isPlatform ? _t('e.g. 7841228', 'tusaale 7841228') : _t('e.g. 2526XXXXXXX', 'tusaale 2526XXXXXXX');
  static String get orderCode => _t('Order Code', 'Koodhka Dalabka');
  static String get status => _t('Status', 'Xaaladda');

  // Deposit
  static String get completeDeposit => _t('Complete Deposit', 'Dhammaystir Dhigashada');
  static String get change => _t('Change', 'Beddel');
  static String get instantMobileTransfer => _t('Instant Mobile Transfer', 'Lacag-dirid degdeg ah');
  static String get bettingAccount => _t('Betting account', 'Akoonka sharadka');
  static String get amountShort => _t('Amount', 'Lacagta');
  static String get sendMoneyToAccount => _t('Send the money to this account', 'Lacagta ku dir koontadaan');
  static String get dial => _t('Dial', 'Garaac');
  static String get copy => _t('Copy', 'Koobiyee');
  static String copied(String text) => _t('$text copied', '$text waa la koobiyeeyay');
  static String get enterNineDigits => _t('Enter the 9-digit number', 'Geli lambarka 9-ka god ah');
  static String get useAnotherNumber => _t('Use another number', 'Isticmaal lambar kale');
  static String get depositDetails => _t('Deposit details', 'Faahfaahinta dhigashada');
  static String get confirmDeposit => _t('Confirm Deposit', 'Xaqiiji Dhigashada');
  static String get depositSubmitted => _t('Deposit Submitted', 'Dhigashada waa la gudbiyay');
  static String depositPlatformHint(String method) => _t(
        'Enter your $method account ID and the amount to deposit.',
        'Geli aqoonsiga akoonkaaga $method iyo lacagta aad dhigayso.',
      );
  static String depositPhoneHint(String method) =>
      _t('Enter the $method number you will pay from.', 'Geli lambarka $method ee aad lacagta ka soo diraysid.');
  static String depositCodeFlowHint(String method) => _t(
        'In $method, withdraw to the Badal cash desk and copy the code you get. '
            'Then enter your account ID, the amount and that code. Your wallet is credited '
            'with the amount $method pays out.',
        'Gudaha $method, lacag u bixi khasnadda Badal oo koobiyee koodhka lagu siiyo. '
            'Kadib geli aqoonsiga akoonkaaga, lacagta iyo koodhkaas. Boorsadaada waxaa lagu '
            'shubayaa lacagta $method bixiso.',
      );
  static String withdrawalCodeLabel(String method) =>
      _t('$method withdrawal code', 'Koodhka bixinta $method');
  static String withdrawalCodeHint(String method) => _t('Code from $method', 'Koodhka $method');
  static String get withdrawalCode => _t('Withdrawal code', 'Koodhka bixinta');
  static String get enterWithdrawalCode => _t('Enter the withdrawal code', 'Geli koodhka bixinta');
  static String get enterCodeExactly => _t('Enter the code exactly as shown', 'Geli koodhka sida uu yahay');
  static String depositCodeUse(String method) => _t(
        'Use this code as the reference when you pay via $method.',
        'Koodhkan u isticmaal tixraac markaad ku bixinayso $method.',
      );

  // Withdraw
  static String get withdrawalDetails => _t('Withdrawal details', 'Faahfaahinta bixinta');
  static String get confirmWithdrawal => _t('Confirm Withdrawal', 'Xaqiiji Bixinta');
  static String get withdrawalSubmitted => _t('Withdrawal Submitted', 'Bixinta waa la gudbiyay');
  static String get sendTo => _t('Send to', 'Loo dirayo');
  static String withdrawPlatformHint(String method) => _t(
        'Enter your $method account ID and the amount to withdraw.',
        'Geli aqoonsiga akoonkaaga $method iyo lacagta aad bixinayso.',
      );
  static String withdrawPhoneHint(String method) =>
      _t('Enter the $method number to receive your withdrawal.', 'Geli lambarka $method ee lacagta lagu soo dirayo.');

  // Orders
  static String get orders => _t('Orders', 'Dalabyada');
  static String get noOrders => _t('No transactions yet', 'Weli dhaqdhaqaaq ma jiro');
  static String get noOrdersHint => _t(
        'Your deposits and withdrawals will show up here.',
        'Dhigashooyinkaaga iyo bixintaada halkan ayay ka muuqan doonaan.',
      );
  static String get orderDetails => _t('Order Details', 'Faahfaahinta Dalabka');
  static String get method => _t('Method', 'Habka');
  static String get transactionRef => _t('Transaction Reference', 'Tixraaca Dhaqdhaqaaqa');
  static String get createdAt => _t('Created', 'La sameeyay');
  static String get completedAt => _t('Completed', 'La dhammeeyay');

  // Profile
  static String get profile => _t('Profile', 'Xogtayda');
  static String get name => _t('Name', 'Magaca');
}
