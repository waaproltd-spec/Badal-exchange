import 'strings.dart';

/// The server answers in English. In Somali, the messages a customer can
/// see (errors, why an order failed) are shown in Somali; anything not
/// known here is shown as the server wrote it (e.g. a note an agent typed).
String serverText(String text, {String? code}) {
  if (!AppLanguage.isSomali || text.isEmpty) return text;
  final byCode = _byCode[code];
  if (byCode != null) return byCode;
  for (final (pattern, somali) in _patterns) {
    final m = pattern.firstMatch(text);
    if (m != null) return somali(m);
  }
  return text;
}

const _byCode = <String, String>{
  'INSUFFICIENT_BALANCE': 'Haraaga boorsadaadu kuma filna.',
  'INVALID_AMOUNT': 'Lacagtu waa inay ka badnaataa eber.',
  'DUPLICATE_WITHDRAWAL': 'Codsi lacag-bixin oo isku mid ah ayaa horay u socda.',
  'REQUEST_IN_PROGRESS': 'Codsigan horay ayaa loo wadaa.',
  'IDEMPOTENCY_KEY_REUSED': 'Codsigan horay ayaa loo isticmaalay. Mar kale isku day.',
  'INVALID_PHONE_PREFIX':
      'Lambarka taleefanku waa inuu ku bilowdaa 61 ama 77 (EVC Plus), 90 (Golis), 63 (ZAAD) ama 62 (eDahab).',
  'PHONE_TAKEN': 'Lambarkan taleefanka horay ayaa loo diiwaangeliyay.',
  'RATE_LIMITED': 'Isku day badan ayaa la sameeyay. Wax yar sug, kadibna mar kale isku day.',
  'INVALID_PASSWORD': 'Erayga sirta ee hadda waa khalad.',
  'SESSION_REPLACED': 'Akoonkan taleefan kale ayaa laga galay. Dib u gal.',
  'NOT_AVAILABLE': 'Adeeggan hadda lama heli karo.',
  'PLAYER_LOOKUP_UNAVAILABLE': 'Ciyaaryahanka hadda lama hubin karo. Mar kale isku day.',
  'PENDING_NOT_FOUND': 'Codsigan horay ayaa loo dhammeeyay ama wuu dhacay.',
};

final _patterns = <(RegExp, String Function(RegExpMatch))>[
  (RegExp(r'^Minimum withdrawal is \$?([\d.]+)'), (m) => 'Lacag-bixinta ugu yar waa \$${m[1]}.'),
  (RegExp(r'^Maximum withdrawal is \$?([\d.]+)'), (m) => 'Lacag-bixinta ugu badan waa \$${m[1]}.'),
  (RegExp(r'^Minimum amount is \$?([\d.]+)'), (m) => 'Lacagta ugu yar waa \$${m[1]}.'),
  (RegExp(r'^Maximum amount is \$?([\d.]+)'), (m) => 'Lacagta ugu badan waa \$${m[1]}.'),
  (RegExp(r'^Enter an amount between \$([\d.]+) and \$([\d.]+)'), (m) => 'Geli lacag u dhaxaysa \$${m[1]} iyo \$${m[2]}.'),
  (RegExp(r'^Invalid amount'), (_) => 'Lacagta waa khalad.'),
  (RegExp(r'^Enter your 9-digit phone number'), (_) => 'Geli lambarkaaga 9-ka god ah ka dib +252.'),
  (RegExp(r'Enter exactly 9 digits'), (_) => 'Lambarka waa khalad. Geli 9 god oo kaliya.'),
  (RegExp(r'^Enter the player ID as digits only'), (_) => 'ID-ga ciyaaryahanka ku geli tirooyin kaliya.'),
  (RegExp(r'^Order is already (\w+)'), (_) => 'Dalabkan horay ayaa la xiray.'),
  (RegExp(r'^This order can no longer be cancelled'), (_) => 'Dalabkan hadda lama joojin karo.'),
  (RegExp(r'^(Order|Wallet|Withdrawal) not found'), (_) => 'Lama helin.'),
  (RegExp(r'^Invalid credentials'), (_) => 'Lambarka taleefanka ama erayga sirta waa khalad.'),
  (RegExp(r'^Account is disabled'), (_) => 'Akoonkan waa la xiray. La xiriir Badal Exchange.'),
  (RegExp(r'^Could not reach the server'), (_) => AppStrings.networkError),
  // Why an order failed.
  (RegExp(r'^Not paid within (\d+) minutes'), (m) => 'Lacag lama bixin ${m[1]} daqiiqo gudahood.'),
  (RegExp(r'^(?:Unpaid|No payment)'), (_) => 'Lacag lama bixin waqtiga loo qabtay gudihiisa.'),
  (RegExp(r'^\S+ account (\S+) was not found'), (m) => 'Akoonka ${m[1]} lama helin.'),
  (RegExp(r'^"(\S+)" is not a .* account ID'), (m) => '"${m[1]}" ma aha ID akoon sax ah.'),
  (RegExp(r'^Payout failed before the PIN step'), (_) => 'Lacag-bixintu way fashilantay ka hor intaan la dirin. Lacagtaada waa lagu celiyay.'),
  (RegExp(r'^Transaction failed'), (_) => 'Dalabku wuu fashilmay. Lacag lagaama jarin.'),
  (RegExp(r'^Transaction was cancelled'), (_) => 'Dalabka waa la joojiyay.'),
  (RegExp(r'^Transaction expired'), (_) => 'Dalabka waqtigiisii wuu dhacay.'),
];
