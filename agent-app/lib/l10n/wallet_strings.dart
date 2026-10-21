import 'dart:ui';

/// Strings of the wallet Add Money / Deduct Money screens, in Somali when the
/// phone is set to Somali and English otherwise.
class WalletStrings {
  WalletStrings._();

  /// Overridable in tests; defaults to the phone's language.
  static bool? somaliOverride;

  static bool get isSomali => somaliOverride ?? PlatformDispatcher.instance.locale.languageCode == 'so';

  static String _t(String en, String so) => isSomali ? so : en;

  static String get addMoney => _t('Add Money', 'Lacag Ku Shub');
  static String get deductMoney => _t('Deduct Money', 'Lacag Ka Jar');
  static String get walletHistory => _t('Wallet History', 'Taariikhda Wallet-ka');
  static String get walletAdjustments => _t('Wallet Adjustments', 'Isbeddelada Wallet-ka');
  static String get walletBalance => _t('Wallet Balance', 'Haraaga Wallet-ka');
  static String get amountUsd => _t('Amount (USD)', 'Qadarka Lacagta (USD)');
  static String get reasonAdd => _t('Reason for adding money', 'Sababta Lacagta Loogu Darayo');
  static String get reasonDeduct => _t('Reason for deducting money', 'Sababta Lacagta Laga Jarayo');
  static String get reasonHintAdd => _t('e.g. Added for the customer', 'tusaale Ku shubid macmiilka');
  static String get reasonHintDeduct => _t('e.g. Deducted from the customer', 'tusaale Ka jarid macmiilka');
  static String get details => _t('Details', 'Faahfaahinta');
  static String get currentBalance => _t('Current balance', 'Haraaga Hadda');
  static String get amountAdded => _t('Amount added', 'Lacagta La Daro');
  static String get amountDeducted => _t('Amount deducted', 'Lacagta La Jaro');
  static String get newBalance => _t('New balance', 'Haraaga Cusub');
  static String get confirmAdd => _t('Confirm & Add', 'Xaqiiji oo Ku Shub');
  static String get confirmDeduct => _t('Confirm & Deduct', 'Xaqiiji oo Ka Jar');
  static String get cancel => _t('Cancel', 'Jooji');
  static String get enterAmount => _t('Enter an amount above \$0', 'Geli lacag ka badan \$0');
  static String get enterReason => _t('Enter a reason (at least 3 characters)', 'Geli sabab (ugu yaraan 3 xaraf)');
  static String get moreThanBalance =>
      _t('More than the customer\'s balance', 'Waxay ka badan tahay haraaga macmiilka');
  static String confirmQuestion(bool add, String amount, String name) => add
      ? _t('Add $amount to $name\'s wallet?', 'Ku shub $amount wallet-ka $name?')
      : _t('Deduct $amount from $name\'s wallet?', 'Ka jar $amount wallet-ka $name?');
  static String get done => _t('Done', 'Waa la dhammeeyay');
  static String get added => _t('Money added', 'Lacagta waa la shubay');
  static String get deducted => _t('Money deducted', 'Lacagta waa la jaray');
  static String get failed => _t('Could not complete', 'Lama dhammaystirin');
  static String get reference => _t('Reference', 'Tixraac');
  static String get balanceBefore => _t('Balance before', 'Haraaga ka hor');
  static String get balanceAfter => _t('Balance after', 'Haraaga kadib');
  static String get reason => _t('Reason', 'Sababta');
  static String get agent => _t('Agent', 'Wakiilka');
  static String get customer => _t('Customer', 'Macmiilka');
  static String get date => _t('Date', 'Taariikhda');
  static String get status => _t('Status', 'Xaaladda');
  static String get completed => _t('Completed', 'La dhammeeyay');
  static String get all => _t('All', 'Dhammaan');
  static String get none => _t('No wallet adjustments yet.', 'Weli isbeddel wallet ma jiro.');
  static String get privateNote =>
      _t('Only staff see this history. The customer sees only the balance.', 'Shaqaalaha oo keliya ayaa arka taariikhdan. Macmiilku wuxuu arkaa haraaga oo keliya.');
}
