import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/customer_api.dart';
import '../l10n/strings.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import '../utils/support_links.dart';

/// Shows the Account Blocked card (over the login screen): what happened, and a Contact Support button.
Future<void> showAccountBlocked(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const AccountBlockedDialog(),
    );

/// "Account Blocked": a red lock, the message from the administrator, and a button that opens the support
/// contact (WhatsApp or Telegram) the administrators set in the Agent App.
class AccountBlockedDialog extends StatefulWidget {
  const AccountBlockedDialog({super.key});

  @override
  State<AccountBlockedDialog> createState() => _AccountBlockedDialogState();
}

class _AccountBlockedDialogState extends State<AccountBlockedDialog> {
  bool _busy = false;

  Future<void> _open(Uri uri) async {
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppStrings.couldNotOpen(uri.host, uri.toString()))));
    }
  }

  Future<void> _contact() async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, String> contacts = const {};
    try {
      contacts = await context.read<CustomerApi>().getSupportContacts();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
    final options = [
      for (final (kind, label) in const [
        ('whatsapp', 'WhatsApp'),
        ('telegram', 'Telegram'),
        ('facebook', 'Facebook')
      ])
        // Telegram is always the support bot; WhatsApp and Facebook are the contacts the administrators set.
        if (kind == 'telegram')
          (label, Uri.parse('https://t.me/Badalaisupportbot'))
        else if (supportLink(kind, contacts[kind]) case final uri?)
          (label, uri),
    ];
    if (options.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppStrings.supportNotSet)));
      return;
    }
    if (options.length == 1) {
      await _open(options.first.$2);
      return;
    }
    final picked = await showModalBottomSheet<Uri>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (label, uri) in options)
            ListTile(
              key: Key('support-${label.toLowerCase()}'),
              leading: const Icon(Icons.headset_mic_rounded),
              title: Text(label),
              onTap: () => Navigator.pop(ctx, uri),
            ),
        ]),
      ),
    );
    if (picked != null) await _open(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('account-blocked'),
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                    color: AppColors.error.withOpacity(0.12),
                    shape: BoxShape.circle),
                child:
                    Icon(Icons.lock_rounded, size: 44, color: AppColors.error),
              ),
            ),
            const SizedBox(height: 16),
            Text(AppStrings.accountBlockedTitle,
                key: const Key('blocked-title'),
                textAlign: TextAlign.center,
                style: AppTextStyles.headline.copyWith(fontSize: 26)),
            const SizedBox(height: 10),
            Text(AppStrings.accountBlockedMessage,
                key: const Key('blocked-message'),
                textAlign: TextAlign.center,
                style: AppTextStyles.body.copyWith(fontSize: 16, height: 1.4)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: AppColors.error.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Icon(Icons.headset_mic_rounded,
                    color: AppColors.error, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(AppStrings.accountBlockedHint,
                      key: const Key('blocked-hint'),
                      style: AppTextStyles.body.copyWith(
                          color: AppColors.error,
                          fontWeight: FontWeight.w700,
                          height: 1.35)),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            DecoratedBox(
              decoration: BoxDecoration(
                  gradient: AppColors.headerGradient,
                  borderRadius: BorderRadius.circular(18)),
              child: TextButton.icon(
                key: const Key('blocked-contact'),
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  foregroundColor: AppColors.textOnPrimary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18)),
                ),
                onPressed: _busy ? null : _contact,
                icon: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: Colors.white))
                    : const Icon(Icons.headset_mic_rounded),
                label: Text(AppStrings.contactSupport,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
