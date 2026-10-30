import '../api/api_exception.dart';
import '../api/customer_api.dart';
import '../l10n/server_text.dart';
import '../l10n/strings.dart';

/// What the customer reads when a deposit or a withdrawal goes wrong: always
/// Somali, whatever language the app is set to. Technical details go to the
/// admin (Telegram), never to the customer.
class PaymentErrors {
  PaymentErrors._();

  /// The title over an error, Somali whatever the app language.
  static const title = 'Tan lama dhammaystiri karin';
  static const deposit = '❌ Dhigasho hadda cilad ayaa ka jirta. Fadlan mar kale isku day.';
  static const withdraw = '❌ Lacag-bixinta hadda cilad ayaa ka jirta. Fadlan mar kale isku day.';

  /// Codes the customer can fix themselves; the server words them in Somali
  /// (limits, KYC, account approval) or the app does.
  static const _serverSomali = {
    'WITHDRAWAL_KYC_REQUIRED',
    'WITHDRAWAL_DAILY_LIMIT',
    'WITHDRAWAL_MONTHLY_LIMIT',
    'WITHDRAWAL_VERIFICATION_REQUIRED',
  };

  static const _fixable = {
    'INSUFFICIENT_BALANCE',
    'DUPLICATE_WITHDRAWAL',
    'INVALID_AMOUNT',
    'BELOW_MIN_WITHDRAWAL',
    'ABOVE_MAX_WITHDRAWAL',
    'BELOW_MIN_DEPOSIT',
    'ABOVE_MAX_DEPOSIT',
  };

  /// A typing mistake, not an error: not reported to the admin.
  static bool _isInput(String code) =>
      code.startsWith('BELOW_MIN') || code.startsWith('ABOVE_MAX') || code == 'VALIDATION_ERROR' || code == 'INVALID_AMOUNT';

  static String message(Object error, {required bool isDeposit}) {
    final generic = isDeposit ? deposit : withdraw;
    if (error is! ApiException) return generic;
    if (_serverSomali.contains(error.code) && error.message.isNotEmpty) return error.message;
    // A typing or balance mistake the customer can fix: its Somali wording
    // (with the limit). The app already words it in Somali when the app is in Somali.
    if (_fixable.contains(error.code)) {
      final somali = AppLanguage.isSomali ? error.message : somaliServerText(error.message, code: error.code);
      if (somali.isNotEmpty && (AppLanguage.isSomali || somali != error.message)) return '❌ $somali';
    }
    return generic;
  }

  /// The Somali message, and a note to the server (fire and forget) so the
  /// admin hears about it on Telegram. Never throws.
  static String handle(
    CustomerApi api,
    Object error, {
    required bool isDeposit,
    String? method,
    String? amount,
  }) {
    final code = error is ApiException ? error.code : 'ERROR';
    if (!_isInput(code)) {
      api
          .reportPaymentError(
            direction: isDeposit ? 'deposit' : 'withdraw',
            method: method ?? '',
            amount: amount ?? '',
            code: code,
            detail: error is ApiException ? error.message : error.toString(),
          )
          .catchError((_) {});
    }
    return message(error, isDeposit: isDeposit);
  }
}
