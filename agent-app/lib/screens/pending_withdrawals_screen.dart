import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/order.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/order_card.dart';
import '../widgets/state_views.dart';
import '../widgets/withdrawal_action_sheets.dart';

/// Pending Withdrawals: pending/processing withdrawal orders. The agent
/// moves each one through: Start Processing -> (agent actually sends the
/// payout via EVC Plus USSD/agent line or the WinWin manager app) ->
/// Complete (with the real transaction reference) or Mark Failed.
class PendingWithdrawalsScreen extends StatefulWidget {
  const PendingWithdrawalsScreen({super.key});

  @override
  State<PendingWithdrawalsScreen> createState() => _PendingWithdrawalsScreenState();
}

class _PendingWithdrawalsScreenState extends State<PendingWithdrawalsScreen> {
  List<Order>? _orders;
  String? _error;
  bool _loading = true;
  final Set<String> _busyOrderIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await context.read<Session>().api.getPendingWithdrawals();
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Failed to load pending withdrawals.';
        _loading = false;
      });
    }
  }

  void _showSnack(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  Future<void> _runAction(String orderId, Future<void> Function() action) async {
    setState(() => _busyOrderIds.add(orderId));
    try {
      await action();
      await _load();
    } catch (e) {
      _showSnack(
        e is ApiException ? e.message : 'Action failed. Please try again.',
        color: AppColors.statusFailed,
      );
    } finally {
      if (mounted) setState(() => _busyOrderIds.remove(orderId));
    }
  }

  Future<void> _startProcessing(Order order) async {
    await _runAction(order.id, () async {
      await context.read<Session>().api.startWithdrawal(order.id);
      _showSnack('Marked as processing.', color: AppColors.statusProcessing);
    });
  }

  Future<void> _complete(Order order) async {
    final ref = await showCompleteWithdrawalSheet(context);
    if (ref == null || ref.isEmpty || !mounted) return;
    await _runAction(order.id, () async {
      await context.read<Session>().api.completeWithdrawal(order.id, transactionRef: ref);
      _showSnack('Withdrawal completed.', color: AppColors.statusCompleted);
    });
  }

  Future<void> _fail(Order order) async {
    final reason = await showFailWithdrawalSheet(context);
    if (reason == null || reason.isEmpty || !mounted) return;
    await _runAction(order.id, () async {
      await context.read<Session>().api.failWithdrawal(order.id, reason: reason);
      _showSnack('Withdrawal marked failed. Balance released to customer.', color: AppColors.statusFailed);
    });
  }

  List<Widget> _actionsFor(Order order) {
    final busy = _busyOrderIds.contains(order.id);
    if (busy) {
      return [
        const SizedBox(
          height: 36,
          width: 36,
          child: Padding(
            padding: EdgeInsets.all(6),
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      ];
    }
    if (order.status == 'pending') {
      return [
        ElevatedButton(onPressed: () => _startProcessing(order), child: const Text('Start Processing')),
      ];
    }
    if (order.status == 'processing') {
      return [
        ElevatedButton(onPressed: () => _complete(order), child: const Text('Complete')),
        OutlinedButton(
          onPressed: () => _fail(order),
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.statusFailed),
          child: const Text('Mark Failed'),
        ),
      ];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: _loading
          ? const LoadingView()
          : (_error != null
              ? ErrorStateView(message: _error!, onRetry: _load)
              : (_orders!.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        EmptyStateView(
                          icon: Icons.arrow_circle_up_rounded,
                          title: 'No pending withdrawals',
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 8, bottom: 24),
                      itemCount: _orders!.length,
                      itemBuilder: (context, index) {
                        final order = _orders![index];
                        return OrderCard(order: order, actions: _actionsFor(order));
                      },
                    ))),
    );
  }
}
