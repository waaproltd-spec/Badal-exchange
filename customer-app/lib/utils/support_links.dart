/// A support contact (set by admins in the Agent App) as a link: a full
/// URL as it is, else a WhatsApp number (wa.me), a Telegram username
/// (t.me) or a Facebook page name. Null when there is nothing usable.
Uri? supportLink(String kind, String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return null;
  final uri = Uri.tryParse(v);
  if (uri != null && uri.hasScheme) return uri;
  switch (kind) {
    case 'whatsapp':
      final digits = v.replaceAll(RegExp(r'\D'), '');
      return digits.length < 8 ? null : Uri.parse('https://wa.me/$digits');
    case 'telegram':
      final name = v.replaceFirst(RegExp(r'^@'), '');
      return RegExp(r'^[A-Za-z0-9_]{4,32}$').hasMatch(name) ? Uri.parse('https://t.me/$name') : null;
    case 'facebook':
      return Uri.parse('https://facebook.com/$v');
  }
  return null;
}
