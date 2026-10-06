import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/console.dart';
import '../../models/management.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
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
