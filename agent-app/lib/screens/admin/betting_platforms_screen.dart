import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/management.dart';
import '../../models/payment_methods.dart';
import '../../services/logo_picker.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';
import '../../l10n/tr.dart';

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
      if (mounted)
        setState(() =>
            _error = errorText(e, tr('Could not load the betting platforms.')));
    }
  }

  Future<void> _setActive(BettingPlatform p, bool on) async {
    setState(() => _busy = p.method);
    try {
      await context.read<Session>().api.setBettingPlatformActive(p.method, on);
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, tr('Could not change it.')));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _open(BettingPlatform p) async {
    final adapter = _adapters.where((a) => a.adapter == p.adapter).firstOrNull;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          BettingPlatformScreen(method: p.method, adapter: adapter, initial: p),
    ));
    if (mounted) _load();
  }

  Future<void> _add() async {
    final result = await showDialog<(String, String)>(
        context: context,
        builder: (_) => _AddPlatformDialog(adapters: _adapters));
    if (result == null || !mounted) return;
    try {
      final method = await context
          .read<Session>()
          .api
          .createBettingPlatform(result.$1, result.$2);
      await _load();
      if (!mounted) return;
      final p = _platforms?.where((x) => x.method == method).firstOrNull;
      if (p != null) await _open(p);
    } catch (e) {
      if (mounted)
        showSnack(context, errorText(e, tr('Could not add the platform.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final platforms = _platforms;
    return Scaffold(
      appBar: AppBar(title: const Tx('Betting Platforms')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-platform'),
        onPressed: _adapters.isEmpty ? null : _add,
        icon: const Icon(Icons.add_rounded),
        label: const Tx('Add platform'),
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
                      Tx(
                        'A platform can be switched on only after its saved credentials pass Test connection. '
                        'Built-in platforms without saved credentials use the server secrets, as before.',
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 12),
                      for (final p in platforms) ...[
                        ConsoleCard(
                          key: Key('platform-${p.method}'),
                          onTap: () => _open(p),
                          child: Row(children: [
                            if (p.logo != null)
                              _LogoImage(
                                  key: Key('platform-logo-${p.method}'),
                                  logo: p.logo!,
                                  size: 44,
                                  fallbackMethod: p.builtIn ? p.method : null)
                            else if (p.builtIn)
                              // The logo the Customer App has built in.
                              MethodLogo(
                                  key: Key('platform-builtin-logo-${p.method}'),
                                  method: p.method,
                                  width: 44 * 2.4)
                            else
                              TintedIcon(
                                  icon: Icons.sports_soccer_rounded,
                                  color: _statusColor(p.status),
                                  size: 44),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Tx(p.name,
                                        style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.textPrimary)),
                                    Text(p.statusLabel,
                                        key: Key('platform-status-${p.method}'),
                                        style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                            color: _statusColor(p.status))),
                                    if (p.modeLabel != null)
                                      Text(p.modeLabel!,
                                          key: Key('platform-mode-${p.method}'),
                                          style: TextStyle(
                                              fontSize: 11.5,
                                              color: AppColors.textSecondary)),
                                    if (p.accounts.length > 1)
                                      Text(
                                          trp('{0} accounts · in use: {1}', [
                                            p.accounts.length,
                                            p.selectedAccount?.label ?? '—'
                                          ]),
                                          key: Key(
                                              'platform-accounts-${p.method}'),
                                          style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.primaryDark)),
                                    if (p.lastTestAt != null)
                                      Text(
                                          trp('Tested {0}',
                                              [formatDateTime(p.lastTestAt!)]),
                                          style: TextStyle(
                                              fontSize: 11.5,
                                              color: AppColors.textFaint)),
                                  ]),
                            ),
                            Switch(
                              key: Key('platform-active-${p.method}'),
                              value: p.active,
                              onChanged: _busy == p.method
                                  ? null
                                  : (v) => _setActive(p, v),
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
      title: const Tx('Add a betting platform'),
      content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('platform-name'),
              controller: _name,
              decoration: InputDecoration(labelText: tr('Platform name')),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('platform-adapter'),
              value: _adapter,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('API')),
              items: [
                for (final a in widget.adapters)
                  DropdownMenuItem(
                      value: a.adapter,
                      child: Tx(a.label, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _adapter = v ?? _adapter),
            ),
            const SizedBox(height: 8),
            Tx(
              'A company with a different API needs its own adapter, written from its official API documentation.',
              style: TextStyle(fontSize: 12, color: AppColors.textFaint),
            ),
          ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Tx('Cancel')),
        FilledButton(
          onPressed: _name.text.trim().length < 2
              ? null
              : () => Navigator.of(context).pop((_name.text.trim(), _adapter)),
          child: const Tx('Add'),
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
          text: switch (f.key) {
        'apiUrl' => _p.apiUrl ?? '',
        'accountId' => _p.accountId ?? '',
        _ => ''
      }),
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

  Future<void> _run(
      Future<BettingPlatform> Function() action, String done) async {
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
      if (mounted)
        showSnack(context, errorText(e, tr('Something went wrong.')));
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
      tr('Saved. Test the connection before switching it on.'),
    );
  }

  Future<void> _test() async {
    final api = context.read<Session>().api;
    await _run(
        () => api.testBettingPlatform(widget.method), tr('Test finished.'));
  }

  Future<void> _addAccount() async {
    final label = await showDialog<String>(
        context: context,
        builder: (_) => _AccountNameDialog(
            title: tr('Add an account'), hint: tr('Account name (optional)')));
    if (label == null || !mounted) return;
    await _run(
        () => context.read<Session>().api.addBettingAccount(widget.method,
            label: label.isEmpty ? null : label),
        tr('Account added. Save its credentials, test it, then switch it on.'));
  }

  Future<void> _renameAccount(BettingAccount a) async {
    final label = await showDialog<String>(
        context: context,
        builder: (_) => _AccountNameDialog(
            title: tr('Rename account'),
            hint: tr('Account name'),
            initial: a.label));
    if (label == null || label.isEmpty || !mounted) return;
    await _run(
        () => context.read<Session>().api.renameBettingAccount(a.id!, label),
        tr('Account renamed.'));
  }

  Future<void> _removeAccount(BettingAccount a) async {
    final reason = await showDialog<String>(
        context: context,
        builder: (_) => _RemoveDialog(name: a.label, account: true));
    if (reason == null || !mounted) return;
    await _run(
        () => context.read<Session>().api.removeBettingAccount(a.id!, reason),
        tr('Account removed. Its orders are kept.'));
  }

  Future<void> _editAccount(BettingAccount a) async {
    final updated =
        await Navigator.of(context).push<BettingPlatform>(MaterialPageRoute(
      builder: (_) => BettingAccountScreen(
          platform: _p, adapter: widget.adapter, accountId: a.id!),
    ));
    if (updated != null && mounted) setState(() => _p = updated);
  }

  /// A logo for this platform: picked, shrunk, sent. Nothing else changes.
  Future<void> _chooseLogo() async {
    final api = context.read<Session>().api;
    final Uint8List? logo;
    try {
      logo = await widget.pickLogo();
    } catch (_) {
      if (mounted) showSnack(context, tr('Could not open the gallery.'));
      return;
    }
    if (logo == null) {
      if (mounted)
        showSnack(
            context, tr('No picture was chosen, or it could not be read.'));
      return;
    }
    await _run(() => api.setBettingPlatformLogo(widget.method, logo),
        tr('Logo saved. The Customer App shows it now.'));
  }

  Future<void> _removeLogo() async {
    final api = context.read<Session>().api;
    await _run(() => api.setBettingPlatformLogo(widget.method, null),
        tr('Logo removed.'));
  }

  Future<void> _remove() async {
    final reason = await showDialog<String>(
        context: context, builder: (_) => _RemoveDialog(name: _p.name));
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await context
          .read<Session>()
          .api
          .deleteBettingPlatform(widget.method, reason);
      if (!mounted) return;
      showSnack(context, '${_p.name} removed. Its orders are kept.');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, tr('Could not remove it.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final adapter = widget.adapter;
    return Scaffold(
      appBar: AppBar(title: Tx(_p.name)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ConsoleCard(
              key: const Key('platform-connection'),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(_p.statusLabel,
                            key: const Key('platform-status'),
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: _statusColor(_p.status))),
                      ),
                      StatusPill(_p.active ? 'active' : 'blocked'),
                    ]),
                    if (_p.lastMessage != null) ...[
                      const SizedBox(height: 6),
                      Text(_p.lastMessage!,
                          key: const Key('platform-message'),
                          style: TextStyle(color: AppColors.textSecondary)),
                    ],
                    const SizedBox(height: 6),
                    InfoRow(
                        tr('Last test'),
                        _p.lastTestAt != null
                            ? formatDateTime(_p.lastTestAt!)
                            : '—'),
                    InfoRow(
                        tr('Last connected'),
                        _p.lastOkAt != null
                            ? formatDateTime(_p.lastOkAt!)
                            : '—'),
                    if (_p.updatedBy != null)
                      InfoRow(tr('Changed by'), _p.updatedBy!),
                  ]),
            ),
            ...[
              GroupLabel(tr('Logo')),
              ConsoleCard(
                key: const Key('platform-logo-card'),
                child: Row(children: [
                  if (_p.logo != null)
                    _LogoImage(
                        key: const Key('platform-logo-preview'),
                        logo: _p.logo!,
                        size: 64,
                        fallbackMethod: _p.builtIn ? _p.method : null)
                  else if (_p.builtIn)
                    MethodLogo(
                        key: const Key('platform-builtin-logo-card'),
                        method: _p.method,
                        width: 64 * 2.4)
                  else
                    TintedIcon(
                        icon: Icons.image_outlined,
                        color: AppColors.textFaint,
                        size: 64),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              _p.logo != null
                                  ? (_p.builtIn
                                      ? tr(
                                          'Logo replaced (the Customer App shows this one)')
                                      : tr('Logo set'))
                                  : (_p.builtIn
                                      ? tr(
                                          'The logo built into the Customer App')
                                      : tr(
                                          'No logo yet (the Customer App shows its initials)')),
                              key: const Key('platform-logo-state'),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 4, children: [
                            OutlinedButton.icon(
                              key: const Key('platform-logo-choose'),
                              onPressed: _busy ? null : _chooseLogo,
                              icon: const Icon(Icons.photo_library_rounded),
                              label: Tx(_p.logo != null
                                  ? tr('Change logo')
                                  : (_p.builtIn
                                      ? tr('Replace logo')
                                      : tr('Choose logo'))),
                            ),
                            if (_p.logo != null)
                              TextButton(
                                key: const Key('platform-logo-remove'),
                                onPressed: _busy ? null : _removeLogo,
                                child: Tx(_p.builtIn
                                    ? tr('Back to the built-in logo')
                                    : tr('Remove')),
                              ),
                          ]),
                        ]),
                  ),
                ]),
              ),
            ],
            if (_p.accounts.isNotEmpty) ...[
              GroupLabel(tr('Accounts')),
              for (final a in _p.accounts) ...[
                _AccountCard(
                  account: a,
                  busy: _busy,
                  onEnabled: (v) => _run(
                      () => context
                          .read<Session>()
                          .api
                          .setBettingAccountEnabled(a.id!, v),
                      v
                          ? tr('Account switched on.')
                          : tr('Account switched off.')),
                  onTest: () => _run(
                      () => context
                          .read<Session>()
                          .api
                          .testBettingAccount(widget.method, a.id!),
                      tr('Test finished.')),
                  onSelect: () => _run(
                      () => context
                          .read<Session>()
                          .api
                          .selectBettingAccount(a.id!),
                      trp('{0} is now the account in use.', [a.label])),
                  onEdit: () => _editAccount(a),
                  onRename: () => _renameAccount(a),
                  onRemove: () => _removeAccount(a),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                key: const Key('account-add'),
                onPressed: _busy ? null : _addAccount,
                icon: const Icon(Icons.add_rounded),
                label: const Tx('Add account'),
              ),
            ],
            const SizedBox(height: 12),
            if (adapter == null)
              const ConsoleCard(
                child: Tx(
                    'No adapter for this API: it has to be written from the provider\'s official documentation.',
                    style: TextStyle(color: AppColors.statusFailed)),
              )
            else ...[
              GroupLabel(_p.accounts.length > 1
                  ? trp('{0}: credentials of {1} (the account in use)',
                      [adapter.label, _p.selectedAccount?.label ?? ''])
                  : adapter.label),
              for (final f in adapter.fields) ...[
                TextFormField(
                  key: Key('field-${f.key}'),
                  controller: _fields[f.key],
                  obscureText: f.secret,
                  keyboardType: f.key == 'accountId'
                      ? TextInputType.number
                      : TextInputType.text,
                  decoration: InputDecoration(
                    labelText: '${f.label}${f.required ? ' *' : ''}',
                    hintText: f.key == 'apiUrl'
                        ? adapter.defaultApiUrl
                        : f.key == 'login' && _p.login != null
                            ? trp(
                                'Saved ({0}): leave empty to keep', [_p.login])
                            : f.secret && _saved(f.key)
                                ? tr('Saved: leave empty to keep')
                                : null,
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (f.required && t.isEmpty && !_saved(f.key))
                      return tr('Required');
                    if (f.key == 'accountId' &&
                        t.isNotEmpty &&
                        !RegExp(r'^\d{1,20}$').hasMatch(t))
                      return tr('Digits only');
                    if (f.key == 'apiUrl' &&
                        t.isNotEmpty &&
                        !t.startsWith('https://'))
                      return tr('Must start with https://');
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
                    label: const Tx('Save'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('platform-test'),
                    onPressed: _busy ||
                            _p.status == 'not_configured' ||
                            _p.status == 'server'
                        ? null
                        : _test,
                    icon: const Icon(Icons.wifi_tethering_rounded),
                    label: const Tx('Test connection'),
                  ),
                ),
              ]),
            ],
            if (!_p.builtIn) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                key: const Key('platform-remove'),
                onPressed: _busy ? null : _remove,
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusFailed),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Tx('Remove platform'),
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

  /// Removing an account (not the platform).
  final bool account;
  const _RemoveDialog({required this.name, this.account = false});

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
      title: Text(trp('Remove {0}?', [widget.name])),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Tx(
            widget.account
                ? 'Its credentials are deleted. Every order it handled is kept.'
                : 'It is switched off and its credentials deleted. Every order that used it is kept.',
            style: TextStyle(color: AppColors.textSecondary)),
        TextField(
          key: const Key('remove-reason'),
          controller: _reason,
          decoration: InputDecoration(labelText: tr('Reason')),
          onChanged: (_) => setState(() {}),
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Tx('Cancel')),
        FilledButton(
          style:
              FilledButton.styleFrom(backgroundColor: AppColors.statusFailed),
          onPressed: _reason.text.trim().length < 3
              ? null
              : () => Navigator.of(context).pop(_reason.text.trim()),
          child: const Tx('Remove'),
        ),
      ],
    );
  }
}

/// A platform's logo, whole, on a white 2.4 : 1 tile (as the Customer App shows it).
class _LogoImage extends StatelessWidget {
  final Uint8List logo;
  final double size;

  /// A built-in platform: its own logo shows when the picture cannot be read.
  final String? fallbackMethod;
  const _LogoImage(
      {super.key, required this.logo, required this.size, this.fallbackMethod});

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
          errorBuilder: (_, __, ___) => fallbackMethod != null
              ? MethodLogo(method: fallbackMethod!, width: size * 2.4)
              : TintedIcon(
                  icon: Icons.image_not_supported_outlined,
                  color: AppColors.textFaint,
                  size: size),
        ),
      ),
    );
  }
}

/// A name for an account (empty: the next "Account N").
class _AccountNameDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String initial;
  const _AccountNameDialog(
      {required this.title, required this.hint, this.initial = ''});

  @override
  State<_AccountNameDialog> createState() => _AccountNameDialogState();
}

class _AccountNameDialogState extends State<_AccountNameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('account-name'),
        controller: _name,
        maxLength: 40,
        decoration: InputDecoration(labelText: widget.hint),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Tx('Cancel')),
        FilledButton(
          key: const Key('account-name-ok'),
          onPressed: () => Navigator.of(context).pop(_name.text.trim()),
          child: const Tx('Save'),
        ),
      ],
    );
  }
}

/// One account of a platform: its status, its own ON / OFF, Test connection,
/// and which one is in use.
class _AccountCard extends StatelessWidget {
  final BettingAccount account;
  final bool busy;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onTest;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  const _AccountCard({
    required this.account,
    required this.busy,
    required this.onEnabled,
    required this.onTest,
    required this.onSelect,
    required this.onEdit,
    required this.onRename,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final a = account;
    final id = a.id ?? 'server';
    final real = a.id != null;
    return ConsoleCard(
      key: Key('account-$id'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Row(children: [
              Flexible(
                  child: Text(a.label,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: AppColors.textPrimary))),
              if (a.selected) ...[
                const SizedBox(width: 8),
                Flexible(
                    child: Container(
                  key: Key('account-inuse-$id'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: AppColors.primaryTint,
                      borderRadius: BorderRadius.circular(10)),
                  child: Tx('In use',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primaryDark)),
                )),
              ],
            ]),
          ),
          Switch(
            key: Key('account-enabled-$id'),
            value: a.enabled,
            onChanged: busy || !real ? null : onEnabled,
          ),
          if (real)
            PopupMenuButton<String>(
              key: Key('account-menu-$id'),
              onSelected: (v) => v == 'rename' ? onRename() : onRemove(),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rename', child: Tx('Rename')),
                if (!a.selected)
                  PopupMenuItem(value: 'remove', child: Tx('Remove account')),
              ],
            ),
        ]),
        Text(a.statusLabel,
            key: Key('account-status-$id'),
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: _statusColor(a.status))),
        if (a.accountId != null)
          Text(trp('Cashdesk ID {0}', [a.accountId]),
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        if (a.lastMessage != null)
          Text(a.lastMessage!,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        if (a.lastTestAt != null)
          Text(trp('Tested {0}', [formatDateTime(a.lastTestAt!)]),
              style: TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
        Text(trp('{0} orders handled', [a.orders]),
            key: Key('account-orders-$id'),
            style: TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
        if (real) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            OutlinedButton.icon(
              key: Key('account-test-$id'),
              onPressed: busy || a.status == 'not_configured' ? null : onTest,
              icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
              label: const Tx('Test connection'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
            ),
            if (!a.selected)
              OutlinedButton.icon(
                key: Key('account-select-$id'),
                onPressed: busy || !a.enabled ? null : onSelect,
                icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                label: const Tx('Use this account'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
              ),
            if (!a.selected)
              TextButton.icon(
                key: Key('account-edit-$id'),
                onPressed: busy ? null : onEdit,
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Tx('Edit credentials'),
              ),
          ]),
        ],
      ]),
    );
  }
}

/// One account's own API URL, IDs and credentials, its Test connection and ON / OFF.
/// Pops with the platform as it was last seen.
class BettingAccountScreen extends StatefulWidget {
  final BettingPlatform platform;
  final BettingAdapter? adapter;
  final String accountId;

  const BettingAccountScreen(
      {super.key,
      required this.platform,
      required this.adapter,
      required this.accountId});

  @override
  State<BettingAccountScreen> createState() => _BettingAccountScreenState();
}

class _BettingAccountScreenState extends State<BettingAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  late BettingPlatform _p = widget.platform;
  late final Map<String, TextEditingController> _fields = {
    for (final f in widget.adapter?.fields ?? const <BettingField>[])
      f.key: TextEditingController(
          text: switch (f.key) {
        'apiUrl' => _a.apiUrl ?? '',
        'accountId' => _a.accountId ?? '',
        _ => ''
      }),
  };
  bool _busy = false;

  BettingAccount get _a => _p.accounts.firstWhere(
      (x) => x.id == widget.accountId,
      orElse: () => const BettingAccount(label: '—', status: 'not_configured'));

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _saved(String key) => switch (key) {
        'login' => _a.login != null,
        'password' => _a.hasPassword,
        'apiSecret' => _a.hasApiSecret,
        'apiKey' => _a.hasApiKey,
        'accountId' => _a.accountId != null,
        _ => false,
      };

  String? _text(String key) {
    final t = _fields[key]?.text.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  Future<void> _run(
      Future<BettingPlatform> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      final p = await action();
      if (!mounted) return;
      setState(() => _p = p);
      for (final k in ['login', 'password', 'apiSecret', 'apiKey']) {
        _fields[k]?.clear();
      }
      showSnack(context, done);
    } catch (e) {
      if (mounted)
        showSnack(context, errorText(e, tr('Something went wrong.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final api = context.read<Session>().api;
    await _run(
      () => api.saveBettingAccount(
        widget.accountId,
        apiUrl: _text('apiUrl'),
        login: _text('login'),
        password: _text('password'),
        cashdeskId: _text('accountId'),
        apiSecret: _text('apiSecret'),
        apiKey: _text('apiKey'),
      ),
      tr('Saved. Test the connection before switching it on.'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final adapter = widget.adapter;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_p);
      },
      child: Scaffold(
        appBar: AppBar(title: Text('${_p.name} · ${a.label}')),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ConsoleCard(
                key: const Key('account-connection'),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(a.statusLabel,
                              key: const Key('account-status'),
                              style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: _statusColor(a.status))),
                        ),
                        Switch(
                          key: const Key('account-enabled'),
                          value: a.enabled,
                          onChanged: _busy
                              ? null
                              : (v) => _run(
                                  () => context
                                      .read<Session>()
                                      .api
                                      .setBettingAccountEnabled(
                                          widget.accountId, v),
                                  v
                                      ? tr('Account switched on.')
                                      : tr('Account switched off.')),
                        ),
                      ]),
                      if (a.lastMessage != null) ...[
                        const SizedBox(height: 6),
                        Text(a.lastMessage!,
                            key: const Key('account-message'),
                            style: TextStyle(color: AppColors.textSecondary)),
                      ],
                      const SizedBox(height: 6),
                      InfoRow(
                          tr('Last test'),
                          a.lastTestAt != null
                              ? formatDateTime(a.lastTestAt!)
                              : '—'),
                      InfoRow(
                          tr('Last connected'),
                          a.lastOkAt != null
                              ? formatDateTime(a.lastOkAt!)
                              : '—'),
                      InfoRow(tr('Orders handled'), '${a.orders}'),
                      if (a.selected)
                        Tx('This account is in use.',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryDark)),
                    ]),
              ),
              const SizedBox(height: 12),
              if (adapter == null)
                const ConsoleCard(
                  child: Tx(
                      'No adapter for this API: it has to be written from the provider\'s official documentation.',
                      style: TextStyle(color: AppColors.statusFailed)),
                )
              else ...[
                GroupLabel(adapter.label),
                for (final f in adapter.fields) ...[
                  TextFormField(
                    key: Key('account-field-${f.key}'),
                    controller: _fields[f.key],
                    obscureText: f.secret,
                    keyboardType: f.key == 'accountId'
                        ? TextInputType.number
                        : TextInputType.text,
                    decoration: InputDecoration(
                      labelText: '${f.label}${f.required ? ' *' : ''}',
                      hintText: f.key == 'apiUrl'
                          ? adapter.defaultApiUrl
                          : f.key == 'login' && a.login != null
                              ? trp(
                                  'Saved ({0}): leave empty to keep', [a.login])
                              : f.secret && _saved(f.key)
                                  ? tr('Saved: leave empty to keep')
                                  : null,
                    ),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (f.required && t.isEmpty && !_saved(f.key))
                        return tr('Required');
                      if (f.key == 'accountId' &&
                          t.isNotEmpty &&
                          !RegExp(r'^\d{1,20}$').hasMatch(t))
                        return tr('Digits only');
                      if (f.key == 'apiUrl' &&
                          t.isNotEmpty &&
                          !t.startsWith('https://'))
                        return tr('Must start with https://');
                      return null;
                    },
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      key: const Key('account-save'),
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.save_rounded),
                      label: const Tx('Save'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('account-test'),
                      onPressed: _busy ||
                              a.status == 'not_configured' ||
                              a.status == 'server'
                          ? null
                          : () => _run(
                              () => context
                                  .read<Session>()
                                  .api
                                  .testBettingAccount(
                                      _p.method, widget.accountId),
                              tr('Test finished.')),
                      icon: const Icon(Icons.wifi_tethering_rounded),
                      label: const Tx('Test connection'),
                    ),
                  ),
                ]),
                if (!a.selected) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('account-use'),
                    onPressed: _busy || !a.enabled
                        ? null
                        : () => _run(
                            () => context
                                .read<Session>()
                                .api
                                .selectBettingAccount(widget.accountId),
                            trp('{0} is now the account in use.', [a.label])),
                    icon: const Icon(Icons.check_circle_outline_rounded),
                    label: const Tx('Use this account'),
                  ),
                  if (!a.enabled)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Tx(
                          'Switch the account on first: it has to pass Test connection.',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textFaint)),
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
