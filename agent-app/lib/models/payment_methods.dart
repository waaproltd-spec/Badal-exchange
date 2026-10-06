import 'package:flutter/material.dart';

/// Payment methods, mirroring backend/src/lib/methods.ts.
///
/// Mobile-money methods identify the customer by phone number; betting
/// platforms by the customer's account ID on that platform.
enum MethodKind { mobileMoney, platform }

class PaymentMethodInfo {
  final String id;
  final String label;
  final MethodKind kind;
  final Color color;

  const PaymentMethodInfo(this.id, this.label, this.kind, this.color);

  bool get isMobileMoney => kind == MethodKind.mobileMoney;
  bool get isPlatform => kind == MethodKind.platform;

  /// Short mark shown in method badges (e.g. "EVC", "1X").
  String get initials {
    switch (id) {
      case 'evc_plus':
        return 'EVC';
      case 'onexbet':
        return '1X';
      case '888starz':
        return '888';
      default:
        return label.substring(0, label.length < 2 ? label.length : 2).toUpperCase();
    }
  }
}

const paymentMethods = <PaymentMethodInfo>[
  PaymentMethodInfo('evc_plus', 'EVC Plus', MethodKind.mobileMoney, Color(0xFF16A34A)),
  PaymentMethodInfo('golis', 'Golis', MethodKind.mobileMoney, Color(0xFF0EA5E9)),
  PaymentMethodInfo('telesom', 'Telesom', MethodKind.mobileMoney, Color(0xFF2563EB)),
  PaymentMethodInfo('edahab', 'eDahab', MethodKind.mobileMoney, Color(0xFFD97706)),
  PaymentMethodInfo('winwin', 'WinWin', MethodKind.platform, Color(0xFF059669)),
  PaymentMethodInfo('onexbet', '1XBET', MethodKind.platform, Color(0xFF1D4ED8)),
  PaymentMethodInfo('melbet', 'MELBET', MethodKind.platform, Color(0xFFCA8A04)),
  PaymentMethodInfo('betwinner', 'Betwinner', MethodKind.platform, Color(0xFF15803D)),
  PaymentMethodInfo('dbbet', 'DBbet', MethodKind.platform, Color(0xFFDC2626)),
  PaymentMethodInfo('888starz', '888STARZ', MethodKind.platform, Color(0xFF7C3AED)),
];

PaymentMethodInfo methodInfo(String id) => paymentMethods.firstWhere(
      (m) => m.id == id,
      orElse: () => PaymentMethodInfo(id, id, MethodKind.mobileMoney, const Color(0xFF6B7280)),
    );

/// Small rounded badge with the method's initials in its color.
class MethodBadge extends StatelessWidget {
  final String method;
  final double size;

  const MethodBadge({super.key, required this.method, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final info = methodInfo(method);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: info.color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Text(
        info.initials,
        style: TextStyle(color: info.color, fontWeight: FontWeight.w800, fontSize: size * 0.3),
      ),
    );
  }
}
