import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/management.dart';
import '../../services/logo_picker.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';

Color _statusColor(String status) => switch (status) {
      'connected' => AppColors.statusCompleted,
      'error' => AppColors.statusFailed,
      'not_tested' => AppColors.statusPending,
      _ => AppColors.textFaint,
    };

/// Betting Platforms: every platform with its connection, on/off, and a way
/// to add one. Credentials are kept on the server (Supabase Vault); a
/// platform is switched on only after its saved credentials pass a test.
class BettingPlatformsScreen extends StatefulWidget {
  const BettingPlatformsScreen({super.key});

  @override
  State<BettingPlatformsScreen> createState() => _BettingPlatformsScreenState();
}

class _BettingPlatformsScreenState extends State<BettingPlatformsScreen> {
  List<BettingAdapter> _adapters = const [];
  List<BettingPlatform>? _platforms;
  String? _error;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await context.read<Session>().api.getBettingPlatforms();
      if (!mounted) return;
      setState(() {
        _adapters = r.adapters;
        _platforms = r.platforms;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, 'Could not load the betting platforms.'));
    }
  }

  Future<void> _setActive(BettingPlatform p, bool on) async {
    setState(() => _busy = p.method);
    try {
      await context.read<Session>().api.setBettingPlatformActive(p.method, on);
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Could not change it.'));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _open(BettingPlatform p) async {
    final adapter = _adapters.where((a) => a.adapter == p.adapter).firstOrNull;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BettingPlatformScreen(method: p.method, adapter: adapter, initial: p),
    ));
    if (mounted) _load();
  }

  Future<void> _add() async {
    final result = await showDialog<(String, String)>(context: context, builder: (_) => _AddPlatformDialog(adapters: _adapters));
    if (result == null || !mounted) return;
    try {
      final method = await context.read<Session>().api.createBettingPlatform(result.$1, result.$2);
      await _load();
      if (!mounted) return;
      final p = _platforms?.where((x) => x.method == method).firstOrNull;
      if (p != null) await _open(p);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Could not add the platform.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final platforms = _platforms;
    return Scaffold(
      appBar: AppBar(title: const Text('Betting Platforms')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-platform'),
        onPressed: _adapters.isEmpty ? null : _add,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add platform'),
      ),
      body: _error != null
          ? ErrorStateView(message: _error!, onRetry: _load)
          : platforms == null
              ? const LoadingView()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    children: [
                      const Text(
                        'A platform can be switched on only after its saved credentials pass Test connection. '
                        'Built-in platforms without saved credentials use the server secrets, as before.',
                        style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 12),
                      for (final p in platforms) ...[
                        ConsoleCard(
                          key: Key('platform-${p.method}'),
                          onTap: () => _open(p),
                          child: Row(children: [
                            if (p.logo != null)
                              _LogoImage(key: Key('platform-logo-${p.method}'), logo: p.logo!, size: 44)
                            else
                              TintedIcon(icon: Icons.sports_soccer_rounded, color: _statusColor(p.status), size: 44),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                                Text(p.statusLabel,
                                    key: Key('platform-status-${p.method}'),
                                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _statusColor(p.status))),
                                if (p.lastTestAt != null)
                                  Text('Tested ${formatDateTime(p.lastTestAt!)}',
                                      style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
                              ]),
                            ),
                            Switch(
                              key: Key('platform-active-${p.method}'),
                              value: p.active,
                              onChanged: _busy == p.method ? null : (v) => _setActive(p, v),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
    );
  }
}

class _AddPlatformDialog extends StatefulWidget {
  final List<BettingAdapter> adapters;
  const _AddPlatformDialog({required this.adapters});

  @override
  State<_AddPlatformDialog> createState() => _AddPlatformDialogState();
}

class _AddPlatformDialogState extends State<_AddPlatformDialog> {
  final _name = TextEditingController();
  late String _adapter = widget.adapters.first.adapter;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a betting platform'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          key: const Key('platform-name'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'Platform name'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const Key('platform-adapter'),
          value: _adapter,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'API'),
          items: [
            for (final a in widget.adapters) DropdownMenuItem(value: a.adapter, child: Text(a.label, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _adapter = v ?? _adapter),
        ),
        const SizedBox(height: 8),
        const Text(
          'A company with a different API needs its own adapter, written from its official API documentation.',
          style: TextStyle(fontSize: 12, color: AppColors.textFaint),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _name.text.trim().length < 2 ? null : () => Navigator.of(context).pop((_name.text.trim(), _adapter)),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// One platform: its API URL, IDs and credentials, Test connection, and
/// removing it (added platforms only).
class BettingPlatformScreen extends StatefulWidget {
  final String method;
  final BettingAdapter? adapter;
  final BettingPlatform initial;

  /// Picks the logo (the gallery, shrunk to 128 x 128); replaced in tests.
  final LogoPicker pickLogo;

  const BettingPlatformScreen({
    super.key,
    required this.method,
    required this.adapter,
    required this.initial,
    this.pickLogo = pickLogoFromGallery,
  });

  @override
  State<BettingPlatformScreen> createState() => _BettingPlatformScreenState();
}

class _BettingPlatformScreenState extends State<BettingPlatformScreen> {
  final _formKey = GlobalKey<FormState>();
  late BettingPlatform _p = widget.initial;
  late final Map<String, TextEditingController> _fields = {
    for (final f in widget.adapter?.fields ?? const <BettingField>[])
      f.key: TextEditingController(
          text: switch (f.key) { 'apiUrl' => _p.apiUrl ?? '', 'accountId' => _p.accountId ?? '', _ => '' }),
  };
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _saved(String key) => switch (key) {
        'login' => _p.login != null,
        'password' => _p.hasPassword,
        'apiSecret' => _p.hasApiSecret,
        'apiKey' => _p.hasApiKey,
        'accountId' => _p.accountId != null,
        _ => false,
      };

  String? _text(String key) {
    final t = _fields[key]?.text.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  Future<void> _run(Future<BettingPlatform> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      final p = await action();
      if (!mounted) return;
      setState(() => _p = p);
      // Secrets are never shown again once saved.
      for (final k in ['login', 'password', 'apiSecret', 'apiKey']) {
        _fields[k]?.clear();
      }
      showSnack(context, done);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Something went wrong.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final api = context.read<Session>().api;
    await _run(
      () => api.saveBettingPlatform(
        widget.method,
        apiUrl: _text('apiUrl'),
        login: _text('login'),
        password: _text('password'),
        accountId: _text('accountId'),
        apiSecret: _text('apiSecret'),
        apiKey: _text('apiKey'),
      ),
      'Saved. Test the connection before switching it on.',
    );
  }

  Future<void> _test() async {
    final api = context.read<Session>().api;
    await _run(() => api.testBettingPlatform(widget.method), 'Test finished.');
  }

  /// A logo for this platform: picked, shrunk, sent. Nothing else changes.
  Future<void> _chooseLogo() async {
    final api = context.read<Session>().api;
    final Uint8List? logo;
    try {
      logo = await widget.pickLogo();
    } catch (_) {
      if (mounted) showSnack(context, 'Could not open the gallery.');
      return;
    }
    if (logo == null) {
      if (mounted) showSnack(context, 'No picture was chosen, or it could not be read.');
      return;
    }
    await _run(() => api.setBettingPlatformLogo(widget.method, logo), 'Logo saved. The Customer App shows it now.');
  }

  Future<void> _removeLogo() async {
    final api = context.read<Session>().api;
    await _run(() => api.setBettingPlatformLogo(widget.method, null), 'Logo removed.');
  }

  Future<void> _remove() async {
    final reason = await showDialog<String>(context: context, builder: (_) => _RemoveDialog(name: _p.name));
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<Session>().api.deleteBettingPlatform(widget.method, reason);
      if (!mounted) return;
      showSnack(context, '${_p.name} removed. Its orders are kept.');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, 'Could not remove it.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final adapter = widget.adapter;
    return Scaffold(
      appBar: AppBar(title: Text(_p.name)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ConsoleCard(
              key: const Key('platform-connection'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(_p.statusLabel,
                        key: const Key('platform-status'),
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: _statusColor(_p.status))),
                  ),
                  StatusPill(_p.active ? 'active' : 'blocked'),
                ]),
                if (_p.lastMessage != null) ...[
                  const SizedBox(height: 6),
                  Text(_p.lastMessage!, key: const Key('platform-message'), style: const TextStyle(color: AppColors.textSecondary)),
                ],
                const SizedBox(height: 6),
                InfoRow('Last test', _p.lastTestAt != null ? formatDateTime(_p.lastTestAt!) : '—'),
                InfoRow('Last connected', _p.lastOkAt != null ? formatDateTime(_p.lastOkAt!) : '—'),
                if (_p.updatedBy != null) InfoRow('Changed by', _p.updatedBy!),
              ]),
            ),
            if (!_p.builtIn) ...[
              const GroupLabel('Logo'),
              ConsoleCard(
                key: const Key('platform-logo-card'),
                child: Row(children: [
                  if (_p.logo != null)
                    _LogoImage(key: const Key('platform-logo-preview'), logo: _p.logo!, size: 64)
                  else
                    const TintedIcon(icon: Icons.image_outlined, color: AppColors.textFaint, size: 64),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_p.logo != null ? 'Logo set' : 'No logo yet (the Customer App shows its initials)',
                          key: const Key('platform-logo-state'), style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        OutlinedButton.icon(
                          key: const Key('platform-logo-choose'),
                          onPressed: _busy ? null : _chooseLogo,
                          icon: const Icon(Icons.photo_library_rounded),
                          label: Text(_p.logo != null ? 'Change logo' : 'Choose logo'),
                        ),
                        if (_p.logo != null)
                          TextButton(
                            key: const Key('platform-logo-remove'),
                            onPressed: _busy ? null : _removeLogo,
                            child: const Text('Remove'),
                          ),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            if (adapter == null)
              const ConsoleCard(
                child: Text('No adapter for this API: it has to be written from the provider\'s official documentation.',
                    style: TextStyle(color: AppColors.statusFailed)),
              )
            else ...[
              GroupLabel(adapter.label),
              for (final f in adapter.fields) ...[
                TextFormField(
                  key: Key('field-${f.key}'),
                  controller: _fields[f.key],
                  obscureText: f.secret,
                  keyboardType: f.key == 'accountId' ? TextInputType.number : TextInputType.text,
                  decoration: InputDecoration(
                    labelText: '${f.label}${f.required ? ' *' : ''}',
                    hintText: f.key == 'apiUrl'
                        ? adapter.defaultApiUrl
                        : f.key == 'login' && _p.login != null
                            ? 'Saved (${_p.login}): leave empty to keep'
                            : f.secret && _saved(f.key)
                                ? 'Saved: leave empty to keep'
                                : null,
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (f.required && t.isEmpty && !_saved(f.key)) return 'Required';
                    if (f.key == 'accountId' && t.isNotEmpty && !RegExp(r'^\d{1,20}$').hasMatch(t)) return 'Digits only';
                    if (f.key == 'apiUrl' && t.isNotEmpty && !t.startsWith('https://')) return 'Must start with https://';
                    return null;
                  },
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    key: const Key('platform-save'),
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Save'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('platform-test'),
                    onPressed: _busy || _p.status == 'not_configured' || _p.status == 'server' ? null : _test,
                    icon: const Icon(Icons.wifi_tethering_rounded),
                    label: const Text('Test connection'),
                  ),
                ),
              ]),
            ],
            if (!_p.builtIn) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                key: const Key('platform-remove'),
                onPressed: _busy ? null : _remove,
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.statusFailed),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Remove platform'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RemoveDialog extends StatefulWidget {
  final String name;
  const _RemoveDialog({required this.name});

  @override
  State<_RemoveDialog> createState() => _RemoveDialogState();
}

class _RemoveDialogState extends State<_RemoveDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Remove ${widget.name}?'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('It is switched off and its credentials deleted. Every order that used it is kept.',
            style: TextStyle(color: AppColors.textSecondary)),
        TextField(
          key: const Key('remove-reason'),
          controller: _reason,
          decoration: const InputDecoration(labelText: 'Reason'),
          onChanged: (_) => setState(() {}),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.statusFailed),
          onPressed: _reason.text.trim().length < 3 ? null : () => Navigator.of(context).pop(_reason.text.trim()),
          child: const Text('Remove'),
        ),
      ],
    );
  }
}

/// A platform's logo, whole, on a white 2.4 : 1 tile (as the Customer App shows it).
class _LogoImage extends StatelessWidget {
  final Uint8List logo;
  final double size;
  const _LogoImage({super.key, required this.logo, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.2),
      child: ColoredBox(
        color: Colors.white,
        child: Image.memory(
          logo,
          width: size * 2.4,
          height: size,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => TintedIcon(icon: Icons.image_not_supported_outlined, color: AppColors.textFaint, size: size),
        ),
      ),
    );
  }
}
