import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/management.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';
import '../../l10n/tr.dart';

/// Payment integrations: the EVC Plus and MobCash/WinWin manager accounts.
/// Credentials are stored encrypted on the server; the password is
/// write-only and never shown again.
class IntegrationsScreen extends StatefulWidget {
  const IntegrationsScreen({super.key});

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends ListScreenState<IntegrationsScreen, PaymentIntegration> {
  @override
  Future<List<PaymentIntegration>> fetch() => api.getIntegrations();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Tx('Payment Integrations')),
      body: body(
        builder: (items) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final i in items) ...[
              ConsoleCard(
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => IntegrationDetailScreen(provider: i.provider)),
                  );
                  if (mounted) load();
                },
                child: Row(
                  children: [
                    TintedIcon(
                      icon: i.isMobCash ? Icons.casino_rounded : Icons.phone_android_rounded,
                      color: i.isActive ? AppColors.statusCompleted : AppColors.textFaint,
                      size: 44,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Tx(i.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                          Tx(
                            i.hasCredentials ? 'Account: ${i.username ?? 'set'}' : tr('No credentials saved'),
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                          ),
                          if (i.isMobCash)
                            Text(
                              trp('Automation: {0}{1}', [i.automationMode, i.automationMode == 'automatic' && i.dryRun ? ' (dry run)' : '']),
                              style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                            ),
                        ],
                      ),
                    ),
                    StatusPill(i.isActive ? 'active' : 'inactive'),
                    Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
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

class IntegrationDetailScreen extends StatefulWidget {
  final String provider;
  const IntegrationDetailScreen({super.key, required this.provider});

  @override
  State<IntegrationDetailScreen> createState() => _IntegrationDetailScreenState();
}

class _IntegrationDetailScreenState extends State<IntegrationDetailScreen> {
  PaymentIntegration? _data;
  List<AutomationRun>? _runs;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Session>().api;
    try {
      final data = await api.getIntegration(widget.provider);
      final runs = data.isMobCash ? await api.getAutomationRuns(widget.provider) : null;
      if (mounted) setState(() {
        _data = data;
        _runs = runs;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, tr('Failed to load the integration.')));
    }
  }

  Future<void> _act(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showSnack(context, success);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, tr('Something went wrong.')));
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _editCredentials(PaymentIntegration d) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _CredentialsScreen(integration: d)),
    );
    if (saved == true) _load();
  }

  Future<void> _showScreenshot(AutomationRun run) async {
    try {
      final b64 = await context.read<Session>().api.getAutomationRunScreenshot(widget.provider, run.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.all(12),
          child: InteractiveViewer(child: Image.memory(base64Decode(b64))),
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, tr('Could not load the screenshot.')));
    }
  }

  Future<void> _goLive() async {
    final ok = await confirmDialog(
      context,
      tr('Turn dry run OFF?'),
      tr('Automation will start moving real money on MobCash. Only do this after reviewing the dry-run log below.'),
    );
    if (!ok || !mounted) return;
    final api = context.read<Session>().api;
    await _act(() => api.setAutomationMode(widget.provider, mode: 'automatic', dryRun: false), tr('Automation is live.'));
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(title: Tx(d?.label ?? tr('Integration'))),
      body: d == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : RefreshIndicator(onRefresh: _load, child: _body(d)),
    );
  }

  Widget _body(PaymentIntegration d) {
    final api = context.read<Session>().api;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ConsoleCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SwitchListTile(
            title: const Tx('Integration active', style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Tx(d.isActive ? 'Active' : tr('Inactive')),
            value: d.isActive,
            onChanged: _busy
                ? null
                : (v) => _act(() => api.setIntegrationActive(d.provider, v), v ? 'Activated.' : tr('Deactivated.')),
          ),
        ),
        GroupLabel(tr('Account')),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InfoRow(tr('Username'), d.hasCredentials ? (d.username ?? tr('Saved')) : tr('Not set')),
              InfoRow(tr('Password'), d.hasCredentials ? 'Saved (hidden)' : tr('Not set')),
              InfoRow(tr('Last test'), d.lastTestAt != null ? '${d.lastTestResult ?? '—'} • ${formatDateTime(d.lastTestAt!)}' : '—'),
              if ((d.lastTestMessage ?? '').isNotEmpty) InfoRow(tr('Test message'), d.lastTestMessage!),
              InfoRow(
                tr('Last connected'),
                d.lastSuccessfulConnectionAt != null ? formatDateTime(d.lastSuccessfulConnectionAt!) : '—',
              ),
              InfoRow(tr('Last transaction'), d.lastTransactionAt != null ? formatDateTime(d.lastTransactionAt!) : '—'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _editCredentials(d),
                      child: Tx(d.hasCredentials ? 'Change credentials' : tr('Set credentials')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _busy || !d.hasCredentials
                          ? null
                          : () => _act(() => api.testIntegration(d.provider), tr('Connection test finished.')),
                      child: const Tx('Test connection'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (d.isMobCash) ...[
          GroupLabel(tr('Automation (MobCash browser automation)')),
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Tx(
                  'There is no official MobCash API: automatic mode drives the real MobCash web portal. It always '
                  'starts in dry run (nothing is submitted) and must be reviewed before going live.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                InfoRow(tr('Mode'), d.automationMode == 'automatic' ? 'Automatic' : tr('Manual')),
                InfoRow(tr('Dry run'), d.dryRun ? 'On (no real money moves)' : tr('Off (live)')),
                InfoRow(tr('Failures in a row'), '${d.consecutiveFailures}'),
                InfoRow(
                  tr('Circuit breaker'),
                  d.circuitBreakerTrippedAt != null
                      ? trp('Tripped {0}{1}', [formatDateTime(d.circuitBreakerTrippedAt!), d.circuitBreakerReason != null ? ' — ${d.circuitBreakerReason}' : ''])
                      : 'OK',
                ),
                const SizedBox(height: 8),
                if (d.automationMode == 'manual')
                  ElevatedButton(
                    onPressed: _busy || !d.hasCredentials
                        ? null
                        : () => _act(
                              () => api.setAutomationMode(d.provider, mode: 'automatic', dryRun: true),
                              tr('Automatic mode on (dry run).'),
                            ),
                    child: const Tx('Enable automatic (dry run)'),
                  ),
                if (d.automationMode == 'automatic' && d.dryRun)
                  ElevatedButton(
                    onPressed: _busy || d.circuitBreakerTrippedAt != null ? null : _goLive,
                    child: const Tx('Turn dry run OFF (go live)'),
                  ),
                if (d.automationMode == 'automatic' && !d.dryRun)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _act(
                              () => api.setAutomationMode(d.provider, mode: 'automatic', dryRun: true),
                              tr('Back to dry run.'),
                            ),
                    child: const Tx('Back to dry run'),
                  ),
                if (d.automationMode == 'automatic')
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _act(
                              () => api.setAutomationMode(d.provider, mode: 'manual', dryRun: true),
                              tr('Back to manual mode.'),
                            ),
                    child: const Tx('Switch to manual'),
                  ),
                if (d.circuitBreakerTrippedAt != null)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _act(() => api.resetCircuitBreaker(d.provider), tr('Circuit breaker reset.')),
                    child: const Tx('Reset circuit breaker'),
                  ),
              ],
            ),
          ),
          GroupLabel(tr('Automation runs')),
          if (_runs == null || _runs!.isEmpty)
            ConsoleCard(child: Tx('No runs yet.', style: TextStyle(color: AppColors.textSecondary)))
          else
            for (final r in _runs!.take(50)) ...[
              ConsoleCard(
                onTap: r.hasScreenshot ? () => _showScreenshot(r) : null,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Tx(r.runType.replaceAll('_', ' '), style: const TextStyle(fontWeight: FontWeight.w700)),
                          if ((r.message ?? '').isNotEmpty)
                            Tx(r.message!, style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                          if (r.finishedAt != null)
                            Tx(formatDateTime(r.finishedAt!), style: TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
                        ],
                      ),
                    ),
                    if (r.hasScreenshot) Icon(Icons.image_outlined, color: AppColors.textFaint),
                    StatusPill(r.status == 'success' ? 'completed' : (r.status == 'failed' ? 'failed' : 'pending')),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
        ],
      ],
    );
  }
}

class _CredentialsScreen extends StatefulWidget {
  final PaymentIntegration integration;
  const _CredentialsScreen({required this.integration});

  @override
  State<_CredentialsScreen> createState() => _CredentialsScreenState();
}

class _CredentialsScreenState extends State<_CredentialsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _username = TextEditingController(text: widget.integration.username ?? '');
  final _password = TextEditingController();
  bool _busy = false;
  MobCashLoginCheck? _check;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _checkLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _check = null;
    });
    try {
      final result = await context.read<Session>().api.checkMobCashLogin(
            username: _username.text.trim(),
            password: _password.text,
          );
      if (mounted) setState(() => _check = result);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, tr('Login check failed.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await context.read<Session>().api.saveIntegrationCredentials(
            widget.integration.provider,
            username: _username.text.trim(),
            password: _password.text,
          );
      if (!mounted) return;
      showSnack(context, tr('Credentials saved.'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, errorText(e, tr('Could not save credentials.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.integration;
    return Scaffold(
      appBar: AppBar(title: Text(trp('{0} credentials', [i.label]))),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Tx(
              'Stored encrypted on the server. The password is write-only — it is never shown again.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _username,
              decoration: InputDecoration(labelText: tr('Username')),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              decoration: InputDecoration(labelText: tr('Password')),
              obscureText: true,
              validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
            ),
            if (i.isMobCash) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _busy ? null : _checkLogin,
                icon: const Icon(Icons.login_rounded),
                label: const Tx('Check MobCash login first'),
              ),
              if (_check != null) ...[
                const SizedBox(height: 10),
                ConsoleCard(
                  color: (_check!.success ? AppColors.statusCompleted : AppColors.statusFailed).withOpacity(0.08),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tx(
                        _check!.success ? 'Login worked' : tr('Login failed'),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Tx(_check!.message, style: TextStyle(color: AppColors.textSecondary)),
                      if (_check!.eposList.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(trp('EPOS accounts: {0}', [_check!.eposList.join(', ')])),
                      ],
                    ],
                  ),
                ),
              ],
            ],
            const SizedBox(height: 20),
            ElevatedButton(onPressed: _busy ? null : _save, child: Tx(_busy ? 'Working…' : tr('Save credentials'))),
          ],
        ),
      ),
    );
  }
}
