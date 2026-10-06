import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';
import 'customer_info_screen.dart';

/// Users = Customer App customers (not agents). Searchable by name or phone,
/// filterable by status. Tapping a customer opens read-only Customer Info.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  static const _pageSize = 50;
  final _search = TextEditingController();
  String _status = 'all';
  List<CustomerSummary> _customers = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

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

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          SearchField(
            hint: 'Search by name or phone number',
            controller: _search,
            onSubmitted: (_) => _load(),
          ),
          const SizedBox(height: 12),
          ChoiceChipsRow<String>(
            options: const [('all', 'All'), ('active', 'Active'), ('blocked', 'Blocked')],
            selected: _status,
            onSelected: (v) {
              setState(() => _status = v);
              _load();
            },
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
