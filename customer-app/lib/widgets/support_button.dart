import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/customer_api.dart';
import '../l10n/strings.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import '../utils/support_links.dart';

/// Space to leave under scrolling content so the [SupportButton] never
/// hides its end.
const double supportButtonClearance = 72;

/// A small "Support" pill floating at the bottom-right of [child] (above the
/// bottom navigation). Tapping it opens WhatsApp / Telegram options built
/// from the support contacts admins set in the Agent App; with none set it
/// says so -- it never shows a made-up link. Tapping the pill again or
/// anywhere else closes it.
class SupportButton extends StatefulWidget {
  const SupportButton({super.key, required this.child});

  final Widget child;

  @override
  State<SupportButton> createState() => _SupportButtonState();
}

class _SupportButtonState extends State<SupportButton> {
  bool _open = false;
  Map<String, String>? _contacts;
  bool _failed = false;

  Future<void> _toggle() async {
    setState(() => _open = !_open);
    if (_open && _contacts == null) await _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final contacts = await context.read<CustomerApi>().getSupportContacts();
      if (mounted) setState(() => _contacts = contacts);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _launch(String app, Uri uri) async {
    setState(() => _open = false);
    var ok = false;
    try {
      // WhatsApp / Telegram if installed; otherwise the browser opens the
      // wa.me / t.me page, which offers the web version.
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppStrings.couldNotOpen(app, uri.toString()))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = _contacts;
    final options = [
      for (final (kind, label) in const [('whatsapp', 'WhatsApp'), ('telegram', 'Telegram')])
        if (supportLink(kind, contacts?[kind]) case final uri?) (kind, label, uri),
    ];
    return Stack(
      children: [
        widget.child,
        if (_open)
          Positioned.fill(
            child: GestureDetector(
              key: const Key('support-barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = false),
            ),
          ),
        Positioned(
          right: 16,
          bottom: 12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_open) ...[
                _Menu(
                  loading: contacts == null && !_failed,
                  failed: _failed,
                  options: options,
                  onPick: _launch,
                ),
                const SizedBox(height: 10),
              ],
              _Pill(open: _open, onTap: _toggle),
            ],
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('support-button'),
      color: AppColors.purpleDark,
      elevation: 6,
      shadowColor: AppColors.purpleDark.withOpacity(0.4),
      shape: StadiumBorder(side: BorderSide(color: AppColors.purpleSecondary.withOpacity(0.8), width: 1.5)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.headset_mic_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(AppStrings.support,
                  style: AppTextStyles.body.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
              const SizedBox(width: 4),
              Icon(open ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded,
                  color: Colors.white, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({required this.loading, required this.failed, required this.options, required this.onPick});

  final bool loading;
  final bool failed;
  final List<(String, String, Uri)> options;
  final void Function(String app, Uri uri) onPick;

  @override
  Widget build(BuildContext context) {
    final width = (MediaQuery.of(context).size.width - 32).clamp(0.0, 240.0);
    return Material(
      key: const Key('support-menu'),
      color: AppColors.surface,
      elevation: 8,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: width,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.cardBorder, width: 1.2),
        ),
        child: loading
            ? const Padding(
                padding: EdgeInsets.all(14),
                child:
                    Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))),
              )
            : options.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(failed ? AppStrings.noSupportContacts : AppStrings.supportNotSetUp,
                        key: const Key('support-unavailable'), style: AppTextStyles.muted),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (kind, label, uri) in options)
                        _Option(kind: kind, label: label, onTap: () => onPick(label, uri)),
                    ],
                  ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.kind, required this.label, required this.onTap});

  final String kind;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final whatsapp = kind == 'whatsapp';
    return InkWell(
      key: Key('support-$kind'),
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            // The official marks: WhatsApp's white glyph on its green, and
            // Telegram's blue circle with the white plane.
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: whatsapp ? const Color(0xFF25D366) : Colors.white,
                shape: BoxShape.circle,
              ),
              child: FaIcon(
                whatsapp ? FontAwesomeIcons.whatsapp : FontAwesomeIcons.telegram,
                color: whatsapp ? Colors.white : const Color(0xFF26A5E4),
                size: whatsapp ? 24 : 40,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700)),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
