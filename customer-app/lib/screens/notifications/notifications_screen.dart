import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/app_content.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';

/// Messages sent to all customers from the Agent App, newest first.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late Future<List<AppNotification>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<CustomerApi>().getNotifications();
  }

  Future<void> _reload() async {
    final next = context.read<CustomerApi>().getNotifications();
    setState(() => _future = next);
    await next.catchError((_) => <AppNotification>[]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.notifications, style: AppTextStyles.appBarTitle)),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: FutureBuilder<List<AppNotification>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator(color: AppColors.primary));
            }
            if (snapshot.hasError) {
              final e = snapshot.error;
              return ListView(children: [
                const SizedBox(height: 140),
                Center(
                  child: Text(
                    e is ApiException ? e.message : 'Could not load notifications.',
                    style: AppTextStyles.muted,
                  ),
                ),
              ]);
            }
            final items = snapshot.data!;
            if (items.isEmpty) {
              return ListView(children: [
                const SizedBox(height: 140),
                Center(child: Text(AppStrings.noNotifications, style: AppTextStyles.muted)),
              ]);
            }
            return ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final n = items[i];
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.cardBorder, width: 1.5),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(color: AppColors.goldTint, shape: BoxShape.circle),
                        child: const Icon(Icons.notifications_rounded, color: AppColors.accentOrange, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(n.title, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(n.body, style: AppTextStyles.muted),
                            const SizedBox(height: 6),
                            Text(Formatters.dateTime(n.createdAt), style: AppTextStyles.muted.copyWith(fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
