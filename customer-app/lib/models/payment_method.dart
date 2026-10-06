import 'package:flutter/material.dart';

/// Payment methods. The backend is the single source of truth
/// (backend/src/lib/methods.ts, served at GET /meta/payment-methods); the
/// app loads that catalog at startup (CustomerApi.loadMethodCatalog).
///
/// Mobile money identifies the customer by their phone number on that
/// service; betting platforms by their account ID on that platform.
class PaymentMethodInfo {
  const PaymentMethodInfo(this.id, this.label, this.isPlatform, this.color, this.initials);

  final String id;
  final String label;
  final bool isPlatform;
  final Color color;

  /// Short mark shown on the method's tile/icon.
  final String initials;

  /// What the customer types for this method.
  String get identifierLabel => isPlatform ? '$label Account ID' : '$label Phone Number';
  String get identifierHint => isPlatform ? 'e.g. 7841228' : 'e.g. 2526XXXXXXX';
}

/// Bundled copy of the backend catalog, used only until the startup load
/// succeeds (e.g. when offline).
List<PaymentMethodInfo> paymentMethods = const <PaymentMethodInfo>[
  PaymentMethodInfo('evc_plus', 'EVC Plus', false, Color(0xFF16A34A), 'EVC'),
  PaymentMethodInfo('golis', 'Golis', false, Color(0xFF0EA5E9), 'GO'),
  PaymentMethodInfo('telesom', 'Telesom', false, Color(0xFF2563EB), 'TE'),
  PaymentMethodInfo('edahab', 'eDahab', false, Color(0xFFD97706), 'eD'),
  PaymentMethodInfo('winwin', 'WinWin', true, Color(0xFF059669), 'WW'),
  PaymentMethodInfo('onexbet', '1XBET', true, Color(0xFF1D4ED8), '1X'),
  PaymentMethodInfo('melbet', 'MELBET', true, Color(0xFFCA8A04), 'MB'),
  PaymentMethodInfo('betwinner', 'Betwinner', true, Color(0xFF15803D), 'BW'),
  PaymentMethodInfo('dbbet', 'DBbet', true, Color(0xFFDC2626), 'DB'),
  PaymentMethodInfo('888starz', '888STARZ', true, Color(0xFF7C3AED), '888'),
];

PaymentMethodInfo _fromJson(Map<String, dynamic> m) {
  final hex = (m['color'] as String? ?? '#6B7280').replaceFirst('#', '');
  final label = m['label'] as String? ?? m['method'] as String;
  return PaymentMethodInfo(
    m['method'] as String,
    label,
    m['kind'] == 'platform',
    Color(int.parse('FF$hex', radix: 16)),
    m['initials'] as String? ?? label.substring(0, label.length < 2 ? label.length : 2).toUpperCase(),
  );
}

/// Replaces [paymentMethods] with the backend catalog; keeps the current
/// list if the response can't be used.
void applyPaymentMethodCatalog(List<dynamic> json) {
  try {
    final list = json.map((e) => _fromJson(e as Map<String, dynamic>)).toList();
    if (list.isNotEmpty) paymentMethods = list;
  } catch (_) {}
}

PaymentMethodInfo methodInfo(String id) => paymentMethods.firstWhere(
      (m) => m.id == id,
      orElse: () => PaymentMethodInfo(id, id, false, const Color(0xFF6B7280), id.isEmpty ? '?' : id[0].toUpperCase()),
    );

/// A method the backend currently offers (enabled), with the numbers or
/// accounts customers send deposits to.
class PaymentMethodOption {
  const PaymentMethodOption({required this.info, required this.depositNumbers});

  final PaymentMethodInfo info;
  final List<({String number, String? label})> depositNumbers;

  factory PaymentMethodOption.fromJson(Map<String, dynamic> json) {
    return PaymentMethodOption(
      // The backend sends label/kind/styling with each method; fall back to
      // the catalog only for older responses.
      info: json['label'] != null ? _fromJson(json) : methodInfo(json['method'] as String),
      depositNumbers: ((json['depositNumbers'] as List<dynamic>?) ?? const [])
          .map((e) => e as Map<String, dynamic>)
          .map((e) => (number: e['number'] as String, label: e['label'] as String?))
          .toList(),
    );
  }
}
