import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/customer_api.dart';
import '../../models/exchange.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_card.dart';
import '../../widgets/summary_row.dart';
import 'exchange_status.dart';

/// One exchange order, kept live (Realtime plus a light poll):
/// 1. Waiting for payment: how to pay (number, amount, ready-to-dial code).
/// 2. Payment verified -> sending the payout.
/// 3. Completed (or being checked, if the payout needs a person).
class ExchangeOrderScreen extends StatefulWidget {
  const ExchangeOrderScreen({super.key, required this.initial});

  final ExchangeOrder initial;

  @override
  State<ExchangeOrderScreen> createState() => _ExchangeOrderScreenState();
}

class _ExchangeOrderScreenState extends State<ExchangeOrderScreen> {
  late ExchangeOrder _order = widget.initial;
  StreamSubscription<String>? _live;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    final api = context.read<CustomerApi>();
    _live = api.liveChanges.where((t) => t == 'exchange_orders').listen((_) => _refresh());
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_order.isFinal) _refresh();
    });
  }

  @override
  void dispose() {
    _live?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final o = await context.read<CustomerApi>().exchangeOrder(_order.id);
      if (mounted) setState(() => _order = o);
    } catch (_) {}
  }

  Future<void> _dial(String ussd) async {
    final uri = Uri.parse('tel:${ussd.replaceAll('#', '%23')}');
    if (!await launchUrl(uri)) {
      await _copy(ussd, 'Code copied');
    }
  }

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  int get _step => switch (_order.status) {
        'pending' => 0,
        'in_progress' || 'failed' => 1,
        'completed' => 2,
        _ => -1,
      };

  @override
  Widget build(BuildContext context) {
    final o = _order;
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text('Exchange ${o.id}', style: AppTextStyles.appBarTitle)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(children: [
                Expanded(child: Text('${o.fromLabel} → ${o.toLabel}', style: AppTextStyles.headline)),
                ExchangeStatusBadge(status: o.status),
              ]),
              const SizedBox(height: 8),
              Text(o.statusMessage, style: AppTextStyles.muted),
              const SizedBox(height: 20),
              if (o.status != 'cancelled') _Steps(step: _step),
              if (o.status == 'pending') ...[
                const SizedBox(height: 20),
                AppCard(
                  color: AppColors.goldTint,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pay now', style: AppTextStyles.title),
                      const SizedBox(height: 8),
                      Text(
                        'Send exactly ${Formatters.money(o.amountSent)} with ${o.fromLabel} from ${o.senderPhone} '
                        'to ${o.collectionPhoneNumber ?? '-'}. We confirm it automatically when the payment arrives.',
                        style: AppTextStyles.body,
                      ),
                      if (o.collectionUssd != null) ...[
                        const SizedBox(height: 16),
                        SelectableText(o.collectionUssd!, style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _dial(o.collectionUssd!),
                              icon: const Icon(Icons.call),
                              label: const Text('Dial to pay'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.outlined(
                            tooltip: 'Copy code',
                            onPressed: () => _copy(o.collectionUssd!, 'Code copied'),
                            icon: const Icon(Icons.copy),
                          ),
                        ]),
                      ],
                      const SizedBox(height: 12),
                      Text('Pay from the same number and the exact amount, or it can\'t be matched to this order.',
                          style: AppTextStyles.muted),
                    ],
                  ),
                ),
              ],
              if (o.status == 'failed') ...[
                const SizedBox(height: 20),
                AppCard(
                  child: Text(
                    'Your payment was received. The payout to ${o.receiverPhone} needs a check by our team; '
                    'you don\'t need to pay again.',
                    style: AppTextStyles.body,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              AppCard(
                child: Column(children: [
                  SummaryRow(label: 'You send', value: '${Formatters.money(o.amountSent)} (${o.fromLabel})'),
                  SummaryRow(label: 'From', value: o.senderPhone),
                  SummaryRow(label: 'Fee', value: Formatters.money(o.fee)),
                  SummaryRow(label: 'You receive', value: '${Formatters.money(o.amountReceived)} (${o.toLabel})', emphasize: true),
                  SummaryRow(label: 'To', value: o.receiverPhone),
                  SummaryRow(label: 'Created', value: Formatters.dateTime(o.createdAt)),
                  if (o.completedAt != null) SummaryRow(label: 'Completed', value: Formatters.dateTime(o.completedAt!)),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    const labels = ['Payment', 'Verified & sending', 'Received'];
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Column(children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: i < step || step == 2 ? AppColors.statusCompleted : (i == step ? AppColors.primary : AppColors.cardBorder),
                child: Icon(i < step || step == 2 ? Icons.check : Icons.circle, size: 14, color: Colors.white),
              ),
              const SizedBox(height: 6),
              Text(labels[i], style: AppTextStyles.muted, textAlign: TextAlign.center),
            ]),
          ),
      ],
    );
  }
}
