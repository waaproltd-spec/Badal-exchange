import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_exception.dart';
import '../models/order.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../utils/ussd.dart';
import '../widgets/order_card.dart';
import '../widgets/state_views.dart';
import '../widgets/withdrawal_action_sheets.dart';

/// Pending Withdrawals: pending/processing withdrawal orders. The customer
/// always requests the withdrawal first (see the customer app) -- the agent
/// only ever processes/pays a request that already exists here.
///
/// For EVC Plus, "Pay / Confirm Payment" claims the order (same
/// startProcessingWithdraw the manual flow always used, so two agents can
/// never both claim it) and auto-dials *712*{customer's number}*{amount}#
/// from the agent's own phone in one tap; "Dial to Pay" on an
/// already-processing order re-dials if the call was dropped or needs a
/// retry. The agent enters their own PIN in the native EVC Plus USSD prompt
/// this opens -- it is never captured, stored, or entered by this app. Once
/// the agent has actually sent the money (or confirmed it failed/was
/// cancelled in that native prompt), Complete finalizes the customer's
/// reserved balance with the real transaction reference, or Mark Failed
/// releases it back to the customer. WinWin orders (no dial step) still use
/// plain Start Processing.
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
  String? _evcPayoutTemplate;

  @override
  void initState() {
    super.initState();
    _load();
    context.read<Session>().api.getEvcPayoutTemplate().then((template) {
      if (mounted) setState(() => _evcPayoutTemplate = template);
    }).catchError((_) {});
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

  Future<void> _dialToPay(Order order) async {
    final dialUri = buildPayoutUssdDialUri(_evcPayoutTemplate, order.phoneNumber ?? '', order.netAmount);
    if (dialUri == null) return;
    try {
      await launchUrl(Uri.parse(dialUri));
    } catch (_) {
      _showSnack('Could not open the dialer.', color: AppColors.statusFailed);
    }
  }

  /// Claims the withdrawal (startWithdrawal) and immediately auto-dials the
  /// EVC Plus payout USSD in one tap. The agent still has to confirm the
  /// real outcome afterwards via Complete/Mark Failed below -- dialing never
  /// finalizes anything on its own.
  Future<void> _payAndDial(Order order) async {
    await _runAction(order.id, () async {
      await context.read<Session>().api.startWithdrawal(order.id);
      final dialUri = buildPayoutUssdDialUri(_evcPayoutTemplate, order.phoneNumber ?? '', order.netAmount);
      if (dialUri != null) {
        try {
          await launchUrl(Uri.parse(dialUri));
          _showSnack('Dialing EVC Plus -- confirm below once the payment is done.', color: AppColors.statusProcessing);
        } catch (_) {
          _showSnack('Could not open the dialer -- use Dial to Pay below to retry.', color: AppColors.statusFailed);
        }
      } else {
        _showSnack('Marked as processing.', color: AppColors.statusProcessing);
      }
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
      final canDial = order.method == 'evc_plus' &&
          buildPayoutUssdDialUri(_evcPayoutTemplate, order.phoneNumber ?? '', order.netAmount) != null;
      if (canDial) {
        return [
          ElevatedButton.icon(
            onPressed: () => _payAndDial(order),
            icon: const Icon(Icons.dialpad_rounded, size: 18),
            label: const Text('Pay / Confirm Payment'),
          ),
        ];
      }
      return [
        ElevatedButton(onPressed: () => _startProcessing(order), child: const Text('Start Processing')),
      ];
    }
    if (order.status == 'processing') {
      final canDial = order.method == 'evc_plus' &&
          buildPayoutUssdDialUri(_evcPayoutTemplate, order.phoneNumber ?? '', order.netAmount) != null;
      return [
        if (canDial)
          OutlinedButton.icon(
            onPressed: () => _dialToPay(order),
            icon: const Icon(Icons.dialpad_rounded, size: 18),
            label: const Text('Dial to Pay'),
          ),
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
