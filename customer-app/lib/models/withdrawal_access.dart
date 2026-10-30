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

  /// The WhatsApp message to the admin: customer ID, registered number and,
  /// for a betting platform, its name and the account ID -- never a
  /// password, PIN or code.
  String prefilled({String? platform, String? platformAccountId}) => [
        'Hello Admin,',
        '',
        'Please approve my withdrawal account.',
        '',
        'Customer ID: ${accountId ?? '-'}',
        'Phone Number: ${phone == null ? '-' : '+${phone!.replaceAll('+', '')}'}',
        if (platform != null) 'Platform: $platform',
        if (platformAccountId != null && platformAccountId.isNotEmpty) 'Account ID: $platformAccountId',
        '',
        'I would like to request approval for withdrawals.',
        '',
        'Thank you.',
      ].join('\n');

  /// wa.me link with the message, or null without a usable number.
  Uri? whatsappLink({String? platform, String? platformAccountId}) {
    final digits = (whatsapp ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8) return null;
    final text = prefilled(platform: platform, platformAccountId: platformAccountId);
    return Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}');
  }
}
