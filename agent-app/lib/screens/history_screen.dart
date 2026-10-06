import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/console.dart';
import '../models/payment_methods.dart';
import '../state/history_filter.dart';
import '../state/live_updates.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/console_widgets.dart';
import '../widgets/state_views.dart';

/// Complete transaction history: deposits, withdrawals and payment
/// confirmations (SMS / agent-entered), with search (customer name, phone,
/// account ID, order code) and filters for type, status, method and date.
class HistoryScreen extends StatefulWidget {
  /// Filters pushed from other tabs (Dashboard, Reports).
  final ValueNotifier<HistoryFilter?> requests;

  const HistoryScreen({super.key, required this.requests});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with LiveRefresh {
  static const _pageSize = 50;
  static final _pretty = DateFormat('MMM d');

  final _search = TextEditingController();
  HistoryFilter _filter = const HistoryFilter();
  List<HistoryItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.requests.addListener(_onRequest);
    if (widget.requests.value != null) {
      _onRequest();
    } else {
      _load();
    }
    listenForLiveChanges(context.read<Session>().live.changes, () {
      if (!_loadingMore) _load();
    });
  }

  @override
  void dispose() {
    widget.requests.removeListener(_onRequest);
    _search.dispose();
    super.dispose();
  }

  void _onRequest() {
    final requested = widget.requests.value;
    if (requested == null) return;
    widget.requests.value = null;
    _search.text = requested.query;
    _filter = requested;
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    final f = _filter;
    try {
      final page = await context.read<Session>().api.getHistory(
            query: f.query,
            type: f.type,
            status: f.status,
            method: f.method,
            from: f.from,
            to: f.to,
            offset: more ? _items.length : 0,
            limit: _pageSize,
          );
      if (!mounted) return;
      setState(() {
        _items = more ? [..._items, ...page] : page;
        _hasMore = page.length == _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Failed to load history.';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _apply(HistoryFilter filter) {
    setState(() => _filter = filter);
    _load();
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<HistoryFilter>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _FilterSheet(initial: _filter),
    );
    if (result != null) _apply(result);
  }

  List<Widget> _activeFilterChips() {
    final f = _filter;
    final chips = <Widget>[];
    void add(String label, HistoryFilter Function() clear) {
      chips.add(InputChip(
        label: Text(label),
        onDeleted: () => _apply(clear()),
        backgroundColor: AppColors.surface,
        side: const BorderSide(color: AppColors.border),
      ));
    }

    if (f.status != null) add('Status: ${f.status}', () => f.copyWith(status: () => null));
    if (f.method != null) add(methodInfo(f.method!).label, () => f.copyWith(method: () => null));
    if (f.from != null || f.to != null) {
      final from = f.from != null ? _pretty.format(DateTime.parse(f.from!)) : '…';
      final to = f.to != null ? _pretty.format(DateTime.parse(f.to!)) : '…';
      add('$from – $to', () => f.copyWith(from: () => null, to: () => null));
    }
    return chips;
  }

  @override
  Widget build(BuildContext context) {
    final chips = _activeFilterChips();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: SearchField(
                  hint: 'Search customer, phone, account or order',
                  controller: _search,
                  onSubmitted: (q) => _apply(_filter.copyWith(query: q)),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _openFilters,
                icon: Badge(
                  isLabelVisible: _filter.hasExtraFilters,
                  smallSize: 8,
                  child: const Icon(Icons.tune_rounded),
                ),
                tooltip: 'Filters',
              ),
            ],
          ),
          const SizedBox(height: 12),
          ChoiceChipsRow<String>(
            options: const [
              ('all', 'All'),
              ('deposit', 'Deposits'),
              ('withdraw', 'Withdrawals'),
              ('order', 'Orders'),
              ('confirmation', 'Confirmations'),
            ],
            selected: _filter.type,
            onSelected: (t) => _apply(_filter.copyWith(type: t)),
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: chips),
          ],
          const SizedBox(height: 12),
          if (_loading)
            const Padding(padding: EdgeInsets.only(top: 80), child: LoadingView())
          else if (_error != null && _items.isEmpty)
            ErrorStateView(message: _error!, onRetry: _load)
          else if (_items.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: EmptyStateView(icon: Icons.history_rounded, title: 'No transactions found'),
            )
          else ...[
            for (final item in _items) ...[
              ActivityTile(item: item, onTap: () => showActivityDetails(context, item)),
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

class _FilterSheet extends StatefulWidget {
  final HistoryFilter initial;
  const _FilterSheet({required this.initial});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  static final _iso = DateFormat('yyyy-MM-dd');
  static final _pretty = DateFormat('MMM d, yyyy');

  late String? _status = widget.initial.status;
  late String? _method = widget.initial.method;
  late DateTimeRange? _range = widget.initial.from != null && widget.initial.to != null
      ? DateTimeRange(start: DateTime.parse(widget.initial.from!), end: DateTime.parse(widget.initial.to!))
      : null;

  static const _orderStatuses = ['pending', 'processing', 'completed', 'failed', 'cancelled'];
  static const _confirmationStatuses = ['matched', 'unmatched', 'duplicate'];

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: _range,
    );
    if (picked != null) setState(() => _range = picked);
  }

  @override
  Widget build(BuildContext context) {
    final statuses = widget.initial.type == 'confirmation'
        ? _confirmationStatuses
        : widget.initial.type == 'all'
            ? [..._orderStatuses, ..._confirmationStatuses]
            : _orderStatuses;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Filters', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String?>(
            value: _status,
            decoration: const InputDecoration(labelText: 'Status'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Any status')),
              for (final s in statuses) DropdownMenuItem(value: s, child: Text(s[0].toUpperCase() + s.substring(1))),
            ],
            onChanged: (v) => setState(() => _status = v),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String?>(
            value: _method,
            decoration: const InputDecoration(labelText: 'Payment method'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Any method')),
              for (final m in paymentMethods) DropdownMenuItem(value: m.id, child: Text(m.label)),
            ],
            onChanged: (v) => setState(() => _method = v),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _pickRange,
            icon: const Icon(Icons.date_range_rounded),
            label: Text(
              _range == null ? 'Any date' : '${_pretty.format(_range!.start)} – ${_pretty.format(_range!.end)}',
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(
                    HistoryFilter(type: widget.initial.type, query: widget.initial.query),
                  ),
                  child: const Text('Clear'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(
                    widget.initial.copyWith(
                      status: () => _status,
                      method: () => _method,
                      from: () => _range != null ? _iso.format(_range!.start) : null,
                      to: () => _range != null ? _iso.format(_range!.end) : null,
                    ),
                  ),
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
