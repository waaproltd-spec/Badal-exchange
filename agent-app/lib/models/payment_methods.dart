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

  /// Short mark shown in method badges (e.g. "EVC", "1X").
  final String initials;

  const PaymentMethodInfo(this.id, this.label, this.kind, this.color, this.initials);

  bool get isMobileMoney => kind == MethodKind.mobileMoney;
  bool get isPlatform => kind == MethodKind.platform;
}

/// The payment-method catalog. The backend is the source of truth
/// (backend/src/lib/methods.ts, served at GET /meta/payment-methods): the
/// app loads it at startup (AgentApi.loadMethodCatalog). This bundled
/// copy is only used until that load succeeds (e.g. offline).
List<PaymentMethodInfo> paymentMethods = const [
  PaymentMethodInfo('evc_plus', 'EVC Plus', MethodKind.mobileMoney, Color(0xFF16A34A), 'EVC'),
  PaymentMethodInfo('golis', 'Golis', MethodKind.mobileMoney, Color(0xFF0EA5E9), 'GO'),
  PaymentMethodInfo('telesom', 'Telesom', MethodKind.mobileMoney, Color(0xFF2563EB), 'TE'),
  PaymentMethodInfo('edahab', 'eDahab', MethodKind.mobileMoney, Color(0xFFD97706), 'eD'),
  PaymentMethodInfo('winwin', 'WinWin', MethodKind.platform, Color(0xFF059669), 'WW'),
  PaymentMethodInfo('onexbet', '1XBET', MethodKind.platform, Color(0xFF1D4ED8), '1X'),
  PaymentMethodInfo('melbet', 'MELBET', MethodKind.platform, Color(0xFFCA8A04), 'MB'),
  PaymentMethodInfo('betwinner', 'Betwinner', MethodKind.platform, Color(0xFF15803D), 'BW'),
  PaymentMethodInfo('dbbet', 'DBbet', MethodKind.platform, Color(0xFFDC2626), 'DB'),
  PaymentMethodInfo('888starz', '888STARZ', MethodKind.platform, Color(0xFF7C3AED), '888'),
];

/// Replaces [paymentMethods] with the backend catalog. Returns false (and
/// keeps the current list) if the response can't be used.
bool applyPaymentMethodCatalog(List<dynamic> json) {
  try {
    final list = json.map((e) {
      final m = e as Map<String, dynamic>;
      final hex = (m['color'] as String? ?? '#6B7280').replaceFirst('#', '');
      return PaymentMethodInfo(
        m['method'] as String,
        m['label'] as String,
        m['kind'] == 'platform' ? MethodKind.platform : MethodKind.mobileMoney,
        Color(int.parse('FF$hex', radix: 16)),
        m['initials'] as String? ?? (m['label'] as String).substring(0, 2).toUpperCase(),
      );
    }).toList();
    if (list.isEmpty) return false;
    paymentMethods = list;
    return true;
  } catch (_) {
    return false;
  }
}

PaymentMethodInfo methodInfo(String id) => paymentMethods.firstWhere(
      (m) => m.id == id,
      orElse: () => PaymentMethodInfo(id, id, MethodKind.mobileMoney, const Color(0xFF6B7280), id.isEmpty ? '?' : id[0].toUpperCase()),
    );

/// Methods with a logo in assets/methods/<id>.png; others show initials.
const _logos = {
  'evc_plus', 'golis', 'telesom', 'edahab', 'onexbet', 'melbet', 'winwin', 'dbbet', 'betwinner', '888starz',
};

/// Small rounded badge: the method's logo, or its initials in its color.
class MethodBadge extends StatelessWidget {
  final String method;
  final double size;

  const MethodBadge({super.key, required this.method, this.size = 40});

  @override
  Widget build(BuildContext context) {
    if (_logos.contains(method)) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.26),
          border: Border.all(color: Colors.black.withOpacity(0.08)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.26),
          child: Image.asset('assets/methods/$method.png', fit: BoxFit.cover, filterQuality: FilterQuality.medium),
        ),
      );
    }
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

/// A method's full logo on a wide rounded tile (2.4 : 1), never cropped or
/// stretched; [MethodBadge] for a method without a logo.
class MethodLogo extends StatelessWidget {
  final String method;
  final double width;

  const MethodLogo({super.key, required this.method, this.width = 96});

  @override
  Widget build(BuildContext context) {
    final height = width / 2.4;
    if (!_logos.contains(method)) {
      return SizedBox(width: width, height: height, child: Center(child: MethodBadge(method: method, size: height)));
    }
    return Container(
      key: Key('wide-logo-$method'),
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset('assets/methods/wide/$method.png', fit: BoxFit.contain, filterQuality: FilterQuality.medium),
      ),
    );
  }
}
