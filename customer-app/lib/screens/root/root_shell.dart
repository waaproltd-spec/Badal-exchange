import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/payment_method.dart';
import '../../services/push_notifications.dart';
import '../../state/auth_provider.dart';
import '../../services/success_sound.dart';
import '../../widgets/floating_nav_bar.dart';
import '../../widgets/transaction_views.dart';
import '../home/home_screen.dart';
import '../notifications/notifications_screen.dart';
import '../orders/orders_list_screen.dart';
import '../profile/profile_screen.dart';
import '../tips/tips_screen.dart';

/// Bottom navigation shell with four tabs: Home, Orders, TIPS (Shaxaha), Profile.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _index = 0;

  late final List<Widget> _tabs = [
    HomeScreen(onViewAllOrders: () => setState(() => _index = 1)),
    const OrdersListScreen(),
    const TipsScreen(),
    const ProfileScreen(),
  ];

  PushNotifications? get _push => PushNotifications.instance;

  /// Back in the app: the latest platform logos (a manager may have changed one).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(context.read<CustomerApi>().loadMethodCatalog());
      // Back in the app: has the account been blocked meanwhile?
      unawaited(context.read<AuthProvider>().checkAccount());
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final push = _push;
    if (push == null) return;
    // Signed in: this device gets the customer's notifications.
    push.start(context.read<CustomerApi>());
    push.opened.addListener(_openFromNotification);
    push.foreground.addListener(_showForeground);
    // Tapped to start the app: open it once the shell is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openFromNotification());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _push?.opened.removeListener(_openFromNotification);
    _push?.foreground.removeListener(_showForeground);
    super.dispose();
  }

  /// A tapped notification: that transaction's details, or for a broadcast
  /// the Notifications screen.
  Future<void> _openFromNotification() async {
    final push = _push;
    final m = push?.opened.value;
    if (push == null || m == null || !mounted) return;
    push.opened.value = null;
    if (m.isBroadcast) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
      return;
    }
    try {
      final order = await context.read<CustomerApi>().getOrder(m.orderId);
      SuccessSound.instance.observe([order]);
      if (mounted) await showTransactionDetails(context, order);
    } catch (_) {
      // Not this customer's order, or offline: the Orders tab still has it.
      if (mounted) setState(() => _index = 1);
    }
  }

  /// Arrived while the app is open: a message to all customers shows as a
  /// banner. A deposit or withdrawal shows nothing more: the app already
  /// shows it (its result screen, Orders, the balance).
  void _showForeground() {
    final m = _push?.foreground.value;
    if (m == null || !mounted) return;
    _push?.foreground.value = null;
    if (!m.isBroadcast) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      key: Key('push-banner-${m.isBroadcast ? 'broadcast' : m.orderId}'),
      duration: const Duration(seconds: 6),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.title != null) Text(m.title!, style: const TextStyle(fontWeight: FontWeight.w800)),
          if (m.body != null) Text(m.body!),
        ],
      ),
      action: SnackBarAction(
        label: AppStrings.viewDetails,
        onPressed: () => _push?.opened.value = m,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The screens are built again when a platform's logo changed.
      body: ValueListenableBuilder<int>(
        valueListenable: paymentMethodLogosVersion,
        builder: (_, version, __) => KeyedSubtree(
          key: ValueKey(version),
          child: IndexedStack(index: _index, children: _tabs),
        ),
      ),
      // The floating bar adds its own margins and the device's bottom safe area.
      bottomNavigationBar: FloatingNavBar(
        selectedIndex: _index,
        onSelected: (i) {
          setState(() => _index = i);
          // The limits show what was withdrawn up to now.
          if (i == 2) TipsScreen.refresh.value++;
          if (i == 3) ProfileScreen.refresh.value++;
        },
        tabs: [
          NavTab(icon: Icons.home_outlined, selectedIcon: Icons.home_rounded, label: AppStrings.home),
          NavTab(icon: Icons.receipt_long_outlined, selectedIcon: Icons.receipt_long_rounded, label: AppStrings.orders),
          NavTab(icon: Icons.tips_and_updates_outlined, selectedIcon: Icons.tips_and_updates_rounded, label: AppStrings.tips),
          NavTab(icon: Icons.person_outline_rounded, selectedIcon: Icons.person_rounded, label: AppStrings.profile),
        ],
      ),
    );
  }
}
