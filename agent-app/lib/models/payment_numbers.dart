/// The networks an admin can authorize a customer to use another number on
/// (ZAAD is Telesom's; the server names it `telesom`).
const paymentNumberNetworks = <(String, String)>[
  ('evc_plus', 'EVC Plus'),
  ('golis', 'Golis'),
  ('telesom', 'ZAAD'),
  ('edahab', 'eDahab'),
];

String paymentNumberNetworkLabel(String method) {
  for (final n in paymentNumberNetworks) {
    if (n.$1 == method) return n.$2;
  }
  return method;
}

List<String> _strings(Object? v) => ((v as List?) ?? const []).map((e) => e.toString()).toList();
DateTime? _date(Object? v) => v == null ? null : DateTime.tryParse(v.toString());

/// A customer in the Payment Numbers list (manage_payment_number_customers).
class PaymentNumberCustomer {
  const PaymentNumberCustomer({
    required this.id,
    required this.name,
    required this.phone,
    required this.accountId,
    required this.enabled,
    required this.methods,
    required this.numberCount,
  });

  final String id;
  final String name;
  final String phone;
  final String accountId;
  final bool enabled;
  final List<String> methods;
  final int numberCount;

  factory PaymentNumberCustomer.fromJson(Map<String, dynamic> j) => PaymentNumberCustomer(
        id: j['id'] as String,
        name: j['name']?.toString() ?? '',
        phone: j['phone']?.toString() ?? '',
        accountId: j['accountId']?.toString() ?? '',
        enabled: j['enabled'] == true,
        methods: _strings(j['methods']),
        numberCount: (j['numberCount'] as num?)?.toInt() ?? 0,
      );
}

/// The permission itself: on or off, and for which networks.
class PaymentNumberAccess {
  const PaymentNumberAccess({required this.enabled, required this.methods, this.note, this.grantedAt, this.grantedBy, this.revokedAt, this.revokedBy});

  final bool enabled;
  final List<String> methods;
  final String? note;
  final DateTime? grantedAt;
  final String? grantedBy;
  final DateTime? revokedAt;
  final String? revokedBy;

  factory PaymentNumberAccess.fromJson(Map<String, dynamic> j) => PaymentNumberAccess(
        enabled: j['enabled'] == true,
        methods: _strings(j['methods']),
        note: j['note'] as String?,
        grantedAt: _date(j['grantedAt']),
        grantedBy: j['grantedBy'] as String?,
        revokedAt: _date(j['revokedAt']),
        revokedBy: j['revokedBy'] as String?,
      );
}

/// A number on a customer's list.
class PaymentNumberEntry {
  const PaymentNumberEntry({
    required this.id,
    required this.method,
    required this.phone,
    required this.addedBy,
    required this.uses,
    required this.blocked,
    this.label,
    this.createdAt,
    this.lastUsedAt,
  });

  final String id;
  final String method;
  final String phone;
  final String? label;
  final String addedBy;
  final int uses;
  final bool blocked;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;

  factory PaymentNumberEntry.fromJson(Map<String, dynamic> j) => PaymentNumberEntry(
        id: j['id'] as String,
        method: j['method']?.toString() ?? '',
        phone: j['phone']?.toString() ?? '',
        label: j['label'] as String?,
        addedBy: j['addedBy']?.toString() ?? 'customer',
        uses: (j['uses'] as num?)?.toInt() ?? 0,
        blocked: j['blocked'] == true,
        createdAt: _date(j['createdAt']),
        lastUsedAt: _date(j['lastUsedAt']),
      );
}

/// One customer: the permission and every number on file (manage_customer_payment_numbers).
class CustomerPaymentNumbers {
  const CustomerPaymentNumbers({
    required this.id,
    required this.name,
    required this.phone,
    required this.accountId,
    required this.access,
    required this.numbers,
  });

  final String id;
  final String name;
  final String phone;
  final String accountId;
  final PaymentNumberAccess access;
  final List<PaymentNumberEntry> numbers;

  factory CustomerPaymentNumbers.fromJson(Map<String, dynamic> j) {
    final c = (j['customer'] as Map).cast<String, dynamic>();
    return CustomerPaymentNumbers(
      id: c['id'] as String,
      name: c['name']?.toString() ?? '',
      phone: c['phone']?.toString() ?? '',
      accountId: c['accountId']?.toString() ?? '',
      access: PaymentNumberAccess.fromJson(((j['access'] as Map?) ?? const {}).cast<String, dynamic>()),
      numbers: ((j['numbers'] as List?) ?? const []).map((e) => PaymentNumberEntry.fromJson((e as Map).cast<String, dynamic>())).toList(),
    );
  }
}
