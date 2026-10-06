import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/agent_api.dart';
import '../api/api_exception.dart';
import '../models/console.dart';
import '../models/payment_methods.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';
import 'login_screen.dart';

/// Screens opened from the Account tab. The admin features need the
/// 'manage_settings' responsibility; the backend enforces it on every call.

String _errorText(Object e, String fallback) => e is ApiException ? e.message : fallback;

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Loads a list, shows loading/error/empty states, and reloads on demand.
abstract class _ListScreenState<W extends StatefulWidget, T> extends State<W> {
  List<T>? items;
  String? error;

  AgentApi get api => context.read<Session>().api;
  Future<List<T>> fetch();

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => error = null);
    try {
      final result = await fetch();
      if (mounted) setState(() => items = result);
    } catch (e) {
      if (mounted) setState(() => error = _errorText(e, 'Failed to load.'));
    }
  }

  /// Runs [action], reports failures, then reloads.
  Future<void> run(Future<void> Function() action, {String? success}) async {
    try {
      await action();
      if (mounted && success != null) _snack(context, success);
    } catch (e) {
      if (mounted) _snack(context, _errorText(e, 'Something went wrong.'));
    }
    if (mounted) load();
  }

  Widget body({required Widget Function(List<T> items) builder}) {
    if (items == null) {
      return error != null ? ErrorStateView(message: error!, onRetry: load) : const LoadingView();
    }
    return RefreshIndicator(onRefresh: load, child: builder(items!));
  }
}

// ---------------------------------------------------------------------------
// Payment method switches
// ---------------------------------------------------------------------------

/// ON/OFF for each method of one [kind]: 'mobile_money' (Manage Platforms)
/// or 'platform' (betting platforms).
class ManageMethodsScreen extends StatefulWidget {
  final String kind;
  const ManageMethodsScreen({super.key, required this.kind});

  @override
  State<ManageMethodsScreen> createState() => _ManageMethodsScreenState();
}

class _ManageMethodsScreenState extends _ListScreenState<ManageMethodsScreen, ManagedMethod> {
  @override
  Future<List<ManagedMethod>> fetch() async =>
      (await api.getManagedMethods()).where((m) => m.kind == widget.kind).toList();

  @override
  Widget build(BuildContext context) {
    final isPlatform = widget.kind == 'platform';
    return Scaffold(
      appBar: AppBar(title: Text(isPlatform ? 'Bet Payment Methods' : 'Manage Platforms')),
      body: body(
        builder: (methods) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              isPlatform
                  ? 'Turn a betting platform OFF to hide it from customers and stop new orders.'
                  : 'Turn a payment platform OFF to hide it from customers and stop new orders. '
                      'Orders already in progress still complete.',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            ConsoleCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (final m in methods)
                    SwitchListTile(
                      secondary: MethodBadge(method: m.method, size: 36),
                      title: Text(m.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(m.enabled ? 'ON' : 'OFF'),
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
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home ads
// ---------------------------------------------------------------------------

class ManageHomeAdsScreen extends StatefulWidget {
  const ManageHomeAdsScreen({super.key});

  @override
  State<ManageHomeAdsScreen> createState() => _ManageHomeAdsScreenState();
}

class _ManageHomeAdsScreenState extends _ListScreenState<ManageHomeAdsScreen, HomeAd> {
  @override
  Future<List<HomeAd>> fetch() => api.getHomeAds();

  Future<void> _edit([HomeAd? ad]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _HomeAdForm(ad: ad)),
    );
    if (saved == true) load();
  }

  Future<void> _delete(HomeAd ad) async {
    final ok = await _confirm(context, 'Delete "${ad.title}"?', 'Customers will no longer see this ad.');
    if (ok) run(() => api.deleteHomeAd(ad.id), success: 'Ad deleted.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Home Ads')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add ad'),
      ),
      body: body(
        builder: (ads) => ads.isEmpty
            ? ListView(children: const [
                SizedBox(height: 100),
                EmptyStateView(
                  icon: Icons.campaign_outlined,
                  title: 'No home ads yet',
                  message: 'Ads you add appear on the Customer App home screen.',
                ),
              ])
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  for (final ad in ads) ...[
                    ConsoleCard(
                      onTap: () => _edit(ad),
                      child: Row(
                        children: [
                          const TintedIcon(icon: Icons.campaign_rounded, color: AppColors.accentOrange),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(ad.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                                if ((ad.body ?? '').isNotEmpty)
                                  Text(
                                    ad.body!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                                  ),
                              ],
                            ),
                          ),
                          Switch(
                            value: ad.enabled,
                            onChanged: (v) => run(() => api.saveHomeAd(
                                  id: ad.id,
                                  title: ad.title,
                                  body: ad.body,
                                  imageUrl: ad.imageUrl,
                                  linkUrl: ad.linkUrl,
                                  enabled: v,
                                  sortOrder: ad.sortOrder,
                                )),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, color: AppColors.statusFailed),
                            onPressed: () => _delete(ad),
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

class _HomeAdForm extends StatefulWidget {
  final HomeAd? ad;
  const _HomeAdForm({this.ad});

  @override
  State<_HomeAdForm> createState() => _HomeAdFormState();
}

class _HomeAdFormState extends State<_HomeAdForm> {
  final _formKey = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.ad?.title);
  late final _body = TextEditingController(text: widget.ad?.body);
  late final _image = TextEditingController(text: widget.ad?.imageUrl);
  late final _link = TextEditingController(text: widget.ad?.linkUrl);
  late final _order = TextEditingController(text: '${widget.ad?.sortOrder ?? 0}');
  late bool _enabled = widget.ad?.enabled ?? true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_title, _body, _image, _link, _order]) {
      c.dispose();
    }
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
    String? orNull(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    try {
      await context.read<Session>().api.saveHomeAd(
            id: widget.ad?.id,
            title: _title.text.trim(),
            body: orNull(_body),
            imageUrl: orNull(_image),
            linkUrl: orNull(_link),
            enabled: _enabled,
            sortOrder: int.tryParse(_order.text.trim()) ?? 0,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(context, _errorText(e, 'Could not save the ad.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.ad == null ? 'Add Home Ad' : 'Edit Home Ad')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title'),
              maxLength: 120,
              validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
            ),
            TextFormField(
              controller: _body,
              decoration: const InputDecoration(labelText: 'Text (optional)'),
              maxLength: 500,
              maxLines: 3,
            ),
            TextFormField(
              controller: _image,
              decoration: const InputDecoration(labelText: 'Image link (optional)', hintText: 'https://...'),
              keyboardType: TextInputType.url,
              validator: _url,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _link,
              decoration: const InputDecoration(labelText: 'Opens link when tapped (optional)', hintText: 'https://...'),
              keyboardType: TextInputType.url,
              validator: _url,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _order,
              decoration: const InputDecoration(labelText: 'Position (0 shows first)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show to customers'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Deposit numbers
// ---------------------------------------------------------------------------

class ManageDepositNumbersScreen extends StatefulWidget {
  const ManageDepositNumbersScreen({super.key});

  @override
  State<ManageDepositNumbersScreen> createState() => _ManageDepositNumbersScreenState();
}

class _ManageDepositNumbersScreenState extends _ListScreenState<ManageDepositNumbersScreen, DepositNumber> {
  @override
  Future<List<DepositNumber>> fetch() => api.getDepositNumbers();

  Future<void> _edit([DepositNumber? number]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _DepositNumberDialog(number: number));
    if (saved == true) load();
  }

  Future<void> _delete(DepositNumber n) async {
    final ok = await _confirm(context, 'Remove ${n.number}?', 'Customers will no longer see this number.');
    if (ok) run(() => api.deleteDepositNumber(n.id), success: 'Number removed.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Deposit Numbers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add number'),
      ),
      body: body(
        builder: (numbers) => numbers.isEmpty
            ? ListView(children: const [
                SizedBox(height: 100),
                EmptyStateView(
                  icon: Icons.phone_in_talk_outlined,
                  title: 'No deposit numbers yet',
                  message: 'Customers see these numbers/accounts when they deposit with that method.',
                ),
              ])
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  for (final n in numbers) ...[
                    ConsoleCard(
                      onTap: () => _edit(n),
                      child: Row(
                        children: [
                          MethodBadge(method: n.method),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(n.number, style: const TextStyle(fontWeight: FontWeight.w800)),
                                Text(
                                  [methodInfo(n.method).label, if ((n.label ?? '').isNotEmpty) n.label!].join(' • '),
                                  style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: n.enabled,
                            onChanged: (v) => run(() => api.saveDepositNumber(
                                  id: n.id,
                                  method: n.method,
                                  number: n.number,
                                  label: n.label,
                                  enabled: v,
                                )),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, color: AppColors.statusFailed),
                            onPressed: () => _delete(n),
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

class _DepositNumberDialog extends StatefulWidget {
  final DepositNumber? number;
  const _DepositNumberDialog({this.number});

  @override
  State<_DepositNumberDialog> createState() => _DepositNumberDialogState();
}

class _DepositNumberDialogState extends State<_DepositNumberDialog> {
  final _formKey = GlobalKey<FormState>();
  late String _method = widget.number?.method ?? 'evc_plus';
  late final _number = TextEditingController(text: widget.number?.number);
  late final _label = TextEditingController(text: widget.number?.label);
  late bool _enabled = widget.number?.enabled ?? true;
  bool _saving = false;

  @override
  void dispose() {
    _number.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<Session>().api.saveDepositNumber(
            id: widget.number?.id,
            method: _method,
            number: _number.text.trim(),
            label: _label.text.trim().isEmpty ? null : _label.text.trim(),
            enabled: _enabled,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(context, _errorText(e, 'Could not save the number.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPlatform = methodInfo(_method).isPlatform;
    return AlertDialog(
      title: Text(widget.number == null ? 'Add deposit number' : 'Edit deposit number'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _method,
                decoration: const InputDecoration(labelText: 'Payment method'),
                items: [for (final m in paymentMethods) DropdownMenuItem(value: m.id, child: Text(m.label))],
                onChanged: (v) => setState(() => _method = v ?? _method),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _number,
                decoration: InputDecoration(labelText: isPlatform ? 'Cashier / account ID' : 'Phone number'),
                keyboardType: isPlatform ? TextInputType.text : TextInputType.phone,
                validator: (v) => (v ?? '').trim().length < 3 ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _label,
                decoration: const InputDecoration(labelText: 'Label (optional)', hintText: 'e.g. Main number'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show to customers'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

class SendNotificationScreen extends StatefulWidget {
  const SendNotificationScreen({super.key});

  @override
  State<SendNotificationScreen> createState() => _SendNotificationScreenState();
}

class _SendNotificationScreenState extends _ListScreenState<SendNotificationScreen, AppNotification> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _sending = false;

  @override
  Future<List<AppNotification>> fetch() => api.getSentNotifications();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    final ok = await _confirm(context, 'Send to all customers?', 'Every Customer App user will see this message.');
    if (!ok) return;
    setState(() => _sending = true);
    await run(() => api.sendNotification(title: _title.text.trim(), body: _body.text.trim()), success: 'Notification sent.');
    if (!mounted) return;
    _title.clear();
    _body.clear();
    setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send Notification')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ConsoleCard(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _title,
                    decoration: const InputDecoration(labelText: 'Title'),
                    maxLength: 120,
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                  ),
                  TextFormField(
                    controller: _body,
                    decoration: const InputDecoration(labelText: 'Message'),
                    maxLength: 1000,
                    maxLines: 4,
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send_rounded),
                    label: Text(_sending ? 'Sending…' : 'Send to all customers'),
                  ),
                ],
              ),
            ),
          ),
          const SectionHeader(title: 'Sent notifications'),
          if (items == null)
            (error != null ? ErrorStateView(message: error!, onRetry: load) : const LoadingView())
          else if (items!.isEmpty)
            const Text('Nothing sent yet.', style: TextStyle(color: AppColors.textSecondary))
          else
            for (final n in items!) ...[
              ConsoleCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(n.body, style: const TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(height: 6),
                    Text(formatDateTime(n.createdAt), style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Security
// ---------------------------------------------------------------------------

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirmNext = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirmNext.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final session = context.read<Session>();
    try {
      await session.api.changePassword(currentPassword: _current.text, newPassword: _next.text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(context, _errorText(e, 'Could not change the password.'));
      return;
    }
    // Every session was signed out on the server; log in with the new password.
    await session.logout();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Password changed'),
        content: const Text('Please log in again with your new password.'),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change Password')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
              validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password (at least 8 characters)'),
              validator: (v) => (v ?? '').length < 8 ? 'At least 8 characters' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _confirmNext,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm new password'),
              validator: (v) => v != _next.text ? 'Passwords do not match' : null,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Change password'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('OK')),
      ],
    ),
  );
  return ok == true;
}
