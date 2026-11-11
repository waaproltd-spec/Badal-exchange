// Wallet to wallet transfers (Wallet -> Send Money). Amounts are decimal strings from the server, shown as they are.

/// The Wallet PIN: set or not, locked after 5 wrong tries.
class WalletPinStatus {
  const WalletPinStatus({required this.hasPin, this.locked = false, this.lockedUntil});

  final bool hasPin;
  final bool locked;
  final DateTime? lockedUntil;

  factory WalletPinStatus.fromJson(Map<String, dynamic> j) => WalletPinStatus(
        hasPin: j['hasPin'] as bool? ?? false,
        locked: j['locked'] as bool? ?? false,
        lockedUntil: j['lockedUntil'] == null ? null : DateTime.tryParse(j['lockedUntil'] as String)?.toLocal(),
      );
}

/// Who owns a Wallet ID: the name to check before sending.
class TransferRecipient {
  const TransferRecipient({required this.found, this.self = false, this.walletId, this.name});

  final bool found;

  /// The customer typed their own Wallet ID.
  final bool self;
  final String? walletId;
  final String? name;

  factory TransferRecipient.fromJson(Map<String, dynamic> j) => TransferRecipient(
        found: j['found'] as bool? ?? false,
        self: j['self'] as bool? ?? false,
        walletId: j['walletId'] as String?,
        name: j['name'] as String?,
      );
}

/// One transfer, as the sender or the recipient sees it.
class WalletTransfer {
  const WalletTransfer({
    required this.id,
    required this.reference,
    required this.direction,
    required this.amount,
    required this.fee,
    required this.counterpartName,
    required this.counterpartWalletId,
    required this.balanceAfter,
    required this.createdAt,
  });

  final String id;
  final String reference;

  /// 'sent' | 'received'
  final String direction;
  final String amount;
  final String fee;
  final String counterpartName;
  final String counterpartWalletId;
  final String balanceAfter;
  final DateTime createdAt;

  bool get sent => direction == 'sent';

  factory WalletTransfer.fromJson(Map<String, dynamic> j) => WalletTransfer(
        id: j['id'] as String,
        reference: j['reference'] as String,
        direction: j['direction'] as String,
        amount: j['amount'] as String,
        fee: j['fee'] as String? ?? '0.00',
        counterpartName: j['counterpartName'] as String? ?? '',
        counterpartWalletId: j['counterpartWalletId'] as String? ?? '',
        balanceAfter: j['balanceAfter'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      );
}

/// The answer to "send": done, or a wrong / locked PIN (a normal answer, not an error).
class TransferOutcome {
  const TransferOutcome({required this.ok, this.code, this.attemptsLeft, this.lockedUntil, this.transfer});

  final bool ok;

  /// WRONG_PIN | PIN_LOCKED when not ok.
  final String? code;
  final int? attemptsLeft;
  final DateTime? lockedUntil;
  final WalletTransfer? transfer;

  factory TransferOutcome.fromJson(Map<String, dynamic> j) {
    final ok = j['ok'] as bool? ?? false;
    return TransferOutcome(
      ok: ok,
      code: j['code'] as String?,
      attemptsLeft: (j['attemptsLeft'] as num?)?.toInt(),
      lockedUntil: j['lockedUntil'] == null ? null : DateTime.tryParse(j['lockedUntil'] as String)?.toLocal(),
      transfer: ok ? WalletTransfer.fromJson(j) : null,
    );
  }
}
