import 'package:flutter/material.dart';

import '../../models/order.dart';
import '../../theme/colors.dart';
import '../../widgets/transaction_views.dart';

/// The withdrawal as submitted: amount, status ("Withdrawal Confirmed" once
/// paid out, otherwise in progress) and its details.
class WithdrawResultScreen extends StatelessWidget {
  const WithdrawResultScreen({super.key, required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: SafeArea(
        child: FollowOrder(order: order, builder: (context, order) => TransactionResultView(order: order)),
      ),
    );
  }
}
