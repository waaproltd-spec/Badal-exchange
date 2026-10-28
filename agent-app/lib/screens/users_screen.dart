import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';
import 'customer_info_screen.dart';

/// Users = Customer App customers (not agents). Customer counts (total,
/// active, blocked, and new in the chosen period), then the list: searchable
/// by name or phone, filterable by status. Tapping a customer opens
/// read-only Customer Info.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  static const _pageSize = 50;
  final _search = TextEditingController();
  String _status = 'all';
  String _sort = 'newest';
  List<CustomerSummary> _customers = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  CustomerOverview? _overview;

  /// The period "New Customers" counts: a preset, or a custom range.
  String _period = 'today';
  DateTimeRange? _custom;

  static const _periods = [
    ('today', 'Today', 'Maanta'),
    ('yesterday', 'Yesterday', 'Shalay'),
    ('month', 'This Month', 'Bishan'),
    ('3m', '3 Months', '3 Bilood'),
    ('6m', '6 Months', '6 Bilood'),
    ('1y', '1 Year', 'Sanad'),
    ('custom', 'Custom', 'Taariikh Gaar ah'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
    _loadOverview();
  }

  DateTimeRange _range() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    return switch (_period) {
      'yesterday' => DateTimeRange(start: yesterday, end: yesterday),
      'month' => DateTimeRange(start: DateTime(today.year, today.month, 1), end: today),
      '3m' => DateTimeRange(start: DateTime(today.year, today.month - 3, today.day), end: today),
      '6m' => DateTimeRange(start: DateTime(today.year, today.month - 6, today.day), end: today),
      '1y' => DateTimeRange(start: DateTime(today.year - 1, today.month, today.day), end: today),
      'custom' => _custom ?? DateTimeRange(start: today, end: today),
      _ => DateTimeRange(start: today, end: today),
    };
  }

  /// The counts; their failure (or an older server) never hides the list.
  Future<void> _loadOverview() async {
    final r = _range();
    try {
      final o = await context.read<Session>().api.getCustomerOverview(from: r.start, to: r.end);
      if (mounted) setState(() => _overview = o);
    } catch (_) {}
  }

  Future<void> _choosePeriod(String p) async {
    if (p == 'custom') {
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2026, 1, 1),
        lastDate: DateTime.now(),
        initialDateRange: _custom,
      );
      if (picked == null || !mounted) return;
      _custom = picked;
    }
    setState(() => _period = p);
    _loadOverview();
  }

  Future<void> _refresh() async {
    _loadOverview();
    await _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = _customers.isEmpty;
        _error = null;
      }
    });
    try {
      final page = await context.read<Session>().api.getCustomers(
            query: _search.text,
            status: _status,
            sort: _sort,
            offset: more ? _customers.length : 0,
          );
      if (!mounted) return;
      setState(() {
        _customers = more ? [..._customers, ...page] : page;
        _hasMore = page.length == _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Failed to load customers.';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _setStatus(String v) {
    setState(() => _status = v);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final o = _overview;
    String count(int? n) => n == null ? '' : ' ($n)';
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          SingleChildScrollView(
            key: const Key('users-periods'),
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (id, en, so) in _periods)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    key: Key('users-period-$id'),
                    avatar: Icon(Icons.calendar_month_rounded,
                        size: 18, color: _period == id ? AppColors.onPrimary : AppColors.textSecondary),
                    label: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(en, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(so, style: const TextStyle(fontSize: 11)),
                    ]),
                    selected: _period == id,
                    showCheckmark: false,
                    selectedColor: AppColors.primaryDark,
                    labelStyle: TextStyle(color: _period == id ? AppColors.onPrimary : AppColors.textPrimary),
                    onSelected: (_) => _choosePeriod(id),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          if (o != null) ...[
            TwoColumnGrid(children: [
              StatCard(
                icon: Icons.groups_rounded,
                color: AppColors.purple,
                value: '${o.total}',
                label: 'Total Customers',
                caption: 'Wadarta Macaamiisha',
                onTap: () => _setStatus('all'),
              ),
              StatCard(
                icon: Icons.person_rounded,
                color: AppColors.statusCompleted,
                value: '${o.active}',
                label: 'Active Customers',
                caption: 'Macaamiisha Firfircoon',
                onTap: () => _setStatus('active'),
              ),
              StatCard(
                icon: Icons.block_rounded,
                color: AppColors.statusFailed,
                value: '${o.blocked}',
                label: 'Blocked Customers',
                caption: 'Macaamiisha La Xannibay',
                onTap: () => _setStatus('blocked'),
              ),
              StatCard(
                key: const Key('users-new'),
                icon: Icons.person_add_alt_1_rounded,
                color: AppColors.statusProcessing,
                value: '${o.joined}',
                label: 'New Customers',
                caption: _periods.firstWhere((p) => p.$1 == _period).$2,
              ),
            ]),
            const SizedBox(height: 12),
          ],
          SearchField(
            hint: 'Search by name or phone number',
            controller: _search,
            onSubmitted: (_) => _load(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ChoiceChipsRow<String>(
                  options: [
                    ('all', 'All${count(o?.total)}'),
                    ('active', 'Active${count(o?.active)}'),
                    ('blocked', 'Blocked${count(o?.blocked)}'),
                  ],
                  selected: _status,
                  onSelected: _setStatus,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Sort',
                initialValue: _sort,
                icon: const Icon(Icons.sort_rounded),
                onSelected: (v) {
                  setState(() => _sort = v);
                  _load();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'newest', child: Text('Newest first')),
                  PopupMenuItem(value: 'oldest', child: Text('Oldest first')),
                  PopupMenuItem(value: 'balance', child: Text('Highest balance')),
                  PopupMenuItem(value: 'name', child: Text('Name A–Z')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(padding: EdgeInsets.only(top: 80), child: LoadingView())
          else if (_error != null && _customers.isEmpty)
            ErrorStateView(message: _error!, onRetry: _load)
          else if (_customers.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: EmptyStateView(icon: Icons.people_outline_rounded, title: 'No customers found'),
            )
          else ...[
            for (final c in _customers) ...[
              _CustomerTile(
                customer: c,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => CustomerInfoScreen(customerId: c.id, name: c.name)),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_hasMore)
              Center(
                child: TextButton(
                  onPressed: _loadingMore ? null : () => _load(more: true),
                  child: Text(_loadingMore ? 'Loading…' : 'Load more'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CustomerTile extends StatelessWidget {
  final CustomerSummary customer;
  final VoidCallback onTap;

  const _CustomerTile({required this.customer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const TintedIcon(icon: Icons.person_rounded, color: AppColors.purple, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  customer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(customer.phone, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                if (customer.registeredAt != null)
                  Text(
                    'Joined ${formatDate(customer.registeredAt!)}',
                    style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint),
                  ),
                const SizedBox(height: 6),
                Wrap(spacing: 12, runSpacing: 2, children: [
                  _Count(Icons.receipt_long_outlined, '${customer.orders} orders'),
                  _Count(Icons.south_rounded, '${customer.deposits} deposits'),
                  _Count(Icons.north_rounded, '${customer.withdrawals} withdrawals'),
                  _Count(Icons.history_rounded, '${customer.transactions} transactions'),
                ]),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '\$${customer.walletBalance}',
                style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.statusCompleted),
              ),
              const SizedBox(height: 4),
              StatusPill(customer.status),
            ],
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
        ],
      ),
    );
  }
}

/// A small icon and a count under a customer's name.
class _Count extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Count(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: AppColors.textFaint),
      const SizedBox(width: 3),
      Text(text, style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
    ]);
  }
}
