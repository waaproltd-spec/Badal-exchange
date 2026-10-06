import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/match_result.dart';
import '../models/order.dart';
import '../state/live_updates.dart';
import '../state/session.dart';
import '../widgets/order_card.dart';
import '../widgets/state_views.dart';
import '../widgets/payment_confirm_sheet.dart';

/// Pending Deposits: EVC Plus deposits are matched automatically in the
/// background by the SMS bridge (see lib/sms/sms_bridge.dart) — a matched
/// order simply disappears from this list on the next refresh, since its
/// status moves to completed. Every other payment (any method) is confirmed
/// by the agent, from an order's "Confirm payment" button or the floating
/// action button (see lib/widgets/payment_confirm_sheet.dart).
class PendingDepositsScreen extends StatefulWidget {
  const PendingDepositsScreen({super.key});

  @override
  State<PendingDepositsScreen> createState() => _PendingDepositsScreenState();
}

class _PendingDepositsScreenState extends State<PendingDepositsScreen> with LiveRefresh {
  List<Order>? _orders;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    listenForLiveChanges(context.read<Session>().live.changes, _load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = _orders == null;
      _error = null;
    });
    try {
      final orders = await context.read<Session>().api.getPendingDeposits();
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Failed to load pending deposits.';
        _loading = false;
      });
    }
  }

  Future<void> _confirm({Order? order}) async {
    final result = await showPaymentConfirmSheet(context, order: order);
    if (result == null || !mounted) return;
    showMatchResultSnackBar(context, result);
    if (result.status == MatchStatus.matched) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
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
                            icon: Icons.arrow_circle_down_rounded,
                            title: 'No pending deposits',
                            message: 'EVC Plus deposits match automatically once the payment SMS arrives. '
                                'Confirm other payments with the button below.',
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 96),
                        itemCount: _orders!.length,
                        itemBuilder: (context, index) {
                          final order = _orders![index];
                          return OrderCard(
                            order: order,
                            actions: [
                              OutlinedButton.icon(
                                onPressed: () => _confirm(order: order),
                                icon: const Icon(Icons.verified_rounded, size: 18),
                                label: const Text('Confirm payment'),
                              ),
                            ],
                          );
                        },
                      ))),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _confirm(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Confirm payment'),
      ),
    );
  }
}
