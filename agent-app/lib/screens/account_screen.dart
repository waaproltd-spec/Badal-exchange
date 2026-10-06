import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../models/payment_methods.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';
import 'login_screen.dart';
import 'manage_screens.dart';

/// Account: agent profile, admin features (only for agents an admin granted
/// 'manage_settings'), bet payment method switches, contact links and
/// security (password, logout).
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  AgentAccount? _account;
  List<ManagedMethod>? _methods;
  final Set<String> _toggling = {};
  String? _error;
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final api = context.read<Session>().api;
    try {
      final account = await api.getAccount();
      final methods = account.canManageSettings ? await api.getManagedMethods() : null;
      if (!mounted) return;
      setState(() {
        _account = account;
        _methods = methods;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Failed to load account.');
    }
  }

  Future<void> _toggleMethod(ManagedMethod m, bool enabled) async {
    setState(() => _toggling.add(m.method));
    try {
      await context.read<Session>().api.setMethodEnabled(m.method, enabled);
      if (!mounted) return;
      setState(() {
        _methods = [
          for (final x in _methods!) x.method == m.method ? ManagedMethod(x.method, x.label, x.kind, enabled) : x,
        ];
      });
    } catch (e) {
      if (mounted) _snack(e is ApiException ? e.message : 'Could not update ${m.label}.');
    } finally {
      if (mounted) setState(() => _toggling.remove(m.method));
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  Future<void> _openLink(String label, String url) async {
    final uri = Uri.tryParse(url);
    if (url.isEmpty || uri == null || !uri.hasScheme) {
      _snack('No $label link set yet.');
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) _snack('Could not open $label.');
  }

  Future<void> _editContacts(Contacts current) async {
    final updated = await showDialog<Contacts>(context: context, builder: (_) => _ContactsDialog(initial: current));
    if (updated == null || !mounted) return;
    try {
      await context.read<Session>().api.saveContacts(updated);
      _snack('Contact links saved.');
      _load();
    } catch (e) {
      _snack(e is ApiException ? e.message : 'Could not save contact links.');
    }
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('Automatic SMS matching stops on this device until you log in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Log out', style: TextStyle(color: AppColors.statusFailed)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _loggingOut = true);
    await context.read<Session>().logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    if (account == null) {
      return _error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView();
    }
    final canManage = account.canManageSettings;
    final betMethods = _methods?.where((m) => m.kind == 'platform').toList() ?? const <ManagedMethod>[];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _ProfileCard(account: account),

          const GroupLabel('Admin features'),
          if (canManage) ...[
            _NavRow(
              icon: Icons.toggle_on_rounded,
              color: AppColors.purple,
              label: 'Manage Platforms (ON/OFF)',
              onTap: () => _open(const ManageMethodsScreen(kind: 'mobile_money')),
            ),
            _NavRow(
              icon: Icons.campaign_rounded,
              color: AppColors.accentOrange,
              label: 'Manage Home Ads',
              onTap: () => _open(const ManageHomeAdsScreen()),
            ),
            _NavRow(
              icon: Icons.phone_in_talk_rounded,
              color: AppColors.statusCompleted,
              label: 'Manage Deposit Numbers',
              onTap: () => _open(const ManageDepositNumbersScreen()),
            ),
            _NavRow(
              icon: Icons.notifications_active_rounded,
              color: AppColors.statusProcessing,
              label: 'Send Notification',
              onTap: () => _open(const SendNotificationScreen()),
            ),
          ] else
            const _LockedNote(),

          const GroupLabel('Bet payment methods'),
          if (canManage)
            ConsoleCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (final m in betMethods)
                    ListTile(
                      leading: MethodBadge(method: m.method, size: 36),
                      title: Text(m.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(m.enabled ? 'ON — customers can use it' : 'OFF — hidden from customers'),
                      trailing: _toggling.contains(m.method)
                          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                          : Switch(value: m.enabled, onChanged: (v) => _toggleMethod(m, v)),
                    ),
                ],
              ),
            )
          else
            const _LockedNote(),

          Row(
            children: [
              const Expanded(child: GroupLabel('Contact')),
              if (canManage)
                TextButton.icon(
                  onPressed: () => _editContacts(account.contacts),
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: const Text('Edit'),
                ),
            ],
          ),
          _NavRow(
            icon: Icons.chat_rounded,
            color: const Color(0xFF25D366),
            label: 'WhatsApp',
            trailing: Icons.open_in_new_rounded,
            onTap: () => _openLink('WhatsApp', account.contacts.whatsapp),
          ),
          _NavRow(
            icon: Icons.facebook_rounded,
            color: const Color(0xFF1877F2),
            label: 'Facebook',
            trailing: Icons.open_in_new_rounded,
            onTap: () => _openLink('Facebook', account.contacts.facebook),
          ),
          _NavRow(
            icon: Icons.send_rounded,
            color: const Color(0xFF229ED9),
            label: 'Telegram',
            trailing: Icons.open_in_new_rounded,
            onTap: () => _openLink('Telegram', account.contacts.telegram),
          ),

          const GroupLabel('Security'),
          _NavRow(
            icon: Icons.lock_rounded,
            color: AppColors.purple,
            label: 'Change Password',
            onTap: () => _open(const ChangePasswordScreen()),
          ),
          const SizedBox(height: 4),
          ConsoleCard(
            onTap: _loggingOut ? null : _confirmLogout,
            color: AppColors.statusFailed.withOpacity(0.06),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                _loggingOut
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.logout_rounded, color: AppColors.statusFailed),
                const SizedBox(width: 14),
                const Text('Logout', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.statusFailed)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final AgentAccount account;
  const _ProfileCard({required this.account});

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      child: Row(
        children: [
          const TintedIcon(icon: Icons.verified_user_rounded, color: AppColors.accentOrange, size: 56),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.name,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  account.email ?? account.phone ?? '—',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.lightGold,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Agent',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: AppColors.purpleDark),
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusPill(account.status),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final IconData trailing;
  final VoidCallback onTap;

  const _NavRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.trailing = Icons.chevron_right_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ConsoleCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            TintedIcon(icon: icon, color: color, size: 36),
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
            Icon(trailing, color: AppColors.textFaint, size: 20),
          ],
        ),
      ),
    );
  }
}

class _LockedNote extends StatelessWidget {
  const _LockedNote();

  @override
  Widget build(BuildContext context) {
    return const ConsoleCard(
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, color: AppColors.textFaint),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Your account does not have access to these settings. Ask an admin to grant the '
              '"manage_settings" responsibility.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactsDialog extends StatefulWidget {
  final Contacts initial;
  const _ContactsDialog({required this.initial});

  @override
  State<_ContactsDialog> createState() => _ContactsDialogState();
}

class _ContactsDialogState extends State<_ContactsDialog> {
  late final _whatsapp = TextEditingController(text: widget.initial.whatsapp);
  late final _facebook = TextEditingController(text: widget.initial.facebook);
  late final _telegram = TextEditingController(text: widget.initial.telegram);

  @override
  void dispose() {
    _whatsapp.dispose();
    _facebook.dispose();
    _telegram.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Contact links'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _whatsapp,
              decoration: const InputDecoration(labelText: 'WhatsApp', hintText: 'https://wa.me/2526...'),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _facebook,
              decoration: const InputDecoration(labelText: 'Facebook', hintText: 'https://facebook.com/...'),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _telegram,
              decoration: const InputDecoration(labelText: 'Telegram', hintText: 'https://t.me/...'),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(Contacts(
            whatsapp: _whatsapp.text.trim(),
            facebook: _facebook.text.trim(),
            telegram: _telegram.text.trim(),
          )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
