import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/console.dart';
import '../../models/management.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';

/// Audit log: every management change and money-moving action, newest first.
class AuditLogsScreen extends StatefulWidget {
  const AuditLogsScreen({super.key});

  @override
  State<AuditLogsScreen> createState() => _AuditLogsScreenState();
}

class _AuditLogsScreenState extends ListScreenState<AuditLogsScreen, AuditLog> {
  final _search = TextEditingController();

  @override
  Future<List<AuditLog>> fetch() => api.getAuditLogs();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _details(AuditLog l) {
    String pretty(dynamic v) => v == null ? '—' : const JsonEncoder.withIndent('  ').convert(v);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            Text(l.action, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            InfoRow('When', formatDateTime(l.createdAt)),
            InfoRow('By', '${l.actorRole ?? 'system'} ${l.actorId ?? ''}'.trim()),
            InfoRow('Entity', '${l.entityType} ${l.entityId ?? ''}'.trim()),
            const GroupLabel('Before'),
            SelectableText(pretty(l.before), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const GroupLabel('After'),
            SelectableText(pretty(l.after), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    return Scaffold(
      appBar: AppBar(title: const Text('Audit Logs')),
      body: body(
        builder: (logs) {
          final shown = q.isEmpty
              ? logs
              : logs
                  .where((l) => '${l.action} ${l.entityType} ${l.entityId ?? ''} ${l.actorRole ?? ''}'.toLowerCase().contains(q))
                  .toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SearchField(hint: 'Filter by action or entity', controller: _search, onSubmitted: (_) => setState(() {})),
              const SizedBox(height: 12),
              Text('Latest ${logs.length} entries', style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
              const SizedBox(height: 8),
              for (final l in shown) ...[
                ConsoleCard(
                  onTap: () => _details(l),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      TintedIcon(
                        icon: l.actorRole == 'customer' ? Icons.person_rounded : Icons.admin_panel_settings_rounded,
                        color: l.actorRole == 'customer' ? AppColors.purple : AppColors.accentOrange,
                        size: 34,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.action, style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(
                              '${l.actorRole ?? 'system'} • ${l.entityType} • ${formatDateTime(l.createdAt)}',
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Customer/App settings: the support contact links shown in the apps.
class AppSettingsScreen extends StatefulWidget {
  final Contacts contacts;
  const AppSettingsScreen({super.key, required this.contacts});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _whatsapp = TextEditingController(text: widget.contacts.whatsapp);
  late final _facebook = TextEditingController(text: widget.contacts.facebook);
  late final _telegram = TextEditingController(text: widget.contacts.telegram);
  bool _saving = false;

  @override
  void dispose() {
    _whatsapp.dispose();
    _facebook.dispose();
    _telegram.dispose();
    super.dispose();
  }

  String? _url(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final uri = Uri.tryParse(t);
    return (uri == null || !uri.hasScheme || !uri.hasAuthority) ? 'Enter a full link starting with https://' : null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<Session>().api.saveContacts(Contacts(
            whatsapp: _whatsapp.text.trim(),
            facebook: _facebook.text.trim(),
            telegram: _telegram.text.trim(),
          ));
      if (!mounted) return;
      showSnack(context, 'Settings saved.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorText(e, 'Could not save settings.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customer & App Settings')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const GroupLabel('Support contact links'),
            const Text(
              'Shown on the Account tab here and available to the Customer App. Leave empty to hide.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _whatsapp,
              decoration: const InputDecoration(labelText: 'WhatsApp', hintText: 'https://wa.me/2526...'),
              keyboardType: TextInputType.url,
              validator: _url,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _facebook,
              decoration: const InputDecoration(labelText: 'Facebook', hintText: 'https://facebook.com/...'),
              keyboardType: TextInputType.url,
              validator: _url,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _telegram,
              decoration: const InputDecoration(labelText: 'Telegram', hintText: 'https://t.me/...'),
              keyboardType: TextInputType.url,
              validator: _url,
            ),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
          ],
        ),
      ),
    );
  }
}

/// Every wallet ledger entry for one customer (read-only).
class CustomerLedgerScreen extends StatefulWidget {
  final String customerId;
  final String name;
  const CustomerLedgerScreen({super.key, required this.customerId, required this.name});

  @override
  State<CustomerLedgerScreen> createState() => _CustomerLedgerScreenState();
}

class _CustomerLedgerScreenState extends ListScreenState<CustomerLedgerScreen, LedgerEntry> {
  @override
  Future<List<LedgerEntry>> fetch() => api.getCustomerLedger(widget.customerId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.name} • Wallet')),
      body: body(
        builder: (entries) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (entries.isEmpty)
              const ConsoleCard(child: Text('No wallet transactions yet.', style: TextStyle(color: AppColors.textSecondary))),
            for (final e in entries) ...[
              ConsoleCard(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.description, style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            '${e.type} • ${formatDateTime(e.createdAt)}',
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('\$${e.amount}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        Text('Bal. \$${e.balanceAfter}', style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

/// Latest wallet ledger entries across every customer.
class AllWalletTransactionsScreen extends StatefulWidget {
  const AllWalletTransactionsScreen({super.key});

  @override
  State<AllWalletTransactionsScreen> createState() => _AllWalletTransactionsScreenState();
}

class _AllWalletTransactionsScreenState extends ListScreenState<AllWalletTransactionsScreen, WalletTransaction> {
  @override
  Future<List<WalletTransaction>> fetch() => api.getAllWalletTransactions();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet Transactions')),
      body: body(
        builder: (entries) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Latest ${entries.length} entries, all customers',
                style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
            const SizedBox(height: 8),
            for (final e in entries) ...[
              ConsoleCard(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.reason, style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${e.type} • ${formatDateTime(e.createdAt)}',
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('\$${e.amount}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        Text('Bal. \$${e.balanceAfter}', style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

/// The Telegram cashier bots (supabase/functions/telegram-bot), one per
/// betting brand's cash register: (brand, bot username).
const telegramBots = [
  ('888starz', 'Badal888starzbot'),
  ('1xBet', 'Badal1xbetbot'),
  ('WinWin', 'Badalwinwinbot'),
  ('Betwinner', 'Badalbetwinnerbot'),
  ('DBbet', 'Badaldbbetbot'),
  ('BetJam', 'Badalbetjambot'),
  ('BetOnGame', 'Badalbetongamebot'),
  ('MELBET', 'Badalmelbetbot'),
];

/// Links this manager's Telegram account to the Telegram cashier bots
/// (CashdeskBot balance, player search, deposits and payouts). One link
/// works with every bot.
class TelegramBotScreen extends StatefulWidget {
  const TelegramBotScreen({super.key});

  @override
  State<TelegramBotScreen> createState() => _TelegramBotScreenState();
}

class _TelegramBotScreenState extends State<TelegramBotScreen> {
  TelegramLink? _link;
  TelegramLinkCode? _code;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final link = await context.read<Session>().api.getTelegramLink();
      if (mounted) setState(() => _link = link);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, 'Could not load the Telegram link.'));
    }
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, failure));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newCode() => _run(() async {
        final code = await context.read<Session>().api.createTelegramLinkCode();
        if (mounted) setState(() => _code = code);
      }, 'Could not create a link code.');

  // The bot reads `/start CODE` from this link as `/link CODE`.
  Future<void> _openBot(String bot, String code) async {
    final ok = await launchUrl(Uri.parse('https://t.me/$bot?start=$code'),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) showSnack(context, 'Could not open Telegram.');
  }

  Future<void> _unlink() => _run(() async {
        final link = await context.read<Session>().api.unlinkTelegram();
        if (mounted) setState(() => _link = link);
      }, 'Could not unlink.');

  @override
  Widget build(BuildContext context) {
    final link = _link;
    final code = _code;
    return Scaffold(
      appBar: AppBar(title: const Text('Telegram Bot')),
      body: _error != null
          ? ErrorStateView(message: _error!, onRetry: _load)
          : link == null
              ? const LoadingView()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Text(
                        'The Telegram bots (888starz, 1xBet, WinWin, Betwinner, DBbet, BetJam and BetOnGame) check their cash register balance, find players, and '
                        'make deposits and payouts. They act as you, and stop working for you if you lose '
                        'access to Admin features. Linking once works with every bot.',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                      const GroupLabel('Status'),
                      InfoRow('Linked', link.linked ? 'Yes' : 'No'),
                      if (link.telegramUsername != null) InfoRow('Telegram', '@${link.telegramUsername}'),
                      if (link.linkedAt != null) InfoRow('Since', formatDateTime(link.linkedAt!)),
                      const GroupLabel('Link your Telegram account'),
                      if (code != null) ...[
                        for (final (brand, bot) in telegramBots) ...[
                          ElevatedButton.icon(
                            onPressed: () => _openBot(bot, code.code),
                            icon: const Icon(Icons.send_rounded),
                            label: Text('Open @$bot ($brand)'),
                          ),
                          const SizedBox(height: 8),
                        ],
                        const SizedBox(height: 4),
                        const Text('Or send this message to either bot in Telegram:'),
                        const SizedBox(height: 8),
                        SelectableText('/link ${code.code}',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 20, fontWeight: FontWeight.w800)),
                        if (code.expiresAt != null) ...[
                          const SizedBox(height: 4),
                          Text('Valid until ${formatDateTime(code.expiresAt!)}, once.',
                              style: const TextStyle(color: AppColors.textSecondary)),
                        ],
                        const SizedBox(height: 12),
                      ],
                      ElevatedButton(
                        onPressed: _busy ? null : _newCode,
                        child: Text(code == null ? 'Get link code' : 'Get a new code'),
                      ),
                      if (link.linked) ...[
                        const SizedBox(height: 12),
                        OutlinedButton(onPressed: _busy ? null : _unlink, child: const Text('Unlink Telegram')),
                      ],
                    ],
                  ),
                ),
    );
  }
}

/// The promo code every customer sees on their wallet card in the Customer
/// App. Empty means no promo code (customers see a dash).
class PromoCodeScreen extends StatefulWidget {
  const PromoCodeScreen({super.key});

  @override
  State<PromoCodeScreen> createState() => _PromoCodeScreenState();
}

class _PromoCodeScreenState extends State<PromoCodeScreen> {
  final _code = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final code = await context.read<Session>().api.getPromoCode();
      if (!mounted) return;
      setState(() {
        _code.text = code ?? '';
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e, 'Could not load the promo code.');
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final saved = await context.read<Session>().api.setPromoCode(_code.text);
      if (!mounted) return;
      _code.text = saved ?? '';
      showSnack(context, saved == null ? 'Promo code removed.' : 'Promo code saved: $saved');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Could not save the promo code.'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Promo Code')),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorStateView(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'Shown to every customer on the wallet card in the Customer App, with a copy button. '
                      'Letters, digits, - and _ only. Leave empty for no promo code.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _code,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 32,
                      decoration: const InputDecoration(labelText: 'Promo code', hintText: 'e.g. RAMADAN26'),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
                  ],
                ),
    );
  }
}
