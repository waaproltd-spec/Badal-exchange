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
    this.name,
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

  /// The customer's name, for the message to the admin.
  final String? name;

  factory WithdrawalAccess.fromJson(Map<String, dynamic> j) => WithdrawalAccess(
        allowed: j['allowed'] as bool? ?? true,
        status: j['status'] as String? ?? 'approved',
        reason: j['reason'] as String?,
        message: j['message'] as String?,
        whatsapp: j['whatsapp'] as String?,
        accountId: j['accountId'] as String?,
        phone: j['phone'] as String?,
        name: j['name'] as String?,
      );

  /// The message to the admin (WhatsApp, and Telegram once pasted): the customer's name, Customer ID (the wallet ID shown in the app)
  /// and registered number only -- never a platform, an account ID, an amount, a password, PIN or code.
  String prefilled() => [
        '🔔 Codsi Lacag Bixin (Withdrawal)',
        '',
        '👤 Macmiil: ${(name ?? '').trim().isEmpty ? '-' : name!.trim()}',
        '🪪 Customer ID: ${accountId ?? '-'}',
        '📱 Number: ${phone == null ? '-' : '+${phone!.replaceAll('+', '')}'}',
        '',
        '🟡 PENDING – Weli Sugaya',
      ].join('\n');

  /// wa.me link with the message, or null without a usable number.
  Uri? whatsappLink() {
    final digits = (whatsapp ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8) return null;
    final text = prefilled();
    return Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}');
  }
}
