import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/order.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_card.dart';
import '../../widgets/method_icon.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/summary_row.dart';

class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  Order? _order;
  String? _error;
  bool _loading = true;

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
      final order = await context.read<CustomerApi>().getOrder(widget.orderId);
      if (!mounted) return;
      setState(() => _order = order);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load this order.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.orderDetails, style: AppTextStyles.title)),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, style: AppTextStyles.muted, textAlign: TextAlign.center),
                    ),
                  )
                : _buildContent(_order!),
      ),
    );
  }

  Widget _buildContent(Order order) {
    final isDeposit = order.isDeposit;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(child: MethodIcon(method: order.method, size: 56)),
        const SizedBox(height: 16),
        Center(
          child: Text(
            '${isDeposit ? '+' : '-'}${Formatters.money(order.amount)}',
            style: AppTextStyles.amountLarge,
          ),
        ),
        const SizedBox(height: 8),
        Center(child: StatusBadge(status: order.status)),
        const SizedBox(height: 8),
        Center(
          child: Text(order.statusMessage, style: AppTextStyles.muted, textAlign: TextAlign.center),
        ),
        const SizedBox(height: 28),
        if (order.method == 'winwin' && order.depositCode != null) ...[
          AppCard(
            color: AppColors.primaryTint,
            child: Column(
              children: [
                Text(
                  AppStrings.depositCodeLabel.toUpperCase(),
                  style: AppTextStyles.label.copyWith(color: AppColors.primaryDark),
                ),
                const SizedBox(height: 10),
                Text(
                  order.depositCode!,
                  style: AppTextStyles.title.copyWith(color: AppColors.primaryDark, letterSpacing: 4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        AppCard(
          child: Column(
            children: [
              SummaryRow(label: 'Order ID', value: order.orderCode),
              const SummaryDivider(),
              SummaryRow(
                label: AppStrings.method,
                value: order.isEvc ? AppStrings.evcPlus : AppStrings.winwin,
              ),
              const SummaryDivider(),
              SummaryRow(label: 'Type', value: isDeposit ? AppStrings.deposit : AppStrings.withdraw),
              if (order.phoneNumber != null) ...[
                const SummaryDivider(),
                SummaryRow(label: 'Phone Number', value: order.phoneNumber!),
              ],
              if (order.winwinId != null) ...[
                const SummaryDivider(),
                SummaryRow(label: 'WinWin ID', value: order.winwinId!),
              ],
              const SummaryDivider(),
              SummaryRow(label: AppStrings.amount, value: Formatters.money(order.amount)),
              const SummaryDivider(),
              SummaryRow(label: AppStrings.fee, value: Formatters.money(order.fee)),
              const SummaryDivider(),
              SummaryRow(
                label: isDeposit ? AppStrings.netAmount : 'You receive',
                value: Formatters.money(order.netAmount),
              ),
              if (order.transactionRef != null) ...[
                const SummaryDivider(),
                SummaryRow(label: AppStrings.transactionRef, value: order.transactionRef!),
              ],
              if (order.failureReason != null) ...[
                const SummaryDivider(),
                SummaryRow(label: 'Failure Reason', value: order.failureReason!),
              ],
              const SummaryDivider(),
              SummaryRow(label: AppStrings.createdAt, value: Formatters.dateTime(order.createdAt)),
              if (order.completedAt != null) ...[
                const SummaryDivider(),
                SummaryRow(label: AppStrings.completedAt, value: Formatters.dateTime(order.completedAt!)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
