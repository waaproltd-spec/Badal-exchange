import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's language: Somali (the default) or English. Chosen in Profile
/// and remembered on the device.
class AppLanguage {
  AppLanguage._();

  static const String english = 'en';
  static const String somali = 'so';
  static const String _prefsKey = 'app_language';

  /// The whole app rebuilds when this changes (see main.dart).
  static final ValueNotifier<String> current = ValueNotifier(somali);

  static bool get isSomali => current.value == somali;

  static Future<void> load() async {
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_prefsKey);
    } catch (_) {}
    current.value = saved == english ? english : somali;
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

  static const String appName = 'BADAL EXCHANGE';

  // Language
  static String get language => _t('Language', 'Luqadda');
  static const String englishName = 'English';
  static const String somaliName = 'Soomaali';
  static String get appearance => _t('Appearance', 'Muuqaalka');
  static String get themeLight => _t('Light', 'Iftiin');
  static String get themeDark => _t('Dark', 'Mugdi');
  static String get themeSystem => _t('Phone', 'Taleefanka');

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
  static String get createYourAccount => _t('Create your account', 'Samee akoonkaaga');
  static String get registerSubtitle =>
      _t('Your wallet, made simple with Badal Exchange', 'Boorsadaada, oo Badal Exchange u fududeeyay');
  static String get fullNameHint => _t('Enter your full name', 'Geli magacaaga oo buuxa');
  static String get phoneDigitsHint => _t('9 digits number', 'Lambar 9 god ah');
  static String get passwordHint => _t('At least 8 characters', 'Ugu yaraan 8 xaraf');
  static String get confirmPasswordHint => _t('Re-enter your password', 'Mar kale geli erayga sirta');
  static String get enterFullName => _t('Enter your full name', 'Geli magacaaga oo buuxa');
  static String get phonePrefixes => _t(
      'Phone number must start with 61 or 77 (EVC Plus), 90 (Golis), 63 (ZAAD) or 62 (eDahab)',
      'Lambarka taleefanku waa inuu ku bilowdaa 61 ama 77 (EVC Plus), 90 (Golis), 63 (ZAAD) ama 62 (eDahab)');
  static String get enterPhone9 => _t('Enter the 9 digits after +252', 'Geli 9-ka god ee ka dambeeya +252');
  static String get passwordTooShort =>
      _t('Password must be at least 8 characters', 'Erayga sirtu waa inuu ahaadaa ugu yaraan 8 xaraf');
  static String get changePassword => _t('Change Password', 'Beddel Erayga Sirta');
  static String get currentPassword => _t('Current Password', 'Erayga Sirta Hadda');
  static String get currentPasswordHint => _t('The password you log in with', 'Erayga aad hadda ku gasho');
  static String get newPassword => _t('New Password', 'Erayga Sirta Cusub');
  static String get wrongCurrentPassword =>
      _t('The current password is wrong.', 'Erayga sirta ee hadda waa khalad.');
  static String get newPasswordSame =>
      _t('Choose a password different from the current one.', 'Dooro eray sir ah oo ka duwan kan hadda.');
  static String get passwordChanged =>
      _t('Your password was changed.', 'Erayga sirta waa la beddelay.');
  static String get passwordsDontMatch => _t('Passwords do not match', 'Erayada sirta isma laha');
  static String get accountCreated =>
      _t('Account created. Welcome to Badal Exchange!', 'Akoonka waa la sameeyay. Ku soo dhawoow Badal Exchange!');
  static String get or => _t('OR', 'AMA');
  static String get welcomeBack => _t('Welcome back', 'Ku soo dhawoow mar kale');
  static String get loginSubtitle => _t('Log in to your Badal Exchange wallet', 'Gal boorsadaada Badal Exchange');
  static String get enterPassword => _t('Enter your password', 'Geli erayga sirta');
  static String get rememberMe => _t('Remember me', 'I xasuuso');
  static String get forgotPassword => _t('Forgot password?', 'Erayga sirta ma ilowday?');
  static String get forgotPasswordTitle => _t('Forgot your password?', 'Erayga sirta ma ilowday?');
  static String get forgotPasswordBody => _t(
        'Contact Badal Exchange support from your registered number. They will check your account and set a new password for you.',
        'La xiriir taageerada Badal Exchange adigoo isticmaalaya lambarkaaga diiwaangashan. Waxay hubin doonaan akoonkaaga oo kuu samayn doonaan eray sir ah oo cusub.',
      );
  static String get noSupportContacts =>
      _t('Support contacts are not available right now. Please try again later.', 'Xiriirka taageerada hadda lama heli karo. Fadlan isku day mar dambe.');
  static String get support => _t('Support', 'Caawimaad');
  static String get viewDetails => _t('View', 'Fiiri');
  static String get supportTitle => _t('Contact Badal Exchange support', 'La xiriir taageerada Badal Exchange');
  static String get supportNotSetUp => _t('Support chat is not set up yet. Please try again later.',
      'Wada-hadalka taageerada weli lama diyaarin. Fadlan isku day mar dambe.');
  static String couldNotOpen(String app, String link) =>
      _t('Could not open $app. Contact us at $link', 'Lama furi karo $app. Nagala soo xiriir $link');
  static String get openedOnAnotherPhone => _t('This account was opened on another phone. Log in again to use it here.',
      'Akoonkan taleefan kale ayaa laga galay. Dib u gal si aad halkan uga isticmaasho.');
  static String get invalidLogin =>
      _t('Wrong phone number or password.', 'Lambarka taleefanka ama erayga sirta waa khalad.');
  static String get showPassword => _t('Show password', 'Muuji erayga sirta');
  static String get hidePassword => _t('Hide password', 'Qari erayga sirta');

  // Home
  static String get home => _t('Home', 'Hoyga');
  static String get availableBalance => _t('Available Balance', 'Haraaga la Isticmaali Karo');
  static String get deposit => _t('Deposit', 'Dhigasho');
  static String get withdraw => _t('Withdraw', 'Bixin');
  static String get bonus => _t('Bonus', 'Gunno');
  static String get promoCode => _t('Promo Code', 'Koodhka Dallacsiinta');
  static String get walletId => _t('Wallet ID', 'Aqoonsiga Boorsada');
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
  static String get withdrawAll => _t('Withdraw all', 'Qaado dhammaan');
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
  static String get networkError => _t('Could not reach the server. Check your internet connection and try again.',
      'Server-ka lama gaarin. Hubi internet-kaaga, kadibna mar kale isku day.');
  static String get couldNotLoadOrders => _t('Could not load your orders. Check your connection and try again.',
      'Dalabaadkaaga lama soo gelin. Hubi internet-kaaga, kadibna mar kale isku day.');
  static String get couldNotLoadWallet => _t('Could not load your wallet. Check your connection and try again.',
      'Boorsadaada lama soo gelin. Hubi internet-kaaga, kadibna mar kale isku day.');
  static String get couldNotLoadNotifications =>
      _t('Could not load notifications.', 'Ogeysiisyada lama soo gelin.');
  static String get couldNotOpenLink => _t('Could not open the link.', 'Linkiga lama furi karo.');
  static String get learnMore => _t('Learn more ›', 'Wax badan ka ogow ›');
  static String get statusFailed => _t('Failed', 'Wuu fashilmay');
  static String get statusCancelled => _t('Cancelled', 'Waa la joojiyay');
  static String get statusExpired => _t('Expired', 'Waqtigii wuu dhacay');
  static String get somethingWentWrong =>
      _t('Something went wrong. Please try again.', 'Wax baa khaldamay. Fadlan isku day mar kale.');
  static String get couldNotComplete => _t('We could not complete this', 'Tan lama dhammaystiri karin');
  static String get accountId => _t('Account ID', 'Aqoonsiga Akoonka');
  static String get enterAccountId => _t('Enter your account ID', 'Geli aqoonsiga akoonkaaga');
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
  static String get bettingCashierDeposit => _t('Betting cashier deposit', 'Dhigasho khasnadda sharadka');
  static String get street => _t('Street', 'Waddada');
  static String get city => _t('City', 'Magaalada');
  static String get paymentLocation => _t('Payment Location', 'Goobta Lacag-bixinta');
  static String get paymentLocationHint => _t('Use this address if required.', 'Isticmaal cinwaankan haddii loo baahdo.');
  static String get paymentCode => _t('Payment code', 'Koodhka lacag-bixinta');
  static String get enterPaymentCode => _t('Enter payment code', 'Geli koodhka lacag-bixinta');
  static String get amountPending => _t('Amount pending', 'Lacagta waa la sugayaa');
  static String get amountShort => _t('Amount', 'Lacagta');
  static String get sendMoneyToAccount => _t('Send the money to this account', 'Lacagta ku dir koontadaan');
  static String get dial => _t('Dial', 'Garaac');
  static String get copy => _t('Copy', 'Koobiyee');
  static String copied(String text) => _t('$text copied', '$text waa la koobiyeeyay');
  static String get payFromOwnNumber => _t('Pay from your registered number', 'Ka dir lambarkaaga diiwaangashan');
  static String get receiveToOwnNumber => _t('Paid to your registered number', 'Waxaa lagu soo dirayaa lambarkaaga diiwaangashan');
  static String get noRegisteredNumber =>
      _t('Your registered number could not be read. Log out and in again.', 'Lambarkaaga diiwaangashan lama heli karo. Ka bax oo mar kale gal.');
  static String get depositDetails => _t('Deposit details', 'Faahfaahinta dhigashada');
  static String get confirmDeposit => _t('Confirm Deposit', 'Xaqiiji Dhigashada');
  static String get depositSubmitted => _t('Deposit Submitted', 'Dhigashada waa la gudbiyay');
  static String depositPlatformHint(String method) => _t(
        'Enter your $method account ID and the amount to deposit.',
        'Geli aqoonsiga akoonkaaga $method iyo lacagta aad dhigayso.',
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
  static String get playerIdFind => _t('Player ID: Find a Player', 'Aqoonsiga Ciyaaryahanka: Raadi Ciyaaryahan');
  static String get playerName => _t('Player Name', 'Magaca Ciyaaryahanka');
  static String get checkingPlayer => _t('Checking...', 'Waa la hubinayaa...');
  static String playerNameUnavailable(String platform) =>
      _t('Not provided by $platform', '$platform ma bixin');
  static String playerNotFound(String platform, String id) => _t(
      'No $platform player has the ID $id. Go back and check the Player ID.',
      'Ciyaaryahan $platform ah oo aqoonsigiisu yahay $id lama helin. Dib u noqo oo hubi aqoonsiga.');
  static String get playerNotFoundShort => _t('Player not found', 'Ciyaaryahanka lama helin');
  static String get playerCheckFailed =>
      _t('Could not check the player right now.', 'Hadda lama hubin karo ciyaaryahanka.');
  static String withdrawPlatformHint(String method) => _t(
        'Enter your $method account ID and the amount to withdraw.',
        'Geli aqoonsiga akoonkaaga $method iyo lacagta aad bixinayso.',
      );
  static String withdrawPhoneHint(String method) => _t(
        'Enter the amount. It is sent to your registered $method number.',
        'Geli lacagta. Waxaa loo dirayaa lambarkaaga $method ee diiwaangashan.',
      );

  // Transaction screens
  static String get transactionDetails => _t('Transaction Details', 'Faahfaahinta Dhaqdhaqaaqa');
  static String get transactionId => _t('Transaction ID', 'Aqoonsiga Dhaqdhaqaaqa');
  static String get type => _t('Type', 'Nooca');
  static String get account => _t('Account', 'Akoonka');
  static String get balanceBefore => _t('Balance Before', 'Haraaga Ka Hor');
  static String get balanceAfter => _t('Balance After', 'Haraaga Kadib');
  static String get dateTime => _t('Date & Time', 'Taariikhda & Waqtiga');
  static String get backToHome => _t('Back to Home', 'Ku noqo Hoyga');
  static String get usdDeposited => _t('USD Deposited', 'USD la dhigay');
  static String get usdWithdrawn => _t('USD Withdrawn', 'USD la bixiyay');
  static String get depositConfirmed => _t('Deposit Confirmed', 'Dhigashada waa la xaqiijiyay');
  static String get withdrawalConfirmed => _t('Withdrawal Confirmed', 'Bixinta waa la xaqiijiyay');
  /// What a customer sees while the server is still confirming: never "Pending".
  static String get verifying => _t('Your payment is being verified…', 'Lacag-bixintaada waa la hubinayaa…');
  static String get verifyingTitle => _t('Verifying...', 'Xaqiijinayaa...');
  static String get verifyStepReceived => _t('Request received', 'Codsiga waa la helay');
  static String get verifyStepChecking => _t('Verifying your payment', 'Xaqiijinta lacag-bixintaada');
  static String get verifyStepCrediting => _t('Adding it to your balance', 'Lacagta waa lagu darayaa haraagaaga');
  static String get statusCompleted => _t('Completed', 'Waa dhammaaday');
  static String get confirmingOrder => _t('Confirming Order...', 'Dalabka waa la xaqiijinayaa...');
  static String get confirmingWithdrawal => _t('Confirming Withdrawal...', 'Bixinta waa la xaqiijinayaa...');
  static String get hangTightDeposit =>
      _t("Hang tight, we're processing your deposit", 'Fadlan sug, dhigashadaada waa la shaqeynayaa');
  // Why a withdrawal still waits after 30 seconds (Order.delay).
  static String get delayTitle => _t('Why is it taking longer?', 'Maxay u daahday?');
  static String delayReason(String code) => switch (code) {
        'provider_unavailable' => _t(
            'The payment service (Sahal) is not responding right now. Your money is safe and will be sent automatically as soon as it is back.',
            'Adeegga lacag-dirista (Sahal) hadda ma shaqaynayo. Lacagtaadu way badbaadsan tahay, si toos ah ayaana loo diri doonaa marka uu soo laabto.'),
        'provider_balance' => _t(
            'Your withdrawal is waiting for the payment account to be topped up. It will then be sent automatically.',
            'Bixintaadu waxay sugaysaa in koontada lacag-bixinta lagu shubo. Kadib si toos ah ayaa loo diri doonaa.'),
        'confirming' => _t(
            'We are confirming the transfer with the payment service. It will never be sent twice.',
            'Waxaan la xaqiijinaynaa adeegga lacag-dirista in lacagta la diray. Marna labo jeer lama diri doono.'),
        'manual' => _t(
            'A member of our team is completing your withdrawal. If it cannot be paid, your money is returned to your wallet.',
            'Shaqaalaheena ayaa dhammaystiraya bixintaada. Haddii aan la bixin karin, lacagtaada waxaa lagu celin doonaa boorsadaada.'),
        _ => _t('Your withdrawal is in the queue and will be sent shortly.',
            'Bixintaadu waa safka, dhawaan ayaa la diri doonaa.'),
      };
  static String get hangTightWithdraw =>
      _t("Hang tight, we're processing your withdrawal", 'Fadlan sug, bixintaada waa la shaqeynayaa');
  // Withdrawal steps while it is sent
  static String get stepCheckFunds => _t('Checking your balance', 'Lacagaha ayaan baarayaa');
  static String get stepSendMoney => _t('Sending the money now', 'Lacagta ayaan dirayaa hadda');
  static String get stepConfirmSent => _t('Confirming it went through', 'Waa xaqiijinayaa inay ku guuleysatay');
  static String get stepDone => _t('DONE', 'LA DHAMMEEYAY');
  static String get stepActive => _t('IN PROGRESS', 'SOCDA');
  static String get stepWaiting => _t('WAITING', 'SUGAYA');
  // Before the first withdrawal: the account is approved by an admin.
  static String get verifyTitle => _t('Account Approval Required', 'Account-ka waa in la fasaxo');
  static String get verifyBody => _t(
      'To withdraw your funds, please contact Admin on WhatsApp to have your account approved for withdrawals.',
      'Si aad lacag ula baxdo markii ugu horreysay, fadlan la xiriir maamulka si account-kaaga loo xaqiijiyo loona fasaxo.');
  static String get verifyRejected => _t('Not approved', 'Lama fasixin');
  static String get verifyRestricted => _t('Withdrawals are on hold', 'Bixinta waa la joojiyay');
  static String get contactAdminWhatsapp => _t('Contact Admin on WhatsApp', 'La xiriir Maamulka (WhatsApp)');
  static String get adminWhatsapp => _t("Admin's WhatsApp:", 'WhatsApp-ka Maamulka:');
  static String get completeWithdrawal => _t('Complete Withdrawal', 'Dhammaystir Bixinta');
  static String get allHistory => _t('All', 'Dhammaan');
  static String get depositsTab => _t('Deposits', 'Dhigashooyin');
  static String get withdrawalsTab => _t('Withdrawals', 'Bixinno');
  static String withdrawLimits(String min, String max) => _t(
        'Minimum withdrawal is $min, maximum is $max',
        'Bixinta ugu yar waa $min, tan ugu badan waa $max',
      );

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

  // Bonus wallet
  static String get bonusWallet => _t('Bonus Wallet', 'Boorsada Gunnada');
  static String bonusRow(String rate) => _t('Bonus ($rate)', 'Gunno ($rate)');
  static String get bonusGoesTo => _t('You will get it in your Bonus Wallet', 'Waxaad heli doontaa Bonus Wallet');
  static String bonusRateInfo(String rate) => _t(
      'You earn $rate on every completed eligible transaction. Transfer it to your main wallet any time.',
      'Waxaad heshaa $rate dhaqdhaqaaq kasta oo la oggol yahay oo dhammaada. U wareeji boorsadaada weyn mar kasta.');
  static String get availableBonus => _t('Available bonus', 'Gunnada diyaarka ah');
  static String get noBonusToTransfer =>
      _t('At least \$0.01 is needed to transfer.', 'Ugu yaraan \$0.01 ayaa loo baahan yahay si loo wareejiyo.');
  static String bonusOnOrder(String amount, String direction, String method) => direction == 'deposit'
      ? _t('On \$$amount deposit • $method', 'Dhigasho \$$amount • $method')
      : _t('On \$$amount withdrawal • $method', 'Lacag-bixin \$$amount • $method');
  static String get bonusOff => _t('The bonus is off for your account.', 'Gunnadu way ka xiran tahay akoonkaaga.');
  static String get totalEarned => _t('Total earned', 'Wadarta la helay');
  static String get moveBonus => _t('Transfer Bonus to Main Wallet', 'U wareeji Gunnada Boorsada Weyn');
  static String bonusMoved(String amount) =>
      _t('\$$amount moved to your main wallet', '\$$amount waxaa loo wareejiyay boorsadaada weyn');
  static String get noBonusYet => _t('No bonus yet', 'Weli gunno ma jirto');
  static String get bonusEarned => _t('Bonus earned', 'Gunno la helay');
  static String get bonusMovedTitle => _t('Moved to main wallet', 'Loo wareejiyay boorsada weyn');
  static String get couldNotLoadBonus => _t('Could not load the bonus', 'Gunnada lama soo rarin');

  // Receiver name (Golis, ZAAD, EVC Plus)
  static String get receiverName => _t('Receiver Name', 'Magaca Qaataha');

  /// "Minimum deposit is ", ", maximum is ": the amounts go between, in bold.
  static (String, String) get depositLimitsParts => AppLanguage.isSomali
      ? ('Dhigashada ugu yar waa ', ' dhigashada ugu badan waa ')
      : ('Minimum deposit is ', ', maximum is ');
}
