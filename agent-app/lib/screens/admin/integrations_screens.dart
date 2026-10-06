import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/management.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';

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
      appBar: AppBar(title: const Text('Payment Integrations')),
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
                          Text(i.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                          Text(
                            i.hasCredentials ? 'Account: ${i.username ?? 'set'}' : 'No credentials saved',
                            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                          ),
                          if (i.isMobCash)
                            Text(
                              'Automation: ${i.automationMode}${i.automationMode == 'automatic' && i.dryRun ? ' (dry run)' : ''}',
                              style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                            ),
                        ],
                      ),
                    ),
                    StatusPill(i.isActive ? 'active' : 'inactive'),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
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
      if (mounted) setState(() => _error = errorText(e, 'Failed to load the integration.'));
    }
  }

  Future<void> _act(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showSnack(context, success);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Something went wrong.'));
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
      if (mounted) showSnack(context, errorText(e, 'Could not load the screenshot.'));
    }
  }

  Future<void> _goLive() async {
    final ok = await confirmDialog(
      context,
      'Turn dry run OFF?',
      'Automation will start moving real money on MobCash. Only do this after reviewing the dry-run log below.',
    );
    if (!ok || !mounted) return;
    final api = context.read<Session>().api;
    await _act(() => api.setAutomationMode(widget.provider, mode: 'automatic', dryRun: false), 'Automation is live.');
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(title: Text(d?.label ?? 'Integration')),
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
            title: const Text('Integration active', style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(d.isActive ? 'Active' : 'Inactive'),
            value: d.isActive,
            onChanged: _busy
                ? null
                : (v) => _act(() => api.setIntegrationActive(d.provider, v), v ? 'Activated.' : 'Deactivated.'),
          ),
        ),
        const GroupLabel('Account'),
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InfoRow('Username', d.hasCredentials ? (d.username ?? 'Saved') : 'Not set'),
              InfoRow('Password', d.hasCredentials ? 'Saved (hidden)' : 'Not set'),
              InfoRow('Last test', d.lastTestAt != null ? '${d.lastTestResult ?? '—'} • ${formatDateTime(d.lastTestAt!)}' : '—'),
              if ((d.lastTestMessage ?? '').isNotEmpty) InfoRow('Test message', d.lastTestMessage!),
              InfoRow(
                'Last connected',
                d.lastSuccessfulConnectionAt != null ? formatDateTime(d.lastSuccessfulConnectionAt!) : '—',
              ),
              InfoRow('Last transaction', d.lastTransactionAt != null ? formatDateTime(d.lastTransactionAt!) : '—'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _editCredentials(d),
                      child: Text(d.hasCredentials ? 'Change credentials' : 'Set credentials'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _busy || !d.hasCredentials
                          ? null
                          : () => _act(() => api.testIntegration(d.provider), 'Connection test finished.'),
                      child: const Text('Test connection'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (d.isMobCash) ...[
          const GroupLabel('Automation (MobCash browser automation)'),
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'There is no official MobCash API: automatic mode drives the real MobCash web portal. It always '
                  'starts in dry run (nothing is submitted) and must be reviewed before going live.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                InfoRow('Mode', d.automationMode == 'automatic' ? 'Automatic' : 'Manual'),
                InfoRow('Dry run', d.dryRun ? 'On (no real money moves)' : 'Off (live)'),
                InfoRow('Failures in a row', '${d.consecutiveFailures}'),
                InfoRow(
                  'Circuit breaker',
                  d.circuitBreakerTrippedAt != null
                      ? 'Tripped ${formatDateTime(d.circuitBreakerTrippedAt!)}${d.circuitBreakerReason != null ? ' — ${d.circuitBreakerReason}' : ''}'
                      : 'OK',
                ),
                const SizedBox(height: 8),
                if (d.automationMode == 'manual')
                  ElevatedButton(
                    onPressed: _busy || !d.hasCredentials
                        ? null
                        : () => _act(
                              () => api.setAutomationMode(d.provider, mode: 'automatic', dryRun: true),
                              'Automatic mode on (dry run).',
                            ),
                    child: const Text('Enable automatic (dry run)'),
                  ),
                if (d.automationMode == 'automatic' && d.dryRun)
                  ElevatedButton(
                    onPressed: _busy || d.circuitBreakerTrippedAt != null ? null : _goLive,
                    child: const Text('Turn dry run OFF (go live)'),
                  ),
                if (d.automationMode == 'automatic' && !d.dryRun)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _act(
                              () => api.setAutomationMode(d.provider, mode: 'automatic', dryRun: true),
                              'Back to dry run.',
                            ),
                    child: const Text('Back to dry run'),
                  ),
                if (d.automationMode == 'automatic')
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _act(
                              () => api.setAutomationMode(d.provider, mode: 'manual', dryRun: true),
                              'Back to manual mode.',
                            ),
                    child: const Text('Switch to manual'),
                  ),
                if (d.circuitBreakerTrippedAt != null)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _act(() => api.resetCircuitBreaker(d.provider), 'Circuit breaker reset.'),
                    child: const Text('Reset circuit breaker'),
                  ),
              ],
            ),
          ),
          const GroupLabel('Automation runs'),
          if (_runs == null || _runs!.isEmpty)
            const ConsoleCard(child: Text('No runs yet.', style: TextStyle(color: AppColors.textSecondary)))
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
                          Text(r.runType.replaceAll('_', ' '), style: const TextStyle(fontWeight: FontWeight.w700)),
                          if ((r.message ?? '').isNotEmpty)
                            Text(r.message!, style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                          if (r.finishedAt != null)
                            Text(formatDateTime(r.finishedAt!), style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
                        ],
                      ),
                    ),
                    if (r.hasScreenshot) const Icon(Icons.image_outlined, color: AppColors.textFaint),
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
      if (mounted) showSnack(context, errorText(e, 'Login check failed.'));
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
      showSnack(context, 'Credentials saved.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, errorText(e, 'Could not save credentials.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.integration;
    return Scaffold(
      appBar: AppBar(title: Text('${i.label} credentials')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Stored encrypted on the server. The password is write-only — it is never shown again.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Username'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
              validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
            ),
            if (i.isMobCash) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _busy ? null : _checkLogin,
                icon: const Icon(Icons.login_rounded),
                label: const Text('Check MobCash login first'),
              ),
              if (_check != null) ...[
                const SizedBox(height: 10),
                ConsoleCard(
                  color: (_check!.success ? AppColors.statusCompleted : AppColors.statusFailed).withOpacity(0.08),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _check!.success ? 'Login worked' : 'Login failed',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(_check!.message, style: const TextStyle(color: AppColors.textSecondary)),
                      if (_check!.eposList.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('EPOS accounts: ${_check!.eposList.join(', ')}'),
                      ],
                    ],
                  ),
                ),
              ],
            ],
            const SizedBox(height: 20),
            ElevatedButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Working…' : 'Save credentials')),
          ],
        ),
      ),
    );
  }
}
