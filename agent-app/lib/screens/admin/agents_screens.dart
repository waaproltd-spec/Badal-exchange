import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/management.dart';
import '../../models/order.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/order_card.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';

/// Responsibilities an agent can hold. 'manage_settings' grants every
/// management function (this Account → Admin features area).
const knownResponsibilities = <(String, String)>[
  ('evc_deposit', 'EVC Plus deposits'),
  ('evc_withdraw', 'EVC Plus withdrawals'),
  ('manage_settings', 'Manage settings (admin features)'),
];

String responsibilityLabel(String r) =>
    knownResponsibilities.firstWhere((k) => k.$1 == r, orElse: () => (r, r.replaceAll('_', ' '))).$2;

class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends ListScreenState<AgentsScreen, AgentListItem> {
  @override
  Future<List<AgentListItem>> fetch() => api.getAgents();

  Future<void> _create() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const _CreateAgentScreen()),
    );
    if (created == true) load();
  }

  Future<void> _open(AgentListItem a) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AgentDetailScreen(agent: a)));
    if (mounted) load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agents')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add agent'),
      ),
      body: body(
        builder: (agents) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            for (final a in agents) ...[
              ConsoleCard(
                onTap: () => _open(a),
                child: Row(
                  children: [
                    TintedIcon(
                      icon: a.canManage ? Icons.admin_panel_settings_rounded : Icons.badge_rounded,
                      color: a.canManage ? AppColors.accentOrange : AppColors.purple,
                      size: 44,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                          Text(a.phone ?? '—', style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                          Text(
                            a.lastSeenAt != null ? 'Last seen ${formatDateTime(a.lastSeenAt!)}' : 'Never seen',
                            style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint),
                          ),
                        ],
                      ),
                    ),
                    StatusPill(a.isActive ? 'active' : 'blocked'),
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

class AgentDetailScreen extends StatefulWidget {
  final AgentListItem agent;
  const AgentDetailScreen({super.key, required this.agent});

  @override
  State<AgentDetailScreen> createState() => _AgentDetailScreenState();
}

class _AgentDetailScreenState extends State<AgentDetailScreen> {
  late AgentListItem _agent = widget.agent;
  List<AgentDevice>? _devices;
  List<Order>? _orders;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadExtras();
  }

  Future<void> _loadExtras() async {
    final api = context.read<Session>().api;
    try {
      final results = await Future.wait([api.getAgentDevices(_agent.id), api.getAgentOrders(_agent.id)]);
      if (!mounted) return;
      setState(() {
        _devices = results[0] as List<AgentDevice>;
        _orders = results[1] as List<Order>;
      });
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Could not load devices and orders.'));
    }
  }

  Future<void> _refreshAgent() async {
    final agents = await context.read<Session>().api.getAgents();
    final updated = agents.where((a) => a.id == _agent.id);
    if (mounted && updated.isNotEmpty) setState(() => _agent = updated.first);
  }

  Future<void> _act(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      await _refreshAgent();
      if (mounted) showSnack(context, success);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Something went wrong.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleStatus() async {
    final enable = !_agent.isActive;
    if (!enable) {
      final ok = await confirmDialog(
        context,
        'Disable ${_agent.name}?',
        'They will be signed out and unable to log in until enabled again.',
      );
      if (!ok) return;
    }
    if (!mounted) return;
    final api = context.read<Session>().api;
    await _act(() => api.setAgentEnabled(_agent.id, enable), enable ? 'Agent enabled.' : 'Agent disabled.');
  }

  Future<void> _editResponsibilities() async {
    final selected = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ResponsibilitiesDialog(initial: _agent.responsibilities),
    );
    if (selected == null || !mounted) return;
    final api = context.read<Session>().api;
    await _act(() => api.setAgentResponsibilities(_agent.id, selected), 'Responsibilities updated.');
  }

  @override
  Widget build(BuildContext context) {
    final a = _agent;
    return Scaffold(
      appBar: AppBar(title: Text(a.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoRow('Phone', a.phone ?? '—'),
                InfoRow('Status', a.isActive ? 'Active' : 'Disabled'),
                InfoRow('Created', a.createdAt != null ? formatDate(a.createdAt!) : '—'),
                InfoRow('Last seen', a.lastSeenAt != null ? formatDateTime(a.lastSeenAt!) : '—'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _editResponsibilities,
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('Responsibilities'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _busy ? null : _toggleStatus,
                  style: a.isActive
                      ? ElevatedButton.styleFrom(backgroundColor: AppColors.statusFailed, foregroundColor: Colors.white)
                      : null,
                  icon: Icon(a.isActive ? Icons.block_rounded : Icons.check_circle_rounded),
                  label: Text(a.isActive ? 'Disable' : 'Enable'),
                ),
              ),
            ],
          ),
          const GroupLabel('Responsibilities'),
          ConsoleCard(
            child: a.responsibilities.isEmpty
                ? const Text('None', style: TextStyle(color: AppColors.textSecondary))
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final r in a.responsibilities)
                        Chip(
                          label: Text(responsibilityLabel(r)),
                          backgroundColor: r == 'manage_settings' ? AppColors.lightGold : AppColors.surfaceRaised,
                          side: const BorderSide(color: AppColors.border),
                        ),
                    ],
                  ),
          ),
          const GroupLabel('Devices'),
          if (_devices == null)
            const Padding(padding: EdgeInsets.all(16), child: LoadingView())
          else if (_devices!.isEmpty)
            const ConsoleCard(child: Text('No registered devices.', style: TextStyle(color: AppColors.textSecondary)))
          else
            for (final d in _devices!) ...[
              ConsoleCard(
                child: Row(
                  children: [
                    const TintedIcon(icon: Icons.smartphone_rounded, color: AppColors.statusProcessing, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(d.label ?? d.deviceId, style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            d.lastSeenAt != null ? 'Last seen ${formatDateTime(d.lastSeenAt!)}' : 'Registered',
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    StatusPill(d.status),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          const GroupLabel('Orders processed'),
          if (_orders == null)
            const Padding(padding: EdgeInsets.all(16), child: LoadingView())
          else if (_orders!.isEmpty)
            const ConsoleCard(child: Text('No orders yet.', style: TextStyle(color: AppColors.textSecondary)))
          else
            for (final o in _orders!.take(50)) OrderCard(order: o),
        ],
      ),
    );
  }
}

class _ResponsibilitiesDialog extends StatefulWidget {
  final List<String> initial;
  const _ResponsibilitiesDialog({required this.initial});

  @override
  State<_ResponsibilitiesDialog> createState() => _ResponsibilitiesDialogState();
}

class _ResponsibilitiesDialogState extends State<_ResponsibilitiesDialog> {
  late final Set<String> _selected = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    // Keep any responsibility not in the known list so editing never drops it.
    final options = [
      ...knownResponsibilities,
      for (final r in widget.initial)
        if (!knownResponsibilities.any((k) => k.$1 == r)) (r, r.replaceAll('_', ' ')),
    ];
    return AlertDialog(
      title: const Text('Responsibilities'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, label) in options)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(key),
                title: Text(label),
                onChanged: (v) => setState(() => v == true ? _selected.add(key) : _selected.remove(key)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(_selected.toList()), child: const Text('Save')),
      ],
    );
  }
}

class _CreateAgentScreen extends StatefulWidget {
  const _CreateAgentScreen();

  @override
  State<_CreateAgentScreen> createState() => _CreateAgentScreenState();
}

class _CreateAgentScreenState extends State<_CreateAgentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final Set<String> _responsibilities = {'evc_deposit', 'evc_withdraw'};
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<Session>().api.createAgent(
            name: _name.text.trim(),
            phone: _phone.text.trim(),
            password: _password.text,
            responsibilities: _responsibilities.toList(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorText(e, 'Could not create the agent.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Agent')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Full name'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _phone,
              decoration: const InputDecoration(labelText: 'Phone number', hintText: '2526XXXXXXXX'),
              keyboardType: TextInputType.phone,
              validator: (v) => (v ?? '').trim().length < 6 ? 'Enter a phone number' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              decoration: const InputDecoration(labelText: 'Temporary password (at least 8 characters)'),
              obscureText: true,
              validator: (v) => (v ?? '').length < 8 ? 'At least 8 characters' : null,
            ),
            const GroupLabel('Responsibilities'),
            for (final (key, label) in knownResponsibilities)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _responsibilities.contains(key),
                title: Text(label),
                onChanged: (v) => setState(() => v == true ? _responsibilities.add(key) : _responsibilities.remove(key)),
              ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Creating…' : 'Create agent')),
          ],
        ),
      ),
    );
  }
}
