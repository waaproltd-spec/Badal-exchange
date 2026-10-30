import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../services/push_notifications.dart';
import '../../services/success_sound.dart';
import '../../widgets/transaction_views.dart';
import '../home/home_screen.dart';
import '../notifications/notifications_screen.dart';
import '../orders/orders_list_screen.dart';
import '../profile/profile_screen.dart';

/// Bottom navigation shell with exactly three tabs: Home, Orders, Profile.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  late final List<Widget> _tabs = [
    HomeScreen(onViewAllOrders: () => setState(() => _index = 1)),
    const OrdersListScreen(),
    const ProfileScreen(),
  ];

  PushNotifications? get _push => PushNotifications.instance;

  @override
  void initState() {
    super.initState();
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
      body: IndexedStack(index: _index, children: _tabs),
      // Compact bar; NavigationBar adds the device's bottom safe area itself.
      bottomNavigationBar: NavigationBar(
        height: 62,
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          // The limits show what was withdrawn up to now.
          if (i == 2) ProfileScreen.refresh.value++;
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home_rounded),
            label: AppStrings.home,
          ),
          NavigationDestination(
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long_rounded),
            label: AppStrings.orders,
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline_rounded),
            selectedIcon: const Icon(Icons.person_rounded),
            label: AppStrings.profile,
          ),
        ],
      ),
    );
  }
}
