import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/api_config.dart';
import '../../api/api_exception.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';

/// Sahal access code from an SMS-forwarding app. When the merchant phone
/// does not run this app, an app such as "SMS Forwarder" can send the Sahal
/// SMS to the server (Add filter -> Incoming SMS -> recipient: URL). The
/// server uses the code exactly as the Agent App would: only while Sahal is
/// waiting for it, once. A manager makes the token here; it is shown once,
/// and a new one replaces (revokes) the old.
class SahalForwarderCard extends StatefulWidget {
  const SahalForwarderCard({super.key});

  /// Where the forwarding app posts.
  static String get url => '${ApiConfig.supabaseUrl}/functions/v1/sahal-sms-hook';

  @override
  State<SahalForwarderCard> createState() => _SahalForwarderCardState();
}

class _SahalForwarderCardState extends State<SahalForwarderCard> {
  Map<String, dynamic>? _status;
  String? _token;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<Session>().api.getSahalSmsHook();
      if (mounted) setState(() => _status = s);
    } catch (_) {
      // Not available (older server): the card just offers the button.
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _make() => _run(() async {
        final api = context.read<Session>().api;
        final token = await api.rotateSahalSmsHook();
        final s = await api.getSahalSmsHook();
        if (mounted) setState(() {
          _token = token;
          _status = s;
        });
      });

  Future<void> _revoke() => _run(() async {
        final s = await context.read<Session>().api.revokeSahalSmsHook();
        if (mounted) setState(() {
          _token = null;
          _status = s;
        });
      });

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied')));
  }

  @override
  Widget build(BuildContext context) {
    final configured = _status?['configured'] == true;
    final last = _status?['lastUsedAt'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const GroupLabel('SMS forwarder (optional)'),
      ConsoleCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            configured
                ? 'Set up${last != null ? ' · last SMS received ${last.substring(0, 16).replaceFirst('T', ' ')} UTC' : ' · no SMS received yet'}.'
                : 'Not set up. Use it when the merchant phone runs an SMS-forwarding app instead of this one.',
            key: const Key('forwarder-status'),
          ),
          if (_token != null) ...[
            const SizedBox(height: 12),
            const Text('Put these in the forwarding app (Add filter → Incoming SMS/RCS → Recipients → Add → URL). '
                'This token is shown once: copy it now.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            _Copyable(label: 'URL', value: SahalForwarderCard.url, onCopy: () => _copy(SahalForwarderCard.url, 'URL')),
            _Copyable(label: 'Header  Authorization', value: 'Bearer $_token', onCopy: () => _copy('Bearer $_token', 'Header')),
            const SizedBox(height: 6),
            const Text('Method POST, JSON body {"from": "<sender>", "text": "<message>"} using the forwarding app\'s '
                'own placeholders for the sender and the message. Filter on messages containing "Sahal".',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: AppColors.statusFailed)),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              key: const Key('forwarder-make'),
              onPressed: _busy ? null : _make,
              icon: const Icon(Icons.key_rounded),
              label: Text(configured ? 'New token (replaces the old)' : 'Create token'),
            ),
            if (configured)
              TextButton(
                key: const Key('forwarder-revoke'),
                onPressed: _busy ? null : _revoke,
                child: const Text('Turn off'),
              ),
          ]),
        ]),
      ),
    ]);
  }
}

class _Copyable extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onCopy;

  const _Copyable({required this.label, required this.value, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
        ]),
      ),
      IconButton(tooltip: 'Copy', onPressed: onCopy, icon: const Icon(Icons.copy_rounded, size: 20)),
    ]);
  }
}
