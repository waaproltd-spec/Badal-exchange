import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../api/api_exception.dart';
import '../models/match_result.dart';
import '../models/order.dart';
import '../models/sms_transaction_log.dart';
import '../services/sms_log_store.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/order_card.dart';
import '../widgets/state_views.dart';
import '../widgets/winwin_confirm_sheet.dart';

/// Pending Deposits: EVC Plus deposits are matched automatically in the
/// background by the SMS bridge (see lib/sms/sms_bridge.dart) — a matched
/// order simply disappears from this list on the next refresh, since its
/// status moves to completed. WinWin deposits are confirmed manually via
/// the floating action button, which opens a small form submitting to
/// POST /agent/winwin-transactions.
class PendingDepositsScreen extends StatefulWidget {
  const PendingDepositsScreen({super.key});

  @override
  State<PendingDepositsScreen> createState() => _PendingDepositsScreenState();
}

class _PendingDepositsScreenState extends State<PendingDepositsScreen> {
  List<Order>? _orders;
  String? _error;
  bool _loading = true;
  bool _submittingWinwin = false;

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

  Future<void> _openWinwinConfirmSheet() async {
    final input = await showWinwinConfirmSheet(context);
    if (input == null || !mounted) return;

    setState(() => _submittingWinwin = true);
    final occurredAt = DateTime.now();
    MatchResult result;
    try {
      result = await context.read<Session>().api.submitWinwinTransaction(
            winwinId: input.winwinId,
            depositCode: input.depositCode,
            amount: input.amount,
            mobcashRef: input.mobcashRef,
            occurredAt: occurredAt,
          );
    } catch (e) {
      result = MatchResult.error(e is ApiException ? e.message : 'Failed to submit confirmation.');
    }

    await SmsLogStore.instance.add(SmsTransactionLog(
      id: const Uuid().v4(),
      provider: 'winwin',
      sender: input.winwinId,
      amount: input.amount,
      transactionRef: input.mobcashRef,
      occurredAt: occurredAt,
      submittedAt: DateTime.now(),
      status: result.status,
      orderId: result.orderId,
      errorMessage: result.errorMessage,
      isManualWinwin: true,
    ));

    if (!mounted) return;
    _showResultSnackBar(result);
    if (result.status == MatchStatus.matched) {
      _load();
    }
    setState(() => _submittingWinwin = false);
  }

  void _showResultSnackBar(MatchResult result) {
    final messenger = ScaffoldMessenger.of(context);
    switch (result.status) {
      case MatchStatus.matched:
        messenger.showSnackBar(const SnackBar(
          content: Text('Matched — the deposit order has been completed.'),
          backgroundColor: AppColors.statusCompleted,
        ));
        break;
      case MatchStatus.unmatched:
        messenger.showSnackBar(const SnackBar(
          content: Text('No pending order matched these details. Double-check and try again.'),
          backgroundColor: AppColors.statusUnmatched,
        ));
        break;
      case MatchStatus.duplicate:
        messenger.showSnackBar(const SnackBar(
          content: Text('This transaction was already submitted.'),
          backgroundColor: AppColors.statusDuplicate,
        ));
        break;
      case MatchStatus.error:
        messenger.showSnackBar(SnackBar(
          content: Text(result.errorMessage ?? 'Something went wrong.'),
          backgroundColor: AppColors.statusFailed,
        ));
        break;
    }
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
                            message: 'EVC Plus deposits match automatically once the payment SMS arrives.',
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 8, bottom: 96),
                        itemCount: _orders!.length,
                        itemBuilder: (context, index) => OrderCard(order: _orders![index]),
                      ))),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _submittingWinwin ? null : _openWinwinConfirmSheet,
        icon: _submittingWinwin
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
              )
            : const Icon(Icons.add_rounded),
        label: const Text('Enter WinWin confirmation'),
      ),
    );
  }
}
