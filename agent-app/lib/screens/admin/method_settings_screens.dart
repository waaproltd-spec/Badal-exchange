import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/management.dart';
import '../../models/payment_methods.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../manage_screens.dart';

/// Payment method management: ON/OFF switches and withdrawal limits, for
/// mobile money and betting platforms alike. There are no rates or fees:
/// every deposit and withdrawal is 1:1 (Dalab Reseller style).

/// Manage Platforms (ON/OFF): one switch per payment method.
class ManageMethodsScreen extends StatefulWidget {
  const ManageMethodsScreen({super.key});

  @override
  State<ManageMethodsScreen> createState() => _ManageMethodsScreenState();
}

class _ManageMethodsScreenState extends ListScreenState<ManageMethodsScreen, MethodSettings> {
  @override
  Future<List<MethodSettings>> fetch() => api.getMethodSettings();

  Widget _group(String title, List<MethodSettings> methods) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GroupLabel(title),
        ConsoleCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              for (final m in methods)
                SwitchListTile(
                  secondary: MethodLogo(method: m.method, width: 84),
                  title: Text(m.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(m.enabled ? 'ON — customers can use it' : 'OFF — hidden from customers'),
                  value: m.enabled,
                  onChanged: (v) => run(
                    () => api.setMethodEnabled(m.method, v),
                    success: '${m.label} turned ${v ? 'ON' : 'OFF'}.',
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Platforms')),
      body: body(
        builder: (methods) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'A platform turned OFF is hidden from customers and refuses new orders. '
                'Orders already in progress still complete.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            _group('Mobile money', methods.where((m) => !m.isPlatform).toList()),
            _group('Betting platforms', methods.where((m) => m.isPlatform).toList()),
          ],
        ),
      ),
    );
  }
}

/// What the overview emphasizes.
enum MethodFocus { all, limits }

/// Lists methods with their current settings; tap one to edit it.
/// [kind] narrows to 'mobile_money' or 'platform'.
class MethodSettingsListScreen extends StatefulWidget {
  final String title;
  final String? kind;
  final MethodFocus focus;

  const MethodSettingsListScreen({super.key, required this.title, this.kind, this.focus = MethodFocus.all});

  @override
  State<MethodSettingsListScreen> createState() => _MethodSettingsListScreenState();
}

class _MethodSettingsListScreenState extends ListScreenState<MethodSettingsListScreen, MethodSettings> {
  @override
  Future<List<MethodSettings>> fetch() async {
    final all = await api.getMethodSettings();
    return widget.kind == null ? all : all.where((m) => m.kind == widget.kind).toList();
  }

  List<String> _summary(MethodSettings m) =>
      ['Withdraw limits: \$${m.minWithdraw ?? '—'} – \$${m.maxWithdraw ?? '—'}'];

  Future<void> _open(MethodSettings m) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => MethodSettingsScreen(settings: m)),
    );
    if (changed == true) load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: body(
        builder: (methods) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final m in methods) ...[
              ConsoleCard(
                onTap: () => _open(m),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    MethodLogo(method: m.method),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(m.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                              ),
                              StatusPill(m.enabled ? 'active' : 'off'),
                            ],
                          ),
                          const SizedBox(height: 4),
                          for (final line in _summary(m))
                            Text(line, style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
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

/// Edit one method: ON/OFF, minimum and maximum withdrawal. Only changed
/// values are saved.
class MethodSettingsScreen extends StatefulWidget {
  final MethodSettings settings;
  const MethodSettingsScreen({super.key, required this.settings});

  @override
  State<MethodSettingsScreen> createState() => _MethodSettingsScreenState();
}

class _MethodSettingsScreenState extends State<MethodSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late bool _enabled = widget.settings.enabled;
  late final _min = TextEditingController(text: widget.settings.minWithdraw ?? '');
  late final _max = TextEditingController(text: widget.settings.maxWithdraw ?? '');
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_min, _max]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _positive(String? v) {
    final n = double.tryParse((v ?? '').trim());
    return (n == null || n <= 0) ? 'Enter a number above 0' : null;
  }

  String? _nonNegative(String? v) {
    final n = double.tryParse((v ?? '').trim());
    return (n == null || n < 0) ? 'Enter 0 or more' : null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final s = widget.settings;
    final api = context.read<Session>().api;
    final m = s.method;
    double d(TextEditingController c) => double.parse(c.text.trim());

    final min = d(_min), max = d(_max);
    if (min > max) {
      showSnack(context, 'Minimum must not be more than maximum.');
      return;
    }

    setState(() => _saving = true);
    try {
      if (_enabled != s.enabled) await api.setMethodEnabled(m, _enabled);
      if (_min.text.trim() != (s.minWithdraw ?? '') || _max.text.trim() != (s.maxWithdraw ?? '')) {
        await api.setWithdrawalLimits(m, min: min, max: max);
      }
      if (!mounted) return;
      showSnack(context, '${s.label} settings saved.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorText(e, 'Could not save all settings. Pull to refresh and check.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      appBar: AppBar(title: Text(s.label)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ConsoleCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SwitchListTile(
                secondary: MethodLogo(method: s.method, width: 84),
                title: Text(s.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                  '${s.isPlatform ? 'Betting platform' : 'Mobile money'} • ${_enabled ? 'ON' : 'OFF'}',
                ),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            ),
            const GroupLabel('Withdrawal limits'),
            ConsoleCard(
              child: Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _min,
                      decoration: const InputDecoration(labelText: 'Minimum (\$)'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: _nonNegative,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _max,
                      decoration: const InputDecoration(labelText: 'Maximum (\$)'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: _positive,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Deposits and withdrawals are 1:1 with no fee: the customer gets exactly the amount sent.',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
          ],
        ),
      ),
    );
  }
}
