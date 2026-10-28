/// May this account withdraw (customer_withdrawal_access)? Before the first
/// withdrawal an admin approves the account; until then the server refuses
/// every withdrawal, whatever the app shows.
class WithdrawalAccess {
  const WithdrawalAccess({
    required this.allowed,
    required this.status,
    this.reason,
    this.message,
    this.whatsapp,
    this.accountId,
    this.phone,
  });

  final bool allowed;

  /// pending | approved | rejected | restricted
  final String status;

  /// The admin's reason when rejected or restricted.
  final String? reason;

  /// The server's message (Somali), with the admin's WhatsApp number.
  final String? message;
  final String? whatsapp;
  final String? accountId;
  final String? phone;

  factory WithdrawalAccess.fromJson(Map<String, dynamic> j) => WithdrawalAccess(
        allowed: j['allowed'] as bool? ?? true,
        status: j['status'] as String? ?? 'approved',
        reason: j['reason'] as String?,
        message: j['message'] as String?,
        whatsapp: j['whatsapp'] as String?,
        accountId: j['accountId'] as String?,
        phone: j['phone'] as String?,
      );

  /// The WhatsApp message to the admin: account ID and registered number
  /// only (never a password, PIN or code).
  String get prefilled => 'Salaam, fadlan account-keyga withdrawal fasax.\n'
      'Account ID: ${accountId ?? '-'}\n'
      'Lambarkeyga: ${phone == null ? '-' : '+${phone!.replaceAll('+', '')}'}';

  /// wa.me link with the message, or null without a usable number.
  Uri? get whatsappLink {
    final digits = (whatsapp ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8) return null;
    return Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(prefilled)}');
  }
}
