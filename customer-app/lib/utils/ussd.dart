/// An amount as it goes into a USSD code. The phone's dialer drops a "."
/// (so $57.52 reached EVC as $5752), so the cents are separated by a "*":
/// 57.52 -> "57*52", 1.5 -> "1*50", 5.00 -> "5". The same form the server
/// uses for payout codes (private.ussd_amount).
String ussdAmount(String amount) {
  final text = amount.trim().replaceAll(',', '.');
  final parts = text.split('.');
  final whole = parts.first.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final fraction = parts.length > 1 ? '${parts[1]}00'.substring(0, 2) : '00';
  final digits = whole.isEmpty ? '0' : whole;
  return fraction == '00' ? digits : '$digits*$fraction';
}
