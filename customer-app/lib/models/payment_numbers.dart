/// Another phone number the customer saved for a network.
class SavedPaymentNumber {
  const SavedPaymentNumber({required this.id, required this.method, required this.phone, this.label});

  final String id;
  final String method;
  final String phone;
  final String? label;

  /// The 9 digits after 252.
  String get local {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 9 ? digits.substring(digits.length - 9) : digits;
  }

  factory SavedPaymentNumber.fromJson(Map<String, dynamic> j) => SavedPaymentNumber(
        id: j['id']?.toString() ?? '',
        method: j['method']?.toString() ?? '',
        phone: j['phone']?.toString() ?? '',
        label: j['label'] as String?,
      );
}

/// Whether an admin let this customer use another phone number to send money
/// and to receive withdrawals (customer_payment_numbers), and for which
/// networks. The server enforces it on every order; the app only offers it.
class PaymentNumbers {
  const PaymentNumbers({required this.allowed, required this.methods, required this.numbers});

  final bool allowed;
  final List<String> methods;
  final List<SavedPaymentNumber> numbers;

  static const none = PaymentNumbers(allowed: false, methods: [], numbers: []);

  /// May the customer use another number on [method]?
  bool allows(String method) => allowed && methods.contains(method);

  /// The saved numbers of [method], most recently used first.
  List<SavedPaymentNumber> forMethod(String method) => numbers.where((n) => n.method == method).toList();

  factory PaymentNumbers.fromJson(Map<String, dynamic> j) => PaymentNumbers(
        allowed: j['allowed'] == true,
        methods: ((j['methods'] as List?) ?? const []).map((e) => e.toString()).toList(),
        numbers: ((j['numbers'] as List?) ?? const [])
            .map((e) => SavedPaymentNumber.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}
