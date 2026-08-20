/// Builds a `tel:` URI from the admin-configured EVC Plus payout USSD
/// template (e.g. `*712*{number}*{amount}#`), substituting the customer's
/// EVC Plus number and the payout amount. `#` must be percent-encoded for
/// `tel:` URIs to dial correctly on Android. Returns null if there's no
/// template configured -- callers should hide the dial button in that case
/// rather than show one that does nothing.
String? buildPayoutUssdDialUri(String? template, String number, String amount) {
  if (template == null || template.isEmpty) return null;
  final code = template.replaceAll('{number}', number).replaceAll('{amount}', amount).replaceAll('#', '%23');
  return 'tel:$code';
}
