import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../models/company_balance.dart';
import '../../models/payment_methods.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import 'company_widgets.dart';

/// One company: its cash register balance and where it came from, the
/// recent balance reads, what was received and sent in the chosen period,
/// and its orders (all, open, completed or failed).
class CompanyDetailScreen extends StatefulWidget {
  final CompanyBalance company;

  const CompanyDetailScreen({super.key, required this.company});

  @override
  State<CompanyDetailScreen> createState() => _CompanyDetailScreenState();
}

class _CompanyDetailScreenState extends State<CompanyDetailScreen> {
  static const _periods = [(1, 'Today'), (7, '7 days'), (30, '30 days')];
  int _days = 1;
  String? _status; // null = all
  CompanyDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime get _from {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).subtract(Duration(days: _days - 1));
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await context
          .read<Session>()
          .api
          .getCompanyDetail(widget.company.method, from: _from, status: _status);
      if (mounted) setState(() => _detail = d);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Could not load this company.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final c = d?.company ?? widget.company;
    final warning = companyWarning(c);
    return Scaffold(
      appBar: AppBar(title: Text(c.label)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            ConsoleCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      MethodLogo(method: c.method, width: 84),
                      const Spacer(),
                      CompanyStatusPill(c.status),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(c.connected ? 'Cash register balance' : 'Balance',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(companyAmount(c),
                        key: const Key('detail-balance'),
                        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                  ),
                  const SizedBox(height: 4),
                  Text(companySource(c), style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
                  if (warning != null) ...[
                    const SizedBox(height: 10),
                    Text(warning,
                        key: const Key('detail-warning'),
                        style: TextStyle(color: companyStatusLook(c.status).$2, fontWeight: FontWeight.w700)),
                  ],
                  const Divider(height: 24),
                  if (c.limit != null) InfoRow('Register limit', '\$${c.limit}'),
                  InfoRow('Last successful check', c.lastSuccessAt == null ? 'Never' : formatDateTime(c.lastSuccessAt!)),
                  InfoRow('Open withdrawals', '${c.openWithdrawals} · \$${c.openWithdrawalAmount}'),
                  if (c.connected) InfoRow('Low-balance level', '\$${c.lowThreshold}'),
                ],
              ),
            ),
            const SizedBox(height: 14),
            ChoiceChipsRow<int>(
              options: _periods,
              selected: _days,
              onSelected: (v) {
                setState(() => _days = v);
                _load();
              },
            ),
            const SizedBox(height: 10),
            if (d == null && _error == null)
              const Padding(padding: EdgeInsets.only(top: 30), child: LoadingView())
            else if (d == null)
              ErrorStateView(message: _error!, onRetry: _load)
            else ...[
              TwoColumnGrid(children: [
                StatCard(
                  icon: Icons.south_rounded,
                  color: AppColors.statusCompleted,
                  value: '\$${d.company.period.received}',
                  label: 'Received · ${d.company.period.receivedCount} deposits',
                ),
                StatCard(
                  icon: Icons.north_rounded,
                  color: AppColors.statusProcessing,
                  value: '\$${d.company.period.sent}',
                  label: 'Sent · ${d.company.period.sentCount} withdrawals',
                ),
                StatCard(
                  icon: Icons.hourglass_top_rounded,
                  color: AppColors.statusPending,
                  value: '${d.company.period.open}',
                  label: 'Pending',
                ),
                StatCard(
                  icon: Icons.close_rounded,
                  color: AppColors.statusFailed,
                  value: '${d.company.period.failed}',
                  label: 'Failed',
                ),
              ]),
              const SizedBox(height: 8),
              const SectionHeader(title: 'Transactions'),
              ChoiceChipsRow<String?>(
                options: const [(null, 'All'), ('open', 'Pending'), ('completed', 'Completed'), ('failed', 'Failed')],
                selected: _status,
                onSelected: (v) {
                  setState(() => _status = v);
                  _load();
                },
              ),
              const SizedBox(height: 8),
              if (d.orders.isEmpty)
                const ConsoleCard(
                  child: Text('No transactions in this period.', style: TextStyle(color: AppColors.textSecondary)),
                )
              else
                for (final o in d.orders) ...[
                  _OrderTile(order: o),
                  const SizedBox(height: 8),
                ],
              if (c.connected) ...[
                const SectionHeader(title: 'Balance checks'),
                if (d.checks.isEmpty)
                  const ConsoleCard(child: Text('Not read yet.', style: TextStyle(color: AppColors.textSecondary)))
                else
                  ConsoleCard(
                    child: Column(
                      children: [
                        for (final b in d.checks)
                          InfoRow(formatDateTime(b.checkedAt), b.ok ? '\$${b.balance}' : 'Failed: ${b.error ?? ''}'),
                      ],
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  final CompanyOrder order;
  const _OrderTile({required this.order});

  @override
  Widget build(BuildContext context) {
    final o = order;
    final deposit = o.direction == 'deposit';
    return ConsoleCard(
      key: Key('company-order-${o.orderCode}'),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TintedIcon(
            icon: deposit ? Icons.south_rounded : Icons.north_rounded,
            color: deposit ? AppColors.statusCompleted : AppColors.statusProcessing,
            size: 40,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${deposit ? 'Deposit' : 'Withdrawal'} · ${o.orderCode}',
                    style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                Text(
                  [if (o.customerName != null) o.customerName!, if (o.accountId != null) 'ID ${o.accountId}'].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                ),
                Text(formatDateTime(o.createdAt), style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
                if (o.waitingTopUp)
                  const Text('Waiting for a cash register top-up',
                      style: TextStyle(color: AppColors.statusFailed, fontSize: 12, fontWeight: FontWeight.w700))
                else if (o.status == 'failed' && o.note != null)
                  Text(o.note!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.statusFailed, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(o.amount == null ? 'Amount pending' : '${deposit ? '+' : '-'}\$${o.amount}',
                  style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              const SizedBox(height: 6),
              StatusPill(o.status),
            ],
          ),
        ],
      ),
    );
  }
}
