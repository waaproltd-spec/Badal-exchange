import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';
import 'login_screen.dart';
import 'admin/agents_screens.dart';
import 'admin/exchange_screens.dart';
import 'admin/integrations_screens.dart';
import 'admin/method_settings_screens.dart';
import 'admin/system_screens.dart';
import 'manage_screens.dart';

/// Account: profile, admin features (everything the old admin dashboard
/// managed; only for agents granted 'manage_settings'), contact links and
/// security (password, logout).
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  AgentAccount? _account;
  String? _error;
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final account = await context.read<Session>().api.getAccount();
      if (mounted) setState(() => _account = account);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Failed to load account.');
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

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _ProfileCard(account: account),

          const GroupLabel('Admin features'),
          if (!canManage)
            const _LockedNote()
          else ...[
            const _SubLabel('Payments'),
            _NavRow(
              icon: Icons.toggle_on_rounded,
              color: AppColors.purple,
              label: 'Manage Platforms (ON/OFF)',
              onTap: () => _open(const ManageMethodsScreen()),
            ),
            _NavRow(
              icon: Icons.account_balance_wallet_rounded,
              color: AppColors.statusCompleted,
              label: 'Payment Methods',
              onTap: () => _open(const MethodSettingsListScreen(title: 'Payment Methods', kind: 'mobile_money')),
            ),
            _NavRow(
              icon: Icons.sports_soccer_rounded,
              color: AppColors.accentOrange,
              label: 'Bet Payment Methods',
              onTap: () => _open(const MethodSettingsListScreen(title: 'Bet Payment Methods', kind: 'platform')),
            ),
            _NavRow(
              icon: Icons.currency_exchange_rounded,
              color: AppColors.statusProcessing,
              label: 'Rates',
              onTap: () => _open(const MethodSettingsListScreen(title: 'Rates', focus: MethodFocus.rates)),
            ),
            _NavRow(
              icon: Icons.percent_rounded,
              color: AppColors.purple,
              label: 'Fees',
              onTap: () => _open(const MethodSettingsListScreen(title: 'Fees', focus: MethodFocus.fees)),
            ),
            _NavRow(
              icon: Icons.straighten_rounded,
              color: AppColors.statusPending,
              label: 'Minimum & Maximum Limits',
              onTap: () => _open(const MethodSettingsListScreen(title: 'Withdrawal Limits', focus: MethodFocus.limits)),
            ),
            _NavRow(
              icon: Icons.phone_in_talk_rounded,
              color: AppColors.statusCompleted,
              label: 'Manage Deposit Numbers',
              onTap: () => _open(const ManageDepositNumbersScreen()),
            ),
            _NavRow(
              icon: Icons.hub_rounded,
              color: AppColors.statusProcessing,
              label: 'Payment Integrations',
              onTap: () => _open(const IntegrationsScreen()),
            ),
            const _SubLabel('Exchange (EVC Plus ⇄ eDahab)'),
            _NavRow(
              icon: Icons.swap_horiz_rounded,
              color: AppColors.purple,
              label: 'Exchange Orders',
              onTap: () => _open(const ExchangeOrdersScreen()),
            ),
            _NavRow(
              icon: Icons.sms_rounded,
              color: AppColors.statusPending,
              label: 'Payment SMS Review',
              onTap: () => _open(const PaymentSmsReviewScreen()),
            ),
            _NavRow(
              icon: Icons.tune_rounded,
              color: AppColors.statusProcessing,
              label: 'Exchange Settings (wallets, PIN, rates)',
              onTap: () => _open(const ExchangeSettingsScreen()),
            ),
            const _SubLabel('Customer App'),
            _NavRow(
              icon: Icons.campaign_rounded,
              color: AppColors.accentOrange,
              label: 'Manage Home Ads',
              onTap: () => _open(const ManageHomeAdsScreen()),
            ),
            _NavRow(
              icon: Icons.notifications_active_rounded,
              color: AppColors.statusProcessing,
              label: 'Send Notifications',
              onTap: () => _open(const SendNotificationScreen()),
            ),
            _NavRow(
              icon: Icons.settings_rounded,
              color: AppColors.textSecondary,
              label: 'Customer & App Settings',
              onTap: () => _open(AppSettingsScreen(contacts: account.contacts)),
            ),
            const _SubLabel('Team & system'),
            _NavRow(
              icon: Icons.groups_rounded,
              color: AppColors.purple,
              label: 'Agents',
              onTap: () => _open(const AgentsScreen()),
            ),
            _NavRow(
              icon: Icons.receipt_long_rounded,
              color: AppColors.statusCompleted,
              label: 'Wallet Transactions',
              onTap: () => _open(const AllWalletTransactionsScreen()),
            ),
            _NavRow(
              icon: Icons.fact_check_rounded,
              color: AppColors.textSecondary,
              label: 'Audit Logs',
              onTap: () => _open(const AuditLogsScreen()),
            ),
          ],

          const GroupLabel('Contact'),
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

class _SubLabel extends StatelessWidget {
  final String text;
  const _SubLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.purple)),
    );
  }
}
