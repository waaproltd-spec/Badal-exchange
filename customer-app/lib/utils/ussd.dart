/// Builds a `tel:` URI from EVC Plus's admin-configured "Dial to Pay" USSD
/// template (e.g. `*712*610346060*{amount}#`), substituting `{amount}`.
/// `#` must be percent-encoded for `tel:` URIs to dial correctly on Android.
/// Returns null if there's no template configured -- callers should skip
/// the auto-dial step in that case rather than dial nothing.
String? buildUssdDialUri(String? template, String amount) {
  if (template == null || template.isEmpty) return null;
  final code = template.replaceAll('{amount}', amount).replaceAll('#', '%23');
  return 'tel:$code';
}
