import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/kyc.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';

final _when = DateFormat('d MMM yyyy, HH:mm');

/// KYC Management (manage_kyc_applications): applications by status, with a
/// search by name, phone or document number. The server checks each
/// submission; without an identity-verification service every application
/// comes here for an admin.
class KycManagementScreen extends StatefulWidget {
  const KycManagementScreen({super.key});

  @override
  State<KycManagementScreen> createState() => _KycManagementScreenState();
}

class _KycManagementScreenState extends State<KycManagementScreen> {
  static const _statuses = ['pending_review', 'pending_auto', 'approved', 'rejected', 'resubmission_required', 'all'];

  String _status = 'pending_review';
  final _search = TextEditingController();
  List<KycListItem>? _items;
  Map<String, int> _counts = const {};
  String _provider = 'none';
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _items == null;
      _error = null;
    });
    try {
      final r = await context.read<Session>().api.getKycApplications(status: _status, query: _search.text.trim());
      if (!mounted) return;
      setState(() {
        _items = r.items;
        _counts = r.counts;
        _provider = r.provider;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Could not load KYC applications.';
        _loading = false;
      });
    }
  }

  String _label(String s) {
    final total = _counts.values.fold<int>(0, (a, b) => a + b);
    if (s == 'all') return 'All ($total)';
    return '${kycStatusLabels[s] ?? s} (${_counts[s] ?? 0})';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('KYC Management')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const LoadingView()
            : (_error != null && _items == null
                ? ErrorStateView(message: _error!, onRetry: _load)
                : ListView(
                    key: const Key('kyc-list'),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    children: [
                      Text(
                        _provider == 'none'
                            ? 'No identity-verification service is set up: every application is checked by the server, then by an admin here.'
                            : 'Identity service: $_provider. Only what it verifies and every check passes is approved automatically.',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 10),
                      ChoiceChipsRow<String>(
                        options: [for (final s in _statuses) (s, _label(s))],
                        selected: _status,
                        onSelected: (s) {
                          setState(() => _status = s);
                          _load();
                        },
                      ),
                      const SizedBox(height: 10),
                      SearchField(hint: 'Search by name, phone or document number…', controller: _search, onSubmitted: (_) => _load()),
                      const SizedBox(height: 10),
                      if (_items!.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 40),
                          child: EmptyStateView(icon: Icons.badge_outlined, title: 'Nothing here', message: 'No applications with this status.'),
                        )
                      else
                        for (final x in _items!)
                          Padding(
                            key: Key('kyc-row-${x.id}'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ConsoleCard(
                              onTap: () async {
                                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => KycReviewScreen(id: x.id)));
                                if (mounted) _load();
                              },
                              child: Row(children: [
                                Icon(x.documentType == 'passport' ? Icons.menu_book_rounded : Icons.badge_rounded,
                                    color: AppColors.purple, size: 30),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(x.customerName?.isNotEmpty == true ? x.customerName! : x.fullName,
                                        style: const TextStyle(fontWeight: FontWeight.w700)),
                                    Text('+${x.phone} · ${x.documentType == 'passport' ? 'Passport' : 'National ID'} ${x.documentNumber}',
                                        maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                                    if (x.submittedAt != null)
                                      Text(_when.format(x.submittedAt!.toLocal()),
                                          style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
                                  ]),
                                ),
                                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                  StatusPill(x.status == 'approved' ? 'completed' : (x.status == 'rejected' ? 'failed' : 'pending')),
                                  if (x.failedChecks > 0)
                                    Text('${x.failedChecks} check(s) failed',
                                        style: const TextStyle(fontSize: 11.5, color: AppColors.statusFailed)),
                                ]),
                              ]),
                            ),
                          ),
                    ],
                  )),
      ),
    );
  }
}

/// Review KYC Application: the documents, the details, the server's checks
/// (and the identity service's result), the history; Approve / Reject /
/// Request Resubmission, each with a reason.
class KycReviewScreen extends StatefulWidget {
  const KycReviewScreen({super.key, required this.id});

  final String id;

  @override
  State<KycReviewScreen> createState() => _KycReviewScreenState();
}

class _KycReviewScreenState extends State<KycReviewScreen> {
  KycApplication? _app;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await context.read<Session>().api.getKycApplication(widget.id);
      if (mounted) setState(() => _app = a);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Could not load the application.');
    }
  }

  Future<void> _decide(String decision) async {
    final reason = TextEditingController(text: decision == 'approve' ? 'Documents checked' : '');
    final title = {'approve': 'Approve', 'reject': 'Reject', 'resubmit': 'Request Resubmission'}[decision]!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$title?'),
        content: TextField(
          key: const Key('kyc-reason'),
          controller: reason,
          autofocus: true,
          decoration: InputDecoration(
            labelText: decision == 'approve' ? 'Reason (kept with the decision)' : 'Reason (shown to the customer)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const Key('kyc-confirm'), onPressed: () => Navigator.pop(context, true), child: Text(title)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<Session>().api.decideKyc(widget.id, decision, reason.text.trim());
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Could not save the decision.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _app;
    return Scaffold(
      appBar: AppBar(title: const Text('Review KYC Application')),
      body: a == null
          ? (_error == null ? const LoadingView() : ErrorStateView(message: _error!, onRetry: _load))
          : ListView(
              key: const Key('kyc-review'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Text(a.item.customerName?.isNotEmpty == true ? a.item.customerName! : a.item.fullName,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                Text('+${a.item.phone}', style: const TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                Text(kycStatusLabels[a.item.status] ?? a.item.status,
                    key: const Key('kyc-review-status'), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (a.item.submittedAt != null)
                  Text('Submitted ${_when.format(a.item.submittedAt!.toLocal())}', style: const TextStyle(color: AppColors.textFaint)),
                const SectionHeader(title: 'Documents'),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final kind in ['front', 'back', 'selfie'])
                    if (a.documents[kind] != null)
                      GestureDetector(
                        key: Key('kyc-doc-$kind'),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (_) => Dialog(child: InteractiveViewer(child: Image.memory(a.documents[kind]!))),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text({'front': a.item.documentType == 'passport' ? 'Passport photo' : 'ID front', 'back': 'ID back',
                            'selfie': 'Selfie'}[kind]!, style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              width: 150,
                              height: 110,
                              child: Image.memory(a.documents[kind]!, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const ColoredBox(color: AppColors.border,
                                      child: Center(child: Text('Not an image')))),
                            ),
                          ),
                        ]),
                      ),
                ]),
                const SectionHeader(title: 'Information'),
                InfoRow('Document', a.item.documentType == 'passport' ? 'Passport' : 'National ID'),
                InfoRow('Full name', a.item.fullName),
                InfoRow('Document number', a.item.documentNumber),
                InfoRow('Country of issue', a.item.country),
                InfoRow('Date of birth', a.dateOfBirth ?? '—'),
                InfoRow('Expiry date', a.expiryDate ?? '—'),
                const SectionHeader(title: 'Verification Result'),
                if (a.reviewReason != null) Text(a.reviewReason!, key: const Key('kyc-review-reason')),
                for (final c in a.checks)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(c.ok ? Icons.check_circle_rounded : Icons.error_rounded,
                        color: c.ok ? AppColors.statusCompleted : AppColors.statusFailed),
                    title: Text(c.key.replaceAll('_', ' ')),
                    subtitle: c.detail == null ? null : Text(c.detail!),
                  ),
                InfoRow('Identity service', a.provider ?? 'none'),
                if (a.decided) ...[
                  const SectionHeader(title: 'Decision'),
                  InfoRow('Decided', a.decidedAt == null ? '—' : _when.format(a.decidedAt!.toLocal())),
                  InfoRow('By', a.decidedBy ?? 'Automatic (identity service)'),
                  InfoRow('Reason', a.decisionReason ?? '—'),
                ],
                if (a.history.isNotEmpty) ...[
                  const SectionHeader(title: 'History'),
                  for (final h in a.history)
                    Text('${kycStatusLabels[h['status']] ?? h['status']} · ${h['reason'] ?? ''}',
                        style: const TextStyle(color: AppColors.textSecondary)),
                ],
                if (!a.decided) ...[
                  const SizedBox(height: 16),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(
                      key: const Key('kyc-approve'),
                      style: FilledButton.styleFrom(backgroundColor: AppColors.statusCompleted),
                      onPressed: _busy ? null : () => _decide('approve'),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Approve'),
                    ),
                    FilledButton.icon(
                      key: const Key('kyc-reject'),
                      style: FilledButton.styleFrom(backgroundColor: AppColors.statusFailed),
                      onPressed: _busy ? null : () => _decide('reject'),
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('Reject'),
                    ),
                    FilledButton.icon(
                      key: const Key('kyc-resubmit'),
                      style: FilledButton.styleFrom(backgroundColor: AppColors.accentOrange),
                      onPressed: _busy ? null : () => _decide('resubmit'),
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('Request Resubmission'),
                    ),
                  ]),
                ],
              ],
            ),
    );
  }
}
