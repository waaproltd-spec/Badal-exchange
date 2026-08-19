import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../models/order.dart';
import '../state/session.dart';
import '../widgets/order_card.dart';
import '../widgets/state_views.dart';

class CompletedScreen extends StatefulWidget {
  const CompletedScreen({super.key});

  @override
  State<CompletedScreen> createState() => _CompletedScreenState();
}

class _CompletedScreenState extends State<CompletedScreen> {
  List<Order>? _orders;
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
      final orders = await context.read<Session>().api.getCompletedOrders();
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Failed to load completed orders.';
        _loading = false;
      });
    }
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
                        EmptyStateView(icon: Icons.check_circle_rounded, title: 'No completed orders yet'),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 8, bottom: 24),
                      itemCount: _orders!.length,
                      itemBuilder: (context, index) => OrderCard(order: _orders![index]),
                    ))),
    );
  }
}
