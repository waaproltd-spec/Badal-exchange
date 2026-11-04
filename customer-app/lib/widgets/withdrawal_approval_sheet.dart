import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/strings.dart';

/// The support bot customers are sent to for withdrawal approval.
const approvalTelegramBot = 'Badalaisupportbot';

/// "Akoonka Waa In La Fasaxo": the popup shown when a first withdrawal needs the administrator's approval.
/// A glowing support icon, the title, the message, and two buttons only: WhatsApp (the administration's contact)
/// and Telegram (@Badalaisupportbot). Dark by design, in light and dark mode alike.
class WithdrawalApprovalSheet extends StatelessWidget {
  const WithdrawalApprovalSheet(
      {super.key, this.whatsappLink, this.telegramMessage, this.reason, this.launch});

  /// The administration's WhatsApp link (with the message ready), or null when none is set.
  final Uri? whatsappLink;

  /// The ready message for the administration. A Telegram bot chat cannot be opened with text in it, so it is
  /// placed on the clipboard for the customer to paste.
  final String? telegramMessage;

  /// The administrator's reason when the account was rejected or restricted.
  final String? reason;

  /// Opens a link; true when it opened. Replaceable for tests.
  final Future<bool> Function(Uri uri)? launch;

  static const _navy = Color(0xFF0B1226);
  static const _navy2 = Color(0xFF151B3A);
  static const _green = Color(0xFF22E06B);

  Future<bool> _open(Uri uri) async {
    try {
      return await (launch ??
          (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
    } catch (_) {
      return false;
    }
  }

  void _say(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _whatsapp(BuildContext context) async {
    final link = whatsappLink;
    if (link == null) return _say(context, AppStrings.supportNotSet);
    if (!await _open(link) && context.mounted)
      _say(context, AppStrings.approvalAppMissing('WhatsApp'));
  }

  /// The Telegram app first; without it, the t.me page in the browser.
  Future<void> _telegram(BuildContext context) async {
    final text = telegramMessage;
    var pasted = false;
    if (text != null && text.isNotEmpty) {
      try {
        await Clipboard.setData(ClipboardData(text: text));
        pasted = true;
      } catch (_) {}
    }
    var ok = await _open(Uri.parse('tg://resolve?domain=$approvalTelegramBot'));
    if (!ok) ok = await _open(Uri.parse('https://t.me/$approvalTelegramBot'));
    if (!context.mounted) return;
    if (!ok) {
      _say(context, AppStrings.approvalAppMissing('Telegram'));
    } else if (pasted) {
      _say(context, AppStrings.approvalMessageCopied);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('withdraw-verify'),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_navy, _navy2]),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 26, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  key: const Key('approval-icon'),
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0E3B2A),
                    boxShadow: [
                      BoxShadow(
                          color: _green.withOpacity(0.45),
                          blurRadius: 34,
                          spreadRadius: 4)
                    ],
                  ),
                  child: const Icon(Icons.support_agent_rounded,
                      size: 52, color: _green),
                ),
              ),
              const SizedBox(height: 22),
              Text.rich(
                key: const Key('approval-title'),
                textAlign: TextAlign.center,
                TextSpan(children: [
                  TextSpan(text: AppStrings.approvalTitleLead),
                  TextSpan(
                      text: AppStrings.approvalTitleHighlight,
                      style: const TextStyle(color: _green)),
                  const TextSpan(text: ' '),
                  const WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Icon(Icons.verified_rounded,
                        key: Key('approval-check'),
                        color: Color(0xFF1FB955),
                        size: 26),
                  ),
                ]),
                style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                    color: Colors.white),
              ),
              const SizedBox(height: 12),
              Text(AppStrings.verifyBody,
                  key: const Key('approval-body'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 16, height: 1.45, color: Color(0xFFE8ECF8))),
              if (reason != null && reason!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(reason!,
                    key: const Key('verify-reason'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 14, color: Color(0xFFFF8A8A))),
              ],
              const SizedBox(height: 22),
              IntrinsicHeight(
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _ContactButton(
                          key: const Key('contact-admin-whatsapp'),
                          icon: Icons.chat_rounded,
                          label: AppStrings.contactAdminWhatsappLabel,
                          colors: const [Color(0xFF1FC94F), Color(0xFF0A8F32)],
                          glow: const Color(0xFF1FC94F),
                          onTap: () => _whatsapp(context),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ContactButton(
                          key: const Key('contact-admin-telegram'),
                          icon: Icons.send_rounded,
                          label: AppStrings.contactAdminTelegramLabel,
                          colors: const [Color(0xFF2E9BFF), Color(0xFF0B5FE0)],
                          glow: const Color(0xFF2E9BFF),
                          onTap: () => _telegram(context),
                        ),
                      ),
                    ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactButton extends StatelessWidget {
  const _ContactButton(
      {super.key,
      required this.icon,
      required this.label,
      required this.colors,
      required this.glow,
      required this.onTap});

  final IconData icon;
  final String label;
  final List<Color> colors;
  final Color glow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.25)),
        boxShadow: [
          BoxShadow(
              color: glow.withOpacity(0.35),
              blurRadius: 16,
              offset: const Offset(0, 6))
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            child: Row(children: [
              Icon(icon, color: Colors.white, size: 26),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label,
                    maxLines: 3,
                    softWrap: true,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        height: 1.2)),
              ),
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.22)),
                child: const Icon(Icons.chevron_right_rounded,
                    color: Colors.white, size: 15),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
